# Chapter 24: Testing Cosmos DB Applications

You wouldn't deploy a web API without tests. So why do so many Cosmos DB applications go to production with nothing but manual spot-checks against the cloud service? Usually it's because the team never figured out a clean way to isolate the database layer. The SDK's types feel too concrete to mock, the emulator feels too heavy to spin up in CI, and the change feed feels too asynchronous to assert against. All of those problems are solvable. This chapter gives you the patterns.

## Testing Philosophy: What to Unit Test vs. Integration Test

The fastest way to waste time writing Cosmos DB tests is to test the wrong thing at the wrong level. Here's the split that works.

**Unit tests** verify *your* logic — the code that decides what to write, how to transform a query result, or when to retry. They should never touch a real Cosmos DB endpoint (cloud or emulator). They run in milliseconds, require zero infrastructure, and belong in every pull request build.

**Integration tests** verify that your code talks to Cosmos DB correctly — that your queries return the right documents, your indexing policy supports the access patterns you expect, and your partition key strategy doesn't produce unexpected cross-partition queries. These need the emulator (or a dedicated test account) and are slower. Run them in CI, not on every keystroke.

**End-to-end tests** verify the full pipeline — a write hits Cosmos DB, the change feed fires, a downstream consumer processes the event, and the result lands where it should. These are the most expensive to maintain, so keep them focused on critical paths.

| Test type | What it proves | Infrastructure needed | Speed | When to run |
|-----------|---------------|----------------------|-------|-------------|
| **Unit** | Your business logic, transforms, retry decisions | None (mocks only) | Milliseconds | Every build |
| **Integration** | Queries, indexing, partition behavior, SDK wiring | Emulator or test account | Seconds | CI pipeline |
| **End-to-end** | Full pipeline (write → change feed → consumer) | Emulator + consumer runtime | Seconds to minutes | CI pipeline (nightly or per-PR) |

Don't unit-test the Cosmos DB SDK itself. You didn't write it, and Microsoft already tested it. Your unit tests should verify what *you* do with the data that comes back from the SDK.

## Unit Testing with a Mocked Cosmos DB Client

The Cosmos DB SDK's `CosmosClient`, `Container`, and `Database` classes are concrete types with internal constructors. You can't just `new` them up in a test. The solution is the same pattern you'd use for any external dependency: put an interface in front of it.

### Abstracting the SDK Behind a Repository Interface

Define a repository interface that describes the operations your application actually performs. Don't try to wrap every SDK method — wrap only the ones you use.

```csharp
public interface IOrderRepository
{
    Task<Order?> GetByIdAsync(string orderId, string customerId);
    Task<IReadOnlyList<Order>> GetByCustomerAsync(string customerId);
    Task UpsertAsync(Order order);
    Task DeleteAsync(string orderId, string customerId);
}
```

Your production implementation talks to Cosmos DB:

```csharp
public class CosmosOrderRepository : IOrderRepository
{
    private readonly Container _container;

    public CosmosOrderRepository(Container container)
    {
        _container = container;
    }

    public async Task<Order?> GetByIdAsync(string orderId, string customerId)
    {
        try
        {
            var response = await _container.ReadItemAsync<Order>(
                orderId, new PartitionKey(customerId));
            return response.Resource;
        }
        catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.NotFound)
        {
            return null;
        }
    }

    public async Task<IReadOnlyList<Order>> GetByCustomerAsync(string customerId)
    {
        var query = new QueryDefinition(
            "SELECT * FROM c WHERE c.customerId = @cid")
            .WithParameter("@cid", customerId);

        var results = new List<Order>();
        using var iterator = _container.GetItemQueryIterator<Order>(
            query, requestOptions: new QueryRequestOptions
            {
                PartitionKey = new PartitionKey(customerId)
            });

        while (iterator.HasMoreResults)
        {
            var batch = await iterator.ReadNextAsync();
            results.AddRange(batch);
        }

        return results;
    }

    public async Task UpsertAsync(Order order)
    {
        await _container.UpsertItemAsync(order,
            new PartitionKey(order.CustomerId));
    }

    public async Task DeleteAsync(string orderId, string customerId)
    {
        await _container.DeleteItemAsync<Order>(
            orderId, new PartitionKey(customerId));
    }
}
```

Your service layer depends on `IOrderRepository`, not on `Container`. That one level of indirection makes everything testable.

### Mocking CosmosClient, Container, and FeedIterator

When you're testing code that consumes your repository interface, mocking is trivial — just mock `IOrderRepository`. But what about testing the repository *implementation* itself? Or code that works directly with the SDK?

The SDK's `Container` methods are virtual, so mocking frameworks like Moq can intercept them. The tricky part is `FeedIterator<T>`, which is the type returned by `GetItemQueryIterator`. Here's how to mock a query that returns results:

```csharp
[Fact]
public async Task GetByCustomer_ReturnsMatchingOrders()
{
    // Arrange: build a fake FeedResponse and FeedIterator
    var expectedOrders = new List<Order>
    {
        new Order { Id = "ord-1", CustomerId = "cust-42", Total = 99.99m },
        new Order { Id = "ord-2", CustomerId = "cust-42", Total = 45.00m }
    };

    var feedResponse = Mock.Of<FeedResponse<Order>>(r =>
        r.GetEnumerator() == expectedOrders.GetEnumerator() &&
        r.Count == expectedOrders.Count);

    var feedIterator = Mock.Of<FeedIterator<Order>>();
    var hasCalledOnce = false;
    Mock.Get(feedIterator)
        .Setup(i => i.HasMoreResults)
        .Returns(() =>
        {
            if (!hasCalledOnce) { hasCalledOnce = true; return true; }
            return false;
        });
    Mock.Get(feedIterator)
        .Setup(i => i.ReadNextAsync(It.IsAny<CancellationToken>()))
        .ReturnsAsync(feedResponse);

    var container = Mock.Of<Container>();
    Mock.Get(container)
        .Setup(c => c.GetItemQueryIterator<Order>(
            It.IsAny<QueryDefinition>(),
            It.IsAny<string>(),
            It.IsAny<QueryRequestOptions>()))
        .Returns(feedIterator);

    var repo = new CosmosOrderRepository(container);

    // Act
    var orders = await repo.GetByCustomerAsync("cust-42");

    // Assert
    Assert.Equal(2, orders.Count);
    Assert.All(orders, o => Assert.Equal("cust-42", o.CustomerId));
}
```

Yes, mocking `FeedIterator<T>` is verbose. That's the cost of the SDK's pagination model — and it's exactly why the repository abstraction pays for itself. Once you've tested your repository implementation with a few mocked-iterator tests, everything above it mocks the clean interface instead.

**Python and JavaScript** don't have the same virtual-method constraint. In Python, you can monkey-patch the `ContainerProxy` methods or use `unittest.mock.AsyncMock`. In JavaScript, any mocking library (Jest, Sinon) can stub the container's methods directly since there's no type system to fight.

```python
# Python: mocking a point read with unittest.mock
import pytest
from unittest.mock import AsyncMock, MagicMock

@pytest.mark.asyncio
async def test_get_order_by_id():
    mock_container = MagicMock()
    mock_container.read_item = AsyncMock(return_value={
        "id": "ord-1",
        "customerId": "cust-42",
        "total": 99.99
    })

    repo = OrderRepository(mock_container)
    order = await repo.get_by_id("ord-1", "cust-42")

    assert order["id"] == "ord-1"
    mock_container.read_item.assert_called_once_with(
        item="ord-1",
        partition_key="cust-42"
    )
```

```javascript
// JavaScript (Jest): mocking a query
const container = {
  items: {
    query: jest.fn().mockReturnValue({
      fetchAll: jest.fn().mockResolvedValue({
        resources: [
          { id: "ord-1", customerId: "cust-42", total: 99.99 },
          { id: "ord-2", customerId: "cust-42", total: 45.00 }
        ]
      })
    })
  }
};

test("getByCustomer returns matching orders", async () => {
  const repo = new OrderRepository(container);
  const orders = await repo.getByCustomer("cust-42");

  expect(orders).toHaveLength(2);
  expect(container.items.query).toHaveBeenCalled();
});
```

## Integration Testing with the Cosmos DB Emulator

Unit tests with mocks prove your logic works. Integration tests prove your logic works *against a real Cosmos DB engine*. The emulator gives you that engine without cloud costs or network variability.

Chapter 3 covers emulator installation and configuration in detail. This section focuses on how to use the emulator effectively in test workflows and CI pipelines.

### Windows Emulator vs. Linux-Based vNext Docker Image

Two emulators exist, and the choice affects your test setup.

| Aspect | Windows (local) emulator | vNext Docker emulator (preview) |
|--------|--------------------------|----------------------------------|
| **Platform** | Windows only | Any OS with Docker |
| **Image** | MSI installer | `mcr.microsoft.com/cosmosdb/linux/azure-cosmos-emulator:vnext-preview` |
| **API support** | NoSQL, MongoDB, Cassandra, Gremlin, Table | NoSQL only (gateway mode) |
| **Stored procedures / triggers / UDFs** | Supported | Not planned |
| **Custom index policies** | Supported | Not yet implemented |
| **RU reporting** | Approximate | Not yet implemented |
| **Change feed** | Supported | Supported |
| **CI-friendly** | Requires Windows runners | Runs on any Linux/Docker CI runner |
| **Default protocol** | HTTPS | HTTP (must pass `--protocol https` for .NET/Java SDKs) |

<!-- Source: emulator.md, emulator-linux.md -->

For CI pipelines, the vNext Docker image is the clear winner — it starts faster, runs anywhere Docker runs, and GitHub Actions can manage its lifecycle as a service container. For local development on Windows when you need stored procedures or custom indexing policies, the Windows emulator is still necessary.

### Configuring the Emulator for CI (Docker Image)

The vNext Docker emulator slots into GitHub Actions as a service container. GitHub starts it before your job, your tests hit `localhost:8081` with the well-known key, and GitHub tears it down when the job completes. <!-- Source: emulator-linux.md -->

```yaml
name: Integration Tests

on: [push, pull_request]

jobs:
  integration-tests:
    runs-on: ubuntu-latest

    services:
      cosmosdb:
        image: mcr.microsoft.com/cosmosdb/linux/azure-cosmos-emulator:vnext-preview
        ports:
          - 8081:8081
        env:
          PROTOCOL: https

    steps:
      - uses: actions/checkout@v4

      - name: Setup .NET
        uses: actions/setup-dotnet@v4
        with:
          dotnet-version: '8.0.x'

      - name: Run integration tests
        env:
          COSMOS_ENDPOINT: https://localhost:8081
          COSMOS_KEY: "C2y6yDjf5/R+ob0N8A7Cgv30VRDJIWEHLM+4QDU5DE2nQ9nDuVTqobD4b8mGGyPMbIZnqyMsEcaGQy67XIw/Jw=="
        run: dotnet test --filter Category=Integration
```

<!-- Source: emulator-linux.md, emulator.md -->

A few CI-specific tips:

**Disable TLS validation in test code** (or import the emulator's self-signed certificate). The emulator's HTTPS certificate isn't trusted by default. How you handle this depends on your language ecosystem: <!-- Source: emulator-linux.md -->

- **.NET** — Set `CosmosClientOptions.HttpClientFactory` to supply an `HttpClient` that ignores certificate errors.
- **Java** — Export the emulator's certificate and import it into the Java keystore (the GitHub Actions example in the emulator docs shows exactly how).
- **Python** — Configure `REQUESTS_CA_BUNDLE` to point to the exported certificate, or adjust your SSL context to trust it.
- **Node.js** — Set the environment variable `NODE_TLS_REJECT_UNAUTHORIZED=0` for test runs.

**Keep the connection string in environment variables**, not in test code. This makes it trivial to swap between the emulator and a real account for different CI stages.

**Azure DevOps pipelines** follow the same pattern — use a Docker container resource or a `docker run` step before your test task.

### Seeding and Tearing Down Test Data Between Runs

Integration tests need predictable data. Here's the pattern that works reliably:

1. **Before each test class** (or test suite): create a fresh database and container with a unique name (e.g., `test-{guid}`). This guarantees isolation between parallel test runs.
2. **Before each test**: seed the exact documents your test needs.
3. **After each test class**: delete the database.

```csharp
public class OrderIntegrationTests : IAsyncLifetime
{
    private CosmosClient _client = null!;
    private Database _database = null!;
    private Container _container = null!;
    private readonly string _databaseName = $"test-{Guid.NewGuid():N}";

    public async Task InitializeAsync()
    {
        _client = new CosmosClient(
            Environment.GetEnvironmentVariable("COSMOS_ENDPOINT")!,
            Environment.GetEnvironmentVariable("COSMOS_KEY")!,
            new CosmosClientOptions
            {
                HttpClientFactory = () =>
                {
                    var handler = new HttpClientHandler
                    {
                        ServerCertificateCustomValidationCallback =
                            HttpClientHandler.DangerousAcceptAnyServerCertificateValidator
                    };
                    return new HttpClient(handler);
                },
                ConnectionMode = ConnectionMode.Gateway
            });

        _database = (await _client.CreateDatabaseAsync(_databaseName)).Database;
        _container = (await _database.CreateContainerAsync(
            "orders", "/customerId", 400)).Container;
    }

    public async Task DisposeAsync()
    {
        await _database.DeleteAsync();
        _client.Dispose();
    }

    [Fact]
    public async Task UpsertAndRead_RoundTrips()
    {
        var order = new Order
        {
            Id = "ord-1",
            CustomerId = "cust-42",
            Total = 99.99m
        };

        await _container.UpsertItemAsync(order,
            new PartitionKey(order.CustomerId));

        var response = await _container.ReadItemAsync<Order>(
            "ord-1", new PartitionKey("cust-42"));

        Assert.Equal(99.99m, response.Resource.Total);
    }
}
```

The `test-{guid}` database name is the key trick. It means two CI jobs running in parallel against the same emulator (or the same shared test account) won't collide. The disposal step cleans up after itself so you don't accumulate orphaned databases.

In Python, use `pytest` fixtures with `autouse` or session scope:

```python
import pytest
import uuid
from azure.cosmos.aio import CosmosClient

@pytest.fixture(scope="module")
async def cosmos_container():
    client = CosmosClient(
        url=os.environ["COSMOS_ENDPOINT"],
        credential=os.environ["COSMOS_KEY"]
    )
    db_name = f"test-{uuid.uuid4().hex}"
    database = await client.create_database(db_name)
    container = await database.create_container(
        id="orders",
        partition_key={"paths": ["/customerId"]},
        offer_throughput=400
    )
    yield container
    await client.delete_database(db_name)
    await client.close()
```

### Verifying Indexing Policy Behavior in Tests

If you've tuned your indexing policy (Chapter 9), integration tests should verify that queries relying on those indexes actually work. The Windows emulator supports custom indexing policies; the vNext emulator does not yet support them as of this writing. <!-- Source: emulator-linux.md -->

For the Windows emulator (or the cloud), create the container with your production indexing policy and then assert that your queries succeed without excessive RU charges:

```csharp
[Fact]
public async Task RangeQuery_UsesCompositeIndex()
{
    // Create container with production indexing policy
    var containerProps = new ContainerProperties("orders-indexed", "/customerId")
    {
        IndexingPolicy = new IndexingPolicy
        {
            CompositeIndexes =
            {
                new Collection<CompositePath>
                {
                    new CompositePath
                        { Path = "/customerId", Order = CompositePathSortOrder.Ascending },
                    new CompositePath
                        { Path = "/orderDate", Order = CompositePathSortOrder.Descending }
                }
            }
        }
    };

    var container = (await _database.CreateContainerAsync(containerProps, 400)).Container;

    // Seed data
    for (int i = 0; i < 10; i++)
    {
        await container.UpsertItemAsync(new
        {
            id = $"ord-{i}",
            customerId = "cust-42",
            orderDate = DateTime.UtcNow.AddDays(-i),
            total = 10.00m * i
        }, new PartitionKey("cust-42"));
    }

    // Query with ORDER BY matching the composite index
    var query = new QueryDefinition(
        "SELECT * FROM c WHERE c.customerId = @cid ORDER BY c.orderDate DESC")
        .WithParameter("@cid", "cust-42");

    var options = new QueryRequestOptions { PartitionKey = new PartitionKey("cust-42") };
    double totalRUs = 0;

    using var iterator = container.GetItemQueryIterator<dynamic>(query, requestOptions: options);
    var results = new List<dynamic>();
    while (iterator.HasMoreResults)
    {
        var response = await iterator.ReadNextAsync();
        totalRUs += response.RequestCharge;
        results.AddRange(response);
    }

    Assert.Equal(10, results.Count);
    // Composite index should keep RU cost low for sorted queries
    Assert.True(totalRUs < 10, $"Expected < 10 RUs but got {totalRUs:F2}");
}
```

The RU assertion is a sanity check, not a precise benchmark — emulator RU charges are approximate. The real value is proving the query *runs* against your indexing policy without errors. If you accidentally exclude a path that a query depends on, the query will either fail or produce an unexpected scan. Your integration test catches that before production does.

## End-to-End Testing Strategies for Change Feed Consumers

The change feed processor is covered in depth in Chapter 15 — here we focus on how to test it.

Change feed consumers are asynchronous by nature — a write happens, then *eventually* a consumer processes it. That "eventually" makes testing awkward. Here's a pattern that tames it.

The trick is to use the change feed processor's own SDK in your test, with a `TaskCompletionSource` (or equivalent) as the signal that processing occurred.

```csharp
[Fact]
public async Task ChangeFeed_ProcessesNewOrders()
{
    // Arrange: seed a lease container
    var leaseContainer = (await _database.CreateContainerAsync(
        $"leases-{Guid.NewGuid():N}", "/id", 400)).Container;

    var processedOrders = new ConcurrentBag<Order>();
    var allProcessed = new TaskCompletionSource<bool>();
    int expectedCount = 3;

    // Build a change feed processor that captures processed items
    var processor = _container
        .GetChangeFeedProcessorBuilder<Order>(
            "test-processor",
            async (context, changes, ct) =>
            {
                foreach (var order in changes)
                    processedOrders.Add(order);

                if (processedOrders.Count >= expectedCount)
                    allProcessed.TrySetResult(true);
            })
        .WithInstanceName("test-instance")
        .WithLeaseContainer(leaseContainer)
        .WithStartTime(DateTime.UtcNow)
        .Build();

    await processor.StartAsync();

    // Act: insert documents
    for (int i = 0; i < expectedCount; i++)
    {
        await _container.UpsertItemAsync(
            new Order
            {
                Id = $"cf-ord-{i}",
                CustomerId = "cust-99",
                Total = 10.00m * i
            },
            new PartitionKey("cust-99"));
    }

    // Wait for the change feed to deliver, with a timeout
    var completed = await Task.WhenAny(
        allProcessed.Task,
        Task.Delay(TimeSpan.FromSeconds(30)));

    await processor.StopAsync();

    // Assert
    Assert.True(allProcessed.Task.IsCompletedSuccessfully,
        $"Change feed only delivered {processedOrders.Count}/{expectedCount} items within timeout.");
    Assert.Equal(expectedCount, processedOrders.Count);
}
```

The key elements:

- **`WithStartTime(DateTime.UtcNow)`** tells the processor to only read changes from now forward, ignoring any leftover data from previous tests.
- **`TaskCompletionSource` with a timeout** gives you a clean pass/fail without sleeping for arbitrary durations.
- **`ConcurrentBag`** handles the thread-safety of the delegate being called from multiple threads.

The same pattern works in Python and JavaScript — replace `TaskCompletionSource` with `asyncio.Event` in Python or a `Promise` wrapper in JavaScript.

One caveat: the change feed processor's poll interval defaults to a few seconds. In tests against the emulator, you might wait 5–10 seconds for the first batch to arrive. That's normal — don't set your timeout lower than 15–20 seconds or you'll get flaky failures.

## Testing Throughput and Partition Key Distribution with Load Tools

Integration tests prove correctness. Load tests prove your data model holds up under pressure. Two areas matter most: throughput consumption and partition key distribution.

### Verifying Partition Key Distribution

A bad partition key creates hot partitions that throttle under load (Chapter 5 covers the theory). You can validate distribution in a test by writing a representative dataset and checking the spread.

```csharp
[Fact]
public async Task PartitionKey_DistributesEvenly()
{
    // Seed 1,000 documents with realistic partition key values
    var random = new Random(42); // deterministic seed for reproducibility
    var customerIds = Enumerable.Range(1, 50)
        .Select(i => $"cust-{i}").ToArray();

    for (int i = 0; i < 1000; i++)
    {
        var customerId = customerIds[random.Next(customerIds.Length)];
        await _container.UpsertItemAsync(new
        {
            id = $"load-{i}",
            customerId,
            amount = random.NextDouble() * 100
        }, new PartitionKey(customerId));
    }

    // Query the count per partition key value
    var query = new QueryDefinition(
        "SELECT c.customerId, COUNT(1) AS cnt FROM c GROUP BY c.customerId");

    using var iterator = _container.GetItemQueryIterator<dynamic>(query);
    var distribution = new Dictionary<string, int>();
    while (iterator.HasMoreResults)
    {
        var batch = await iterator.ReadNextAsync();
        foreach (var item in batch)
        {
            distribution[(string)item.customerId] = (int)item.cnt;
        }
    }

    // Assert: no single partition key holds more than 5% of total documents
    int maxCount = distribution.Values.Max();
    Assert.True(maxCount <= 50,
        $"Hottest partition key has {maxCount} docs — distribution is too skewed.");
}
```

This isn't a substitute for monitoring in production (Chapter 18), but it catches obviously bad partition key choices during development.

### Load Testing with the Benchmarking Tool

For throughput testing against the *cloud service* (not the emulator — the emulator doesn't accurately reflect production throughput limits), use a dedicated load testing tool. Microsoft's `azure-cosmos-dotnet-v3` repo includes a benchmarking tool, and tools like `k6`, `Locust`, or `NBomber` work well for custom scenarios.

The pattern: write a load test that simulates your production read/write mix, run it against a test account with production-equivalent throughput, and measure:

- **RU consumption per operation** — are your queries costing what you expect?
- **429 (throttling) rate** — are you hitting partition-level throughput limits?
- **P99 latency** — does it stay within your SLA requirements?

Keep load tests separate from your regular CI pipeline. They require provisioned throughput, take minutes to run, and cost real money. Run them before major releases or after significant data model changes.

## Common Testing Pitfalls

### Singleton Client Leaks in Tests

The Cosmos DB SDK best practices are explicit: use a single `CosmosClient` instance for the lifetime of your application. Each `CosmosClient` manages its own connection pool — HTTP connections in gateway mode, TCP connections in direct mode. Creating a new client per test (or worse, per test method) burns through connections and causes port exhaustion. <!-- Source: best-practice-dotnet.md, conceptual-resilient-sdk-applications.md -->

In test suites, create the `CosmosClient` once per test class (or per test session) and share it across tests. In xUnit, use `IAsyncLifetime` on a collection fixture. In NUnit, use `[OneTimeSetUp]`. In pytest, use a session-scoped fixture.

```csharp
// BAD: new client per test
[Fact]
public async Task SomeTest()
{
    using var client = new CosmosClient(endpoint, key); // DON'T
    // ...
}

// GOOD: shared client via fixture
public class CosmosFixture : IAsyncLifetime
{
    public CosmosClient Client { get; private set; } = null!;

    public Task InitializeAsync()
    {
        Client = new CosmosClient(
            Environment.GetEnvironmentVariable("COSMOS_ENDPOINT")!,
            Environment.GetEnvironmentVariable("COSMOS_KEY")!,
            new CosmosClientOptions { ConnectionMode = ConnectionMode.Gateway });
        return Task.CompletedTask;
    }

    public Task DisposeAsync()
    {
        Client.Dispose();
        return Task.CompletedTask;
    }
}

[CollectionDefinition("Cosmos")]
public class CosmosCollection : ICollectionFixture<CosmosFixture> { }

[Collection("Cosmos")]
public class OrderIntegrationTests
{
    private readonly CosmosClient _client;

    public OrderIntegrationTests(CosmosFixture fixture)
    {
        _client = fixture.Client;
    }

    // Tests use _client...
}
```

### Emulator Cold-Start Latency

The vNext Docker emulator's gateway endpoint is typically available immediately according to the docs. In our experience, though, the first request can still take a few seconds while internal components finish initializing. A readiness check is still good practice — if your CI test runner starts executing tests the instant the container is "healthy," the first test may time out. <!-- Source: emulator-linux.md -->

Fix this with a readiness check before running tests:

```bash
# Wait for the emulator to respond (GitHub Actions step)
- name: Wait for Cosmos DB Emulator
  run: |
    for i in $(seq 1 30); do
      curl -sk https://localhost:8081/ && break || sleep 2
    done
```

Or in code, add a retry loop in your test fixture's initialization:

```csharp
public async Task InitializeAsync()
{
    _client = new CosmosClient(/* ... */);

    // Retry until the emulator is ready
    for (int i = 0; i < 15; i++)
    {
        try
        {
            await _client.ReadAccountAsync();
            break;
        }
        catch (Exception) when (i < 14)
        {
            await Task.Delay(2000);
        }
    }

    // Now create the database...
}
```

### Testing Against the Emulator vs. the Cloud

The emulator is a development tool, not a miniature Cosmos DB. As the comparison table earlier in this chapter shows, the two emulator variants differ in API coverage, protocol defaults, and feature completeness — and *neither* fully replicates the cloud service. Here's what that means for your test strategy:

- **Consistency and geo-replication** can't be meaningfully tested on a single-instance emulator. If your application relies on Bounded Staleness, Consistent Prefix, or multi-region failover, those tests need a cloud account. <!-- Source: emulator.md -->
- **RU-based assertions are unreliable.** Emulator RU numbers are approximate at best (Windows) or not yet implemented (vNext). Don't gate CI on exact RU costs. <!-- Source: emulator.md, emulator-linux.md -->
- **Throughput throttling isn't representative.** In our practical experience, the emulator is not designed to replicate production throughput constraints — this isn't documented behavior, but load testing should always happen against a real account.
- **Server-side execution** (stored procedures, triggers, UDFs) is not planned for the vNext emulator, so test those paths with the Windows emulator or a cloud account. <!-- Source: emulator-linux.md -->

The practical strategy: run correctness tests (queries, CRUD, change feed) against the emulator in CI. Run performance tests, consistency tests, and failover tests against a dedicated cloud account in a separate pipeline stage.

### Forgetting to Dispose the FeedIterator

In .NET, `FeedIterator<T>` implements `IDisposable`. If you iterate through query results without a `using` block, you leak HTTP connections. In unit tests this might not matter, but in integration tests that run hundreds of queries, it causes timeouts and socket exhaustion.

```csharp
// Always wrap FeedIterator in a using block
using var iterator = container.GetItemQueryIterator<Order>(query);
while (iterator.HasMoreResults)
{
    var batch = await iterator.ReadNextAsync();
    // ...
}
```

### Non-Deterministic Test Data

If your test seeds random data without a fixed seed, you'll get flaky failures that can't be reproduced. Always use a deterministic seed (`new Random(42)`) or static test data. Your future self, debugging a CI failure at 11 PM, will thank you.

With these patterns in place, you've got a testing strategy that covers the full spectrum — from fast, isolated unit tests to change-feed-aware end-to-end tests — without requiring a cloud account for every build. Chapter 25 shifts gears to a different kind of search: vector embeddings and building AI-powered applications on top of Cosmos DB.
