# Chapter 26: Performance Tuning and Best Practices

By now you have a working Cosmos DB application—containers are provisioned, queries are returning data, and the change feed is humming along. But "working" and "fast" are not the same thing. This chapter is about closing that gap. We'll walk through a systematic tuning loop, dive into the optimizations that yield the biggest returns, and finish with a production-readiness checklist you can pin to your team's wall.

## The Performance Tuning Loop

Performance tuning is not a one-time event. It's an iterative cycle with four stages:

1. **Measure** – Collect baseline metrics: RU consumption per operation, end-to-end latency (p50, p95, p99), and 429 (rate-limited) response counts. Azure Monitor's built-in Cosmos DB metrics and the SDK's diagnostics strings are your primary instruments.
2. **Identify** – Find the bottleneck. Is it a single expensive query? A hot partition? Network latency from gateway mode? The diagnostics will tell you.
3. **Optimize** – Apply a targeted fix: rewrite the query, tune the indexing policy, switch connectivity modes, or redistribute throughput.
4. **Validate** – Re-measure. Confirm the fix actually helped and didn't introduce a regression elsewhere. Then loop back to step one.

Resist the urge to change five things at once. Change one variable, measure the impact, and move on. Disciplined iteration beats shotgun optimization every time.

### Key Metrics to Watch

| Metric | Where to Find It | What It Tells You |
|--------|-------------------|-------------------|
| **Request charge (RU/s)** | SDK response headers, Azure Monitor | Cost of each operation |
| **Normalized RU consumption (%)** | Azure Monitor, split by PartitionKeyRangeId | Whether any partition is hotter than others |
| **End-to-end latency** | SDK diagnostics, Azure Monitor | Total round-trip time including network |
| **Server-side latency** | Azure Monitor | Time spent inside Cosmos DB itself |
| **429 response count** | Azure Monitor, SDK diagnostics | Rate-limiting events |
| **Document count / storage** | Azure Monitor | Whether you're approaching partition size limits |

## Choosing Direct Connectivity Mode for Lowest Latency

Every Cosmos DB SDK supports two connectivity modes: **Gateway** and **Direct**.

- **Gateway mode** routes every request through a centralized HTTPS gateway endpoint. It's simpler—only port 443 is required—and works well behind restrictive firewalls. But every request adds an extra network hop.
- **Direct mode** establishes TCP connections straight to the backend replica that owns your data. This eliminates the gateway hop and cuts latency significantly—typically reducing p99 latency by 20–40% for point reads.

For production workloads, **always prefer Direct mode** unless network constraints force you into Gateway. Here's how to configure it across SDKs:

**.NET:**
```csharp
CosmosClientOptions options = new CosmosClientOptions
{
    ConnectionMode = ConnectionMode.Direct
};
CosmosClient client = new CosmosClient(endpoint, key, options);
```

**Java:**
```java
DirectConnectionConfig directConfig = DirectConnectionConfig.getDefaultConfig();
CosmosAsyncClient client = new CosmosClientBuilder()
    .endpoint(endpoint)
    .key(key)
    .directMode(directConfig)
    .buildAsyncClient();
```

**Python:**
**Note:** The Python SDK currently supports Gateway mode only. To minimize latency, colocate your application in the same Azure region as your Cosmos DB account.

**JavaScript/Node.js:**
The JavaScript SDK currently operates in Gateway mode only. To compensate, colocate your application in the same Azure region as your Cosmos DB account and use a singleton `CosmosClient` instance for connection reuse.

> **Tip:** Direct mode requires ports 10000–20000 to be open for TCP. If you're running in Azure App Service, Azure Kubernetes Service, or Azure VMs, these ports are open by default. If you're behind a corporate proxy, you may need to stay with Gateway mode and focus on other optimizations.

## Optimizing Document Size and Structure

The RU cost of every operation—reads, writes, queries—correlates directly with document size. Smaller documents mean cheaper operations. Here are the practical levers:

- **Strip what you don't query.** Large blobs of text, Base64-encoded images, or verbose audit trails that you never filter on should live in Azure Blob Storage. Store a URL reference in your Cosmos DB document instead. A 1 KB write costs roughly 5.5 RUs; a 100 KB write can cost 50+ RUs.
- **Flatten shallow, nest deep.** Cosmos DB is optimized for denormalized documents. Embedding related data (like a customer's recent orders) avoids cross-document joins. But don't embed unbounded arrays—an array that grows to thousands of entries bloats every read and write.
- **Use short property names in high-volume containers.** Property names are stored with every document. Renaming `customerEmailAddress` to `email` across millions of documents saves real storage and index cost. This is a judgment call—readability matters too—but for IoT or telemetry workloads with billions of documents, the savings are meaningful.
- **Keep documents under 100 KB.** The hard limit is 2 MB, but performance degrades well before that. If a document regularly exceeds 100 KB, consider splitting it across multiple items with the same partition key.

## Indexing Policy Tuning for Write-Heavy Workloads

By default, Cosmos DB indexes **every property** in every document. This is great for query flexibility during development, but it means every write pays the indexing tax on every field—even fields you never query.

For write-heavy workloads, tuning the indexing policy is one of the highest-leverage optimizations you can make.

### Strategy 1: Exclude Unused Paths

If you query on `status`, `createdAt`, and `customerId`, but never filter on `payload` or `metadata`, exclude those paths:

```json
{
  "indexingMode": "consistent",
  "includedPaths": [
    { "path": "/*" }
  ],
  "excludedPaths": [
    { "path": "/payload/*" },
    { "path": "/metadata/*" },
    { "path": "/_etag/?" }
  ]
}
```

### Strategy 2: Include Only What You Need

For maximum write performance, flip the model—exclude everything and include only the paths your queries touch:

```json
{
  "indexingMode": "consistent",
  "includedPaths": [
    { "path": "/customerId/?" },
    { "path": "/status/?" },
    { "path": "/createdAt/?" }
  ],
  "excludedPaths": [
    { "path": "/*" }
  ]
}
```

This can reduce write RU costs by 30–60% depending on document complexity.

### Strategy 3: Disable Indexing Entirely

For pure key-value workloads where you only do point reads (by `id` and partition key) and never run queries:

```json
{
  "indexingMode": "none"
}
```

This gives you the absolute lowest write cost, but you lose the ability to run any queries except point reads.

### Composite Indexes for Sorting

If your queries use `ORDER BY` on multiple properties, add a composite index. Without one, the query engine performs an expensive in-memory sort:

```json
{
  "compositeIndexes": [
    [
      { "path": "/customerId", "order": "ascending" },
      { "path": "/createdAt", "order": "descending" }
    ]
  ]
}
```

> **Important:** Changing the indexing policy triggers a background index transformation. Monitor the **Index Transformation Progress** metric in Azure Monitor to know when the new policy is fully applied.

## Query Optimization Walk-Through: From Expensive to Efficient

Let's walk through a real-world scenario. You have an `orders` container partitioned by `customerId`, and this query appears in your monitoring as a top RU consumer:

### The Expensive Query

```sql
SELECT * FROM c WHERE c.status = "shipped" ORDER BY c.createdAt DESC
```

**Problems:**
1. `SELECT *` returns every property, including large ones you don't need.
2. No partition key filter—this is a **cross-partition fan-out query** that hits every physical partition.
3. `ORDER BY` without a composite index forces an in-memory sort.

**RU cost:** ~85 RUs per page of results.

### Step 1: Project Only What You Need

```sql
SELECT c.id, c.customerId, c.status, c.total, c.createdAt
FROM c WHERE c.status = "shipped" ORDER BY c.createdAt DESC
```

**Impact:** Reduces payload size and network transfer. RU cost drops to ~60 RUs.

### Step 2: Add a Composite Index

```json
{
  "compositeIndexes": [
    [
      { "path": "/status", "order": "ascending" },
      { "path": "/createdAt", "order": "descending" }
    ]
  ]
}
```

**Impact:** Eliminates the in-memory sort. RU cost drops to ~25 RUs.

### Step 3: Scope to a Single Partition When Possible

If the caller already knows the customer:

```sql
SELECT c.id, c.status, c.total, c.createdAt
FROM c WHERE c.customerId = "cust-42" AND c.status = "shipped"
ORDER BY c.createdAt DESC
```

Pass the partition key in the SDK's request options (or the query itself). **Impact:** Query hits one partition instead of all of them. RU cost drops to ~5 RUs.

**Total improvement:** From ~85 RUs down to ~5 RUs—a 94% reduction.

## Using Query Advisor Recommendations

Cosmos DB's **Query Advisor** is a built-in feature in the Azure portal that analyzes your queries and provides actionable optimization recommendations. You'll find it in the Data Explorer under the query editor.

Query Advisor catches common pitfalls:

- **Missing composite indexes** for `ORDER BY` clauses on multiple properties.
- **High cross-partition query counts** where a partition key filter would eliminate fan-out.
- **Functions in filters** (like `LOWER(c.name)`) that prevent index utilization—it will suggest computed properties or a case-normalized stored value instead.
- **Suboptimal `SELECT *` usage** that inflates response sizes.
- **Missing range indexes** for inequality filters (`>`, `<`, `>=`, `<=`, `!=`).

To use Query Advisor effectively:

1. Open **Data Explorer** in the Azure portal.
2. Run your query and review the **Query Stats** tab for the RU charge and index utilization.
3. Check the **Query Advisor** panel for recommendations.
4. Apply the suggested changes—often an indexing policy update or a query rewrite—and re-run to validate the improvement.

Query Advisor is also available when querying from Microsoft Fabric's mirrored databases, so you get the same optimization guidance regardless of where you execute queries.

> **Tip:** Make it a habit to check Query Advisor during development, not just when things are slow in production. Catching an expensive pattern early is always cheaper than fixing it under pressure.

## Handling Hot Partitions at Scale

Even with a well-chosen partition key, real-world workloads are rarely perfectly uniform. A viral product, a flash sale, or a single enterprise customer can create a **hot partition**—one physical partition that consumes disproportionately more throughput than the others.

### Detecting Hot Partitions

1. In **Azure Monitor**, open the **Normalized RU Consumption (%) by PartitionKeyRangeId** metric for your container. If one partition consistently sits at 100% while others are at 20–30%, you have a hot partition.
2. In **Diagnostic Logs** (the `CDBPartitionKeyRUConsumption` category), use Kusto queries to find the specific partition key range and logical partition keys consuming the most RUs.

### Redistributing Throughput Across Physical Partitions

Cosmos DB now supports **custom throughput redistribution** across physical partitions (currently in preview). Instead of increasing overall RU/s—which spreads evenly and wastes money on cold partitions—you can allocate more RU/s specifically to the hot partition.

Using Azure CLI:

```bash
# Retrieve current per-partition throughput
az cosmosdb sql container retrieve-partition-throughput \
    --resource-group "myRG" \
    --account-name "myAccount" \
    --database-name "myDB" \
    --name "orders" \
    --all-partitions

# Redistribute: give partition 3 more RU/s, take from partition 0
az cosmosdb sql container redistribute-partition-throughput \
    --resource-group "myRG" \
    --account-name "myAccount" \
    --database-name "myDB" \
    --name "orders" \
    --target-partition-info 0=400 3=1200 \
    --source-partition-info 1=400 2=400
```

Key constraints to keep in mind:

- Each physical partition can be assigned a maximum of **10,000 RU/s**.
- If a hot partition's single logical partition key is responsible for all the traffic, redistributing won't help—all that key's data lives on one physical partition. You'd need to revisit your partition key strategy.
- After redistribution, the throughput policy changes to "Custom." To return to even distribution later, reset the policy back to "Equal."
- You can also **split a physical partition** to create more partition key ranges, but only if the hot partition contains multiple logical partition keys whose data can be distributed across the new partitions.

## Capacity Planning and Load Testing with the RU Calculator

Before going to production—or before a major launch—use the **Azure Cosmos DB Capacity Planner** at [cosmos.azure.com/capacitycalculator](https://cosmos.azure.com/capacitycalculator/) to estimate your RU/s and monthly cost.

### Basic Mode

Plug in your expected operations per second (point reads, creates, updates, deletes, queries), item size, number of regions, and whether you need multi-region writes. The calculator gives you a quick RU/s and cost estimate using default settings for indexing and consistency.

### Advanced Mode

Sign in to unlock additional parameters:

- **Custom indexing policy** (automatic, off, or custom path configuration)
- **Consistency level** (remember: Strong and Bounded Staleness cost 2x the RUs for reads compared to Session or Eventual)
- **Variable workload mode** with peak/off-peak percentages—great for workloads with predictable traffic patterns
- **Upload a sample JSON document** for accurate item-size estimation

### Load Testing in Practice

The capacity planner gives you a theoretical estimate. Validate it with a real load test:

1. **Provision a test container** with the estimated RU/s.
2. Use a load testing tool (Azure Load Testing, k6, Locust, or even a simple console app with `Task.WhenAll`) to simulate your expected traffic pattern.
3. Monitor the **Normalized RU Consumption**, **429 count**, and **end-to-end latency** during the test.
4. If you see 429s, increase throughput or optimize the hot operations. If utilization is below 50%, consider reducing RU/s to save cost.
5. Test with **autoscale** if your workload is variable—set a max RU/s and let Cosmos DB scale between 10% of that max and the full value.

## Per-Language SDK Best Practices

Each SDK has language-specific optimizations. Here are the most impactful tips for each.

### .NET SDK v3

| Practice | Why It Matters |
|----------|---------------|
| Use a **singleton** `CosmosClient` for the app's lifetime | Connection setup is expensive; reuse amortizes it |
| Enable **Direct mode** (TCP) | Eliminates gateway hop; lowest latency |
| Use **Stream APIs** (`ReadItemStreamAsync`, `CreateItemStreamAsync`) when you don't need deserialization | Avoids serialization overhead; reduces CPU and memory |
| Enable **bulk execution** (`AllowBulkExecution = true`) for batch ingestion | Groups operations into batches for higher throughput |
| Disable the `DefaultTraceListener` in production | It causes significant CPU overhead; SDK v3.23.0+ removes it automatically |
| Set `ApplicationPreferredRegions` to colocated regions | Ensures reads go to the nearest replica |
| Use `CosmosClientBuilder.WithThrottlingRetryOptions` | Customizes retry behavior on 429s |

### Java SDK v4

| Practice | Why It Matters |
|----------|---------------|
| Use **`CosmosAsyncClient`** (async/reactive) over sync client | Non-blocking I/O; much higher throughput under load |
| Enable **Direct mode** with `directMode()` | Same TCP benefit as .NET |
| Use **content response on write disabled** (`setContentResponseOnWriteEnabled(false)`) | Avoids returning the full document on write operations; saves bandwidth |
| Set **`maxDegreeOfParallelism`** and **`maxBufferedItemCount`** for queries | Controls parallelism across partitions and memory usage |
| Colocate client in the same Azure region | Cross-region latency can add 50–200 ms per hop |
| Use the **bulk executor** for large ingestion workloads | Optimized batching and retry logic built in |

### Python SDK

| Practice | Why It Matters |
|----------|---------------|
| Use a **singleton** `CosmosClient` | Same connection-reuse benefit as .NET |
| Prefer **session consistency** (the default) for lowest read cost | Strong/Bounded Staleness costs 2x RUs for reads |
| Set `preferred_locations` to the nearest region | Reduces network latency |
| Use **integrated cache** for read-heavy workloads | Reduces RU consumption for repeated reads |
| Enable **connection pooling** and reuse the HTTP session | Default `requests` transport creates new connections; use `aiohttp` for async |
| Exclude unused paths from the indexing policy | Reduces write RUs—this isn't SDK-specific, but Python workloads often have large JSON payloads |

### JavaScript / Node.js SDK

| Practice | Why It Matters |
|----------|---------------|
| Use a **singleton** `CosmosClient` | Connection reuse is critical in Node.js's single-threaded model |
| Set `partitionKey` in `FeedOptions` for single-partition queries | Eliminates the query plan call to the gateway; reduces latency |
| Tune **`maxItemCount`** (page size) | Default is 100 items; increasing to 500–1000 reduces round trips for large result sets |
| Use **`enableQueryControl`** (SDK 4.3.0+) | Gives you predictable latency and granular RU consumption per `fetchNext` call |
| Run at least **4 cores / 8 GB RAM** in production | Node.js is CPU-bound; undersized VMs cause jitter |
| Enable **Accelerated Networking** on your VM | Reduces network latency and CPU jitter under high throughput |

## When to Consider Multiple Containers vs. a Single Container

Cosmos DB's pricing model charges RU/s at the container (or shared database) level, so container design is a cost decision as much as a data-modeling one.

**Favor a single container when:**
- Your entities share a natural partition key (e.g., `tenantId` for a multi-tenant SaaS app).
- You can use a `type` discriminator property to store different entity types in the same container.
- You want to minimize provisioned throughput by sharing RU/s across entity types.
- You need transactional batch operations across entity types (transactional batches require the same partition key and container).

**Favor multiple containers when:**
- Entity types have fundamentally different access patterns (e.g., high-write telemetry vs. low-read reference data). Separate containers let you provision and scale each independently.
- Indexing policies differ significantly. One container's "index everything" policy would bloat writes for another entity type that only needs point reads.
- You need different TTL policies per entity type.
- Different containers need different partition keys for optimal distribution.

**The shared throughput database** is a middle ground: up to 25 containers share a pool of RU/s, with each container guaranteed a minimum of 100 RU/s. This works well for microservices that have many low-traffic containers.

## Production Readiness Checklist

Before flipping the switch to production traffic, walk through this checklist with your team:

| # | Category | Item | Status |
|---|----------|------|--------|
| 1 | **Connectivity** | SDK uses Direct mode (or Gateway with documented justification) | ☐ |
| 2 | **Connectivity** | `CosmosClient` is a singleton, created once at app startup | ☐ |
| 3 | **Connectivity** | `ApplicationPreferredRegions` is set to the nearest Azure region(s) | ☐ |
| 4 | **Consistency** | Consistency level is explicitly chosen and documented (not left at default Strong if Session suffices) | ☐ |
| 5 | **Indexing** | Indexing policy is tuned—unused paths excluded, composite indexes added for ORDER BY queries | ☐ |
| 6 | **Queries** | No `SELECT *` in production queries; only projected fields are returned | ☐ |
| 7 | **Queries** | All high-frequency queries include a partition key filter | ☐ |
| 8 | **Queries** | Query Advisor recommendations reviewed and applied | ☐ |
| 9 | **Partition Strategy** | Partition key is chosen for even distribution and aligned with primary access patterns | ☐ |
| 10 | **Partition Strategy** | No single logical partition key expected to exceed 20 GB | ☐ |
| 11 | **Throughput** | RU/s provisioned based on capacity planner estimate and validated with load testing | ☐ |
| 12 | **Throughput** | Autoscale configured if workload is variable; manual RU/s if steady-state | ☐ |
| 13 | **Throughput** | 429 retry policy configured with appropriate `MaxRetryAttemptsOnRateLimitedRequests` and `MaxRetryWaitTimeOnRateLimitedRequests` | ☐ |
| 14 | **Availability** | Multi-region replication enabled with service-managed failover | ☐ |
| 15 | **Availability** | Availability strategy configured (hedging for reads, circuit breaker for writes) | ☐ |
| 16 | **Monitoring** | Azure Monitor alerts configured for Normalized RU Consumption > 90%, 429 count > 0, and server-side latency > threshold | ☐ |
| 17 | **Monitoring** | Diagnostic settings enabled for `DataPlaneRequests`, `QueryRuntimeStatistics`, and `PartitionKeyRUConsumption` | ☐ |
| 18 | **Security** | Microsoft Entra ID (AAD) authentication used instead of primary/secondary keys | ☐ |
| 19 | **Security** | VNet service endpoints or private endpoints configured | ☐ |
| 20 | **Backup** | Backup policy reviewed—continuous backup enabled if point-in-time restore is needed | ☐ |
| 21 | **SDK** | Latest stable SDK version is in use | ☐ |
| 22 | **SDK** | `DefaultTraceListener` removed (.NET) or equivalent logging overhead eliminated | ☐ |
| 23 | **Cost** | Monthly cost estimate reviewed and budget alerts set in Azure Cost Management | ☐ |

Print this table, check every box, and keep it in your runbook. The items you skip today become the incidents you debug at 3 AM.

## Summary

Performance tuning in Cosmos DB comes down to a simple discipline: measure, identify the bottleneck, apply a targeted fix, and validate. The highest-leverage optimizations are usually the simplest—switching to Direct mode, tuning the indexing policy, and adding a partition key filter to your hottest query can easily cut your RU bill in half and shave double-digit percentages off latency.

When those basics are covered, the advanced tools—throughput redistribution across physical partitions, the capacity planner, and Query Advisor—give you the precision instruments to fine-tune at scale.

The production readiness checklist isn't optional. It's the difference between an application that works in development and one that thrives under real-world load.

---

## What's Next

In **Chapter 27**, we'll bring everything together in a **capstone project** — building a complete, production-ready application from scratch. You'll design the data model, implement CRUD and query endpoints with the SDK, add change feed processing, secure the app with Entra ID and RBAC, wire up monitoring and distributed tracing, write a full test suite, and deploy to Azure with Bicep and a CI/CD pipeline.
