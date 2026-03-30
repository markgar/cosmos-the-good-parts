# Chapter 7: Using the Cosmos DB SDKs

You've created an account, designed your documents, chosen your partition key. Now it's time to write code. This chapter is the canonical reference for connecting to Cosmos DB, performing CRUD operations, and managing your client correctly in production. We'll work primarily in C#, Python, and JavaScript/Node.js — the three most popular SDK ecosystems — with notes on where the others differ.

If you followed the quickstart in Chapter 3, you've already written your first item through the SDK. Here, we go deeper: the object model, the patterns that matter in production, and the gotchas that will bite you if you learn them the hard way.

## Overview of Supported SDKs

Azure Cosmos DB for NoSQL has official SDKs for six languages:

<!-- Source: quickstart-dotnet.md, quickstart-python.md, quickstart-nodejs.md, quickstart-go.md, quickstart-rust.md -->

| Language | Package | Install Command |
|----------|---------|----------------|
| **.NET** | `Microsoft.Azure.Cosmos` | `dotnet add package Microsoft.Azure.Cosmos` |
| **Java** | `com.azure:azure-cosmos` | Maven/Gradle dependency |
| **Python** | `azure-cosmos` | `pip install azure-cosmos` |
| **JavaScript/Node.js** | `@azure/cosmos` | `npm install @azure/cosmos` |
| **Go** | `azcosmos` | `go install github.com/Azure/azure-sdk-for-go/sdk/data/azcosmos` |
| **Rust** | `azure_data_cosmos` | `cargo add azure_data_cosmos` |

> **Gotcha:** The Rust SDK is in **public preview** — no SLA, not recommended for production workloads. Everything else is GA. <!-- Source: quickstart-rust.md -->

All six SDKs follow the same conceptual model: you create a client, navigate to a database and container, and perform operations on items. The API surface names differ slightly by language, but the structure is identical. Once you understand the pattern in one SDK, you can translate it to any other.

The .NET SDK gets new features first and has the deepest integration (Direct mode, LINQ, partition-level circuit breaker). If you're choosing a stack for a new project and have flexibility, .NET gives you the most knobs to turn. But the Python and JavaScript SDKs are fully capable for production workloads — the choice should be driven by your team's expertise, not Cosmos DB feature gaps.

## SDK Fundamentals: CosmosClient, Database, Container

Every SDK mirrors the Cosmos DB resource hierarchy you learned in Chapter 2: **account → database → container → item**. The SDK maps this to three core objects.

### The Object Model

| .NET | Python | JavaScript | Role |
|------|--------|------------|------|
| `CosmosClient` | `CosmosClient` | `CosmosClient` | Entry point. Connects to your account. |
| `Database` | `DatabaseProxy` | `Database` | Reference to a database. |
| `Container` | `ContainerProxy` | `Container` | Where you perform item operations. |

<!-- Source: how-to-dotnet-get-started.md, how-to-python-get-started.md, how-to-javascript-get-started.md -->

The `CosmosClient` is the top of the chain. You create one, then navigate down to a database and container. The database and container objects are lightweight references — creating them doesn't make a network call. They're validated server-side only when you actually perform an operation.

Here's what the setup looks like in all three languages:

**C#**
```csharp
using Microsoft.Azure.Cosmos;

CosmosClient client = new(
    accountEndpoint: "https://your-account.documents.azure.com:443/",
    tokenCredential: new DefaultAzureCredential()
);

Database database = client.GetDatabase("cosmicworks");
Container container = database.GetContainer("products");
```

**Python**
```python
from azure.cosmos import CosmosClient
from azure.identity import DefaultAzureCredential

client = CosmosClient(
    url="https://your-account.documents.azure.com:443/",
    credential=DefaultAzureCredential()
)

database = client.get_database_client("cosmicworks")
container = database.get_container_client("products")
```

**JavaScript**
```javascript
const { CosmosClient } = require("@azure/cosmos");
const { DefaultAzureCredential } = require("@azure/identity");

const client = new CosmosClient({
    endpoint: "https://your-account.documents.azure.com:443/",
    aadCredentials: new DefaultAzureCredential()
});

const database = client.database("cosmicworks");
const container = database.container("products");
```

<!-- Source: quickstart-dotnet.md, quickstart-python.md, quickstart-nodejs.md -->

Notice that all three examples use `DefaultAzureCredential` from Azure Identity rather than connection strings or master keys. This is the recommended approach — it supports managed identities in Azure, service principals in CI/CD, and your developer credentials locally. We'll cover the security implications in detail in Chapter 17; for now, just adopt the pattern.

> **Tip:** You can still use a connection string or account key for local development and the emulator. But for anything that touches a real Azure account, prefer Microsoft Entra ID authentication via `DefaultAzureCredential`.

## CRUD Operations in Code

With a `Container` object in hand, you're ready to work with data. Let's walk through every fundamental operation.

### Creating and Upserting Items

The most common write operation is an **upsert**: create the item if it doesn't exist, replace it if it does. This is the default in the quickstart samples for a reason — it's idempotent, which makes it safe to retry.

**C#**
```csharp
var product = new Product(
    id: "prod-1001",
    category: "gear-surf-surfboards",
    name: "Yamba Surfboard",
    quantity: 12,
    price: 850.00m,
    clearance: false
);

ItemResponse<Product> response = await container.UpsertItemAsync(
    item: product,
    partitionKey: new PartitionKey("gear-surf-surfboards")
);

Console.WriteLine($"Upsert cost: {response.RequestCharge} RUs");
```

**Python**
```python
product = {
    "id": "prod-1001",
    "category": "gear-surf-surfboards",
    "name": "Yamba Surfboard",
    "quantity": 12,
    "price": 850.00,
    "clearance": False,
}

response = container.upsert_item(product)
```

**JavaScript**
```javascript
const product = {
    id: "prod-1001",
    category: "gear-surf-surfboards",
    name: "Yamba Surfboard",
    quantity: 12,
    price: 850.00,
    clearance: false
};

const { resource, headers } = await container.items.upsert(product);
console.log(`Upsert cost: ${headers["x-ms-request-charge"]} RUs`);
```

<!-- Source: quickstart-dotnet.md, quickstart-python.md, quickstart-nodejs.md -->

A few things to notice:

- **You always pass the partition key** with write operations. The SDK needs it to route the request to the correct physical partition. If you forget it, the SDK will try to extract it from the item body — but being explicit is better practice. Chapter 5 explained why partition key routing matters; this is where that theory becomes code.
- **The response includes the RU charge.** We'll cover how to read it systematically later in this chapter, but notice it's available right here on every response.
- **Upsert vs. Create:** As you saw in Chapter 3, upsert is idempotent — it creates or replaces. Use `CreateItemAsync` (C#) or `create_item` (Python) when you specifically need insert-only semantics; it returns HTTP 409 if the item already exists.

### Reading Items (Point Read)

The cheapest operation in Cosmos DB is the **point read**: fetch a single item by its `id` and partition key. No query engine, no index scan — just a direct lookup to the correct physical partition. About 1 RU for a 1 KB document. Chapter 10 will quantify exactly how RU costs scale with document size.

**C#**
```csharp
ItemResponse<Product> response = await container.ReadItemAsync<Product>(
    id: "prod-1001",
    partitionKey: new PartitionKey("gear-surf-surfboards")
);

Product product = response.Resource;
double ruCost = response.RequestCharge;
```

**Python**
```python
product = container.read_item(
    item="prod-1001",
    partition_key="gear-surf-surfboards"
)
```

**JavaScript**
```javascript
const { resource: product } = await container
    .item("prod-1001", "gear-surf-surfboards")
    .read();
```

<!-- Source: quickstart-dotnet.md, quickstart-python.md, quickstart-nodejs.md -->

This is the operation you should reach for whenever you know the `id` and partition key. If your most frequent access pattern can't be served by a point read, that's a signal to reconsider your data model (Chapter 4) or your partition key (Chapter 5).

> **Gotcha:** A point read requires *both* `id` and partition key. If you only have the `id`, you have to run a query — which is significantly more expensive. Design your access patterns so your hot path always has both values available.

### Partial Document Update with the Patch API

Sometimes you need to update a single field without replacing the entire document. The **Patch API** lets you do exactly that — send just the changes, saving both bandwidth and RU cost compared to a full read-modify-write cycle.

**C#**
```csharp
ItemResponse<Product> response = await container.PatchItemAsync<Product>(
    id: "prod-1001",
    partitionKey: new PartitionKey("gear-surf-surfboards"),
    patchOperations: new[] {
        PatchOperation.Replace("/price", 799.00),
        PatchOperation.Increment("/quantity", -1)
    }
);
```

<!-- Source: partial-document-update-getting-started.md -->

You can combine up to 10 patch operations in a single call. The supported operations are **Add**, **Set**, **Replace**, **Remove**, **Increment**, and **Move**. You can also apply a conditional predicate so the patch only executes if the item matches a filter.

<!-- Source: partial-document-update.md -->

This is just a taste — Chapter 6 is the canonical home for the Patch API, covering all six operations, conditional patching, RU savings, and transactional batch integration. If you're deciding between Patch and a full Replace, start there.

### Querying with FeedIterator and Async Paging

Point reads are great when you know exactly which item you want. When you need multiple items that match a condition, you write a query. Cosmos DB's query language looks like SQL (covered in depth in Chapter 8), and the SDK returns results through a **paged iterator** pattern.

Results come back in pages because a single query might match thousands of items across multiple partitions. The SDK gives you a page at a time; you loop until there are no more pages.

**C#**
```csharp
var query = new QueryDefinition(
    "SELECT * FROM products p WHERE p.category = @category"
).WithParameter("@category", "gear-surf-surfboards");

using FeedIterator<Product> feed = container.GetItemQueryIterator<Product>(query);

List<Product> results = new();
while (feed.HasMoreResults)
{
    FeedResponse<Product> page = await feed.ReadNextAsync();
    foreach (Product item in page)
    {
        results.Add(item);
    }
}
```

**Python**
```python
query = "SELECT * FROM products p WHERE p.category = @category"
parameters = [{"name": "@category", "value": "gear-surf-surfboards"}]

results = container.query_items(
    query=query,
    parameters=parameters,
    enable_cross_partition_query=False
)

items = [item for item in results]
```

**JavaScript**
```javascript
const querySpec = {
    query: "SELECT * FROM products p WHERE p.category = @category",
    parameters: [{ name: "@category", value: "gear-surf-surfboards" }]
};

const { resources: items } = await container.items
    .query(querySpec)
    .fetchAll();
```

<!-- Source: how-to-dotnet-query-items.md, quickstart-python.md, quickstart-nodejs.md -->

A few things to highlight:

- **Always use parameterized queries.** The `@category` syntax prevents SQL injection and enables query plan reuse on the server. Never concatenate user input into query strings.
- **The C# `FeedIterator` is the most explicit.** You control the page-by-page loop with `HasMoreResults` and `ReadNextAsync`. Each `FeedResponse` contains a page of results plus metadata (RU charge, continuation token, diagnostics).
- **Python and JavaScript abstract the paging.** The Python SDK returns an iterable that pages transparently. The JavaScript `fetchAll()` drains all pages into one array — convenient for small result sets, but be cautious with large ones since it loads everything into memory.
- **Cross-partition queries require a flag in Python.** Set `enable_cross_partition_query=True` when your query can't be scoped to a single partition. We'll explore the cost implications of cross-partition queries in Chapter 8.

For large result sets, you'll want to page through results using **continuation tokens** rather than loading everything at once. The `FeedResponse` includes a continuation token that you can store (in a cookie, URL parameter, or cache) and pass back to resume iteration later. Chapter 8 covers pagination strategies in depth.

### Deleting Items

Deleting an item also requires `id` and partition key — same as a point read.

**C#**
```csharp
await container.DeleteItemAsync<Product>(
    id: "prod-1001",
    partitionKey: new PartitionKey("gear-surf-surfboards")
);
```

**Python**
```python
container.delete_item(
    item="prod-1001",
    partition_key="gear-surf-surfboards"
)
```

**JavaScript**
```javascript
await container.item("prod-1001", "gear-surf-surfboards").delete();
```

There's no soft delete built into Cosmos DB. Once it's gone, it's gone — unless you have continuous backup with point-in-time restore enabled (Chapter 19). For time-based expiration, Chapter 6 covers TTL (time-to-live), which lets items delete themselves automatically after a set duration. For bulk server-side deletion of all items sharing a partition key, Chapter 6 also covers the delete-by-partition-key feature.

## Connection Management: The Singleton Client Pattern

This is the single most impactful performance decision in your SDK usage, and it's the one developers most often get wrong.

**Use a single `CosmosClient` instance for the lifetime of your application.** One client per Cosmos DB account, shared across all requests. Do not create a new client per request, per controller, or per function invocation.

<!-- Source: performance-tips-dotnet-sdk-v3.md, best-practice-dotnet.md, best-practice-python.md -->

Why does this matter so much? The `CosmosClient` is thread-safe and manages its own internal connection pool. When you create one, it:

1. **Resolves account metadata** — fetches container information and partition key definitions from the gateway.
2. **Builds a routing map** — discovers which physical partitions exist and where their replicas live.
3. **Opens TCP connections** (in Direct mode) — establishes long-lived connections to backend replicas.

All of that is cached for the lifetime of the client. Creating a new client per request throws away that cache, re-resolves metadata, and opens fresh connections every time. At scale, this causes connection exhaustion, dramatically higher latency, and sporadic failures.

Here's the recommended pattern in each language:

**C# (ASP.NET Core dependency injection)**
```csharp
// In Program.cs or Startup.cs — register as singleton
builder.Services.AddSingleton<CosmosClient>(sp =>
{
    return new CosmosClient(
        accountEndpoint: configuration["CosmosDb:Endpoint"],
        tokenCredential: new DefaultAzureCredential(),
        clientOptions: new CosmosClientOptions
        {
            ApplicationRegion = Regions.EastUS
        }
    );
});
```

**Python (module-level singleton)**
```python
# cosmos_client.py — import this wherever you need it
from azure.cosmos import CosmosClient
from azure.identity import DefaultAzureCredential

_client = CosmosClient(
    url=os.environ["COSMOS_ENDPOINT"],
    credential=DefaultAzureCredential(),
    preferred_locations=["East US", "West US"]
)

def get_container(database_name: str, container_name: str):
    return _client.get_database_client(database_name) \
                   .get_container_client(container_name)
```

**JavaScript (module-level singleton)**
```javascript
// cosmosClient.js — import this wherever you need it
const { CosmosClient } = require("@azure/cosmos");
const { DefaultAzureCredential } = require("@azure/identity");

const client = new CosmosClient({
    endpoint: process.env.COSMOS_ENDPOINT,
    aadCredentials: new DefaultAzureCredential()
});

module.exports = client;
```

<!-- Source: performance-tips-dotnet-sdk-v3.md, best-practice-python.md, best-practices-javascript.md -->

> **Gotcha:** In Azure Functions, the same rule applies — but it's easy to violate. Functions on the Consumption plan spin up and tear down instances frequently. Store your `CosmosClient` in a static field (C#) or a module-level variable (Python/JS) so it survives across invocations within the same host instance. Don't create it inside the function handler.

## Direct vs. Gateway Connectivity Mode

When your SDK talks to Cosmos DB, the request travels over one of two **connectivity modes**: **Direct** or **Gateway**. This choice affects latency, connection behavior, and which firewall ports you need open.

<!-- Source: sdk-connection-modes.md -->

### Gateway Mode

In **Gateway mode**, every request goes through HTTPS to a gateway server in the Cosmos DB frontend. The gateway resolves routing (which partition? which replica?) and forwards the request to the backend. It's an extra network hop, but it uses standard HTTPS on port 443 — no special firewall rules needed.

All SDKs support Gateway mode. It's the *only* mode available for Python, JavaScript, and Go.

### Direct Mode

In **Direct mode**, the SDK opens TCP connections directly to the backend replica nodes that store your data. It skips the gateway hop, which means lower latency and higher throughput. The tradeoff: your client needs access to ports in the range **10,000–20,000** (or 0–65,535 when using private endpoints).

<!-- Source: sdk-connection-modes.md -->

Direct mode is supported only in the **.NET** and **Java** SDKs. The .NET SDK v3 uses Direct mode by default.

### When to Use Which

| Scenario | Recommended Mode |
|----------|-----------------|
| **.NET or Java**, no firewall restrictions | **Direct** (default in .NET v3) |
| Python, JavaScript, or Go | **Gateway** (only option) |
| Corporate network with strict firewall rules | **Gateway** |
| Azure Functions on Consumption plan | **Gateway** (limited socket connections) |
| Lowest possible latency in .NET/Java | **Direct** |

To switch modes in .NET:

```csharp
var client = new CosmosClient(
    endpoint,
    credential,
    new CosmosClientOptions
    {
        ConnectionMode = ConnectionMode.Gateway  // Default is Direct
    }
);
```

<!-- Source: performance-tips-dotnet-sdk-v3.md -->

> **Tip:** If you're deploying .NET or Java in an environment where you control the network (an Azure VM, AKS, App Service with VNet integration), stick with Direct mode. The latency improvement is real and consistent. Switch to Gateway only when network constraints force it.

### How Direct Mode Works Under the Hood

When the SDK opens in Direct mode, it first hits the gateway via HTTPS to fetch account metadata and a routing map — the physical partition layout and replica TCP addresses. That information is cached locally. From then on, data plane requests (reads, writes, queries) go directly to the correct replica over TCP.

Each physical partition has a replica set of four replicas (one primary, three secondaries). The SDK opens connections to all of them and load-balances reads across the set. Writes always target the primary replica. When replicas move (maintenance, scaling events), the SDK detects stale routes, refreshes from the gateway, and reconnects transparently.

<!-- Source: sdk-connection-modes.md -->

The result: in steady state, Direct mode produces fewer network hops per operation, which translates directly to lower latency. The cost is more TCP connections from your client, which matters if you have many physical partitions — the steady-state formula is roughly *4 connections × number of physical partitions*.

## Reading the RU Charge from Response Headers

Every operation against Cosmos DB returns the **request unit charge** — the cost of that specific request measured in RUs. This number is essential for understanding and optimizing your costs (Chapter 10 goes deep on RU mechanics). The SDKs make it easy to read.

**C# — from any `ItemResponse<T>` or `FeedResponse<T>`**
```csharp
ItemResponse<Product> response = await container.ReadItemAsync<Product>(
    id: "prod-1001",
    partitionKey: new PartitionKey("gear-surf-surfboards")
);
double ruCharge = response.RequestCharge;
```

For queries, the RU charge is per *page*, so you'll want to accumulate it across all pages:

```csharp
double totalRUs = 0;
using FeedIterator<Product> feed = container.GetItemQueryIterator<Product>(query);
while (feed.HasMoreResults)
{
    FeedResponse<Product> page = await feed.ReadNextAsync();
    totalRUs += page.RequestCharge;
}
Console.WriteLine($"Total query cost: {totalRUs} RUs");
```

<!-- Source: how-to-dotnet-read-item.md -->

**Python — from the response headers**
```python
response = container.read_item(item="prod-1001", partition_key="gear-surf-surfboards")
ru_charge = container.client_connection.last_response_headers["x-ms-request-charge"]
```

**JavaScript — from the response headers**
```javascript
const { resource, headers } = await container
    .item("prod-1001", "gear-surf-surfboards")
    .read();
const ruCharge = headers["x-ms-request-charge"];
```

The underlying HTTP header is `x-ms-request-charge`, and it's present on *every* response. Get in the habit of logging it during development — you'll catch expensive operations early, before they become expensive production surprises. Chapter 10 covers RU budgeting strategies and how to systematically track costs across your workload.

## Retry Policies and Handling Transient Errors

Distributed systems fail in interesting ways. Network blips, brief partition movements, throttling during traffic spikes — these are normal, not exceptional. The Cosmos DB SDKs have built-in retry logic for the most common transient errors, but you need to understand what they do (and don't do) so you can fill the gaps.

<!-- Source: conceptual-resilient-sdk-applications.md -->

### What the SDK Retries Automatically

| Status Code | Description | SDK Retries? | You Should Retry? |
|-------------|-------------|:------------:|:-----------------:|
| **408** | Request timeout | Yes (reads only)* | Yes |
| **410** | Gone (transient) | Yes | Yes |
| **429** | Too many requests (throttled) | Yes | Yes |
| **449** | Concurrent write conflict (transient) | Yes | Yes |
| **503** | Service unavailable | Yes (reads only)* | Yes |
| **409** | Conflict (duplicate `id`) | No | No |
| **412** | Precondition failed (ETag mismatch) | No | No |
| **413** | Request entity too large (item > 2 MB) | No | No |

<!-- Source: conceptual-resilient-sdk-applications.md -->

### HTTP 429: Rate Limiting

The most common retryable error is **429 Too Many Requests** — you've exceeded your provisioned RU/s for that partition. The SDK handles this automatically: it reads the `x-ms-retry-after-ms` header from the response, waits the indicated time, and retries.

By default, the .NET SDK retries up to **9 times** with a cumulative maximum wait of **30 seconds**. If retries are still failing after that, the SDK surfaces a `CosmosException` with status code 429 to your application code.

<!-- Source: performance-tips-dotnet-sdk-v3.md -->

A small percentage of 429s (1–5% of total requests) is actually healthy — it means you're efficiently utilizing your provisioned throughput. If the rate exceeds that, you have a throughput sizing problem (Chapter 11) or a hot partition problem (Chapter 5).

<!-- Source: troubleshoot-request-rate-too-large.md -->

> **Tip:** You can tune the retry behavior in .NET via `CosmosClientOptions`:
> ```csharp
> new CosmosClientOptions
> {
>     MaxRetryAttemptsOnRateLimitedRequests = 15,
>     MaxRetryWaitTimeOnRateLimitedRequests = TimeSpan.FromSeconds(60)
> }
> ```
> Increase these for batch workloads that can tolerate longer waits. For latency-sensitive paths, you might want to *decrease* them and shed load faster.

### Timeout and Connectivity Failures (408, 503)

Network timeouts and service unavailable errors are retried by the SDK automatically for **read operations**. For **write operations**, the SDK does *not* retry by default — because writes aren't idempotent. If a write timed out, the SDK can't know whether the server processed it before the connection dropped.

<!-- Source: conceptual-resilient-sdk-applications.md -->

This means your application needs its own retry logic for write timeouts. A common pattern:

1. Retry the write as an upsert (idempotent by design).
2. If you used a plain `Create`, the retry might get a 409 Conflict — that means the original write *did* succeed. Catch it and move on.

If your account has multiple regions, the SDKs also perform **cross-region retries** for transient failures — routing to a secondary region when the primary is temporarily unreachable. Chapter 21 covers advanced resilience patterns including the threshold-based availability strategy and partition-level circuit breaker in the .NET SDK.

### ETag Conflicts (412)

A 412 Precondition Failed means you attempted an optimistic concurrency update with an ETag that no longer matches the server's version — someone else modified the item since you read it. This is *not* retried by the SDK because it's a business-logic decision: you need to re-read the item, resolve the conflict, and try again. Chapter 16 covers optimistic concurrency in detail.

## LINQ to SQL: Querying Cosmos DB with .NET LINQ Expressions

If you're a .NET developer, the SDK offers something Python and JavaScript developers don't get: a **LINQ provider** that translates C# expressions into Cosmos DB SQL queries. You write strongly-typed lambda expressions; the SDK generates the query text and executes it.

<!-- Source: how-to-dotnet-query-items.md -->

```csharp
IOrderedQueryable<Product> queryable = container.GetItemLinqQueryable<Product>();

var matches = queryable
    .Where(p => p.quantity > 10)
    .Where(p => p.category == "gear-surf-surfboards")
    .OrderBy(p => p.price);

using FeedIterator<Product> feed = matches.ToFeedIterator();

while (feed.HasMoreResults)
{
    FeedResponse<Product> page = await feed.ReadNextAsync();
    foreach (Product item in page)
    {
        Console.WriteLine($"{item.name}: ${item.price}");
    }
}
```

<!-- Source: how-to-dotnet-query-items.md -->

A few things to know about LINQ with Cosmos DB:

**It's translated, not executed locally.** The LINQ expression tree is converted to a Cosmos DB SQL query string and sent to the server. You get the same query engine, the same indexing benefits, and the same RU charges as if you'd written the SQL by hand.

**Always call `ToFeedIterator()`.** The `IQueryable` you get from `GetItemLinqQueryable` supports `foreach` directly — but that path is **synchronous**. In production, convert to a `FeedIterator` and use `ReadNextAsync` for async paging. The performance tips documentation explicitly warns against using `ToList()` on a LINQ queryable because it blocks the calling thread.

<!-- Source: performance-tips-dotnet-sdk-v3.md -->

**Not every C# expression translates.** The LINQ provider supports the most common operations — `Where`, `Select`, `OrderBy`, `Take`, `Distinct`, aggregate functions — but complex method calls or custom functions may fail at translation time. If you hit a translation error, fall back to a raw SQL string query using `QueryDefinition`.

> **Tip:** During development, you can inspect the generated SQL by calling `matches.ToQueryDefinition().QueryText`. This is invaluable for debugging — you'll often discover that the generated SQL isn't what you expected, or that a slight LINQ refactor produces a more efficient query.

LINQ is a convenience, not a necessity. For complex queries — joins, subqueries, spatial functions — writing the SQL directly via `QueryDefinition` gives you full control. Chapter 8 covers the full query language.

## Putting It All Together: Per-Request Options

Most operations accept a request options object that lets you override defaults on a per-request basis. Here are the most useful overrides:

**Consistency level override (C#)**
```csharp
ItemResponse<Product> response = await container.ReadItemAsync<Product>(
    id: "prod-1001",
    partitionKey: new PartitionKey("gear-surf-surfboards"),
    requestOptions: new ItemRequestOptions
    {
        ConsistencyLevel = ConsistencyLevel.Eventual
    }
);
```

<!-- Source: how-to-manage-consistency.md -->

This lets you weaken consistency for a specific read without changing the account default. You can go from Strong to Eventual on a single request to get lower latency or reduced RU cost. You can only weaken — you can't strengthen beyond your account's default. Chapter 13 covers when and why you'd override consistency per request.

**Disable content response on writes (C#)**
```csharp
ItemResponse<Product> response = await container.CreateItemAsync(
    product,
    new PartitionKey(product.category),
    new ItemRequestOptions { EnableContentResponseOnWrite = false }
);
// response.Resource is null — but the write succeeded and cost fewer RUs
```

<!-- Source: performance-tips-dotnet-sdk-v3.md -->

When you already have the object you're writing, there's no reason to deserialize it from the response. Disabling the content response reduces network bandwidth and saves the SDK from allocating memory for serialization. The headers (including RU charge) are still available. This is a small but free optimization for write-heavy workloads.

## What's Next

You now have the complete toolkit for connecting to Cosmos DB and performing every fundamental operation. The patterns in this chapter — singleton clients, parameterized queries, point reads, RU tracking — are the foundation of every production Cosmos DB application.

Chapter 8 picks up where the querying section left off, diving into the full NoSQL query language: SQL syntax, joins within documents, aggregations, system functions, and cross-partition query mechanics. If you've been writing `SELECT * FROM c`, you'll learn to write much more targeted (and cheaper) queries.

For advanced SDK patterns — bulk operations, transactional batch, OpenTelemetry integration, custom retry strategies, and connection tuning — Chapter 21 is the follow-up. Everything here was about getting the fundamentals right; Chapter 21 is about squeezing every last drop of performance and observability out of the SDK.
