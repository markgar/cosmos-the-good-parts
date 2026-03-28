# Chapter 2: Core Concepts and Architecture

Before you write a single line of code against Azure Cosmos DB, you need a solid mental model of how the service is organized, how it charges you, and how it scales. This chapter gives you that foundation. We'll walk through the resource hierarchy, explain what a "document" actually is, demystify Request Units, and dig into the partitioning architecture that makes Cosmos DB tick. By the end, you'll understand why Cosmos DB makes the design choices it does — and how to think about your data in a way that sets you up for success.

## The Resource Model: From Account to Item

Everything in Cosmos DB follows a clean four-level hierarchy. If you've worked with relational databases, think of this as a more flexible version of server → database → table → row. Here's how it maps:

| Level | Cosmos DB Entity | NoSQL API Term | Relational Analogy |
|-------|-----------------|----------------|-------------------|
| 1 | **Account** | Account | Server instance |
| 2 | **Database** | Database | Database / schema |
| 3 | **Container** | Container | Table |
| 4 | **Item** | Item (document) | Row |

### Account

Your Azure Cosmos DB account is the top-level resource. It lives under your Azure subscription and has a unique DNS name (something like `myaccount.documents.azure.com`). The account is where you configure global distribution — adding or removing Azure regions, setting your default consistency level, and managing access keys. You can create up to 250 Cosmos DB accounts per Azure subscription (more by request).

### Database

A database in Cosmos DB is essentially a namespace — a logical grouping of containers. It's lightweight and doesn't have much configuration of its own, but it serves an important role: you can provision *shared throughput* at the database level and split it across up to 25 containers. This is a handy cost-saving measure when you have several containers with similar, modest workloads.

### Container

The container is where the action happens. It's the unit of scalability — where you define your partition key, configure throughput (dedicated or shared), set your indexing policy, and define optional features like time-to-live (TTL) and unique key constraints. Containers are *schema-agnostic*: you can store items with completely different shapes in the same container, as long as they share the same partition key property.

Under the hood, a container's data is distributed across one or more physical partitions, but you never interact with those directly. Your container is the abstraction you work with.

### Item

An item is a single JSON document stored in a container. It's the lowest level of the hierarchy and the thing you actually read and write. Every item must have an `id` property that's unique within its logical partition. Beyond that, you can put whatever JSON you like in there.

## What Is a "Document" in Cosmos DB?

If you're coming from MongoDB or other document databases, the concept is familiar. If you're coming from relational databases, here's the key shift: **there is no schema enforced by the database**. Each item is a self-contained JSON document, and two items in the same container can have completely different structures.

Here's a minimal valid item — the only required property is `id`:

```json
{
  "id": "unique-string-2309509"
}
```

And here's something more realistic — a product catalog entry:

```json
{
  "id": "product-1042",
  "categoryId": "electronics",
  "name": "Wireless Noise-Canceling Headphones",
  "price": 249.99,
  "tags": ["audio", "wireless", "noise-canceling"],
  "specifications": {
    "battery": "30 hours",
    "weight": "250g",
    "connectivity": "Bluetooth 5.2"
  },
  "inStock": true
}
```

Notice a few things: you've got strings, numbers, booleans, arrays, and nested objects all living together. Cosmos DB is perfectly happy with all of this. The `categoryId` field here might serve as the partition key, but we'll get to that shortly.

### System-Generated Properties

When Cosmos DB stores your item, it adds several system properties that you'll see when you read the item back. These all start with an underscore:

```json
{
  "id": "product-1042",
  "categoryId": "electronics",
  "name": "Wireless Noise-Canceling Headphones",
  "_rid": "d9RzAJRFKsd8AAAAAAAAAA==",
  "_self": "dbs/d9RzAA==/colls/d9RzAJRFKsc=/docs/d9RzAJRFKsd8AAAAAAAAAA==/",
  "_etag": "\"0000d98e-0000-0100-0000-64a5c3f20000\"",
  "_ts": 1688650738
}
```

Here's what each one does:

| Property | Purpose |
|----------|---------|
| `_rid` | A system-generated, unique resource identifier. Used internally for navigation. |
| `_self` | An addressable URI for the item within the REST API. |
| `_etag` | An entity tag used for optimistic concurrency control. Changes every time the item is updated. |
| `_ts` | A Unix timestamp of the item's last modification. |

There's also a `_lsn` (log sequence number) that shows up in change feed payloads, but you won't see it in normal reads. You don't set or modify any of these properties — Cosmos DB manages them for you.

A quick note on the `id` property: while it's not underscored like the system properties, it occupies a special role. Every item **must** have an `id`, and it must be unique within its logical partition. If you don't provide one, some SDKs will auto-generate a GUID — but in practice, you'll want to assign meaningful IDs yourself (like `"order-5001"` or `"user-jane"`).

### When You'll Actually Use These Properties

In day-to-day development, here's when each property matters:

- **`id`** — Every point read requires it (along with the partition key). It's how you address a specific item. Choose IDs that are meaningful to your domain rather than relying on auto-generated GUIDs.
- **`_etag`** — Essential for **optimistic concurrency control**. Pass it in an `If-Match` header on updates, and Cosmos DB will reject the write if the item has changed since you read it. We'll cover this pattern in depth in Chapter 15.
- **`_ts`** — Useful for lightweight "last modified" logic, audit trails, or ordering items by recency without maintaining a separate timestamp field. It's a Unix epoch timestamp (seconds).
- **`_rid`** and **`_self`** — Primarily used internally by the REST API and older SDKs. You'll rarely interact with these directly in modern SDK code, but they can show up in diagnostics and logs.

### Unique Key Constraints

Before we leave the topic of items and containers, there's one more container-level feature worth understanding: **unique key constraints**. When you create a container, you can define a unique key policy that enforces uniqueness of one or more property paths *within each logical partition*.

For example, if you're building a user management system partitioned by `tenantId`, you might want to guarantee that no two users in the same tenant have the same `email`:

```json
{
  "uniqueKeyPolicy": {
    "uniqueKeys": [
      { "paths": ["/email"] }
    ]
  }
}
```

A few important rules to know:

- **Scoped to the logical partition.** Two items in *different* partitions can have the same email — the constraint only enforces uniqueness within a single partition key value.
- **Immutable after creation.** You set the unique key policy when you create the container, and you cannot change it afterward. If you need a different policy, you'll need to create a new container and migrate data.
- **Composite unique keys are supported.** You can combine multiple paths into a single constraint (e.g., `/firstName` + `/lastName` + `/email`) — up to 16 paths per key and 10 unique key constraints per container.
- **Sparse keys aren't supported.** If a property is missing from an item, it's treated as `null`, and only one item per partition can have `null` for that unique key.
- **Slight RU overhead.** Writes to containers with unique key policies cost slightly more RUs because of the additional uniqueness check.

Unique key constraints are different from the `id` property: `id` is always unique within a partition, but it's just one field. Unique keys let you enforce business-level uniqueness rules on *any* combination of properties.

### Schema Flexibility: Power and Responsibility

Schema flexibility is one of Cosmos DB's greatest strengths and, if you're not careful, one of its biggest pitfalls. There's nothing stopping you from storing a `Product` item next to an `Order` item in the same container. In fact, this is a common and recommended pattern when those items share a partition key (say, `customerId`). You distinguish item types by including a `type` or `discriminator` property:

```json
{ "id": "order-5001", "customerId": "cust-42", "type": "order", "total": 149.99 }
{ "id": "cust-42",    "customerId": "cust-42", "type": "customer", "name": "Jane" }
```

The tradeoff is that **your application becomes responsible for schema validation**. Cosmos DB won't reject a document just because it's missing a field your app expects. Use your SDK's serialization layer, or a schema validation library, to enforce structure in your application code.

## Request Units: The Universal Currency

This is probably the single most important concept to internalize when working with Cosmos DB. Every operation you perform — reads, writes, queries, stored procedure executions — costs a certain number of **Request Units (RUs)**. An RU is a blended measure of CPU, IOPS, and memory consumed by that operation. You don't think about individual hardware resources; you think about RUs.

The foundational benchmark is this:

> **A point read of a single 1 KB item by its `id` and partition key costs 1 RU.**

Everything else is measured relative to that baseline.

### How RUs Are Calculated

Here's a practical reference table for common operations on a 1 KB item with typical indexing:

| Operation | Approximate RU Cost | Notes |
|-----------|-------------------|-------|
| Point read (by `id` + partition key) | **1 RU** | The cheapest operation you can do |
| Create (insert) an item | **~5.5 RUs** | Includes writing the item and updating indexes |
| Replace / update an item | **~10 RUs** | Cost depends on how many properties change |
| Delete an item | **~5 RUs** | |
| Query (indexed, ≤100 results) | **~10 RUs** | Varies widely based on query complexity |

These are *estimates* for a 1 KB item with fewer than five indexed properties. Actual costs depend on several factors:

- **Item size**: Larger items cost more. A 10 KB point read costs roughly 3 RUs, not 1 — RU cost scales sub-linearly with document size.
- **Property count and indexing**: More indexed properties means more work on writes.
- **Query complexity**: Cross-partition fan-out queries, queries with multiple filters, or queries returning large result sets will cost significantly more. A complex analytical query could easily consume hundreds or thousands of RUs.
- **Consistency level**: Reads at Strong or Bounded Staleness consistency cost roughly twice as much as reads at Session or Eventual consistency, because the system must contact more replicas.

Every SDK response includes a header with the exact RU charge for that operation. In the .NET SDK, for example, you access it via `response.RequestCharge`. Always check this during development — it's the most reliable way to understand your costs.

### Why Thinking in RUs Matters

You provision throughput in RU/s (Request Units per second). If you provision 1,000 RU/s on a container, that means you can execute roughly 1,000 one-KB point reads per second, or about 200 one-KB writes per second, or some mix in between.

If your operations exceed the provisioned throughput, Cosmos DB responds with an HTTP 429 ("Too Many Requests") status and tells you how long to wait before retrying. The SDKs handle this automatically with built-in retry logic, but sustained 429s mean you've underprovisioned — you're either burning money on inefficient queries or you need to scale up.

This model has a profound implication: **the cost of every API call is knowable and deterministic.** You can profile your workload, predict your bill, and make informed optimization decisions. That's not something you get with most databases. The flip side is that you *must* think about RU cost. A poorly designed query that scans an entire container will drain your budget fast.

There are three provisioning modes to choose from:

- **Manual throughput**: You set a fixed RU/s value (minimum 400 RU/s per container). You pay for this whether you use it or not.
- **Autoscale**: You set a maximum RU/s, and Cosmos DB scales between 10% of that maximum and the full value based on demand. Useful for variable workloads.
- **Serverless**: No provisioning at all. You pay per RU consumed. Great for development, low-traffic workloads, or bursty applications, but with some limitations (no global distribution, no shared throughput databases).

## Automatic Indexing: Everything Is Indexed by Default

Here's something that surprises developers coming from relational databases or even MongoDB: **Cosmos DB automatically indexes every property of every item, by default.** You don't need to declare indexes up front. You don't need to know your query patterns at design time. You just write data, and the index is there waiting when you query it.

The default indexing policy looks like this:

```json
{
  "indexingMode": "consistent",
  "includedPaths": [{ "path": "/*" }],
  "excludedPaths": [{ "path": "/\"_etag\"/?" }]
}
```

That `/*` path means "index everything." The `_etag` system property is excluded by default since you rarely query on it.

The indexing mode `consistent` means the index is updated synchronously with every write. Your reads always see a fully up-to-date index. There's also a `none` mode that disables indexing entirely — useful when you're using a container purely as a key-value store where you only do point reads, never queries.

### Why Would You Customize Indexing?

The automatic indexing overhead is modest — typically around **10–20%** of your item size in additional storage. But it also adds RU cost to every write, because every write has to update the index. If you have properties you never query on — say, a large `description` text field or a `metadata` blob — you can exclude them from indexing to reduce both storage and write RU costs.

The customization is done through include/exclude paths in the indexing policy:

```json
{
  "indexingMode": "consistent",
  "includedPaths": [{ "path": "/*" }],
  "excludedPaths": [
    { "path": "/\"_etag\"/?" },
    { "path": "/largeDescription/?" },
    { "path": "/internalMetadata/*" }
  ]
}
```

You can also go the other way — start with nothing indexed and opt in to specific paths. The general recommendation from Microsoft is to start with the default (index everything) and exclude paths as needed. This way, any new property you add to your data model is automatically indexed without intervention.

## The Logical Partition: Cosmos DB's Fundamental Unit of Scale

If Request Units are the most important *cost* concept, then the **partition key** is the most important *design* concept. Every container requires a partition key — a property path you choose when you create the container — and every item's partition key value determines which **logical partition** that item belongs to.

A logical partition is simply the set of all items that share the same partition key value. For example, if your partition key is `/categoryId`, then all items with `"categoryId": "electronics"` live in one logical partition, and all items with `"categoryId": "clothing"` live in another.

Logical partitions matter for three reasons:

1. **Transaction scope**: Multi-item transactions (via stored procedures, triggers, or the transactional batch API) can only operate on items within a single logical partition.
2. **Query efficiency**: Queries that include the partition key in the `WHERE` clause can be routed directly to the correct partition. Queries that don't must fan out across all partitions (called a *cross-partition query*), which is significantly more expensive.
3. **Storage and throughput limits**: Each logical partition has a maximum data size of **20 GB** and a maximum throughput of **10,000 RU/s**. If you pick a partition key that funnels too much data into a single value, you'll hit these limits.

Choosing a good partition key means finding a property with **high cardinality** (many distinct values) that aligns with your most common access patterns. Once you create a container, the partition key can't be changed — you'd need to migrate your data to a new container. This is one of the few decisions in Cosmos DB that's hard to undo, so take it seriously. We'll cover partition key strategy in depth in a later chapter.

If your data model requires you to exceed the 20 GB logical partition limit, consider **hierarchical partition keys**. This feature allows up to three levels of partition key paths (for example, `/tenantId`, `/userId`, `/sessionId`), enabling finer-grained data distribution while still supporting efficient single-partition queries on the top-level key.

## Physical vs. Logical Partitions Explained

Logical partitions are your abstraction. Physical partitions are Cosmos DB's reality. Understanding the distinction helps you reason about performance and scale.

A **physical partition** is an internal unit of storage and compute. Each physical partition:

- Can store up to **50 GB** of data
- Can handle up to **10,000 RU/s** of throughput
- Contains one or more logical partitions
- Is managed entirely by Cosmos DB — you can't see or control physical partitions directly

When you create a small container with 400 RU/s, it starts on a single physical partition. As your data grows or you increase throughput, Cosmos DB automatically splits physical partitions to accommodate. This is invisible to your application.

Here's how the mapping works:

```
Physical Partition 1 (up to 50 GB, up to 10,000 RU/s)
  ├── Logical Partition: categoryId = "electronics"
  ├── Logical Partition: categoryId = "clothing"
  └── Logical Partition: categoryId = "books"

Physical Partition 2 (up to 50 GB, up to 10,000 RU/s)
  ├── Logical Partition: categoryId = "home"
  ├── Logical Partition: categoryId = "sports"
  └── Logical Partition: categoryId = "toys"
```

Cosmos DB uses **hash-based partitioning** — it hashes your partition key value and uses that hash to determine which physical partition stores the data. Provisioned throughput is divided evenly across physical partitions. If you have 18,000 RU/s and three physical partitions, each physical partition gets 6,000 RU/s.

This is where the concept of "hot partitions" comes in. If one partition key value receives a disproportionate share of traffic, it will exhaust its physical partition's throughput budget while the other partitions sit idle. The result: 429 throttling even though your *aggregate* throughput is well below what you provisioned. This is the single most common performance mistake in Cosmos DB.

**Key takeaway**: A logical partition can never span multiple physical partitions. But a single physical partition can (and usually does) hold many logical partitions. Focus on choosing a partition key that distributes data and requests *evenly* across logical partitions, and the physical partition management will take care of itself.

## Replica Sets and High Availability Within a Region

Each physical partition doesn't store just a single copy of your data. Internally, it maintains a **replica set** — a group of replicas (at least four) that collectively manage the data for that partition. One replica is the leader (handling writes), and the others serve reads and provide redundancy.

This architecture gives you:

- **Durability**: Your data is written to multiple replicas before being acknowledged.
- **High availability**: If one replica fails, the others continue serving requests. Azure Cosmos DB guarantees an RTO (Recovery Time Objective) of 0 and an RPO (Recovery Point Objective) of 0 for individual node outages — no data loss, no downtime.
- **Consistency**: The replica set implements the various consistency levels (Strong, Bounded Staleness, Session, Consistent Prefix, Eventual) that we'll explore in a later chapter.

Within a single Azure region, you get a **99.99% availability SLA** (about 52 minutes of allowed downtime per year). Enable **availability zones** (which spread replicas across physically separate datacenters within the region) and that jumps to **99.995%**. Add a second region and you reach **99.999%** for reads — five nines.

The important thing to remember: this replication is invisible to you. You read and write to a single endpoint, and Cosmos DB handles replica coordination, failover, and quorum management behind the scenes. Smaller containers that only need a single physical partition still get at least four replicas.

## Service Limits and Quotas

Every cloud service has limits, and Cosmos DB is no exception. Knowing these numbers helps you design within the boundaries and avoid surprises in production. Here are the ones that matter most:

### Per-Item Limits

| Limit | Value |
|-------|-------|
| Maximum item size | **2 MB** (UTF-8 length of JSON representation) |
| Maximum `id` length | **1,023 bytes** |
| Maximum partition key value length | **2,048 bytes** (101 bytes without large partition keys enabled) |
| Maximum nesting depth | **128 levels** of embedded objects/arrays |
| Maximum number of properties | No practical limit |
| Maximum TTL value | **2,147,483,647** (max 32-bit integer) |

### Per-Container / Database Limits

| Limit | Value |
|-------|-------|
| Maximum RU/s per container (dedicated) | **1,000,000 RU/s** (higher by request) |
| Maximum RU/s per database (shared) | **1,000,000 RU/s** (higher by request) |
| Maximum RU/s per physical partition | **10,000 RU/s** |
| Maximum storage per logical partition | **20 GB** |
| Maximum storage per physical partition | **50 GB** |
| Maximum storage per container | **Unlimited** (scales via partition splits) |
| Minimum RU/s (manual throughput) | **400 RU/s** |

### Per-Request Limits

| Limit | Value |
|-------|-------|
| Maximum request size | **2 MB** |
| Maximum response size (single page) | **4 MB** |
| Maximum execution time (single operation) | **5 seconds** |
| Maximum operations in transactional batch | **100** |

The 2 MB item size limit is the one you'll bump into most often if you're not careful. If you're storing large blobs of text or embedded arrays that grow unboundedly, you'll need to model your data to keep items under this ceiling — typically by splitting large data into separate items and referencing them. We'll cover data modeling strategies in a later chapter.

## The Cosmos DB Emulator for Local Development

You don't need an Azure subscription to start building with Cosmos DB. The **Azure Cosmos DB emulator** provides a local instance that mimics the cloud service on your development machine. It's a real database engine — not a mock — and it reports accurate RU charges for your operations, which is invaluable for cost estimation during development.

### Getting Started with the Emulator

The emulator ships as a Windows application (with a Linux preview available) and exposes the same REST API and SDK endpoints as the cloud service. Once running, you connect to it using the well-known default credentials:

| Setting | Value |
|---------|-------|
| Endpoint | `https://localhost:8081` |
| Account Key | `C2y6yDjf5/R+ob0N8A7Cgv30VRDJIWEHLM+4QDU5DE2nQ9nDuVTqobD4b8mGGyPMbIZnqyMsEcaGQy67XIw/Jw==` |

Your code can switch between the emulator and the cloud service by simply changing the connection string — no code changes required.

### Emulator Limitations

The emulator is designed for development and testing, not production. Keep these constraints in mind:

- **Throughput**: Supports up to 10 fixed-size containers at 400 RU/s, or 5 unlimited-size containers. Performance will degrade beyond that.
- **Consistency**: Only supports Session and Strong consistency levels. It doesn't actually implement distributed consistency — it just flags the configured level for testing purposes.
- **No geo-replication**: You can't simulate multi-region distribution. Only a single running instance is supported.
- **No serverless mode**: The emulator only supports provisioned throughput.
- **Data Explorer**: The built-in Data Explorer UI is only fully supported for the NoSQL and MongoDB APIs.
- **Item ID limit**: The emulator constrains item IDs to 254 characters (versus 1,023 bytes in the cloud service).

Despite these limitations, the emulator is the recommended way to develop locally. It saves you real money during the development cycle, gives you accurate RU feedback, and lets you iterate without network latency. Download it from the Azure Cosmos DB documentation or install it via Docker.

## What's Next

You now have a solid understanding of how Cosmos DB is structured, how it charges you, and how it scales under the hood. In **Chapter 3**, we'll put this knowledge to work. You'll create your first Cosmos DB account, set up a database and container, and start reading and writing data using the .NET SDK. We'll also explore the Azure portal's Data Explorer and see Request Units in action on real operations.
