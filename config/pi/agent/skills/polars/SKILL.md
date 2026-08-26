---
name: polars
description: |
  Concise Polars best-practice skill for lazy streaming pipelines.
  Covers Parquet, Delta Lake, SQLite/Postgres/MariaDB sources.
  Enforces scan, predicate pushdown, partition pruning, and sink.
---

# Polars — Lazy Streaming Best Practices

## Golden Rule
**Scan → Lazy transform → Sink.** Never `collect().write_*` on large data.

| Source | Lazy API | Notes |
|--------|----------|-------|
| Parquet | `pl.scan_parquet(path)` | Predicate/project pushdown built-in |
| Delta Lake | `pl.scan_delta(table_uri)` | Time-travel, partition pruning |
| SQLite/Postgres/MariaDB | `pl.read_database_uri(sql, uri)` then `.lazy()` | **Must use URI string**; push filters into SQL; partition with `partition_on` |

## Core Patterns

### Selection + Predicate Pushdown
Polars skips columns and row-groups at the scan level automatically.

```python
lf = (
    pl.scan_parquet("s3://bucket/events/*.parquet")
    .select("user_id", "event_time", "revenue")      # project pushdown
    .filter(pl.col("event_time") >= dt.date(2024, 1, 1))
    .filter(pl.col("revenue") > 0)                    # predicate pushdown
)
```

### Aggregation (Streaming)
Prefer native expressions. Group-by aggregates are fully streamable.

```python
lf = (
    pl.scan_parquet("*.parquet")
    .with_columns(pl.col("ts").dt.truncate("1h").alias("hour"))
    .group_by("hour", "region")
    .agg(
        pl.sum("revenue").alias("total_revenue"),
        pl.mean("revenue").alias("avg_revenue"),
        pl.count().alias("n_events"),
    )
)
lf.sink_parquet("output.parquet", compression="zstd", maintain_order=False)
```

### Partition Pruning (Parquet)
Use Hive-style paths so Polars skips files before reading.

```python
# Path structure enables pruning: year=2024/month=06/*.parquet
lf = pl.scan_parquet("s3://bucket/events/year=2024/**/*.parquet")
lf = lf.filter(pl.col("month") == 6)   # may prune directories
```

### Delta Lake
```python
lf = pl.scan_delta("s3://bucket/table")
    .filter(pl.col("date") >= dt.date(2024, 1, 1))
    .select("date", "user_id", "amount")

lf.sink_parquet("out.parquet")
```

### Database → Lazy
**Always use `pl.read_database_uri` with a URI string.** Never pass connection objects.

```python
uri = "postgresql://user:pass@host:5432/db"
# uri = "sqlite:///path/to/db.sqlite"
# uri = "mysql://user:pass@host:3306/db"

query = """
    SELECT user_id, event_time, amount
    FROM events
    WHERE event_time >= '2024-01-01'
"""
lf = pl.read_database_uri(query, uri).lazy()

# Partitioned read for huge tables
lf = pl.read_database_uri(
    "SELECT * FROM events WHERE partition_key = {partition}",
    uri,
    partition_on="partition_key",
    partition_range=(0, 99),
).lazy()

lf.group_by(...).agg(...).sink_parquet("out.parquet")
```

## Terminal Operations

| Method | When |
|--------|------|
| `lf.sink_parquet(path)` | Large result; stream to disk |
| `lf.sink_ipc(path)` | Arrow interop; streaming |
| `lf.collect(streaming=True)` | Result fits RAM; need DataFrame in Python |
| `lf.fetch(n=1000)` | Peek at head; stays lazy |

## Multiplexed Sinks
```python
q1 = lf.sink_parquet("out.parquet", lazy=True)
q2 = lf.sink_ipc("out.arrow", lazy=True)
pl.collect_all([q1, q2])
```

## Anti-Patterns
```python
# ❌ Eager read + eager write on big data
df = pl.read_parquet("*.parquet")
df.write_parquet("out.parquet")

# ❌ Collect just to sink
lf.collect().write_parquet("out.parquet")

# ❌ Database connection object instead of URI string
pl.read_database(query, engine=connection)
# ✅ pl.read_database_uri(query, "postgresql://...").lazy()

# ❌ Python UDF instead of native expr
lf.with_columns(pl.col("x").map_elements(lambda v: v * 2))
# ✅ pl.col("x") * 2

# ❌ Unbounded collect on huge data
lf.group_by(...).agg(...).collect()
# ✅ .sink_parquet(...) or .collect(streaming=True)
```

## Verify Streaming
```python
lf.explain(streaming=True)
# Look for full STREAMING plan. If you see --- END STREAMING,
# the remainder runs in-memory. Replace non-streaming ops.
```

## Checklist
- [ ] Source is `scan_parquet`, `scan_delta`, or `read_database_uri(..., uri_string).lazy()`
- [ ] Filters/projections are before any terminal op (pushdown)
- [ ] Hive-style partitioning used for file-skipping
- [ ] Terminal is `sink_*` or `collect(streaming=True)`
- [ ] No Python `map_elements` where native expr works
- [ ] `explain(streaming=True)` confirms streamability
