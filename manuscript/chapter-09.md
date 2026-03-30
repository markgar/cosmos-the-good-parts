# Chapter 9: Indexing Policies

Most databases make you think about indexes upfront. You analyze your query patterns, create the right indexes, and hope you didn't miss one. Cosmos DB takes a radically different approach: it indexes *everything*, automatically, the moment you write a document. No schema declaration, no `CREATE INDEX` statement, no DBA intervention. You get fast queries on any property, right out of the box.

That's the magic. But magic has a cost — in this case, write RUs and storage. The default policy is the right starting point for most workloads, but production applications almost always benefit from tuning it. This chapter is the canonical reference for indexing policy configuration: how automatic indexing works under the hood, what the default policy gives you, and how to customize it for your specific access patterns.

Chapter 8 taught you the query language. This chapter teaches you how to make those queries fast and cheap.

## How Cosmos DB Automatic Indexing Works Under the Hood

Every time you write an item to a container, Cosmos DB converts it into a tree representation. Each property becomes a node, and scalar values (strings, numbers, booleans) sit at the leaf nodes. Arrays get intermediate nodes for each positional index. The engine then extracts **property paths** from this tree — paths like `/headquarters/country` or `/locations/0/city` — and feeds them into an **inverted index**.

<!-- Source: mslearn-docs/content/manage-your-account/containers-and-items/index-overview.md -->

The inverted index maps each path-value pair to the set of item IDs that contain it. Think of it like the index in the back of a textbook: instead of scanning every page to find where "partition key" appears, you look it up in the index and jump straight to the relevant pages.

Here's a simplified view of what the inverted index looks like for a container with two items:

| Path | Value | Item IDs |
|------|-------|----------|
| `/city` | "Seattle" | 1 |
| `/city` | "Portland" | 2 |
| `/status` | "active" | 1, 2 |
| `/age` | 28 | 1 |
| `/age` | 35 | 2 |

Two properties of this structure matter for understanding query behavior:

1. **Values are sorted in ascending order within each path.** This is why `ORDER BY` on a single property works directly from the index, and why range queries (`>`, `<`, `>=`, `<=`) can use a binary search instead of scanning every value.
2. **The engine can scan the distinct set of values for a path** to identify which index pages hold matching results. Functions like `CONTAINS` and `ENDSWITH` use this full index scan — it's more expensive than a seek, but still better than loading every document.

The result: when your query filters on indexed paths, the engine reads only the relevant index pages and loads only the matching items from the transactional store. When a path *isn't* indexed, the engine falls back to a **full scan** — loading every item in the container (or partition) to evaluate the filter. That's the difference between a 3 RU query and a 300 RU query.

## The Default Indexing Policy

When you create a new container, Cosmos DB applies this indexing policy automatically:

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

<!-- Source: mslearn-docs/content/develop-modern-applications/performance/indexing/index-policy.md -->

Let's decode what this gives you:

- **`indexingMode: "consistent"`** — The index is updated synchronously with every write. Your queries always see up-to-date results.
- **`automatic: true`** — Every item gets indexed on write, without needing to opt in per-document.
- **`includedPaths: ["/*"]`** — Every property at every level of nesting is indexed with a **range index**. That covers equality filters, range comparisons, `ORDER BY` on single properties, `IS_DEFINED` checks, and string functions like `CONTAINS` and `STARTSWITH`.
- **`excludedPaths: ["/_etag/?"]`** — The system `_etag` property is excluded by default since you rarely query on it.

A few things the default policy does *not* include:

- **No composite indexes.** Multi-property `ORDER BY` queries fail without them. You must add composite indexes explicitly.
- **No spatial indexes.** Geospatial functions like `ST_DISTANCE` and `ST_WITHIN` won't use an index unless you configure one.
- **No vector indexes.** Vector search works but falls back to a brute-force full scan without a vector index policy.
- **No full-text indexes.** Full-text search functions operate without an index but at higher RU cost.

Two system properties get special treatment regardless of what your policy says: **`id`** and **`_ts`** are always indexed when the indexing mode is `consistent`. You can't disable this, and they don't appear in the policy's path list — they're indexed by the engine itself.

<!-- Source: mslearn-docs/content/develop-modern-applications/performance/indexing/index-policy.md -->

> **Gotcha:** The partition key path is *not* automatically included in the index (unless it happens to be `/id`). If you use an exclude-root strategy (`"excludedPaths": ["/*"]`), you need to explicitly include your partition key path. Without it, queries that filter on the partition key hierarchy will force full scans, costing far more RUs than necessary.

For many workloads — especially in early development — the default policy is fine. You pay a bit more on writes to index everything, but your queries are fast on any path you throw at them. The point where you customize is when you know your access patterns well enough to make targeted trade-offs.

## Customizing Your Indexing Policy

### Including and Excluding Specific Paths

The core mechanism for customizing an indexing policy is controlling which property paths are indexed. You have two strategies:

**Opt-out (recommended):** Start with everything indexed (`/*`), then exclude paths you know you'll never query. This is the safest approach because new properties added to your data model are automatically indexed.

```json
{
    "indexingMode": "consistent",
    "includedPaths": [
        { "path": "/*" }
    ],
    "excludedPaths": [
        { "path": "/internalMetadata/*" },
        { "path": "/rawPayload/?" },
        { "path": "/\"_etag\"/?" }
    ]
}
```

**Opt-in:** Exclude everything (`/*` in excluded paths), then include only the paths your queries actually use. This minimizes write RUs and index storage, but it's fragile — add a new query pattern without updating the policy and you'll get full scans.

```json
{
    "indexingMode": "consistent",
    "includedPaths": [
        { "path": "/customerId/?" },
        { "path": "/orderDate/?" },
        { "path": "/status/?" }
    ],
    "excludedPaths": [
        { "path": "/*" }
    ]
}
```

<!-- Source: mslearn-docs/content/develop-modern-applications/performance/indexing/how-to-manage-indexing-policy.md -->

#### Path Syntax

The path notation has three special suffixes:

| Suffix | Meaning | Example |
|--------|---------|---------|
| `/?` | A scalar value (string, number, boolean) | `/status/?` |
| `/*` | Everything below this node | `/metadata/*` |
| `/[]` | All elements in an array (collectively) | `/tags/[]/?` |

Some concrete mappings for a document like `{ "locations": [{ "country": "Germany", "city": "Berlin" }], "headquarters": { "country": "Belgium" } }`:

- `/headquarters/country/?` — indexes the scalar value `"Belgium"`
- `/locations/[]/country/?` — indexes `"Germany"` (and any other country values in the array)
- `/headquarters/*` — indexes everything under `headquarters`

#### Path Precedence Rules

When included and excluded paths conflict, **the more precise path wins**:

- `/food/ingredients/nutrition/*` (included) beats `/food/ingredients/*` (excluded) — data under `nutrition` gets indexed even though `ingredients` broadly is excluded.
- `/?` is more precise than `/*` — so `/a/?` beats `/a/*`.
- The root path `/*` must appear in either the included or excluded list.

<!-- Source: mslearn-docs/content/develop-modern-applications/performance/indexing/index-policy.md -->

This precedence system lets you express "index everything under this subtree *except* this one branch" or "exclude this whole subtree *except* these specific leaves" cleanly in a single policy.

### Range Indexes for Equality and Range Queries

**Range indexes** are the workhorse of Cosmos DB indexing. They're based on an ordered tree structure, and they're what the default policy creates for every string and number property. Range indexes support:

- **Equality filters:** `WHERE c.status = 'active'`
- **`IN` expressions:** `WHERE c.status IN ('active', 'pending')`
- **Range comparisons:** `WHERE c.age > 18`, `WHERE c.price <= 100`
- **`IS_DEFINED` checks:** `WHERE IS_DEFINED(c.email)`
- **String functions:** `CONTAINS`, `STARTSWITH`, `STRINGEQUALS`, `ENDSWITH`, `RegexMatch`
- **Single-property `ORDER BY`:** `ORDER BY c.createdAt`
- **Array containment:** `ARRAY_CONTAINS(c.tags, 'urgent')`

<!-- Source: mslearn-docs/content/manage-your-account/containers-and-items/index-overview.md -->

You don't configure range indexes explicitly — they're the default type created for any included path. If a path is in your included list, it gets a range index. The only decision is whether to include or exclude the path.

> **Key rule:** An `ORDER BY` clause on a single property *always* requires a range index on that property. If the path isn't indexed, the query fails — it doesn't just get slow, it returns an error.

### Spatial Indexes for Geospatial Data

Cosmos DB doesn't create spatial indexes by default. If your documents contain GeoJSON data and you want to use `ST_DISTANCE`, `ST_WITHIN`, or `ST_INTERSECTS` in your queries, you need to explicitly add a spatial index.

<!-- Source: mslearn-docs/content/manage-your-account/containers-and-items/index-overview.md -->

A spatial index definition specifies the path and the geometry types to index:

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
            "types": ["Point", "Polygon"]
        }
    ]
}
```

<!-- Source: mslearn-docs/content/develop-modern-applications/how-to-geospatial-index-query.md -->

The supported geometry types are **Point**, **Polygon**, **MultiPolygon**, and **LineString**. Your data must be stored as valid [GeoJSON](https://geojson.org/) — Cosmos DB won't index invalid geometry. Chapter 8 covered the spatial query functions; here, just make sure the indexing policy matches the geometry types you're actually querying.

Only include the geometry types you need. Indexing all four types on a path costs more write RUs than indexing just `Point` and `Polygon`, so be deliberate.

### Composite Indexes

This is where indexing policy customization delivers the biggest bang for the buck. **Composite indexes** are purpose-built for queries that touch multiple properties — multi-property `ORDER BY`, filter-plus-sort combinations, and multi-filter queries where at least one filter is an equality.

<!-- Source: mslearn-docs/content/develop-modern-applications/performance/indexing/index-policy.md -->

The default policy doesn't create any composite indexes. You must define them explicitly, and you need to understand the ordering rules to get them right.

Here's a composite index definition:

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
    "compositeIndexes": [
        [
            { "path": "/status", "order": "ascending" },
            { "path": "/createdAt", "order": "descending" }
        ],
        [
            { "path": "/customerId", "order": "ascending" },
            { "path": "/orderDate", "order": "descending" }
        ]
    ]
}
```

Each composite index is an array of path-order pairs. You can define multiple composite indexes per policy. The limits are generous: up to **8 properties per composite index** and up to **100 composite index paths** per container.

<!-- Source: mslearn-docs/content/manage-your-account/enterprise-readiness/concepts-limits.md -->

> **Note:** Composite paths have an implicit `/?` at the end — you shouldn't specify `/?` or `/*` in composite paths. They only index scalar values, and the paths are case-sensitive.

#### Rules for Composite Index Property Order

The property order in your composite index definition must match how your queries use those properties. Here are the three patterns and their rules:

**Pattern 1: Multi-property `ORDER BY`**

The composite index paths must match the `ORDER BY` clause in sequence and sort direction. The one exception: a composite index also supports the *exact opposite* sort order on all paths.

| Composite Index | Query `ORDER BY` | Supported? |
|----------------|------------------|------------|
| `(name ASC, age ASC)` | `ORDER BY c.name ASC, c.age ASC` | ✅ Yes |
| `(name ASC, age ASC)` | `ORDER BY c.name DESC, c.age DESC` | ✅ Yes (opposite on all) |
| `(name ASC, age ASC)` | `ORDER BY c.age ASC, c.name ASC` | ❌ No (wrong sequence) |
| `(name ASC, age ASC)` | `ORDER BY c.name ASC, c.age DESC` | ❌ No (mixed directions) |

<!-- Source: mslearn-docs/content/develop-modern-applications/performance/indexing/index-policy.md -->

A composite index on three paths does *not* serve a query that `ORDER BY`s on only two of them. You need an exact match.

**Pattern 2: Multi-property filters**

For queries that filter on multiple properties (at least one equality), the rules shift:

- **Equality filters first.** Properties with equality filters (`=`) must precede the range filter in the composite index.
- **One range filter, last.** Each composite index optimizes at most one range filter (`>`, `<`, `>=`, `<=`, `!=`), and it must be the last property in the index.
- **Sort order doesn't matter for filter-only queries.** The `ASC`/`DESC` order is irrelevant when no `ORDER BY` is involved.

| Composite Index | Query | Supported? |
|----------------|-------|------------|
| `(name ASC, age ASC)` | `WHERE c.name = 'John' AND c.age > 18` | ✅ Yes |
| `(age ASC, name ASC)` | `WHERE c.name = 'John' AND c.age > 18` | ❌ No (equality must come first) |
| `(name ASC, age ASC)` | `WHERE c.name != 'John' AND c.age > 18` | ❌ No (name uses range, not equality) |

<!-- Source: mslearn-docs/content/develop-modern-applications/performance/indexing/index-policy.md -->

When a query has two range filters, you need *two separate composite indexes* — one for each range property. A single composite index on `(name ASC, age ASC, _ts ASC)` can't optimize both `age > 18` and `_ts > 1612212188` in the same query. Instead, define `(name ASC, age ASC)` and `(name ASC, _ts ASC)` as separate composite indexes.

**Pattern 3: Filter + `ORDER BY`**

When a query filters on some properties and sorts on others, include the filter properties first in the `ORDER BY` clause (and in the composite index) to enable the composite index:

```sql
-- Without composite index optimization (uses range index, more expensive):
SELECT * FROM c WHERE c.name = 'John' ORDER BY c.timestamp

-- Rewritten to use composite index (name ASC, timestamp ASC):
SELECT * FROM c WHERE c.name = 'John' ORDER BY c.name, c.timestamp
```

The rule: filter properties appear first in the composite index, followed by `ORDER BY` properties. Equality filters before any range filter. The range filter (if any) goes last.

| Composite Index | Query | Supported? |
|----------------|-------|------------|
| `(name ASC, timestamp ASC)` | `WHERE c.name = 'John' ORDER BY c.name ASC, c.timestamp ASC` | ✅ Yes |
| `(name ASC, timestamp ASC)` | `WHERE c.name = 'John' ORDER BY c.timestamp ASC` | ❌ No |
| `(age ASC, name ASC, timestamp ASC)` | `WHERE c.age = 18 AND c.name = 'John' ORDER BY c.age ASC, c.name ASC, c.timestamp ASC` | ✅ Yes |

<!-- Source: mslearn-docs/content/develop-modern-applications/performance/indexing/index-policy.md -->

#### Composite Indexes with Range Filters

The "one range filter per composite index" rule is the most common source of confusion. Let me state it plainly: if a query has equality filters on properties A and B, and range filters on properties C and D, you need:

- A composite index `(A, B, C)` for the range filter on C
- A composite index `(A, B, D)` for the range filter on D

*Not* a single composite index `(A, B, C, D)`. The engine uses both composite indexes together with the individual range indexes to evaluate the query.

#### Composite Indexes with Aggregate Functions

Composite indexes also optimize queries that combine filters with aggregate functions like `SUM` and `AVG`:

```sql
SELECT AVG(c.timestamp) FROM c WHERE c.name = 'John' AND c.age = 25
```

This query benefits from a composite index on `(name ASC, age ASC, timestamp ASC)` — equality filters first, the aggregated property last. The sort order (`ASC`/`DESC`) doesn't matter for aggregates.

<!-- Source: mslearn-docs/content/develop-modern-applications/performance/indexing/index-policy.md -->

| Composite Index | Query | Supported? |
|----------------|-------|------------|
| `(name ASC, timestamp ASC)` | `SELECT AVG(c.timestamp) FROM c WHERE c.name = 'John'` | ✅ Yes |
| `(timestamp ASC, name ASC)` | `SELECT AVG(c.timestamp) FROM c WHERE c.name = 'John'` | ❌ No (filter property must come first) |
| `(name ASC, age ASC, timestamp ASC)` | `SELECT AVG(c.timestamp) FROM c WHERE c.name = 'John' AND c.age = 25` | ✅ Yes |

### Tuple Indexes for Array Element Queries

**Tuple indexes** solve a specific and common problem: efficiently filtering on *multiple fields within the same array element*. Without a tuple index, a query that checks two properties of an array element can match items where those values appear in *different* elements of the array, leading to false positives or forcing the engine to do extra work.

<!-- Source: mslearn-docs/content/develop-modern-applications/performance/indexing/index-policy.md -->

Consider a document with an `events` array:

```json
{
    "id": "venue-101",
    "events": [
        { "name": "M&M", "category": "Candy" },
        { "name": "Jazz Night", "category": "Music" }
    ]
}
```

You want to find venues that have an event where `name = 'M&M'` AND `category = 'Candy'` — the same event, not just any combination. A tuple index tells the engine to index those properties *together* at the array element level.

The syntax uses a tuple specifier `{}` after the array wildcard `[]`:

```json
{
    "indexingMode": "consistent",
    "automatic": true,
    "includedPaths": [
        { "path": "/*" },
        { "path": "/events/[]/{name, category}/?" }
    ],
    "excludedPaths": []
}
```

The query that uses this index:

```sql
SELECT * FROM root r
WHERE EXISTS (
    SELECT VALUE 1 FROM ev IN r.events
    WHERE ev.name = 'M&M' AND ev.category = 'Candy'
)
```

<!-- Source: mslearn-docs/content/develop-modern-applications/performance/indexing/how-to-manage-indexing-policy.md -->

A few syntax rules for tuple paths:

- The path prefix (e.g., `/events`) leads to the array.
- The array wildcard `[]` must immediately precede the tuple specifier `{}`.
- Tuples inside `{}` don't start with `/` and don't end with `?`.
- The whole path ends with `/?`.
- No nested array wildcards allowed in the path prefix or inside tuples.

Valid: `/events/[]/{name, category}/?`, `/events/[]/{name/first, category}/?`

Invalid: `/events/[]/{name/[]/first, category}/?` (array wildcard inside tuple), `/events/{name, category}/?` (missing `[]`)

## Disabling Indexing for Write-Heavy Bulk Import Scenarios

When you're doing a bulk import of millions of items — an initial data migration, a backfill, or a batch ETL — indexing every property on every write is overhead you don't need yet. Each index update adds to the write RU cost, and during a bulk load you care about throughput, not query speed.

You have two options:

**Option 1: Set indexing mode to `none`.** This completely disables indexing. The container becomes a pure key-value store — point reads by `id` and partition key still work, but all queries fall back to full scans.

```json
{
    "indexingMode": "none"
}
```

After the bulk import completes, switch back to `consistent` mode. The engine triggers an index transformation that builds the full index in the background. You can track progress via the SDK.

<!-- Source: mslearn-docs/content/develop-modern-applications/performance/indexing/index-policy.md -->

> **Gotcha:** You can't enable TTL (time-to-live) on a container with `indexingMode: "none"`. If your container uses TTL, use Option 2 instead.

**Option 2: Exclude all paths but keep consistent mode.** This gives you the benefits of minimal indexing while keeping TTL and `id`/`_ts` indexing active:

```json
{
    "indexingMode": "consistent",
    "includedPaths": [],
    "excludedPaths": [
        { "path": "/*" }
    ]
}
```

After the import, add your included paths back. The system properties `id` and `_ts` stay indexed throughout, so point reads continue working.

For more on RU cost implications of indexing during bulk operations, see Chapter 10 (Request Units In Depth) and Chapter 11 (Provisioned Throughput).

## Full-Text Search Indexing Policy

Full-text search in Cosmos DB requires two things: a **full-text policy** on the container and a **full-text index** in the indexing policy. The full-text policy defines *which paths contain searchable text and what language they use*. The full-text index tells the engine to *build a specialized text index on those paths*.

<!-- Source: mslearn-docs/content/build-ai-applications/full-text-indexing-and-search/gen-ai-full-text-search.md -->

> **Prerequisite:** You must enable the "Full Text & Hybrid Search for NoSQL API" feature on your Cosmos DB account before configuring full-text indexes.

### The Full-Text Policy (Container Level)

This is a container-level setting, separate from the indexing policy. It declares the paths and languages:

```json
{
    "defaultLanguage": "en-US",
    "fullTextPaths": [
        {
            "path": "/description",
            "language": "en-US"
        },
        {
            "path": "/reviewText",
            "language": "en-US"
        }
    ]
}
```

Supported languages include English (`en-US`), German (`de-DE`), Spanish (`es-ES`), French (`fr-FR`), Italian (`it-IT`), Portuguese (`pt-PT`), and Brazilian Portuguese (`pt-BR`). Multi-language support beyond English is in preview.

<!-- Source: mslearn-docs/content/build-ai-applications/full-text-indexing-and-search/gen-ai-full-text-search.md -->

> **Note:** Wildcards (`*`, `[]`) are not supported in full-text policies or full-text indexes. Each path must be explicit.

### The Full-Text Index (Indexing Policy)

With the container policy in place, add a `fullTextIndexes` section to your indexing policy:

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
        { "path": "/description" },
        { "path": "/reviewText" }
    ]
}
```

<!-- Source: mslearn-docs/content/develop-modern-applications/performance/indexing/index-policy.md -->

The paths in `fullTextIndexes` must match paths declared in the container's full-text policy. Once configured, functions like `FullTextContains`, `FullTextContainsAll`, `FullTextContainsAny`, and `FullTextScore` (for BM25 relevance ranking) use this index. Without it, these functions still work but consume significantly more RUs.

Full-text indexing includes tokenization, stemming, and stop word removal — the standard text processing pipeline you'd expect from a search engine. The BM25 scoring considers term frequency, inverse document frequency, and document length to rank results by relevance.

Chapter 25 covers the full-text search query functions and hybrid search patterns in depth. This section is just the indexing configuration you need to make them efficient.

## Vector Indexing Policies (DiskANN)

Vector search is one of the most significant additions to Cosmos DB, and its indexing story is different from everything else we've covered. Vector indexes aren't part of the standard inverted index — they're specialized data structures optimized for high-dimensional similarity search.

<!-- Source: mslearn-docs/content/build-ai-applications/use-vector-search/vector-search.md -->

> **Prerequisite:** Enable the "Vector Search for NoSQL API" feature on your account before configuring vector indexes.

### Container Vector Policy

Before you define a vector index, you need a **container vector policy** that tells the engine where your vectors live, their dimensions, data type, and distance function:

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

<!-- Source: mslearn-docs/content/build-ai-applications/use-vector-search/vector-search.md -->

The key settings:

| Setting | Options | Default |
|---------|---------|---------|
| **`dataType`** | `float32`, `float16`, `int8`, `uint8` | — |
| **`distanceFunction`** | `cosine`, `dotproduct`, `euclidean` | `cosine` |
| **`dimensions`** | 1–4096 (varies by index type) | 1536 |

Using `float16` instead of `float32` cuts vector storage by 50% with a minor accuracy trade-off — worth considering for large-scale deployments.

> **Important:** You can't modify vector embedding or vector indexing policy settings in place. However, you *don't* need to create a new container — you can drop the existing vector policy and index, then re-add them with the new configuration. Be aware that this triggers a full reindex of your vector data, which consumes RUs and leaves vector search unavailable on that path until the new index builds. Plan your initial settings carefully, but know that the escape hatch exists.
<!-- Source: mslearn-docs/content/build-ai-applications/use-vector-search/vector-search.md line 203 -->

### Vector Index Types

You specify the vector index in the indexing policy's `vectorIndexes` section. Three types are available:

| Index Type | Algorithm | Max Dimensions | Accuracy | Best For |
|-----------|-----------|----------------|----------|----------|
| **`flat`** | Brute-force kNN | 505 | 100% | Small datasets, exact results |
| **`quantizedFlat`** | Brute-force with compression | 4,096 | Near-100% | ≤50K vectors per physical partition, filtered searches |
| **`diskANN`** | DiskANN (ANN) | 4,096 | High (approximate) | >50K vectors per physical partition, production scale |

<!-- Source: mslearn-docs/content/develop-modern-applications/performance/indexing/index-policy.md -->

**`flat`** stores vectors directly in the standard index. It gives you perfect recall — every search result is guaranteed to be the actual nearest neighbor. The trade-off is a hard limit of 505 dimensions, which rules out most modern embedding models (OpenAI's `text-embedding-ada-002` produces 1536 dimensions).

**`quantizedFlat`** compresses vectors using product quantization before storing them. You get brute-force search accuracy (near-perfect) with lower latency and RU cost than `flat`. Best for scenarios where query filters narrow the search space to a manageable set of vectors — think "find similar products within this category."

**`diskANN`** is the production-grade choice for most vector workloads. Developed by Microsoft Research, DiskANN builds a graph-based approximate nearest neighbor index that can offer some of the lowest latency, highest throughput, and lowest RU cost at scale, while maintaining high accuracy. If you have more than 50,000 vectors per physical partition, DiskANN is the clear winner.

> **Gotcha:** Both `quantizedFlat` and `diskANN` require at least **1,000 vectors** to be inserted before the quantization is accurate. Below that threshold, the engine falls back to a full scan and RU charges will be higher.

Here's a complete indexing policy with a DiskANN vector index:

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

Notice that `/contentVector/*` is in the excluded paths. You don't want the standard range index wasting storage on high-dimensional float arrays — the vector index handles those paths separately.

### Tuning Vector Index Build Parameters

Both `diskANN` and `quantizedFlat` accept optional parameters to tune the accuracy-vs-cost trade-off:

- **`quantizationByteSize`** — Size in bytes for product quantization (min: 1, max: 512, default: system-determined). Larger values improve search accuracy but increase RU cost and latency. Applies to both `quantizedFlat` and `diskANN`.
- **`indexingSearchListSize`** — Number of vectors to search during index construction (min: 10, max: 500, default: 100). Larger values build a higher-quality graph but increase ingest latency. Applies to `diskANN` only.

<!-- Source: mslearn-docs/content/develop-modern-applications/performance/indexing/index-policy.md -->

For most workloads, the defaults are a solid starting point. Tune these only after you've benchmarked with representative data and queries.

### Sharded DiskANN for Multi-Tenant Vector Search

Standard DiskANN builds one index per physical partition. For multi-tenant applications or category-specific searches, you can **shard the DiskANN index** by a property value, creating a separate smaller index for each distinct value.

<!-- Source: mslearn-docs/content/build-ai-applications/use-vector-search/gen-ai-sharded-diskann.md -->

Add a `vectorIndexShardKey` to the vector index definition:

```json
{
    "vectorIndexes": [
        {
            "path": "/embedding",
            "type": "diskANN",
            "vectorIndexShardKey": ["/tenantId"]
        }
    ]
}
```

This creates a separate DiskANN index for each unique `tenantId`. When you query with a filter on `tenantId`, the search runs against only that tenant's index — smaller, faster, cheaper, and with better recall because you're not searching through every tenant's vectors.

```sql
SELECT TOP 10 *
FROM c
WHERE c.tenantId = 'tenant-42'
ORDER BY VectorDistance(c.embedding, [0.1, 0.2, ...])
```

The shard key can be any document property — it doesn't have to be the partition key, though using the partition key is a natural fit for multi-tenant scenarios. Chapter 26 (Multi-Tenancy Patterns) covers the broader architecture; Chapter 25 covers the vector search query patterns.

## Lazy vs. Consistent Indexing Mode

Cosmos DB supports two indexing modes, and one deprecated one:

| Mode | Behavior | Use When |
|------|----------|----------|
| **`consistent`** | Index updated synchronously on every write | Almost always — this is the default and the right choice |
| **`none`** | No indexing at all | Bulk imports, pure key-value stores |
| **`lazy`** *(deprecated)* | Index updated asynchronously at lower priority | Never — see below |

<!-- Source: mslearn-docs/content/develop-modern-applications/performance/indexing/index-policy.md -->

**Lazy mode** updates the index at a lower priority when the engine isn't busy with other work. This sounds appealing — lower write latency! — but it means your queries can return **inconsistent or incomplete results**. You might write an item and immediately query for it, only to get zero results because the index hasn't caught up yet.

New containers can't select lazy mode. It's a legacy option that Microsoft has deprecated. If you have an existing container on lazy mode, migrate to `consistent`. The only exception would require contacting Microsoft directly — and serverless accounts don't support lazy mode at all.

The bottom line: use `consistent` for everything. If you need to reduce write costs, tune your included/excluded paths instead of weakening index consistency.

## Global Secondary Indexes (Preview)

Every indexing technique we've covered so far works within the bounds of a partition. Your indexes live alongside your data on each physical partition, and they're great at accelerating queries *within* a partition. But what about queries that need to filter on a property that isn't the partition key? Those become cross-partition queries that fan out to every physical partition — expensive and slow as your container grows (Chapter 5 covered why).

**Global secondary indexes (GSIs)** address this by letting you create a read-only copy of your data with a *different partition key*. What would be a cross-partition query on the source container becomes a single-partition query on the GSI.

<!-- Source: mslearn-docs/content/develop-modern-applications/global-secondary-indexes-(preview)/global-secondary-indexes.md -->

> **Preview warning:** GSIs are currently in preview. Don't use them for production workloads until they reach GA.

### How GSIs Work

A GSI is a separate container that's automatically synced from a source container via change feed. You define:

- A **partition key** (different from the source) optimized for your query pattern.
- A **definition query** that projects which properties to include (e.g., `SELECT c.customerId, c.emailAddress FROM c`).
- An **indexing policy** (just like any container — you can add vector, full-text, or composite indexes).

GSI containers must use **autoscale throughput**. They're eventually consistent with the source container regardless of your account's consistency level.

```sql
-- Source container partition key: /customerId
-- This is a cross-partition query on the source:
SELECT * FROM c WHERE c.emailAddress = 'priya@example.com'

-- GSI partition key: /emailAddress  
-- Same query becomes a single-partition query on the GSI:
SELECT * FROM c WHERE c.emailAddress = 'priya@example.com'
```

### GSI Trade-offs

GSIs add storage cost (you're storing a copy of the data) and RU cost (change feed reads from the source, writes to the GSI). They're eventually consistent, so there's a lag between a write to the source and its appearance in the GSI. You can monitor this lag with the **Global Secondary Index Propagation Latency in Seconds** metric in the Azure portal.

<!-- Source: mslearn-docs/content/develop-modern-applications/global-secondary-indexes-(preview)/global-secondary-indexes.md -->

The definition query and partition key are **immutable after creation** — choose carefully. Projected properties are flattened to the top level in the GSI, so nested properties like `name.first` become top-level `first`.

GSIs are powerful for read-heavy workloads where you need efficient queries on multiple access patterns without denormalizing your data model in the source container. They're also useful for isolating vector or full-text search indexes from your transactional workload.

## Measuring Index Storage and RU Impact

Indexing isn't free. Every indexed path adds to your storage footprint, and every write pays an RU tax to update those indexes. The default "index everything" policy can result in an index that's *larger than your data* — that's not a bug, it's the cost of querying any path instantly.

### Tracking Index Size

Total consumed storage = **data size + index size**. You can view both in the Azure portal's **Metrics** section under the `DocumentCount` and storage metrics. Some behaviors to know:

- When data is deleted, indexes are compacted on a near-continuous basis. Small deletions won't show an immediate decrease in index size.
- Index size can temporarily grow during physical partition splits, then settle back down.

<!-- Source: mslearn-docs/content/develop-modern-applications/performance/indexing/index-policy.md -->

### Using Index Metrics to Find What's Missing

Cosmos DB provides **index metrics** that tell you exactly which indexed paths a query used and which new indexes might help. Enable them in your query by setting `PopulateIndexMetrics` to `true`:

```csharp
QueryRequestOptions options = new QueryRequestOptions
{
    PopulateIndexMetrics = true
};

FeedIterator<Order> iterator = container.GetItemQueryIterator<Order>(
    "SELECT * FROM c WHERE c.status = 'active' AND c.total > 100",
    requestOptions: options
);

FeedResponse<Order> response = await iterator.ReadNextAsync();
Console.WriteLine(response.IndexMetrics);
```

<!-- Source: mslearn-docs/content/develop-modern-applications/performance/indexing/index-metrics.md -->

The output shows two categories:

- **Utilized indexes:** The paths and composite indexes the query actually used. If a path doesn't appear here, removing it from the indexing policy won't hurt this query.
- **Potential indexes:** Paths and composite indexes that, if added, might improve performance. These are *recommendations*, not guarantees — always test the suggestion and confirm it actually reduces RU cost.

```
Index Utilization Information
  Utilized Single Indexes
    Index Spec: /status/?
    Index Impact Score: High
    ---
    Index Spec: /total/?
    Index Impact Score: High
    ---
  Potential Composite Indexes
    Index Spec: /status ASC, /total ASC
    Index Impact Score: High
    ---
```

Each index entry includes an **impact score** (high or low) based on the query shape. Focus on high-impact suggestions first.

> **Tip:** Don't enable index metrics in production continuously — they add overhead. Use them for targeted troubleshooting: identify expensive queries from your diagnostic logs, replay them with index metrics enabled, and use the recommendations to tune your policy.

### The Index Transformation Process

When you update an indexing policy, the engine performs an **index transformation** — rebuilding the index in the background from old policy to new. Key facts about this process:

- It's **online and in-place**. No extra storage is consumed, and writes continue uninterrupted.
- It's **asynchronous**. The time it takes depends on your provisioned throughput, item count, and item size.
- It runs at **lower priority** than your CRUD operations and queries — it won't steal RUs from your workload.
- **Adding a new index:** Queries don't use it until the transformation completes. Old query performance is unchanged during the build.
- **Removing an index:** Takes effect immediately. The engine stops using the dropped index and falls back to a full scan for queries that depended on it.

<!-- Source: mslearn-docs/content/develop-modern-applications/performance/indexing/index-policy.md -->

Because add and remove have asymmetric timing, be careful when *replacing* one index with another (say, swapping a single-path index for a composite index). Add the new index first, wait for the transformation to complete, *then* remove the old one. If you remove first, queries depending on the old index will fall back to full scans until the new one finishes building.

Batch your changes when possible. Multiple indexing policy updates trigger separate transformations, but a single update with all changes triggers one transformation that completes faster.

You can track transformation progress via the SDK by checking the `x-ms-documentdb-collection-index-transformation-progress` response header after a container read with `PopulateQuotaInfo` set to `true`. The value goes from 0 to 100.

### The Write Cost Trade-off

Every indexed path adds to the RU cost of writes. A point write on a 1 KB document with the default "index everything" policy typically costs around 5–7 RUs. Excluding paths you don't query reduces that cost. For write-heavy workloads, the savings compound fast.
<!-- Source: key-value-store-cost.md (5 RU baseline for a 1 KB write without indexing); with the default index-all policy, actual cost is higher and varies with document structure and number of indexed paths -->

The flip side: excluding a path means queries on that path fall back to full scans, which costs more RUs per query. The optimization is straightforward — if you query a path rarely but write to the container constantly, exclude it. If you query it on every request, include it.

Chapter 10 dives into the exact RU mechanics of reads and writes. Chapter 27 covers the iterative performance tuning loop where indexing policy changes are one of your primary levers.

### Limits at a Glance

| Limit | Value |
|-------|-------|
| Maximum explicitly included paths per container | 1,500 |
| Maximum explicitly excluded paths per container | 1,500 |
| Maximum properties in a composite index | 8 |
| Maximum composite index paths per container | 100 |
| Maximum dimensions for `flat` vector index | 505 |
| Maximum dimensions for `quantizedFlat` / `diskANN` | 4,096 |
| Minimum vectors before quantization is accurate | 1,000 |

<!-- Source: mslearn-docs/content/manage-your-account/enterprise-readiness/concepts-limits.md, mslearn-docs/content/build-ai-applications/use-vector-search/vector-search.md -->

Your indexing policy is one of the most powerful — and most frequently under-tuned — knobs in Cosmos DB. The default gets you started. Composite indexes, path exclusions, and specialized index types get you to production-grade performance. Next up, Chapter 10 takes a deep look at how request units work and how every operation — including the indexing work behind every write — maps to a concrete cost.
