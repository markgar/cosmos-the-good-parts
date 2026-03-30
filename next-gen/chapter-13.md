# Chapter 13: Consistency Levels

You've replicated your data to three continents. A user in Frankfurt writes a product review. A user in Sydney reads the product page half a second later. Does she see the review? That depends entirely on the consistency level you chose — and choosing the wrong one means your application either pays too much, reads stale data at the worst time, or slows to a crawl waiting for a guarantee it didn't need.

Most distributed databases give you two options: strong consistency (safe but slow) or eventual consistency (fast but chaotic). Cosmos DB gives you five. That's not complexity for its own sake — it's recognition that different operations within the same application have different tolerance for staleness. A bank transfer needs the latest balance. A social media like count does not. Cosmos DB lets you pick the right tradeoff instead of forcing a one-size-fits-all answer.

## The Consistency Spectrum

Think of consistency as a dial, not a switch. At one extreme, **strong consistency** guarantees every read returns the most recent write — across every region, every replica, every time. At the other extreme, **eventual consistency** says the data will converge *at some point*, but right now you might read something stale. Between those poles sit three levels that trade off increasing staleness tolerance for better latency, throughput, and availability.

<!-- Source: consistency-levels.md -->

Here's the spectrum from strongest to weakest:

| Consistency Level | Guarantee | Write Latency | RU Cost (Reads) |
|---|---|---|---|
| **Strong** | Linearizable — always the latest committed write | Highest (multi-region: 2×RTT + 10ms) | 2× |
| **Bounded Staleness** | Reads lag by at most *K* versions or *T* seconds | < 10ms at p99 | 2× |
| **Session** | Read-your-writes within a client session | < 10ms at p99 | 1× |
| **Consistent Prefix** | No out-of-order reads, but can lag | < 10ms at p99 | 1× |
| **Eventual** | No ordering guarantees, lowest latency | < 10ms at p99 | 1× |

Every step down the ladder trades some freshness for better performance. The rest of this chapter explains exactly what each level guarantees, what it doesn't, and when to use it.

## The Five Consistency Levels Explained

Before we dive into each level, one architectural detail matters: each physical partition in Cosmos DB maintains a **four-replica set**. Writes are committed to some quorum of those replicas, and reads are served from one or more replicas depending on the consistency level. The differences in how many replicas participate — and whether remote regions must acknowledge — is what makes each level behave differently.

<!-- Source: consistency-levels.md -->

One more ground rule: **read consistency applies to a single read operation within a single logical partition**. Whether that read comes from your application code, a stored procedure, or a trigger, the consistency guarantee applies per-operation, not globally across your entire dataset.

### Strong Consistency

**Strong** consistency offers a **linearizability** guarantee. Every read, in every region, returns the most recent committed version of an item. You never see an uncommitted or partial write. If two clients on opposite sides of the planet read the same item at the same instant after a write, they both get the same value — the latest one.

<!-- Source: consistency-levels.md -->

This is the easiest model to reason about. It behaves like a single-copy system. No stale reads, no surprises. But that guarantee costs something:

**Writes require acknowledgment from every region.** When you write an item under strong consistency, the operation doesn't return until all regions in your account have committed the write. The docs call this a "global majority" commit, but under normal conditions that means every region — no exceptions. (The Dynamic Quorum section below explains what happens when a region becomes unresponsive.)

**Write latency scales with geography.** For multi-region accounts, the write latency at the 99th percentile equals **two times the round-trip time (RTT) between the two farthest regions, plus 10 milliseconds**. If your farthest regions are US East and Australia East — roughly 200ms RTT — you're looking at around 410ms per write at p99. That's an order of magnitude slower than the sub-10ms latency you get with other consistency levels.

<!-- Source: consistency-levels.md -->

**Reads consume 2× the RUs.** Strong consistency reads from two replicas in the local region (a minority quorum) to ensure freshness. That doubles the RU cost compared to session or eventual consistency. A point read that costs 1 RU under session consistency costs 2 RUs under strong.

<!-- Source: consistency-levels.md, request-units.md -->

**Regions farther than 5,000 miles (8,000 km) apart are blocked by default.** If you need strong consistency spanning, say, US East and Southeast Asia, you'll need to contact Azure support to enable it. Microsoft blocks this by default because the write latency would be punishingly high.

<!-- Source: consistency-levels.md -->

#### Dynamic Quorum

Strong consistency isn't as brittle as it sounds. Cosmos DB implements **dynamic quorum** for accounts with three or more regions.

Under normal conditions, a write must be acknowledged by all regions. But if a region becomes unresponsive, the system can temporarily remove it from the quorum set to maintain write availability while preserving the strong consistency guarantee. In a five-region account, up to two unresponsive regions can be removed (since the majority is three). Removed regions can't serve reads until they rejoin the quorum.

<!-- Source: consistency-levels.md -->

#### When to Use Strong Consistency

Use strong when your application cannot tolerate *any* stale reads and the latency penalty is acceptable. Financial ledgers, inventory systems where double-selling is catastrophic, and regulatory scenarios where reads must always reflect the latest state are the classic use cases.

Strong consistency is **not available with multi-region writes**. If your account is configured for multi-region writes, you can't select strong as your consistency level — the distributed system can't guarantee both zero RPO and zero RTO simultaneously. Chapter 12 covers this constraint from the replication angle.

<!-- Source: consistency-levels.md -->

### Bounded Staleness

**Bounded staleness** lets you put a ceiling on *how stale* a read can be. You configure two bounds, and whichever is reached first takes effect:

- **K** — the maximum number of versions (writes) a read can lag behind
- **T** — the maximum time interval a read can lag behind

If you set K = 100,000 and T = 300 seconds, you're saying: "Reads in secondary regions can be at most 100,000 versions or 5 minutes behind, whichever is tighter."

<!-- Source: consistency-levels.md -->

The minimums depend on your account topology:

| Account Type | Minimum K | Minimum T |
|---|---|---|
| Single-region | 10 write operations | 5 seconds |
| Multi-region | 100,000 write operations | 300 seconds (5 minutes) |

<!-- Source: consistency-levels.md -->

There's a subtlety that trips people up: **staleness checks happen only across regions, not within a region**. Within any given region, data is always replicated to a local majority (three replicas in the four-replica set) regardless of the consistency level. So within the write region, bounded staleness behaves like strong consistency. The "bounded lag" applies to *secondary regions* reading data written in the primary.

<!-- Source: consistency-levels.md -->

Like strong consistency, bounded staleness reads use a **minority quorum** — two replicas in the local region — which means **reads cost 2× the RUs** of weaker consistency levels.

<!-- Source: consistency-levels.md -->

If the replication lag for any partition exceeds the configured staleness bounds, writes to that partition are **throttled** until staleness falls back within limits. This is the service enforcing the guarantee you asked for — but it can cause unexpected 429 (rate-limited) responses if cross-region replication is slow.

<!-- Source: consistency-levels.md -->

#### Bounded Staleness and Multi-Region Writes: An Anti-Pattern

The docs are blunt about this, and so am I: **bounded staleness in a multi-region write account is an anti-pattern**. In a multi-write topology, application servers should be reading and writing in the same region. The staleness bound measures lag *between* regions, which is irrelevant if you're always reading from where you wrote. You'd be paying the 2× RU read cost for a guarantee that doesn't help you. Use session consistency instead.

<!-- Source: consistency-levels.md -->

#### When to Use Bounded Staleness

Bounded staleness is designed for **single-region write accounts with multiple read regions** where you need near-strong consistency globally but can tolerate a small, predictable lag. Think: a global analytics dashboard that can be a few minutes behind, but never wildly out of date. Or a multi-region app where regulatory requirements dictate a maximum data freshness window.

### Session Consistency

**Session** is the default consistency level for Cosmos DB accounts, and for good reason — it's the right choice for most applications.

The guarantee: within a single client session, you get **read-your-writes** and **write-follows-reads**. If you write an item and immediately read it back, you see your write. Always. Outside your session, other readers might see stale data (exactly like eventual consistency), but *you* never see your own writes disappear.

<!-- Source: consistency-levels.md -->

The mechanism behind this is the **session token**. After every write, the server returns an updated session token to the SDK. The SDK caches this token and sends it with subsequent read requests. The token tells the server "I need data at least as fresh as version X." If the replica serving the read has that version (or newer), it returns the data. If not, the SDK retries against other replicas in the region and, if necessary, in other regions.

<!-- Source: consistency-levels.md -->

A few critical details:

**Session tokens are partition-bound.** Each token is associated with a specific physical partition. If your client writes to partition A and then reads from partition B (a different partition key), there's no session token for partition B — and that read behaves like eventual consistency. This is by design, but it surprises developers who expect session consistency to be "sticky" across the entire container.

**New clients start cold.** When you create a new `CosmosClient` instance (or restart your application), the session token cache is empty. Until the client performs writes that populate the cache, reads behave like eventual consistency. This is why Chapter 7 stressed using a singleton `CosmosClient` — creating fresh instances breaks session continuity.

**You can pass session tokens between clients.** In a web application with stateless backends behind a load balancer, requests might land on different servers, each with its own `CosmosClient` instance. If you need read-your-writes across those servers, extract the session token from the write response header (`x-ms-session-token`) and pass it to subsequent read requests. The typical approach is to flow the token through a cookie or custom HTTP header.

<!-- Source: how-to-manage-consistency.md -->

Here's what passing a session token looks like in C#:

```csharp
// After a write, capture the session token
ItemResponse<Order> writeResponse = await container.UpsertItemAsync(order, 
    new PartitionKey(order.CustomerId));
string sessionToken = writeResponse.Headers.Session;

// On a subsequent read (possibly from a different server), pass it
ItemResponse<Order> readResponse = await container.ReadItemAsync<Order>(
    order.Id,
    new PartitionKey(order.CustomerId),
    new ItemRequestOptions { SessionToken = sessionToken }
);
```

<!-- Source: how-to-manage-consistency.md -->

And in JavaScript:

```javascript
// Capture session token from the write response
const { headers } = await container.items.upsert(order);
const sessionToken = headers["x-ms-session-token"];

// Use it on a subsequent read
const { resource } = await container.item(order.id, order.customerId)
    .read({ sessionToken });
```

<!-- Source: how-to-manage-consistency.md -->

If you don't manually manage session tokens, the SDK handles it automatically within a single client instance. You only need to get involved when crossing client boundaries.

#### When to Use Session Consistency

Session is the right default for the vast majority of applications. Any scenario where users interact with their own data — shopping carts, user profiles, document editing, order tracking — benefits from read-your-writes without the latency or cost penalty of strong consistency. It provides write latencies, availability, and read throughput comparable to eventual consistency while giving you the one guarantee most applications actually need.

<!-- Source: consistency-levels.md -->

### Consistent Prefix

**Consistent prefix** guarantees that you never see writes out of order — but makes no promise about *how far behind* you might be.

The key distinction here is between single-document writes and transactional batches:

- **Single document writes** see eventual consistency. A standalone write to one document offers no ordering guarantee relative to other standalone writes.
- **Transactional batch writes** are always visible together. If a transaction writes Doc1 v2 and Doc2 v2 atomically, a reader will see either both old values (Doc1 v1, Doc2 v1) or both new values (Doc1 v2, Doc2 v2) — never a mix like Doc1 v2 with Doc2 v1.

<!-- Source: consistency-levels.md -->

This level reads from a single replica, so **RU cost is the same as session and eventual** — no 2× penalty. Writes use local majority (three of four replicas), same as all non-strong levels.

#### When to Use Consistent Prefix

Consistent prefix is useful when you're processing events or state transitions that must appear in order but don't need to be real-time. A pipeline processing status updates (pending → processing → complete) benefits from never seeing "complete" before "processing," even if the reader is a few seconds behind. However, for single-document operations, consistent prefix offers minimal benefit over eventual. Its value is concentrated in transactional batch scenarios.

### Eventual Consistency

**Eventual** consistency is the weakest level. The only guarantee is that, given enough time without new writes, all replicas will converge to the same value. While writes are still propagating, a client might read stale data — and might even read *older* data than it read a moment ago. There's no ordering guarantee whatsoever.

<!-- Source: consistency-levels.md -->

Reads go to any one of the four replicas in the local region. If that replica is lagging, you get stale data. No retries, no version checking, no session tokens — just whatever the first replica has.

This gives you the best read performance. Single-replica reads mean the lowest possible latency and the standard 1× RU cost. Write performance is identical to all other non-strong levels: local majority commit, asynchronous replication to other regions.

#### When to Use Eventual Consistency

Eventual consistency works for data where staleness is harmless and ordering doesn't matter: like counts, social media reactions, non-threaded comments, view counters, or telemetry aggregations. If you're building a dashboard that shows approximate metrics and can tolerate a few seconds of lag, eventual consistency gives you the cheapest, fastest reads available.

Don't use it for anything where a user could notice inconsistency. A shopping cart that loses the last item you added — even temporarily — is a terrible experience.

## Choosing the Right Consistency for Your Workload

The five levels aren't equally popular. In practice, the decision tree is simpler than the spectrum implies.

**Start with Session.** It's the default for a reason. Most application logic operates in the context of a user session — a web request, an API call, a mobile app interaction. Within that context, read-your-writes is the guarantee you actually need. Session consistency costs the same as eventual for reads (1× RU) and gives you a meaningful guarantee.

**Step up to Strong or Bounded Staleness only when you have a concrete reason.** Financial transactions, inventory reservations, or regulatory requirements that mandate zero staleness justify the cost. Remember: you're paying 2× RU on every read and (for strong in multi-region) significantly higher write latency.

**Step down to Eventual only for genuinely unimportant reads.** Analytics counters, activity feeds where "close enough" is fine, bulk data pipelines where the consumer tolerates lag.

**Consistent Prefix lives in a narrow niche.** It's mainly useful when you have transactional batches that must be visible atomically but don't need to be current. For single-document operations, it behaves almost identically to eventual.

Here's a decision table:

| Scenario | Recommended Level | Why |
|---|---|---|
| User reads their own data (profiles, carts, orders) | **Session** | Read-your-writes at low cost |
| Financial ledger, inventory, legal record | **Strong** | Zero staleness required |
| Global dashboard, max 5 min delay acceptable | **Bounded Staleness** | Controlled lag ceiling |
| Event processing pipeline with ordered transactions | **Consistent Prefix** | No out-of-order batch reads |
| Like counts, view counters, telemetry | **Eventual** | Staleness is harmless |

## Consistency and Its Impact on RU Cost and Latency

Consistency isn't free. Your choice affects both the cost of individual operations and the throughput ceiling of your account.

### Read Cost

The fundamental split: **strong and bounded staleness reads cost 2× the RUs** of session, consistent prefix, and eventual reads. This is because strong and bounded staleness read from two replicas (a local minority quorum), while the weaker levels read from a single replica.

<!-- Source: consistency-levels.md, request-units.md -->

| Consistency Level | Quorum Reads | Quorum Writes | Read RU Multiplier |
|---|---|---|---|
| **Strong** | Local Minority (2 replicas) | Global Majority | 2× |
| **Bounded Staleness** | Local Minority (2 replicas) | Local Majority | 2× |
| **Session** | Single Replica (session token) | Local Majority | 1× |
| **Consistent Prefix** | Single Replica | Local Majority | 1× |
| **Eventual** | Single Replica | Local Majority | 1× |

<!-- Source: consistency-levels.md -->

Concretely: a point read of a 1 KB item costs about 1 RU at session consistency but about 2 RUs at strong consistency. For a read-heavy workload doing millions of point reads per day, that's a 2× difference in your monthly bill's read component. Chapter 10 covers RU mechanics in depth; the takeaway here is that consistency level is one of the main levers for managing RU cost.

### Write Cost

Write RU cost is **identical across all consistency levels**. A 1 KB upsert costs the same number of RUs whether your account is set to strong or eventual. The difference is in *latency*, not cost:

- **Strong:** writes must commit to all regions (the docs call this "global majority"). Latency = 2×RTT between farthest regions + 10ms at p99.
- **All others:** writes commit to a local majority (three of four replicas in the local region). Replication to other regions is asynchronous. Latency stays under 10ms at p99.

<!-- Source: consistency-levels.md -->

### Read Latency

All consistency levels guarantee read latency under 10 milliseconds at the 99th percentile, with typical (p50) read latency of 4 milliseconds or less. The consistency level doesn't change the latency SLA for reads — it changes the *cost* (RUs) and the *freshness* of what you read.

<!-- Source: consistency-levels.md -->

### The Throughput Impact

Since strong and bounded staleness reads consume 2× RUs, they also halve your effective read throughput for the same provisioned RU/s. If you provision 10,000 RU/s, a workload using session consistency can sustain roughly twice as many 1 KB point reads per second as the same workload using strong consistency. That's a significant capacity difference — factor it into your provisioning calculations.

## Per-Request Consistency Override

You don't have to pick one consistency level and live with it for every operation. Cosmos DB lets you **override the default consistency on a per-request basis** — but with a critical constraint: **you can only relax, never strengthen**. If your account default is session, you can weaken a specific read to eventual (cheaper, faster), but you can't elevate it to strong.

<!-- Source: consistency-levels.md, how-to-manage-consistency.md -->

This is useful when different operations within the same application have different freshness needs. Your checkout flow might use the account default (session) to guarantee read-your-writes on the order, while a product recommendations query relaxes to eventual because a slightly stale recommendation is fine.

Chapter 7 showed the code pattern. Here's a quick reminder in C#:

```csharp
// Account default is Session. Relax this specific read to Eventual.
var options = new ItemRequestOptions
{
    ConsistencyLevel = ConsistencyLevel.Eventual
};

ItemResponse<Product> response = await container.ReadItemAsync<Product>(
    "prod-1001",
    new PartitionKey("gear-surf-surfboards"),
    options
);
```

<!-- Source: how-to-manage-consistency.md -->

And the same in Go, where per-request overrides are set through options:

```go
container.ReadItem(
    context.Background(),
    azcosmos.NewPartitionKeyString("gear-surf-surfboards"),
    "prod-1001",
    &azcosmos.ItemOptions{
        ConsistencyLevel: azcosmos.ConsistencyLevelEventual.ToPtr(),
    },
)
```

<!-- Source: how-to-manage-consistency.md -->

One detail that catches people: **overriding consistency affects reads only**. An account configured for strong consistency still writes synchronously to every region, even if the SDK or request overrides the read consistency to eventual. You're changing *how reads are served*, not how writes are replicated.

<!-- Source: consistency-levels.md, how-to-manage-consistency.md -->

To go the other direction — strengthening consistency — you need to change the account-level default. If your account is set to eventual and you need strong consistency for some operations, you must change the account default to strong and then relax per-request where you don't need it. One important housekeeping note: after changing the account-level consistency, restart your application (or recreate your SDK client instances) so the SDK picks up the new default.

<!-- Source: consistency-levels.md -->

## How Consistency Interacts with Multi-Region Writes

Chapter 12 covers multi-region write topologies and conflict resolution in detail. Here, we'll focus specifically on how consistency levels behave differently in multi-region write accounts.

### Strong Consistency Is Off the Table

As covered in the Strong Consistency section above, **strong consistency is not available with multi-region writes** — you must use a single-region write configuration.

### Bounded Staleness Isn't Worth It

As discussed earlier, combining bounded staleness with multi-region writes is an anti-pattern — you pay the 2× read cost for no benefit.

### Session Is the Sweet Spot for Multi-Region Writes

In a multi-region write account, session consistency gives you read-your-writes within each region. As long as your application reads from the same region where it wrote (which the SDK's preferred-regions configuration handles automatically), session consistency works exactly as you'd expect. Writes that arrive in satellite regions are sent to the hub region for conflict resolution asynchronously, but your local reads see your local writes immediately.

### Consistency and Data Durability

Your consistency level directly impacts your **Recovery Point Objective (RPO)** — how much data you could lose during a regional outage. Here's the relationship:

<!-- Source: consistency-levels.md -->

| Regions | Replication Mode | Consistency Level | RPO |
|---|---|---|---|
| 1 | Single or multiple write | Any | < 240 minutes |
| >1 | Single write | Session, Consistent Prefix, Eventual | < 15 minutes |
| >1 | Single write | Bounded Staleness | *K* versions & *T* seconds |
| >1 | Single write | Strong | 0 |
| >1 | Multiple write | Session, Consistent Prefix, Eventual | < 15 minutes |
| >1 | Multiple write | Bounded Staleness | *K* & *T* |

Only strong consistency with a single-region write account gives you zero RPO — no data loss during a regional outage. Every other combination can lose some recent writes. Chapter 19 covers disaster recovery planning in depth; keep this table in mind when choosing your consistency level for mission-critical workloads.

## In Practice: Consistency Is Often Stronger Than You Asked For

One last thing worth knowing: Cosmos DB frequently delivers stronger consistency than the level you configured. If there are no active writes, a read at eventual consistency might return the same result as a read at strong consistency — because all replicas have already converged. The **Probabilistically Bounded Staleness (PBS)** metric in the Azure portal quantifies this: it shows the probability that your reads are actually strongly consistent, even when you've configured a weaker level.

<!-- Source: consistency-levels.md, how-to-manage-consistency.md -->

This is a nice-to-know, not something to design around. Always architect for the *guaranteed* behavior, not the optimistic case. But it does mean that in practice, the cost savings of weaker consistency levels come with fewer real-world staleness incidents than you'd expect from the theory.

Up next, we'll leave the distributed systems theory behind and get into server-side code: stored procedures, triggers, and user-defined functions in Chapter 14.
