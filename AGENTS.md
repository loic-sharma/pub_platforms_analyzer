# Notes for agents

A single-file Dart CLI ([main.dart](main.dart)) that crawls pub.dev and writes one JSON
line per package to a JSONL file, for analysis with DuckDB. Read these first:

- [README.md](README.md): usage, DuckDB queries, and the **output schema** (the
  "Tables" section).
- [PERFORMANCE.md](PERFORMANCE.md): what limits speed, every measurement, how to
  benchmark, and ideas already tried or rejected. Read it before touching
  concurrency, HTTP or scheduling code.

## Running

```bash
dart run main.dart --out "data/$(date +%F)-pub.jsonl" --failures "data/$(date +%F)-failures.jsonl"
```

- `data/` is git-ignored except `data/.gitkeep`. The script's defaults still
  write `pub.jsonl` / `failures.jsonl` in the project root.
- Resume is per `--out` file: packages already in it are skipped. A new file
  means a full crawl (~97k packages, roughly an hour on a ~10 MB/s link).
- `dart run` (JIT) is fine; the crawl is network-bound. `dart compile exe`
  gives no measurable speedup.

## Invariants (don't break these)

**Output data**
- One line per package; `"id"` must be the **first key** of every record.
  `_loadDone` reads ids from the `{"id":"` line prefix to resume without
  decoding lines.
- Existing lines are never rewritten. Output changes apply only to newly
  written rows, so a file can mix old and new shapes. When changing the
  output, update the README "Tables" section and any README query that uses
  the field.
- Score keys are converted to snake_case (`download_count_30_days`, etc.).
- Archive entry `type` is `dir`, `file` (tar `reg`/`regA`), or the tar type
  name (`symlink`, `link`, …).

**Performance and robustness** (benchmarked or bug fixes; details in
PERFORMANCE.md)
- Metadata and archives use separate "lanes" (`_Lane` = Pool + its own
  HttpClient): `--concurrency 32` for metadata and score requests,
  `--archive-concurrency 4` for archives. 4 saturated both a ~4 MB/s and a
  ~10 MB/s link; more streams only slow metadata down.
- `inFlight` pool (≥1000) caps packages between "metadata started" and "line
  written".
- `_get`: abort the request on a `send` timeout (`AbortableRequest`; a plain
  `Future.timeout` leaks the pooled connection); use `stream.timeout` for
  bodies, including the non-200 drain; timeouts are *idle* timeouts (60 s with
  no bytes), not total; retry only IOException / ClientException /
  TimeoutException; non-retried statuses throw `_HttpStatusException`.
- Shutdown: first SIGINT/SIGTERM completes `_stopRequested`. Queued work
  throws `_Stopped` (not a failure), `_backoff` is cut short and cancels its
  timer, and in-flight requests finish and are written. A second signal
  exits with 130/143. Signal subscriptions must be cancelled at the end or the
  process won't exit.

## Testing (there is no test suite)

- **Never hit pub.dev hard, and never point `--out` at real data.** Use short
  time-boxed runs (20–60 s) writing to a scratch directory. Don't run two
  crawlers at once; they share the bandwidth.
- **Unit-style checks of private functions:** copy `main.dart` to a temp file
  *inside the project directory* (package imports only resolve there), rename
  `main` to `realMain` with sed, append a test `main()` that calls `_get`,
  `_lane`, `_score`, etc. against a local `HttpServer` (stall, 503, 404
  routes), run it, then delete the temp file. Shorten `_idleTimeout` with sed
  for timeout tests. A useful check: with `_lane(1)`, a stalled request that
  times out must not block the next request on the single connection.
- **Output equality:** compare records for ids present in both an old and a
  new run (parse the JSON, compare dicts). Differences in `version`,
  `version_count`, `published` or `pubspec` usually mean the package
  released a new version in between, not a bug.
- **Resume:** copy a real output file, append a partial line, run briefly, and
  check the "already done" count, that the partial line is gone, that there
  are no duplicate ids, and that the original bytes are unchanged.
- **Shutdown:** one signal → exit 0 within seconds, no partial line; two
  signals → exit 130/143 at once.
- **Throughput:** measure MB/s from the interface byte counter
  (`netstat -ibn -I en0`), not completed downloads (that undercounts high
  concurrency). Alternate the order of variants; the CDN makes repeat runs
  warmer.
- macOS gotchas: there is no `timeout` command; background jobs in a
  non-interactive bash ignore SIGINT for binaries that don't watch it (use
  `kill -TERM`).
- Run `dart format main.dart` and `dart analyze` after edits.

## Environment

macOS (arm64), Dart 3.15 dev SDK, DuckDB at `~/.local/bin/duckdb`. In agent
mode DuckDB prints markdown tables. Use the typed view from the README rather
than `read_json_auto`, because inferred types can vary across rows.

## State as of 2026-11-26

- A fresh crawl was running into `data/2026-11-26-pub.jsonl` (87,800 rows when
  the session ended; resume with the same `--out` if it was interrupted).
  All of its rows have snake_case scores.
- `pub.jsonl.backup` / `failures.jsonl.backup` (untracked, project root): an
  earlier full crawl of 96,894 rows. Its first 33,485 rows have no `score`; the
  rest have **camelCase** score keys (`downloadCount30Days`), so README
  queries return NULL scores on it.

## Open ideas (not built)

- `--max-archive-mb` to defer large archives: read Content-Length, abort
  without downloading, and leave the package for a later run. 4% of archives
  (>20 MB) hold 60% of archive bytes.
- Change the script's default output paths to `data/`.
- Backfill or convert scores in old files (write a new file; never modify the
  original).
- Rejected: adaptive archive concurrency, HTTP/2, isolates, streaming archive
  parsing (see PERFORMANCE.md for why).

## Working with the owner

- Commit only when asked.
- Verify claims with measurements or tests before reporting them.
- Don't regress performance, and keep changes simple. Small wins aren't
  worth added complexity.
