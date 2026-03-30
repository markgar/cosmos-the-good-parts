# Chapter 8: Querying with the NoSQL API

Cosmos DB gives you a query language that looks like SQL but behaves like nothing you've used in a relational database. You write `SELECT`, `FROM`, `WHERE` — familiar syntax, familiar feel — but under the hood, the engine is navigating partitioned JSON documents, not joining normalized tables. If you try to think in relational terms, you'll write queries that work but cost ten times more than they should. If you learn to think in Cosmos DB's terms, you'll write queries that are fast, cheap, and elegant.

Chapter 7 showed you how to execute queries through the SDK — `FeedIterator`, parameterized inputs, paging through results. This chapter is about the query language itself: what you can express, how the engine evaluates it, and where the cost traps hide.

## Introduction to Cosmos DB SQL (NoSQL Query Language)

The query language for Azure Cosmos DB for NoSQL is a SQL-like language rooted in JavaScript's type system. Microsoft calls it "SQL (Structured Query Language)" in the docs, but don't let the name fool you — it operates on schema-free JSON items within a single container. There are no cross-container joins, no foreign keys, no relational algebra.

<!-- Source: tutorial-query.md -->

What it *does* give you is a surprisingly expressive way to project, filter, transform, aggregate, and navigate deeply nested JSON. You can flatten arrays, reshape output, call built-in system functions, compute geospatial distances, and score text relevance — all within a single query.

Every query targets a single container. If you need data from two containers, that's two queries and application-side assembly. Design your data model (Chapter 4) and partition key (Chapter 5) so your hot-path queries can be answered from a single container and, ideally, a single partition.

## Basic SELECT, FROM, WHERE Syntax

Let's start with sample data. Here's a product catalog item in a container partitioned on `/category`:

```json
{
  "id": "prod-1001",
  "category": "gear-surf-surfboards",
  "name": "Yamba Surfboard",
  "description": "High-performance shortboard for experienced surfers.",
  "price": 850.00,
  "quantity": 12,
  "tags": ["shortboard", "performance", "fiberglass"],
  "supplier": {
    "name": "Pacific Wave Co.",
    "region": "AU"
  },
  "ratings": [
    { "user": "alex", "score": 5, "comment": "Best board I've owned." },
    { "user": "jordan", "score": 4, "comment": "Great board, pricey." }
  ]
}
```

### The Simplest Query

```sql
SELECT * FROM c
```

This returns every item in the container. The `c` is an alias — it can be anything (`products`, `p`, `x`). Unlike relational SQL, `FROM` doesn't name a table; it names the container (or more precisely, an alias for the items in the container). You'll see `FROM c` in nearly every Cosmos DB query.

### Projection

Select only the fields you need. This reduces both response size and RU cost:

```sql
SELECT c.name, c.price FROM c
```

Result:

```json
[
  { "name": "Yamba Surfboard", "price": 850.00 }
]
```

You can also reshape the output with aliases:

```sql
SELECT c.name AS productName, c.price AS unitPrice FROM c
```

The **`VALUE`** keyword strips the wrapping object and returns raw values:

```sql
SELECT VALUE c.name FROM c
```

Result:

```json
["Yamba Surfboard"]
```

This is handy when you want a flat list of values rather than an array of objects.

### Filtering with WHERE

```sql
SELECT c.name, c.price
FROM c
WHERE c.category = "gear-surf-surfboards" AND c.price > 500
```

The `WHERE` clause supports the comparison operators you'd expect: `=`, `!=`, `<`, `>`, `<=`, `>=`. Logical operators `AND`, `OR`, and `NOT` work as expected. String comparisons are case-sensitive.

> **Tip:** When your `WHERE` clause includes the partition key (`c.category` in this example), the query is routed to a single physical partition. That's an **in-partition query** — the cheapest kind. Leave the partition key out, and Cosmos DB fans the query to every physical partition. We'll dig into the cost implications later in this chapter.

<!-- Source: how-to-query-container.md -->

## Keywords: DISTINCT, TOP, BETWEEN, LIKE, IN

### DISTINCT

Removes duplicates from the result set:

```sql
SELECT DISTINCT c.category FROM c
```

`DISTINCT` works across all data types, including objects and arrays. Be aware that it requires server-side processing and can increase RU cost compared to the same query without it.

### TOP

Limits the result to the first N items:

```sql
SELECT TOP 10 c.name, c.price
FROM c
WHERE c.category = "gear-surf-surfboards"
ORDER BY c.price ASC
```

`TOP` is evaluated *after* `ORDER BY`, so you get the actual cheapest 10 products, not a random 10.

### BETWEEN

A range filter (inclusive on both ends):

```sql
SELECT c.name, c.price
FROM c
WHERE c.price BETWEEN 200 AND 800
```

This is equivalent to `c.price >= 200 AND c.price <= 800`. Use whichever reads better.

### LIKE

Pattern matching with `%` (any sequence of characters) and `_` (single character):

```sql
SELECT c.name
FROM c
WHERE c.name LIKE "Yamba%"
```

`LIKE` uses the index when the pattern starts with a literal prefix (like `"Yamba%"`). A leading wildcard (`"%Surfboard"`) forces a full scan — avoid it on large containers.

### IN

Tests membership in a list:

```sql
SELECT c.name, c.category
FROM c
WHERE c.category IN ("gear-surf-surfboards", "gear-surf-wetsuits")
```

When the `IN` list contains partition key values, Cosmos DB intelligently routes the query to only the relevant physical partitions — not all of them. This is a useful middle ground between a single-partition query and a full fan-out.

<!-- Source: how-to-query-container.md -->

## Parameterized Queries

Never concatenate user input into query strings. Use **parameterized queries** instead. They prevent injection, and they enable query plan reuse on the server — the engine doesn't have to recompile the plan for every variation of a parameter value.

```sql
SELECT c.name, c.price
FROM c
WHERE c.category = @category AND c.price > @minPrice
```

Chapter 7 showed the SDK syntax for passing parameters. Here's a quick reminder in C#:

```csharp
var query = new QueryDefinition(
    "SELECT c.name, c.price FROM c WHERE c.category = @category AND c.price > @minPrice"
)
.WithParameter("@category", "gear-surf-surfboards")
.WithParameter("@minPrice", 500);
```

<!-- Source: how-to-dotnet-query-items.md -->

The Java SDK caches query plans for parameterized single-partition queries, so after the first execution, subsequent calls skip the gateway call entirely. In the .NET SDK, Optimistic Direct Execution (ODE) can bypass client-side query plan generation altogether for qualifying single-partition queries. Both optimizations depend on parameterization — another reason to always use it.

<!-- Source: performance-tips-query-sdk.md -->

> **Gotcha:** Parameterized values can be used in `WHERE` clauses, but not in place of property names or aliases. You can't parameterize the `SELECT` list or `ORDER BY` columns.

## Querying Nested Objects and Arrays

This is where Cosmos DB's query language earns its keep. Your documents have nested objects and arrays — the query language lets you reach into them naturally.

### Nested Object Properties

Access nested properties with dot notation:

```sql
SELECT c.name, c.supplier.name AS supplierName, c.supplier.region
FROM c
WHERE c.supplier.region = "AU"
```

There's no depth limit on dot-path navigation (though deeply nested documents have other problems — Chapter 4 covered those).

### Array Elements by Index

You can reference array elements by position:

```sql
SELECT c.name, c.tags[0] AS firstTag
FROM c
```

But positional access is brittle — you need to know the array structure at write time. The real power comes from JOINs across arrays, which we'll cover shortly.

### Checking Array Contents

The `ARRAY_CONTAINS` function tests whether an array includes a value:

```sql
SELECT c.name
FROM c
WHERE ARRAY_CONTAINS(c.tags, "performance")
```

This is the single most common way to filter on array data.

## Aggregate Functions: COUNT, SUM, MIN, MAX, AVG

Cosmos DB supports the standard aggregate functions:

```sql
SELECT
    COUNT(1) AS totalProducts,
    MIN(c.price) AS cheapest,
    MAX(c.price) AS mostExpensive,
    AVG(c.price) AS averagePrice,
    SUM(c.quantity) AS totalInventory
FROM c
WHERE c.category = "gear-surf-surfboards"
```

Aggregates use the index when possible — an equality or range filter on an indexed property lets the engine compute the aggregate without scanning every document. But if your filter forces a scan (like wrapping the property in `UPPER()`), the aggregate has to load every matching document first.

<!-- Source: troubleshoot-query-performance.md -->

> **Tip:** For cross-partition aggregate queries, Cosmos DB computes the aggregate per partition and merges the results client-side. A `COUNT` across 20 physical partitions runs 20 sub-queries and sums the results. The RU cost scales linearly with partition count.

<!-- Source: query-metrics.md -->

## GROUP BY

The `GROUP BY` clause groups results by one or more properties and applies aggregates to each group:

```sql
SELECT
    c.category,
    COUNT(1) AS productCount,
    AVG(c.price) AS avgPrice
FROM c
GROUP BY c.category
```

Some rules to know:

- Every property in the `SELECT` must either be in the `GROUP BY` clause or wrapped in an aggregate function. No exceptions.
- `GROUP BY` supports scalar properties, nested properties (like `c.supplier.region`), and system functions.
- The RU cost increases with the cardinality of the grouped property — more distinct values means more work.

<!-- Source: troubleshoot-query-performance.md -->

You can group by multiple properties:

```sql
SELECT
    c.category,
    c.supplier.region,
    COUNT(1) AS count
FROM c
GROUP BY c.category, c.supplier.region
```

If you find yourself running the same `GROUP BY` aggregation frequently on a large container, consider building a materialized view via the change feed (Chapter 15) — it'll be cheaper than re-aggregating every time.

## Pagination Strategies

Queries in Cosmos DB return results in pages. Even if a query matches 10,000 items, you won't get them all in one response. Understanding pagination is essential for building responsive applications.

### Continuation Token-Based Pagination (Recommended)

The **continuation token** pattern is the native, recommended approach. Here's how it works:

1. You execute a query. The server returns a page of results plus an opaque **continuation token**.
2. To get the next page, you pass the continuation token back with the same query.
3. Repeat until the continuation token is `null` (no more results).

Chapter 7 covered the `FeedIterator` loop in detail. The key insight for pagination is that continuation tokens are *stateless on the server* — the server doesn't maintain any session between pages. The token encodes enough information for the engine to pick up where it left off.

This means you can store a continuation token in a cookie, URL parameter, or cache, and resume pagination hours later from a different client instance. That's what makes it the right choice for API pagination — return the token to your caller and let them send it back for the next page.

```csharp
// Resume from a previously stored token — see Ch 7 for the full FeedIterator loop
FeedIterator<Product> feed = container.GetItemQueryIterator<Product>(
    queryDefinition: query,
    continuationToken: savedToken,  // null on first call, stored token on subsequent calls
    requestOptions: new QueryRequestOptions { MaxItemCount = 25 }
);
```

<!-- Source: performance-tips-query-sdk.md, how-to-dotnet-query-items.md -->

> **Gotcha:** Continuation tokens are opaque and SDK-version-specific. Don't parse them, modify them, or assume they'll work across different SDK versions. The .NET SDK's Optimistic Direct Execution (ODE) can produce a different token format that older SDKs won't recognize.

### OFFSET/LIMIT

Cosmos DB also supports `OFFSET ... LIMIT` syntax:

```sql
SELECT c.name, c.price
FROM c
ORDER BY c.price ASC
OFFSET 20 LIMIT 10
```

This skips 20 results and returns the next 10. It looks familiar if you're coming from PostgreSQL or MySQL, but here's the problem: **the engine must still process all the items up to the offset**. `OFFSET 1000 LIMIT 10` processes 1,010 items and throws away the first 1,000. That's 1,010 items' worth of RU cost for 10 items of results.

For small offsets or one-off exploratory queries in the Data Explorer, `OFFSET/LIMIT` is fine. For production API pagination with potentially deep page numbers, use continuation tokens instead. The RU cost of continuation tokens doesn't grow with the page number — page 50 costs the same as page 1.

<!-- Source: performance-tips-query-sdk.md -->

| Strategy | Best For | RU Cost Pattern |
|----------|----------|-----------------|
| **Continuation tokens** | Production API pagination, large result sets | Constant per page |
| **OFFSET/LIMIT** | Data Explorer, small offsets, ad-hoc queries | Grows with offset |

## Joins and Self-Joins Across Arrays

Here's the concept that trips up every relational developer: **Cosmos DB's `JOIN` operates within a single document, not across documents.** It unfolds arrays inside an item, producing a cross-product of the parent item with each element of the array.

Think of it as a flattening operation. Given our product document with a `ratings` array:

```sql
SELECT
    c.name,
    r.user,
    r.score
FROM c
JOIN r IN c.ratings
WHERE c.category = "gear-surf-surfboards"
```

Result:

```json
[
  { "name": "Yamba Surfboard", "user": "alex", "score": 5 },
  { "name": "Yamba Surfboard", "user": "jordan", "score": 4 }
]
```

<!-- Source: tutorial-query.md -->

The `JOIN r IN c.ratings` iterates over each element in the `ratings` array and produces one output row per element. If a product has 5 ratings, the query produces 5 rows for that product.

### Multiple JOINs

You can join across multiple arrays within the same document:

```sql
SELECT
    c.name,
    t AS tag,
    r.user
FROM c
JOIN t IN c.tags
JOIN r IN c.ratings
```

This produces a cross-product: if a product has 3 tags and 2 ratings, you get 6 rows. Be careful with this — large arrays can cause combinatorial explosion, driving up both result size and RU cost.

### Filtering on Array Elements

Combine `JOIN` with `WHERE` to filter within the array:

```sql
SELECT c.name, r.comment
FROM c
JOIN r IN c.ratings
WHERE r.score >= 5
```

This returns only the 5-star reviews and their parent product names. Without `JOIN`, you'd have no way to express this filter on individual array elements.

> **Gotcha:** Remember, there's no cross-document `JOIN`. If you need data from two different items, that's two queries or a data model redesign (Chapter 4). The `JOIN` in Cosmos DB is purely for navigating arrays within a single item.

## Subqueries and Correlated Subqueries

Subqueries let you nest one query inside another, which is useful for computing intermediate values or filtering on derived data.

### Subquery as an Expression

Use a subquery in the `SELECT` clause to compute a value:

```sql
SELECT
    c.name,
    (SELECT VALUE COUNT(1) FROM r IN c.ratings) AS ratingCount
FROM c
```

This counts the ratings for each product without needing a `GROUP BY`.

### Subquery in WHERE

Filter items based on a condition applied to their nested arrays:

```sql
SELECT c.name, c.price
FROM c
WHERE EXISTS (
    SELECT VALUE r FROM r IN c.ratings WHERE r.score = 5
)
```

This returns products that have *at least one* 5-star rating. `EXISTS` returns true if the subquery produces any results.

### Correlated Subqueries for JOIN Optimization

A common performance pattern is to replace a `JOIN` with a correlated subquery. When you use `JOIN` with a filter, the engine produces the full cross-product first, then filters. A subquery can sometimes be more efficient because it filters within the array first:

```sql
SELECT c.name, highRatings
FROM c
JOIN (SELECT VALUE r FROM r IN c.ratings WHERE r.score >= 4) AS highRatings
```

<!-- Source: troubleshoot-query-performance.md -->

The geospatial query example in the docs uses exactly this pattern — computing `ST_DISTANCE` in a subquery to avoid recalculating it in both `SELECT` and `WHERE`:

```sql
SELECT
    o.name,
    NumberBin(distanceMeters / 1000, 0.01) AS distanceKilometers
FROM offices o
JOIN (SELECT VALUE ROUND(ST_DISTANCE(o.location, @compareLocation))) AS distanceMeters
WHERE o.category = @partitionKey AND distanceMeters > @maxDistance
```

<!-- Source: how-to-geospatial-index-query.md -->

## Built-in System Functions

Cosmos DB ships with a rich library of built-in functions. These are server-side — they run in the query engine, not your application. Let's survey the most important categories.

### String Functions

| Function | Description | Index Usage |
|----------|-------------|-------------|
| `CONTAINS(str, substr)` | True if `str` contains `substr` | ⚠️ Full index scan (cost scales with cardinality) |
| `STARTSWITH(str, prefix)` | True if `str` starts with `prefix` | ✅ Precise scan |
| `ENDSWITH(str, suffix)` | True if `str` ends with `suffix` | ⚠️ Full index scan (cost scales with cardinality) |
| `UPPER(str)`, `LOWER(str)` | Case conversion | ❌ Full scan — loads every document |
| `LEFT(str, n)`, `RIGHT(str, n)` | Substring from start/end | Partial |
| `LENGTH(str)` | Character count | ❌ |
| `CONCAT(str1, str2, ...)` | Concatenation | N/A (projection) |
| `REPLACE(str, find, replace)` | String replacement | N/A (projection) |
| `TRIM(str)` | Remove leading/trailing whitespace | N/A (projection) |
| `RegexMatch(str, pattern)` | Regular expression matching | ⚠️ Full index scan (cost scales with cardinality) |
| `StringEquals(str1, str2)` | Equality (supports case-insensitive) | ✅ Uses index |

<!-- Source: troubleshoot-query-performance.md -->

The critical detail: **`UPPER()` and `LOWER()` in a `WHERE` clause don't use the index.** If you filter with `WHERE UPPER(c.name) = "YAMBA SURFBOARD"`, the engine loads every document and applies the function. For a container with 60,000+ items, that can cost 4,000+ RUs for a single query. The fix: store a pre-lowered or pre-uppercased copy of the field, or use computed properties (covered later in this chapter).

<!-- Source: troubleshoot-query-performance.md, query-metrics-performance.md -->

### Math Functions

Standard math operations — `ABS`, `CEILING`, `FLOOR`, `ROUND`, `POWER`, `SQRT`, `LOG`, `LOG10`, `EXP`, `SIGN`, `TRUNC`, `PI`, `NumberBin`, and trigonometric functions (`SIN`, `COS`, `TAN`, `ASIN`, `ACOS`, `ATAN`). Most are used in `SELECT` projections; when used in `WHERE` they typically don't leverage the index.

### Array Functions

| Function | Description |
|----------|-------------|
| `ARRAY_CONTAINS(arr, val)` | True if `arr` contains `val` |
| `ARRAY_LENGTH(arr)` | Number of elements |
| `ARRAY_SLICE(arr, start, length)` | Returns a sub-array |
| `ARRAY_CONCAT(arr1, arr2)` | Merges arrays |
| `SetIntersect(arr1, arr2)` | Returns common elements |
| `SetUnion(arr1, arr2)` | Returns all unique elements |

`ARRAY_CONTAINS` is the workhorse. You can also use it to match objects within an array:

```sql
SELECT c.name
FROM c
WHERE ARRAY_CONTAINS(c.ratings, { "score": 5 }, true)
```

The third parameter (`true`) enables partial matching — the array element just needs to *contain* the specified properties, not match exactly.

### Date and Time Functions

Cosmos DB provides functions for working with dates as ISO 8601 strings or Unix timestamps:

| Function | Returns |
|----------|---------|
| `GetCurrentDateTime()` | Current UTC date/time as ISO string |
| `GetCurrentTimestamp()` | Current UTC as Unix milliseconds |
| `GetCurrentTicks()` | Current UTC as 100-nanosecond ticks |
| `DateTimeAdd(unit, amount, dateStr)` | Date arithmetic |
| `DateTimeDiff(unit, start, end)` | Difference between two dates |
| `DateTimePart(unit, dateStr)` | Extract year, month, day, etc. |
| `DateTimeToTimestamp(dateStr)` | Convert ISO string to Unix timestamp |
| `TimestampToDateTime(ts)` | Convert Unix timestamp to ISO string |
| `DateTimeBin(dateStr, unit, binSize)` | Bin datetime into intervals |

> **Gotcha:** `GetCurrentDateTime()` and its siblings are evaluated at query execution time, not from the index. Don't use them in `WHERE` clauses — calculate the target timestamp in your application code and pass it as a parameter instead. This lets the query use the index.

<!-- Source: troubleshoot-query-performance.md -->

### Spatial Functions

These power geospatial queries (covered in more detail later this chapter):

| Function | Description |
|----------|-------------|
| `ST_DISTANCE(geom1, geom2)` | Distance in meters between two geometries |
| `ST_WITHIN(geom1, geom2)` | True if `geom1` is inside `geom2` |
| `ST_INTERSECTS(geom1, geom2)` | True if geometries overlap |
| `ST_ISVALID(geom)` | True if GeoJSON is valid |
| `ST_ISVALIDDETAILED(geom)` | Validity info with reason |

<!-- Source: how-to-geospatial-index-query.md, index-overview.md -->

### Full-Text Search Functions

These are the newer text search capabilities. They require a **full-text policy** and **full-text index** to be configured on your container (Chapter 9 covers the indexing setup).

<!-- Source: gen-ai-full-text-search.md -->

**`FullTextContains(path, term)`** — Returns true if the text at `path` contains the given term. The term goes through the same tokenization and stemming as the indexed text, so searching for "bicycles" will match documents containing "bicycle."

```sql
SELECT TOP 10 *
FROM c
WHERE FullTextContains(c.description, "red bicycle")
```

**`FullTextContainsAll(path, term1, term2, ...)`** — All specified terms must appear in the text (logical AND):

```sql
SELECT TOP 10 *
FROM c
WHERE FullTextContainsAll(c.description, "red", "bicycle")
```

**`FullTextContainsAny(path, term1, term2, ...)`** — At least one term must appear (logical OR):

```sql
SELECT TOP 10 *
FROM c
WHERE FullTextContains(c.description, "red")
  AND FullTextContainsAny(c.description, "bicycle", "skateboard")
```

<!-- Source: gen-ai-full-text-search.md -->

### Full-Text Scoring: FullTextScore and ORDER BY RANK

**`FullTextScore(path, term1, term2, ...)`** uses the **BM25 (Best Matching 25)** algorithm to score documents by relevance. BM25 considers term frequency, inverse document frequency, and document length — the same algorithm behind most search engines. Documents that contain your search terms more frequently and more prominently rank higher.

`FullTextScore` can *only* be used in an `ORDER BY RANK` clause — you can't project it in `SELECT` or use it in `WHERE`:

```sql
SELECT TOP 10 *
FROM c
ORDER BY RANK FullTextScore(c.description, "bicycle", "mountain")
```

<!-- Source: gen-ai-full-text-search.md, gen-ai-full-text-search-faq.md -->

The most relevant documents appear first. Keep search terms as individual keywords rather than long phrases — splitting `"mountain bicycle with performance shocks"` into `"mountain", "bicycle", "performance", "shocks"` typically performs better.

<!-- Source: gen-ai-full-text-search-faq.md -->

### Hybrid Search: The RRF Function

**Hybrid search** combines vector similarity search with full-text keyword search to get better relevance than either approach alone. Cosmos DB implements this through the **`RRF` (Reciprocal Rank Fusion)** function, which merges rankings from multiple search methods into a single unified ranking.

<!-- Source: gen-ai-hybrid-search.md -->

```sql
SELECT TOP 10 *
FROM c
ORDER BY RANK RRF(
    VectorDistance(c.vector, [0.12, 0.45, 0.78]),
    FullTextScore(c.description, "mountain", "bicycle")
)
```

`RRF` takes two or more ranking functions and produces a single ordering. You can optionally provide weights to emphasize one method over another. For example, to weight vector search twice as much as text scoring:

```sql
SELECT TOP 10 *
FROM c
ORDER BY RANK RRF(
    VectorDistance(c.vector, [0.12, 0.45, 0.78]),
    FullTextScore(c.description, "mountain", "bicycle"),
    [2, 1]
)
```

<!-- Source: gen-ai-hybrid-search.md -->

Hybrid search requires both a vector index and a full-text index on your container. The setup details for vector indexing and the AI use cases that drive hybrid search are covered in Chapter 25; the indexing configuration is in Chapter 9.

## Computed Properties

Some queries can't use the index because they depend on a computed value — like `UPPER(c.name)` or `c.price * c.quantity`. Historically, the workaround was to pre-compute and store these values at write time. **Computed properties** offer a cleaner alternative: you define a server-side expression, and Cosmos DB materializes the result as a virtual property that can be indexed and queried.

<!-- Source: https://learn.microsoft.com/azure/cosmos-db/nosql/query/computed-properties (not in local mirror) -->

You define computed properties on the container. Each entry has a `name` (the virtual property path) and a `query` (a SQL scalar expression using `SELECT VALUE ... FROM c`). Here's a container definition that adds a `lowerName` computed property:

```json
{
  "computedProperties": [
    {
      "name": "lowerName",
      "query": "SELECT VALUE LOWER(c.name) FROM c"
    }
  ]
}
```

Once defined, add the computed property's path to your indexing policy so the engine can index it:

```json
{
  "indexingPolicy": {
    "includedPaths": [
      { "path": "/lowerName/?" }
    ]
  }
}
```

Now you can query the computed property directly — with full index support:

```sql
SELECT c.name, c.price
FROM c
WHERE c.lowerName = "yamba surfboard"
```

This query gets a precise index seek instead of the full-scan penalty you'd pay with `WHERE LOWER(c.name) = "yamba surfboard"`.

This feature is especially valuable when you have existing data and can't easily backfill a pre-computed field across millions of documents. The computed property handles it transparently at the engine level.

## Understanding Cross-Partition Queries

Chapter 5 warned you that cross-partition queries are more expensive. Now let's understand exactly *why* and *how much more*.

### How They Work

When you run a query that includes the partition key in the `WHERE` clause — like `WHERE c.category = "gear-surf-surfboards"` — Cosmos DB routes the query to the single physical partition that holds that data. One index lookup, one result set. This is an **in-partition query**.

When your query *doesn't* include the partition key, Cosmos DB has no way to know which partition holds the matching data. So it fans the query out to *every* physical partition, runs it against each partition's index, and merges the results on the client side.

<!-- Source: how-to-query-container.md, query-metrics.md -->

Here's the flow:

1. The SDK sends the query to the Cosmos DB gateway.
2. The gateway (or the SDK in Direct mode) identifies that no partition key filter exists.
3. The query is dispatched to every physical partition in parallel.
4. Each partition runs the query against its own independent index.
5. Results from all partitions are merged client-side (for `ORDER BY`, this means a merge-sort; for `COUNT`, a sum; etc.).

### The RU Math

Each physical partition charges a minimum of about **2.5 RUs** just to check its index — even if it returns zero matching items. If your container has 20 physical partitions, a cross-partition query costs at least 50 RUs as a baseline, even for a simple filter that matches items in only one partition.

<!-- Source: how-to-query-container.md -->

As your container grows, you get more physical partitions (one per ~10,000 RU/s or ~50 GB of data). A container provisioned at 100,000 RU/s has at least 10 physical partitions; one storing 500 GB might have 10 or more. The base cost of cross-partition queries scales linearly with partition count.

| Physical Partitions | Minimum Cross-Partition Query Cost |
|--------------------|------------------------------------|
| 3 | ~7.5 RUs |
| 10 | ~25 RUs |
| 50 | ~125 RUs |
| 100 | ~250 RUs |

And that's just the baseline. Add actual index lookups, document loads, and aggregate computation on each partition, and the cost climbs higher.

### When It Matters (and When It Doesn't)

Cross-partition queries are fine for small containers. If you have one or two physical partitions, the fan-out cost is negligible. The docs call this out explicitly: "if you have only one (or just a few) physical partitions, cross-partition queries don't consume significantly more RUs than in-partition queries."

<!-- Source: how-to-query-container.md -->

Start caring when your container exceeds 30,000 provisioned RU/s or 100 GB of storage. At that scale, the partition count makes fan-out expensive.

### How to Minimize Cross-Partition Queries

1. **Design your partition key around your most common query filter.** If 80% of your queries filter by `customerId`, make that your partition key.
2. **Use the `IN` operator with partition key values** when you know the target partitions. `WHERE c.category IN ("A", "B")` fans out to only those two partitions, not all of them.
3. **Consider hierarchical partition keys** (Chapter 5) for scenarios where you need both broad and narrow query scopes.
4. **Use global secondary indexes (preview)** for query patterns that can't align with your primary partition key. They create a synchronized copy with a different partition key, turning cross-partition queries into in-partition ones for specific patterns. Chapter 9 covers this.

### The SDK's Parallel Execution

The SDKs don't execute cross-partition queries serially — they parallelize across partitions. You can control the degree of parallelism via `MaxConcurrency` (C#) or `setMaxDegreeOfParallelism` (Java). Setting it to `-1` lets the SDK auto-tune.

<!-- Source: performance-tips-query-sdk.md, query-metrics.md -->

```csharp
var options = new QueryRequestOptions
{
    MaxConcurrency = -1,
    MaxBufferedItemCount = -1
};
```

Parallelism helps with *latency* (you get results faster), but it doesn't reduce *RU cost* (you're still querying every partition). Tuning parallelism is about the user experience, not the bill.

## Indexing and Querying Geospatial Data

Cosmos DB natively supports **GeoJSON** data types — Points, LineStrings, Polygons, and MultiPolygons — and provides built-in spatial functions for location-based queries.

### Storing Geospatial Data

Store locations as GeoJSON objects within your documents:

```json
{
  "id": "store-0042",
  "name": "Downtown Seattle",
  "category": "retail-store",
  "location": {
    "type": "Point",
    "coordinates": [-122.33207, 47.60621]
  }
}
```

Note: GeoJSON uses `[longitude, latitude]` order — the opposite of what Google Maps and most people expect. Get this wrong and your stores end up in the ocean.

<!-- Source: how-to-geospatial-index-query.md -->

### Distance Queries

Find all stores within 5 kilometers of a given point:

```sql
SELECT c.name, ST_DISTANCE(c.location, {
    "type": "Point",
    "coordinates": [-122.11758, 47.66901]
}) AS distanceMeters
FROM c
WHERE c.category = "retail-store"
  AND ST_DISTANCE(c.location, {
    "type": "Point",
    "coordinates": [-122.11758, 47.66901]
  }) < 5000
```

`ST_DISTANCE` returns distance in **meters**. The query above uses it in both `SELECT` (to return the distance) and `WHERE` (to filter). A subquery pattern can avoid the redundant computation — see the subquery section earlier in this chapter.

### Within Queries

Check if a point falls inside a polygon (e.g., a delivery zone):

```sql
SELECT c.name
FROM c
WHERE ST_WITHIN(c.location, {
    "type": "Polygon",
    "coordinates": [[
        [-122.13237, 47.64606],
        [-122.13222, 47.63376],
        [-122.11841, 47.64175],
        [-122.12061, 47.64589],
        [-122.13237, 47.64606]
    ]]
})
```

### Spatial Indexing

Spatial queries require a **spatial index** on the location property. The default indexing policy indexes all paths with range indexes, but spatial indexes need to be explicitly configured. Chapter 9 covers the indexing policy syntax in detail, but here's the key element:

```json
{
  "spatialIndexes": [
    {
      "path": "/location/*",
      "types": ["Point", "Polygon"]
    }
  ]
}
```

<!-- Source: how-to-geospatial-index-query.md, index-overview.md -->

Without a spatial index, `ST_DISTANCE` and `ST_WITHIN` still work — they just scan every document, which is expensive on large containers.

| Spatial Function | Description | Requires Spatial Index |
|-----------------|-------------|----------------------|
| `ST_DISTANCE` | Distance between geometries (meters) | Recommended |
| `ST_WITHIN` | Is geometry A inside geometry B? | Recommended |
| `ST_INTERSECTS` | Do geometries overlap? | Recommended |
| `ST_ISVALID` | Is the GeoJSON well-formed? | No |
| `ST_ISVALIDDETAILED` | Validity with error details | No |

## Query Advisor: Built-in Optimization Recommendations

When you run a query in the Azure portal's Data Explorer, check the **Query Advisor** panel alongside your results. It analyzes your query's execution and offers specific recommendations — missing composite indexes, suboptimal filter ordering, system functions that can't use the index.

Query Advisor uses the same **index metrics** available programmatically through the SDK. When you set `PopulateIndexMetrics = true` in your query options, the response includes detailed information about which indexes were used and which *could* have helped:

```csharp
var options = new QueryRequestOptions
{
    PopulateIndexMetrics = true
};

FeedIterator<Product> feed = container.GetItemQueryIterator<Product>(query, requestOptions: options);
FeedResponse<Product> response = await feed.ReadNextAsync();

Console.WriteLine(response.IndexMetrics);
```

<!-- Source: index-metrics.md -->

The output shows two categories:

- **Utilized indexes** — the indexes the query actually used. If a path appears here, removing it from your indexing policy would hurt this query.
- **Potential indexes** — indexes the query *could* use if you added them. These are recommendations, not guarantees.

```
Index Utilization Information
  Utilized Single Indexes
    Index Spec: /category/?
    Index Impact Score: High
  Potential Composite Indexes
    Index Spec: /category ASC, /price ASC
    Index Impact Score: High
```

<!-- Source: index-metrics.md -->

Each recommendation includes an **index impact score** — either *high* or *low*. Focus on the high-impact ones. Here's what the loop looks like in practice.

Say you're querying products by category and sorting by price:

```sql
SELECT c.name, c.price FROM c
WHERE c.category = "gear-surf-surfboards"
ORDER BY c.price ASC
```

You run it and see 42 RUs. The index metrics show:

```
Potential Composite Indexes
  Index Spec: /category ASC, /price ASC
  Index Impact Score: High
```

The engine is telling you it filtered on `/category` using the index but had to do a post-retrieval sort on `/price`. Add the recommended composite index to your indexing policy:

```json
{
  "compositeIndexes": [
    [
      { "path": "/category", "order": "ascending" },
      { "path": "/price", "order": "ascending" }
    ]
  ]
}
```

Rerun the same query — the RU cost drops to ~3 RUs. The composite index lets the engine satisfy both the filter and the sort directly from the index, eliminating the in-memory sort step.

Chapter 27 integrates Query Advisor into a broader performance tuning workflow. For now, just know it's there and build the habit of checking it whenever a query costs more RUs than you expect.

## Query Metrics and Diagnosing Expensive Queries

When a query is slow or expensive, you need to understand *where* the time and RUs are going. Cosmos DB provides detailed **query execution metrics** on every response.

### The Key Metrics

| Metric | What It Tells You |
|--------|-------------------|
| `TotalTime` | Total server-side execution time |
| `RetrievedDocumentCount` | Documents the engine loaded from storage |
| `OutputDocumentCount` | Documents in the final result set |
| `IndexLookupTime` | Time spent in the index |
| `DocumentLoadTime` | Time spent loading documents from storage |
| `RuntimeExecutionTime` | Time spent evaluating filters and functions |
| `IndexHitRatio` | Ratio of matched to loaded documents [0, 1] |

<!-- Source: query-metrics.md -->

The single most diagnostic comparison is **`RetrievedDocumentCount` vs. `OutputDocumentCount`**. If you retrieved 60,000 documents but output 7, your query scanned 60,000 documents to find 7 matches. That's a 0.01% index hit ratio — you're almost certainly missing an index or using a function that can't leverage one.

<!-- Source: troubleshoot-query-performance.md -->

### Accessing Metrics in the SDK

In the .NET SDK (v3.36.0+), query metrics are available as a strongly typed `ServerSideCumulativeMetrics` object:

```csharp
FeedResponse<Product> response = await feed.ReadNextAsync();
ServerSideCumulativeMetrics metrics = response.Diagnostics.GetQueryMetrics();

Console.WriteLine($"Total time: {metrics.CumulativeMetrics.TotalTime}");
Console.WriteLine($"Retrieved docs: {metrics.CumulativeMetrics.RetrievedDocumentCount}");
Console.WriteLine($"Output docs: {metrics.CumulativeMetrics.OutputDocumentCount}");
```

<!-- Source: query-metrics-performance.md -->

In Python, enable metrics by passing `populate_query_metrics=True` and reading the response headers:

```python
results = container.query_items(
    query=query_text,
    enable_cross_partition_query=True,
    populate_query_metrics=True
)

items = [item for item in results]
print(container.client_connection.last_response_headers['x-ms-documentdb-query-metrics'])
```

<!-- Source: query-metrics-performance-python.md -->

The metrics output in Python gives you `retrievedDocumentCount`, `outputDocumentCount`, `indexUtilizationRatio`, `totalExecutionTimeInMs`, and more — all the same data, just in a different format.

### The Diagnostic Workflow

When a query seems expensive:

1. **Check `RetrievedDocumentCount` vs. `OutputDocumentCount`.** A big gap means a scan. Fix the index or rewrite the filter.
2. **Check `IndexLookupTime` vs. `DocumentLoadTime`.** If `DocumentLoadTime` dominates, you're loading too many documents — again, an index issue.
3. **Check `RuntimeExecutionTime`.** High runtime with low document counts suggests expensive system functions or UDFs.
4. **Enable `PopulateIndexMetrics`** to see exactly which indexes were (and weren't) used, and what indexes would help.
5. **Look at the per-partition breakdown.** If one partition's metrics are dramatically worse than others, you may have a hot partition or skewed data.

<!-- Source: query-metrics.md, query-metrics-performance.md -->

Chapter 18 covers setting up monitoring dashboards to track these metrics across all your queries in production. The per-query diagnostics here are your debugging tool; the Chapter 18 dashboards are your operational visibility.

---

This chapter gave you the core Cosmos DB query toolkit — from basic `SELECT` to hybrid search, from continuation tokens to cross-partition mechanics. But the query engine can only work with the indexes you give it. In Chapter 9, we'll look at how to configure indexing policies that make these queries fast and cheap.
