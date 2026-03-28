# Chapter 7: Querying with the NoSQL API

If data modeling is the foundation of a well-designed Cosmos DB application, querying is how you put that foundation to work. The NoSQL API ships with a powerful, SQL-like query language that will feel immediately familiar if you've ever written a `SELECT` statement—but with important adaptations for working with schema-free JSON documents. In this chapter, you'll learn everything from basic filtering to full-text search, geospatial queries, and the tools Cosmos DB provides to help you understand and optimize query performance.

## The Cosmos DB SQL Query Language

Cosmos DB's query language borrows heavily from SQL syntax but is purpose-built for hierarchical JSON data. There's no fixed schema—properties can be missing or have different types across documents—and the language is case-sensitive. A typical query uses the familiar `SELECT`, `FROM`, and `WHERE` clauses:

```sql
SELECT p.name, p.price
FROM products p
WHERE p.price > 20
ORDER BY p.price ASC
```

The `FROM` clause identifies the container (aliased here as `p`), not a table. Since every item in a container is a JSON document, you project individual properties with dot notation. `SELECT *` returns the entire document, while explicit projections give you control over the shape of results.

## Basic SELECT, FROM, and WHERE

The `SELECT` clause controls what appears in results. You can project specific fields, rename them with aliases, or use `VALUE` to return a raw scalar or array instead of wrapping the result in an object:

```sql
SELECT p.name, p.description AS copy
FROM products p
WHERE p.price > 500
```

The `WHERE` clause supports the comparison operators you'd expect (`=`, `!=`, `<`, `>`, `<=`, `>=`), logical operators (`AND`, `OR`, `NOT`), arithmetic, and string matching. You can access nested properties using dot notation or bracket notation:

```sql
SELECT p.manufacturer.name, p["metadata"].sku
FROM products p
WHERE p.category = "Electronics"
```

## Keywords: DISTINCT, TOP, BETWEEN, LIKE, and IN

Several SQL keywords help you narrow results without complex logic:

- **`DISTINCT`** removes duplicates from the result set.
- **`TOP N`** limits the number of results returned.
- **`BETWEEN`** filters on a range (inclusive).
- **`IN`** checks membership in a list of values.
- **`LIKE`** enables wildcard pattern matching with `%` (any characters) and `_` (single character).

```sql
-- Unique categories
SELECT DISTINCT VALUE p.category
FROM products p

-- Five most expensive products
SELECT TOP 5 *
FROM products p
ORDER BY p.price DESC

-- Price range with category filter
SELECT *
FROM products p
WHERE p.category IN ("Accessories", "Clothing")
  AND p.price BETWEEN 10 AND 50

-- Pattern matching on name
SELECT *
FROM products p
WHERE p.name LIKE "%bike%"
```

## Parameterized Queries

Never concatenate user input directly into query strings. Parameterized queries prevent SQL injection, and they also enable the query engine to reuse execution plans across calls with different parameter values—saving both RU cost and latency.

Parameters use the `@` prefix. Here's how it looks in the Cosmos DB query language and with the .NET SDK:

```sql
SELECT * FROM products p WHERE p.price > @minPrice AND p.category = @category
```

```csharp
var query = new QueryDefinition(
        "SELECT * FROM products p WHERE p.price > @minPrice AND p.category = @category")
    .WithParameter("@minPrice", 25.00)
    .WithParameter("@category", "Electronics");

using FeedIterator<Product> feed = container.GetItemQueryIterator<Product>(query);

while (feed.HasMoreResults)
{
    FeedResponse<Product> page = await feed.ReadNextAsync();
    foreach (Product item in page)
    {
        Console.WriteLine($"{item.name}: {item.price}");
    }
}
```

The `QueryDefinition` class is fluent—chain as many `.WithParameter()` calls as your query requires.

## Querying Nested Objects and Arrays

Because Cosmos DB stores denormalized JSON, your documents will frequently contain nested objects and arrays. Dot notation handles nested objects directly:

```sql
SELECT
    p.name,
    p.manufacturer.name AS brand,
    p.manufacturer.country
FROM products p
```

For arrays, you can reference a specific index:

```sql
SELECT p.name, p.sizes[0].description AS defaultSize
FROM products p
```

But hard-coding indexes is fragile. To work with all elements in an array, use a `JOIN` (covered in detail below) or a subquery with `EXISTS`:

```sql
SELECT VALUE p.name
FROM products p
WHERE EXISTS (
    SELECT VALUE s FROM s IN p.sizes WHERE s.description LIKE "%Large"
)
```

## Aggregate Functions

Cosmos DB supports the standard aggregate functions: `COUNT`, `SUM`, `MIN`, `MAX`, and `AVG`. They can operate over the entire result set or within groups:

```sql
SELECT
    COUNT(1) AS totalProducts,
    MIN(p.price) AS cheapest,
    MAX(p.price) AS mostExpensive,
    AVG(p.price) AS averagePrice
FROM products p
```

You can also use aggregate scalar subqueries to compute per-document aggregations—for example, counting the elements of a nested array:

```sql
SELECT
    p.name,
    (SELECT VALUE COUNT(1) FROM s IN p.sizes) AS sizeCount
FROM products p
```

## GROUP BY

The `GROUP BY` clause works similarly to relational SQL. The key restriction is that every property in the `SELECT` clause must be either an aggregate function or appear in the `GROUP BY` list:

```sql
SELECT p.category, COUNT(1) AS productCount
FROM products p
GROUP BY p.category
```

You can group by multiple properties and combine grouping with `ORDER BY` (a composite index on the grouped and sorted properties will improve performance significantly):

```sql
SELECT p.category, p.manufacturer.country, AVG(p.price) AS avgPrice
FROM products p
GROUP BY p.category, p.manufacturer.country
```

## Pagination Strategies

Most real-world queries return more results than you want to send to a client in a single response. Cosmos DB offers two pagination mechanisms, and choosing the right one matters for both cost and correctness.

### Continuation Token–Based Pagination (Recommended)

This is the idiomatic approach. When a query has more results than fit in a single response (controlled by `MaxItemCount` in request options), the SDK returns a **continuation token** with the response. You pass that token back on the next call to resume exactly where you left off.

```csharp
string? continuationToken = null;
var options = new QueryRequestOptions { MaxItemCount = 25 };

do
{
    using FeedIterator<Product> feed = container.GetItemQueryIterator<Product>(
        queryText: "SELECT * FROM products p WHERE p.category = 'Clothing'",
        continuationToken: continuationToken,
        requestOptions: options);

    FeedResponse<Product> page = await feed.ReadNextAsync();

    foreach (Product item in page)
    {
        Console.WriteLine(item.name);
    }

    // Store this to resume later (e.g., return to client as a page token)
    continuationToken = page.ContinuationToken;

} while (continuationToken != null);
```

Continuation tokens are opaque strings. You can store them in your API response so clients can request "the next page" without the server needing to re-execute the query from scratch. This approach is efficient because each page only consumes the RUs needed for that page's results.

### OFFSET / LIMIT

`OFFSET LIMIT` skips a specified number of results and then takes a specified count:

```sql
SELECT * FROM products p
ORDER BY p.name
OFFSET 20 LIMIT 10
```

This is useful for small datasets or ad hoc exploration in the Data Explorer. However, **avoid it for production pagination of large result sets**. The query engine must still read and discard the skipped items, so page 100 costs far more RUs than page 1. Continuation tokens don't have this problem—each page costs roughly the same regardless of how deep you are into the result set.

## Joins and Self-Joins

In a relational database, `JOIN` combines rows across tables. In Cosmos DB, there are no cross-document or cross-container joins. Instead, `JOIN` performs a **self-join within a single document**—it creates a cross-product between the document and one of its embedded arrays.

Consider a product document with a `sizes` array:

```sql
SELECT p.name, s.key, s.description
FROM products p
JOIN s IN p.sizes
```

This "flattens" the array: if a product has four sizes, the query produces four rows—one per size—each paired with the product's name.

You can chain multiple joins:

```sql
SELECT p.name, t.name AS tag, s.description AS size
FROM products p
JOIN t IN p.tags
JOIN s IN p.sizes
```

Be careful here—multiple joins produce a **cross-product**. If tags has 3 items and sizes has 4, you get 12 rows per document. For large arrays this can be expensive.

### Optimizing Joins with Subqueries

You can dramatically reduce the cross-product by filtering arrays inside subqueries before joining them:

```sql
SELECT VALUE COUNT(1)
FROM products p
JOIN (SELECT VALUE t FROM t IN p.tags WHERE t.key IN ("fabric", "material"))
JOIN (SELECT VALUE s FROM s IN p.sizes WHERE s["order"] >= 3)
JOIN (SELECT VALUE c FROM c IN p.colors WHERE c LIKE "%gray%")
```

If each original array has 10 items, a naive triple-join produces 1,000 tuples per document. With filtered subqueries, you might reduce that to 25—a 40× improvement.

## Subqueries and Correlated Subqueries

Beyond join optimization, subqueries are a versatile tool in the Cosmos DB query language. There are two kinds:

**Scalar subqueries** return a single value and can appear in `SELECT` or `WHERE`:

```sql
SELECT
    p.name,
    (SELECT VALUE COUNT(1) FROM c IN p.colors) AS colorCount,
    (SELECT VALUE COUNT(1) FROM s IN p.sizes) AS sizeCount
FROM products p
```

**Multi-value subqueries** return a set of items and are used in the `FROM` clause (as shown in the join optimization example above).

**Correlated subqueries** reference values from the outer query. This example conditionally projects a field only when a condition is met:

```sql
SELECT
    p.id,
    (SELECT p.name WHERE CONTAINS(p.name, "Shoes")).name
FROM products p
```

Documents whose name doesn't contain "Shoes" will have a `null` for that field, while matching documents include the name.

You can also use the `EXISTS` keyword with a correlated subquery for powerful array filtering:

```sql
SELECT VALUE p.name
FROM products p
WHERE EXISTS (
    SELECT VALUE c FROM c IN p.colors WHERE c LIKE "%blue%"
)
```

## Built-In System Functions

Cosmos DB provides a rich library of built-in functions you can use in any clause. Here's a curated overview by category.

### String Functions

```sql
-- Case-insensitive search
SELECT * FROM p WHERE CONTAINS(p.name, "bike", true)

-- Prefix matching (uses index efficiently)
SELECT * FROM p WHERE STARTSWITH(p.sku, "BK-")

-- Case conversion
SELECT UPPER(p.name) AS upperName, LOWER(p.category) AS lowerCat FROM products p
```

Other useful string functions include `SUBSTRING`, `LENGTH`, `REPLACE`, `TRIM`, `CONCAT`, `INDEX_OF`, `REVERSE`, and `REGEXMATCH`.

> **Performance tip:** `STARTSWITH` uses a precise index scan, while `CONTAINS` requires a full index scan. Prefer `STARTSWITH` when possible.

### Math Functions

Standard math operations are available: `ABS`, `CEILING`, `FLOOR`, `ROUND`, `SQRT`, `POWER`, `LOG`, `LOG10`, `EXP`, `SIN`, `COS`, `TAN`, `ASIN`, `ACOS`, `ATAN`, `RAND`, and `TRUNC`.

```sql
SELECT p.name, ROUND(p.price * 0.9, 2) AS discountedPrice
FROM products p
```

### Array Functions

- `ARRAY_CONTAINS(array, value)` — checks if a value exists in an array.
- `ARRAY_LENGTH(array)` — returns the array's length.
- `ARRAY_SLICE(array, start, length)` — extracts a sub-array.
- `ARRAY_CONCAT(array1, array2)` — merges two arrays.
- `SetIntersect`, `SetUnion` — set operations on arrays.

```sql
SELECT * FROM p WHERE ARRAY_CONTAINS(p.tags, "outdoor")
```

### Date and Time Functions

Cosmos DB offers comprehensive date functions: `GetCurrentDateTime`, `GetCurrentTimestamp`, `GetCurrentTicks`, `DateTimeAdd`, `DateTimeDiff`, `DateTimePart`, `DateTimeToTimestamp`, `TimestampToDateTime`, and more.

```sql
SELECT p.name, DateTimeDiff("day", p.createdDate, GetCurrentDateTime()) AS ageInDays
FROM products p
```

### Spatial Functions

These functions enable geospatial queries over GeoJSON data (covered in more detail later in this chapter):

- `ST_DISTANCE(geom1, geom2)` — distance between two geometries in meters.
- `ST_WITHIN(geom1, geom2)` — whether one geometry is within another.
- `ST_INTERSECTS(geom1, geom2)` — whether two geometries intersect.
- `ST_ISVALID(geom)` — validates GeoJSON format.
- `ST_ISVALIDDETAILED(geom)` — detailed validation result.

### Full-Text Search Functions

Cosmos DB's full-text search feature introduces three filtering functions and a scoring function:

- **`FullTextContains(path, term)`** — returns true if the property contains the specified term.
- **`FullTextContainsAll(path, term1, term2, ...)`** — returns true only if *all* terms are present.
- **`FullTextContainsAny(path, term1, term2, ...)`** — returns true if *any* term is present.

```sql
-- Must contain the keyword/term
SELECT TOP 10 * FROM c WHERE FullTextContains(c.description, "wireless charging")

-- Must contain ALL specified terms
SELECT * FROM c WHERE FullTextContainsAll(c.description, "waterproof", "lightweight")

-- Must contain at least one term
SELECT * FROM c WHERE FullTextContainsAny(c.description, "bluetooth", "wifi", "NFC")
```

These functions require enrollment in the Full Text Search feature and benefit from a full-text index on the target property.

### Full-Text Scoring with FullTextScore

`FullTextScore` calculates a BM25 relevance score for ranking results. It can only be used inside an `ORDER BY RANK` clause—you cannot project it directly:

```sql
SELECT TOP 10 c.title, c.description
FROM c
ORDER BY RANK FullTextScore(c.description, "cosmos", "database", "NoSQL")
```

Combine it with `FullTextContains` in the `WHERE` clause to filter first, then rank:

```sql
SELECT TOP 10 c.title
FROM c
WHERE FullTextContains(c.description, "cosmos")
ORDER BY RANK FullTextScore(c.description, "cosmos", "database")
```

### Hybrid Search with RRF

The `RRF` (Reciprocal Rank Fusion) function merges rankings from multiple scoring functions—typically combining vector similarity search with full-text BM25 scoring. This is particularly powerful for Retrieval-Augmented Generation (RAG) scenarios:

```sql
SELECT TOP 10 *
FROM c
ORDER BY RANK RRF(
    VectorDistance(c.embedding, [0.12, 0.45, ...]),
    FullTextScore(c.text, "cosmos", "database")
)
```

You can optionally weight the component scores. To make vector search twice as important as text search:

```sql
SELECT TOP 10 *
FROM c
ORDER BY RANK RRF(
    VectorDistance(c.embedding, [0.12, 0.45, ...]),
    FullTextScore(c.text, "cosmos", "database"),
    [2, 1]
)
```

RRF can also fuse two `FullTextScore` functions or two `VectorDistance` functions—it's not limited to one of each.

## Computed Properties

Computed properties are server-side derived values based on existing item properties. They aren't physically stored in the document, but they can be indexed and queried as if they were persisted fields. This lets you define complex expressions once and reuse them across queries.

Each computed property has a name and a query that evaluates per item. Define them on the container (up to 20 per container):

```json
{
  "computedProperties": [
    {
      "name": "cp_lowerName",
      "query": "SELECT VALUE LOWER(c.name) FROM c"
    },
    {
      "name": "cp_20PercentDiscount",
      "query": "SELECT VALUE (c.price * 0.2) FROM c"
    }
  ]
}
```

Then use them in queries exactly like regular properties:

```sql
SELECT c.cp_lowerName, c.price - c.cp_20PercentDiscount AS salePrice
FROM c
WHERE c.cp_20PercentDiscount < 50
```

**Important:** Computed properties aren't included in `SELECT *`—you must project them explicitly. They also aren't covered by wildcard index paths; add them to your indexing policy explicitly:

```json
{
  "includedPaths": [
    { "path": "/*" },
    { "path": "/cp_lowerName/?" },
    { "path": "/cp_20PercentDiscount/?" }
  ]
}
```

By indexing computed properties, you avoid full container scans for system functions like `LOWER()` or `SUBSTRING()`. The result is faster queries at lower RU cost, with a small increase in write RUs for maintaining the index.

## Understanding Cross-Partition Queries

When a query includes a filter on the partition key, Cosmos DB routes it to the single relevant partition—a **single-partition query**. This is the most efficient pattern.

When the partition key is absent from the `WHERE` clause, the query becomes a **cross-partition query** (also called a "fan-out query"). The engine sends the query to every physical partition, gathers results, and merges them. Cross-partition queries:

- Consume more RUs (the total is the sum of per-partition charges).
- Have higher latency (bounded by the slowest partition).
- Are sometimes unavoidable (e.g., aggregations across all data), but should be minimized in hot paths.

**Best practice:** Always include the partition key in your most frequent queries. If you find yourself frequently running cross-partition queries, revisit your partition key choice or consider using a materialised/denormalized view.

## LINQ to SQL

If you're using the .NET SDK, you can write queries using Language Integrated Query (LINQ) instead of raw SQL strings. The SDK's LINQ provider translates your expressions into the underlying Cosmos DB query language.

```csharp
IOrderedQueryable<Product> queryable = container.GetItemLinqQueryable<Product>();

var matches = queryable
    .Where(p => p.category == "Clothing" && p.price < 100)
    .OrderByDescending(p => p.price)
    .Select(p => new { p.name, p.price });

using FeedIterator<dynamic> feed = matches.ToFeedIterator();

while (feed.HasMoreResults)
{
    foreach (var item in await feed.ReadNextAsync())
    {
        Console.WriteLine($"{item.name}: {item.price}");
    }
}
```

The LINQ provider supports `Select`, `Where`, `SelectMany` (which translates to `JOIN`), `OrderBy`, `OrderByDescending`, `Skip`, `Take`, `Count`, `Sum`, `Min`, `Max`, `Average`, and math/string/array functions from .NET. `SelectMany` is particularly useful—it gives you self-join behavior in a strongly-typed way:

```csharp
// Equivalent to: SELECT VALUE c FROM f JOIN c IN f.children
var children = queryable.SelectMany(f => f.children);
```

> **Tip:** Call `.ToString()` on your `IQueryable` to see the generated SQL. This is invaluable for debugging and optimizing LINQ-based queries.

## Indexing and Querying Geospatial Data

Cosmos DB natively supports GeoJSON geometry types: `Point`, `LineString`, `Polygon`, and `MultiPolygon`. To query geospatial data, you need to add a spatial index to your indexing policy:

```json
{
  "includedPaths": [
    {
      "path": "/location/?",
      "indexes": [
        { "kind": "Spatial", "dataType": "Point" }
      ]
    }
  ]
}
```

With a spatial index in place, you can run distance and containment queries:

```sql
-- Find offices within 2 km of a point
SELECT o.name, ST_DISTANCE(o.location, {
    "type": "Point",
    "coordinates": [-122.117, 47.669]
}) / 1000 AS distanceKm
FROM offices o
WHERE o.category = "business-office"
  AND ST_DISTANCE(o.location, {
    "type": "Point",
    "coordinates": [-122.117, 47.669]
  }) < 2000

-- Check if a point falls within a polygon
SELECT * FROM regions r
WHERE ST_WITHIN(
    { "type": "Point", "coordinates": [-122.128, 47.639] },
    r.boundary
)
```

In the .NET SDK, you can use the `Microsoft.Azure.Cosmos.Spatial` namespace to work with typed geometry objects:

```csharp
using Microsoft.Azure.Cosmos.Spatial;

var query = new QueryDefinition(
    @"SELECT o.name, ST_DISTANCE(o.location, @compareLocation) / 1000 AS distKm
      FROM offices o
      WHERE o.category = @category
        AND ST_DISTANCE(o.location, @compareLocation) < @maxDistance")
    .WithParameter("@maxDistance", 2000)
    .WithParameter("@category", "business-office")
    .WithParameter("@compareLocation", new Point(-122.117, 47.669));
```

## Query Advisor

Query Advisor is a built-in feature in the Azure portal's Data Explorer that analyzes your queries and provides actionable optimization recommendations. When you run a query, Query Advisor examines the execution plan and suggests improvements such as:

- Adding missing indexes (single, composite, or spatial) to eliminate full scans.
- Restructuring `JOIN` expressions with subqueries to reduce cross-products.
- Adding partition key filters to avoid costly fan-out queries.
- Replacing functions like `CONTAINS` with `STARTSWITH` for better index utilization.

Look for the **Query Advisor** tab in the Data Explorer results pane after executing a query. It's particularly useful when you're seeing unexpectedly high RU charges or slow response times.

## Query Metrics and Diagnosing Expensive Queries

Every query response from Cosmos DB includes diagnostic information you can use to understand performance. The key metrics to monitor are:

- **Request Charge (RUs):** The total cost of the query. This is the single most important number for cost optimization.
- **Retrieved Document Count vs. Output Document Count:** If retrieved documents far exceed output documents, your query is reading many items but discarding most of them—a sign of a missing index or a broad filter.
- **Index Utilization:** Whether the query was fully served by the index or required a scan.
- **Execution Time:** Broken down into document load time, index lookup time, and query engine time.

In the .NET SDK, you can access diagnostics from the `FeedResponse`:

```csharp
FeedResponse<Product> page = await feed.ReadNextAsync();

Console.WriteLine($"Request charge: {page.RequestCharge} RUs");
Console.WriteLine($"Diagnostics: {page.Diagnostics}");
```

For deeper analysis, enable **index metrics** with `PopulateIndexMetrics = true` in your request options. This tells you exactly which index paths were used and which weren't—helping you fine-tune your indexing policy.

**General guidelines for reducing query cost:**

1. **Add the partition key** to your `WHERE` clause whenever possible.
2. **Index the properties** you filter, sort, and group on.
3. **Use parameterized queries** to benefit from plan caching.
4. **Prefer `STARTSWITH` over `CONTAINS`** when the query pattern allows it.
5. **Avoid `OFFSET/LIMIT`** for deep pagination—use continuation tokens instead.
6. **Filter inside subqueries** before joining arrays to minimize cross-products.
7. **Use Query Advisor** to catch missing indexes and anti-patterns.

## What's Next

Now that you have a solid grasp of the Cosmos DB query language—from basic filters to full-text search, geospatial queries, and performance diagnostics—it's time to look at the other side of the equation. In **Chapter 8**, we'll dive into **indexing strategies**: how Cosmos DB's automatic indexing works under the hood, how to customize indexing policies for your workload, and how to design composite and spatial indexes that make your queries fast and cost-effective.
