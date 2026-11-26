# Usage

```sh
dart run main.dart --out pub.jsonl [--concurrency 32] [--archive-concurrency 4] [--all]
```

# Queries

Run this first to create a typed view of the data:

```sql
CREATE VIEW pub AS SELECT * FROM read_json('pub.jsonl', columns = {
  id: 'VARCHAR', is_plugin: 'BOOLEAN', pubspec: 'JSON', score: 'JSON',
  entries: 'STRUCT(name VARCHAR, size BIGINT, type VARCHAR)[]'});
```

### List packages

```sql
SELECT id,
  json_extract(score, '$.downloadCount30Days')::BIGINT AS downloads_30d,
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
