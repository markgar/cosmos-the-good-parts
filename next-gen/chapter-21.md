# Chapter 21: Advanced SDK Patterns

The basics of reading and writing items through the Cosmos DB SDKs — covered in Chapter 7 — will carry you through most application scenarios. But "most" isn't good enough when you're bulk-loading a million documents into a new container, trying to shave P99 tail latency during a regional blip, or troubleshooting a slow request at 2 AM with nothing but a diagnostics string. This chapter is about the patterns that separate a working application from a production-hardened one.

We'll cover five areas: bulk operations for high-throughput ingestion, performance tuning for the SDK's connection and region configuration, Entity Framework Core as an ORM layer, OpenTelemetry and observability instrumentation, and — perhaps most importantly — designing resilient applications that handle failures gracefully.

## Bulk Operations

When you need to push hundreds of thousands of items into Cosmos DB as fast as possible, issuing individual `CreateItemAsync` calls sequentially is like filling a swimming pool with a coffee mug. The SDK's **bulk execution mode** solves this: it groups concurrent operations into batches aligned to partition key ranges, then dispatches those batches as single service calls. The result is dramatically higher throughput with less client-side overhead.
<!-- Source: bulk-executor-overview.md, tutorial-dotnet-bulk-import.md -->

The now-deprecated **bulk executor library** (for .NET V2 SDK and pre-V4 Java) benchmarked at over 500,000 RU/s from a single Azure VM instance. The built-in `AllowBulkExecution` mode in modern SDKs uses the same batching strategy, but your actual throughput depends on provisioned RU/s, document size, and indexing policy — there's no single headline number.
<!-- Source: bulk-executor-overview.md -->

One important constraint: the legacy bulk executor library is **not supported on serverless accounts**. The docs recommend using the built-in V3 SDK bulk support (`AllowBulkExecution`) instead, which doesn't carry the same restriction. That said, serverless containers cap at 5,000 RU/s burst, so bulk loading into them will always be slower than into provisioned containers.
<!-- Source: bulk-executor-overview.md -->

### Bulk Mode in the .NET SDK

In the .NET V3 SDK, you enable bulk mode by setting `AllowBulkExecution = true` on `CosmosClientOptions`. Once enabled, the `CosmosClient` internally groups concurrent point operations into optimized service calls — you don't change *how* you call the SDK, just how you orchestrate concurrency.
<!-- Source: tutorial-dotnet-bulk-import.md -->

```csharp
CosmosClient client = new CosmosClient(
    endpoint,
    credential,
    new CosmosClientOptions { AllowBulkExecution = true });
```

The pattern is straightforward: create a list of tasks, each representing a point operation, then await them all concurrently with `Task.WhenAll`. The SDK handles the batching internally.

```csharp
Container container = database.GetContainer("orders");
List<Task> tasks = new(itemsToInsert.Count);

foreach (var order in itemsToInsert)
{
    tasks.Add(
        container.CreateItemAsync(order, new PartitionKey(order.CustomerId))
            .ContinueWith(t =>
            {
                if (!t.IsCompletedSuccessfully)
                {
                    CosmosException ex = t.Exception?.Flatten()
                        .InnerExceptions.OfType<CosmosException>().FirstOrDefault();
                    if (ex != null)
                        Console.WriteLine($"Failed: {ex.StatusCode} - {ex.Message}");
                }
            }));
}

await Task.WhenAll(tasks);
```
<!-- Source: tutorial-dotnet-bulk-import.md -->

A few things to note about this pattern:

- **Bulk is a client-level setting**, immutable for the lifetime of that `CosmosClient` instance. If you need both bulk and non-bulk workloads, create separate clients.
<!-- Source: tutorial-dotnet-bulk-import.md -->
- **Minimize your indexing policy** for write-heavy bulk loads. Excluding all paths except the ones you actually query on can significantly reduce RU cost per write. You can always add indexes back after the load completes.
- **Disable content response on writes** (`EnableContentResponseOnWrite = false` in `ItemRequestOptions`) to skip deserializing the returned document. You already have the object in memory — no need for the service to send it back.
<!-- Source: performance-tips-dotnet-sdk-v3.md -->

### Bulk Mode in the Java SDK

Java V4 SDK has bulk execution built in. You construct a `Flux<CosmosItemOperation>` stream of operations and pass it to `executeBulkOperations` on the container:
<!-- Source: bulk-executor-java.md -->

```java
Flux<CosmosItemOperation> operations = families.map(
    family -> CosmosBulkOperations.getCreateItemOperation(
        family, new PartitionKey(family.getLastName())));

container.executeBulkOperations(operations).blockLast();
```

The Java SDK supports bulk create, upsert, replace, and delete — all through the same `CosmosBulkOperations` factory. The SDK handles rate-limiting retries and partition-level batching automatically.
<!-- Source: bulk-executor-java.md -->

### Bulk Operations in the JavaScript SDK

The JavaScript SDK (version 4.3+) supports bulk through `container.items.executeBulkOperations()`. You pass an array of operation descriptors, each specifying the operation type, partition key, and resource body:
<!-- Source: bulk-executor-nodejs.md -->

```javascript
const { BulkOperationType, CosmosClient } = require("@azure/cosmos");

const operations = [
    {
        operationType: BulkOperationType.Upsert,
        partitionKey: "gear-surf-surfboards",
        resourceBody: { id: "board-001", category: "gear-surf-surfboards", name: "Yamba Surfboard" }
    },
    {
        operationType: BulkOperationType.Upsert,
        partitionKey: "gear-surf-surfboards",
        resourceBody: { id: "board-002", category: "gear-surf-surfboards", name: "Kiama Classic" }
    }
];

const response = await container.items.executeBulkOperations(operations);
```

The feature automatically adjusts per-partition concurrency — scaling up when calls succeed without throttling and scaling back when 429s appear.
<!-- Source: bulk-executor-nodejs.md -->

### The Legacy Bulk Executor Library

You'll still find references to a standalone **bulk executor library** for .NET (V2 SDK) and Java (pre-V4). This library is deprecated. For new applications, use the built-in bulk support described above. If you're on the legacy library, Microsoft provides migration guides for both [.NET](https://learn.microsoft.com/azure/cosmos-db/how-to-migrate-from-bulk-executor-library) and [Java](https://learn.microsoft.com/azure/cosmos-db/how-to-migrate-from-bulk-executor-library-java).
<!-- Source: bulk-executor-dotnet.md, bulk-executor-java.md -->

## Performance Tips for High-Throughput Scenarios

Bulk mode gets you the raw throughput, but the surrounding configuration determines whether you actually reach it. Here are the knobs that matter.

### Use Direct Mode (When You Can)

The SDK offers two connectivity modes: **Direct** (TCP) and **Gateway** (HTTPS). Direct mode talks TCP straight to backend replicas, skipping the gateway hop entirely. It's the default in both the .NET V3 and Java V4 SDKs, and it's the right choice for almost all production workloads.
<!-- Source: sdk-connection-modes.md -->

| Mode | Protocol | SDKs | Best for |
|------|----------|------|----------|
| **Direct** | TCP (TLS) | .NET, Java | Low-latency production workloads |
| **Gateway** | HTTPS | All SDKs | Restrictive firewalls, Azure Functions Consumption plan, integrated cache |

<!-- Source: sdk-connection-modes.md -->

Gateway mode uses a single HTTPS endpoint (port 443), which makes it the only option when firewall rules block the dynamic TCP port range (10000–20000) that Direct mode requires. It's also required if you're using the **dedicated gateway** for integrated cache scenarios — see Chapter 11 for the full story on integrated cache configuration and cost tradeoffs.
<!-- Source: dedicated-gateway.md, sdk-connection-modes.md -->

Python and JavaScript SDKs only support Gateway mode. If you're in those ecosystems, there's no choice to make.
<!-- Source: sdk-connection-modes.md -->

### Connection Tuning

In Direct mode, the SDK opens TCP connections to each replica in every physical partition your workload touches. The number of connections is roughly *physical partitions × 4 replicas*, plus additional connections if concurrent request volume spikes.
<!-- Source: sdk-connection-modes.md -->

Here are the key configuration knobs for the .NET SDK:

| Setting | Default | Guidance |
|---------|---------|----------|
| `MaxRequestsPerTcpConnection` | 30 | Higher values (up to 50–100) for high-parallelism workloads; lower values (8–16) for latency-sensitive workloads |
| `MaxTcpConnectionsPerEndpoint` | 65,535 | Rarely needs changing |
| `IdleTcpConnectionTimeout` | Indefinite | Set to 20 min–24 hours for sparse workloads to avoid ephemeral port exhaustion |
| `OpenTcpConnectionTimeout` | 5 seconds | Reduce to 1 second for faster connection failure detection |
| `PortReuseMode` | `ReuseUnicastPort` | Set to `PrivatePortPool` for sparse connection patterns |

<!-- Source: tune-connection-configurations-net-sdk-v3.md -->

The Java SDK exposes equivalent settings through `DirectConnectionConfig`:

```java
DirectConnectionConfig directConfig = DirectConnectionConfig.getDefaultConfig();
directConfig.setMaxConnectionsPerEndpoint(130);
directConfig.setIdleConnectionTimeout(Duration.ZERO); // Keep connections alive indefinitely
```
<!-- Source: tune-connection-configurations-java-sdk-v4.md -->

For Gateway mode, the main lever is `GatewayModeMaxConnectionLimit` (default 50 in .NET), which controls the HTTP connection pool size. If you're running in Gateway mode with high concurrency, bump this up.
<!-- Source: tune-connection-configurations-net-sdk-v3.md -->

### Preferred Regions

Setting **preferred regions** tells the SDK which Azure regions to prioritize for reads and where to fail over if a region goes down. Every production application should configure this explicitly. If you don't, the SDK defaults to the account's primary region for everything — which means you're not benefiting from the geo-distributed replicas you're paying for.
<!-- Source: troubleshoot-sdk-availability.md, best-practice-dotnet.md -->

| Account Type | Reads Route To | Writes Route To |
|-------------|----------------|-----------------|
| Single write region, preferred regions set | First preferred region | Primary (write) region |
| Multi-region writes, preferred regions set | First preferred region | First preferred region |
| Any account, **no** preferred regions set | Primary region | Primary region |

<!-- Source: troubleshoot-sdk-availability.md -->

The syntax varies by SDK:

```csharp
// .NET
var options = new CosmosClientOptions
{
    ApplicationPreferredRegions = new List<string> { "East US", "West US", "North Europe" }
};
```

```java
// Java
CosmosAsyncClient client = new CosmosClientBuilder()
    .endpoint(endpoint)
    .credential(credential)
    .preferredRegions(Arrays.asList("East US", "West US", "North Europe"))
    .directMode()
    .buildAsyncClient();
```

```python
# Python
client = CosmosClient(url, credential, preferred_locations=["East US", "West US"])
```

```javascript
// JavaScript
const client = new CosmosClient({
    endpoint,
    credential,
    connectionPolicy: { preferredLocations: ["East US", "West US"] }
});
```
<!-- Source: troubleshoot-sdk-availability.md -->

### The Singleton Rule

This bears repeating even though Chapter 7 covered it: **use a single `CosmosClient` instance per account per application lifetime**. Every instance manages its own connection pool, address cache, and metadata cache. Creating multiple instances wastes memory, opens redundant connections, and can lead to socket exhaustion. In Azure Functions, use a static client. In ASP.NET Core, register the client as a singleton in your DI container.
<!-- Source: best-practice-dotnet.md, best-practice-java.md, best-practices-javascript.md -->

### Other High-Impact Tips

| Tip | Why it matters |
|-----|---------------|
| **Use async/await exclusively** (.NET) | Blocking calls (`Task.Result`, `Task.Wait`) starve the thread pool and tank throughput |
| **Avoid `.block()` in reactive chains** (Java) | Same principle — blocking defeats the async pipeline |
| **Enable server-side GC** (.NET) | Set `gcServer` to `true` in your runtime config to reduce GC pauses under load |
| **Enable Accelerated Networking** (Azure VMs) | Bypasses the host virtual switch, reducing latency and CPU jitter |
| **Cache database/container references** | `ReadDatabaseAsync` and `ReadContainerAsync` are metadata calls that consume system RUs — do them once at startup, not per request |
| **Run in the same Azure region** | Cross-region round-trips add 50+ ms of latency |
| **Use at least 4-core, 8 GB VMs** | Undersized machines throttle the client before the service |

<!-- Source: best-practice-dotnet.md, best-practice-java.md, best-practices-javascript.md, performance-tips-dotnet-sdk-v3.md -->

## Entity Framework Core with Cosmos DB

If your team lives in the .NET ecosystem and prefers working through an ORM, EF Core ships with a built-in **Cosmos DB provider**. It gives you familiar DbContext-based patterns — LINQ queries, change tracking, migrations — over Cosmos DB's NoSQL storage. It's a legitimate option for applications that value developer ergonomics and don't need every last feature the raw SDK provides.
<!-- Source: sdk-dotnet-v3.md -->

### Setting Up the Provider

Install the `Microsoft.EntityFrameworkCore.Cosmos` NuGet package and configure your `DbContext`:

```csharp
public class CatalogDbContext : DbContext
{
    public DbSet<Product> Products { get; set; }

    protected override void OnConfiguring(DbContextOptionsBuilder options)
    {
        options.UseCosmos(
            accountEndpoint: "https://your-account.documents.azure.com:443/",
            accountKey: "your-key",
            databaseName: "catalog");
    }
}
```

Each `DbSet<T>` maps to a Cosmos DB container by default. You can customize the container name, partition key, and throughput through the `OnModelCreating` override:

```csharp
protected override void OnModelCreating(ModelBuilder modelBuilder)
{
    modelBuilder.Entity<Product>()
        .ToContainer("products")
        .HasPartitionKey(p => p.CategoryId);
}
```

### Mapping Entities and Owned Types

EF Core maps each entity to a JSON document. **Owned types** — entities configured with `OwnsOne` or `OwnsMany` — become embedded objects or arrays within the parent document, which aligns naturally with Cosmos DB's document model.

```csharp
modelBuilder.Entity<Product>(builder =>
{
    builder.OwnsOne(p => p.Dimensions);       // Embedded object
    builder.OwnsMany(p => p.Reviews);         // Embedded array
});
```

This is where EF Core actually shines with Cosmos DB. The embedding pattern maps cleanly to the data modeling strategies we discussed in Chapter 4: owned types model the "embed for one-to-few, co-located access" pattern without you having to think about JSON structure manually.

### Querying and Change Tracking

LINQ queries against a `DbSet` translate to SQL queries under the hood. EF Core's change tracker handles read-your-writes semantics — modify an entity, call `SaveChangesAsync()`, and the provider issues the appropriate point operations.

```csharp
var surfboards = await context.Products
    .Where(p => p.CategoryId == "surfboards" && p.Price < 500)
    .ToListAsync();
```

Be aware that EF Core generates a Cosmos DB SQL query from your LINQ expression. If the query doesn't include the partition key in the `Where` clause, it becomes a **cross-partition query** — and EF Core's Cosmos provider has limited support for these. Always filter by partition key when you can.

### Limitations vs. the Raw SDK

EF Core is an abstraction, and abstractions hide things — sometimes things you need. Here's what you give up:

| Capability | Raw SDK | EF Core Provider |
|-----------|---------|-----------------|
| Cross-partition queries | Full support | Limited |
| Bulk operations | `AllowBulkExecution` | Not supported |
| Partial document update (patch) | `PatchItemAsync` | Not supported |
| Stored procedures, triggers, UDFs | Full support | Not supported |
| Change feed | Full support | Not supported |
| Hierarchical partition keys | Full support | Limited |
| Transactional batch | Full support | Limited |

If your workload involves bulk data loading, change feed processing, or fine-grained patch operations, you'll need the raw SDK for those paths. Many teams use a hybrid approach: EF Core for straightforward CRUD in their API layer, and the SDK directly for background jobs, migrations, and advanced operations.

## OpenTelemetry Instrumentation

You can't optimize what you can't see. The .NET and Java SDKs ship with built-in **distributed tracing** support that integrates with OpenTelemetry, giving you per-operation visibility into latency, RU consumption, status codes, and the regions your requests touched.
<!-- Source: sdk-observability.md -->

### Enabling Tracing

Distributed tracing support is available in these SDK versions:

| SDK | Minimum Version | Default State |
|-----|----------------|---------------|
| .NET V3 (stable) | 3.36.0 | **Off** — set `DisableDistributedTracing = false` |
| .NET V3 (preview) | 3.33.0-preview | **On** by default |
| Java V4 | 4.43.0 | On by default |

<!-- Source: sdk-observability.md -->

In .NET, you enable tracing through `CosmosClientTelemetryOptions`:

```csharp
CosmosClientOptions options = new CosmosClientOptions
{
    CosmosClientTelemetryOptions = new CosmosClientTelemetryOptions
    {
        DisableDistributedTracing = false
    }
};
```
<!-- Source: sdk-observability.md -->

Then register the `Azure.Cosmos.Operation` source in your OpenTelemetry trace provider:

```csharp
using var traceProvider = Sdk.CreateTracerProviderBuilder()
    .AddSource("Azure.Cosmos.Operation")    // Cosmos DB operation-level telemetry
    .AddSource("MyApp.OrderService")        // Your application spans
    .AddAzureMonitorTraceExporter(o => o.ConnectionString = aiConnectionString)
    .AddHttpClientInstrumentation()
    .SetResourceBuilder(ResourceBuilder.CreateDefault().AddService("order-api"))
    .Build();
```
<!-- Source: sdk-observability.md -->

### Trace Attributes

Every Cosmos DB span carries a set of attributes that follow the OpenTelemetry database semantic conventions, plus Cosmos-specific extensions:

| Attribute | Type | Description |
|-----------|------|-------------|
| `db.system` | string | Always `cosmosdb` |
| `db.name` | string | Database name |
| `db.operation` | string | e.g., `CreateItemAsync` |
| `db.cosmosdb.container` | string | Container name |
| `db.cosmosdb.connection_mode` | string | `direct` or `gateway` |
| `db.cosmosdb.status_code` | int | HTTP status code |
| `db.cosmosdb.sub_status_code` | int | Cosmos DB sub-status |
| `db.cosmosdb.request_charge` | double | RUs consumed |
| `db.cosmosdb.regions_contacted` | string | Regions touched |
| `db.cosmosdb.client_id` | string | Unique client instance ID |

<!-- Source: sdk-observability.md -->

The `request_charge` attribute is especially valuable — it lets you build dashboards that show RU consumption *per operation type* rather than just aggregate container-level metrics. When you see a spike in RU consumption, you can trace it to the specific query or write pattern responsible.

### Diagnostic Logs for Slow and Failed Requests

Beyond traces, the SDKs can automatically emit **diagnostic logs** for requests that fail or exceed a latency threshold. In .NET, you configure the thresholds like this:

```csharp
CosmosClientTelemetryOptions = new CosmosClientTelemetryOptions
{
    DisableDistributedTracing = false,
    CosmosThresholdOptions = new CosmosThresholdOptions
    {
        PointOperationLatencyThreshold = TimeSpan.FromMilliseconds(100),
        NonPointOperationLatencyThreshold = TimeSpan.FromMilliseconds(500)
    }
}
```
<!-- Source: sdk-observability.md -->

The defaults are 1 second for point operations and 3 seconds for non-point operations. Failed requests always emit diagnostics regardless of latency.

| Log Level | What you get |
|-----------|-------------|
| `Error` | Logs for errors only |
| `Warning` | Errors + high-latency requests exceeding thresholds |
| `Information` | Same as Warning |

<!-- Source: sdk-observability.md -->

In Java, the equivalent configuration goes through `CosmosDiagnosticsThresholds`:

```java
CosmosClientTelemetryConfig telemetryConfig = new CosmosClientTelemetryConfig()
    .diagnosticsThresholds(
        new CosmosDiagnosticsThresholds()
            .setPointOperationLatencyThreshold(Duration.ofMillis(100))
            .setNonPointOperationLatencyThreshold(Duration.ofMillis(2000))
            .setRequestChargeThreshold(100));
```
<!-- Source: sdk-observability.md -->

### Correlating with Application Spans

The real power of OpenTelemetry is **correlation**. When you instrument both your application code and the Cosmos DB SDK with the same trace provider, each Cosmos DB operation appears as a child span under your application's request span. That end-to-end view is invaluable for pinpointing whether latency lives in your code, the network, or the database.

A single distributed trace might look like this:

> HTTP request received → validate input → read item from Cosmos DB (3.2 RU, 4ms, East US) → transform response → return

For dashboarding and alerting on the telemetry you're collecting here, see Chapter 18.

### A Note on OTel Metrics vs. Tracing

The outline calls for "enabling built-in tracing and metrics" under OpenTelemetry, so let's be precise about what each SDK provides. The .NET and Java SDKs ship with built-in OTel *tracing* (the `Azure.Cosmos.Operation` activity source covered above). However, the .NET SDK does not currently expose a separate `Meter` for OTel *metrics* — there's no `AddMeter("Azure.Cosmos.Operation")` equivalent. The per-operation RU charges and latencies are available as span attributes on traces, which you can extract into metrics at the exporter or dashboarding layer (Application Insights does this automatically). For true client-side metrics in a dedicated metrics pipeline, the Java SDK's Micrometer integration (covered next) is the mature option. If you're on .NET, aggregating trace attributes into custom metrics at your collector is the current workaround.
<!-- Source: sdk-observability.md -->

## SDK Observability Beyond OpenTelemetry

OpenTelemetry is the modern path, but it's not the only observability tool the SDKs offer.

### Micrometer Metrics (Java)

The Java SDK integrates with **Micrometer**, the de facto metrics library in the Java ecosystem. You can wire it to Prometheus, Datadog, or any Micrometer-compatible registry.
<!-- Source: client-metrics-java.md -->

```java
PrometheusMeterRegistry prometheusRegistry =
    new PrometheusMeterRegistry(PrometheusConfig.DEFAULT);

CosmosClientTelemetryConfig telemetryConfig = new CosmosClientTelemetryConfig()
    .diagnosticsThresholds(
        new CosmosDiagnosticsThresholds()
            .setRequestChargeThreshold(10)
            .setPointOperationLatencyThreshold(Duration.ofDays(10)))
    .metricsOptions(
        new CosmosMicrometerMetricsOptions()
            .meterRegistry(prometheusRegistry)
            .applyDiagnosticThresholdsForTransportLevelMeters(true));

CosmosAsyncClient client = new CosmosClientBuilder()
    .endpoint(endpoint)
    .key(key)
    .clientTelemetryConfig(telemetryConfig)
    .buildAsyncClient();
```
<!-- Source: client-metrics-java.md -->

The SDK emits two categories of metrics: **operation-level** (prefixed with `cosmos.client.op`) and **request-level** (with `rntbd` or `gw` in the name for Direct and Gateway mode respectively). Request-level metrics only include requests that exceed the diagnostic thresholds — this is intentional, to keep cardinality manageable.

Use operation-level metrics for alerting on user-visible latency and RU consumption — these reflect what your application actually experiences. Use request-level metrics when you need to diagnose transport-layer issues: connection failures, TCP channel health, and per-replica latencies that hide inside a single logical operation.
<!-- Source: client-metrics-java.md -->

You can further reduce noise with `sampleDiagnostics(0.25)` to sample only 25% of eligible diagnostics, adjustable at runtime without restarting the client. This is useful when diagnostic volume overwhelms your metrics pipeline but you still want statistical visibility into slow or expensive requests.
<!-- Source: client-metrics-java.md -->

### Diagnostic Strings and Request-Level Diagnostics

Every SDK response carries **diagnostic information** you can capture and log. This is your first line of defense when debugging slow or failed requests.

- **.NET V3**: The `Diagnostics` property on every `ItemResponse<T>`, `FeedResponse<T>`, and `CosmosException` contains structured information about retries, contacted regions, request timelines, and transport-level details.
<!-- Source: troubleshoot-dotnet-sdk-slow-request.md -->
- **Java V4**: Call `getDiagnostics()` on any response or exception. The `CosmosDiagnostics` object includes `getDuration()` for total elapsed time — compare this against your SLA to decide whether to log.
<!-- Source: best-practice-java.md -->

A practical pattern: log diagnostics for any operation that exceeds your latency budget.

```csharp
// .NET
ItemResponse<Order> response = await container.ReadItemAsync<Order>(id, pk);
if (response.Diagnostics.GetClientElapsedTime() > TimeSpan.FromSeconds(1))
{
    logger.LogWarning("Slow read: {Diagnostics}", response.Diagnostics.ToString());
}
```

```java
// Java
CosmosDiagnostics diag = response.getDiagnostics();
if (diag.getDuration().compareTo(Duration.ofSeconds(1)) > 0)
{
    logger.warn("Slow read: {}", diag.toString());
}
```

**Don't log diagnostics for every request in production** — the strings are verbose and the volume will overwhelm your logging pipeline. Use them conditionally: on exceptions, on latency threshold breaches, and during performance investigations.
<!-- Source: best-practice-java.md, best-practice-dotnet.md -->

## Designing Resilient SDK Applications

Your application will encounter errors when talking to Cosmos DB. Network blips, regional outages, partition movements, throttling — these aren't hypothetical. The question isn't *if* but *how often* and *how your code responds*. This section is the definitive guide to building SDK applications that handle failures gracefully.

### Understanding What the SDK Retries For You

The SDKs have built-in retry logic for several error classes. Before you layer on your own retry policies, understand what's already handled:
<!-- Source: conceptual-resilient-sdk-applications.md -->

| Status Code | Description | SDK Retries? | You Should Retry? |
|-------------|-------------|:------------:|:-----------------:|
| 400 | Bad request | No | No |
| 401 | Not authorized | No | No |
| 403 | Forbidden | No | Situational |
| 404 | Not found | No | No |
| 408 | Request timeout | **Yes** | Yes |
| 409 | Conflict | No | No |
| 410 | Gone (transient) | **Yes** | Yes |
| 412 | Precondition failure (ETag mismatch) | No | No — re-read and retry |
| 413 | Entity too large | No | No |
| 429 | Too many requests (throttled) | **Yes** | Yes |
| 449 | Retry with (concurrency) | **Yes** | Yes |
| 500 | Internal server error | No | No — contact support |
| 503 | Service unavailable | **Yes** | Yes |

<!-- Source: conceptual-resilient-sdk-applications.md -->

The critical nuance: **for write operations, the SDKs do not retry on timeouts and connectivity failures** because writes aren't idempotent. If a timeout occurs, the SDK can't know whether the write reached the server. Your application needs its own strategy for this.

The standard pattern is to re-read and check whether the write actually landed, then conditionally retry. Retrying a `Create` that already succeeded yields a 409 Conflict, which is easy to handle.
<!-- Source: conceptual-resilient-sdk-applications.md -->

For 429 (throttled) responses, the SDK retries automatically, respecting the `x-ms-retry-after-ms` header from the service. If retries are exhausted, the error surfaces to your application. At that point, your code should implement exponential backoff or honor the `RetryAfter` value from the exception.

For write timeouts, the pattern is more involved. Because you don't know if the write succeeded, you need to check before retrying:
<!-- Source: conceptual-resilient-sdk-applications.md -->

```csharp
async Task CreateWithRetryAsync(Container container, Order order, PartitionKey pk)
{
    try
    {
        await container.CreateItemAsync(order, pk);
    }
    catch (CosmosException ex) when (ex.StatusCode == System.Net.HttpStatusCode.RequestTimeout
                                  || ex.StatusCode == System.Net.HttpStatusCode.ServiceUnavailable)
    {
        // Write timed out — did it land?
        try
        {
            await container.ReadItemAsync<Order>(order.Id, pk);
            // Item exists — the original write succeeded. Nothing to retry.
        }
        catch (CosmosException readEx) when (readEx.StatusCode == System.Net.HttpStatusCode.NotFound)
        {
            // Item doesn't exist — safe to retry the create.
            await container.CreateItemAsync(order, pk);
        }
    }
    catch (CosmosException ex) when (ex.StatusCode == System.Net.HttpStatusCode.Conflict)
    {
        // 409 — the write already succeeded on a previous attempt.
    }
}
```
<!-- Source: conceptual-resilient-sdk-applications.md -->

### Preferred Regions and Cross-Region Failover

When you configure preferred regions (as shown earlier in this chapter) and the SDK exhausts local retries for a request, it can attempt a **cross-region retry** to the next region in your preference list. This happens automatically for read operations. Write operations can only fail over to another region if the account has multi-region writes enabled.
<!-- Source: troubleshoot-sdk-availability.md -->

Every 5 minutes, the SDK refreshes its view of the account's available regions. If a region is removed from the account, the SDK detects this through a backend response and immediately routes to the next preferred region. If a new region is added and it ranks higher in your preference list, the SDK switches to it on the next refresh.
<!-- Source: troubleshoot-sdk-availability.md -->

### Threshold-Based Availability Strategy

For applications where tail latency matters as much as availability, both the .NET and Java SDKs support a **threshold-based availability strategy** that hedges read requests across regions.
<!-- Source: performance-tips-dotnet-sdk-v3.md, performance-tips-java-sdk-v4.md -->

Here's how it works:

1. The SDK sends a read request to the primary preferred region and starts a timer.
2. If no response arrives within the `threshold` (e.g., 500ms), a parallel request goes to the second preferred region.
3. If neither responds within `threshold + thresholdStep` (e.g., 600ms), a third parallel request fires.
4. The first response to arrive wins; the others are discarded.

```csharp
// .NET
CosmosClient client = new CosmosClientBuilder("connection-string")
    .WithApplicationPreferredRegions(
        new List<string> { "East US", "East US 2", "West US" })
    .WithAvailabilityStrategy(
        AvailabilityStrategy.CrossRegionHedgingStrategy(
            threshold: TimeSpan.FromMilliseconds(500),
            thresholdStep: TimeSpan.FromMilliseconds(100)))
    .Build();
```
<!-- Source: performance-tips-dotnet-sdk-v3.md -->

```java
// Java
CosmosEndToEndOperationLatencyPolicyConfig config =
    new CosmosEndToEndOperationLatencyPolicyConfigBuilder(Duration.ofSeconds(3))
        .availabilityStrategy(new ThresholdBasedAvailabilityStrategy(
            Duration.ofMillis(500), Duration.ofMillis(100)))
        .build();

CosmosItemRequestOptions options = new CosmosItemRequestOptions();
options.setCosmosEndToEndOperationLatencyPolicyConfig(config);
```
<!-- Source: performance-tips-java-sdk-v4.md -->

The tradeoff is cost: hedged requests consume RUs in multiple regions. This strategy is optimal for **read-heavy workloads** where you're willing to pay extra RUs to eliminate tail latency. If the first region responds fast — the common case — no extra requests are sent.
<!-- Source: performance-tips-dotnet-sdk-v3.md -->

### Partition-Level Circuit Breaker

The **partition-level circuit breaker** (PPCB) takes a different approach to resilience. Instead of hedging preemptively, it tracks failures per physical partition and short-circuits requests away from unhealthy partitions to healthier regions.
<!-- Source: performance-tips-dotnet-sdk-v3.md, performance-tips-java-sdk-v4.md -->

The lifecycle:

1. **Failure tracking**: The SDK counts consecutive failures (503, 408, timeouts) for each partition in each region.
2. **Failover trigger**: Once the threshold is breached (default: 10 consecutive read failures, 5 for writes in .NET), requests for that partition are redirected to the next preferred region.
3. **Recovery**: A background task periodically probes the failed partition. Once healthy, traffic returns to the original region.
<!-- Source: performance-tips-dotnet-sdk-v3.md, performance-tips-java-sdk-v4.md -->

In .NET, PPCB is controlled through environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `AZURE_COSMOS_CIRCUIT_BREAKER_ENABLED` | `false` | Enable/disable PPCB |
| `AZURE_COSMOS_PPCB_CONSECUTIVE_FAILURE_COUNT_FOR_READS` | `10` | Read failures before failover |
| `AZURE_COSMOS_PPCB_CONSECUTIVE_FAILURE_COUNT_FOR_WRITES` | `5` | Write failures before failover |

<!-- Source: performance-tips-dotnet-sdk-v3.md -->

In Java (requires SDK version 4.63.0+), use system properties:

```java
System.setProperty(
    "COSMOS.PARTITION_LEVEL_CIRCUIT_BREAKER_CONFIG",
    "{\"isPartitionLevelCircuitBreakerEnabled\": true, "
    + "\"circuitBreakerType\": \"CONSECUTIVE_EXCEPTION_COUNT_BASED\","
    + "\"consecutiveExceptionCountToleratedForReads\": 10,"
    + "\"consecutiveExceptionCountToleratedForWrites\": 5}");
```
<!-- Source: performance-tips-java-sdk-v4.md -->

The Python SDK also supports PPCB through environment variables (`AZURE_COSMOS_ENABLE_CIRCUIT_BREAKER`), with similar threshold configuration.
<!-- Source: performance-tips-python-sdk.md -->

**PPCB vs. hedging: when to use which?**

| Strategy | Cost Impact | Best For | Handles |
|----------|------------|----------|---------|
| Threshold-based hedging | Extra RUs (parallel requests) | Read-heavy, latency-sensitive | Slow regions, tail latency |
| Partition-level circuit breaker | No extra RUs | Write-heavy or mixed | Unhealthy partitions, transient failures |

You can use both together. PPCB handles sustained partition-level issues without extra cost, while hedging covers the transient latency spikes that PPCB might be too slow to catch.
<!-- Source: performance-tips-dotnet-sdk-v3.md, performance-tips-java-sdk-v4.md -->

### Excluded Regions (Per-Request Routing)

Starting with .NET SDK version 3.37.0, you can **exclude specific regions** on a per-request basis without creating separate client instances. This is useful for routing around a region that's returning 429s or experiencing degraded performance:
<!-- Source: performance-tips-dotnet-sdk-v3.md -->

```csharp
var requestOptions = new ItemRequestOptions
{
    ExcludeRegions = new List<string> { "East US" }
};

await container.ReadItemAsync<Order>(id, pk, requestOptions);
```

When all regions are excluded, requests route to the primary region. This feature pairs well with external health-checking systems (traffic managers, load balancers) that can dynamically decide which regions to avoid.
<!-- Source: performance-tips-dotnet-sdk-v3.md -->

### Connection Timeout and Keep-Alive Tuning

Connection-level settings affect how quickly your application detects and recovers from network issues:
<!-- Source: tune-connection-configurations-net-sdk-v3.md -->

**`OpenTcpConnectionTimeout`** — How long to wait for a new TCP connection to establish. The default is 5 seconds. Reducing this to 1 second means faster failure detection and faster failover to the next replica or region. The tradeoff: on slow networks, you might see false connection failures.

**`IdleTcpConnectionTimeout`** — How long to keep idle connections open. The default is indefinite. For services with bursty traffic and long idle periods, setting this to 20 minutes–24 hours prevents ephemeral port exhaustion without constantly tearing down and rebuilding the connection pool.

**`EnableTcpConnectionEndpointRediscovery`** — Enabled by default in .NET. Detects when a backend endpoint changes (due to partition movement or maintenance) and re-establishes connections automatically.
<!-- Source: tune-connection-configurations-net-sdk-v3.md -->

For Java, the equivalent setting is `idleEndpointTimeout` on `DirectConnectionConfig`. The default is 1 hour. Setting this too low forces frequent connection teardown and re-establishment, adding latency to the first request after each reconnection.
<!-- Source: best-practice-java.md -->

The next chapter shifts from the SDK itself to the broader Azure ecosystem — how Cosmos DB integrates with Azure Functions, Event Hubs, Synapse Link, and Microsoft Fabric.
