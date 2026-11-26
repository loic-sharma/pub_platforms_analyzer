# Usage

```sh
dart run main.dart --out pub.jsonl [--concurrency 32] [--archive-concurrency 4] [--all]
```

# Queries

### List packages

```sql
SELECT id,
  list(DISTINCT split_part(e.name, '/', 1)) FILTER (WHERE e.name LIKE '%/%') AS top_dirs,
  json_keys(any_value(pubspec), '$.flutter.plugin.platforms') AS declared
FROM (SELECT id, pubspec, unnest(entries) AS e
      FROM read_json_auto('pub.jsonl') WHERE is_plugin)
GROUP BY id;
```

### Top-level folders

```sql
CREATE VIEW pub AS SELECT * FROM read_json('pub.jsonl', columns = {
  id: 'VARCHAR', is_plugin: 'BOOLEAN', pubspec: 'JSON',
  entries: 'STRUCT(name VARCHAR, size BIGINT, type VARCHAR)[]'});

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

```sql
CREATE VIEW pub AS SELECT * FROM read_json('pub.jsonl', columns = {
  id: 'VARCHAR', is_plugin: 'BOOLEAN', pubspec: 'JSON',
  entries: 'STRUCT(name VARCHAR, size BIGINT, type VARCHAR)[]'});

SELECT platform, count(*) AS packages
FROM (SELECT unnest(json_keys(pubspec, '$.flutter.plugin.platforms')) AS platform
      FROM pub WHERE is_plugin)
GROUP BY platform
ORDER BY packages DESC, platform;
```
