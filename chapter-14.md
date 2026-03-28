# Chapter 14: The Change Feed

Every database has a transaction log, but most keep it locked away as an internal implementation detail. Azure Cosmos DB does something different: it exposes that stream of changes as a first-class feature called the **change feed**. If you've ever wished you could react to every insert and update the moment it happens — without polling your container over and over — the change feed is your answer.

In this chapter, you'll learn what the change feed captures, how to consume it with the tools Microsoft provides, and the architectural patterns it unlocks. By the end, you'll be wiring up event-driven pipelines, maintaining materialized views, and monitoring your consumers for lag.

## What the Change Feed Captures

The change feed is a persistent, ordered record of changes to a container. Every time an item is created or updated, that change appears in the feed in the order it was modified. The feed is scoped to a single container and is available per physical partition, which means multiple consumers can process different partition ranges in parallel.

A few essential characteristics to internalize:

- **Enabled by default.** You don't flip a switch; the change feed exists for every container in every Cosmos DB account.
- **Ordered within a partition key.** Changes for items sharing the same partition key are guaranteed to arrive in the order they were written. Across partition keys, there's no ordering guarantee.
- **At-least-once delivery.** Each change is recorded once in the underlying feed log. However, consumption is "at least once" — if your consumer crashes mid-batch, changes may be redelivered. Design your handlers to be idempotent. Your consumer is responsible for tracking its position (checkpointing), though libraries like the Change Feed Processor handle this for you automatically.
- **Reads consume RU/s.** Reading the change feed is a Cosmos DB operation like any other — it costs request units drawn from the container's provisioned or serverless throughput.

The change feed is *not* a separate copy of your data. It's a different lens on the same underlying log. That means reads from the change feed are always consistent with direct queries against the container.

## Change Feed Modes

Cosmos DB offers two distinct modes for consuming the change feed. Each mode determines which operations you see and what metadata accompanies each change.

### Latest Version Mode (Default)

This is the mode you'll use most often. It captures **inserts and updates** — you get the most recent version of each changed item. If an item is updated three times between two consecutive reads, you see only the final state, not the intermediate versions.

Key characteristics:

- **Deletes are not captured.** When an item is deleted, it simply disappears from the feed. The standard workaround is a *soft-delete* pattern: set a `deleted` flag on the item and apply a TTL so Cosmos DB garbage-collects it later. The flag change shows up as an update in the feed.
- **Unlimited retention.** As long as an item exists in the container, the change that created or last modified it is available in the feed. You can start reading from the very beginning of the container's lifetime.
- **Flexible start position.** You can begin reading from the start of the container, from "now," from a specific point in time (approximately five-second precision), or from a saved continuation token.

Latest version mode works with all consumption methods: the Change Feed Processor, Azure Functions triggers, the pull model, and Spark.

### All Versions and Deletes Mode

This mode gives you the full operation log — **creates, updates, and deletes** — including intermediate versions that would be collapsed in latest version mode. Deletes from TTL expirations are captured too, with metadata that distinguishes them from explicit deletes.

Each change record includes an `operationType` field (`create`, `replace`, or `delete`) and a `crts` (conflict-resolved timestamp), so you always know *what* happened and *when*.

There are important prerequisites and constraints:

- **Continuous backups required.** You must have continuous backup configured on your account before enabling this mode.
- **Retention is bounded.** You can only read changes within the continuous backup retention window (typically 7 or 30 days). You cannot read from the beginning of the container.
- **Start position is limited.** You can start from "now" or from a saved continuation token — not from an arbitrary point in time.
- **NoSQL API only.** This mode is exclusive to the API for NoSQL.
- **No Azure Functions trigger support.** During the preview, you can consume all versions and deletes only through the pull model or the Change Feed Processor (in supported SDK versions).

A delete record in this mode looks like this:

```json
{
  "metadata": {
    "operationType": "delete",
    "lsn": 42,
    "crts": 1699900000,
    "timeToLiveExpired": false,
    "id": "order-9921",
    "partitionKey": { "customerId": "C-100" }
  }
}
```

Choose **latest version** mode when you need simplicity and unlimited history. Choose **all versions and deletes** when you need a complete audit trail, must react to deletes, or need every intermediate state.

## Consuming the Change Feed

Cosmos DB gives you four ways to consume the change feed, each sitting at a different point on the convenience-versus-control spectrum.

### The Change Feed Processor (Push Model)

The Change Feed Processor is a library built into the .NET V3 and Java V4 SDKs. It handles the hard parts — lease management, partition balancing, checkpointing, and fault tolerance — so you can focus on your business logic.

It relies on four components:

1. **Monitored container** — the container whose changes you want to process.
2. **Lease container** — a separate container (partitioned on `/id`) that stores the processing state. Think of each lease document as a bookmark for one physical partition's position in the feed.
3. **Compute instance** — the host running your code (a VM, a Kubernetes pod, an App Service instance). Each instance gets a unique name.
4. **Delegate** — your callback function. The processor invokes it with each batch of changes.

When you scale out to multiple compute instances, the processor automatically redistributes leases among them. If one instance goes down, its leases are picked up by the survivors. This gives you "at least once" delivery semantics with zero coordination code on your part.

Here's a complete setup in C#:

```csharp
private static async Task<ChangeFeedProcessor> StartChangeFeedProcessorAsync(
    CosmosClient cosmosClient,
    string databaseName)
{
    Container leaseContainer = cosmosClient.GetContainer(databaseName, "leases");
    Container monitoredContainer = cosmosClient.GetContainer(databaseName, "orders");

    ChangeFeedProcessor processor = monitoredContainer
        .GetChangeFeedProcessorBuilder<Order>(
            processorName: "orderProcessor",
            onChangesDelegate: HandleChangesAsync)
        .WithInstanceName(Environment.MachineName)
        .WithLeaseContainer(leaseContainer)
        .Build();

    await processor.StartAsync();
    Console.WriteLine("Change Feed Processor started.");
    return processor;
}

static async Task HandleChangesAsync(
    ChangeFeedProcessorContext context,
    IReadOnlyCollection<Order> changes,
    CancellationToken cancellationToken)
{
    Console.WriteLine($"Lease {context.LeaseToken}: {changes.Count} changes, " +
                      $"{context.Headers.RequestCharge} RU consumed.");

    foreach (Order order in changes)
    {
        Console.WriteLine($"  Order {order.Id} — status: {order.Status}");
        // Forward to a downstream service, update a view, etc.
    }
}
```

A few operational tips:

- **Keep the lease container in the same account** as the monitored container to minimize latency.
- **Use a global endpoint** (e.g., `contoso.documents.azure.com`) when creating the `CosmosClient`, not a regional endpoint. This ensures failover works correctly.
- **Call `StopAsync`** during graceful shutdown so leases are released promptly rather than waiting for the expiration timeout.

### Azure Functions Trigger (The Simplest Path)

If you don't want to manage hosting infrastructure at all, the Azure Functions Cosmos DB trigger is the fastest path to a working change feed consumer. Under the hood, it *is* the Change Feed Processor — Azure Functions just wraps it in a serverless execution model.

You need two containers: the monitored container and a lease container (which the trigger can create for you automatically). Here's an isolated worker model example using extension 4.x:

```csharp
public class OrderChangeFeed
{
    private readonly ILogger<OrderChangeFeed> _logger;

    public OrderChangeFeed(ILogger<OrderChangeFeed> logger)
    {
        _logger = logger;
    }

    [Function("OrderChangeFeed")]
    public void Run([CosmosDBTrigger(
        databaseName: "ecommerce",
        containerName: "orders",
        Connection = "CosmosDBConnection",
        LeaseContainerName = "leases",
        CreateLeaseContainerIfNotExists = true)] IReadOnlyList<Order> changes,
        FunctionContext context)
    {
        if (changes is not null && changes.Any())
        {
            _logger.LogInformation("Processing {Count} order changes.", changes.Count);

            foreach (Order order in changes)
            {
                _logger.LogInformation("Order {Id}: {Status}", order.Id, order.Status);
            }
        }
    }
}
```

The `Connection` property points to an application setting containing your Cosmos DB connection string (or, preferably, a managed identity–based reference). The trigger handles checkpointing, partition balancing, and scaling automatically.

**Current limitation:** the Azure Functions trigger only supports latest version mode. If you need all versions and deletes, use the Change Feed Processor or pull model directly.

### Direct SDK Pull Model

The pull model puts you in complete control. You create a `FeedIterator`, poll it at whatever cadence you choose, and manage your own continuation tokens. This is ideal when you need fine-grained control over parallelism, want to integrate with a custom orchestrator, or are running in an environment where the push model's background threads aren't a good fit.

Here's how to read changes for an entire container:

```csharp
FeedIterator<Order> iterator = container.GetChangeFeedIterator<Order>(
    ChangeFeedStartFrom.Now(),
    ChangeFeedMode.LatestVersion);

while (iterator.HasMoreResults)
{
    FeedResponse<Order> response = await iterator.ReadNextAsync();

    if (response.StatusCode == HttpStatusCode.NotModified)
    {
        Console.WriteLine("No new changes. Waiting...");
        // Save the continuation token before sleeping
        string token = response.ContinuationToken;
        await Task.Delay(TimeSpan.FromSeconds(5));
    }
    else
    {
        foreach (Order order in response)
        {
            Console.WriteLine($"Change detected: Order {order.Id}");
        }
    }
}
```

Since the change feed is conceptually infinite, `HasMoreResults` is always `true`. A `NotModified` (304) response means there are no new changes — back off and retry.

#### Parallelizing with FeedRange

To process a large container's change feed in parallel, use `FeedRange` to split the work across multiple iterators — one per physical partition:

```csharp
IReadOnlyList<FeedRange> ranges = await container.GetFeedRangesAsync();

// Create one iterator per physical partition
List<FeedIterator<Order>> iterators = ranges
    .Select(range => container.GetChangeFeedIterator<Order>(
        ChangeFeedStartFrom.Beginning(range),
        ChangeFeedMode.LatestVersion))
    .ToList();

// Process each iterator on a separate thread or machine
await Task.WhenAll(iterators.Select(async iterator =>
{
    while (iterator.HasMoreResults)
    {
        FeedResponse<Order> response = await iterator.ReadNextAsync();
        if (response.StatusCode == HttpStatusCode.NotModified)
        {
            await Task.Delay(TimeSpan.FromSeconds(5));
            continue;
        }

        foreach (Order order in response)
        {
            Console.WriteLine($"[{Task.CurrentId}] Order {order.Id}");
        }
    }
}));
```

You can also target a single partition key with `FeedRange.FromPartitionKey(new PartitionKey("value"))` — useful when you want to monitor changes for one specific entity (a single customer's orders, for example).

The pull model also supports distributing work across machines by serializing a `FeedRange` to a string with `FeedRange.ToJsonString()` and deserializing it on the consumer with `FeedRange.FromJsonString()`.

### Apache Spark Connector

For big-data and analytics workloads, the Azure Cosmos DB Spark connector exposes the change feed as a structured streaming source. You configure it with a `spark.cosmos.changeFeed` option block, and Spark treats incoming changes like any other streaming DataFrame — you can filter, transform, join, and write them to a sink (Azure Data Lake, Synapse Analytics, Delta Lake, or another Cosmos DB container).

This path is ideal when you're building ETL or lambda-architecture pipelines and want to process high-volume change data with Spark SQL transformations in near–real time. The Spark connector supports both latest version and all versions and deletes modes.

The Spark approach differs from the other three in a fundamental way: you're operating in *batch* or *micro-batch* mode rather than event-at-a-time. That makes it a better fit for aggregate analytics than for low-latency event handling. If you need sub-second reaction times, stick with the Change Feed Processor or Azure Functions.

## Common Change Feed Patterns

The change feed is a building block. Here are the architectural patterns you'll see it powering in production.

### Event-Driven Microservices

The most common pattern: service A writes to Cosmos DB, and services B, C, and D each run their own change feed consumer (with independent lease containers) to react to those writes. Because each consumer tracks its own position independently, adding a new downstream service doesn't affect existing ones. The change feed replaces point-to-point API calls with a decoupled, event-driven architecture.

For example, an e-commerce platform might have an `orders` container. The payment service, inventory service, and notification service each run a Change Feed Processor against that container. When a new order is inserted, all three services react independently — charge the card, decrement stock, and send a confirmation email — without the order service knowing or caring about any of them.

The Change Feed Processor's "at least once" delivery guarantee means your downstream handlers should be **idempotent** — safe to process the same change more than once. Use natural idempotency keys (like the item's `id` combined with its `_etag`) to guard against duplicate processing.

### Real-Time Materialized Views

Need to maintain a denormalized view of your data — say, an "order summary" container optimized for reads by customer ID, derived from a normalized "order line items" container? Wire up a change feed consumer that reads inserts and updates from the source container and writes the aggregated view to the target container.

This is one of the most powerful patterns in Cosmos DB's data-modeling toolkit. Instead of trying to serve every query shape from a single container, you use the change feed to keep purpose-built views in sync in near–real time.

### Streaming into Event Hubs or Kafka

The change feed makes Cosmos DB a viable alternative to a dedicated message queue for many ingestion scenarios. It offers unlimited retention (in latest version mode), guaranteed low-latency writes, and built-in global distribution — features that traditional message brokers charge extra for or don't offer at all.

For systems that already have a Kafka or Event Hubs backbone, a common pattern is to use an Azure Function or Change Feed Processor to bridge the two: read from the Cosmos DB change feed and publish each change as a message to the broker. This gives you the best of both worlds — Cosmos DB's operational database capabilities with your existing stream-processing infrastructure (Azure Stream Analytics, Apache Flink, or custom Kafka consumers).

This bridge pattern is especially powerful for building real-time dashboards: write operational data to Cosmos DB, funnel it through the change feed into Event Hubs, process it with Stream Analytics, and visualize it in Power BI — all with end-to-end latency measured in seconds.

### Cache Invalidation

If you cache query results in Redis or another in-memory store, the change feed gives you a reliable way to invalidate or refresh those entries. A lightweight change feed consumer watches for updates and either evicts the stale cache key or eagerly repopulates it with the new value. This replaces brittle TTL-based expiration with a precise, event-driven approach.

## Checkpointing and Resuming from a Position

Every change feed consumer needs to remember where it left off. How this works depends on which consumption method you're using.

**Change Feed Processor and Azure Functions:** Checkpointing is automatic. After your delegate processes a batch of changes, the processor updates the corresponding lease document in the lease container. If the process crashes and restarts, it picks up from the last committed lease position. Since checkpointing happens after your delegate returns, a crash mid-batch means those changes will be redelivered — this is the "at least once" guarantee in action.

**Pull model:** You manage continuation tokens yourself. After processing a batch, grab `response.ContinuationToken`, persist it (to a database, a file, Azure Blob Storage — wherever makes sense), and use it to resume later:

```csharp
// Persist after processing
string token = response.ContinuationToken;
await SaveCheckpointAsync(partitionRange, token);

// Resume later
string savedToken = await LoadCheckpointAsync(partitionRange);
FeedIterator<Order> iterator = container.GetChangeFeedIterator<Order>(
    ChangeFeedStartFrom.ContinuationToken(savedToken),
    ChangeFeedMode.LatestVersion);
```

In latest version mode, a continuation token never expires as long as the container exists. In all versions and deletes mode, the token is valid only within the continuous backup retention window.

## Change Feed and Global Distribution

In a multi-region Cosmos DB account, the change feed is **per-region**. Each region has its own change feed reflecting the writes that have been replicated to that region. Your consumer reads from whichever region its `CosmosClient` is connected to.

This has practical implications:

- **Single-write accounts:** Changes are written in one region and replicated to all read regions. The change feed in each read region eventually contains every change once replication catches up.
- **Multi-write accounts:** Each region's change feed reflects writes from all regions after conflict resolution. In latest version mode, if the same item is updated in two regions simultaneously, only the conflict-resolution winner appears. In all versions and deletes mode, all changes are captured.
- **Failover:** The change feed works across manual failover operations seamlessly. If your write region fails over, the new write region's change feed picks up where the old one left off — the feed is contiguous.

If your change feed consumer runs in `East US` but your account also spans `West Europe`, you'll see changes as fast as they replicate to `East US`. For latency-sensitive consumers, run them in the same region as your write region.

## Monitoring Change Feed Lag with the Estimator

The change feed estimator tells you how far behind your processor is — the number of changes that have been written to the container but not yet processed. This is the single most important operational metric for any change feed consumer.

### Push-Based Estimator

You can configure the estimator to periodically push the lag value to a callback:

```csharp
ChangeFeedProcessor estimator = monitoredContainer
    .GetChangeFeedEstimatorBuilder(
        "orderProcessor",
        HandleEstimationAsync,
        TimeSpan.FromSeconds(30))
    .WithLeaseContainer(leaseContainer)
    .Build();

await estimator.StartAsync();

static async Task HandleEstimationAsync(
    long estimation, CancellationToken cancellationToken)
{
    if (estimation > 0)
    {
        Console.WriteLine($"Estimated lag: {estimation} changes pending.");
        // Send to Application Insights, Azure Monitor, etc.
    }
}
```

The estimator name must match the `processorName` used when building your Change Feed Processor, and it must share the same lease container.

### On-Demand Detailed Estimation

For more granular insight — lag per lease and which instance owns each lease — use the on-demand estimator:

```csharp
ChangeFeedEstimator estimator = monitoredContainer
    .GetChangeFeedEstimator("orderProcessor", leaseContainer);

using FeedIterator<ChangeFeedProcessorState> iterator =
    estimator.GetCurrentStateIterator();

while (iterator.HasMoreResults)
{
    FeedResponse<ChangeFeedProcessorState> states =
        await iterator.ReadNextAsync();

    foreach (ChangeFeedProcessorState state in states)
    {
        string owner = state.InstanceName ?? "unowned";
        Console.WriteLine(
            $"Lease [{state.LeaseToken}] owned by {owner}: " +
            $"{state.EstimatedLag} changes behind.");
    }
}
```

This is invaluable for diagnosing hot partitions (one lease with disproportionately high lag) or identifying instances that have gone offline (leases showing as unowned).

**Deployment tip:** Run the estimator on a separate instance from your processor. A single estimator instance can monitor all leases and all processor instances. Keep the polling interval reasonable — every 30 to 60 seconds is a good starting point — since each estimation consumes request units from both the monitored and lease containers.

## Key Takeaways

| Concept | What to Remember |
|---|---|
| **Modes** | Latest version (default) captures inserts and updates with unlimited retention. All versions and deletes captures everything but requires continuous backup and has bounded retention. |
| **Push vs. pull** | Use the Change Feed Processor or Azure Functions for simplicity and automatic scaling. Use the pull model when you need full control over timing and parallelism. |
| **Ordering** | Guaranteed within a partition key, not across partition keys. Design your partition key accordingly. |
| **Idempotency** | The processor guarantees "at least once" delivery. Your handlers must be safe to execute more than once for the same change. |
| **Monitoring** | Always deploy the change feed estimator in production. Lag is your early-warning system. |

## What's Next

The change feed turns Cosmos DB from a database into an event platform. In **Chapter 15**, we'll tackle **transactions and optimistic concurrency** — how single-item writes are inherently atomic, how to execute multi-item transactions with transactional batch operations in the SDK, and how to use ETags for optimistic concurrency control to prevent conflicting updates in concurrent environments.
