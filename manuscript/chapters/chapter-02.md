# Chapter 2: Core Concepts and Architecture

Before you write a single line of code against Cosmos DB, you need a mental model of how the service is put together. Not the marketing version — the real one. How data is organized, how the engine charges you for work, how it splits and replicates your data behind the scenes. This chapter gives you that foundation. Everything else in the book — modeling, querying, tuning, scaling — builds on the concepts here.

## The Resource Model: Accounts, Databases, Containers, and Items

Cosmos DB organizes everything into a four-level hierarchy: **account → database → container → item**. Each level serves a distinct purpose, and understanding what lives where saves you from misconfigurations that are painful to undo later.

### Account

An **account** is the top-level resource. It's what you create in the Azure portal (or via ARM/Bicep/Terraform), and it gives you a unique DNS endpoint — something like `https://your-account.documents.azure.com`. All configuration that applies globally lives at the account level: which Azure regions your data is replicated to, the default consistency level, whether multi-region writes are enabled, and your networking and security settings.

You can create up to 250 accounts per Azure subscription by default, increasable to 1,000 via a support request. In practice, most applications use a single account. <!-- Source: concepts-limits.md -->

### Database

A **database** is essentially a namespace — a logical grouping of containers. Think of it as an organizational bucket. If you're coming from relational databases, it maps roughly to a database in SQL Server or a keyspace in Cassandra. There's no compute or storage directly associated with a database; it's just a grouping.

Where databases *do* matter is **shared throughput**. You can provision throughput at the database level and share it across up to 25 containers within that database. This is useful when you have many small containers with similar workloads and don't want to pay for dedicated throughput on each one. We'll cover throughput modes in detail in Chapter 11. <!-- Source: resource-model.md, set-throughput.md -->

### Container

The **container** is where the real action is. It's the fundamental unit of scalability — the thing you provision throughput for, define partition keys on, configure indexing policies for, and ultimately store data in.

A container in the NoSQL API maps to a *collection* in MongoDB, a *table* in Cassandra or Table API, and a *graph* in Gremlin. Regardless of what you call it, the underlying engine is the same.

Containers are **schema-agnostic**. Items within a single container can have completely different structures — a customer profile and that customer's orders can live side by side, sharing the same partition key. There's no `CREATE TABLE` statement, no schema migration to run. You just write JSON. Whether that freedom helps or hurts you depends on your data modeling discipline (Chapter 4 covers that).

Each container can hold an unlimited amount of data and throughput. When you hear "unlimited," there's always a catch — the catch here is that growth happens through partitioning, which we'll cover shortly.

A heads-up: once you create a container, certain decisions are locked in. The partition key can't be changed. Unique key constraints can't be modified. Switching a container between shared and dedicated throughput requires creating a new container and copying the data. Plan before you provision. <!-- Source: resource-model.md, unique-keys.md -->

### Item

An **item** is an individual JSON document stored inside a container. It's the lowest level of the hierarchy — the actual data. In MongoDB terms it's a document; in Cassandra terms it's a row; in Gremlin it's a node or edge.

Every item must have an `id` property, and that `id` must be unique *within its logical partition*. The combination of partition key + `id` uniquely identifies any item in the container. Two items *can* share the same `id` as long as they live in different logical partitions.

The maximum item size is **2 MB** (measured as the UTF-8 length of the JSON representation). That's a hard limit for the NoSQL API. If you're storing blobs, images, or large payloads, store them in Azure Blob Storage and keep a reference in your Cosmos DB item. <!-- Source: concepts-limits.md -->

## What Is a "Document" in Cosmos DB?

Each item is a self-contained JSON document. Nested objects, arrays, arrays of objects — all fair game. Here's a typical example:

```json
{
  "id": "order-1042",
  "customerId": "cust-337",
  "status": "shipped",
  "lineItems": [
    { "sku": "WIDGET-A", "quantity": 3, "price": 12.99 },
    { "sku": "GADGET-B", "quantity": 1, "price": 49.99 }
  ],
  "shippingAddress": {
    "street": "123 Main St",
    "city": "Seattle",
    "state": "WA",
    "zip": "98101"
  },
  "orderDate": "2025-03-15T08:30:00Z"
}
```

This is a valid Cosmos DB item. Nested objects, arrays, arrays of objects — all fine. The maximum nesting depth is 128 levels, which you'll never hit in a sane data model. <!-- Source: concepts-limits.md -->

The schema flexibility is genuinely useful for iterative development, polymorphic data (think: a container with multiple entity types), and domains where the shape of data varies per record. But flexibility doesn't mean "anything goes" — it means *you* own the schema discipline, not the database. Chapter 4 dives deep into when to embed vs. reference, how to handle schema evolution, and the anti-patterns that turn this freedom into a maintenance nightmare.

## System Properties

Every item in a Cosmos DB container carries a set of **system-generated properties** alongside your application data. When you read an item back from the service, you'll see these properties injected into the JSON. Understanding them saves you from confusion the first time you inspect a document and wonder where all the underscore-prefixed fields came from.

```json
{
  "id": "order-1042",
  "customerId": "cust-337",
  "status": "shipped",
  "_rid": "EHcYAPolTiABAAAAAAAAAA==",
  "_self": "dbs/EHcYAA==/colls/.../docs/.../",
  "_etag": "\"0000a1b2-0000-0700-0000-65f5c3a00000\"",
  "_ts": 1710627744
}
```

Here's what each property does:

| Property | Type | Purpose |
|----------|------|---------|
| `id` | String (user-set) | Unique within a logical partition. Max: 1,023 bytes. |
| `_rid` | String (system) | Internal resource ID, unique across account. |
| `_self` | String (system) | Legacy REST self-link URI. Rarely needed. |
| `_etag` | String (system) | Changes on every update. For **optimistic concurrency**. |
| `_ts` | Integer (system) | Unix timestamp (seconds) of last write. |

You set `id` yourself; if you omit it, the SDK generates a GUID. The `_etag` is what you pass with a write to detect conflicts — the server rejects the write if the item changed since your last read. Chapter 16 covers this pattern in depth.

<!-- Source: resource-model.md (item system properties table) -->

A few practical notes:

- **`_etag` is your concurrency primitive.** In a relational database, you might use `rowversion` or `timestamp` columns for optimistic concurrency. In Cosmos DB, `_etag` fills that role. The SDK exposes it through the response headers and the item itself.
- **`_ts` is seconds, not milliseconds.** If you're used to JavaScript timestamps, remember to multiply by 1,000 before passing it to `new Date()`.
- **`_rid` is not the same as `id`.** The `_rid` is an internal routing identifier. Your application should never need to parse or construct one. Use `id` (the one you control) for all application logic.
- **System properties count toward the 2 MB item size limit.** They're small, but they're there.

There's also `_lsn` (log sequence number), which appears in change feed payloads but not on regular item reads. We'll encounter it in Chapter 15 when we cover the change feed. <!-- Source: resource-model.md -->

## Unique Key Constraints

By default, the only uniqueness guarantee within a Cosmos DB container is the combination of partition key + `id`. If you need to enforce uniqueness on *other* properties — say, ensuring no two users in the same company have the same email address — you define a **unique key policy** when creating the container.

Key rules:

- Unique keys are scoped to a **logical partition**. Two items in *different* logical partitions can have the same value for a unique key property. The constraint only prevents duplicates within the same partition.
- You define unique keys **at container creation time only**. You can't add, modify, or remove them later. This is a one-shot decision. <!-- Source: unique-keys.md -->
- There are hard limits on the number of unique key constraints and paths per constraint — see the Service Limits table later in this chapter. <!-- Source: concepts-limits.md -->
- Values are case-sensitive. `/email` and `/Email` are different paths.
- Sparse values aren't supported — missing properties are treated as `null`, and only one item per logical partition can have `null` for a given unique key.

A composite unique key lets you enforce uniqueness across *combinations* of properties. For example, a constraint on `/firstName`, `/lastName`, `/email` ensures that the specific combination of all three is unique — not each property individually.

```json
{
  "uniqueKeyPolicy": {
    "uniqueKeys": [
      { "paths": ["/email"] },
      { "paths": ["/firstName", "/lastName", "/email"] }
    ]
  }
}
```

When a write violates a unique key constraint, the service returns a conflict error (`409`). The write is simply rejected — no partial updates, no silent overwriting.

One gotcha: unique key enforcement adds a small overhead to write operations (a few extra RUs). It's negligible for most workloads, but worth knowing if you're micro-optimizing a high-throughput write path.

## Request Units: The Universal Currency

This is the concept that makes or breaks your Cosmos DB experience. If you understand **Request Units (RUs)**, you can predict costs, diagnose performance problems, and design efficient applications. If you don't, you'll be surprised by your Azure bill and confused by throttling errors.

### What Is a Request Unit?

A **Request Unit** is Cosmos DB's abstraction for the cost of a database operation. Every read, write, query, and stored procedure execution consumes some number of RUs. The RU charge rolls up CPU, memory, and IOPS into a single number, so you don't have to reason about individual hardware resources.

The baseline: **a point read of a single 1 KB item by its `id` and partition key costs 1 RU**. Everything else is measured relative to that. <!-- Source: request-units.md -->

| Operation | ~Cost |
|-----------|-------|
| Point read, 1 KB | 1 RU |
| Point read, 100 KB | 10 RUs |
| Write, 1 KB | 5 RUs |
| Write, 100 KB | 50 RUs |
| Query | Varies with complexity |

"Write" covers insert, replace, and upsert. Query cost depends on result set size, predicates, and index usage.

<!-- Source: key-value-store-cost.md -->

These numbers come from the docs with automatic indexing turned off. In practice, with the default indexing policy enabled (which indexes every property), writes cost a bit more — a 1 KB insert typically lands between 5 and 7 RUs depending on how many properties the item has. The table above is still useful as a baseline; just know that your real numbers will be slightly higher on writes. <!-- Source: key-value-store-cost.md --> Change the consistency level, and the numbers shift too: reads at **strong** or **bounded staleness** consistency cost roughly **2x** the RUs of the more relaxed levels (session, consistent prefix, eventual). <!-- Source: request-units.md -->

### What Affects RU Cost?

Several factors determine how many RUs an operation consumes: <!-- Source: request-units.md -->

- **Item size.** Larger items cost more to read and write. The relationship is roughly linear.
- **Indexing.** By default, every property is indexed. More indexed properties means more RUs on writes. You can customize the indexing policy to exclude properties you never query on (Chapter 9).
- **Consistency level.** Strong and bounded staleness reads cost ~2x more than session or eventual.
- **Query complexity.** A query that scans 10,000 items costs far more than one that uses an index to find 3. The number of predicates, cross-partition fan-out, and result set size all matter.
- **Stored procedures and triggers.** They consume RUs proportional to the complexity of the operations they perform internally.

The critical insight: **RU charges are deterministic**. The same query on the same data with the same index always costs the same number of RUs. This makes performance predictable and debuggable — you can measure the RU cost of any operation by inspecting the response headers.

```csharp
ItemResponse<Order> response = await container.ReadItemAsync<Order>(
    "order-1042",
    new PartitionKey("cust-337")
);
Console.WriteLine($"This read cost {response.RequestCharge} RUs");
```

Every SDK surfaces `RequestCharge` on every response. Get in the habit of checking it during development. If a query costs 500 RUs and you're running it 100 times per second, you need 50,000 RU/s of provisioned throughput just for that one query pattern. The math is simple — that's the whole point.

### How You Pay for RUs

Cosmos DB offers three capacity modes, each with a different relationship between you and your RU budget:

| Mode | Best For |
|------|----------|
| **Provisioned (manual)** | Steady, predictable workloads |
| **Autoscale** | Variable traffic with peaks |
| **Serverless** | Dev/test, low or sporadic traffic |

- **Provisioned (manual):** You set a fixed RU/s value. Operations exceeding that budget get throttled (HTTP 429). Billed at the highest provisioned RU/s **per hour** — if you scale up mid-hour and back down, you pay for the peak.
- **Autoscale:** You set a max RU/s. The service scales between 10% and 100% of that max based on demand. Billed at the highest RU/s reached **per hour**.
- **Serverless:** No provisioning. You pay per RU consumed.

<!-- Source: request-units.md -->

Provisioned throughput is allocated in increments of 100 RU/s, with a minimum of 400 RU/s for a container with manual throughput. Autoscale starts at a minimum max of 1,000 RU/s. The maximum for any single container or database is 1,000,000 RU/s, which can be raised further via a support request. <!-- Source: concepts-limits.md -->

We'll go deep on capacity planning, cost optimization, and choosing between these modes in Chapter 11. For now, internalize the core idea: **everything you do in Cosmos DB has an RU cost, and that cost is how you plan capacity and budget.**

## Automatic Indexing

Cosmos DB indexes every property of every item in a container by default. Range indexes are created for all strings and numbers, so your queries work efficiently out of the box — no `CREATE INDEX` statements, no DBA reviewing query plans before production. When you insert an item, the index updates synchronously (in the default "consistent" indexing mode), so the item is immediately queryable. You can customize the indexing policy to include or exclude specific paths, and Chapter 9 covers indexing policies — including composite, spatial, and vector indexes — in full. <!-- Source: index-policy.md -->

## The Logical Partition: Cosmos DB's Unit of Scale

A **logical partition** is the set of all items that share the same partition key value. If your container uses `customerId` as the partition key, then all items with `customerId = "cust-337"` form one logical partition.

Logical partitions matter because they define boundaries for several important behaviors:

- **Uniqueness.** The `id` property must be unique within a logical partition, not the whole container.
- **Unique key constraints.** Enforced per logical partition.
- **Transactions.** Multi-item ACID transactions (via stored procedures or transactional batch) are scoped to a single logical partition. You can't atomically update items across different partition key values. <!-- Source: partitioning.md, database-transactions-optimistic-concurrency.md -->
- **Storage limit.** Each logical partition can hold up to **20 GB** of data. If a single partition key value accumulates more than 20 GB, writes to that partition will fail. This is the most common scaling wall people hit, and it's why partition key choice is the single most important design decision you'll make (Chapter 5). <!-- Source: concepts-limits.md, partitioning.md -->

There's no limit to the *number* of logical partitions in a container. You can have billions of distinct partition key values. The constraint is on the *size* of each individual one. <!-- Source: concepts-limits.md -->

## Physical vs. Logical Partitions

Behind the scenes, Cosmos DB maps your logical partitions onto **physical partitions** — actual storage and compute resources on the service's infrastructure. Multiple logical partitions can share a single physical partition. As your data grows, the service automatically splits physical partitions to maintain performance.

Each physical partition supports up to **10,000 RU/s** of throughput and up to **50 GB** of storage. When either limit is approached, Cosmos DB splits the physical partition, redistributing logical partitions across the new physical partitions. This happens transparently — your application sees no downtime and no behavior change. The mechanics of how splits work, what triggers them, and how the reverse operation (partition merge) can reclaim fragmented resources are covered in Chapter 5. <!-- Source: resource-model.md, partitioning.md -->

Provisioned throughput is divided evenly across physical partitions, which means an uneven partition key can create a "hot partition" that gets throttled even though the container has headroom overall. We'll explore the throughput math and partition key design strategies in Chapter 5, including hierarchical partition keys that help you break through the 20 GB logical partition limit.

## Replica Sets and High Availability

Each physical partition isn't a single point of failure. It's backed by a **replica set** — a group of replicas that collectively make the data within that partition durable, highly available, and consistent. Each replica hosts an instance of the Cosmos DB database engine and maintains a copy of the data and indexes.

Every physical partition has at least **four replicas**, even for small containers that only need a single physical partition. One replica acts as the leader (handling writes), and the others serve reads and stand ready to take over if the leader fails. Writes are committed using a majority quorum — they must be acknowledged by a majority of replicas before the write is confirmed to the client. <!-- Source: partitioning.md, global-distribution.md -->

If your account spans *N* Azure regions, there are at least *N* × 4 copies of all your data. A three-region account means at least 12 replicas of every partition. This is how Cosmos DB delivers its high-availability SLAs without you configuring anything — the redundancy is baked into the architecture. <!-- Source: global-distribution.md -->

Replicas within a region are spread across fault domains (typically 10–20 per data center), so a rack failure or even a partial data center outage won't take down your data. We'll cover multi-region distribution, failover policies, and availability zone configuration in Chapter 12. <!-- Source: global-distribution.md -->

## Service Limits and Quotas

Every service has limits. Knowing them upfront prevents nasty surprises at 2 AM. Here are the ones that matter most for day-to-day development:

### Item Limits

| Resource | Limit |
|----------|-------|
| Max item size | 2 MB (UTF-8 JSON length) |
| Max `id` length | 1,023 bytes |
| Max partition key length | 2,048 bytes* |
| Max nesting depth | 128 levels |
| Max properties per item | No practical limit |

*Without large partition keys enabled, the max is 101 bytes.

<!-- Source: concepts-limits.md -->

### Container and Database Limits

| Resource | Limit |
|----------|-------|
| DBs + containers per account | 500 total |
| Shared-throughput DB containers | 25 |
| Stored procs per container | 100 |
| UDFs per container | 50 |
| Unique key constraints | 10 per container |
| Paths per unique key | 16 |
| DB / container name length | 255 chars |

<!-- Source: concepts-limits.md -->

### Throughput Limits

| Resource | Limit |
|----------|-------|
| Max RU/s per container or DB | 1,000,000* |
| Max RU/s per physical partition | 10,000 |
| Min RU/s (manual throughput) | 400 |
| Min autoscale max RU/s | 1,000 |
| Storage per logical partition | 20 GB |
| Storage per physical partition | 50 GB |

*Increasable via Azure support request.

<!-- Source: concepts-limits.md -->

### Request Limits

| Resource | Limit |
|----------|-------|
| Max execution time (single op) | 5 seconds |
| Max request size | 2 MB |
| Max response page size | 4 MB |
| Transactional batch ops | 100 |
| Max SQL query length | 512 KB |
| Max JOINs per query | 10 |

<!-- Source: concepts-limits.md -->

A full reference of all limits (including less common ones like composite index paths, token expiry times, and control plane rate limits) is in Appendix E.

With these fundamentals in place — the resource hierarchy, system properties, the RU model, partitioning, and service limits — you have the vocabulary to understand everything that follows. Chapter 3 puts it into practice: setting up your first Cosmos DB account, creating databases and containers, and writing your first item.
