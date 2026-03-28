# Chapter 8: Indexing Policies

Every query you run in Cosmos DB hits an index. Whether you realize it or not, the indexing policy attached to your container is the single biggest lever you have for controlling query performance, write latency, and storage costs. The good news: the defaults are sensible. The better news: when you understand how to tune them, you can squeeze dramatically more out of every RU.

## How Automatic Indexing Works Under the Hood

Cosmos DB is schema-agnostic. You don't declare columns or field types before writing data — you just write JSON. Yet every property is queryable by default. How?

When you write an item to a container, Cosmos DB projects the JSON document into a tree representation. A pseudo root node sits at the top, with every nested property becoming a child node. Leaf nodes hold the actual scalar values. Arrays get intermediate nodes labeled by their positional index (0, 1, 2, and so on).

Take this document:

```json
{
  "locations": [
    { "country": "Germany", "city": "Berlin" },
    { "country": "France", "city": "Paris" }
  ],
  "headquarters": { "country": "Belgium", "employees": 250 }
}
```

Cosmos DB converts this into property paths like `/locations/0/country`, `/locations/0/city`, `/locations/1/country`, `/headquarters/employees`, and so on. Each path and its corresponding value are then fed into an inverted index — a structure that maps values back to the documents that contain them.

This happens automatically on every write. There's no background job, no eventual catch-up. By default, every property of every item is indexed the moment it's persisted — and that's what makes ad hoc queries work out of the box.

## The Default Indexing Policy

When you create a new container, Cosmos DB assigns this indexing policy:

```json
{
  "indexingMode": "consistent",
  "automatic": true,
  "includedPaths": [
    {
      "path": "/*"
    }
  ],
  "excludedPaths": [
    {
      "path": "/\"_etag\"/?"
    }
  ]
}
```

This policy says: index everything (`/*`), do it synchronously on every write (`consistent`), and skip only the `_etag` system property. Range indexes are enforced for every string and number value. The system properties `id` and `_ts` are always indexed when the mode is consistent — they don't appear in the policy because their indexing can't be disabled.

For many workloads, this default is perfectly fine. But "index everything" has a cost: every write must update every index entry for every property in the document. If your documents have 50 properties and you only ever query on three of them, you're paying write RUs for 47 index entries you'll never use.

## Customizing Your Indexing Policy

### Including and Excluding Specific Paths

The most impactful optimization you can make is to stop indexing paths you never query. The path syntax extends the tree representation with a few conventions:

- `/?` at the end targets a scalar value (string or number)
- `/[]` addresses all elements of an array (instead of `/0`, `/1`, etc.)
- `/*` is a wildcard matching everything below a node

Two strategies exist:

1. **Include root, exclude specific paths** (recommended). Start with `/*` included and carve out the properties you don't need. This way, new properties added to your data model are automatically indexed.
2. **Exclude root, include specific paths**. Start with `/*` excluded and explicitly add only the paths you query on. This is more restrictive but gives you full control.

Here's a policy that indexes everything except a large `metadata` object and a `rawPayload` field:

```json
{
  "indexingMode": "consistent",
  "automatic": true,
  "includedPaths": [
    { "path": "/*" }
  ],
  "excludedPaths": [
    { "path": "/metadata/*" },
    { "path": "/rawPayload/?" },
    { "path": "/\"_etag\"/?" }
  ]
}
```

If your included and excluded paths conflict, the more precise path wins. For example, if you exclude `/food/ingredients/*` but include `/food/ingredients/nutrition/*`, the nutrition sub-tree is still indexed.

One important note: the partition key path is **not** automatically indexed. If your partition key isn't `/id`, and you exclude the root path, you should explicitly include your partition key path. Otherwise, queries filtering on the partition key hierarchy will force full scans.

### Range Indexes

Range indexes are the workhorses. They're based on an ordered tree structure and power:

- Equality queries (`WHERE c.status = "active"`)
- `IN` expressions
- Range comparisons (`>`, `<`, `>=`, `<=`, `!=`)
- `ORDER BY` on a single property
- `IS_DEFINED` checks
- String functions like `CONTAINS` and `STRINGEQUALS`
- `ARRAY_CONTAINS` for matching array elements
- `JOIN` expressions over nested arrays

The default policy creates range indexes for every string and number, so you get all of this out of the box. You only need to think about range indexes explicitly when you're selectively including paths.

### Spatial Indexes

Spatial indexes power geospatial queries using `ST_DISTANCE`, `ST_WITHIN`, and `ST_INTERSECTS`. Unlike range indexes, Cosmos DB does **not** create spatial indexes by default — you must explicitly add them.

You define spatial indexes by specifying the path and the GeoJSON types you want to index:

```json
{
  "indexingMode": "consistent",
  "automatic": true,
  "includedPaths": [
    { "path": "/*" }
  ],
  "excludedPaths": [
    { "path": "/\"_etag\"/?" }
  ],
  "spatialIndexes": [
    {
      "path": "/location/*",
      "types": ["Point", "Polygon", "MultiPolygon", "LineString"]
    }
  ]
}
```

Only include the types your data actually uses. If your documents store points (latitude/longitude pairs) and you only run `ST_DISTANCE` queries, indexing `Point` alone is sufficient. The data must be stored as valid GeoJSON for the spatial index to work.

### Composite Indexes

Composite indexes are where indexing policy tuning gets serious. You need a composite index whenever you:

- `ORDER BY` two or more properties
- Filter on multiple properties where at least one is an equality filter
- Combine filters with `ORDER BY` on different properties

No composite indexes exist by default — you must define them explicitly.

```json
{
  "compositeIndexes": [
    [
      { "path": "/category", "order": "ascending" },
      { "path": "/price", "order": "ascending" }
    ],
    [
      { "path": "/category", "order": "ascending" },
      { "path": "/createdAt", "order": "descending" }
    ]
  ]
}
```

#### Rules for Composite Index Property Order

The rules for composite indexes are strict, and getting the order wrong means the index simply won't be used:

1. **Path sequence must match the `ORDER BY` sequence.** A composite index on `(name ASC, age ASC)` supports `ORDER BY c.name ASC, c.age ASC` but **not** `ORDER BY c.age ASC, c.name ASC`.

2. **Sort direction must match — or be completely reversed.** `(name ASC, age ASC)` supports both `ORDER BY name ASC, age ASC` and `ORDER BY name DESC, age DESC`, but **not** `ORDER BY name ASC, age DESC`.

3. **All `ORDER BY` properties must be present.** A composite index on `(name ASC, age ASC, _ts ASC)` does **not** support `ORDER BY name ASC, age ASC` — you need an exact match on the number of paths.

Here's a reference table:

| Composite Index | Query | Supported? |
|---|---|---|
| `(name ASC, age ASC)` | `ORDER BY c.name ASC, c.age ASC` | ✅ Yes |
| `(name ASC, age ASC)` | `ORDER BY c.name DESC, c.age DESC` | ✅ Yes |
| `(name ASC, age ASC)` | `ORDER BY c.age ASC, c.name ASC` | ❌ No |
| `(name ASC, age ASC)` | `ORDER BY c.name ASC, c.age DESC` | ❌ No |

#### Composite Indexes with Range Filters

For filter-only queries (no `ORDER BY`), the rules change slightly:

- **Equality filters first, range filter last.** In a composite index for `WHERE c.name = "John" AND c.age > 18`, put `name` before `age`. The property with the range filter (`>`, `<`, `>=`, `<=`, `!=`) must be defined last in the composite index.

- **Each composite index optimizes at most one range filter.** If your query has two range filters — say `c.age > 18 AND c._ts > 1612212188` — you need two separate composite indexes: `(name, age)` and `(name, _ts)`. A single composite index on `(name, age, _ts)` won't optimize both range predicates.

- **Sort order doesn't matter for filter-only queries.** When a composite index is used purely for filtering (no `ORDER BY`), the ascending/descending designation has no effect on results.

#### Composite Indexes with Aggregate Functions

Composite indexes also optimize aggregate queries. A query like:

```sql
SELECT COUNT(1) FROM c WHERE c.name = "John" AND c.age > 18
```

benefits from a composite index on `(name ASC, age ASC)` just like a non-aggregate query would. The same rules apply — equality properties first, range property last.

### Tuple Indexes

Tuple indexes solve a specific problem: efficiently filtering on multiple fields *within the same array element*. Consider documents with a `tags` array where each element has a `category` and a `type`:

```json
{
  "id": "product-1",
  "tags": [
    { "category": "electronics", "type": "sale" },
    { "category": "accessories", "type": "new" }
  ]
}
```

If you want to find items where a single tag has `category = "electronics" AND type = "sale"`, a standard range index can't correlate the two fields within the same array element. A tuple index can.

Tuple paths are defined in `includedPaths` using a special syntax:

```
<path prefix>/[]/{<tuple 1>, <tuple 2>, ...}/?
```

For example:

```json
{
  "includedPaths": [
    { "path": "/*" },
    { "path": "/tags/[]/{category, type}/?" }
  ],
  "excludedPaths": [
    { "path": "/\"_etag\"/?" }
  ]
}
```

A few rules to keep in mind:

- The `[]` array wildcard must appear immediately before the `{}` tuple specifier
- Tuple field names don't start with `/` and don't end with `?` or `*`
- The entire path must end with `/?`
- You can't use `/*` wildcards in tuple paths
- Only one level of array wildcard is allowed in the path prefix — `/city/[]/events/[]/{name, category}/?` is invalid because it has two array wildcards

## Disabling Indexing for Write-Heavy Bulk Imports

If you're doing a large bulk data load and won't be querying during the import, you can temporarily disable indexing entirely by setting the indexing mode to `none`:

```json
{
  "indexingMode": "none",
  "automatic": true
}
```

This eliminates the write RU cost of maintaining indexes, which can significantly accelerate bulk imports. When the import is complete, switch the mode back to `consistent`. Cosmos DB will rebuild the index in the background — an online operation with no downtime. You can track the progress of the index transformation using the SDK's `IndexTransformationProgress` property.

This is a common pattern: set mode to `none`, bulk import millions of documents at reduced RU cost, then flip to `consistent` and let the index catch up. Your container remains available for reads throughout, though queries will scan rather than seek until the index rebuild completes.

## Full-Text Search Indexing

Cosmos DB for NoSQL supports native full-text search with BM25 scoring — no external search service required. Setting it up involves two pieces: a **full-text policy** on the container and a **full-text index** in the indexing policy.

The container-level full-text policy declares which paths contain searchable text and what language they're in:

```json
{
  "defaultLanguage": "en-US",
  "fullTextPaths": [
    { "path": "/title", "language": "en-US" },
    { "path": "/description", "language": "en-US" }
  ]
}
```

Then, in your indexing policy, you add the corresponding full-text indexes:

```json
{
  "indexingMode": "consistent",
  "automatic": true,
  "includedPaths": [
    { "path": "/*" }
  ],
  "excludedPaths": [
    { "path": "/\"_etag\"/?" }
  ],
  "fullTextIndexes": [
    { "path": "/title" },
    { "path": "/description" }
  ]
}
```

With both policies configured, you can use the full-text query functions:

- **`FullTextContains(c.title, "red bicycle")`** — keyword/term match in a `WHERE` clause
- **`FullTextContainsAll(c.description, "red", "bicycle")`** — all keywords must appear (but not necessarily together)
- **`FullTextContainsAny(c.description, "bicycle", "skateboard")`** — at least one keyword must appear
- **`FullTextScore(c.description, "mountain", "bicycle")`** — BM25 relevance scoring, used exclusively in `ORDER BY RANK`

A relevance-ranked search looks like this:

```sql
SELECT TOP 10 *
FROM c
WHERE FullTextContains(c.title, "bicycle")
ORDER BY RANK FullTextScore(c.description, "bicycle", "mountain")
```

Multi-language support is in preview for German, Spanish, French, Italian, and Portuguese, with language-specific tokenization and stemming. Wildcard characters are not supported in full-text policy paths or indexes.

## Vector Indexing Policies

Cosmos DB's vector search lets you store embeddings alongside your data and query them with the `VectorDistance` system function. To make vector search performant, you need two things: a **container vector policy** and a **vector index** in your indexing policy.

The container vector policy declares the paths that contain vectors, their data type, dimensionality, and distance function:

```json
{
  "vectorEmbeddings": [
    {
      "path": "/contentVector",
      "dataType": "float32",
      "distanceFunction": "cosine",
      "dimensions": 1536
    }
  ]
}
```

Supported data types include `float32`, `float16` (50% storage savings with minor accuracy trade-off), `int8`, and `uint8`. Distance functions are `cosine`, `dotproduct`, and `euclidean`.

Then you configure the vector index. Cosmos DB offers three types:

| Type | Description | Max Dimensions |
|---|---|---|
| `flat` | Brute-force exact search. 100% recall, but limited scale. | 505 |
| `quantizedFlat` | Compressed vectors, still brute-force. Good for < ~50,000 vectors per physical partition. | 4,096 |
| `diskANN` | Approximate nearest neighbors using Microsoft Research's DiskANN algorithms. Best for large-scale search. | 4,096 |

A typical vector indexing policy:

```json
{
  "indexingMode": "consistent",
  "automatic": true,
  "includedPaths": [
    { "path": "/*" }
  ],
  "excludedPaths": [
    { "path": "/\"_etag\"/?" },
    { "path": "/contentVector/*" }
  ],
  "vectorIndexes": [
    {
      "path": "/contentVector",
      "type": "diskANN"
    }
  ]
}
```

Note that the vector path is excluded from the regular included paths — you don't want range indexes on embedding arrays. The `diskANN` index handles them separately.

Both `quantizedFlat` and `diskANN` require at least 1,000 vectors to be inserted before the quantization kicks in. Below that threshold, the engine falls back to a full scan. DiskANN indexes accept optional tuning parameters:

- **`quantizationByteSize`**: Controls the compression level (1–512 bytes). Larger values improve accuracy but cost more RUs.
- **`indexingSearchListSize`**: Controls how many vectors are searched during index construction (10–500). Higher values build a more accurate index but slow down ingestion.

### Sharded DiskANN for Multi-Tenant Vector Search

In multi-tenant scenarios where your container is partitioned by tenant, each physical partition gets its own DiskANN index. Vector search automatically runs within partition scope when you include the partition key in your query filter, giving you tenant-isolated search with the full performance of DiskANN. For containers using hierarchical partition keys, contact the Cosmos DB team to optimize the partitioning scheme for vector search.

## Lazy vs. Consistent Indexing Mode

Cosmos DB supports two indexing modes:

- **Consistent** (default and recommended): The index is updated synchronously on every write. Your reads always reflect the latest data. This is what you should use for any workload that queries data.
- **None**: Indexing is completely disabled. Use this only for pure key-value lookup patterns (point reads by `id` and partition key) or temporarily during bulk imports.

There's technically a third mode — **lazy** — that updates the index at a lower priority when the engine is idle. However, lazy indexing can produce inconsistent or incomplete query results and is effectively deprecated. New containers cannot select lazy indexing. If you see it mentioned in older documentation, ignore it — use `consistent` for any container you plan to query.

## Global Secondary Indexes (Preview)

Global secondary indexes (GSIs) tackle one of the most common Cosmos DB pain points: expensive cross-partition queries. A GSI is a read-only container that's automatically kept in sync with your source container via change feed, but with a **different partition key**.

Consider an e-commerce container partitioned by `customerId`. Queries like "find all orders for customer X" are cheap single-partition queries. But "find all orders for product Y" requires a cross-partition fan-out. A GSI partitioned by `productId` converts that into a single-partition query.

Key characteristics of GSIs:

- **Automatic syncing**: Changes propagate from the source container via change feed. No client-side logic needed.
- **Eventually consistent**: Regardless of your account's consistency level, GSIs are always eventually consistent with the source.
- **Performance isolation**: GSIs have their own throughput (autoscale required) and storage. Queries against the GSI don't consume RUs from your source container.
- **Custom data model**: The GSI definition query projects which properties to include. Projected properties are flattened to the top level.
- **Full query capabilities**: Once created, you can run the full NoSQL query syntax against the GSI, including vector search, full-text search, and hybrid queries.

A GSI definition specifies a source container, a projection query, and a new partition key. The definition query must be a simple `SELECT ... FROM c` — no `WHERE`, `JOIN`, `GROUP BY`, or functions allowed. Once created, the definition can't be changed.

GSIs are currently in preview and not recommended for production workloads. But they represent a significant architectural improvement — essentially giving you materialized views with automatic maintenance.

## Measuring Index Storage and RU Impact

Tuning your indexing policy without measuring is guessing. Cosmos DB gives you several tools to close the feedback loop.

### Index Metrics

You can enable index metrics on any query by setting the `PopulateIndexMetrics` request option to `true`. The response includes details about which indexes the query actually used, and — critically — which indexes it *could have used* if they existed.

The metrics report two key sections:

- **Utilized indexes**: The single and composite indexes the query engine actually leveraged.
- **Potential indexes**: Indexes the engine recommends adding. These are suggested included paths and composite indexes that would improve the query.

Use this when troubleshooting a query that consumes more RUs than expected. The potential indexes section is essentially Cosmos DB telling you exactly what composite index to add.

### Index Storage

In the Azure portal, the **Metrics** blade shows your container's data size and index size separately. If your index size is approaching or exceeding your data size, it's a signal to review your indexing policy. Excluding paths you don't query can dramatically reduce index storage — and the write RUs needed to maintain those entries.

### Index Transformation

Whenever you modify an indexing policy — adding a composite index, excluding a path, changing the indexing mode — Cosmos DB performs an online index transformation. This is a background operation that doesn't cause downtime. Your container remains fully available for reads and writes throughout. However, during the transformation, queries may temporarily use existing range indexes instead of the new composite index until the build completes.

You can monitor transformation progress through the SDK. In .NET, for example, the `IndexTransformationProgress` property on the response headers tells you the percentage complete. Don't deploy an indexing policy change and immediately benchmark — wait for the transformation to finish.

## What's Next

You now understand how Cosmos DB's indexing engine works and how to shape it to your workload. But every index and every query has a cost measured in Request Units. In **Chapter 9**, we'll dive deep into **Request Units** — breaking down RU costs by operation type, finding the exact RU charge for any operation, budgeting RUs for your application, and learning systematic strategies to reduce RU consumption across reads, writes, and queries.
