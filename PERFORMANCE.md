# Performance notes for `main.dart`

Notes for whoever works on crawler speed next. All numbers come from an
Apple Silicon Mac on a home connection in November 2026. Measure again before
relying on any absolute number. The relative findings should still hold.

## TL;DR

- **The crawler is limited by network bandwidth, not CPU.** Most of the time
  goes to downloading plugin archives (`.tar.gz`). The process uses about 20% of
  one core.
- **Metadata and archives need different concurrency.** Metadata requests are
  small and limited by latency, so they benefit from many in flight. Archive
  downloads are large and limited by bandwidth, so a few in flight are enough,
  and more just fight over the link.
- Splitting the two into separate pools and HTTP clients, and capping archive
  downloads at 4 (`--archive-concurrency 4`), gave **about 4.6× more packages
  and 2× more archive bytes** in the same time as the original single pool of
  32. The records written were identical.

## What was measured

### Where the time goes

| Measurement | Result |
|---|---|
| CPU time during a ~100 s run of the original | ~21 s user, so not CPU-bound |
| Metadata request, single, with curl (`/api/packages/<name>`) | ~120 ms, 1–10 KB gzipped |
| Metadata requests only, 32 concurrent, from Dart | **160 packages/s**, p50 159 ms, p90 255 ms |
| Metadata requests only, 64 concurrent | 155/s, p50 259 ms, so no gain past 32 |
| Metadata latency **during a real crawl** (original) | p50 417 ms, p90 1076 ms, rising to ~1.1 s average |
| Archive download latency during a real crawl (original) | ~2.8 s average |
| Total link bandwidth (4 parallel curl downloads from GCS) | ~4 MB/s |
| 8 parallel cache-busted archive downloads from pub.dev | ~2.4 MB/s total |
| Archive throughput reached by the original | ~1.15–1.75 MB/s |
| CPU to sha256 + gunzip + list a 9.2 MB archive (27 MB unpacked, AOT) | sha256 ~34 ms, tar listing ~38 ms |

So:
- The metadata endpoint can serve far faster than the crawl ran. During a crawl
  its latency went up 3–7× because the requests queued behind archive
  downloads, both for pool slots and on the saturated link.
- CPU cost is about 20 ms per MB of compressed archive. Even with `--all`, that
  stays well below the network cost at this bandwidth.
- No HTTP 429s or 5xxs showed up at 32-way concurrency, so pub.dev was not
  throttling.

### Data shape (from the first ~1300 packages, alphabetical)

- 96,854 packages in total (`/api/package-names`, ~470 KB).
- About 25% are plugins in the first slice. That share is probably lower over
  the whole list, so check it.
- Plugin archives: median ~93 KB, but heavy-tailed. One was 9.1 MB, and pub.dev
  allows archives up to 100 MB. A handful of large archives make up most of the
  bytes.
- Package names are `[a-z0-9_]` only, so they never need JSON escaping. The
  fast resume path depends on this.

## What changed, and why

1. **Separate pools and `HttpClient`s for metadata and archives.** A package
   frees its metadata slot before waiting for an archive slot, so big
   downloads can't starve metadata requests.
2. **`--archive-concurrency` defaults to 4.** Measured on 60 s runs, in
   packages / archive MB:
   - original (single pool of 32): 845/69 and 840/68
   - 8: 2006/103 and 2429/90
   - **4: 3856/130 and 3871/135**
   - 16: 2503/43 (one run only)

   Fewer streams means less queuing on the link, so metadata stays fast too.
   The best value depends on bandwidth, and 4 was only measured on this one
   home connection. **On a faster link (or a cloud machine), raise
   `--archive-concurrency` and watch archive MB per second across a few
   60-second runs; keep the lowest value past which it stops rising.**
3. **An `inFlight` pool (max(1000, …))** caps the number of packages between
   "metadata started" and "line written". Without it, metadata runs far ahead
   of archives and finished records pile up in memory, especially with `--all`.
4. **Idle timeout (60 s with no bytes) instead of a 2-minute total timeout.**
   Under contention, a large archive could hit the 2-minute limit mid-download
   and be downloaded again on every retry, wasting the scarce resource.
   Non-200 response bodies are now read to the end so their connections can be
   reused.

   **Keep timeouts from leaking connections.** `Future.timeout` only stops
   *waiting*. On `client.send(...)` the request carries on, and its late
   response is never listened to, so it holds one of the few pooled
   connections indefinitely (with 4 archive slots, each leak is a 25%
   throughput loss). `_get` therefore uses `http.AbortableRequest` and
   completes the abort trigger on timeout (needs `http` ≥ 1.5.0). For bodies,
   use `stream.timeout(...)`, which cancels the subscription, never
   `drain().timeout(...)`. Verified with a local server that never sends
   headers and `maxConnectionsPerHost = 1`: the old code left the next request
   with no connection; the new one serves it immediately.
5. **Fused `utf8.decoder.fuse(json.decoder)`** parses JSON straight from bytes.
   This is a minor CPU saving.
6. **`_loadDone` streams the output file.** It finds the last newline by
   reading backwards in 64 KB chunks, truncates any partial line, and takes
   each id from the `{"id":"` prefix, falling back to `jsonDecode`. Before,
   it read the whole file into memory and fully decoded every line, which
   hurts with multi-GB `--all` output.

7. **Clean shutdown on Ctrl+C / SIGTERM.** The `inFlight` buffer means up to
   ~1000 packages can be partly done at any moment, and killing the process
   threw that work away. Now the first signal completes `_stopRequested`:
   packages still waiting for a pool slot are dropped (via `_Stopped`, which
   is not recorded as a failure), a retry backoff in progress is cut short
   and not retried (`_backoff` also cancels its timer so it can't keep the
   process alive), and only requests already sent are finished and written.
   Measured: exit 9–11 s after the signal (the wait is the 4 archive downloads
   in progress), no partial or duplicate lines. A second signal exits at once
   with 130 (SIGINT) or 143 (SIGTERM); the next run truncates any partial line.

## How to benchmark

The benchmarks run against **live pub.dev**, so keep runs short and don't
start several at once. The script sets a User-Agent with a contact address.
Keep it.

### 1. Build AOT binaries

JIT warm-up skews short runs, so compile both versions:

```bash
git show HEAD:main.dart > /tmp/orig.dart   # or any baseline revision
```

The baseline must sit **inside the project directory** to resolve
`package:` imports. Copy it in, compile, then delete it:

```bash
cp /tmp/orig.dart orig.dart && dart compile exe orig.dart -o $SCRATCH/orig && rm orig.dart
```

```bash
dart compile exe main.dart -o $SCRATCH/new
```

### 2. Time-boxed runs into a scratch directory

Never point `--out` at the real `pub.jsonl`. The crawler resumes from its
`--out` file, so an empty file means every run starts from the same
alphabetical position, which makes runs comparable. The harness used:

```bash
#!/bin/bash
# usage: EXTRA="--archive-concurrency 4" run.sh <exe> <dir> <seconds>
cd $2; rm -f out.jsonl f.jsonl
$1 --out out.jsonl --failures f.jsonl $EXTRA > log.txt 2>&1 & PID=$!
sleep $3; kill -TERM $PID; wait $PID 2>/dev/null
python3 - <<'PY'
import json
rows=[json.loads(l) for l in open('out.jsonl') if l.endswith('\n')]
ab=sum(r.get('archive_bytes',0) for r in rows)
print(f"{len(rows)} pkgs, {sum(r['is_plugin'] for r in rows)} plugins, "
      f"{ab/1e6:.0f} MB archives, failures={sum(1 for _ in open('f.jsonl'))}")
PY
```

Report **both** packages written and archive MB. The package count alone
favours designs that run metadata ahead. Archive MB per second is the closest
measure of real progress, because archives dominate the total work.

Pitfalls found the hard way:
- macOS has no `timeout` or `gtimeout`.
- **Background jobs in a non-interactive bash ignore SIGINT**, so `kill -INT`
  does nothing to the original binary. Use `kill -TERM`. (The current version
  watches SIGINT itself, which overrides the ignore.)
- **SIGTERM now stops gracefully**, so the harness's `wait` includes ~10 s of
  finishing in-flight downloads, and those records count. Against an older
  binary that dies instantly on SIGTERM this slightly favours the new one;
  for a strict comparison, count only lines written before the signal, or
  compare runs of the current binary with different flags.
- `/usr/bin/time -l` wrapping the binary makes `pgrep -n` return the wrong
  process. Use `$!` instead.
- **Results are noisy.** pub.dev sits behind a CDN with `max-age=7200`, so the
  first run is cold and later runs are warmer. Run variants **back to back and
  alternate the order**. Repeat the baseline in the same session.
- Adding `?x=N` to an archive URL bypasses the CDN. That is useful for
  measuring origin bandwidth, but it is not representative of a crawl.

### 3. Per-request instrumentation

To see latency per request type, temporarily add a log line in `_get` after
the response arrives:

```dart
stderr.writeln('${t0.millisecondsSinceEpoch} ${elapsedMs} ${res.statusCode} ${bytes} $url');
```

Then group the lines with awk by URL type (`/api/packages/` vs `/api/archives/`)
and by 5-second bucket. That is how the "metadata latency rises during the
crawl" finding came out. Compile it as a separate binary and don't commit it.

### 4. Check correctness on every change

Compare records for package ids that appear in both a baseline run and a new
run. They must be byte-for-byte equal as parsed JSON:

```python
a = {json.loads(l)['id']: json.loads(l) for l in open('base/out.jsonl')}
b = {json.loads(l)['id']: json.loads(l) for l in open('new/out.jsonl')}
assert all(a[k] == b[k] for k in a.keys() & b.keys())
```

Also check resume. Copy `pub.jsonl`, append a partial line such as
`{"id":"partial_li`, run for a few seconds, and confirm that the log reports
the right "already done" count, the partial line is gone, and no id appears
twice.

And check shutdown: send one SIGINT or SIGTERM after ~20 s and confirm exit
code 0 within seconds, a "Stopped after" line, no partial last line, and no
new failures. Send two SIGINTs a second apart and confirm exit code 130
almost immediately.

## Ideas not yet tried

Roughly in order of expected value:

For context: on this connection a full crawl is roughly 40 minutes, and the
link's ceiling (~4 MB/s) puts the best case near 20. That estimate is
extrapolated from the first ~1300 packages. No code change can beat the link,
so none of the ideas below were judged worth doing here. Running from a cloud
machine near Google Cloud Storage is the biggest lever, and only then do 2 and
3 start to matter.

1. **Fine-tune archive concurrency.** 4 was best of {4, 8, 16} on this link;
   2, 3, 5 and 6 were not tried. The owner chose to keep 4. Tuning per link is
   a flag change; see the bold note in "What changed".
2. **Stream archives instead of buffering them.** Feed chunks into a chunked
   sha256 sink and gzip→`TarReader` as they arrive. This overlaps CPU with
   network and caps memory per download, since archives can reach 100 MB.
   Watch out: the tar reader can stop before EOF, but sha256 has to see every
   byte, so keep draining the HTTP stream after tar finishes. A retry must
   throw away the partial entries. The CPU saving is small; the main benefit is
   memory.
3. **Move archive parsing to an isolate** (`Isolate.run`) when using `--all`.
   CPU is about 20 ms/MB, which only matters if bandwidth goes far above
   ~4 MB/s.
4. **HTTP/2** (via `package:http2` or `cupertino_http`/`cronet_http`). `dart:io`
   `HttpClient` only speaks HTTP/1.1. Multiplexing would mainly help metadata
   latency. Archives stay bandwidth-bound.
5. **Avoid fetching unneeded bytes.** `/api/packages/<name>` returns every
   version's pubspec, but we only use `latest` and the version count. No
   lighter endpoint was found. The responses are already gzipped and small, so
   this is low value.

What will **not** help: more metadata concurrency (flat past 32), or
optimizing sha256, gzip or tar code paths (negligible next to the network).

**Considered and rejected: adjusting archive concurrency automatically**
(e.g. AIMD on measured throughput, ~80–120 lines). The throughput signal is
dominated by which archives happen to be downloading (sizes range from KBs to
9 MB+) and by CDN cache hits, so it needs long windows and gets only a handful
of adjustments in a 40-minute crawl. Maximizing archive bytes can also slow
the metadata requests sharing the link, which is why 4 beat 8. It can't be
validated without real networks of different speeds. A fixed default plus
the flag is more predictable.
