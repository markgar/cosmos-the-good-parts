# Chapter 10: Request Units In Depth

Every operation you perform in Cosmos DB has a price tag, and it's denominated in **Request Units**. Chapter 2 introduced RUs as the universal currency of the service. This chapter is where you learn exactly what things cost, how to read the receipt, and how to spend less.

If you treat RUs as an abstract concept — something the service charges but you never inspect — you'll overprovision, overspend, and miss the optimization opportunities hiding in plain sight. The developers who run Cosmos DB cheaply and fast are the ones who know, down to the decimal, what their operations cost and why.

## Breaking Down RU Cost by Operation Type

Not all operations are created equal. A point read and a cross-partition query might both return one document, but their RU costs can differ by orders of magnitude. Understanding the cost hierarchy lets you make informed design choices before you ship code.

### Point Reads: The Cheapest Operation in Cosmos DB

A **point read** is a direct lookup by `id` and partition key. No query engine involved, no index scan — the service goes straight to the correct physical partition and fetches the item. For a 1 KB item, this costs approximately **1 RU**. Chapter 2 introduced that baseline; here's the complete picture of how costs scale and what drives them.

<!-- Source: mslearn-docs/content/throughput-(request-units)/request-units.md -->

The cost scales linearly with item size. A 100 KB item costs roughly 10 RUs to read with default indexing. The table below shows the relationship:

| Item Size | Point Read Cost | Write Cost (indexing off) |
|-----------|----------------|--------------------------|
| 1 KB      | ~1 RU          | ~5 RUs                   |
| 100 KB    | ~10 RUs        | ~50 RUs                  |

<!-- Source: mslearn-docs/content/develop-modern-applications/performance/key-value-store-cost.md -->

These numbers assume default automatic indexing is turned off. With indexing on (the default), writes cost more because the engine must update index entries for every indexed property. Reads aren't affected by indexing policy — the cost is the same whether the item's properties are indexed or not.

One more factor: **consistency level**. If your account uses strong or bounded staleness consistency, reads cost approximately **2x** the RUs compared to session, consistent prefix, or eventual consistency. That's because the service must confirm the read against the quorum. For most applications using session consistency (the default), this isn't a concern — but if you've configured strong consistency, factor in the doubled read cost.

<!-- Source: mslearn-docs/content/throughput-(request-units)/request-units.md -->

### Writes: Creates, Replaces, Upserts, and Deletes

Write operations — creates, replaces, upserts, and deletes — are more expensive than reads. The cost depends on three things: the item's size, the number of properties being indexed, and the total number of indexed properties.

For a 1 KB item with default indexing turned off, a write costs roughly **5 RUs**. Turn default indexing on (which indexes every property), and that number climbs based on how many properties the item has and how deeply nested they are. A real-world document with 20–30 properties and a couple of nested objects might cost 10–15 RUs to write at 1 KB. A 10 KB document with rich nested arrays could cost 50+ RUs.

<!-- Source: mslearn-docs/content/throughput-(request-units)/request-units.md, key-value-store-cost.md -->

The key insight: **writes are where indexing policy pays for itself — or bleeds you dry.** If you're writing documents with 50 properties but only ever query on 5 of them, you're paying to index 45 unused paths on every single write. Chapter 9 covers how to trim your indexing policy; this chapter just wants you to understand why it matters for RU cost.

Upserts cost the same as a create when the item doesn't exist, and the same as a replace when it does. There's no penalty for choosing upsert over create-or-replace — it's the same work server-side.

Deletes cost roughly the same as other write operations — approximately 5 RUs for a 1 KB item with default indexing off. The docs categorize deletes alongside inserts, replaces, and upserts as writes, and they're priced accordingly.

<!-- Source: mslearn-docs/content/develop-modern-applications/performance/key-value-store-cost.md -->

### Queries: The Cost Spectrum

Queries occupy a wide cost spectrum. A targeted single-partition query that returns one document from an indexed property might cost 3 RUs. A cross-partition query scanning thousands of documents across dozens of physical partitions could cost thousands.

The factors that drive query cost:

| Factor | RU Impact |
|--------|-----------|
| **Partitions touched** | More partitions = higher cost |
| **Docs scanned vs. returned** | Pay for all scanned docs |
| **Result set size** | Larger results cost more |
| **Query complexity** | Aggregates, sorts, joins add cost |
| **Round trips (pages)** | Each page charges separately |

- **Partitions:** Cross-partition queries fan out to every physical partition, each incurring its own RU cost.
- **Scanned docs:** If the query scans 10,000 documents to return 10, you pay for all 10,000. The **index hit ratio** tells you how efficiently the index narrowed candidates.
- **Result size:** The service reads and serializes more bytes for larger payloads — 100 KB costs more than 1 KB.
- **Complexity:** Aggregations (`COUNT`, `SUM`, `AVG`), cross-partition `ORDER BY`, `DISTINCT`, and joins all add compute overhead.
- **Pagination:** Large result sets are paginated. Each page is a separate round trip with its own RU charge; total cost is the sum across all pages.

<!-- Source: mslearn-docs/content/throughput-(request-units)/request-units.md, query-metrics.md -->

**Why cross-partition queries cost more.** When you issue a query without a partition key in the `WHERE` clause, the SDK sends it to every physical partition in parallel. Each partition searches its local index, returns its results, and the SDK merges them client-side.

If you have 20 physical partitions, you're running 20 mini-queries. Even if 19 of them return zero results, each still costs a minimum RU charge. As your container grows and splits into more physical partitions, the cost of cross-partition queries grows with it — even if the data you're querying hasn't changed.

Chapter 8 explains the mechanics of cross-partition queries in detail. Here, the takeaway is simple: **queries with a partition key filter are cheaper, and the gap widens as your container scales.**

One critical property of RU charges: **the same query on the same data always costs the same number of RUs on repeated executions.** RU cost is deterministic. That's what makes the budgeting workflow in the next section possible — you can measure a representative set of operations during development, multiply by expected volume, and arrive at a reliable capacity estimate. Without determinism, capacity planning would be guesswork.

<!-- Source: mslearn-docs/content/throughput-(request-units)/request-units.md -->

### Stored Procedures and Triggers

Stored procedures and triggers execute server-side JavaScript within the database engine. Their RU cost is the sum of every database operation they perform internally (reads, writes, queries) plus a small overhead for the JavaScript runtime itself.

<!-- Source: mslearn-docs/content/develop-modern-applications/server-side-programming/stored-procedures-triggers-udfs.md -->

Because everything runs server-side, stored procedures eliminate the network round-trip latency between your client and the database for each internal operation — a significant win when you're batching dozens of writes in a single call. But stored procedures can also consume RUs fast. A procedure that loops through hundreds of items, updating each one, can burn through your partition's throughput budget in a single invocation. If it hits the provisioned throughput limit, it gets rate-limited just like any other request.

Stored procedures also have a **5-second timeout**. If the procedure doesn't finish within that window, the entire transaction is rolled back. That means your procedure must be designed to complete within that window — large or unbounded loops risk timeout and rollback. Between the timeout and the RU consumption, stored procedures work best for write-heavy batch operations on a small, bounded set of items within a single logical partition.

<!-- Source: mslearn-docs/content/develop-modern-applications/server-side-programming/stored-procedures-triggers-udfs.md -->

> **Gotcha:** Stored procedures are scoped to a single logical partition key. You cannot execute a stored procedure across multiple partition keys. If your batch spans partitions, you'll need to use transactional batch operations from the SDK instead.

## Finding the RU Charge for Any Operation

You can't optimize what you don't measure. Every response from Cosmos DB includes the RU charge for that operation. Here's how to read it.

### Response Headers: The x-ms-request-charge Header

Every Cosmos DB response — whether it's a point read, a write, a query page, or a stored procedure execution — includes an `x-ms-request-charge` header with the RU cost of that operation. The SDKs expose this through typed properties so you don't have to parse raw HTTP headers.

<!-- Source: mslearn-docs/content/develop-modern-applications/operations-on-containers-and-items/find-request-unit-charge.md -->

Here's the quick version — every SDK response exposes the charge:

```csharp
ItemResponse<Product> response = await container.ReadItemAsync<Product>(
    "product-42", new PartitionKey("electronics"));
Console.WriteLine($"Point read cost: {response.RequestCharge} RUs");
```

<!-- Source: mslearn-docs/content/develop-modern-applications/operations-on-containers-and-items/find-request-unit-charge.md -->

Chapter 7 covers reading RU charges across all SDKs (C#, Python, JavaScript, Java) in detail, including the pattern for accumulating per-page costs on paginated queries. Here, the point is: **log the RU charge for your critical operations during development.** It's the single most useful number for understanding your cost profile.

### Azure Portal: Query Stats

The quickest way to check a query's RU cost without writing code is the Data Explorer in the Azure portal. Run your query, then click **Query Stats** beneath the results. You'll see the request charge, the number of documents retrieved, the index hit ratio, and the round trip count.

This is great for ad hoc exploration and debugging. For production monitoring, you'll want the metrics and diagnostic logs covered in Chapter 18.

### Azure Monitor Metrics

For ongoing visibility, Azure Monitor exposes the **Total Request Units** metric for your Cosmos DB account. You can split this metric by operation type, database, container, status code, or region to see exactly where your RUs are going. The **Normalized RU Consumption** metric (0–100%) shows how close each physical partition is to its throughput ceiling — invaluable for spotting hot partitions before they cause throttling.

<!-- Source: mslearn-docs/content/manage-your-account/monitor/use-azure-monitor-metrics/monitor-request-unit-usage.md, monitor-normalized-request-units.md -->

We'll cover the monitoring dashboard setup in Chapter 18. For now, know that these metrics exist and that you should be watching them from day one.

## RU Budgeting for Your Application

Once you know what individual operations cost, you can build a budget. RU budgeting is the process of estimating your total RU/s requirement based on your workload profile — how many of each operation type you expect per second, at peak.

The formula is straightforward:

```
Total RU/s = Σ (operations per second × RU cost per operation)
```

For example, an e-commerce product catalog service might have this profile at peak:

| Operation | Ops/sec x RU | RU/s |
|-----------|-------------:|-----:|
| Point reads (by ID) | 500 x 2 | 1,000 |
| Single-partition queries | 50 x 8 | 400 |
| Cross-partition search | 10 x 45 | 450 |
| Product upserts | 20 x 12 | 240 |
| **Total** | | **2,090** |

You'd provision at least 2,100 RU/s to handle this peak — or use autoscale if traffic is variable. Chapter 11 walks through the capacity models and how to choose between manual provisioned throughput, autoscale, and serverless.

### The Capacity Calculator

Microsoft provides an online **Capacity Calculator** at [cosmos.azure.com/capacitycalculator](https://cosmos.azure.com/capacitycalculator/) that helps you estimate RU/s and cost. You plug in your expected item sizes, operation volumes, number of regions, consistency level, and indexing policy. It gives you an RU/s estimate and a monthly cost projection.

<!-- Source: mslearn-docs/content/throughput-(request-units)/provisioned-throughput/estimate-ru-with-capacity-planner.md -->

The calculator has two modes:

- **Basic mode** uses default settings for indexing and consistency. Good for quick, back-of-envelope estimates.
- **Advanced mode** lets you upload a sample JSON document, customize indexing policy, and adjust consistency. Use this when you're planning a real deployment.

The calculator is a starting point, not a contract. Real workloads are spikier and more varied than any estimate. The right approach: estimate with the calculator, provision conservatively, then measure actual RU consumption in production and adjust. The monitoring tools in Chapter 18 close that feedback loop.

### Multi-Region Cost Multiplier

One detail that catches people off guard: if you provision *R* RU/s on a container and your account has *N* regions, Cosmos DB provisions *R* RU/s **in each region**. The total RU/s available globally is R × N — and you're billed for all of it.

<!-- Source: mslearn-docs/content/throughput-(request-units)/request-units.md -->

A container provisioned at 10,000 RU/s across 3 regions uses 30,000 RU/s for billing purposes. This is by design — each region gets its own full throughput allocation so that local reads and writes are fast everywhere. But it means your multi-region bill is a straight multiple of the single-region cost. Factor this in when budgeting.

## Strategies to Reduce RU Consumption

You've measured your costs and built a budget. Now let's shrink it. These strategies are ranked roughly by impact — the ones at the top tend to save the most RUs for the least effort.

### Prefer Point Reads Over Queries for Known IDs

This is the single highest-leverage optimization available to you. If you know the `id` and partition key of the item you want, **use a point read, not a query**. A point read on a 1 KB document costs ~1 RU. A `SELECT * FROM c WHERE c.id = 'xyz'` query on the same document costs at least 2.8 RUs — and more if it's cross-partition.

Many applications use queries by habit where point reads would work. Any time your code does `SELECT * FROM c WHERE c.id = @id AND c.partitionKey = @pk`, you're paying a query tax for no reason. Replace it with `ReadItemAsync` (or your SDK's equivalent) and you'll cut the cost by half or more.

### Optimize Query Predicates and Avoid Full Scans

When you do need queries, make them efficient:

- **Include the partition key in the WHERE clause.** This turns a cross-partition fan-out into a single-partition query, eliminating the per-partition overhead from every partition you're not interested in.
- **Use equality filters on indexed properties.** `WHERE c.status = 'active'` is cheaper than `WHERE c.status != 'inactive'` because the former can use the index directly.
- **Avoid queries with no filter at all.** `SELECT * FROM c` scans every document in the container (or partition). You pay for every document scanned, whether you need it or not.
- **Watch the index hit ratio.** If your query's index hit ratio (visible in Query Stats) is low — say 10% — it means the engine is scanning 10x more documents than it returns. That's a sign your query predicates don't align with your indexing policy.

Chapter 8 covers query optimization techniques in depth. Chapter 9 explains how to configure your indexing policy to support your query patterns.

### Use Projections to Fetch Only Needed Fields

`SELECT *` is easy to write and expensive to execute. If you only need three fields from a 50-property document, use a projection:

```sql
SELECT c.id, c.name, c.price FROM c WHERE c.category = 'electronics'
```

Projections reduce the **result set size**, which means fewer bytes to read, serialize, and transmit. The RU savings scale with the ratio of projected fields to total document size. For small documents, the difference is marginal. For documents with large nested objects or arrays that you don't need, projections can cut query cost significantly.

### Tune Indexing to Exclude Unused Paths

By default, Cosmos DB indexes every property at every nesting level of every document. That's great for query flexibility but expensive for writes. If your documents have properties you never query or filter on — audit metadata, large description blobs, internal tracking fields — excluding them from the index reduces write RU cost.

<!-- Source: mslearn-docs/content/develop-modern-applications/performance/indexing/index-policy.md -->

A custom indexing policy that includes only the paths you actually query can substantially reduce the latency and RU charge of write operations. The tradeoff: if you later need to query on an excluded path, you'll have to update the policy and wait for reindexing.

Chapter 9 is the canonical reference for indexing policy configuration — include/exclude paths, composite indexes, and the mechanics of how indexes affect both reads and writes. From an RU perspective, the key principle is: **every indexed path adds cost to every write. Only index what you query.**

### Use the Patch API for Partial Updates

When you need to update a single field on a document — say, incrementing an inventory count or toggling a status flag — the traditional approach is a read-modify-write cycle: read the full document, change the field client-side, then replace the entire document. That's two operations (a read and a full write) with the full document transmitted over the wire both ways.

The **Patch API** lets you send just the change — an increment, a set, a remove — without reading or replacing the entire document. It's a single operation, and you avoid sending the full document payload over the network.

<!-- Source: mslearn-docs/content/develop-modern-applications/operations-on-containers-and-items/partial-document-update/partial-document-update.md -->

A quick example — incrementing a quantity field:

```csharp
List<PatchOperation> patchOps = new()
{
    PatchOperation.Increment("/inventory/quantity", 10),
    PatchOperation.Set("/lastUpdated", DateTime.UtcNow)
};

ItemResponse<Product> response = await container.PatchItemAsync<Product>(
    id: "product-42",
    partitionKey: new PartitionKey("electronics"),
    patchOperations: patchOps
);
Console.WriteLine($"Patch cost: {response.RequestCharge} RUs");
```

A note of honesty: the Patch API's RU cost per operation isn't dramatically lower than a replace. The FAQ states that "users shouldn't expect a significant reduction in RU."

The real savings come from **eliminating the read** in the read-modify-write cycle and from sending less data over the network. For large documents where you're changing one field, that's a meaningful win in both RUs (you skip the read) and latency. For small documents, the improvement is modest.

<!-- Source: mslearn-docs/content/develop-modern-applications/operations-on-containers-and-items/partial-document-update/partial-document-update-faq.md -->

Patch operations are limited to **10 operations per call**. Chapter 6 covers the full Patch API surface — supported operations, conditional patches, and real-world patterns.

### Quick Reference: RU Optimization Tactics

| Tactic | Impact | Effort |
|--------|--------|--------|
| Use point reads over queries | High (2-5x cheaper) | Low |
| Add partition key to WHERE | High (no fan-out) | Low |
| Project specific fields only | Medium | Low |
| Exclude unused index paths | Medium (every write) | Low-Med |
| Patch instead of read-modify-write | Medium (skip the read) | Low |
| Add composite indexes | Medium (skip sorts) | Medium |
| Trim document size | Medium (reads + writes) | Med-High |

## Priority-Based Execution

Not all requests deserve equal treatment. A user browsing your product catalog should never get throttled because a background data migration is consuming all your RU/s. **Priority-based execution** lets you tag requests as high or low priority so Cosmos DB knows which ones to protect when demand exceeds supply.

> **Note:** Priority-based execution is a **preview feature** and is subject to change. There are no SLAs linked to its performance, and it operates on a best-effort basis. Plan accordingly before relying on it in production.

<!-- Source: mslearn-docs/content/throughput-(request-units)/priority-based-execution-(preview)/priority-based-execution.md -->

### How It Works

When priority-based execution is enabled and total RU consumption on a container exceeds the provisioned RU/s, Cosmos DB throttles low-priority requests first, preserving capacity for high-priority ones. If there's headroom in the budget, both priorities execute normally — the feature only kicks in under contention.

There are exactly **two priority levels**: High and Low. By default, all requests are **High** priority. You opt specific workloads *down* to Low priority, not the other way around.

<!-- Source: mslearn-docs/content/throughput-(request-units)/priority-based-execution-(preview)/priority-based-execution-faq.md -->

A few important details:

- **No RU reservation.** Priority-based execution doesn't carve out a portion of RU/s for high-priority requests. All provisioned RU/s are available to any request. The feature only affects behavior when demand exceeds supply.
- **Best-effort, no SLA.** The docs are explicit: there's no SLA guaranteeing that low-priority requests are always throttled before high-priority ones. It operates on a best-effort basis.
- **Not supported for serverless accounts.** You need provisioned or autoscale throughput.
- **Free.** No additional cost to enable or use this feature.

### Enabling and Using Priority-Based Execution

Enable the feature from the **Features** page in your Cosmos DB account in the Azure portal. Then tag requests in your SDK code:

**C#**
```csharp
// High priority — user-facing product lookup
ItemRequestOptions highPriority = new() { PriorityLevel = PriorityLevel.High };
ItemResponse<Product> product = await container.ReadItemAsync<Product>(
    "product-42", new PartitionKey("electronics"), highPriority
);

// Low priority — background catalog sync
ItemRequestOptions lowPriority = new() { PriorityLevel = PriorityLevel.Low };
ItemResponse<Product> syncResponse = await container.CreateItemAsync(
    newProduct, new PartitionKey("electronics"), lowPriority
);
```

**Python**
```python
# High priority
item = container.read_item("product-42", partition_key="electronics", priority="High")

# Low priority
container.create_item(body=new_product, priority="Low")
```

<!-- Source: mslearn-docs/content/throughput-(request-units)/priority-based-execution-(preview)/priority-based-execution.md -->

### SDK Version Requirements

| SDK | Minimum Version |
|-----|----------------|
| .NET v3 | 3.38.0 |
| Java v4 | 4.45.0 |
| JavaScript v4 | 4.0.0 |
| Python | 4.6.0 (preview) |

<!-- Note: The docs list v4.5.2b2 in the requirements table but v4.6.0 in the Python code sample. We use v4.6.0 as the safer minimum. -->

<!-- Source: mslearn-docs/content/throughput-(request-units)/priority-based-execution-(preview)/priority-based-execution.md -->

### When to Use It

The pattern is straightforward: **anything user-facing gets high priority; everything else gets low.** Typical low-priority candidates:

- Background data ingestion and migration jobs
- Stored procedure executions for maintenance tasks
- Materialized view rebuilds
- Analytics queries that aren't latency-sensitive
- Change feed processors doing secondary indexing

You can also flip the default. If most of your workload is background processing and only a small slice is user-facing, set the account's default priority to Low using Azure CLI, then explicitly tag the user-facing requests as High:

```azurecli
az cosmosdb update \
  -g my-resource-group \
  -n my-cosmos-account \
  --enable-priority-based-execution true \
  --default-priority-level low
```

> **Gotcha:** When priority-based execution is enabled, the Azure portal's Data Explorer runs with **low** priority by default. If you're troubleshooting a throttled container and wondering why your portal queries are slow, that's why. You can change it in the Data Explorer's Settings menu.

<!-- Source: mslearn-docs/content/throughput-(request-units)/priority-based-execution-(preview)/priority-based-execution.md -->

### Limitations

Priority-based execution has non-deterministic behavior for shared throughput database containers (where multiple containers share database-level RU/s). It also doesn't work well for read prioritization with strong or bounded staleness consistency — low-priority write requests may execute even when there's contending high-priority read traffic under those consistency levels.

<!-- Source: mslearn-docs/content/throughput-(request-units)/priority-based-execution-(preview)/priority-based-execution.md -->

Now you know what operations cost and how to spend less. The next question is *how you pay* — whether you pre-commit to a fixed RU/s budget, let the service scale for you, or go pure pay-per-request. Chapter 11 covers provisioned throughput, autoscale, and serverless — the three capacity models that turn your RU knowledge into a billing strategy.
