# Chapter 9: Request Units In Depth

Every database has a cost model, but most of them hide it behind vague concepts like "compute hours" or "I/O operations." Azure Cosmos DB takes a radically different approach: it gives you a single, deterministic currency called the **Request Unit (RU)**. Every operation you perform—reads, writes, queries, stored procedures—returns an exact RU charge in the response. Once you understand how RUs work, you can predict costs, diagnose bottlenecks, and optimize your application with surgical precision.

In this chapter, you'll learn what drives RU costs for different operation types, how to measure them, and—most importantly—how to spend fewer of them.

## Breaking Down RU Cost by Operation Type

Not all operations are created equal. A point read and a cross-partition query can differ by orders of magnitude in RU cost, even when they return the same data. Let's walk through the major categories.

### Point Reads: The Cheapest Operation

A **point read** is a direct key/value lookup: you provide both the item's `id` and its partition key, and Cosmos DB retrieves the document in a single, index-free hop. This is the most efficient operation in the entire system.

The cost is beautifully simple—it scales linearly with item size:

| Item Size | Point Read Cost |
|-----------|----------------|
| 1 KB      | 1 RU           |
| 10 KB     | ~3 RUs         |
| 100 KB    | ~10 RUs        |

A few things to keep in mind:

- Point reads are only available through the SDK or REST API. A query like `SELECT * FROM c WHERE c.id = @id AND c.pk = @pk` is *not* a point read—even though it returns one item, it still goes through the query engine and costs more.
- If you're using **strong** or **bounded staleness** consistency, the RU cost of any read operation is **doubled**. With session, consistent prefix, or eventual consistency, you pay the standard rate.
- Point reads always use the read region closest to your client, making them not just cheap but also fast—typically under 10 milliseconds.

The takeaway: if you know an item's `id` and partition key, always use `ReadItemAsync`, never a query.

### Writes: Inserts, Replaces, Upserts, and Deletes

Writes are more expensive than reads because Cosmos DB must update the document, maintain indexes, replicate data, and write to a transaction log. The RU cost of a write depends on two factors:

1. **Item size** — larger documents cost more to write.
2. **Indexing overhead** — the more properties you index, the more RUs each write consumes.

Here are some baseline numbers from the official documentation:

| Operation                        | Approximate Cost (1 KB item) |
|----------------------------------|------------------------------|
| Insert (with default indexing)   | ~5–7 RUs (varies with number of indexed properties) |
| Insert (no indexing)             | ~5.5 RUs                     |
| Replace                          | ~10–11 RUs                   |
| Upsert                           | ~5.5–11 RUs                  |
| Delete                           | ~5.5 RUs                     |

A **replace** effectively costs about twice what an insert does for the same item, because Cosmos DB must remove the old index entries and create new ones. An **upsert** costs the same as an insert if the item doesn't exist, or roughly the same as a replace if it does.

One important nuance: these numbers assume the default indexing policy, which indexes *every* property. If your items have 50 properties but your queries only filter on 3, you're paying index maintenance costs for 47 properties you'll never search on. We'll come back to this in the optimization section.

### Queries: Where RU Costs Get Interesting

Queries are the most variable operation in terms of RU cost. The charge depends on:

- **Number of items scanned** — even if you return 10 items, the query engine might scan thousands.
- **Number of items returned** — larger result sets cost more to serialize and transfer.
- **Index utilization** — queries that can be fully satisfied by the index are dramatically cheaper than those requiring full scans.
- **Query complexity** — aggregations, JOINs, UDFs, and ORDER BY on non-indexed paths add CPU cost.
- **Cross-partition fan-out** — if your query doesn't include the partition key, Cosmos DB must execute it against every physical partition in parallel, then merge results. Each partition incurs its own RU charge, and they all add up.

To give you a concrete sense of the range: a well-targeted single-partition query returning a handful of 1 KB items might cost 3–5 RUs. The same query without a partition key filter, fanned out across 20 physical partitions, could easily cost 60–100+ RUs—even if it returns the same data.

**Fan-out queries** deserve special attention. When a query lacks a partition key filter, the SDK sends it to *every* physical partition. Each partition processes the query independently, consuming RUs against that partition's throughput budget. A container with 50 physical partitions will execute 50 sub-queries. If each sub-query costs 3 RUs, the total is 150 RUs—even if most partitions return zero results. As your data grows and partitions split, fan-out costs grow proportionally.

The query metrics returned by the SDK are invaluable for understanding where RUs are being spent. Here's an example of what they look like:

```
Retrieved Document Count        :          1
Retrieved Document Size         :      9,963 bytes
Output Document Count           :          1
Output Document Size            :     10,012 bytes
Index Utilization               :     100.00 %
Total Query Execution Time      :       0.48 milliseconds
  Query Compilation Time        :       0.07 milliseconds
  Index Lookup Time             :       0.06 milliseconds
  Document Load Time            :       0.03 milliseconds
  Runtime Execution Times
    Query Engine Time           :       0.03 milliseconds
  Client Side Metrics
    Request Charge              :       3.19 RUs
```

Notice the **Index Utilization** metric. At 100%, the query was fully served by the index. If you see this number drop, you're doing partial or full scans—and your RU bill will reflect it.

### Stored Procedures and Triggers

Stored procedures and triggers execute server-side JavaScript within a single partition key scope. Their RU cost is the sum of all operations they perform internally. If a stored procedure reads 10 items and writes 5, you pay the read RUs plus the write RUs, all bundled into a single response charge.

Because stored procedures run within a transaction boundary on a single partition, they don't incur cross-partition overhead. However, complex procedures that loop through large datasets can accumulate significant RU charges. The response from `ExecuteStoredProcedureAsync` includes the total `RequestCharge`, so you can measure the cost just like any other operation.

Pre-triggers and post-triggers add their RU cost on top of the triggering operation. A pre-trigger that validates a document before a write will increase the total RU charge of that write.

## Finding the RU Charge for Any Operation

Every single response from Cosmos DB includes an `x-ms-request-charge` header with the exact RU cost. The SDKs surface this as a `RequestCharge` property on every response object, making it trivial to log and monitor.

### Reading RU Charges in the .NET SDK

Here's how to capture the RU charge for the three most common operation types using the .NET SDK v3:

```csharp
using Microsoft.Azure.Cosmos;

Container container = cosmosClient.GetContainer("myDatabase", "myContainer");

// --- Point read ---
ItemResponse<Product> readResponse = await container.ReadItemAsync<Product>(
    id: "product-42",
    partitionKey: new PartitionKey("electronics"));

Console.WriteLine($"Point read cost: {readResponse.RequestCharge} RUs");

// --- Write (create) ---
var newProduct = new Product { Id = "product-99", Category = "electronics", Name = "Widget" };
ItemResponse<Product> writeResponse = await container.CreateItemAsync(
    item: newProduct,
    partitionKey: new PartitionKey(newProduct.Category));

Console.WriteLine($"Create cost: {writeResponse.RequestCharge} RUs");

// --- Query (paginated) ---
double totalQueryRUs = 0;
FeedIterator<Product> iterator = container.GetItemQueryIterator<Product>(
    queryText: "SELECT * FROM c WHERE c.category = 'electronics' AND c.price > 100",
    requestOptions: new QueryRequestOptions
    {
        PartitionKey = new PartitionKey("electronics")
    });

while (iterator.HasMoreResults)
{
    FeedResponse<Product> page = await iterator.ReadNextAsync();
    totalQueryRUs += page.RequestCharge;
    Console.WriteLine($"  Page cost: {page.RequestCharge} RUs ({page.Count} items)");
}

Console.WriteLine($"Total query cost: {totalQueryRUs} RUs");

// --- Stored procedure ---
Scripts scripts = container.Scripts;
StoredProcedureExecuteResponse<string> sprocResponse =
    await scripts.ExecuteStoredProcedureAsync<string>(
        storedProcedureId: "bulkDelete",
        partitionKey: new PartitionKey("electronics"),
        parameters: new dynamic[] { "obsolete" });

Console.WriteLine($"Stored procedure cost: {sprocResponse.RequestCharge} RUs");
```

Notice that for queries, you must sum the `RequestCharge` across all pages. A query that returns results in three pages might show 2.8, 3.1, and 2.5 RUs per page—for a total of 8.4 RUs.

### Using the Azure Portal

If you'd rather not instrument your code, the Azure portal provides built-in metrics. Navigate to your Cosmos DB account and open the **Metrics** blade. Key metrics to watch:

- **Total Request Units** — the aggregate RU consumption over time, broken down by operation type.
- **Total Requests** — helps you correlate RU spikes with request volume.
- **429 (Rate Limited) Requests** — the number of requests that exceeded your provisioned throughput.

You can also filter these metrics by partition key range, which is useful for identifying hot partitions that consume disproportionate RUs.

In **Data Explorer**, every query you run displays the RU charge in the results pane—a handy way to experiment with query optimizations interactively.

## RU Budgeting for Your Application

Before you provision throughput, you need an RU budget. Let's work through a concrete example.

### Scenario: An E-Commerce Product Catalog

Imagine you're building a product catalog with the following expected workload during peak hours:

| Operation                              | Ops/Second | RU per Op | RUs/Second |
|----------------------------------------|------------|-----------|------------|
| Point reads (product detail pages)     | 500        | 1         | 500        |
| Single-partition queries (search by category) | 50   | 8         | 400        |
| New product inserts                    | 10         | 6         | 60         |
| Product updates (replace)              | 20         | 11        | 220        |
| Cross-partition queries (admin search) | 5          | 50        | 250        |
| **Total**                              |            |           | **1,430**  |

You'd provision at least **1,500 RU/s** to give yourself some headroom. In practice, you'd add a 20–30% buffer for traffic spikes, bringing you to roughly **1,800–2,000 RU/s**.

A few budgeting tips:

- **Measure with real data.** The numbers above are estimates. Use the SDK's `RequestCharge` property with representative documents and queries to get actual costs before going to production.
- **Use the [Capacity Calculator](https://cosmos.azure.com/capacitycalculator/).** Microsoft provides an online tool where you upload a sample document and describe your workload. It gives you a recommended RU/s figure.
- **Think in RU/s, not monthly cost.** Cosmos DB bills per RU/s per hour. 400 RU/s is the minimum for a single container. You can scale up and down dynamically using autoscale (which ranges from 10% to 100% of a configured maximum) to handle variable workloads without over-provisioning.
- **Watch for 429s.** If your application starts receiving HTTP 429 (Too Many Requests) responses, you've exceeded your provisioned throughput. The SDK retries automatically with exponential backoff, but frequent 429s mean you need to either increase throughput or optimize your operations.

## Strategies to Reduce RU Consumption

Now for the fun part. Here are the most impactful techniques for squeezing more performance out of fewer RUs.

### 1. Optimize Query Predicates and Avoid Full Scans

The single biggest RU killer is queries that can't use the index effectively. A query like:

```sql
SELECT * FROM c WHERE CONTAINS(c.description, "wireless")
```

This forces a full scan of every document in the partition (or every partition, if no partition key is specified). Cosmos DB must load each document and evaluate the predicate in-memory.

Instead, design your data model so you can use equality and range filters on indexed properties:

```sql
SELECT * FROM c WHERE c.category = "electronics" AND c.price > 50
```

This query leverages the index on `category` and `price`, resulting in dramatically lower RU consumption.

### 2. Prefer Point Reads Over Queries for Known IDs

This bears repeating because it's one of the most common mistakes. If your code does this:

```sql
SELECT * FROM c WHERE c.id = "product-42"
```

You're paying query overhead (compilation, index lookup, serialization) for something that could be a 1 RU point read. Always use `ReadItemAsync` when you know both the `id` and partition key.

### 3. Use Projections to Fetch Only Needed Fields

If you only need a product's name and price, don't retrieve the entire 10 KB document:

```sql
-- Expensive: returns entire document
SELECT * FROM c WHERE c.category = "electronics"

-- Cheaper: returns only needed fields
SELECT c.id, c.name, c.price FROM c WHERE c.category = "electronics"
```

Projections reduce the **Output Document Size**, which directly reduces the RU charge. The savings are proportional to how much data you're excluding.

### 4. Tune Indexing to Exclude Unused Paths

Cosmos DB's default indexing policy indexes every property in every document—a convenience that becomes expensive in production. Each indexed property adds to the RU cost of every write operation.

If your queries only filter on `category`, `price`, and `createdDate`, exclude everything else:

```json
{
  "indexingMode": "consistent",
  "includedPaths": [
    { "path": "/category/?" },
    { "path": "/price/?" },
    { "path": "/createdDate/?" }
  ],
  "excludedPaths": [
    { "path": "/*" }
  ]
}
```

This approach can reduce write RU costs significantly—sometimes by 30–50% depending on document complexity. The tradeoff is that queries filtering on excluded paths will trigger expensive full scans, so be deliberate about what you include.

> **Tip:** The `id` and `_ts` properties are always indexed regardless of your indexing policy. However, the partition key path is **not** automatically indexed — if you exclude the root wildcard path, include your partition key path explicitly to avoid expensive full scans on queries that filter by partition key.

### 5. Use the Patch API for Partial Updates

If you need to update a single field on a document—say, incrementing an inventory count—the traditional approach is read-modify-write: fetch the full document, change the field locally, and send the entire document back with `ReplaceItemAsync`. You pay for a point read *plus* a full replace. As we explored in Chapter 6, the Patch API offers a much more efficient alternative.

The **Patch API** (partial document update) lets you modify individual properties server-side without reading or sending the full document:

```csharp
var patchOperations = new List<PatchOperation>
{
    PatchOperation.Increment("/inventory/quantity", 10),
    PatchOperation.Set("/lastUpdated", DateTime.UtcNow)
};

ItemResponse<Product> response = await container.PatchItemAsync<Product>(
    id: "product-42",
    partitionKey: new PartitionKey("electronics"),
    patchOperations: patchOperations);

Console.WriteLine($"Patch cost: {response.RequestCharge} RUs");
```

The Patch API supports `Add`, `Set`, `Replace`, `Remove`, `Increment`, and `Move` operations. You can batch up to 10 patch operations in a single request. Because only the changed paths are written, you save on both network bandwidth and RU cost compared to a full replace—especially for large documents.

An additional benefit: in multi-region write configurations, patch operations on *different paths* of the same document are automatically conflict-resolved at the path level, rather than the document level. Two regions can concurrently patch different fields without triggering Last Write Wins at the document level.

## Priority-Based Execution

Sometimes you can't avoid RU contention. Your container handles both user-facing reads and background data ingestion, and during peak load, both workloads compete for the same provisioned throughput. When total demand exceeds your RU/s budget, *something* gets throttled—but which workload should it be?

**Priority-based execution** lets you tag each request as either **High** or **Low** priority. When the container is under pressure, Cosmos DB throttles low-priority requests first, preserving throughput for high-priority work. When there's no contention, both priority levels can use the full provisioned throughput—there's no reservation or partitioning of RUs between levels.

### Enabling the Feature

Priority-based execution must be enabled at the account level. You can do this in the Azure portal (under **Features**) or via the CLI:

```bash
az cosmosdb update \
  -g myResourceGroup \
  -n myCosmosAccount \
  --enable-priority-based-execution true
```

By default, all requests are treated as **High** priority. You can change the account-wide default to **Low** if you want to opt-in to high priority explicitly:

```bash
az cosmosdb update \
  -g myResourceGroup \
  -n myCosmosAccount \
  --default-priority-level low
```

### Using Priority Levels in Code

In the .NET SDK (v3.38.0+), set the `PriorityLevel` property on your request options:

```csharp
using Microsoft.Azure.Cosmos;

// User-facing read — high priority
var readOptions = new ItemRequestOptions { PriorityLevel = PriorityLevel.High };
ItemResponse<Product> product = await container.ReadItemAsync<Product>(
    "product-42",
    new PartitionKey("electronics"),
    readOptions);

// Background catalog sync — low priority
var writeOptions = new ItemRequestOptions { PriorityLevel = PriorityLevel.Low };
ItemResponse<Product> syncResponse = await container.CreateItemAsync(
    bulkProduct,
    new PartitionKey(bulkProduct.Category),
    writeOptions);
```

For queries, set the priority on `QueryRequestOptions`:

```csharp
var queryOptions = new QueryRequestOptions
{
    PartitionKey = new PartitionKey("electronics"),
    PriorityLevel = PriorityLevel.Low
};

FeedIterator<Product> iterator = container.GetItemQueryIterator<Product>(
    "SELECT * FROM c",
    requestOptions: queryOptions);
```

### When to Use It

Priority-based execution shines when you have mixed workloads on the same container:

- **User-facing reads and writes** → High priority
- **Background data ingestion or migration** → Low priority
- **Stored procedure batch jobs** → Low priority
- **Analytics or reporting queries** → Low priority

A few things to keep in mind:

- This feature operates on a **best-effort** basis. It doesn't guarantee that low-priority requests are always throttled before high-priority ones—there are no SLAs on the behavior.
- It's **not supported on serverless accounts**, only on provisioned throughput.
- It's **free**—there's no additional charge for enabling or using priority levels.
- The SDK's built-in retry logic handles throttled low-priority requests automatically, so your background workload will complete eventually—it just yields gracefully to user-facing traffic during contention.

## Putting It All Together

RU management isn't something you do once during initial setup and then forget about. It's an ongoing discipline:

1. **Measure first.** Instrument your application to log `RequestCharge` for every operation, or at least for your most frequent operations. You can't optimize what you can't see.
2. **Budget realistically.** Use representative documents and queries to calculate your expected RU/s, add a buffer, and configure autoscale so you don't overpay during quiet hours.
3. **Optimize the big wins.** Point reads instead of queries, projections instead of `SELECT *`, targeted indexing instead of index-everything—these three changes alone often cut RU consumption in half.
4. **Use Patch for partial updates.** Every full replace on a large document is a missed opportunity to use the Patch API.
5. **Prioritize your workloads.** Tag background tasks as low priority so your users never feel the impact of a batch job.

## What's Next

You now have a thorough understanding of how Cosmos DB charges for operations and how to keep those charges under control. In **Chapter 10**, we'll explore how to **provision that throughput** — comparing manual provisioned throughput, autoscale, and serverless capacity modes. You'll learn about burst capacity, throughput buckets, how to switch between modes, and a decision framework for choosing the right capacity model for your workload.
