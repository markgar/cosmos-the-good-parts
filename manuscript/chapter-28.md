# Chapter 28: Capstone — Building a Production-Ready Application

You've spent 27 chapters learning Cosmos DB's moving parts in isolation — data modeling, partitioning, queries, change feed, security, monitoring, testing, deployment. Now it's time to wire them all together. This chapter builds a complete, production-ready application from scratch: a multi-tenant task management API called **TaskHub**. Along the way, you'll see every major concept from this book show up in context, working together the way they do in a real system.

The goal isn't to re-teach anything. Each section applies a concept you've already learned, references the canonical chapter, and focuses on the *integration* — the decisions and trade-offs that only surface when everything has to fit together.

## What We're Building

TaskHub is a multi-tenant API that lets organizations manage tasks for their teams. Each tenant is an organization. Users within a tenant create, assign, update, and complete tasks. The API also maintains a real-time activity log — every task change is captured by the change feed and written to a separate audit container.

Here's the feature set:

- **Multi-tenant isolation.** Each tenant's data lives in a shared container, isolated by partition key.
- **CRUD endpoints.** Create, read, update, delete, and query tasks via a REST API.
- **Activity log.** The change feed drives a downstream processor that writes an immutable audit trail.
- **Identity-based auth.** Microsoft Entra ID and RBAC — no account keys in application code.
- **Observability.** OpenTelemetry traces, Azure Monitor metrics, and alerts for throttling.
- **Automated testing.** Unit tests with a mocked SDK, integration tests against the Docker emulator.
- **Infrastructure as Code.** Bicep templates for the Cosmos DB account, database, and containers, deployed through a CI/CD pipeline.

The primary code is C#/.NET. Where the SDK surface differs meaningfully for Python or JavaScript, we'll note it.

## Designing the Data Model

TaskHub stores two entity types in a single container: **tasks** and **task comments**. This is the item type pattern from Chapter 6 — a `type` discriminator field distinguishes them.

```json
{
  "id": "task-a29f3c",
  "type": "task",
  "tenantId": "contoso",
  "title": "Migrate auth to Entra ID",
  "assignedTo": "kai@contoso.com",
  "status": "in-progress",
  "priority": 2,
  "createdAt": "2025-07-01T14:30:00Z",
  "updatedAt": "2025-07-10T09:15:00Z"
}
```

```json
{
  "id": "comment-e8b712",
  "type": "comment",
  "tenantId": "contoso",
  "taskId": "task-a29f3c",
  "author": "kai@contoso.com",
  "body": "Scoped the work — two-day estimate.",
  "createdAt": "2025-07-02T10:00:00Z"
}
```

Comments are embedded as references, not nested arrays. A task might accumulate hundreds of comments over its lifetime, and embedding unbounded arrays is an anti-pattern (Chapter 4). Keeping them as separate items with the same partition key means they're co-located on the same physical partition and can be fetched together in a single-partition query — or individually by point read.

### Choosing the Partition Key

This is the most consequential decision in the entire application (Chapter 5). TaskHub is multi-tenant, so the partition key needs to isolate tenant data while distributing writes evenly. The natural choice is `/tenantId`.

For small-to-medium tenants, `/tenantId` works well. But what happens when one tenant has 50,000 active tasks and growing? A single logical partition can hold up to 20 GB, which is plenty for task documents. But if you anticipate tenants outgrowing that ceiling — or if you need to isolate RU consumption more finely — you'd reach for **hierarchical partition keys** (Chapter 5). For TaskHub, we'll use a hierarchical key of `/tenantId` → `/type`:

<!-- Source: hierarchical-partition-keys.md -->

```csharp
var containerProperties = new ContainerProperties
{
    Id = "tasks",
    PartitionKeyPaths = new List<string> { "/tenantId", "/type" }
};
```

This gives us efficient single-partition reads when querying a specific tenant's tasks (`WHERE c.tenantId = 'contoso' AND c.type = 'task'`) while keeping the door open for individual tenants to scale beyond the 20 GB logical partition limit.

The audit container is simpler. Its partition key is `/tenantId` — audit entries don't need a second level.

## Implementing CRUD and Query Endpoints

With the data model and partition key in place, the SDK wiring is straightforward. Everything in this section applies Chapter 7 (SDK fundamentals) and Chapter 8 (queries).

### The Singleton Client

First rule: one `CosmosClient` instance for the lifetime of the application. The SDK manages connection pools, caches routing information, and amortizes TCP setup costs. Creating a client per request is the single most common Cosmos DB performance mistake.

```csharp
// Program.cs — register as singleton in the DI container
builder.Services.AddSingleton<CosmosClient>(sp =>
{
    var credential = new DefaultAzureCredential();
    return new CosmosClient(
        accountEndpoint: builder.Configuration["CosmosDb:Endpoint"],
        tokenCredential: credential,
        new CosmosClientOptions
        {
            ApplicationName = "TaskHub",
            ConnectionMode = ConnectionMode.Direct,
            CosmosClientTelemetryOptions = new CosmosClientTelemetryOptions
            {
                DisableDistributedTracing = false
            }
        });
});
```

<!-- Source: sdk-observability.md, how-to-connect-role-based-access-control.md -->

Notice we're using `DefaultAzureCredential` instead of an account key. We'll wire up the RBAC role assignment shortly. And we set `ConnectionMode.Direct` — the lowest-latency option for production workloads (Chapter 7, Chapter 27).

### Point Reads and Upserts

The cheapest operation in Cosmos DB is the point read: fetch an item by `id` + partition key. For TaskHub's "get task by ID" endpoint, that's exactly one RU for a 1 KB item (Chapter 10).

```csharp
public async Task<TaskItem?> GetTaskAsync(string tenantId, string taskId)
{
    try
    {
        var response = await _container.ReadItemAsync<TaskItem>(
            id: taskId,
            partitionKey: new PartitionKeyBuilder()
                .Add(tenantId)
                .Add("task")
                .Build());

        return response.Resource;
    }
    catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.NotFound)
    {
        return null;
    }
}
```

For creating or updating tasks, use `UpsertItemAsync` — it inserts if the item doesn't exist and replaces if it does. This is idempotent, which makes retries safe:

```csharp
public async Task<TaskItem> UpsertTaskAsync(TaskItem task)
{
    var response = await _container.UpsertItemAsync(
        item: task,
        partitionKey: new PartitionKeyBuilder()
            .Add(task.TenantId)
            .Add("task")
            .Build());

    _logger.LogInformation("Upserted task {TaskId}. RU charge: {RU}",
        task.Id, response.RequestCharge);

    return response.Resource;
}
```

Always log the RU charge. It's the single most useful number for understanding cost and performance. The charge comes back in every response header — Chapter 7 covers the mechanics, Chapter 10 covers what to do with the data.

### Querying Tasks

To list all tasks for a tenant, filtered by status:

```csharp
public async IAsyncEnumerable<TaskItem> QueryTasksAsync(
    string tenantId,
    string? status = null)
{
    var queryBuilder = new StringBuilder(
        "SELECT * FROM c WHERE c.tenantId = @tenantId AND c.type = 'task'");

    var parameters = new List<(string, object)>
    {
        ("@tenantId", tenantId)
    };

    if (status is not null)
    {
        queryBuilder.Append(" AND c.status = @status");
        parameters.Add(("@status", status));
    }

    queryBuilder.Append(" ORDER BY c.updatedAt DESC");

    var queryDef = new QueryDefinition(queryBuilder.ToString());
    foreach (var (name, value) in parameters)
        queryDef = queryDef.WithParameter(name, value);

    using var iterator = _container.GetItemQueryIterator<TaskItem>(
        queryDef,
        requestOptions: new QueryRequestOptions
        {
            PartitionKey = new PartitionKeyBuilder()
                .Add(tenantId)
                .Add("task")
                .Build()
        });

    while (iterator.HasMoreResults)
    {
        var batch = await iterator.ReadNextAsync();
        foreach (var item in batch)
            yield return item;
    }
}
```

A few things to note:

- **Parameterized queries.** Never string-concatenate user input into query text. Parameterized queries prevent injection and enable query plan reuse (Chapter 8).
- **Partition key in the request.** Because we specify both levels of the hierarchical partition key, this is a single-partition query — no fan-out, minimal RU cost (Chapter 5, Chapter 8).
- **`ORDER BY` requires a composite index** if you're ordering by a field that's also filtered. We'll handle that in the Bicep template. If you need a refresher on composite index ordering rules, see Chapter 9.

> **Python/JS note:** The Python SDK uses `query_items()` on the container, returning an async iterable. The JavaScript SDK uses `container.items.query()`. The pattern is the same — parameterized queries, single-partition targeting, paginated iteration.

## Adding Change Feed Processing

Every time a task is created or updated, we want an audit entry written to a separate container. The change feed is the right tool — it captures inserts and updates automatically, with at-least-once delivery (Chapter 15).

### Setting Up the Processor

The change feed processor needs four things: the monitored container, a lease container, an instance name, and a delegate that handles each batch of changes.

<!-- Source: change-feed-processor.md -->

```csharp
public class AuditFeedProcessor : IHostedService
{
    private readonly CosmosClient _client;
    private ChangeFeedProcessor? _processor;
    private readonly ILogger<AuditFeedProcessor> _logger;

    public AuditFeedProcessor(CosmosClient client, ILogger<AuditFeedProcessor> logger)
    {
        _client = client;
        _logger = logger;
    }

    public async Task StartAsync(CancellationToken cancellationToken)
    {
        var tasksContainer = _client.GetContainer("taskhub-db", "tasks");
        var leaseContainer = _client.GetContainer("taskhub-db", "leases");

        _processor = tasksContainer
            .GetChangeFeedProcessorBuilder<TaskItem>(
                processorName: "auditProcessor",
                onChangesDelegate: HandleChangesAsync)
            .WithInstanceName(Environment.MachineName)
            .WithLeaseContainer(leaseContainer)
            .Build();

        await _processor.StartAsync();
        _logger.LogInformation("Audit change feed processor started.");
    }

    private async Task HandleChangesAsync(
        ChangeFeedProcessorContext context,
        IReadOnlyCollection<TaskItem> changes,
        CancellationToken cancellationToken)
    {
        var auditContainer = _client.GetContainer("taskhub-db", "audit");

        foreach (var task in changes)
        {
            var entry = new AuditEntry
            {
                Id = Guid.NewGuid().ToString(),
                TenantId = task.TenantId,
                TaskId = task.Id,
                Action = task.Status == "deleted" ? "deleted" : "upserted",
                Snapshot = task,
                Timestamp = DateTime.UtcNow
            };

            await auditContainer.CreateItemAsync(
                entry,
                new PartitionKey(entry.TenantId));
        }

        _logger.LogInformation(
            "Processed {Count} changes. Lease: {Lease}, RU: {RU}",
            changes.Count, context.LeaseToken, context.Headers.RequestCharge);
    }

    public async Task StopAsync(CancellationToken cancellationToken)
    {
        if (_processor is not null)
            await _processor.StopAsync();
    }
}
```

Register it as a hosted service:

```csharp
builder.Services.AddHostedService<AuditFeedProcessor>();
```

The lease container stores checkpoints — one document per physical partition range. If the processor crashes and restarts, it picks up where it left off. If you need to scale horizontally, deploy multiple instances with different `WithInstanceName` values and the processor automatically distributes partition ranges across them (Chapter 15).

### Why Not Azure Functions?

You could replace this entire class with an Azure Functions change feed trigger (Chapter 22) and get the same behavior with less code. We're using the processor library here because TaskHub is already a long-running API service — adding a hosted service keeps everything in one process, simplifies deployment, and avoids managing a separate Functions app. For event-driven architectures where compute should scale to zero, the Functions trigger is the better choice.

## Securing the App with Entra ID and RBAC

Account keys are a liability. They grant full access to everything in the account, they don't expire automatically, and rotating them means coordinating across every service that holds a copy. TaskHub uses **Microsoft Entra ID** with **data-plane RBAC** instead (Chapter 17).

### The Role Assignment

Cosmos DB has two built-in data-plane roles:

<!-- Source: reference-data-plane-security.md -->

| Role | ID |
|---|---|
| **Built-in Data Reader** | `00000000-0000-0000-0000-000000000001` |
| **Built-in Data Contributor** | `00000000-0000-0000-0000-000000000002` |

- **Data Reader:** read items, execute queries, read change feed.
- **Data Contributor:** full CRUD on containers and items.

TaskHub's API needs to read and write data, so we assign the **Data Contributor** role to the app's managed identity. Here's the Azure CLI command:

```bash
az cosmosdb sql role assignment create \
    --account-name taskhub-cosmos \
    --resource-group taskhub-rg \
    --role-definition-id "00000000-0000-0000-0000-000000000002" \
    --principal-id "<managed-identity-object-id>" \
    --scope "/dbs/taskhub-db"
```

Scoping to `/dbs/taskhub-db` limits the identity to that single database — it can't touch other databases in the account. This follows the principle of least privilege.

### Disabling Key-Based Auth

Once RBAC is wired up and verified, disable key-based authentication entirely:

<!-- Source: how-to-connect-role-based-access-control.md -->

```bash
az resource update \
    --resource-group taskhub-rg \
    --name taskhub-cosmos \
    --resource-type "Microsoft.DocumentDB/databaseAccounts" \
    --set properties.disableLocalAuth=true
```

Now there's no key to leak. The `CosmosClient` we registered earlier already uses `DefaultAzureCredential`, which resolves to the managed identity in Azure and to your developer credentials locally. Chapter 17 has the full breakdown of the authentication chain and how to configure it for different environments.

## Wiring Up Monitoring, Alerting, and Distributed Tracing

A production app you can't observe is a production app you can't fix. TaskHub wires up three layers of observability (Chapters 18 and 21).

### OpenTelemetry Distributed Tracing

We already enabled `DisableDistributedTracing = false` in the `CosmosClientOptions` when we registered the singleton client. That's the SDK side. Now we need an exporter to actually send traces somewhere.

<!-- Source: sdk-observability.md -->

```csharp
builder.Services.AddOpenTelemetry()
    .WithTracing(tracing =>
    {
        tracing
            .AddSource("Azure.Cosmos.Operation")
            .AddAspNetCoreInstrumentation()
            .AddHttpClientInstrumentation()
            .AddOtlpExporter(); // Send to Azure Monitor, Jaeger, etc.
    });
```

Every Cosmos DB operation now emits a span with attributes like `db.cosmosdb.request_charge`, `db.cosmosdb.status_code`, and `db.cosmosdb.regions_contacted`. These correlate with your application-level spans, so you can trace a single HTTP request from the API endpoint all the way through to the Cosmos DB point read — and see exactly how many RUs it cost.

For diagnostics on slow or failed operations, the .NET SDK automatically logs detailed diagnostics when latency exceeds configurable thresholds:

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

### Azure Monitor Alerts

Set up alerts for the two failure modes that matter most: throttling and elevated latency. In the Azure portal (or through your Bicep template), create:

1. **429 alert.** Fire when `TotalRequests` with `StatusCode = 429` exceeds 0 in any 5-minute window. Any throttling in production deserves investigation.
2. **P99 latency alert.** Fire when server-side latency at the 99th percentile exceeds your SLA target. For most CRUD APIs, 20 ms is a reasonable threshold.

### Diagnostic Logs for Query Analysis

Enable diagnostic settings to ship `DataPlaneRequests` and `QueryRuntimeStatistics` to a Log Analytics workspace. This gives you the ability to find your most expensive queries after the fact:

<!-- Source: diagnostic-queries.md -->

```kusto
let topRequestsByRUcharge = CDBDataPlaneRequests
| where TimeGenerated > ago(24h)
| project RequestCharge, TimeGenerated, ActivityId;
CDBQueryRuntimeStatistics
| project QueryText, ActivityId, DatabaseName, CollectionName
| join kind=inner topRequestsByRUcharge on ActivityId
| project DatabaseName, CollectionName, QueryText, RequestCharge, TimeGenerated
| order by RequestCharge desc
| take 10
```

This query joins data-plane request logs with query runtime statistics to surface the top 10 costliest queries in the last 24 hours. Run it weekly — or better, wire it into a scheduled alert — and you'll catch query regressions before they become incidents. Chapter 18 covers the full diagnostic logging setup; Chapter 27 walks through the performance tuning loop.

## Writing the Test Suite

Testing a Cosmos DB application requires strategy at three levels (Chapter 24).

### Unit Tests: Mock the SDK

Your repository class depends on a `Container` — not on Cosmos DB itself. Wrap it behind an interface and mock it in unit tests.

```csharp
public interface ITaskRepository
{
    Task<TaskItem?> GetTaskAsync(string tenantId, string taskId);
    Task<TaskItem> UpsertTaskAsync(TaskItem task);
    IAsyncEnumerable<TaskItem> QueryTasksAsync(string tenantId, string? status = null);
}
```

Now your API controller tests never hit a database. They verify HTTP status codes, response shapes, and business logic — fast, deterministic, no infrastructure required.

### Integration Tests: The Docker Emulator

For tests that verify actual Cosmos DB behavior — query correctness, indexing policy effects, partition key routing — run the Linux-based vNext emulator as a Docker container:

<!-- Source: emulator-linux.md -->

```bash
docker run --detach \
    --publish 8081:8081 \
    --publish 1234:1234 \
    mcr.microsoft.com/cosmosdb/linux/azure-cosmos-emulator:vnext-preview \
    --protocol https
```

The emulator runs on port 8081 and supports the NoSQL API in gateway mode. Use it in your test fixture to create the database, containers, seed test data, run your integration tests, and tear everything down:

```csharp
public class CosmosIntegrationFixture : IAsyncLifetime
{
    public CosmosClient Client { get; private set; } = null!;
    public Container TasksContainer { get; private set; } = null!;

    public async Task InitializeAsync()
    {
        Client = new CosmosClient(
            "https://localhost:8081",
            "C2y6yDjf5/R+ob0N8A7Cgv30VRDJIWEHLM+4QDU5DE2nQ9nDuVTqobD4b8mGGyPMbIZnqyMsEcaGQy67XIw/Jw==",
            new CosmosClientOptions
            {
                ConnectionMode = ConnectionMode.Gateway,
                HttpClientFactory = () => new HttpClient(
                    new HttpClientHandler
                    {
                        ServerCertificateCustomValidationCallback =
                            HttpClientHandler.DangerousAcceptAnyServerCertificateValidator
                    })
            });

        var db = await Client.CreateDatabaseIfNotExistsAsync("taskhub-db");
        TasksContainer = await db.Database.CreateContainerIfNotExistsAsync(
            new ContainerProperties
            {
                Id = "tasks",
                PartitionKeyPaths = new List<string> { "/tenantId", "/type" }
            },
            throughput: 400);
    }

    public async Task DisposeAsync()
    {
        await Client.GetDatabase("taskhub-db").DeleteAsync();
        Client.Dispose();
    }
}
```

Two gotchas to know (both covered in Chapter 24):

1. **Gateway mode only.** The vNext emulator doesn't support Direct mode. Your integration tests will use gateway connectivity even though production uses direct. That's fine — the query and CRUD behavior is identical.
2. **Self-signed certificate.** The emulator uses a self-signed HTTPS cert. The `DangerousAcceptAnyServerCertificateValidator` bypass shown above is acceptable *only* in test code. Never use it in production.

### CI Pipeline Integration

In your GitHub Actions or Azure DevOps pipeline, spin up the emulator as a service container, run integration tests against it, then tear it down. The emulator starts in seconds and costs nothing. This gives you real Cosmos DB query semantics in CI without an Azure subscription. Chapter 20 covers the full pipeline setup.

## Deploying to Azure with Bicep

TaskHub's infrastructure is defined in Bicep — the Cosmos DB account, database, both containers, the diagnostic settings, and the RBAC role assignment. No portal clicking in production, ever (Chapter 20).

### The Bicep Template

Here's the core of the template, focused on the Cosmos DB resources:

<!-- Source: quickstart-template-bicep.md, manage-with-bicep.md -->

```bicep
@description('Cosmos DB account name')
param accountName string = 'taskhub-${uniqueString(resourceGroup().id)}'

@description('Primary region')
param location string = resourceGroup().location

@description('Principal ID for the API managed identity')
param apiPrincipalId string

// RBAC role assignment and diagnostic settings omitted for brevity — see Chapters 17 and 18

resource account 'Microsoft.DocumentDB/databaseAccounts@2024-02-15-preview' = {
  name: toLower(accountName)
  location: location
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
    locations: [
      {
        locationName: location
        failoverPriority: 0
        isZoneRedundant: true
      }
    ]
    enableAutomaticFailover: true
    disableLocalAuth: true
  }
}

resource database 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2024-02-15-preview' = {
  parent: account
  name: 'taskhub-db'
  properties: {
    resource: { id: 'taskhub-db' }
  }
}

resource tasksContainer 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-02-15-preview' = {
  parent: database
  name: 'tasks'
  properties: {
    resource: {
      id: 'tasks'
      partitionKey: {
        paths: [ '/tenantId', '/type' ]
        kind: 'MultiHash'
        version: 2
      }
      indexingPolicy: {
        indexingMode: 'consistent'
        includedPaths: [ { path: '/*' } ]
        excludedPaths: [ { path: '/_etag/?' } ]
        compositeIndexes: [
          [
            { path: '/tenantId', order: 'ascending' }
            { path: '/updatedAt', order: 'descending' }
          ]
        ]
      }
      defaultTtl: -1 // Enables per-item TTL without a container-wide expiration — useful for soft-expiring completed tasks later
    }
    options: {
      autoscaleSettings: { maxThroughput: 1000 }
    }
  }
}

resource auditContainer'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-02-15-preview' = {
  parent: database
  name: 'audit'
  properties: {
    resource: {
      id: 'audit'
      partitionKey: {
        paths: [ '/tenantId' ]
        kind: 'Hash'
      }
      defaultTtl: 7776000 // 90 days — audit entries expire automatically
    }
    options: {
      autoscaleSettings: { maxThroughput: 1000 }
    }
  }
}

resource leaseContainer 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-02-15-preview' = {
  parent: database
  name: 'leases'
  properties: {
    resource: {
      id: 'leases'
      partitionKey: {
        paths: [ '/id' ]
        kind: 'Hash'
      }
    }
    options: { throughput: 400 }
  }
}
```

A few decisions embedded in this template:

- **`disableLocalAuth: true`** — no key-based auth from day one. The account is Entra-only.
- **Autoscale at 1,000 max RU/s** for the tasks and audit containers. That means a baseline of 100 RU/s when idle, scaling up to 1,000 under load (Chapter 11). Generous for a new app; easy to bump later by redeploying with a higher value.
- **TTL on the audit container.** Audit entries expire after 90 days. TTL cleanup is automatic and consumes only leftover RUs that haven't been used by user requests — effectively free under most provisioned workloads, but not truly zero-cost. On serverless accounts, expired-item deletions are charged at the normal delete rate (Chapter 6). <!-- Source: manage-your-account/containers-and-items/time-to-live.md -->
- **The lease container uses manual throughput at 400 RU/s.** Lease containers are low-traffic by nature; autoscale would be wasteful.
- **Composite index on `[/tenantId ASC, /updatedAt DESC]`.** This supports the `ORDER BY c.updatedAt DESC` query we wrote earlier without an expensive full-index scan (Chapter 9).

### Deploying the Template

```bash
az deployment group create \
    --resource-group taskhub-rg \
    --template-file infra/main.bicep \
    --parameters apiPrincipalId="<managed-identity-object-id>"
```

This command is what your CI/CD pipeline runs on every merge to `main`. The Bicep template is idempotent — redeploying with the same parameters is a no-op. Changing the autoscale max or adding a composite index is a code change, reviewed in a pull request, applied through the pipeline. No portal drift, no undocumented manual changes. Chapter 20 covers the full CI/CD pipeline design, including environment promotion from dev to staging to production.

## Retrospective: Trade-offs Made and Alternatives Considered

Every architecture is a set of trade-offs. Here's what we chose for TaskHub, what we gave up, and when you'd choose differently.

**Shared container with item type pattern vs. separate containers per entity.** We put tasks and comments in the same container, using hierarchical partition keys and a `type` discriminator. This minimizes the number of containers to manage and keeps related data co-located. The trade-off: your indexing policy applies to all item types in the container. If tasks and comments had radically different query patterns, separate containers with tailored indexing policies might be more efficient. For TaskHub's workload, the unified approach wins on simplicity.

**Hierarchical partition keys vs. simple `/tenantId`.** We added `/type` as a second-level key to future-proof for large tenants. If your tenants are uniformly small (under a few GB each), a flat `/tenantId` key is simpler and equally effective. The hierarchical key adds a small amount of SDK complexity — you build `PartitionKeyBuilder` instances instead of plain `PartitionKey` values — but eliminates a painful migration if a tenant outgrows the 20 GB logical partition limit later.

**Change feed processor vs. Azure Functions trigger.** We embedded the change feed processor as a hosted service inside the API process. This is the right call for a single long-running service that's already deployed. If TaskHub evolved into a microservices architecture, or if we needed the processor to scale independently of the API, the Azure Functions trigger (Chapter 22) would be the better choice — it handles scaling, checkpointing, and lifecycle management for you.

**Entra ID RBAC vs. account keys.** No trade-off here — RBAC is strictly better for production workloads. The only scenario where keys make sense is quick prototyping or environments where Entra ID isn't available (like certain air-gapped setups). Chapter 17 covers the edge cases.

**Autoscale vs. manual throughput.** Autoscale costs 50% more per RU at peak compared to manual provisioned throughput. If TaskHub's traffic were perfectly predictable, manual provisioning would save money. It rarely is.

Autoscale trades a modest cost premium for the insurance that you won't throttle users during unexpected spikes. For a new application without traffic history, it's the right default. Once you have months of usage data, you can switch specific containers to manual provisioning if the savings justify the risk (Chapter 11).

**Session consistency.** We left the default — Session consistency. It guarantees that a client always reads its own writes, which is exactly what a CRUD API needs. Stronger consistency (Bounded Staleness, Strong) would cost more RUs per read and limit multi-region write configurations. Weaker consistency (Eventual) would risk a user creating a task and not seeing it in the response list — a confusing experience. Session is the sweet spot for this workload, and for most workloads (Chapter 13).

**What's missing.** TaskHub is deliberately minimal. A production system would also need:

- Rate limiting per tenant
- A CDN for static assets
- Graceful degradation under sustained throttling
- A blue/green deployment strategy for container schema changes
- Vector search if you're building task recommendation features

Each of those is covered in its respective chapter — this capstone showed you the skeleton that everything else hangs on.

---

In Chapter 1, we made a promise: by the end of this book, you'd understand Cosmos DB well enough to build confidently on it — not just follow tutorials, but make real architectural decisions with full awareness of the trade-offs. TaskHub is that promise delivered. It's not a toy demo. It's a multi-tenant, change-feed-driven, RBAC-secured, infrastructure-as-code-deployed, observable, testable application built on every concept this book covers.

The patterns you've learned aren't specific to task management. Swap tasks for orders, or IoT events, or patient records, and the architecture translates directly. The partition key choice changes. The query patterns shift. The TTL values differ. But the skeleton — singleton client, hierarchical partition key, change feed for side effects, Entra ID for auth, OpenTelemetry for traces, Bicep for deployment, emulator for tests — that skeleton is the starting point for every production Cosmos DB application you'll build from here.

Now go build something.
