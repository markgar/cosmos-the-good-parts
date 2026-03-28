# Chapter 12: Consistency Levels

Every distributed database forces you to make a trade-off. You can have data that is always perfectly up to date, or data that is blazing fast to read — but getting both at once is physically impossible when your data lives in multiple regions separated by the speed of light. Most systems hand you two options: strong or eventual. Azure Cosmos DB gives you five.

This chapter walks through those five consistency levels, explains what each one actually guarantees (and what it doesn't), and helps you pick the right one for your workload. You'll learn how consistency affects your RU bill, how to override it per request, and how the whole model behaves when you turn on multi-region writes.

## The Consistency Spectrum

Traditional relational databases give you strong consistency: every read returns the most recent write, full stop. That works beautifully when your database lives on a single server. But the moment you replicate data across regions — say, from East US to Southeast Asia — physics intervenes. A write committed in Virginia takes real, measurable time to propagate to Singapore. During that window, what should a reader in Singapore see?

Strong consistency says "wait until the write arrives." The reader gets correct data, but at the cost of latency. Eventual consistency says "return whatever we have right now." The reader gets an answer fast, but it might be stale.

Most real-world applications don't need either extreme. A social media feed can tolerate a few seconds of staleness, but a financial ledger cannot. Azure Cosmos DB acknowledges this reality with a spectrum of five consistency levels, each offering a different balance of correctness, latency, throughput, and availability:

**Strong → Bounded Staleness → Session → Consistent Prefix → Eventual**

Moving left to right, you trade read consistency for lower latency, higher throughput, and better availability. The key insight is that you set a *default* consistency level on your account, but you can *relax* it on individual requests — giving you fine-grained control without managing multiple database accounts.

## The Five Consistency Levels Explained

### Strong

Strong consistency provides linearizability — the gold standard. Every read is guaranteed to return the most recently committed version of an item. There is no window of staleness, no stale replicas, no ambiguity.

How does Cosmos DB pull this off across regions? Writes must be replicated and acknowledged by a *global majority* of replicas before they're considered committed. Reads consult a *local minority* quorum (two out of four replicas in the local region) to guarantee they see the latest committed data.

The trade-offs are real:

- **Write latency** increases because every write must round-trip to remote regions before acknowledgment.
- **Read cost** doubles — strong and bounded staleness reads consume roughly 2× the RUs of weaker levels because they read from two replicas instead of one.
- **Availability** decreases. If more than half your regions go down, the quorum can't be reached and writes fail. For accounts with only two regions, losing one region impacts *both* reads and writes.
- **Multi-region writes are not supported.** You cannot enable strong consistency on an account configured for multiple write regions, because a distributed system cannot simultaneously provide zero RPO (recovery point objective) and zero RTO (recovery time objective).

**When to use it:** Financial transactions, inventory systems where overselling is unacceptable, or any scenario where correctness is more important than speed.

### Bounded Staleness

Bounded staleness is "strong consistency with a controlled lag." You configure two bounds, and the system guarantees that reads in any *secondary* region lag behind writes by at most:

- **K** versions (updates) of an item, *or*
- **T** seconds

…whichever threshold is reached first.

The defaults depend on your account topology:

| Account type | Minimum K (versions) | Minimum T (seconds) |
|---|---|---|
| Single-region | 10 | 5 |
| Multi-region | 100,000 | 300 |

Within the *write region itself*, bounded staleness behaves identically to strong consistency — reads are served from a minority quorum (two out of four replicas) and always return the latest data. The staleness bounds apply only to cross-region replication lag.

An important subtlety: staleness checks are made *only across regions*, not within a region. Inside a given region, data is always replicated to a local majority (three replicas in a four-replica set) regardless of your consistency level.

If the replication lag for a physical partition exceeds the configured staleness window, Cosmos DB *throttles writes* on that partition until the secondary regions catch up. This is how bounded staleness enforces its guarantee — it slows down the source rather than serving stale data.

Like strong consistency, reads are served from two replicas, so **read RU cost is approximately 2× that of weaker levels.**

**When to use it:** Applications requiring near-strong consistency across regions but with a single write region — for example, a global e-commerce catalog where product prices must converge within a known time window. Avoid it with multi-region writes; that's an anti-pattern because the staleness guarantee depends on cross-region replication lag, which shouldn't matter when reads and writes happen in the same region.

### Session

Session consistency is the **default** level for new Cosmos DB accounts, and for good reason: it gives most applications exactly the guarantees they need without the cost of stronger levels.

Within a single client session, you get:

- **Read-your-own-writes:** If you write a value and immediately read it back, you see your write.
- **Monotonic reads:** Once you read version N, you never see a version older than N.
- **Write-follows-reads:** Your writes are ordered after your reads within the session.

These guarantees are tracked through *session tokens*. Every write operation returns an updated session token, and every subsequent read sends that token to the server. The server ensures it returns data at least as fresh as the token specifies. If the local replica doesn't yet have that version, the request is routed to another replica (or even another region) that does.

Session tokens are partition-bound — each token is associated with a specific logical partition. The SDK manages them automatically; you don't need to think about them unless you're sharing sessions across multiple client instances (for example, behind a load balancer). In that case, you extract the session token from the response headers and pass it to subsequent requests manually.

Outside the session — for other clients who haven't received the session token — there's no consistency guarantee beyond eventual.

**When to use it:** The vast majority of applications. User-facing web apps, mobile backends, and microservices where each user's experience should be self-consistent.

### Consistent Prefix

Consistent prefix guarantees that you never see writes out of order. If the write sequence is A, B, C, you might read A, or A then B, or A then B then C — but never A then C (skipping B), and never C then A.

This level doesn't promise *how far behind* you might be (that's bounded staleness's job), only that what you do see respects the original write order.

Writes use a local majority quorum, and reads are served from a single replica, giving you the lower RU cost of the weaker consistency levels.

**When to use it:** Applications where ordering matters but lag is acceptable — activity feeds, event logs, or replication of state machines where processing events out of order would corrupt state.

### Eventual

Eventual consistency is the weakest level and offers no ordering guarantees. Reads may return data from any replica, in any order. Over time, in the absence of further writes, all replicas converge to the same value — but "over time" could mean milliseconds or seconds depending on replication lag.

The upside is maximum throughput and minimum latency. Reads hit a single replica and never wait for quorum.

In practice, most reads under eventual consistency are strongly consistent anyway. Azure Cosmos DB exposes a **Probabilistically Bounded Staleness (PBS)** metric in the Azure portal that shows the probability of getting a strongly consistent read for your actual workload. For many workloads, PBS shows that 99%+ of reads under eventual consistency already return the latest data.

**When to use it:** High-throughput, latency-sensitive workloads where occasional stale reads are acceptable — page view counters, "likes," IoT telemetry aggregation, or caching layers.

## Comparison Table

| Level | Read Guarantee | Read RU Cost | Write Quorum | Read Replicas | Availability | Typical Use Case |
|---|---|---|---|---|---|---|
| **Strong** | Linearizable — always latest write | ~2× base | Global majority | Local minority (2) | Lowest (quorum required globally) | Financial ledgers, inventory |
| **Bounded Staleness** | Lag ≤ K versions or T seconds | ~2× base | Local majority | Local minority (2) | Reduced during regional outages | Global catalogs, near-strong reads |
| **Session** (default) | Read-your-writes within session | 1× base | Local majority | Single replica + session token | High | Web/mobile apps, user-facing APIs |
| **Consistent Prefix** | No out-of-order reads | 1× base | Local majority | Single replica | High | Activity feeds, event streams |
| **Eventual** | No guarantees (converges over time) | 1× base | Local majority | Single replica | Highest | Counters, telemetry, caching |

## Choosing the Right Consistency for Your Workload

Start with session consistency. It's the default for a reason — it handles the "read what you just wrote" pattern that dominates most application interactions, and it does so at the lowest read RU cost.

Escalate to **bounded staleness** when you need cross-client consistency guarantees in a single-write-region account — for example, when multiple microservices read the same data and all need to agree within a known time window.

Escalate to **strong** only when correctness is non-negotiable and you accept the latency and availability trade-offs. Remember, strong consistency is incompatible with multi-region writes.

Relax to **consistent prefix** when you need ordering but can tolerate lag — event-sourced systems and audit logs are natural fits.

Relax to **eventual** for truly fire-and-forget reads where speed is king.

## Consistency and Its Impact on RU Cost and Latency

The RU impact is straightforward:

- **Strong and bounded staleness** reads cost approximately **2× the RUs** of weaker levels because they consult two replicas (a local minority quorum) to guarantee consistency.
- **Session, consistent prefix, and eventual** reads hit a single replica and incur the base read cost.
- **Write RU cost is the same regardless of consistency level.** What changes is where replicas acknowledge the write. Strong consistency waits for a global majority; all others commit to a local majority (three out of four replicas in the local region) and replicate asynchronously.

For latency:

- **Strong consistency** adds write latency proportional to the round-trip time to your farthest region because every write must be acknowledged globally before returning.
- **Bounded staleness** doesn't add write latency (local majority writes), but it can throttle writes if secondary regions fall behind the staleness window.
- **Session and below** offer the lowest latency: local majority writes, single-replica reads.

The practical takeaway: if you're running a multi-region account and your reads are costing more RUs than expected, check whether your consistency level is strong or bounded staleness. Dropping to session consistency can cut read costs in half.

## Per-Request Consistency Override

Cosmos DB lets you set a default consistency level on your account and then *relax* it on individual requests. You can go weaker per request — but not stronger. To move from a weaker default to a stronger level, you must change the account setting.

> **Important:** Overriding consistency only affects reads. An account configured for strong consistency still writes and replicates synchronously to every region, regardless of what the SDK request specifies.

Here's how to override consistency on a point read using the .NET SDK v3:

```csharp
using Microsoft.Azure.Cosmos;

// Your CosmosClient is configured with the account's default consistency
CosmosClient client = new CosmosClient(endpoint, key);
Container container = client.GetContainer("inventory-db", "products");

// Override to Eventual for a non-critical read (e.g., displaying a product catalog)
ItemRequestOptions options = new ItemRequestOptions
{
    ConsistencyLevel = ConsistencyLevel.Eventual
};

ItemResponse<Product> response = await container.ReadItemAsync<Product>(
    id: "product-42",
    partitionKey: new PartitionKey("electronics"),
    requestOptions: options
);

Product product = response.Resource;
double ruCharge = response.RequestCharge; // Lower RU cost than a Strong read
```

You can also override consistency on queries:

```csharp
QueryRequestOptions queryOptions = new QueryRequestOptions
{
    ConsistencyLevel = ConsistencyLevel.Eventual
};

using FeedIterator<Product> feed = container.GetItemQueryIterator<Product>(
    queryText: "SELECT * FROM c WHERE c.category = 'electronics'",
    requestOptions: queryOptions
);

while (feed.HasMoreResults)
{
    FeedResponse<Product> page = await feed.ReadNextAsync();
    foreach (Product item in page)
    {
        // Process each product
    }
}
```

This pattern is powerful for applications that need strong consistency for some operations (order placement) but can tolerate eventual consistency for others (browsing the catalog). You pay the higher RU cost only where you need it.

## Designing Resilient SDK Applications

Choosing the right consistency level is only half the story. Your application also needs to handle transient failures gracefully, because in a distributed system, *something* is always going wrong somewhere.

### Retry Strategies

The Cosmos DB SDKs have built-in retry logic for transient errors. The most common retryable scenarios:

| Status Code | Meaning | SDK Retries Automatically? |
|---|---|---|
| 408 | Request timeout | Yes |
| 429 | Rate limited (too many RUs) | Yes, after `x-ms-retry-after-ms` delay |
| 449 | Concurrent write conflict (transient) | Yes, with incremental back-off |
| 503 | Service unavailable | Yes |

For **429 errors**, the SDK waits for the duration specified in the response's `x-ms-retry-after-ms` header before retrying. If retries are exhausted, the error surfaces to your application. You should add your own retry layer with exponential back-off for these cases.

For **write timeouts**, the SDKs do *not* automatically retry because writes are not idempotent. A timed-out write may have actually succeeded on the server. Your application should implement idempotent writes (for example, using the item ID as a natural idempotency key) and handle 409 Conflict responses that result from retrying a write that already succeeded.

### Preferred Regions

Always configure a preferred regions list in your SDK client. This tells the SDK which regions to try, in order, when the primary region is unavailable:

```csharp
CosmosClient client = new CosmosClient(endpoint, key, new CosmosClientOptions
{
    ApplicationPreferredRegions = new List<string>
    {
        Regions.EastUS,
        Regions.WestUS,
        Regions.WestEurope
    }
});
```

During a read-region outage, the SDK detects the failure through backend response codes, marks the region as unavailable, and routes subsequent requests to the next region in the list. This happens transparently — your application code doesn't need to change.

### Circuit Breakers and Availability Strategy

For even more control, modern versions of the .NET and Java SDKs support **partition-level circuit breakers** and **availability strategies** (sometimes called "hedging"):

- **Partition-level circuit breaker:** If a specific physical partition in one region is consistently failing, the SDK can route requests for that partition to another region, without affecting other partitions.
- **Threshold-based availability strategy:** Sends a parallel (hedged) request to a secondary region if the primary region hasn't responded within a configurable latency threshold. The first response wins. This reduces tail latency at the cost of slightly higher RU consumption.

The general principle: configure your SDK for failure. Set preferred regions, enable diagnostics logging, and layer your own retry logic on top of the SDK's built-in retries for the error codes that matter to your application.

## How Consistency Interacts with Multi-Region Writes

Multi-region writes (also called multi-master) let any region accept write operations. This fundamentally changes how consistency behaves.

### Strong Consistency Is Not Available

As noted earlier, strong consistency requires a global majority quorum on every write. With multi-region writes, there's no single "source of truth" to quorum against — writes can originate anywhere. Cosmos DB therefore does not allow strong consistency on multi-region write accounts. If you need strong consistency, use a single write region.

### Bounded Staleness Becomes an Anti-Pattern

With multi-region writes, applications should read from the same region they write to. Since bounded staleness is designed to control lag *between* regions, it provides no benefit when your reads and writes happen locally. Using bounded staleness with multi-region writes adds cost (2× read RUs) without meaningful consistency improvement.

### Session Consistency Remains Effective

Session consistency works well with multi-region writes because the session token tracks the client's own writes within its local region. As long as your client writes and reads from the same region (which the SDK does by default), read-your-writes guarantees hold.

### Conflict Resolution

When two regions write to the same item simultaneously, a conflict occurs. Cosmos DB resolves conflicts automatically using one of two policies:

- **Last-Writer-Wins (LWW):** The default. Cosmos DB uses a system-generated `_ts` timestamp (or a custom numeric property you specify) to pick the winner. The write with the higher timestamp value survives.
- **Custom conflict resolution:** You provide a stored procedure that runs server-side to merge or resolve conflicts according to your business logic.

Conflict resolution is orthogonal to consistency level — it determines *which write wins*, not *when readers see it*. Once a conflict is resolved, all consistency guarantees apply to the winning value.

### Data Durability Across Regions

Consistency level directly affects your recovery point objective (RPO) — the maximum data loss during a regional outage:

| Regions | Write Config | Consistency Level | RPO |
|---|---|---|---|
| >1 | Single write region | Strong | 0 (no data loss) |
| >1 | Single write region | Bounded Staleness | K versions or T seconds |
| >1 | Single write region | Session / Prefix / Eventual | < 15 minutes |
| >1 | Multiple write regions | Session / Prefix / Eventual | < 15 minutes |

If zero data loss during regional outages is a hard requirement, strong consistency with a single write region is your only option.

## Key Takeaways

1. **Start with session consistency.** It's the default, it's cheap, and it covers the most common access pattern: users reading their own writes.
2. **Only pay for stronger consistency where you need it.** Use per-request overrides to relax consistency on non-critical reads.
3. **Strong and bounded staleness cost 2× the read RUs.** Factor this into your capacity planning.
4. **Strong consistency is incompatible with multi-region writes.** Design your topology accordingly.
5. **Configure your SDK for resilience.** Set preferred regions, understand which errors to retry, and consider availability strategies for latency-sensitive workloads.
6. **Use the PBS metric** in the Azure portal to understand how often your eventual-consistency reads are actually returning the latest data.

## What's Next

You now understand the consistency guarantees Cosmos DB offers and how to choose between them. In **Chapter 13**, we'll explore **stored procedures, triggers, and user-defined functions** — Cosmos DB's server-side JavaScript programming model. You'll learn how to execute multi-document transactions within a partition key, hook into create and update operations with pre- and post-triggers, and extend the query language with custom UDFs.
