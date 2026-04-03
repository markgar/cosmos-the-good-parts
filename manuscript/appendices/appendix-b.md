# Appendix B: NoSQL Query Language Reference

This is a quick-reference card for the Cosmos DB for NoSQL query language. For narrative explanations, worked examples, and cost analysis, see Chapter 8. For indexing strategies that affect query performance, see Chapter 9.

Every query targets a single container. The language is SQL-like but operates on schema-free JSON items — there are no cross-container joins, no foreign keys, no relational algebra.

<!-- Source: mslearn-docs/content/develop-modern-applications/tutorial-query.md -->

## Query Clause Reference

### SELECT

```sql
-- Return all properties
SELECT * FROM c

-- Project specific fields
SELECT c.name, c.price FROM c

-- Alias with AS
SELECT c.name AS productName, c.price AS unitPrice FROM c

-- Value expression (unwrap single-value wrapper)
SELECT VALUE c.name FROM c

-- Computed expressions
SELECT c.name, c.price * c.quantity AS totalValue FROM c
```

### DISTINCT

```sql
SELECT DISTINCT c.category FROM c

SELECT DISTINCT VALUE c.category FROM c
```

### TOP

```sql
SELECT TOP 10 c.name, c.price FROM c ORDER BY c.price DESC
```

### FROM

```sql
-- Alias the container (required)
SELECT * FROM products p WHERE p.price > 100
```

### WHERE

```sql
SELECT * FROM c WHERE c.category = "gear-surf-surfboards"

SELECT * FROM c WHERE c.price > 500 AND c.quantity > 0

SELECT * FROM c WHERE c.status != "discontinued"
```

### ORDER BY

```sql
-- Single property (requires range index)
SELECT * FROM c ORDER BY c.price ASC

-- Multiple properties (requires composite index)
SELECT * FROM c ORDER BY c.category ASC, c.price DESC
```

### GROUP BY

```sql
SELECT c.category, COUNT(1) AS itemCount, AVG(c.price) AS avgPrice
FROM c
GROUP BY c.category
```

### OFFSET LIMIT

```sql
-- Skip 20 rows, return 10 (expensive on large result sets — prefer continuation tokens)
SELECT * FROM c ORDER BY c.createdAt DESC OFFSET 20 LIMIT 10
```

### EXISTS

```sql
-- Items where at least one rating has score 5
SELECT * FROM c WHERE EXISTS (
    SELECT VALUE r FROM r IN c.ratings WHERE r.score = 5
)
```

### IN

```sql
SELECT * FROM c WHERE c.category IN ("gear-surf-surfboards", "gear-climb-helmets")
```

### BETWEEN

```sql
SELECT * FROM c WHERE c.price BETWEEN 100 AND 500
```

### LIKE

```sql
-- % = any sequence of characters, _ = single character
SELECT * FROM c WHERE c.name LIKE "Yamba%"

SELECT * FROM c WHERE c.sku LIKE "PROD-____"
```

> **Performance note:** `LIKE` uses a full index scan. Prefer `STARTSWITH` when matching prefixes — it uses a precise index scan and costs less.
<!-- Source: mslearn-docs/content/manage-your-account/containers-and-items/index-overview.md -->

### JOIN (Intra-Document)

Cosmos DB JOIN is a self-join within a single item — it flattens arrays, not cross-container relationships.

```sql
-- Flatten an array
SELECT c.name, tag
FROM c
JOIN tag IN c.tags

-- Flatten nested arrays with filter
SELECT c.name, r.user, r.score
FROM c
JOIN r IN c.ratings
WHERE r.score >= 4
```

### Subqueries

```sql
-- Scalar subquery
SELECT c.name, (SELECT VALUE COUNT(1) FROM r IN c.ratings) AS ratingCount
FROM c

-- Expression subquery in FROM
SELECT p.name, avgRating
FROM products p
JOIN (SELECT VALUE AVG(r.score) FROM r IN p.ratings) AS avgRating
```

---

## Operators

### Comparison Operators

| Operator | Description | Example |
|----------|-------------|---------|
| `=` | Equal | `c.status = "active"` |
| `!=` or `<>` | Not equal | `c.status != "deleted"` |
| `<` | Less than | `c.price < 100` |
| `>` | Greater than | `c.price > 100` |
| `<=` | Less than or equal | `c.quantity <= 0` |
| `>=` | Greater than or equal | `c.rating >= 4.5` |

### Logical Operators

| Operator | Description | Example |
|----------|-------------|---------|
| `AND` | Logical and | `c.price > 10 AND c.qty > 0` |
| `OR` | Logical or | `c.type = "a" OR c.type = "b"` |
| `NOT` | Logical negation | `NOT IS_DEFINED(c.deletedAt)` |

### Arithmetic Operators

| Operator | Description | Example |
|----------|-------------|---------|
| `+` | Addition | `c.price + c.tax` |
| `-` | Subtraction | `c.price - c.discount` |
| `*` | Multiplication | `c.price * c.quantity` |
| `/` | Division | `c.total / c.count` |
| `%` | Modulo | `c.id % 10` |

### Other Operators

| Operator | Description | Example |
|----------|-------------|---------|
| `\|\|` | String concatenation | `c.first \|\| " " \|\| c.last` |
| `??` | Null coalescing | `c.nickname ?? c.first` |
| `? :` | Ternary / conditional | `c.qty > 0 ? "Yes" : "No"` |

---

## Aggregate Functions

| Function | Description | Example |
|----------|-------------|---------|
| `COUNT(expr)` | Count of items | `SELECT COUNT(1) FROM c` |
| `SUM(expr)` | Sum numeric values | `SELECT SUM(c.price) FROM c` |
| `AVG(expr)` | Average numeric values | `SELECT AVG(c.price) FROM c` |
| `MIN(expr)` | Min value | `SELECT MIN(c.price) FROM c` |
| `MAX(expr)` | Max value | `SELECT MAX(c.price) FROM c` |

Use `COUNT(1)` to count all items. All aggregate functions ignore items where the expression evaluates to `undefined`. Combine with `GROUP BY` for per-group aggregation.

---

## System Functions by Category

### String Functions

| Function | Description |
|----------|-------------|
| `CONCAT(s1, s2, ...)` | Concatenate strings |
| `CONTAINS(s, sub)` | True if s contains sub |
| `ENDSWITH(s, suffix)` | True if s ends with suffix |
| `STARTSWITH(s, prefix)` | True if s starts with prefix |
| `INDEX_OF(s, sub)` | Position of sub, or -1 |
| `LEFT(s, len)` | Leftmost characters |
| `RIGHT(s, len)` | Rightmost characters |
| `LENGTH(s)` | String length |
| `LOWER(s)` | Convert to lowercase |
| `UPPER(s)` | Convert to uppercase |
| `LTRIM(s)` | Strip leading whitespace |
| `RTRIM(s)` | Strip trailing whitespace |
| `TRIM(s)` | Strip surrounding whitespace |
| `REPLACE(s, find, repl)` | Replace occurrences |
| `REPLICATE(s, n)` | Repeat s n times |
| `REVERSE(s)` | Reverse character order |
| `SUBSTRING(s, start, len)` | Extract substring (0-based) |
| `ToString(expr)` | Convert value to string |
| `StringEquals(s1, s2)` | String equality check |
| `RegexMatch(s, pattern)` | Regex match |

`CONTAINS`, `ENDSWITH`, `STARTSWITH`, and `StringEquals` accept an optional `ignoreCase` boolean parameter. `RegexMatch` accepts optional `modifiers` (e.g., `"i"` for case-insensitive).

> **Index efficiency:** `STARTSWITH` and `StringEquals` use precise or expanded index scans. `CONTAINS`, `ENDSWITH`, `RegexMatch`, and `LIKE` use full index scans. `UPPER` and `LOWER` trigger full container scans — avoid them in WHERE clauses on large containers.
<!-- Source: mslearn-docs/content/manage-your-account/containers-and-items/index-overview.md -->

### Mathematical Functions

| Function | Description |
|----------|-------------|
| `ABS(n)` | Absolute value |
| `CEILING(n)` | Smallest int ≥ n |
| `FLOOR(n)` | Largest int ≤ n |
| `ROUND(n)` | Nearest integer |
| `SIGN(n)` | Returns -1, 0, or 1 |
| `POWER(base, exp)` | base raised to exp |
| `SQRT(n)` | Square root |
| `LOG(n)` | Natural log |
| `LOG10(n)` | Base-10 log |
| `EXP(n)` | e^n |
| `PI()` | Returns π |
| `SIN(n)`, `COS(n)`, `TAN(n)` | Trig (radians) |
| `ASIN(n)`, `ACOS(n)`, `ATAN(n)` | Inverse trig |
| `ATN2(y, x)` | Arctangent of y/x |
| `RAND()` | Random float in [0, 1) |
| `NumberBin(n, size)` | Round to bin multiple |

### Array Functions

| Function | Description |
|----------|-------------|
| `ARRAY_CONCAT(a1, a2, ...)` | Concatenate arrays |
| `ARRAY_CONTAINS(arr, val)` | True if arr contains val |
| `ARRAY_LENGTH(arr)` | Element count |
| `ARRAY_SLICE(arr, start)` | Subset of array (0-based) |
| `SetIntersect(a1, a2)` | Common elements |
| `SetUnion(a1, a2)` | All unique elements |

`ARRAY_CONTAINS` accepts an optional third parameter `partial` (boolean) for partial object matching. `ARRAY_SLICE` accepts an optional `length` parameter.

### Type-Checking Functions

| Function | Returns true if… |
|----------|------------------|
| `IS_ARRAY(expr)` | Value is an array |
| `IS_BOOL(expr)` | Value is a boolean |
| `IS_NULL(expr)` | Value is null |
| `IS_NUMBER(expr)` | Value is a number |
| `IS_OBJECT(expr)` | Value is a JSON object |
| `IS_STRING(expr)` | Value is a string |
| `IS_DEFINED(expr)` | Property is assigned |
| `IS_PRIMITIVE(expr)` | Value is primitive |

`IS_DEFINED` returns true even when the value is null — it checks property existence, not value. `IS_PRIMITIVE` covers strings, numbers, booleans, and null.

### Date and Time Functions

| Function | Description |
|----------|-------------|
| `GetCurrentDateTime()` | Current UTC (ISO 8601) |
| `GetCurrentTimestamp()` | Current UTC (ms epoch) |
| `GetCurrentTicks()` | Current UTC (100ns ticks) |
| `DateTimeAdd(part, n, dt)` | Add n units to datetime |
| `DateTimeDiff(part, s, e)` | Diff between two datetimes |
| `DateTimePart(part, dt)` | Extract component |
| `DateTimeToTicks(dt)` | ISO 8601 → ticks |
| `TicksToDateTime(ticks)` | Ticks → ISO 8601 |
| `DateTimeToTimestamp(dt)` | ISO 8601 → Unix ms |
| `TimestampToDateTime(ts)` | Unix ms → ISO 8601 |
| `DateTimeBin(dt, part, n)` | Round to bin boundary |

All datetime parameters expect ISO 8601 strings. Ticks are 100-nanosecond intervals since 00:00:00 Jan 1, 0001. `DateTimeBin` accepts an optional `origin` parameter.

**Date part identifiers** used with these functions:

| Part | Abbreviation |
|------|-------------|
| Year | `"yyyy"` |
| Month | `"mm"` |
| Day | `"dd"` |
| Hour | `"hh"` |
| Minute | `"mi"` |
| Second | `"ss"` |
| Millisecond | `"ms"` |
| Microsecond | `"mcs"` |
| Nanosecond | `"ns"` |

### Spatial Functions

These functions require a spatial index on the queried property path. See Chapter 9 for spatial index configuration.

<!-- Source: mslearn-docs/content/manage-your-account/containers-and-items/index-overview.md -->
<!-- Source: mslearn-docs/content/develop-modern-applications/how-to-geospatial-index-query.md -->

| Function | Description |
|----------|-------------|
| `ST_DISTANCE(g1, g2)` | Distance in meters |
| `ST_WITHIN(g1, g2)` | True if g1 is within g2 |
| `ST_INTERSECTS(g1, g2)` | True if geometries overlap |
| `ST_ISVALID(g)` | True if GeoJSON is valid |
| `ST_ISVALIDDETAILED(g)` | Validity info + reason |

Both arguments are GeoJSON geometries. `ST_ISVALIDDETAILED` returns a JSON object with a `valid` boolean and a `reason` string.

Supported GeoJSON types: `Point`, `LineString`, `Polygon`, `MultiPolygon`.

```sql
-- Find locations within 5 km of a point
SELECT c.name, ST_DISTANCE(c.location, {"type":"Point","coordinates":[-122.12, 47.66]}) AS distMeters
FROM c
WHERE ST_DISTANCE(c.location, {"type":"Point","coordinates":[-122.12, 47.66]}) < 5000
```

### Vector Search Function

Vector search requires a container vector policy and vector index. See Chapter 25 for full configuration details.

<!-- Source: mslearn-docs/content/build-ai-applications/use-vector-search/vector-search.md -->

| Function | Description |
|----------|-------------|
| `VectorDistance(v1, v2)` | Vector similarity score |

Uses the distance function defined in the container's vector policy (see distance functions below).

**Distance functions** (configured in the container vector policy, not in the query):

| Metric | Range | Ordering |
|--------|-------|----------|
| `cosine` (default) | -1 to +1 | Higher = more similar |
| `dotproduct` | -∞ to +∞ | Higher = more similar |
| `euclidean` | 0 to +∞ | Lower = more similar |

```sql
-- Find 10 most similar items (always use TOP with vector search)
SELECT TOP 10 c.title, VectorDistance(c.contentVector, [1,2,3]) AS SimilarityScore
FROM c
ORDER BY VectorDistance(c.contentVector, [1,2,3])
```

> **Always use `TOP N`** with vector queries. Without it, the engine attempts to return all results, driving up RU cost and latency dramatically.

### Full-Text Search Functions

Full-text search requires a full-text index and full-text policy on the container. See Chapter 25 for setup.

<!-- Source: mslearn-docs/content/build-ai-applications/full-text-indexing-and-search/gen-ai-full-text-search.md -->

| Function | Used in |
|----------|---------|
| `FullTextContains(p, text)` | `WHERE` |
| `FullTextContainsAll(p, ...)` | `WHERE` |
| `FullTextContainsAny(p, ...)` | `WHERE` |
| `FullTextScore(p, ...)` | `ORDER BY RANK` |

- **FullTextContains** — true if property contains the text
- **FullTextContainsAll** — true if property contains *all* given terms
- **FullTextContainsAny** — true if property contains *any* given terms
- **FullTextScore** — BM25 relevance score

> **`FullTextScore` cannot be projected in `SELECT` or used in `WHERE`.** It can only appear inside an `ORDER BY RANK` clause.

```sql
-- Full-text filter
SELECT TOP 10 *
FROM c
WHERE FullTextContains(c.text, "red bicycle")

-- Full-text ranking (BM25 scoring)
SELECT TOP 10 *
FROM c
ORDER BY RANK FullTextScore(c.text, "bicycle", "mountain")

-- Combined: filter + rank
SELECT TOP 10 *
FROM c
WHERE FullTextContains(c.text, "red")
  AND FullTextContainsAny(c.text, "bicycle", "skateboard")
```

### Hybrid Search (RRF)

<!-- Source: mslearn-docs/content/build-ai-applications/gen-ai-hybrid-search.md -->

| Function | Used in |
|----------|---------|
| `RRF(s1, s2, ...)` | `ORDER BY RANK` |

**Reciprocal Rank Fusion** combines rankings from multiple search methods (vector, full-text) into a unified ranking. Accepts an optional weights array as the last argument.

```sql
-- Combine vector + full-text search
SELECT TOP 10 *
FROM c
ORDER BY RANK RRF(VectorDistance(c.vector, [1,2,3]), FullTextScore(c.text, "search", "terms"))

-- Weighted: vector search weighted 2x vs full-text
SELECT TOP 10 *
FROM c
ORDER BY RANK RRF(VectorDistance(c.vector, [1,2,3]), FullTextScore(c.text, "search"), [2, 1])
```

---

## Index Efficiency at a Glance

How you write a query determines which index strategy the engine uses — and that directly affects RU cost.

<!-- Source: mslearn-docs/content/manage-your-account/containers-and-items/index-overview.md -->

| Strategy | RU Cost |
|----------|---------|
| **Index seek** | Constant per filter |
| **Precise scan** | Slightly above seek |
| **Expanded scan** | Moderate |
| **Full index scan** | Linear with index size |
| **Full scan** (no index) | Scales with container |

Which constructs map to which strategy:

- **Index seek:** `=`, `IN`
- **Precise scan:** `>`, `<`, `>=`, `<=`, `STARTSWITH`
- **Expanded scan:** case-insensitive `STARTSWITH`, case-insensitive `StringEquals`
- **Full index scan:** `CONTAINS`, `ENDSWITH`, `RegexMatch`, `LIKE`
- **Full scan:** `UPPER`, `LOWER` in `WHERE`

When both `STARTSWITH` and `CONTAINS` would work for your query, use `STARTSWITH` — it's significantly cheaper.

---

## Per-Request Query Limits

<!-- Source: mslearn-docs/content/manage-your-account/enterprise-readiness/concepts-limits.md -->

| Limit | Value |
|-------|-------|
| Execution time per page | 5 seconds |
| Response size per page | 4 MB |
| Max request size | 2 MB |

If a query can't finish within 5 seconds or 4 MB per page, the service returns a continuation token. Your application must page through results using the SDK's `FeedIterator` (Chapter 7 covers this in depth).
