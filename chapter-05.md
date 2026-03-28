# Chapter 5: Partition Keys — The Most Important Decision You'll Make

Every distributed database has a mechanism for deciding where data lives. In Azure Cosmos DB, that mechanism is the **partition key** — and choosing the right one is the single most consequential design decision you'll make for your application. A good partition key unlocks near-limitless scale, sub-millisecond reads, and cost-efficient throughput. A bad one creates hot spots, throttling, and a ceiling you can't raise without migrating your data to an entirely new container.

This chapter gives you the mental model to get it right the first time.

## How Partitioning Works Under the Hood

Before you can choose a good key, you need to understand the two-level system Cosmos DB uses to organize your data (see Chapter 2 for a refresher on logical and physical partitions).

### Logical Partitions

A **logical partition** is the set of all items that share the same partition key value. If your container uses `/customerId` as its partition key and you have 50,000 customers, you have 50,000 logical partitions — one per customer.

Logical partitions are the unit of transactional scope. Stored procedures, triggers, and transactional batch operations all execute within a single logical partition. You cannot span a transaction across two different partition key values.

The critical limit here: **each logical partition can store up to 20 GB of data**. There is no limit on the *number* of logical partitions in a container, but any single partition key value cannot exceed that 20 GB ceiling.

### Physical Partitions

Behind the scenes, Cosmos DB maps your logical partitions onto **physical partitions** — the actual compute and storage units managed by the service. You don't create or manage physical partitions directly; Cosmos DB handles them transparently.

Each physical partition has hard limits:

- **Up to 50 GB of storage**
- **Up to 10,000 RU/s of throughput**

Multiple logical partitions can (and typically do) live on the same physical partition. When a physical partition runs out of room — either because storage exceeds 50 GB or throughput demand warrants it — Cosmos DB automatically **splits** it, redistributing logical partitions across the new physical partitions without any downtime.

Provisioned throughput is divided **evenly** across all physical partitions. If you provision 30,000 RU/s and your container has three physical partitions, each one gets 10,000 RU/s. This is the root cause of hot partition problems — if 80% of your traffic targets data on one physical partition, the other two partitions' allocated throughput goes to waste while the hot one throttles.

## Properties of a Good Partition Key

Choosing a partition key means balancing three properties. A great key nails all three; a good key nails at least two.

### High Cardinality

Your partition key should have a **wide range of distinct values** — hundreds, thousands, or millions. High cardinality means your data spreads across many logical partitions, which in turn spread across many physical partitions. This gives Cosmos DB room to distribute load.

Think about an e-commerce application with three candidate keys:

| Candidate Key | Distinct Values | Cardinality |
|---|---|---|
| `/categoryId` | ~50 product categories | Low |
| `/customerId` | ~500,000 customers | High |
| `/orderId` | ~10,000,000 orders | Very High |

With `/categoryId`, you have at most 50 logical partitions. One popular category like "Electronics" could easily dominate both storage and throughput, creating a hot partition. With `/customerId` or `/orderId`, you have far more values to spread data across.

### Even Write Distribution

High cardinality is necessary but not sufficient. You also need your **write traffic to be evenly distributed** across those values. If 90% of your writes target a single customer (say, a batch import job for one large enterprise tenant), having 500,000 unique customer IDs doesn't help — that one logical partition still gets hammered.

The 10,000 RU/s physical partition limit means any single partition key value is also capped at 10,000 RU/s, since a logical partition maps to exactly one physical partition. If one value needs more than that, you'll hit throttling no matter how much total throughput you've provisioned.

### Efficient Single-Partition Reads

For read-heavy workloads, you want your most common queries to include the partition key in the `WHERE` clause. This turns a potentially expensive **cross-partition query** into a cheap **single-partition query** that Cosmos DB routes directly to the one physical partition holding your data.

Ask yourself: "What property do I almost always filter by?" If you frequently run `SELECT * FROM c WHERE c.customerId = @id`, then `/customerId` is a strong candidate — your reads go straight to the right partition every time.

### Putting It Together: The E-Commerce Example

For our e-commerce application, let's evaluate the tradeoffs:

- **`/orderId`** — Very high cardinality and perfectly even distribution (one item per partition). Ideal for point reads by order ID. But terrible for "get all orders for customer X" queries, which become expensive cross-partition fan-outs.
- **`/customerId`** — High cardinality, reads by customer are efficient single-partition queries, and most customers have manageable data volumes (well under 20 GB). However, a handful of enterprise customers with millions of orders could create hot partitions.
- **`/categoryId`** — Low cardinality, uneven distribution, creates hot partitions. This is almost never the right choice.

For most e-commerce workloads, **`/customerId`** is the best compromise. Your dominant access pattern ("show me this customer's orders") hits a single partition, cardinality is high, and distribution is reasonably even. For the outlier enterprise tenants, you have escape hatches — hierarchical partition keys or synthetic keys — which we'll cover shortly.

## Partition Key Anti-Patterns and Their Consequences

Understanding what *not* to do is just as important as knowing best practices.

### Hot Partitions and Throughput Throttling

A **hot partition** occurs when a disproportionate share of requests targets a single physical partition. Since throughput is divided evenly across physical partitions, a hot partition hits its 10,000 RU/s ceiling while other partitions sit idle.

Imagine you provision 40,000 RU/s across four physical partitions (10,000 RU/s each). If 70% of your writes hit one partition, that partition needs 28,000 RU/s but only has 10,000. You get HTTP 429 (rate limited) responses while 75% of your provisioned throughput goes unused. You're paying for 40,000 RU/s but can effectively use only about 16,000.

### Sequential IDs and Timestamps

Using a sequentially increasing value — an auto-increment integer, a timestamp, or a date — is one of the most common mistakes developers make.

If your partition key is `/createdDate` and every new item gets today's date, *all* of today's writes funnel into a single logical partition. Yesterday's partition is cold, today's is on fire, and tomorrow's doesn't exist yet. You've created a perpetual hot partition where only the "current" partition key value does any work.

The same applies to sequential IDs. If your values are `1, 2, 3, ... N` and each item has a unique partition key, writes will distribute evenly across physical partitions — but you lose the ability to perform single-partition queries on groups of related items and cannot use transactional batch across items.

**The fix:** If you need to query by time range, use time as part of a synthetic or hierarchical partition key — not as the sole key.

### Low-Cardinality Keys

Using a property with only a handful of values — like `/status` (pending, active, completed) or `/country` (maybe 200 values) — is another anti-pattern. With only three logical partitions for status values, Cosmos DB can never split your data across more than three physical partitions, regardless of how much throughput you provision. You're capping your container's scalability at 30,000 RU/s total (3 partitions × 10,000 RU/s each).

## Synthetic Partition Keys: Combining Properties for Better Distribution

Sometimes no single property in your data makes a good partition key. The solution is to **construct one** by concatenating multiple properties into a synthetic value.

### Concatenating Properties

Suppose you have IoT device telemetry with `deviceId` and `date` fields. Neither is ideal alone — `deviceId` gives you per-device reads but a few high-traffic devices may dominate writes, while `date` gives you a daily hot partition. A synthetic key combines them:

```json
{
  "deviceId": "sensor-42",
  "date": "2024-03-15",
  "partitionKey": "sensor-42-2024-03-15"
}
```

Now your data distributes across (devices × days) logical partitions. The dominant query pattern "give me today's readings for this device" still hits a single partition.

Your application computes this synthetic value before writing each item. It adds a small amount of client-side logic, but the benefits to distribution are significant.

### Random Suffix Strategy

For extreme write-heavy scenarios (like logging or event ingestion), you can append a random number to the partition key:

```
2024-03-15.1, 2024-03-15.2, ... 2024-03-15.400
```

This fans out writes for a single date across 400 logical partitions instead of one. The tradeoff: reading all items for a given date now requires querying across all 400 suffix values.

### Precalculated Suffix Strategy

A smarter variation: instead of a random suffix, compute a hash of a property you'll query on later. For example, hash the `vehicleId` to a number between 1 and 400, and append it to the date:

```
partitionKey = "2024-03-15." + (hash(vehicleId) % 400)
```

Now writes are evenly distributed *and* you can deterministically calculate the partition key when reading a specific vehicle's data for a given date. You get the write distribution of random suffixes without sacrificing read efficiency.

## Hierarchical Partition Keys (Subpartitioning)

Introduced to address the limitations of single-value partition keys, **hierarchical partition keys** let you define up to **three levels** of partition key hierarchy. Cosmos DB uses these levels to create a tree of subpartitions, enabling individual tenants or entities to exceed the 20 GB logical partition limit.

### How They Work

Instead of specifying a single path like `/customerId`, you define an ordered list of paths:

```csharp
List<string> subpartitionKeyPaths = new List<string> {
    "/TenantId",
    "/UserId",
    "/SessionId"
};

ContainerProperties containerProperties = new ContainerProperties(
    id: "events",
    partitionKeyPaths: subpartitionKeyPaths
);
```

Cosmos DB uses `MultiHash` partitioning under the hood. The key insight is that queries specifying a **prefix** of the hierarchy are efficiently routed to only the relevant physical partitions. A query filtering on just `TenantId` doesn't fan out to all 1,000 physical partitions — it targets only the subset that actually holds that tenant's data.

### Use Case: Multi-Tenant Applications

Hierarchical keys were designed with multi-tenancy in mind. Consider a SaaS platform where:

- You partition first by `/tenantId` — queries for a specific tenant's data are efficient.
- Large tenants can exceed 20 GB because Cosmos DB subpartitions within that tenant by `/userId`.
- If even a single user within a large tenant generates massive data, the third level (`/sessionId`) provides further subdivision.

Without hierarchical keys, you'd face an impossible choice: partition by `/tenantId` and risk the 20 GB limit for large tenants, or partition by `/userId` and make every tenant-scoped query a cross-partition fan-out. Hierarchical keys eliminate this tradeoff.

### Use Case: High-Cardinality Time-Series Data

For time-series workloads like IoT telemetry or application logging, a hierarchical key of `/deviceId` → `/year` → `/month` works well:

- Queries for a specific device's data route to a small set of physical partitions.
- Within a device, data is further subdivided by time, preventing any single device from becoming a hot partition.
- A device that generates terabytes of data over years can scale beyond 20 GB seamlessly.

This is a cleaner alternative to the synthetic key approach for time-series data, since you don't need to compute and manage a concatenated value client-side.

### When Not to Use Hierarchical Keys

Hierarchical keys aren't a universal upgrade. If your first-level key has **low cardinality** (say, only 5 tenants), all writes for a given tenant are initially scoped to a single physical partition until it accumulates enough data (50 GB) to trigger a split. For write-heavy ingestion scenarios with few first-level values, this can bottleneck you at 10,000 RU/s per tenant during the initial load.

The rule of thumb: your first-level key should have high cardinality (at least thousands of distinct values) for write-heavy workloads. For read-heavy workloads with occasional writes, lower cardinality at the first level is acceptable.

## Cross-Partition Queries: When They're Unavoidable and How to Tame Them

A **cross-partition query** is any query whose `WHERE` clause doesn't include the partition key. Without knowing which partition holds the relevant data, Cosmos DB must **fan out** the query to every physical partition, execute it in parallel, and merge the results.

### The Cost

Cross-partition queries aren't forbidden — they're just more expensive:

- The query runs independently against each physical partition's index, then results are merged.
- The RU cost scales with the number of physical partitions. Each additional physical partition adds overhead to the query's RU cost (the exact amount depends on query complexity and data distribution).
- Latency increases because the overall response time is bounded by the slowest partition.

For a container with 5 physical partitions, the overhead is negligible. For a container with 500 physical partitions, a cross-partition query that would cost 5 RU as a single-partition query might cost 1,000+ RU.

### Strategies to Minimize Cross-Partition Queries

1. **Choose your partition key based on your dominant query pattern.** If 80% of your reads filter by `customerId`, make that your partition key.

2. **Include the partition key in queries wherever possible.** Even if you're also filtering by other fields, adding the partition key to the `WHERE` clause turns a cross-partition query into a targeted one.

3. **Use hierarchical partition keys for prefix matching.** If you partition by `/tenantId/userId/sessionId`, a query filtering on just `/tenantId` routes only to that tenant's physical partitions — not all partitions in the container.

4. **Consider global secondary indexes (preview).** If your workload has multiple distinct query patterns that can't be served by a single partition key, global secondary indexes let you create additional copies of your data with different partition keys, each optimized for a specific access pattern. The tradeoff is additional storage and RU cost, and the secondary index data is eventually consistent with the source.

5. **Denormalize and duplicate.** Store the same data in multiple containers with different partition keys, each optimized for a specific query pattern. This is a manual version of what global secondary indexes automate. You trade storage cost for query efficiency.

### When Cross-Partition Queries Are Acceptable

Not every cross-partition query is a crisis. They're perfectly fine when:

- Your container has a small number of physical partitions (fewer than 5–10).
- The query runs infrequently (analytics, admin dashboards, nightly reports).
- You're using them for background processes where latency isn't critical.

The goal isn't to eliminate cross-partition queries entirely — it's to ensure your **hot path** (the queries that run thousands of times per second) targets single partitions.

## Partition Merge: Recombining Physical Partitions

Cosmos DB automatically splits physical partitions as your data and throughput grow. But what happens when you scale *down*? After a large data migration, you might have provisioned 100,000 RU/s (creating 10+ physical partitions), then scaled back to 5,000 RU/s for steady state. Now each physical partition gets a tiny slice of your throughput — perhaps only 500 RU/s each — and you're more likely to hit per-partition rate limits even though total throughput should be sufficient.

**Partition merge** (currently in preview) solves this by allowing Cosmos DB to **recombine physical partitions**, reducing their count so that each one gets a larger share of provisioned throughput.

### When to Consider Merge

Your container is a good candidate for merge when:

- **RU/s per physical partition is below ~3,000 RU/s** — typically after scaling down from a peak.
- **Average storage per physical partition is under ~20 GB** — often after bulk deletion or TTL expiration clears out data.

For example, you scaled to 50,000 RU/s for a one-time data migration, creating 10 physical partitions. After migration, you dropped to 4,000 RU/s. Each partition now has only 400 RU/s — well below the 10,000 RU/s capacity. A single burst of activity on one partition could trigger throttling. Merging those 10 partitions down to 2 gives each partition 2,000 RU/s, dramatically reducing throttling risk.

### How to Trigger a Merge

Merge is initiated through PowerShell or Azure CLI, not automatically. You can preview the result before committing:

```powershell
# Preview the merge (no changes made)
Invoke-AzCosmosDBSqlContainerMerge `
    -ResourceGroupName "myResourceGroup" `
    -AccountName "myCosmosAccount" `
    -DatabaseName "myDatabase" `
    -Name "myContainer" `
    -WhatIf

# Execute the merge
Invoke-AzCosmosDBSqlContainerMerge `
    -ResourceGroupName "myResourceGroup" `
    -AccountName "myCosmosAccount" `
    -DatabaseName "myDatabase" `
    -Name "myContainer"
```

### Limitations to Know

Partition merge is a preview feature with important constraints:

- Available only for **single-write-region** accounts using the **NoSQL or MongoDB API**.
- Requires specific SDK versions (.NET ≥ 3.27.0, Java ≥ 4.42.0, JavaScript ≥ 4.3.0, Python ≥ 4.14.2). Older SDKs are **blocked entirely** while the feature is enabled.
- Not compatible with point-in-time restore, customer-managed keys, or per-partition automatic failover.
- Merge is a long-running operation — plan for at least 5–6 hours and avoid changing container settings while it runs.

Merge is a powerful tool, but treat it as an operational procedure rather than an everyday feature. Plan your partition key well upfront, and you'll rarely need it.

## Choosing a Partition Key: A Decision Framework

When you're staring at your data model and aren't sure where to start, work through these questions:

1. **What is your most common query filter?** That property is your starting candidate.
2. **Does it have high cardinality?** If not, can you combine it with another property (synthetic key) or use hierarchical keys?
3. **Is write volume evenly distributed across its values?** If a few values dominate writes, you'll create hot partitions.
4. **Will any single value exceed 20 GB?** If so, consider hierarchical partition keys.
5. **Is the value immutable?** Partition key values cannot be updated — you'd have to delete and recreate the item.

Remember: once you set a partition key, **you can't change it** without migrating to a new container (using container copy jobs or manual migration). Getting this decision right upfront saves you from a painful data migration later.

## What's Next

You now understand how partition keys shape the performance, scalability, and cost profile of your Cosmos DB containers. In **Chapter 6**, we'll build on that foundation with **advanced data modeling patterns** — the item type pattern for colocating entities, TTL for automatic data expiration, the Patch API for surgical updates, optimistic concurrency with ETags, and strategies for modeling hierarchical structures, many-to-many relationships, and event-sourced architectures.
