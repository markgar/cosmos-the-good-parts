# Chapter 15: The Change Feed

Every write to a Cosmos DB container — every insert, every update — gets recorded in an ordered, persistent log. That log is the **change feed**, and it's the foundation for every reactive pattern in this book. It turns Cosmos DB from a database you query into a database that *tells you* when something happens.

You don't enable the change feed. It's on by default for every container, with zero configuration and no additional cost beyond the RUs you spend reading it. There's no toggle, no opt-in, no separate storage tier. Every container has a change feed from the moment it's created, whether you use it or not.
<!-- Source: change-feed.md -->

The implications are significant. The change feed enables you to:

- Build event-driven architectures where downstream systems react in near-real-time to data changes
- Maintain materialized views that stay synchronized without polling
- Stream data to caches, search indexes, or analytics pipelines
- Replicate data to other databases or regions
- Trigger workflows from the simple act of writing to a container

If you read Chapter 4's discussion of denormalization and Chapter 6's event sourcing pattern, the change feed is the mechanism that makes those patterns practical.

## What the Change Feed Captures

The change feed is a persistent, ordered log of changes to items in a container. Each change appears exactly once, and within a given logical partition, changes are guaranteed to arrive in modification order. Across partition key values, there's no ordering guarantee — we'll come back to why that matters. Here's how to consume it and what patterns it enables.
<!-- Source: change-feed.md -->

Items written within a transactional batch, stored procedure, or bulk operation share the same modification timestamp. Changes within that scope may arrive in any order, but they'll all be present.
<!-- Source: change-feed.md -->

### Sort Order

Changes are sorted by modification time *within* each logical partition. If customer `cust-337` places three orders in sequence, you'll see those three inserts in order. But if `cust-337` and `cust-500` both write at the same instant, there's no guarantee which appears first. If your application needs a total ordering across all partitions, you'll need to implement that yourself — the change feed gives you per-partition ordering only.
<!-- Source: change-feed.md, change-feed-design-patterns.md -->

For multi-region write accounts, sorting is based on the conflict-resolved timestamp (`crts`) — the time at which a conflict was resolved (or the absence of a conflict confirmed) in the hub region. This is a detail that matters if you're running multi-region writes and processing the change feed: the order reflects when conflicts are settled, not necessarily when the write originally occurred in the local region.
<!-- Source: change-feed.md, multi-region-writes.md -->

## Change Feed Modes

Cosmos DB offers two change feed modes. You can consume the same container's change feed in both modes simultaneously from different applications — they're independent.
<!-- Source: change-feed-modes.md -->

### Latest Version Mode (Default)

**Latest version mode** is the default and the one you'll use in most scenarios. It captures two kinds of operations:

- **Inserts** — a new item is created
- **Updates** — an existing item is modified

That's it. Deletes are *not* captured. If you delete an item, it vanishes from the change feed as if it never existed. The all versions and deletes mode (covered next) addresses this, but understanding this limitation is critical — it affects how you design systems that depend on the feed.

There's another subtlety: the change feed delivers the *current* state of each item, not a diff. When you read a change, you get the full JSON document as it exists after the modification. If an item was updated three times between your reads, you see only the final version — the intermediate states are gone. This is a log of "what changed," not a log of "every mutation that happened."
<!-- Source: change-feed-modes.md -->

Key characteristics:

- **No delete detection.** To work around this, use a **soft-delete pattern**: add a `deleted: true` property and set a TTL on the item. The change feed captures the update (the soft-delete marker), and the item is automatically removed when the TTL expires.
- **No intermediate versions.** Only the latest version of a changed item is in the feed. If an item was updated five times between reads, you see the fifth version only.
- **Unlimited retention.** Changes are available for as long as the item exists in the container. You can read from the beginning of the container's lifetime — there's no expiration window.
- **Flexible starting point.** You can start reading from the beginning of the container, from a specific point in time (with approximately five-second precision), from "now," or from a saved checkpoint.
<!-- Source: change-feed-modes.md -->

Latest version mode is compatible with all consumption methods: change feed processor, Azure Functions trigger, pull model, and Spark connector. It works with all Cosmos DB account types that support the NoSQL API.

### All Versions and Deletes Mode (Preview)
<!-- Source: change-feed-modes.md — still in preview as of June 2025. Verify status before press. -->

**All versions and deletes mode** is in preview and addresses the biggest limitation of latest version mode: it captures deletes, intermediate changes, and TTL expirations. Every create, update, and delete is recorded as a separate entry, with metadata indicating the operation type.
<!-- Source: change-feed-modes.md -->

There are prerequisites and constraints:

- **Continuous backups required.** You must have continuous backups configured on your account before enabling this mode. Enabling the feature can take up to 30 minutes, and no other account changes can be made during that time.
- **NoSQL API only.** Other APIs aren't supported.
- **Retention is limited** to the continuous backup retention period. With a 7-day retention window, you can't read changes from 8 days ago. This is fundamentally different from latest version mode's unlimited retention.
- **No reading from the beginning** or from a specific point in time. You can start from "now" or resume from a saved continuation token or lease within the retention window.
- **Accounts with merged partitions are not supported.** <!-- Source: change-feed-modes.md -->

The response payloadis richer than latest version mode. Each entry includes a `metadata` object with the `operationType` (`create`, `replace`, or `delete`) and a `crts` (conflict-resolved timestamp). Delete operations include the item's `id` and partition key, plus a `timeToLiveExpired` flag when the delete resulted from TTL expiration. A `current` object holds the item's state for creates and replaces; it's absent for deletes.

Here's what a delete record looks like:

```json
{
  "metadata": {
    "operationType": "delete",
    "lsn": 42,
    "crts": 1719235200,
    "previousImageLSN": 41,
    "timeToLiveExpired": false,
    "id": "order-2001",
    "partitionKey": {
      "customerId": "cust-337"
    }
  }
}
```
<!-- Source: change-feed-modes.md -->

> **Gotcha:** The previous version of the item is *not* available in either mode. For deletes, you get the `id` and partition key but not the full document that was deleted. If your downstream system needs the pre-delete state, you must capture it before the delete happens.

### Choosing Between Modes

| Consideration | Latest Version | All Versions and Deletes |
|---|---|---|
| **Captures deletes** | No (soft-delete workaround) | Yes |
| **Intermediate changes** | Only latest version | All versions preserved |
| **Retention** | Unlimited (life of the container) | Continuous backup retention period |
| **Starting point** | Beginning, point in time, now, checkpoint | Now or checkpoint only |
| **Prerequisites** | None | Continuous backups enabled |
| **Azure Functions trigger** | Supported | Not supported |
| **Status** | GA | Preview |
<!-- Source: change-feed-modes.md -->

For most production workloads today, latest version mode is the right choice. It's GA, has no prerequisites, supports all consumption methods, and its unlimited retention makes it resilient to downstream outages — you can always catch up. Reach for all versions and deletes mode when you specifically need delete capture without soft-delete workarounds, when you need audit trails of every mutation, or when intermediate state changes matter to your business logic.

## Consuming the Change Feed

There are four ways to read the change feed, each suited to different scenarios and levels of control. Let's walk through them from simplest to most hands-on.

### Azure Functions Trigger

The Azure Functions trigger for Cosmos DB is the simplest way to consume the change feed. It's built on top of the change feed processor internally, so you get the same reliable event detection and automatic parallelization — but you don't manage any infrastructure.
<!-- Source: change-feed-functions.md, read-change-feed.md -->

You create a function, point it at a container, and write your business logic. Azure Functions handles scaling, checkpointing, and lease management behind the scenes. When changes arrive, your function is invoked with a batch of modified documents.

The trigger requires two containers: the **monitored container** (the one generating changes) and a **lease container** (which tracks processing state). The lease container can be auto-created if you set `CreateLeaseContainerIfNotExists` in your trigger configuration. Partitioned lease containers must use `/id` as the partition key.
<!-- Source: change-feed-functions.md -->

Here's a minimal C# Azure Function that processes change feed events:

```csharp
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;

public class OrderChangeFeedFunction
{
    private readonly ILogger<OrderChangeFeedFunction> _logger;

    public OrderChangeFeedFunction(ILogger<OrderChangeFeedFunction> logger)
    {
        _logger = logger;
    }

    [Function(nameof(OrderChangeFeedFunction))]
    public void Run(
        [CosmosDBTrigger(
            databaseName: "ecommerce",
            containerName: "orders",
            Connection = "CosmosDBConnection",
            LeaseContainerName = "leases",
            CreateLeaseContainerIfNotExists = true)]
        IReadOnlyList<Order> changes)
    {
        foreach (var order in changes)
        {
            _logger.LogInformation("Order {OrderId} changed, status: {Status}",
                order.Id, order.Status);

            // Downstream logic: update a materialized view, 
            // send a notification, invalidate a cache, etc.
        }
    }
}
```

There are two important caveats. First, the Azure Functions trigger currently only supports **latest version mode** — you can't use it with all versions and deletes mode. Second, error handling follows the same rules as the underlying change feed processor: if your function throws an unhandled exception, the trigger *does not* advance past the failed batch. The processing thread stops, a new thread picks up from the last checkpoint, and the same batch of changes is delivered to your function again. This continues until the batch succeeds, which means a poison message can stall processing. Build dead-letter logic (a `try`/`catch` that routes failures to a secondary store) so one bad item doesn't block the entire feed.
<!-- Source: change-feed-processor.md -->

We'll explore deeper Azure Functions integration patterns — scaling configuration, batching behavior, and combining triggers with output bindings — in Chapter 22.

### Change Feed Processor

The **change feed processor** is the most common way to consume the change feed in application code. It's built into the .NET V3 and Java V4 SDKs, and it handles the hard parts: partition distribution, lease management, checkpointing, and fault-tolerant delivery with an **at-least-once guarantee**.
<!-- Source: change-feed-processor.md, read-change-feed.md -->

The change feed processor has four components:

| Component | Role |
|---|---|
| **Monitored container** | The container whose changes you're consuming |
| **Lease container** | Stores processing state — one lease document per physical partition range |
| **Compute instance** | The host running your processor (a VM, a pod, an App Service instance) |
| **Delegate** | Your code — a function that receives each batch of changes |
<!-- Source: change-feed-processor.md -->

Here's a production-realistic C# example:

```csharp
Container monitoredContainer = cosmosClient.GetContainer("ecommerce", "orders");
Container leaseContainer = cosmosClient.GetContainer("ecommerce", "leases");

ChangeFeedProcessor processor = monitoredContainer
    .GetChangeFeedProcessorBuilder<Order>(
        processorName: "orderProjection",
        onChangesDelegate: HandleChangesAsync)
    .WithInstanceName(Environment.MachineName)
    .WithLeaseContainer(leaseContainer)
    .Build();

await processor.StartAsync();

// Delegate: process each batch of changes
static async Task HandleChangesAsync(
    ChangeFeedProcessorContext context,
    IReadOnlyCollection<Order> changes,
    CancellationToken cancellationToken)
{
    Console.WriteLine($"Lease {context.LeaseToken}: {changes.Count} changes, " +
                      $"{context.Headers.RequestCharge} RUs consumed");

    foreach (Order order in changes)
    {
        // Update materialized view, push to Event Hub, etc.
        await ProjectOrderToViewAsync(order);
    }
}
```

The processor distributes work automatically. Each physical partition range in the monitored container gets a lease document. If you deploy three instances of your application (each with a unique `WithInstanceName`), the processor divides the leases equally among them. Add a fourth instance? The leases rebalance. One instance crashes? Its leases are picked up by the survivors after the lease expiration period (60 seconds by default).
<!-- Source: change-feed-processor.md -->

**Error handling** deserves attention. If your delegate throws an unhandled exception, the processor restarts processing from the last successful checkpoint and re-delivers the same batch. This continues until your delegate succeeds — which means a poison message can stall processing for that partition range. The fix: wrap your delegate in a try/catch and write failed items to a dead-letter container or queue, then move on.
<!-- Source: change-feed-processor.md -->

> **Gotcha:** Always use a **global endpoint** (e.g., `contoso.documents.azure.com`) when creating the `CosmosClient` for your change feed processor, not a regional endpoint. The processor creates lease documents scoped to the configured endpoint — if you switch from a regional to a global endpoint later, it creates new independent leases and you'll reprocess everything. Use `ApplicationPreferredRegions` to control which region serves the traffic.
<!-- Source: change-feed-processor.md -->

Three lease timing parameters let you tune the processor's behavior:

| Parameter | Default | What It Controls |
|---|---|---|
| **Lease Acquire** | 17 seconds | How often hosts check for unowned leases |
| **Lease Expiration** | 60 seconds | How long before a dead host's leases are reassigned |
| **Lease Renewal** | 13 seconds | How often an active host renews its lease |
<!-- Source: change-feed-processor.md -->

Lowering these values speeds up recovery from failures but increases RU consumption on the lease container. The defaults are reasonable for most workloads.

The change feed processor supports both latest version mode and all versions and deletes mode. For all versions and deletes, use `GetChangeFeedProcessorBuilderWithAllVersionsAndDeletes` instead, and your delegate receives `ChangeFeedItem<T>` objects with metadata:

```csharp
ChangeFeedProcessor processor = monitoredContainer
    .GetChangeFeedProcessorBuilderWithAllVersionsAndDeletes<Order>(
        processorName: "orderAudit",
        onChangesDelegate: HandleAllChangesAsync)
    .WithInstanceName(Environment.MachineName)
    .WithLeaseContainer(leaseContainer)
    .Build();

static async Task HandleAllChangesAsync(
    ChangeFeedProcessorContext context,
    IReadOnlyCollection<ChangeFeedItem<Order>> changes,
    CancellationToken cancellationToken)
{
    foreach (var change in changes)
    {
        if (change.Metadata.OperationType == ChangeFeedOperationType.Delete)
        {
            Console.WriteLine($"Order deleted: {change.Metadata.OperationType}");
        }
        else
        {
            Console.WriteLine($"Order {change.Current.Id}: {change.Metadata.OperationType}");
        }
    }
}
```
<!-- Source: change-feed-processor.md -->

### SDK Pull Model

The **pull model** gives you the most control. Instead of the change feed pushing batches to your delegate, you pull changes at your own pace using a `FeedIterator`. There's no automatic lease management, no parallelization, no retry logic. You handle all of that yourself.
<!-- Source: change-feed-pull-model.md, read-change-feed.md -->

Use the pull model when you need to:

- Read changes for a **specific partition key** (the change feed processor can't do this)
- **Control the pace** at which you consume changes
- Perform a **one-time read** of existing data, like a migration
<!-- Source: change-feed-pull-model.md -->

Here's the pull model in C#:

```csharp
Container container = cosmosClient.GetContainer("ecommerce", "orders");

FeedIterator<Order> iterator = container.GetChangeFeedIterator<Order>(
    ChangeFeedStartFrom.Beginning(),
    ChangeFeedMode.LatestVersion);

while (iterator.HasMoreResults)
{
    FeedResponse<Order> response = await iterator.ReadNextAsync();

    if (response.StatusCode == HttpStatusCode.NotModified)
    {
        // No new changes — save the continuation token and check later
        string continuation = response.ContinuationToken;
        await Task.Delay(TimeSpan.FromSeconds(5));
        continue;
    }

    foreach (Order order in response)
    {
        Console.WriteLine($"Changed order: {order.Id}");
    }
}
```

And in Python:

```python
container = database.get_container_client("orders")

response = container.query_items_change_feed(start_time="Beginning")
for item in response:
    print(f"Changed item: {item['id']}")

# Save the continuation token for later
continuation_token = container.client_connection.last_response_headers['etag']

# Later, resume from where we left off
response = container.query_items_change_feed(continuation=continuation_token)
for item in response:
    print(f"New change: {item['id']}")
```
<!-- Source: change-feed-pull-model.md -->

The `HasMoreResults` property is always `true` — the change feed is conceptually infinite. When there are no new changes, you receive an HTTP 304 `NotModified` status. Your code must handle this case explicitly by pausing and polling again later.
<!-- Source: change-feed-pull-model.md -->

For parallelization, you can fetch `FeedRange` values from the container (one per physical partition) and create separate iterators for each range:

```csharp
IReadOnlyList<FeedRange> ranges = await container.GetFeedRangesAsync();

// Distribute ranges across workers — each processes its own slice
foreach (FeedRange range in ranges)
{
    FeedIterator<Order> rangeIterator = container.GetChangeFeedIterator<Order>(
        ChangeFeedStartFrom.Beginning(range),
        ChangeFeedMode.LatestVersion);

    // Process this range on a separate thread or machine
}
```
<!-- Source: change-feed-pull-model.md -->

| Feature | Change Feed Processor | Pull Model |
|---|---|---|
| **Progress tracking** | Automatic (lease container) | Manual (continuation tokens) |
| **Parallelization** | Automatic across instances | Manual via FeedRange |
| **Error handling** | Automatic retry (at-least-once) | You handle it |
| **Partition key filtering** | Not supported | Supported |
| **Polling** | Automatic (configurable interval) | Manual |
<!-- Source: change-feed-pull-model.md -->

**Continuation tokens in latest version mode never expire** as long as the container exists. In all versions and deletes mode, tokens are valid only within the continuous backup retention window.
<!-- Source: change-feed-pull-model.md -->

### Apache Spark Connector

The Spark connector reads the change feed at scale through Spark Structured Streaming. Built on the Java SDK's pull model, it distributes processing transparently across Spark executors and provides built-in checkpointing — something you'd have to build yourself with the raw pull model.
<!-- Source: change-feed-spark.md -->

This is the right choice when your change feed processing involves complex transformations, aggregations, or joins with other datasets — workloads where Spark's distributed compute model shines. For simpler per-document processing, the change feed processor or pull model are better fits.

```python
change_feed_config = {
    "spark.cosmos.accountEndpoint": cosmosEndpoint,
    "spark.cosmos.accountKey": cosmosKey,
    "spark.cosmos.database": "ecommerce",
    "spark.cosmos.container": "orders",
    "spark.cosmos.changeFeed.startFrom": "Beginning",
    "spark.cosmos.changeFeed.mode": "LatestVersion",
    "spark.cosmos.changeFeed.itemCountPerTriggerHint": "50000",
}

change_feed_df = (spark
    .readStream
    .format("cosmos.oltp.changeFeed")
    .options(**change_feed_config)
    .load())

query = (change_feed_df
    .writeStream
    .format("cosmos.oltp")
    .outputMode("append")
    .option("checkpointLocation", "/mnt/checkpoints/order-feed")
    .options(**output_config)
    .start())
```
<!-- Source: change-feed-spark.md -->

One important behavior: the `spark.cosmos.changeFeed.startFrom` configuration is **ignored** if existing checkpoints are found at the checkpoint location. The connector always resumes from the last processed position. This is by design — it prevents duplicate processing after restarts — but it surprises people who change the start position and expect it to take effect.
<!-- Source: change-feed-spark.md -->

The Spark connector supports both latest version and all versions and deletes mode. If you don't set `itemCountPerTriggerHint`, all available data is processed in the first micro-batch, which can be a very expensive operation on a large container.

### Which Consumer Should You Choose?

| Scenario | Best Fit |
|---|---|
| Serverless, reactive processing with minimal infrastructure | **Azure Functions trigger** |
| Long-running service with automatic scaling and fault tolerance | **Change feed processor** |
| One-time migration or targeted partition key reads | **Pull model** |
| Large-scale ETL, joins with other datasets, Spark pipelines | **Spark connector** |

## Common Change Feed Patterns

The change feed is a building block. The real power is in the patterns it enables.

### Event-Driven Microservices

In a microservices architecture, services need to react to data changes in other services without tight coupling. The change feed is a natural fit: Service A writes to its Cosmos DB container, and Service B consumes the change feed to react. No polling, no message bus between them (though you might add one for durability — see the streaming pipeline pattern below).

Consider an e-commerce system. The order service writes new orders to a `orders` container. The fulfillment service consumes the change feed and kicks off warehouse workflows. The notification service reads the same change feed independently and sends confirmation emails. Each service has its own change feed processor deployment unit with its own `processorName`, processing the same feed for its own purposes.
<!-- Source: change-feed-design-patterns.md -->

This works because multiple applications can subscribe to the same container's change feed simultaneously — each maintains its own leases and processes changes independently.

### Real-Time Materialized Views

Chapter 4 introduced the concept of denormalization — storing data redundantly to optimize reads. The challenge is keeping those copies in sync. The change feed solves this elegantly.

Say you have a `products` container partitioned by `productId` and a `productsByCategory` container partitioned by `categoryId`. When a product's price changes in the source container, a change feed processor picks up the change and updates the corresponding document in the view container. The view is eventually consistent — there's a small window where the materialized view lags behind the source — but for most applications, that delay is measured in milliseconds to low seconds.
<!-- Source: change-feed-design-patterns.md -->

```csharp
static async Task HandleChangesAsync(
    ChangeFeedProcessorContext context,
    IReadOnlyCollection<Product> changes,
    CancellationToken cancellationToken)
{
    foreach (Product product in changes)
    {
        // Update the category-based materialized view
        var viewItem = new ProductByCategory
        {
            Id = product.Id,
            CategoryId = product.CategoryId,
            Name = product.Name,
            Price = product.Price,
            LastModified = DateTime.UtcNow
        };

        await categoryViewContainer.UpsertItemAsync(
            viewItem,
            new PartitionKey(viewItem.CategoryId),
            cancellationToken: cancellationToken);
    }
}
```

This is the same materialized view pattern described in Chapter 6, but now with a concrete implementation mechanism. The change feed processor handles the "how" — you just define the transformation in your delegate.

### Streaming Pipelines into Event Hubs or Kafka

Sometimes you need to bridge Cosmos DB changes into a broader streaming ecosystem — Azure Event Hubs, Apache Kafka, or Azure Stream Analytics. The pattern is straightforward: a change feed processor reads changes and publishes them to the streaming platform.

This is useful when downstream consumers aren't Cosmos DB-aware, when you need durable message semantics that the change feed alone doesn't provide, or when you're feeding data into real-time analytics pipelines. Cosmos DB's change feed has advantages over a pure message queue — there's no maximum retention period in latest version mode, and you get Cosmos DB's availability SLA. But Event Hubs or Kafka provide consumer groups, replay semantics, and ecosystem connectors that the change feed doesn't.
<!-- Source: change-feed-design-patterns.md -->

We'll cover the integration details — Event Hubs bindings, Kafka Connect connectors, and the architectural tradeoffs — in Chapter 22.

### Cache Invalidation

"There are only two hard things in computer science: cache invalidation and naming things." The change feed makes the first one significantly easier.

Instead of setting arbitrary TTLs on your cache entries and hoping for the best, use the change feed to invalidate or refresh cache entries the moment the underlying data changes. A change feed processor watches your container and, for each change, either deletes the corresponding cache key or updates it with the new value. No stale reads during the TTL window, no cache stampedes after expiration.

```csharp
static async Task HandleChangesAsync(
    ChangeFeedProcessorContext context,
    IReadOnlyCollection<Product> changes,
    CancellationToken cancellationToken)
{
    foreach (Product product in changes)
    {
        string cacheKey = $"product:{product.Id}";
        await redisCache.StringSetAsync(cacheKey, JsonSerializer.Serialize(product),
            expiry: TimeSpan.FromHours(24));
    }
}
```

This gives you the best of both worlds: fast reads from the cache, and near-real-time consistency with the source of truth.

## Checkpointing and Resuming from a Position

Every change feed consumer needs to answer one question: if I restart, where do I pick up? This is **checkpointing** — persisting a bookmark of the last successfully processed position so you can resume without reprocessing everything or missing changes.

The change feed processor handles checkpointing automatically through the lease container. After your delegate successfully processes a batch of changes, the processor updates the corresponding lease document with the current position. If the host crashes and restarts, it reads the lease and resumes from the last checkpoint. This is what gives the processor its at-least-once guarantee.
<!-- Source: change-feed-processor.md -->

> **Gotcha:** The processor checkpoints *after* your delegate returns. If your delegate kicks off asynchronous work that hasn't completed when the method returns, the processor may checkpoint before that work finishes. If the host crashes, the in-flight work is lost. Either process synchronously within your delegate, or use explicit completion tracking.
<!-- Source: change-feed-processor.md -->

With the **pull model**, checkpointing is your responsibility. The `FeedIterator` exposes a `ContinuationToken` on each response. Persist that string (to a database, a file, a blob — wherever makes sense), and when you need to resume, pass it to `ChangeFeedStartFrom.ContinuationToken()`:

```csharp
// After processing, save the token
string token = response.ContinuationToken;
await SaveCheckpointAsync(token);

// Later, resume
string savedToken = await LoadCheckpointAsync();
FeedIterator<Order> iterator = container.GetChangeFeedIterator<Order>(
    ChangeFeedStartFrom.ContinuationToken(savedToken),
    ChangeFeedMode.LatestVersion);
```

In Python, the continuation token is available from the response headers:

```python
continuation_token = container.client_connection.last_response_headers['etag']
# Persist this value, then later:
response = container.query_items_change_feed(continuation=continuation_token)
```
<!-- Source: change-feed-pull-model.md -->

For the **Spark connector**, checkpointing is built in. Specify a `checkpointLocation` path, and the connector persists its position across micro-batches automatically. This is a significant advantage over the raw pull model for production Spark workloads.
<!-- Source: change-feed-spark.md -->

The **starting point options** vary by mode. In latest version mode, you can start from the beginning of the container, a specific point in time, "now," or a saved checkpoint. In all versions and deletes mode, you can only start from "now" or a saved checkpoint within the continuous backup retention window. Once the lease container is initialized, the starting point configuration is ignored on subsequent runs — the processor always resumes from its checkpoint.
<!-- Source: change-feed-processor.md, change-feed-modes.md -->

## Change Feed and Global Distribution

In a multi-region Cosmos DB account, the change feed is available in every region. Write to your container in West US, and a change feed consumer running in East US sees the change — eventually. The feed works across failover events; if a write region fails over, the change feed in the new region is contiguous.
<!-- Source: change-feed.md -->

For accounts with **single write region**, this is straightforward. All writes land in one region, propagate to read replicas, and the change feed is consistent everywhere with a small replication delay.

For accounts with **multiple write regions**, things get more nuanced. Writes can arrive in any region, and conflicts are resolved asynchronously. In latest version mode, if the same document is modified in two regions before the conflict is resolved, the "losing" version may be dropped from the change feed — you see only the winner. In all versions and deletes mode, all changes are captured regardless.
<!-- Source: change-feed.md -->

There's no guarantee of *when* changes will be available in other regions for multi-write accounts. If your change feed consumer runs in East US and a write happened in West Europe, it arrives after replication and conflict resolution complete.

The practical implication: for change feed consumers, **deploy them in the same region as your write region** (or your primary region in a multi-write setup) to minimize latency between the write and the consumer seeing it. Use `ApplicationPreferredRegions` on your `CosmosClient` to control this, and always use the global endpoint — never a regional one — so that failovers are handled transparently. Chapter 12 covers global distribution mechanics in detail.

## Monitoring Change Feed Lag with the Change Feed Estimator

How do you know if your change feed processor is keeping up? If changes arrive faster than your processor can handle them, a backlog builds up — and that backlog means downstream systems are seeing stale data. The **change feed estimator** tells you exactly how far behind you are.
<!-- Source: how-to-use-change-feed-estimator.md -->

The estimator is part of the .NET and Java SDKs. It measures the difference between the latest change in the container and the last change your processor consumed (as recorded in the lease container), then reports the gap as a count of pending changes.

The estimator supports two usage patterns:

**Push model (periodic notifications):** The estimator runs as a background process and calls a delegate at a configurable interval (default: 5 seconds) with the current lag:

```csharp
ChangeFeedProcessor estimator = monitoredContainer
    .GetChangeFeedEstimatorBuilder(
        "orderProjection",
        HandleEstimationAsync,
        TimeSpan.FromMinutes(1))
    .WithLeaseContainer(leaseContainer)
    .Build();

await estimator.StartAsync();

static async Task HandleEstimationAsync(long estimation, CancellationToken cancellationToken)
{
    if (estimation > 0)
    {
        Console.WriteLine($"Change feed lag: {estimation} items pending");
        // Push to Azure Monitor, Application Insights, etc.
    }
}
```
<!-- Source: how-to-use-change-feed-estimator.md -->

**On-demand (detailed per-lease breakdown):** For deeper diagnostics, you can query the estimator for per-lease lag and see which compute instance owns each lease:

```csharp
ChangeFeedEstimator estimator = monitoredContainer
    .GetChangeFeedEstimator("orderProjection", leaseContainer);

using FeedIterator<ChangeFeedProcessorState> stateIterator =
    estimator.GetCurrentStateIterator();

while (stateIterator.HasMoreResults)
{
    FeedResponse<ChangeFeedProcessorState> states =
        await stateIterator.ReadNextAsync();

    foreach (ChangeFeedProcessorState state in states)
    {
        string owner = state.InstanceName ?? "unowned";
        Console.WriteLine(
            $"Lease [{state.LeaseToken}] owned by {owner}: " +
            $"{state.EstimatedLag} items behind");
    }
}
```
<!-- Source: how-to-use-change-feed-estimator.md -->

The estimator works with both latest version and all versions and deletes modes. The estimate isn't guaranteed to be an exact count — it's an approximation — but it's reliable enough to drive scaling decisions and alerting.
<!-- Source: how-to-use-change-feed-estimator.md -->

A few operational tips:

- **Deploy the estimator separately** from your processor. It doesn't need to run on the same host — it just needs access to the same monitored and lease containers with the same processor name.
- **Start with a 1-minute polling interval.** Lower frequencies consume more RUs on the monitored and lease containers. You can always tighten it if you need faster alerting.
- **Feed the numbers into Azure Monitor or Application Insights.** A change feed lag metric over time is one of the most useful dashboards you can build for a Cosmos DB-backed system.
- **Use lag to trigger scaling.** If lag is growing, add more compute instances to your processor deployment. The processor will automatically rebalance leases across the new instances.

Every write becomes an event. The change feed turns that fact into an architecture. In Chapter 16, we'll turn to another critical aspect of data integrity: transactions and optimistic concurrency control with ETags.
