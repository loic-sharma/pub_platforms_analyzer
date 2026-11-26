# Pub platforms analyzer

## Usage

```sh
dart run main.dart [--out pub.jsonl] [--concurrency 32] [--archive-concurrency 4] [--all]
```

Output with timestamps:

```sh
dart run main.dart --out "data/$(date +%F)-pub.jsonl" --failures "data/$(date +%F)-failures.jsonl"
```

## Queries

Run this first to create a typed view of the data:

```sql
CREATE VIEW pub AS SELECT * FROM read_json('pub.jsonl', columns = {
  id: 'VARCHAR', is_plugin: 'BOOLEAN', pubspec: 'JSON', score: 'JSON',
  entries: 'STRUCT(name VARCHAR, size BIGINT, type VARCHAR)[]'});
```

### List packages

```sql
SELECT id,
  json_extract(score, '$.download_count_30_days')::BIGINT AS downloads_30d,
  json_keys(pubspec, '$.platforms') AS dart_platforms,
  CASE WHEN is_plugin
    THEN json_keys(pubspec, '$.flutter.plugin.platforms')
  END AS plugin_platforms
FROM pub
WHERE json_exists(pubspec, '$.platforms')
ORDER BY downloads_30d DESC NULLS LAST, id;
```

### Top-level folders

```sql
WITH folders AS (
  SELECT DISTINCT id, split_part(e.name, '/', 1) AS folder
  FROM (SELECT id, unnest(entries) AS e FROM pub)
  WHERE e.name LIKE '%/%' OR e.type = 'dir'
)
SELECT folder, count(*) AS packages
FROM folders
GROUP BY folder
ORDER BY packages DESC, folder;
```

### Declared platforms

Dart:

```sql
SELECT dart_platform, count(*) AS packages
FROM (
  SELECT unnest(json_keys(pubspec, '$.platforms')) AS dart_platform
  FROM pub
  WHERE json_exists(pubspec, '$.platforms')
)
GROUP BY dart_platform
ORDER BY packages DESC, dart_platform;
```

Flutter:

```sql
SELECT flutter_platform, count(*) AS packages
FROM (
  SELECT unnest(json_keys(pubspec, '$.flutter.plugin.platforms')) AS flutter_platform
  FROM pub
  WHERE is_plugin
)
GROUP BY flutter_platform
ORDER BY packages DESC, flutter_platform;
```

### Keys under `flutter.plugins.<platform>`

```sql
WITH platforms AS (
  SELECT id, pubspec,
    unnest(json_keys(pubspec, '$.flutter.plugin.platforms')) AS platform
  FROM pub
  WHERE json_type(pubspec, '$.flutter.plugin.platforms') = 'OBJECT'
), keys AS (
  SELECT id, platform,
    unnest(json_keys(pubspec, '$.flutter.plugin.platforms."' || platform || '"')) AS key
  FROM platforms
  WHERE json_type(pubspec, '$.flutter.plugin.platforms."' || platform || '"') = 'OBJECT'
)
SELECT key,
  list(DISTINCT platform ORDER BY platform) AS platforms,
  count(*) AS occurrences,
  count(DISTINCT id) AS packages
FROM keys
GROUP BY key
ORDER BY occurrences DESC, key;
```

## Tables

### pub.jsonl

This table contains one row per package, describing its latest version. Each line is one JSON object.

Column name | Data type | Description
-- | -- | --
id | String | Package name, e.g. `http`. Unique. Good for joins
version | String | Latest version, e.g. `1.6.0`
published | String | UTC timestamp when the latest version was published, ISO 8601 (e.g. `2024-10-05T16:15:30.055291Z`)
is_plugin | Bool | Whether the latest pubspec declares a Flutter plugin (`flutter.plugin`)
is_discontinued | Bool | Whether the package is marked discontinued
version_count | int | Number of published versions
score | Object | Package score, see [Score object](#score-object)
pubspec | Object | Latest version's pubspec, as JSON. Query with `json_extract`, e.g. `'$.flutter.plugin.platforms'`
entries | Array of objects | Files in the latest version's archive, see [entries](#entries-object). Null unless the package is a plugin (or the crawl used `--all`)
pubspec_yaml | String | Raw `pubspec.yaml` text from the archive, with comments and key order. Null when `entries` is null
archive_bytes | int | Size of the compressed `.tar.gz` archive, in bytes. Missing when `entries` is null

#### Score object

This object contains the package's score from `/api/packages/<name>/score`, with keys converted to snake case.

Column name | Data type | Description
-- | -- | --
granted_points | int | Pub points granted by pana
max_points | int | Maximum pub points available
like_count | int | Number of likes
download_count_30_days | int | Downloads over the last 30 days. Null for some packages, e.g. ones published very recently
tags | Array of strings | Package tags, e.g. `sdk:flutter`, `platform:android`, `is:dart3-compatible`, `license:mit`

### Entries object

This array contains one object per tar entry in the latest version's archive. Entries are listed, not extracted.

Column name | Data type | Description
-- | -- | --
name | String | Path relative to the package root, e.g. `lib/src/client.dart`
size | int | Uncompressed size in bytes. 0 for directories
type | String | `file`, `dir`, or another tar entry type such as `symlink` or `link`
