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
| `AND` | Logical and | `c.price > 10 AND c.price < 100` |
| `OR` | Logical or | `c.status = "active" OR c.status = "pending"` |
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
| `\|\|` | String concatenation | `c.firstName \|\| " " \|\| c.lastName` |
| `??` | Null coalescing | `c.nickname ?? c.firstName` |
| `? :` | Ternary / conditional | `c.quantity > 0 ? "In Stock" : "Out of Stock"` |

---

## Aggregate Functions

| Function | Description | Example |
|----------|-------------|---------|
| `COUNT(expr)` | Count of items (use `COUNT(1)` for all) | `SELECT COUNT(1) FROM c` |
| `SUM(expr)` | Sum of numeric values | `SELECT SUM(c.price) FROM c` |
| `AVG(expr)` | Average of numeric values | `SELECT AVG(c.price) FROM c` |
| `MIN(expr)` | Minimum value | `SELECT MIN(c.price) FROM c` |
| `MAX(expr)` | Maximum value | `SELECT MAX(c.price) FROM c` |

All aggregate functions ignore items where the expression evaluates to `undefined`. Combine with `GROUP BY` for per-group aggregation.

---

## System Functions by Category

### String Functions

| Function | Description | Example |
|----------|-------------|---------|
| `CONCAT(str1, str2, ...)` | Concatenates two or more strings | `CONCAT(c.first, " ", c.last)` |
| `CONTAINS(str, substr [, ignoreCase])` | Returns true if first string contains second | `CONTAINS(c.name, "board")` |
| `ENDSWITH(str, suffix [, ignoreCase])` | Returns true if string ends with suffix | `ENDSWITH(c.email, ".com")` |
| `STARTSWITH(str, prefix [, ignoreCase])` | Returns true if string starts with prefix | `STARTSWITH(c.sku, "PROD")` |
| `INDEX_OF(str, substr)` | Returns starting position of substring, or -1 | `INDEX_OF(c.name, "surf")` |
| `LEFT(str, length)` | Returns leftmost characters | `LEFT(c.sku, 4)` |
| `RIGHT(str, length)` | Returns rightmost characters | `RIGHT(c.phone, 4)` |
| `LENGTH(str)` | Returns string length | `LENGTH(c.name)` |
| `LOWER(str)` | Converts to lowercase | `LOWER(c.email)` |
| `UPPER(str)` | Converts to uppercase | `UPPER(c.category)` |
| `LTRIM(str)` | Removes leading whitespace | `LTRIM(c.name)` |
| `RTRIM(str)` | Removes trailing whitespace | `RTRIM(c.name)` |
| `TRIM(str)` | Removes leading and trailing whitespace | `TRIM(c.name)` |
| `REPLACE(str, find, replace)` | Replaces occurrences of a substring | `REPLACE(c.url, "http://", "https://")` |
| `REPLICATE(str, count)` | Repeats a string N times | `REPLICATE("*", 5)` |
| `REVERSE(str)` | Reverses character order | `REVERSE(c.code)` |
| `SUBSTRING(str, start, length)` | Extracts a substring (0-based index) | `SUBSTRING(c.sku, 0, 4)` |
| `ToString(expr)` | Converts a value to string | `ToString(c.price)` |
| `StringEquals(str1, str2 [, ignoreCase])` | Case-sensitive (or insensitive) string comparison | `StringEquals(c.code, "abc", true)` |
| `RegexMatch(str, pattern [, modifiers])` | Regular expression match | `RegexMatch(c.email, "^[a-z]+@")` |

> **Index efficiency:** `STARTSWITH` and `StringEquals` use precise or expanded index scans. `CONTAINS`, `ENDSWITH`, `RegexMatch`, and `LIKE` use full index scans. `UPPER` and `LOWER` trigger full container scans — avoid them in WHERE clauses on large containers.
<!-- Source: mslearn-docs/content/manage-your-account/containers-and-items/index-overview.md -->

### Mathematical Functions

| Function | Description | Example |
|----------|-------------|---------|
| `ABS(num)` | Absolute value | `ABS(c.balance)` |
| `CEILING(num)` | Smallest integer ≥ value | `CEILING(c.rating)` |
| `FLOOR(num)` | Largest integer ≤ value | `FLOOR(c.rating)` |
| `ROUND(num)` | Rounds to nearest integer | `ROUND(c.price)` |
| `SIGN(num)` | Returns -1, 0, or 1 | `SIGN(c.balance)` |
| `POWER(base, exp)` | Raises base to a power | `POWER(c.value, 2)` |
| `SQRT(num)` | Square root | `SQRT(c.variance)` |
| `LOG(num)` | Natural logarithm | `LOG(c.value)` |
| `LOG10(num)` | Base-10 logarithm | `LOG10(c.value)` |
| `EXP(num)` | e raised to the specified power | `EXP(c.rate)` |
| `PI()` | Returns π (3.14159...) | `PI()` |
| `SIN(num)` | Sine (radians) | `SIN(c.angle)` |
| `COS(num)` | Cosine (radians) | `COS(c.angle)` |
| `TAN(num)` | Tangent (radians) | `TAN(c.angle)` |
| `ASIN(num)` | Arcsine | `ASIN(c.value)` |
| `ACOS(num)` | Arccosine | `ACOS(c.value)` |
| `ATAN(num)` | Arctangent | `ATAN(c.value)` |
| `ATN2(y, x)` | Arctangent of y/x | `ATN2(c.y, c.x)` |
| `RAND()` | Returns a random float between 0 and 1 | `RAND()` |
| `NumberBin(num, binSize)` | Rounds to the nearest multiple of bin size | `NumberBin(c.distance / 1000, 0.01)` |

### Array Functions

| Function | Description | Example |
|----------|-------------|---------|
| `ARRAY_CONCAT(arr1, arr2, ...)` | Concatenates two or more arrays | `ARRAY_CONCAT(c.tags, c.labels)` |
| `ARRAY_CONTAINS(arr, value [, partial])` | Returns true if array contains value; set `partial` to true for partial object matching | `ARRAY_CONTAINS(c.tags, "sale")` |
| `ARRAY_LENGTH(arr)` | Returns number of elements | `ARRAY_LENGTH(c.ratings)` |
| `ARRAY_SLICE(arr, start [, length])` | Returns a subset of an array (0-based) | `ARRAY_SLICE(c.tags, 0, 3)` |
| `SetIntersect(arr1, arr2)` | Returns elements common to both arrays | `SetIntersect(c.tags, ["sale", "new"])` |
| `SetUnion(arr1, arr2)` | Returns all unique elements from both arrays | `SetUnion(c.tags, c.labels)` |

### Type-Checking Functions

| Function | Description | Example |
|----------|-------------|---------|
| `IS_ARRAY(expr)` | Returns true if the value is an array | `IS_ARRAY(c.tags)` |
| `IS_BOOL(expr)` | Returns true if the value is a Boolean | `IS_BOOL(c.isActive)` |
| `IS_NULL(expr)` | Returns true if the value is null | `IS_NULL(c.deletedAt)` |
| `IS_NUMBER(expr)` | Returns true if the value is a number | `IS_NUMBER(c.price)` |
| `IS_OBJECT(expr)` | Returns true if the value is a JSON object | `IS_OBJECT(c.address)` |
| `IS_STRING(expr)` | Returns true if the value is a string | `IS_STRING(c.name)` |
| `IS_DEFINED(expr)` | Returns true if the property has been assigned a value (including null) | `IS_DEFINED(c.email)` |
| `IS_PRIMITIVE(expr)` | Returns true if the value is a string, number, Boolean, or null | `IS_PRIMITIVE(c.value)` |

### Date and Time Functions

| Function | Description | Example |
|----------|-------------|---------|
| `GetCurrentDateTime()` | Returns current UTC date/time as ISO 8601 string | `GetCurrentDateTime()` |
| `GetCurrentTimestamp()` | Returns current UTC as milliseconds since Unix epoch | `GetCurrentTimestamp()` |
| `GetCurrentTicks()` | Returns current UTC as 100-nanosecond ticks since 00:00:00 Jan 1, 0001 | `GetCurrentTicks()` |
| `DateTimeAdd(part, num, dateTime)` | Adds a value to a date/time string | `DateTimeAdd("dd", 7, c.createdAt)` |
| `DateTimeDiff(part, start, end)` | Returns difference between two date/times | `DateTimeDiff("hh", c.start, c.end)` |
| `DateTimePart(part, dateTime)` | Extracts a component from a date/time | `DateTimePart("yyyy", c.createdAt)` |
| `DateTimeToTicks(dateTime)` | Converts ISO 8601 string to ticks | `DateTimeToTicks(c.createdAt)` |
| `TicksToDateTime(ticks)` | Converts ticks to ISO 8601 string | `TicksToDateTime(c.tickValue)` |
| `DateTimeToTimestamp(dateTime)` | Converts ISO 8601 string to Unix timestamp (ms) | `DateTimeToTimestamp(c.createdAt)` |
| `TimestampToDateTime(timestamp)` | Converts Unix timestamp (ms) to ISO 8601 string | `TimestampToDateTime(c.ts)` |
| `DateTimeBin(dateTime, part, binSize [, origin])` | Rounds a date/time to a bin boundary | `DateTimeBin(c.createdAt, "hh", 1)` |

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

| Function | Description | Example |
|----------|-------------|---------|
| `ST_DISTANCE(geom1, geom2)` | Returns distance in meters between two GeoJSON points | `ST_DISTANCE(c.location, {"type":"Point","coordinates":[-122.12,47.66]})` |
| `ST_WITHIN(geom1, geom2)` | Returns true if geom1 is within geom2 | `ST_WITHIN(c.location, @polygon)` |
| `ST_INTERSECTS(geom1, geom2)` | Returns true if two geometries intersect | `ST_INTERSECTS(c.area, @boundary)` |
| `ST_ISVALID(geom)` | Returns true if the GeoJSON is valid | `ST_ISVALID(c.location)` |
| `ST_ISVALIDDETAILED(geom)` | Returns JSON with validity info and reason | `ST_ISVALIDDETAILED(c.location)` |

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
| `VectorDistance(vector1, vector2)` | Returns the distance/similarity score between two vectors using the distance function defined in the container's vector policy |

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

| Function | Description | Used In |
|----------|-------------|---------|
| `FullTextContains(property, text)` | Returns true if the property contains the given text | `WHERE` |
| `FullTextContainsAll(property, term1, term2, ...)` | Returns true if the property contains *all* of the given terms | `WHERE` |
| `FullTextContainsAny(property, term1, term2, ...)` | Returns true if the property contains *any* of the given terms | `WHERE` |
| `FullTextScore(property, term1, term2, ...)` | Returns a BM25 relevance score | `ORDER BY RANK` only |

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

| Function | Description |
|----------|-------------|
| `RRF(score1, score2, ... [, weights])` | Reciprocal Rank Fusion — combines rankings from multiple search methods into a single unified ranking. Used in `ORDER BY RANK`. |

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

| Index Strategy | Query Constructs | RU Behavior |
|----------------|-----------------|-------------|
| **Index seek** | `=`, `IN` | Constant per filter |
| **Precise index scan** | `>`, `<`, `>=`, `<=`, `STARTSWITH` | Slightly above seek |
| **Expanded index scan** | `STARTSWITH` (case-insensitive), `StringEquals` (case-insensitive) | Moderate |
| **Full index scan** | `CONTAINS`, `ENDSWITH`, `RegexMatch`, `LIKE` | Linear with index cardinality |
| **Full scan** (no index) | `UPPER`, `LOWER` | Scales with container size |

When both `STARTSWITH` and `CONTAINS` would work for your query, use `STARTSWITH` — it's significantly cheaper.

---

## Per-Request Query Limits

<!-- Source: mslearn-docs/content/manage-your-account/enterprise-readiness/concepts-limits.md -->

| Limit | Value |
|-------|-------|
| Max execution time per query page | 5 seconds |
| Max response size per page | 4 MB |
| Max request size | 2 MB |

If a query can't finish within 5 seconds or 4 MB per page, the service returns a continuation token. Your application must page through results using the SDK's `FeedIterator` (Chapter 7 covers this in depth).
