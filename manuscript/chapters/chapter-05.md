# Chapter 5: Partition Keys — The Most Important Decision You'll Make

You can change your indexing policy. You can switch between autoscale and manual throughput. You can add regions, adjust consistency, even reshape your documents with the Patch API. But once you create a container, you cannot change its partition key. If you got it wrong, your options are creating a new container and migrating all your data — or living with a performance ceiling that no amount of RUs can fix.

That's why this is the most important decision you'll make in Cosmos DB. Your data model (Chapter 4) shapes how your documents look. Your partition key determines how they scale.

## Why Partition Key Choice Defines Your Performance Ceiling

Chapter 2 introduced logical and physical partitions briefly. Now we go deep.

When you create a container and specify a partition key path — say, `/customerId` — you're telling Cosmos DB how to distribute your data. Every item you write gets hashed on that property's value and assigned to a **logical partition**: the set of all items sharing the same partition key value. Cosmos DB then maps logical partitions to **physical partitions**, which are the actual compute and storage units running behind the scenes.

<!-- Source: partitioning.md -->

Here's what you need to internalize:

- Each **logical partition** can store up to **20 GB** of data. Hit that ceiling and writes for that partition key value are rejected with an HTTP 403 — you'll need to delete data or migrate to a new partition key to resume writing.
- Each **physical partition** can store up to **50 GB** and serve up to **10,000 RU/s**. Since each logical partition maps to exactly one physical partition, a single logical partition is also capped at 10,000 RU/s.
- Provisioned throughput is divided **evenly** across physical partitions. If you provision 30,000 RU/s and have three physical partitions, each gets 10,000 RU/s — regardless of how much traffic each partition actually receives.

<!-- Source: partitioning.md -->

That last point is the kicker. If 80% of your traffic targets one partition key value, that value's physical partition gets 80% of the load but only a third of the throughput. The other two partitions sit mostly idle while users hitting the hot partition get throttled. No amount of provisioned RU/s fixes a bad partition key — you're just buying capacity that goes unused.

Your partition key doesn't just organize data. It sets the upper bound on how fast and how large any single slice of your application can grow.

## Properties of a Good Partition Key

The docs list the criteria, and they're right. But they read like a checklist without context. Let's add the *why*.

<!-- Source: partitioning.md -->

### High Cardinality

**Cardinality** means the number of distinct values the partition key can take. You want a lot of them — hundreds, thousands, ideally millions.

Why? Because Cosmos DB can only distribute data and throughput across physical partitions at the logical-partition boundary. If you have 5 distinct partition key values, you can never use more than 5 logical partitions, which limits how many physical partitions your data can spread across. Even if you provision 100,000 RU/s, each partition key value is constrained to the throughput of its single physical partition (10,000 RU/s max), and splits can only help at the physical partition level — not the logical one.

A property like `customerId` (millions of distinct values) has high cardinality. A property like `status` ("active," "inactive," "suspended") does not. A property like `country` (around 200 values) is borderline — it might work for a small dataset but becomes a bottleneck at scale.

### Even Write Distribution

High cardinality isn't enough if traffic isn't evenly spread. A partition key with a million distinct values still creates a hot partition if one value generates 90% of the writes.

Think about a multi-tenant SaaS application where `tenantId` is the partition key. If you have 10,000 tenants but one enterprise customer generates half the traffic, that customer's logical partition absorbs half the write load while receiving only a fraction of the total throughput. The other 9,999 tenants' partitions sit underutilized.

The ideal partition key distributes *work* — not just *data* — roughly evenly across values.

### Efficient Single-Partition Reads

The cheapest read in Cosmos DB is a **point read**: you provide the `id` and the partition key, and the service goes directly to the correct physical partition and fetches the item. About 1 RU for a 1 KB document. No query engine, no index scan — just a direct lookup.

The cheapest query is an **in-partition query**: you include the partition key in the `WHERE` clause, and Cosmos DB routes the query to a single physical partition. It searches only that partition's index.

Both of these operations require knowing the partition key. If your most common read patterns don't naturally include the partition key, every read becomes a **cross-partition query** that fans out to every physical partition. That's not catastrophic for small containers, but the per-partition overhead adds up fast as your container grows. We'll quantify the exact cost in the Cross-Partition Queries section later in this chapter.

<!-- Source: how-to-query-container.md -->

The best partition key aligns with your hottest read path. Ask yourself: *what property do I almost always know when I'm fetching data?*

### The Decision Matrix

Here's the three-part test, summarized:

| Criterion | Good Sign | Red Flag |
|-----------|-----------|----------|
| High cardinality | 100K+ distinct values | <100 distinct values |
| Even distribution | No single value dominates | One value >5% of traffic |
| Read alignment | Queries include it in `WHERE` | Queries filter on other prop |

A property that passes all three is your partition key. When no single property qualifies, you'll need synthetic keys or hierarchical partition keys — both covered later in this chapter.

## Partition Key Anti-Patterns and Their Consequences

### Hot Partitions and Throughput Throttling

A **hot partition** occurs when one logical partition (or a small number of them) receives a disproportionate share of requests. Because throughput is divided evenly across physical partitions, the hot partition's physical partition runs out of RU/s while the others have capacity to spare. The result: `429 Too Many Requests` errors on the hot partition, even though your container-level throughput isn't fully consumed.

<!-- Source: partitioning.md -->

Imagine you've provisioned 18,000 RU/s across three physical partitions — 6,000 RU/s each. If one partition receives 12,000 RU/s of traffic, half those requests are throttled. Meanwhile, the other two partitions are using maybe 2,000 RU/s each. You're paying for 18,000 RU/s but can only use 10,000. The "fix" of doubling your throughput to 36,000 RU/s just creates more physical partitions with more unused capacity on each one.

> **Gotcha:** Throughput redistribution (preview) and burst capacity can provide some relief for uneven workloads, but they're band-aids, not cures. The root cause is always the partition key choice. Chapter 27 covers remediation strategies for hot partitions in production.

### Sequential IDs or Timestamps as Partition Keys

Using a timestamp like `/createdAt` or a sequential ID like `/orderNumber` as your partition key is one of the most common mistakes. It feels logical — new orders get new IDs, new events get new timestamps — but it creates a *write-hot* pattern where all current writes funnel into the same logical partition (the latest time bucket or the highest ID range).

Consider a time-based key with month granularity (`2025-06`). All writes for the entire month go to a single logical partition. If you've provisioned 100,000 RU/s across 10 physical partitions, only the one partition holding the current month is doing work — capping your effective write throughput at 10,000 RU/s.

<!-- Source: design-partitioning-iot.md -->

Increase the granularity (daily, hourly, by-the-minute) and you spread writes better, but now every query that spans a time range becomes a cross-partition query hitting many physical partitions. You've traded one problem for another.

The same logic applies to monotonically increasing IDs. If your `id` values are sequential (1, 2, 3, …), all current writes pile up on whatever logical partition handles the latest range.

> **Tip:** If you need to query by time range, store the timestamp as a regular indexed property and use a different property (or a synthetic/hierarchical key) as the partition key. You get the time-range queries *and* even write distribution.

## Synthetic Partition Keys: Combining Properties for Better Distribution

Sometimes no single property in your documents satisfies all three criteria. That's where **synthetic partition keys** come in — you compute a new property by concatenating or hashing existing ones, and use that as the partition key.

<!-- Source: synthetic-partition-keys.md -->

### Concatenation

The simplest approach: combine two or more properties into a single value.

```json
{
  "deviceId": "sensor-4521",
  "date": "2025-06-15",
  "partitionKey": "sensor-4521-2025-06-15",
  "temperature": 22.5,
  "humidity": 61.3
}
```

Here, neither `deviceId` alone (risk of exceeding 20 GB over time) nor `date` alone (all devices' data for a day lands on one partition) is a great partition key. But concatenating them gives you a value with high cardinality and good write distribution — each device-day combination gets its own logical partition.

The trade-off: queries that only know the `deviceId` can't target a single partition. They'll fan out across all partitions because the partition key includes the date. This is where hierarchical partition keys (covered next) shine — they give you the data distribution of a synthetic key without the cross-partition query penalty for prefix matches.

### Random Suffix

For truly hot partition keys — say, a high-volume event that many users trigger on the same date — you can append a random number:

```json
{
  "eventDate": "2025-06-15",
  "partitionKey": "2025-06-15.237",
  "payload": { ... }
}
```

If you choose a random number between 1 and 400, writes for a single date spread across 400 logical partitions. Throughput distribution is excellent.

The downside: reading a specific item requires knowing the suffix, and querying all items for a date means hitting up to 400 logical partitions. This strategy favors write-heavy workloads where reads are either by exact key or are batch/analytical operations that can tolerate fan-out.

### Precalculated Suffix

A middle ground between random and concatenation: compute a deterministic hash of some queryable property and append it to the partition key. For example, hash the `vehicleId` to a number between 1 and 400 and append it to the date:

```json
{
  "vehicleId": "VIN-98765",
  "date": "2025-06-15",
  "partitionKey": "2025-06-15.42",
  "mileage": 58231
}
```

<!-- Source: synthetic-partition-keys.md -->

Since the hash is deterministic, you can always recompute it at read time. If you know the vehicle ID, you know the suffix, which means you can build the full partition key and do a point read. Writes are evenly distributed; reads by vehicle + date are single-partition. The only penalty is queries spanning all vehicles for a date — those still fan out across the suffix range.

> **Tip:** Synthetic keys add complexity to your application. You own the concatenation or hashing logic in your write path and read path. Before reaching for a synthetic key, check whether hierarchical partition keys solve the same problem more cleanly.

## Large Partition Keys: Values Up to 2 KB

Before May 2019, Cosmos DB hashed only the first 101 bytes of a partition key value. Containers created with this older hash function treat partition key values that share the same first 101 bytes as the same logical partition — a **partition key collision** that leads to data skew, incorrect unique key enforcement, and uneven storage distribution.

<!-- Source: large-partition-keys.md -->

**Large partition keys** fix this by enabling an enhanced hash function that uses up to **2,048 bytes** (2 KB) of the partition key value. This is important when your partition key is a long string — a URL, a concatenated synthetic key, or a fully qualified tenant identifier.

The practical details:

- Containers created via the Azure portal use large partition keys **by default**.
- Containers created via the .NET SDK v3 use large partition keys by default. The older .NET SDK v2 does not — you must explicitly set `PartitionKeyDefinitionVersion.V2`.
- Large partition key support can only be enabled at **container creation time**. If your existing container doesn't support it, you'll need to create a new container and migrate.

<!-- Source: large-partition-keys.md -->

Unless you're working with legacy SDKs or an application that predates May 2019, always use large partition keys. There's no downside.

## Hierarchical Partition Keys (Subpartitioning)

This is the feature that solves the hardest partition key problems. If synthetic keys feel like a workaround, **hierarchical partition keys** (HPK) are the platform-level answer.

<!-- Source: hierarchical-partition-keys.md -->

### The Problem HPK Solves

Consider a multi-tenant SaaS application. You want to partition by `tenantId` so that queries for a specific tenant's data stay within a single physical partition — no fan-out. But your largest tenant has 50 GB of data, far exceeding the 20 GB logical partition limit. Partitioning by `tenantId` alone will block writes for that tenant once it hits the ceiling.

You could use a synthetic key like `tenantId-userId`, but now *every* query for a tenant (without specifying the user) becomes a cross-partition fan-out. You've traded a storage problem for a query performance problem.

Hierarchical partition keys let you have both: partition by `TenantId` first, then subdivide by `UserId` (and optionally a third level). The logical partition is now defined by the *full path* — `TenantId + UserId` — so the 20 GB limit applies to each `TenantId + UserId` combination, not to the `TenantId` alone. But queries that only specify `TenantId` are still routed to just the subset of physical partitions that hold that tenant's data — no full fan-out.

### How It Works

With HPK, you define up to **three levels** of partition key paths at container creation time. Cosmos DB uses a `MultiHash` partitioning kind with version 2 of the partition key definition.

```csharp
// Create a container with hierarchical partition keys
List<string> keyPaths = new List<string> {
    "/tenantId",
    "/userId",
    "/sessionId"
};

ContainerProperties properties = new ContainerProperties(
    id: "events",
    partitionKeyPaths: keyPaths
);

Container container = await database.CreateContainerIfNotExistsAsync(
    properties,
    throughput: 10000
);
```

<!-- Source: hierarchical-partition-keys.md -->

Under the hood, Cosmos DB tries to co-locate all items with the same first-level key (`tenantId`) on the same physical partition. When a physical partition exceeds 50 GB, the service splits it — but it does so intelligently, using the second-level key to decide how to divide the data. A single `tenantId` can now span multiple physical partitions if needed, breaking through the 20 GB logical partition limit of traditional partitioning.

### Query Routing with HPK

The routing behavior follows the key hierarchy from left to right:

| Filter in Query | Routing |
|----------------|---------|
| `tenantId` + `userId` + `sessionId` | Single partition |
| `tenantId` + `userId` | Targeted subset |
| `tenantId` only | Targeted subset |
| `userId` only (no `tenantId`) | Full fan-out |
| `sessionId` only | Full fan-out |

"Single partition" means the query is routed to exactly one physical partition — most efficient. "Targeted subset" routes only to the partitions holding matching data. "Full fan-out" hits every physical partition in the container.

<!-- Source: hierarchical-partition-keys.md -->

The key insight: specifying a *prefix* of the hierarchy gives you targeted routing. Specifying a property from the "middle" or "bottom" of the hierarchy without the prefix gives you a full fan-out. Always structure your hierarchy so the property you most commonly query on is the first level.

### Use Case: Multi-Tenant Applications

Multi-tenancy is the canonical use case for HPK. Consider a B2B platform storing events per tenant:

```json
{
  "id": "evt-00482",
  "tenantId": "contoso",
  "userId": "user-8812",
  "sessionId": "sess-a1b2c3",
  "eventType": "page_view",
  "timestamp": "2025-06-15T09:23:41Z",
  "payload": { ... }
}
```

With hierarchical keys `/tenantId` → `/userId` → `/sessionId`:

- Small tenants with a few users fit entirely within one physical partition. Queries on `tenantId` hit a single partition — zero fan-out overhead.
- Large tenants (think: an enterprise with 100,000 users) can span multiple physical partitions. Queries on `tenantId` fan out only to the specific partitions holding that tenant's data, not to every partition in the container.
- The 20 GB logical partition limit applies to each unique combination of `tenantId + userId + sessionId`, not to `tenantId` alone. A single tenant can effectively store unlimited data.

Chapter 26 covers multi-tenancy patterns in depth — tenant isolation strategies, shared vs. dedicated containers, noisy-neighbor mitigation. HPK is one piece of that puzzle.

### Use Case: High-Cardinality Time-Series Data

IoT telemetry is the other classic case. Imagine tens of thousands of sensors each logging data every second. A single device can blow past the 20 GB logical partition limit within months if you partition by `deviceId` alone. HPK solves this neatly: use `/deviceId` as the first level and `/timestamp` (at date-hour-minute granularity) as the second. Each `deviceId + timestamp` combination stays well under 20 GB, device-scoped queries target only the relevant partitions, and writes distribute naturally because the timestamp is always changing.

We'll evaluate this scenario step by step — comparing partition key candidates in a decision table and walking through the full document model — in the IoT Telemetry walk-through later in this chapter.

<!-- Source: design-partitioning-iot.md -->

### Important HPK Considerations

A few things the docs bury that you should know up front:

**First-level cardinality matters for write-heavy workloads.** Cosmos DB optimizes HPK by co-locating all items with the same first-level key on the same physical partition (until splits happen). If your first level has only 5 distinct values, all your writes are funneled through at most 5 physical partitions — severely limiting throughput. For write-heavy workloads, the first-level key needs at least thousands of unique values.

<!-- Source: hierarchical-partition-keys.md -->

**You can't add HPK to existing containers.** It's a creation-time decision. If you need to switch, create a new container with HPK and migrate your data using container copy jobs.

<!-- Source: hierarchical-partition-keys-faq.md -->

**SDK version requirements exist.** HPK requires .NET SDK ≥ 3.33.0, Java SDK ≥ 4.42.0, JavaScript SDK ≥ 4.0.0, or Python SDK ≥ 4.6.0. Older SDKs can't create or interact with HPK containers.

<!-- Source: hierarchical-partition-keys.md -->

### HPK vs. Synthetic Keys: When to Choose Which

| Factor | HPK | Synthetic Keys |
|--------|-----|----------------|
| Prefix queries | Targeted routing | Full fan-out |
| 20 GB limit | Overcome by full key path | Overcome by differentiator |
| App complexity | Low (SDK handles it) | Medium (you build keys) |
| SDK support | Recent versions required | All versions |
| Query patterns | Left-to-right in hierarchy | Must match exact value |

For most new workloads, HPK is the better choice when you need multi-property partitioning. Use synthetic keys when you're working with older SDKs, need backward compatibility, or when your key structure doesn't naturally form a hierarchy.

## Cross-Partition Queries: Cost Warning and When They're Unavoidable

A **cross-partition query** (also called a fan-out query) is any query that doesn't include the partition key in its filter. Cosmos DB has to send the query to every physical partition, collect the results, and merge them. Each physical partition's index is checked independently — there's no global index.

<!-- Source: how-to-query-container.md -->

The cost: approximately **2.5 RUs of overhead per physical partition** checked, even if that partition returns zero results. For a container with 50 physical partitions, that's 125 RUs of overhead *before* the actual query work.

The latency impact is real too. Although the SDK parallelizes cross-partition queries, the total wall-clock time increases with partition count because you're waiting for the slowest partition to respond.

**When cross-partition queries are unavoidable:**

- **Ad hoc analytics.** Searching across all customers for a specific behavior, or aggregating data across all tenants. These are inherently cross-partition.
- **Secondary access patterns.** Your partition key is `customerId`, but you also need to query by `email` or `productSku`. Without a global secondary index, these are cross-partition.
- **`ORDER BY` across all data.** Sorting results across the entire container requires visiting every partition.

**When they should be avoided:**

- Your hot read path — the query your application runs most frequently — should always be an in-partition or targeted query. If it isn't, your partition key is wrong.
- Don't "accept" cross-partition queries on a container with 30,000+ RU/s or 100+ GB of data without understanding the cost. At that scale, fan-out overhead adds up fast.

Chapter 8 covers cross-partition query mechanics, parallelism tuning, and optimization strategies in depth.

## Partition Merge: Recombining Physical Partitions After Scale-Down

Cosmos DB automatically splits physical partitions as your throughput or data grows. But what about the other direction? If you scaled up throughput for a big data ingestion and then scaled back down, or if you deleted a large volume of data via TTL, you can end up with many physical partitions that are each underutilized — low RU/s per partition, low storage per partition.

**Partition merge** (preview) lets you recombine physical partitions to reverse this fragmentation.

<!-- Source: merge.md -->

### Why Merge Matters

Consider a container where you temporarily scaled to 100,000 RU/s for a data migration, creating 10 physical partitions. After the migration, you scale down to 10,000 RU/s. Each physical partition now gets only 1,000 RU/s — potentially less than your application needs for its hottest partition. Merge lets you consolidate back to fewer physical partitions so each one gets a larger share of the provisioned throughput.

Containers that benefit from merge typically meet both of these conditions:

- Current RU/s per physical partition is **less than 3,000 RU/s**
- Average storage per physical partition is **less than 20 GB**

<!-- Source: merge.md -->

### The Caveats

Partition merge is still in preview, and the constraints are significant:

- **Single-region write accounts only.** Multi-region write isn't supported.
- **SDK version requirements.** When merge is enabled on your account, *all* requests must come from supported SDK versions (.NET ≥ 3.27.0, Java ≥ 4.42.0, Python ≥ 4.14.2, JavaScript ≥ 4.3, or the Cosmos DB Spark connector ≥ 4.18.0). Requests from older SDKs or unsupported connectors are blocked entirely — even requests unrelated to the merge.
- **Feature exclusions.** Accounts using point-in-time restore, customer-managed keys, or per-partition automatic failover can't use merge.
- **It's a long-running operation.** Plan for at least 5–6 hours. Changing container settings (TTL, indexing policy) while a merge is in progress cancels it.

<!-- Source: merge.md -->

Merge is a useful tool for specific situations, but it's not something you'll use routinely. The better strategy is to choose a partition key that distributes data well enough that you don't accumulate empty or underutilized partitions in the first place.

## Real-World Partition Key Walk-Throughs

Theory is useful. Let's apply it.

### IoT Telemetry Platform

**The scenario:** 50,000 sensors across 10 districts, each logging environmental data every second. That's 4.32 billion records per day. Document size is roughly 1 KB.

**Access patterns:**
- Real-time readings for a specific device (high frequency)
- Historical data for a device over a time range (moderate frequency)
- Aggregate readings across a district (low frequency, analytics)

**Evaluating partition key candidates:**

| Candidate | Verdict |
|-----------|---------|
| `/deviceId` | ⚠️ 20 GB limit risk |
| `/districtId` | ❌ Only 10 partitions |
| `/timestamp` (month) | ❌ All writes to one partition |
| Synthetic: `/deviceId` + `/timestamp` | ⚠️ Works, but device reads fan out |
| HPK: `/deviceId` → `/timestamp` | ✅ **Best choice** |

- **`/deviceId`:** Good cardinality (50K) and write distribution, but each device accumulates ~30 GB/year — risking the 20 GB logical partition limit.
- **`/districtId`:** Only 10 distinct values creates 10 hot partitions — terrible write distribution, guaranteed storage limit breach.
- **`/timestamp` (month):** 12 values per year, all current writes funnel to one partition.
- **Synthetic `/deviceId` + `/timestamp`:** Millions of unique values with excellent write distribution, but device-scoped queries require full fan-out since you can't query by prefix.
- **HPK `/deviceId` → `/timestamp`:** Same cardinality and write distribution as synthetic, but device queries target only relevant partitions. Breaks the 20 GB-per-device limit.

<!-- Source: design-partitioning-iot.md -->

The winner is a hierarchical partition key with `/deviceId` as the first level and `/timestamp` (at date-hour-minute granularity) as the second. Device-scoped queries target only the partitions holding that device's data. The 20 GB limit applies to each `deviceId + timestamp` combination, not the device as a whole. Writes distribute across many logical partitions because the timestamp is always changing.

```json
{
  "id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
  "deviceId": "sensor-67890",
  "timestamp": "2025-06-15T09:23",
  "districtId": "district-05",
  "temperature": 22.5,
  "humidity": 55.2,
  "airQualityIndex": 42,
  "noiseLevel": 35
}
```

What about district-level queries? Those are cross-partition by nature. For a real-time dashboard aggregating data across a district, push the data to an analytical store (Azure Synapse Link, Chapter 22) rather than fighting the transactional partition model.

### E-Commerce Catalog

**The scenario:** An online marketplace with 2 million products across 5,000 categories. Products have reviews, pricing, and inventory data.

**Access patterns:**
- Product detail page: load a single product by ID (very high frequency)
- Category browsing: list products in a category, sorted by popularity (high frequency)
- Seller dashboard: show all products for a seller (moderate frequency)
- Search results: filtered by multiple attributes (moderate frequency)

**Document structure:**

```json
{
  "id": "prod-88421",
  "type": "product",
  "categoryId": "cat-electronics-phones",
  "sellerId": "seller-2049",
  "name": "ProPhone X200",
  "price": 899.99,
  "rating": 4.6,
  "reviewCount": 1247,
  "inStock": true,
  "attributes": {
    "brand": "ProTech",
    "color": "midnight blue",
    "storage": "256GB"
  }
}
```

**Evaluating partition key candidates:**

| Candidate | Strength | Risk |
|-----------|----------|------|
| `/id` (product ID) | Point reads: ~1 RU each | Category queries fan out |
| `/categoryId` | Category browsing aligned | Popular categories skew |
| `/sellerId` | Seller dashboard aligned | Mega-seller skew |

- **`/id`:** 2M cardinality with perfect write distribution. Every product detail load is a single-partition point read. But category browsing becomes cross-partition.
- **`/categoryId`:** 5,000 categories gives decent cardinality, but popular categories (e.g., "electronics" with 500K products) create storage and throughput skew.
- **`/sellerId`:** Thousands of sellers, but mega-sellers with large inventories cause the same uneven distribution problem.

For an e-commerce catalog, the dominant access pattern is the product detail page — a point read by `id`. That makes `/id` a strong partition key choice. Every point read is a direct lookup: you know the product ID, and since it *is* the partition key, the read targets a single partition for ~1 RU.

But what about category browsing? That becomes a cross-partition query. For a catalog with only a few physical partitions, this might be acceptable. For a large catalog, you have options:

- **Materialize category views.** Use the change feed (Chapter 15) to maintain a separate container partitioned by `/categoryId` with denormalized product summaries. Writes to the product catalog automatically update the category view.
- **Use a global secondary index (preview).** Create a secondary index partitioned by `/categoryId` that's automatically synchronized with the source container.

The right answer depends on your scale and query volume. For most e-commerce platforms, `/id` as the partition key plus a materialized category view gives you the best of both worlds: cheap point reads on the hot path and efficient category browsing without cross-partition queries.

---

Your partition key is your contract with Cosmos DB's scaling engine. Get it right, and the service works *with* your access patterns — distributing data evenly, routing queries efficiently, and scaling transparently. Get it wrong, and you'll spend months working around hot partitions, throttling, and cross-partition query overhead.

The good news: with hierarchical partition keys, synthetic keys, and the decision framework in this chapter, you have the tools to get it right the first time. The next chapter builds on this foundation, covering advanced data modeling patterns — the item type pattern, TTL, the Patch API — that determine how your documents live and evolve inside the partitions you've just designed.
