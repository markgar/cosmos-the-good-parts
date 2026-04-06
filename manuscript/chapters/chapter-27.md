# Chapter 27: Performance Tuning and Best Practices

Your Cosmos DB application works. It passes tests, handles happy-path requests, and the demo went well. Now you need it to be *fast* — consistently, under load, in production. That's a different problem entirely. Performance tuning in Cosmos DB isn't about tweaking a single knob; it's a disciplined loop of measurement, identification, optimization, and validation. This chapter is the applied playbook.

## The Performance Tuning Loop

Every performance investigation follows the same cycle:

1. **Measure.** Collect baseline metrics — RU consumption, latency percentiles, 429 rates, normalized RU consumption per partition.
2. **Identify.** Find the bottleneck. Is it a hot partition? An expensive query? A bloated document? An SDK misconfiguration?
3. **Optimize.** Apply the targeted fix from the sections that follow.
4. **Validate.** Re-measure. Confirm the fix moved the numbers in the right direction without introducing regressions.

Then repeat. Performance tuning is iterative, not a one-shot exercise.

The metrics you need for step 1 come from Azure Monitor — the same dashboards and diagnostic logs covered in Chapter 18. The RU analysis techniques from Chapter 10 tell you *what* each operation costs. This chapter focuses on steps 2 and 3: finding the problem and fixing it.

## Choosing Direct Connectivity Mode for Lowest Latency

Chapter 7 introduced the two SDK connection modes. Here's where the choice actually matters for production performance.

<!-- Source: develop-modern-applications/sdk-connection-modes.md -->

**Gateway mode** routes every request through an HTTPS gateway endpoint. It's simple — one DNS name, port 443, works through corporate firewalls. The tradeoff is an extra network hop on every read and write. The gateway server fans out your request to the appropriate backend partition, adding latency.

**Direct mode** opens TCP connections straight to the backend replica sets. Your client talks directly to the partition that holds your data, with no intermediary. Fewer hops means lower latency — it's that simple.

| Characteristic | Gateway | Direct |
|---|---|---|
| **Protocol** | HTTPS | TCP (TLS) |
| **Hops** | Client → GW → Partition | Client → Partition |
| **SDK support** | All SDKs | .NET and Java |
| **Ports** | 443 only | 10000–20000 range |

- **Direct mode ports:** 10000–20000 for public endpoints; 0–65535 for private endpoints.
- **Best for gateway:** firewall-restricted environments, Azure Functions Consumption plan.
- **Best for direct:** production workloads where latency matters.

<!-- Source: develop-modern-applications/sdk-connection-modes.md -->

Direct mode is the default in the .NET SDK v3 and the recommended choice for the Java SDK v4. If you're on Python or JavaScript, you're on gateway mode — there's no direct mode option for those SDKs today. <!-- Source: develop-modern-applications/sdk-connection-modes.md -->

### How Direct Mode Connections Work

When the SDK operates in direct mode, it first fetches container metadata and routing information from a gateway node — this tells it which physical partitions exist and what their TCP addresses are. Then it opens persistent TCP connections directly to the replica sets. Each physical partition has four replicas (one primary, three secondaries). Writes go to the primary; reads can be served from any replica. <!-- Source: develop-modern-applications/sdk-connection-modes.md -->

These connections are cached and reused across operations. The SDK refreshes routing information only when replicas move (maintenance, upgrades, partition splits), so the gateway overhead is a one-time cost, not per-request.

The number of TCP connections scales with your partition count. In steady state, expect roughly one connection per replica per physical partition — so a container with 10 physical partitions opens around 40 connections. High-concurrency workloads may open additional connections when concurrent requests exceed the per-connection threshold. <!-- Source: develop-modern-applications/sdk-connection-modes.md -->

### When to Stick with Gateway Mode

Use gateway mode when your environment restricts outbound TCP ports to 443 only, when you're running in Azure Functions on the Consumption plan with strict connection limits, or when you're using the Python or JavaScript SDKs (which don't support direct mode). For everything else — especially latency-sensitive .NET or Java workloads — use direct mode. <!-- Source: develop-modern-applications/sdk-connection-modes.md -->

## Optimizing Document Size and Structure

Chapter 4 covered data modeling principles. Here's the performance angle: **bigger documents cost more RUs**. With automatic indexing turned off, a point read of a 1 KB document costs 1 RU; a 100 KB document costs 10 RUs. Writes follow the same pattern — 5 RUs for a 1 KB write, 50 RUs for 100 KB. Notice that 100× the document size doesn't mean 100× the RU cost — the scaling is sub-linear, not proportional. But don't let that lull you into complacency. With the default indexing policy (everything indexed), write costs climb further because the index must be updated, and those extra RUs compound across every read and write your application performs. <!-- Source: develop-modern-applications/performance/key-value-store-cost.md -->

This means document bloat is a silent cost multiplier. Every unnecessary property, every deeply nested array you never query, every base64-encoded thumbnail you embedded "for convenience" — they all inflate RU charges on every operation that touches the document.

### Practical Trimming Strategies

**Project only the properties you need** — we'll see this in action in the query optimization walk-through below.

**Move large blobs out of Cosmos DB.** Store images, PDFs, and large binary payloads in Azure Blob Storage. Keep a URL reference in your Cosmos DB item. The 2 MB item size limit (Chapter 2) enforces this eventually — you might as well design for it from the start. <!-- Source: manage-your-account/enterprise-readiness/concepts-limits.md -->

**Flatten when you don't need depth.** Every level of nesting increases serialization overhead. If a nested object is always read and written as a unit, consider flattening it into top-level properties. This doesn't apply to arrays of complex types where the nesting *is* the model — it applies to structural nesting that adds no querying value.

**Trim system properties you don't use.** You can't remove `_rid`, `_etag`, or `_ts` from Cosmos DB's response, but you can ignore them during deserialization. More importantly, don't add your own redundant metadata — if `_ts` gives you the last-modified timestamp, you don't need a `lastUpdated` field too.

## Indexing Policy Tuning for Write-Heavy Workloads

By default, Cosmos DB indexes every property of every document. That's great for query flexibility, but it has a cost: every write must update the index for every indexed property. For read-heavy workloads, the default is fine. For write-heavy workloads, targeted index exclusion can meaningfully reduce RU consumption per write. <!-- Source: develop-modern-applications/performance/indexing/index-policy.md -->

Chapter 9 covers indexing policy configuration in detail. Here we focus on the performance trade-off.

### The Include-Everything vs. Exclude-and-Opt-In Strategy

There are two approaches:

| Strategy | Policy Root |
|---|---|
| **Include all, exclude selectively** | `"includedPaths": [{"path": "/*"}]` |
| **Exclude all, include selectively** | `"excludedPaths": [{"path": "/*"}]` |

Use **include-all** for most workloads — exclude only paths you never filter or sort on. Use **exclude-all** for write-heavy workloads with known, narrow query patterns — only index what you actually query.

<!-- Source: develop-modern-applications/performance/indexing/index-policy.md -->

For a write-heavy IoT telemetry container where you only query by `deviceId` and `timestamp`, excluding the root and including just those two paths can cut write RU costs substantially. You're trading query flexibility for write throughput — any query that filters on an excluded path will require a full scan.

```json
{
  "indexingMode": "consistent",
  "includedPaths": [
    { "path": "/deviceId/?" },
    { "path": "/timestamp/?" }
  ],
  "excludedPaths": [
    { "path": "/*" }
  ]
}
```

> **Gotcha:** When you exclude the root path, the partition key property is *not* indexed by default. If your queries filter on the partition key hierarchy, explicitly include those paths — otherwise you'll get full scans with high RU costs even on queries that look like they should be efficient. <!-- Source: develop-modern-applications/performance/indexing/index-policy.md -->

### Indexing Mode: None

For containers used purely as key-value stores — point reads and writes by `id` and partition key, no queries — you can set the indexing mode to `None`. This eliminates all index maintenance overhead. But it's a hard tradeoff: any query against the container will fail unless you explicitly opt into full scans. Reserve this for containers where you're certain you'll never need to query. <!-- Source: develop-modern-applications/performance/indexing/index-policy.md -->

### Use Index Metrics to Validate

Don't guess which indexes matter. Set `PopulateIndexMetrics = true` on your query request options (or the equivalent in your SDK) to get a report of which indexes the query engine used and which potential indexes could improve performance. This tells you exactly which paths to include and which are dead weight. We covered this in Chapter 9 — use it here as part of the tuning loop. <!-- Source: develop-modern-applications/performance/query/query-metrics.md -->

## Query Optimization Walk-Through: From Expensive to Efficient

Chapter 8 taught you the query language. Now let's take an expensive real-world query and systematically make it cheaper.

### The Starting Point

Picture an e-commerce container partitioned by `customerId` using the item type pattern from Chapter 4 — orders, line items, customer profiles, all coexisting in the same container with a `type` discriminator. A developer needs to fetch the line items for a specific order and writes:

```sql
SELECT * FROM c WHERE c.type = "lineItem" AND c.orderId = "order-123"
```

This query *works* — it returns the right documents. But it's expensive for two reasons:

1. **It's a cross-partition query.** There's no `customerId` filter, so the engine fans it out to *every* physical partition, even though every line item for `order-123` lives under a single customer.
2. **It returns entire documents.** `SELECT *` pulls back every property on each line item, including fields the caller doesn't need.

The result: high RU cost, high latency, and a query that gets worse as the container grows.

### Step 1: Add a Partition Key Filter

The application already knows which customer placed this order — it navigated from a customer context to reach this screen. Pass that value into the query:

```sql
SELECT * FROM c
WHERE c.customerId = "cust-337"
  AND c.type = "lineItem"
  AND c.orderId = "order-123"
```

This converts the query from a cross-partition fan-out to a single-partition query. The engine contacts only the one physical partition that holds `cust-337`'s data. RU cost drops dramatically, and latency improves because there's no fan-out coordination overhead.

If your application *doesn't* know the `customerId` when it needs to look up an order's line items, that's a data-modeling signal. You may need to embed line items inside the order document, or maintain a lightweight lookup item that maps `orderId` → `customerId`. Revisit Chapter 4's discussion of embedding vs. referencing — the right model eliminates cross-partition queries at design time.

### Step 2: Ensure the Filter Uses an Index

Adding the partition key got you to the right partition. Now make sure the filter predicates within that partition are index-served. Check that `/type/?` and `/orderId/?` are included in your indexing policy. If either path is excluded, the engine performs a scan within the partition — loading every document belonging to `cust-337` just to evaluate the `WHERE` clause.

You can verify this with index metrics. Set `PopulateIndexMetrics = true` on your query request options to see exactly which indexes were used. Look for `IndexHitRatio` in the query metrics — a value of 1.0 means the filter was fully served by the index. A value significantly below 1.0 means documents were loaded and discarded, which wastes RUs. <!-- Source: develop-modern-applications/performance/query/query-metrics.md -->

### Step 3: Project Only What You Need

Don't return entire documents when you only need a few fields:

```sql
-- Before: returns every property on each line item
SELECT * FROM c
WHERE c.customerId = "cust-337" AND c.type = "lineItem" AND c.orderId = "order-123"

-- After: only the fields the UI actually renders
SELECT c.productName, c.quantity, c.unitPrice
FROM c
WHERE c.customerId = "cust-337" AND c.type = "lineItem" AND c.orderId = "order-123"
```

Smaller retrieved document size means fewer RUs consumed by the query's document-load phase. If your line items carry large nested objects — shipping details, product metadata, audit history — the difference between `SELECT *` and a targeted projection can be substantial.

### Step 4: Check the Execution Metrics

Look at the query execution metrics to confirm your optimizations worked:

| Metric | Meaning |
|---|---|
| `RetrievedDocumentCount` | Docs loaded by engine |
| `OutputDocumentCount` | Docs in final result set |
| `IndexHitRatio` | 1.0 = fully index-served |
| `IndexLookupTime` | Time in index lookups |
| `DocumentLoadTime` | Time loading from storage |

`RetrievedDocumentCount` should be close to `OutputDocumentCount` — a large gap means your filter isn't fully index-served. High `DocumentLoadTime` confirms too many documents are being loaded. `IndexLookupTime` should be low relative to total execution time.

<!-- Source: develop-modern-applications/performance/query/query-metrics.md -->

If `RetrievedDocumentCount` is much larger than `OutputDocumentCount`, your filter isn't being served by the index. Either the path isn't indexed, or you're using a function that prevents index usage (like `LOWER()` on a non-computed property).

### Step 5: Consider an Optimistic Direct Execution Path

For single-partition queries that don't require pagination, the .NET SDK offers **Optimistic Direct Execution (ODE)**. ODE skips client-side query plan generation and sends the query directly to the target partition, reducing both latency and RU cost. Enable it with `EnableOptimisticDirectExecution = true` in `QueryRequestOptions`. <!-- Source: develop-modern-applications/performance/query/performance-tips-query-sdk.md -->

A single-partition query fetching line items for one order is a textbook ODE candidate — it targets one partition and typically fits in a single response page. If the query actually requires cross-partition execution or pagination, ODE can increase both latency and RU cost, so only enable it when you're confident the query targets one partition and fits in a single response page. <!-- Source: develop-modern-applications/performance/query/performance-tips-query-sdk.md -->

## Leveraging Query Advisor in the Tuning Loop

Chapter 8 introduced Query Advisor — the built-in tool in the Azure portal's Data Explorer that analyzes your queries and suggests optimizations. In the tuning loop, use it as a quick sanity check after writing a new query. It catches common anti-patterns like missing partition key filters, unbounded queries without `TOP`, and functions that inhibit index usage. It won't catch everything, but it's a free first pass before you dig into query metrics.

## Handling Hot Partitions at Scale

A **hot partition** occurs when one physical partition consumes a disproportionate share of the container's throughput. The result: that partition hits its RU/s ceiling while others sit idle, and your application gets 429 throttling errors even though the *container-level* throughput looks underutilized. Chapter 5 explained why partition key choice is the root cause. This section covers the remediation.

### Detecting Hot Partitions

Navigate to **Insights → Throughput → Normalized RU Consumption (%) By PartitionKeyRangeID** in the Azure portal. Each `PartitionKeyRangeId` maps to a physical partition. If one partition is consistently at 100% while others are at 30% or less, you have a hot partition. <!-- Source: manage-your-account/monitor/use-azure-monitor-metrics/monitor-normalized-request-units.md -->

For deeper analysis, enable diagnostic logs and query the `CDBPartitionKeyRUConsumption` table to identify which *logical* partition keys within the hot physical partition are consuming the most RUs:

```kusto
CDBPartitionKeyRUConsumption
| where TimeGenerated >= ago(24h)
| where DatabaseName == "OrdersDB" and CollectionName == "Orders"
| where isnotempty(PartitionKey) and isnotempty(PartitionKeyRangeId)
| summarize sum(RequestCharge) by bin(TimeGenerated, 1h), PartitionKey
| order by sum_RequestCharge desc
```

<!-- Source: throughput-request-units/distribute-throughput-across-partitions-preview-container/how-to-redistribute-throughput-across-partitions.md -->

### Remediation Strategy 1: Fix the Partition Key

The best fix is the one that addresses the root cause. If a single logical partition key is consuming most of the RUs, and you can redesign your partition key to spread the load, do that. Synthetic partition keys (Chapter 5) and hierarchical partition keys (Chapter 5) are the primary tools. The catch: changing the partition key requires creating a new container and migrating data. That's a bigger project, but it's the permanent fix.

### Remediation Strategy 2: Throughput Redistribution Across Physical Partitions

> **Note:** As of this writing, throughput redistribution is a preview feature — verify its status before relying on it in production. <!-- Source: throughput-request-units/distribute-throughput-across-partitions-preview-container/how-to-redistribute-throughput-across-partitions.md -->

When you can't change the partition key — or need relief right now — Cosmos DB lets you redistribute provisioned throughput unevenly across physical partitions. By default, throughput is spread equally. This feature lets you assign more RU/s to the hot partition and fewer to the cold ones. <!-- Source: throughput-request-units/distribute-throughput-across-partitions-preview-container/how-to-redistribute-throughput-across-partitions.md -->

Key constraints:

- Available for provisioned throughput (manual or autoscale), not serverless.
- Each physical partition can hold a maximum of **10,000 RU/s**.
- You can set a target of up to **20,000 RU/s** on a single partition — this triggers an automatic partition split, distributing the throughput evenly across the two new partitions.
- Once you customize throughput distribution, the throughput policy changes from "Equal" to "Custom." At that point, you can no longer use the portal throughput slider or standard CLI throughput-update commands — all changes must go through the redistribution API until you reset the policy back to "Equal." <!-- Source: throughput-request-units/distribute-throughput-across-partitions-preview-container/how-to-redistribute-throughput-across-partitions.md -->

<!-- Source: throughput-request-units/distribute-throughput-across-partitions-preview-container/how-to-redistribute-throughput-across-partitions.md -->

Here's an example using Azure CLI. Suppose your container has 6,000 RU/s across two physical partitions (P0 and P1), each with 3,000 RU/s. P1 is hot. You want to give P1 more headroom:

```bash
az cosmosdb sql container redistribute-partition-throughput \
    --resource-group "myResourceGroup" \
    --account-name "my-cosmos-account" \
    --database-name "OrdersDB" \
    --name "Orders" \
    --target-partition-info "0=1000 1=5000"
```

This gives P0 1,000 RU/s and P1 5,000 RU/s. The total container throughput stays at 6,000 RU/s.

If P1 truly needs more than 10,000 RU/s, set its target above 10,000 (up to 20,000). Cosmos DB will split the partition and distribute the throughput across the resulting halves. But if the hotness comes from a single logical partition key, splitting won't help — all data for that key stays on one physical partition, capped at 10,000 RU/s. In that case, you're back to Strategy 1. <!-- Source: throughput-request-units/distribute-throughput-across-partitions-preview-container/how-to-redistribute-throughput-across-partitions.md -->

### Remediation Strategy 3: Scale Up the Container

Sometimes the simplest answer is to increase the container's overall throughput. If your workload is generally well-distributed but one partition is slightly hotter than others, raising the total RU/s gives every partition more headroom. This costs more, but it's the fastest fix and requires no data migration.

## Capacity Planning and Load Testing with the Capacity Planner

Before you launch, you need to estimate how many RU/s your workload requires. Guessing is expensive — overprovision and you waste money, underprovision and you get throttled.

The **Azure Cosmos DB Capacity Planner** at [cosmos.azure.com/capacitycalculator](https://cosmos.azure.com/capacitycalculator/) gives you an RU/s and cost estimate based on your workload profile. It has two modes: <!-- Source: throughput-request-units/provisioned-throughput/estimate-ru-with-capacity-planner.md -->

| Mode | Best For |
|---|---|
| **Basic** | Quick cost estimates |
| **Advanced** | Production capacity planning |

- **Basic inputs:** item size, reads/sec, writes/sec, queries/sec, region count.
- **Advanced inputs:** all of the above plus indexing policy, consistency level, peak-vs-steady ratios, and sample JSON documents.

<!-- Source: throughput-request-units/provisioned-throughput/estimate-ru-with-capacity-planner.md -->

The advanced mode lets you upload a sample JSON document for accurate size estimation, specify your indexing policy (automatic, custom, or off), and set the consistency level — which matters because strong and bounded staleness consistency cost 2x the read RUs of session or eventual. <!-- Source: throughput-request-units/provisioned-throughput/estimate-ru-with-capacity-planner.md -->

### Load Testing in Practice

The capacity planner gives you a *starting* estimate. Real-world validation requires load testing against your actual container with realistic data. Here's the approach:

1. **Provision a test container** with the estimated RU/s and your production indexing policy.
2. **Seed realistic data** — at least enough to create multiple physical partitions, matching your expected data distribution.
3. **Generate load** using your preferred tool (k6, Locust, JMeter, or a custom harness using the SDK's bulk mode).
4. **Monitor** normalized RU consumption, P99 latency, and 429 rate in Azure Monitor during the test.
5. **Adjust.** If 429 rates exceed 1–5% of total requests, increase throughput. If P99 latency is too high, investigate connection mode and query patterns.

The 1–5% 429 rate guideline comes directly from Microsoft's guidance: for production workloads, a small percentage of 429s with acceptable end-to-end latency is a healthy sign that you're fully utilizing your provisioned throughput. <!-- Source: manage-your-account/monitor/use-azure-monitor-metrics/monitor-normalized-request-units.md -->

## Per-Language SDK Best Practices

SDK fundamentals are covered in Chapter 7, and advanced patterns in Chapter 21. Here's the performance-specific checklist for each language.

### .NET SDK v3

| Practice | Why |
|---|---|
| **Direct mode** (default) | Eliminates gateway hop |
| **Singleton `CosmosClient`** | Manages pools and cache |
| **Server-side GC** | Reduces GC pauses |
| **Async-only calls** | Prevents thread starvation |
| **No write response body** | Saves deserialization cost |
| **Remove `DefaultTraceListener`** | High CPU/I/O in production |
| **Accelerated Networking** | Lower latency on VMs |
| **`Newtonsoft.Json` ≥ 13.0.3** | Avoids security vulns |

- Don't switch to gateway unless firewalls force it. One `CosmosClient` per app — creating multiple wastes resources.
- Set `gcServer = true`. Use `async`/`await` throughout — never `Task.Wait()` or `Task.Result`.
- Set `EnableContentResponseOnWrite = false` on write-heavy paths to skip deserializing the response body.
- `DefaultTraceListener` is auto-removed in SDK 3.24.0+. <!-- Source: develop-modern-applications/performance/net/performance-tips-dotnet-sdk-v3.md -->
- Accelerated Networking bypasses the host virtual switch, reducing CPU jitter.
- The SDK depends on `Newtonsoft.Json` but doesn't manage the version — use ≥ 13.0.3 to avoid security vulnerabilities.

<!-- Source: develop-modern-applications/performance/net/performance-tips-dotnet-sdk-v3.md, develop-modern-applications/performance/net/best-practice-dotnet.md -->

```csharp
CosmosClient client = new CosmosClientBuilder("connection-string")
    .WithApplicationPreferredRegions(new List<string> { "East US", "West US" })
    .WithBulkExecution(true) // for high-throughput ingestion
    .Build();

// Write without deserializing the response
ItemRequestOptions options = new() { EnableContentResponseOnWrite = false };
await container.CreateItemAsync(order, new PartitionKey(order.CustomerId), options);
```

### Java SDK v4

| Practice | Why |
|---|---|
| **Direct mode** (`directMode()`) | Default; set explicitly |
| **Singleton `CosmosAsyncClient`** | Thread-safe, one per app |
| **Async over sync client** | Non-blocking I/O (Netty) |
| **Pass partition key on writes** | Avoids doc parsing overhead |
| **Don't block Netty threads** | Causes deadlocks |
| **Disable Netty logging** | Verbose; steals CPU |
| **Raise `nofile` on Linux** | Direct mode needs many FDs |

- Set `directMode()` explicitly to configure `DirectConnectionConfig`. <!-- Source: develop-modern-applications/performance/java/tune-connection-configurations-java-sdk-v4.md -->
- Prefer `CosmosAsyncClient` — its non-blocking I/O saturates throughput far better than the sync wrapper.
- Passing just the item forces the SDK to parse the document to extract the partition key, adding latency.
- Offload CPU-intensive work to `Schedulers.parallel()` to keep Netty event loop threads free.

<!-- Source: develop-modern-applications/performance/java/performance-tips-java-sdk-v4.md -->

```java
CosmosAsyncClient client = new CosmosClientBuilder()
    .endpoint(endpoint)
    .key(masterKey)
    .consistencyLevel(ConsistencyLevel.SESSION)
    .preferredRegions(Arrays.asList("East US", "West US"))
    .directMode()
    .buildAsyncClient();

// Always pass the partition key explicitly
asyncContainer.createItem(order, new PartitionKey(order.getCustomerId()),
    new CosmosItemRequestOptions()).block();
```

### Python SDK

| Practice | Why |
|---|---|
| **Singleton `CosmosClient`** | Reuse for app lifetime |
| **Set `preferred_locations`** | Nearest region + failover |
| **Raise `max_item_count`** | Default 100; reduce trips |
| **Keep CPU under 70%** | Gateway-only; CPU-sensitive |
| **Exclude unused index paths** | Cuts write RU cost |

The Python SDK has no direct mode — it uses gateway mode exclusively, making CPU-bound environments more impactful on latency. Increase `max_item_count` beyond the default of 100 items to reduce round trips for large result sets.

<!-- Source: develop-modern-applications/performance/python/best-practice-python.md, develop-modern-applications/performance/python/performance-tips-python-sdk.md -->

```python
client = CosmosClient(
    url=endpoint,
    credential=key,
    preferred_locations=["East US", "West US"]
)

# Increase page size for large queries
items = container.query_items(
    query="SELECT c.id, c.status FROM c WHERE c.customerId = @cid",
    parameters=[{"name": "@cid", "value": "cust-337"}],
    max_item_count=500
)
```

### JavaScript/Node.js SDK

| Practice | Why |
|---|---|
| **Singleton `CosmosClient`** | One instance per app |
| **Set `preferredLocations`** | Read routing + failover |
| **Use `cluster` module** | Node.js is single-threaded |
| **Raise `maxItemCount`** | Default 100 items / 4 MB |
| **Accelerated Networking** | Lower latency on VMs |
| **≥ 4 cores, 8 GB RAM** | SDK HTTP overhead is real |

Set `preferredLocations` in `ConnectionPolicy` to drive read routing and failover. Single-threaded Node.js can become the bottleneck before Cosmos DB does — use the `cluster` module under load. Set a higher `maxItemCount` to reduce round trips for large result sets.

<!-- Source: develop-modern-applications/performance/javascript/best-practices-javascript.md -->

### Cross-SDK Summary

Some practices apply everywhere, regardless of language:

- **Use a single client instance.** This is the number-one SDK performance mistake across all languages. Every SDK is designed to be a singleton.
- **Collocate your app and your Cosmos DB account in the same Azure region.** Cross-region calls add 50+ ms of latency that no SDK optimization can fix. <!-- Source: develop-modern-applications/performance/python/performance-tips-python-sdk.md -->
- **Always specify preferred regions.** Without them, the SDK can't route reads to nearby replicas or fail over gracefully.
- **Use the latest SDK version.** Performance improvements ship with every release. Running an old SDK means leaving performance on the table.

## When to Consider Multiple Containers vs. a Single Container

Chapter 4 made the case for embedding related data in a single container. But there's a performance dimension to the one-container-vs-many debate.

**Single container, shared partition key** — works well when your entities are accessed together and share a natural partition key. You get transactional batch operations (Chapter 16), simple indexing, and no cross-container query overhead.

**Multiple containers** — make sense when:

| Scenario | Why Split |
|---|---|
| **Different indexing needs** | One policy can't serve both |
| **Different throughput** | Avoid cross-subsidizing RU/s |
| **Different TTL** | Separate expiry policies |
| **Independent scaling** | Scale each entity type alone |

For example, a write-heavy telemetry container needs minimal indexing while a product catalog needs full indexing. An orders container at 50,000 RU/s shouldn't share throughput with user profiles at 2,000 RU/s. Telemetry expiring in 30 days shouldn't share a container with permanent reference data.

The cost of multiple containers is operational complexity and the inability to use transactional batches across them. Don't split containers for the sake of "organization" — split them when the performance or operational characteristics genuinely differ.

## Production Readiness Checklist

Before you go live, walk through this list. Each item maps back to a chapter in this book where you can find the full details.

| Category | Check | Ref |
|---|---|---|
| **SDK** | Latest version? | Ch 7 |
| **SDK** | Singleton client? | Ch 7 |
| **SDK** | Direct mode? (.NET/Java) | This ch |
| **SDK** | Preferred regions set? | Ch 7, 21 |
| **SDK** | No write response body? | This ch |
| **Data Model** | Lean docs, no blobs? | Ch 4 |
| **Partition Key** | High cardinality, even? | Ch 5 |
| **Indexing** | Unused paths excluded? | Ch 9 |
| **Indexing** | No missing indexes? | Ch 9 |
| **Queries** | PK filter on queries? | Ch 8 |
| **Queries** | Projections, not `SELECT *`? | This ch |
| **Throughput** | Load-tested estimate? | This ch |
| **Throughput** | Autoscale if variable? | Ch 11 |
| **Monitoring** | 429/P99/RU alerts set? | Ch 18 |
| **Monitoring** | Diagnostic logs on? | Ch 18 |
| **Availability** | Multi-region + failover? | Ch 12 |
| **Availability** | Availability strategy? | Ch 21 |
| **Security** | Entra ID, no local keys? | Ch 17 |
| **Backup** | Continuous backup (PITR)? | Ch 19 |
| **Testing** | Emulator in CI? | Ch 24 |

- **No write response body:** set `EnableContentResponseOnWrite = false` on write-heavy .NET paths.
- **Lean docs:** no embedded blobs or redundant properties.
- **Partition key:** high cardinality, even distribution, supports your primary access pattern.
- **No missing indexes:** confirm via index metrics for critical queries.
- **Monitoring alerts:** 429 rate > 5%, P99 latency, and normalized RU consumption. Enable `CDBPartitionKeyRUConsumption` diagnostic logs.
- **Availability:** multi-region replication with service-managed failover. Threshold-based availability strategy for .NET/Java.
- **Backup:** continuous backup with appropriate retention period.

Performance tuning isn't a one-time event — it's a practice. The tools and techniques in this chapter give you a systematic approach to find and fix the bottlenecks that matter. In Chapter 28, we'll put everything together and build a production-ready application from scratch, applying these patterns in context.
