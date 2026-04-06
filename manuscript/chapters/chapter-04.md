# Chapter 4: Thinking in Documents

If you've spent your career with relational databases, your brain has been trained to do one thing instinctively: normalize. See a repeating group? Extract it into a separate table. See a many-to-one relationship? Add a foreign key. See redundant data? Eliminate it. Those instincts served you well in a world of predefined schemas, powerful JOINs, and ACID transactions that span any number of tables.

Cosmos DB is a different world. And the data modeling instincts that made you successful in SQL Server or PostgreSQL will, if left unchecked, produce designs that are slow, expensive, and painful to work with here. This chapter is about rewiring those instincts — not abandoning relational thinking entirely, but learning when it applies and when it doesn't.

## The Shift from Relational to NoSQL Thinking

In a relational database, you model your data first and figure out your access patterns later. The schema is the source of truth; the queries adapt. Normalization ensures data integrity, and the query optimizer figures out how to assemble the pieces at read time via JOINs.

In Cosmos DB, you flip that. **Your access patterns drive your data model.** You start by listing the reads and writes your application performs, then design your documents to serve those operations as cheaply as possible. The data model is in service of the workload, not the other way around.

This inversion has a few concrete consequences:

- **There are no JOINs across documents.** Cosmos DB's `JOIN` keyword exists, but it's an intra-document operation that unfolds arrays within a single item (Chapter 8 covers this). There's no equivalent of `SELECT ... FROM orders JOIN customers ON ...`. If your application needs data from two separate items, that's two separate reads — two round trips, two RU charges.
- **Transactions are scoped to a single logical partition.** You can do multi-item ACID transactions via transactional batch or stored procedures, but only within one partition key value. There's no distributed transaction coordinator spanning partitions or containers.
- **Reads are far more common than writes for most workloads.** Optimizing for read performance — even if it means doing a little extra work on writes — is usually the right trade-off.

The upshot: in a relational database, you normalize aggressively and pay the cost at query time (JOINs). In Cosmos DB, you **denormalize strategically** and pay the cost at write time (keeping copies in sync). The question isn't *whether* to denormalize — it's *how much* and *where*.

## Embedding vs. Referencing: The Core Trade-Off

Every relationship in your data model comes down to a single decision: do you **embed** the related data inside the parent document, or do you store it as a separate item and **reference** it by ID?

This is the most important modeling decision you'll make in Cosmos DB, and it's one you'll revisit for every relationship in your domain. There's no universal answer — it depends on how the data is accessed, how it grows, and how often it changes. Let's build the decision framework.

### Embedding: One Document, One Read

**Embedding** means storing related data as nested objects or arrays inside a single document. When you read the parent, you get everything in one operation — one point read, one RU charge.

Here's a customer profile with embedded addresses:

```json
{
  "id": "cust-337",
  "type": "customer",
  "firstName": "Priya",
  "lastName": "Kapoor",
  "email": "priya@example.com",
  "addresses": [
    {
      "label": "home",
      "street": "742 Evergreen Terrace",
      "city": "Seattle",
      "state": "WA",
      "zip": "98101"
    },
    {
      "label": "work",
      "street": "200 Tower Ave",
      "city": "Bellevue",
      "state": "WA",
      "zip": "98004"
    }
  ],
  "loyaltyTier": "gold"
}
```

In a relational database, you'd have a `Customers` table and an `Addresses` table with a foreign key. Loading a customer's profile with their addresses would require a JOIN. Here, it's a single point read — provide the `id` and partition key, and you get everything back for roughly 1 RU (depending on document size).

In your .NET code, this maps directly to a class with a nested list:

```csharp
public class Customer
{
    public string Id { get; set; }
    public string Type { get; set; }
    public string FirstName { get; set; }
    public string LastName { get; set; }
    public string Email { get; set; }
    public List<Address> Addresses { get; set; }
    public string LoyaltyTier { get; set; }
}

public class Address
{
    public string Label { get; set; }
    public string Street { get; set; }
    public string City { get; set; }
    public string State { get; set; }
    public string Zip { get; set; }
}
```

One point read, one deserialized object, addresses included — no joins, no second query.

<!-- Source: model-data-for-partitioning/modeling-data.md -->

That's the power of embedding. But it's not free — you're trading read simplicity for coupling. If addresses were shared across entities (say, a shipping address linked to both a customer and an order), embedding creates redundant copies that you'd need to update in multiple places.

### When to Embed

Embed related data when these conditions are true: <!-- Source: model-data-for-partitioning/modeling-data.md -->

- **The relationship is "contained."** The child data has no meaning outside the parent. Addresses belong to a customer. Line items belong to an order. They don't exist independently.
- **The relationship is one-to-few.** A customer with 2–3 addresses, an order with 5–10 line items, a product with a handful of reviews. The embedded array has a natural, practical upper bound.
- **The data is read together.** Every time you load the parent, you need the children too. If your UI always shows a customer's addresses alongside their profile, embedding is a perfect fit.
- **The child data changes infrequently.** Addresses don't change every minute. Line items are written once when the order is placed. If the embedded data were updated constantly by independent processes, embedding would mean rewriting the entire parent document on every change.
- **The embedded data doesn't grow without bound.** This is the critical constraint. An array that can grow indefinitely will eventually push the document past the **2 MB item size limit** — and long before you hit that wall, you'll feel the pain of increasing RU costs on every read and write as the document bloats.

<!-- Source: manage-your-account/enterprise-readiness/concepts-limits.md (2 MB maximum item size, UTF-8 length of JSON representation) -->

When all five conditions hold, embedding is almost always the right call. You get atomic reads, atomic writes, and a data model that maps naturally to how your application thinks about the entity.

### Referencing: Separate Documents, Linked by ID

**Referencing** means storing related data as separate items, with one item holding the ID (or partition key + ID) of the other. It's the NoSQL equivalent of a foreign key — except there's no constraint enforcement. The database won't stop you from writing a dangling reference.

Here's the same customer, but with orders stored as separate items:

```json
{
  "id": "cust-337",
  "type": "customer",
  "firstName": "Priya",
  "lastName": "Kapoor",
  "email": "priya@example.com"
}

{
  "id": "order-2001",
  "type": "order",
  "customerId": "cust-337",
  "status": "shipped",
  "orderDate": "2025-03-15T08:30:00Z",
  "lineItems": [
    { "sku": "WIDGET-A", "quantity": 3, "unitPrice": 12.99 },
    { "sku": "GADGET-B", "quantity": 1, "unitPrice": 49.99 }
  ],
  "total": 88.96
}

{
  "id": "order-2002",
  "type": "order",
  "customerId": "cust-337",
  "status": "pending",
  "orderDate": "2025-04-01T14:15:00Z",
  "lineItems": [
    { "sku": "DOOHICKEY-C", "quantity": 2, "unitPrice": 24.50 }
  ],
  "total": 49.00
}
```

Notice that the line items are *embedded* within each order (one-to-few, always read together), but the orders themselves are *referenced* from the customer (one-to-many, grow over time, often queried independently). This hybrid approach — embedding within a level, referencing across levels — is the norm in well-designed Cosmos DB data models.

<!-- Source: model-data-for-partitioning/modeling-data.md -->

### When to Reference

Use references when any of these apply: <!-- Source: model-data-for-partitioning/modeling-data.md -->

- **The relationship is one-to-many or many-to-many.** A customer could have hundreds or thousands of orders. Embedding them all would bloat the customer document beyond usability.
- **The related data is unbounded.** Blog comments, IoT telemetry readings, transaction logs — anything where you can't predict or control the count. Unbounded arrays are the single most common anti-pattern in document databases.
- **The child data changes independently.** An order's status changes from "pending" to "shipped" without touching the customer profile. If the child is updated by a different process or at a different frequency than the parent, referencing avoids rewriting the parent on every child update.
- **The child data is accessed independently.** You query orders by date range, by status, by fulfillment center — without needing the customer profile. If the child has its own access patterns, it deserves its own item.
- **The related data changes frequently and is shared across many items.** The stock portfolio example is classic: if you embed current stock prices into every portfolio document, a single stock trade forces you to update thousands of portfolios. Store the stock as a separate item and reference it by symbol.

The cost of referencing is extra reads. To display "Customer Priya Kapoor and her 5 most recent orders," you need one read for the customer and a query for the orders — at minimum two operations. That's more RUs and more latency than a single embedded document. But for unbounded or independently accessed data, the alternative (a monolithic, ever-growing document) is worse.

### The Decision Framework

Here's the cheat sheet. For every relationship in your model, ask these questions:

| Question | Yes → | No → |
|----------|-------|------|
| Always read with parent? | Embed | Reference |
| Count bounded & small (<20)? | Embed | Reference |
| Changes independently? | Reference | Embed |
| Can grow without bound? | Reference | Embed |
| Shared across parents? | Reference | Embed |
| Combined doc under 2 MB? | Embed | Ref. or chunk |

When the answers conflict — the data is read together *and* grows without bound — you'll use a hybrid approach. Embed a summary or the N most recent items and reference the full collection. The docs call this a "hybrid data model," and it's the pragmatic middle ground for many real-world scenarios. <!-- Source: model-data-for-partitioning/modeling-data.md -->

Here's what that hybrid looks like for blog posts with comments:

```json
{
  "id": "post-5001",
  "type": "post",
  "title": "Why Partition Keys Matter",
  "content": "...",
  "authorId": "user-42",
  "authorName": "Alex Chen",
  "commentCount": 347,
  "recentComments": [
    { "id": "c-9901", "author": "Jordan", "text": "Great post!", "date": "2025-04-10T09:00:00Z" },
    { "id": "c-9902", "author": "Sam", "text": "Saved me hours.", "date": "2025-04-10T08:45:00Z" },
    { "id": "c-9903", "author": "Taylor", "text": "What about HPKs?", "date": "2025-04-10T08:30:00Z" }
  ]
}
```

The post embeds the three most recent comments for display on a "post summary" page. The full 347 comments live as separate items, queryable by `postId`. The `commentCount` is a denormalized aggregate, updated on each new comment. This pattern gives you fast reads for the common case (show the post with a preview of recent comments) and scalable access to the full comment list when needed.

<!-- Source: model-data-for-partitioning/real-world-examples/model-partition-example.md (blog example with denormalized counts and hybrid embedding) -->

## Denormalization as a Feature, Not a Flaw

If you've internalized the relational mantra — "every fact in one place" — denormalization feels like cheating. Storing the author's name on a post *and* in the user profile? That's redundant data. That's a maintenance risk. That's *wrong*.

Except it isn't. Not here.

In a relational database, denormalization is a calculated compromise — you trade data integrity risk for read performance, and the JOIN capability is always there as a fallback. In Cosmos DB, denormalization isn't a compromise. It's the *primary mechanism* for efficient reads. Without JOINs across documents, the only way to avoid multiple round trips is to put the data where it's needed.

The docs put it simply: "Denormalizing data might reduce the number of queries and updates your application needs to complete common operations." <!-- Source: model-data-for-partitioning/modeling-data.md --> That's an understatement. The Microsoft documentation walks through a blogging platform — users, posts, comments, likes — and iterates from a fully normalized model (V1) to a denormalized one (V3). The results are striking.

Consider the operation "list a user's posts in short form" — the kind of query that runs every time someone visits a profile page. In the normalized V1 model, each post is a bare document: no author name, no comment count, no like count. To display a post summary, the application has to query for the user's posts (a fan-out across partitions, since posts aren't partitioned by `userId`), then issue *additional queries per post* to look up the author's username, count comments, and count likes. The result: **130 ms and 619 RU** for a single page load. <!-- Source: model-data-for-partitioning/real-world-examples/model-partition-example.md -->

In the denormalized V3 model, the author's username, comment count, and like count are embedded directly on each post item, and a copy of the user's posts is maintained in a `users` container partitioned by `userId`. Now the same operation is a single-partition query: **4 ms and 6.46 RU**. <!-- Source: model-data-for-partitioning/real-world-examples/model-partition-example.md -->

That's a 97% reduction in latency and a 99% reduction in RU cost — from a design change, not a hardware upgrade. The full walkthrough is worth reading (search for "model and partition data using a real-world example" in the Azure Cosmos DB documentation), but the takeaway is simple: denormalization isn't a compromise in Cosmos DB. It's how you build fast, cheap reads.

### What You're Actually Trading

Denormalization trades **write complexity for read simplicity**. When you duplicate the author's name on every post, you get instant reads — but if the author changes their name, you need to update every post, comment, and like that carries that username.

This is a real cost. But it's a manageable one:

- **Many denormalized values rarely change.** Author names, product categories, country codes — these are updated infrequently enough that the occasional multi-document update is trivial.
- **When values do change, the change feed handles propagation.** Cosmos DB's change feed (Chapter 15) lets you react to updates in one container and push the changes to denormalized copies in other containers — or even other items in the same container. It's the engine that makes denormalization sustainable at scale.
- **Precalculated aggregates save reads.** Storing `commentCount: 347` on the post means you never have to run `SELECT COUNT(*) FROM c WHERE c.postId = 'post-5001'` at read time. You pay one increment on each write; you save one aggregation query on every read. For read-heavy workloads, that's a massive win.

> **Gotcha:** Denormalization without a strategy for keeping copies in sync is a recipe for stale data. Before you duplicate a value, answer two questions: *How often does this value change?* and *What mechanism will propagate changes?* If you can't answer both, don't denormalize — reference instead.

### The Relational Safety Net You Don't Have

In a relational database, foreign keys enforce referential integrity. Delete a customer, and the database can cascade-delete their orders or reject the operation. Cosmos DB has no such mechanism. References between documents are "weak links" — the database doesn't validate that a `customerId` in an order actually points to an existing customer item. <!-- Source: model-data-for-partitioning/modeling-data.md -->

This means referential integrity is your application's responsibility. You enforce it through:

- **Application-level validation** before writes.
- **Stored procedures or transactional batches** for operations that must be atomic within a partition.
- **Change feed processors** for cross-partition or cross-container consistency.

Chapter 15 covers the change feed in depth, including patterns for propagating denormalized data. For now, just know that the tool exists and it's how serious Cosmos DB applications keep their denormalized data consistent.

## Handling Polymorphic Data and Schema Evolution

Cosmos DB is **schema-agnostic**. There's no `CREATE TABLE` with fixed columns, no `ALTER TABLE ADD COLUMN` migration. Every item is a self-contained JSON document, and two items in the same container can have completely different shapes. This flexibility is one of Cosmos DB's genuine strengths — and one of its sharpest footguns.

### Polymorphic Data and Type Discriminators

It's common — and encouraged — to store multiple entity types in a single container. A `posts` container might hold post items, comment items, and like items, all sharing the same partition key (`postId`) so they live in the same logical partition and can be transacted together.

When you do this, you need a way to tell the types apart. The standard pattern is a **type discriminator field**: <!-- Source: model-data-for-partitioning/modeling-data.md -->

```json
{
  "id": "post-5001",
  "type": "post",
  "postId": "post-5001",
  "title": "Why Partition Keys Matter",
  "content": "..."
}

{
  "id": "comment-9901",
  "type": "comment",
  "postId": "post-5001",
  "authorName": "Jordan",
  "text": "Great post!"
}

{
  "id": "like-3301",
  "type": "like",
  "postId": "post-5001",
  "userId": "user-88"
}
```

The `type` field lets you filter queries to a specific entity type (`SELECT * FROM c WHERE c.type = 'comment' AND c.postId = 'post-5001'`), deserialize to the right class in your application code, and reason about the container's contents without guessing. Chapter 6 goes deep on the **item type pattern** and the advanced modeling strategies that build on it.

### Schema Evolution

Schemas evolve. You ship v1 with a `shippingAddress` as a flat set of fields. Six months later, you need to support international addresses with a `countryCode` and a `postalCodeFormat`. In a relational database, you'd run `ALTER TABLE` and backfill data. In Cosmos DB, you handle it differently.

The fundamental approach is **additive evolution**: add new properties, but don't remove or rename existing ones until all readers can handle the change. Since Cosmos DB doesn't enforce a schema, old items without the new property simply return `undefined` (or `null`) for that field. Your application code needs to handle that gracefully.

Here are the core strategies:

**Add new properties with defaults.** When your code reads an item that predates the change, treat a missing `countryCode` as `"US"` (or whatever your default is). No migration needed — new items carry the property, old items rely on the application default.

**Use a version field.** Add a `schemaVersion` property to each item. When your application reads an item, it checks the version and handles the differences:

```json
{
  "id": "order-2001",
  "type": "order",
  "schemaVersion": 2,
  "shippingAddress": {
    "street": "742 Evergreen Terrace",
    "city": "Seattle",
    "state": "WA",
    "zip": "98101",
    "countryCode": "US"
  }
}
```

Items at `schemaVersion: 1` might have `zip` but no `countryCode`. Your deserialization logic routes accordingly.

**Lazy migration.** When you read a v1 item, transform it to v2 in memory. If the operation also writes (upsert, update), the item is saved in the new format. Over time, active items migrate themselves. Stale items stay in v1 until they're touched — or until you run a batch migration.

**Batch migration for breaking changes.** Sometimes you need to transform every item — renaming a property, restructuring nested objects, changing a partition key value. For these, you'll read items in bulk, transform them, and write them back. The Cosmos DB SDKs support bulk execution mode for this (Chapter 7), and the change feed can power continuous migration pipelines. Chapter 20 covers the operational side — CI/CD pipelines, migration scripts, and infrastructure-as-code patterns for managing schema changes across environments.

> **Tip:** Resist the urge to run a "big bang" migration every time you add a field. Additive changes with application-level defaults are cheaper, safer, and cause zero downtime. Reserve batch migrations for genuine breaking changes.

## Common Document Design Patterns

With embedding, referencing, and schema evolution in your toolkit, let's look at the structural patterns you'll use most often.

### Subdocuments and Nested Objects

A **subdocument** is a JSON object nested inside a parent document. It's the simplest form of embedding — grouping related fields into a coherent unit.

```json
{
  "id": "product-100",
  "type": "product",
  "name": "Trail Runner Pro",
  "category": "footwear",
  "pricing": {
    "listPrice": 129.99,
    "salePrice": 99.99,
    "currency": "USD"
  },
  "dimensions": {
    "weight": 0.68,
    "weightUnit": "kg",
    "lengthCm": 30
  }
}
```

Subdocuments work well for logically grouped properties that are always read and written as a unit. The `pricing` object here is meaningful only in the context of its product. You'd never query pricing independently of the product, and you'd never share the same pricing object across multiple products.

In your queries, you access nested properties with dot notation: `SELECT c.pricing.salePrice FROM c WHERE c.category = 'footwear'`. Cosmos DB's default indexing policy indexes nested properties automatically, so these queries are efficient out of the box. Chapter 9 covers indexing policies, including how to optimize them for deeply nested structures.

### Arrays of Complex Types

Arrays of objects are the workhorse of embedded data modeling. Line items in an order, tags on a product, skills on a resume — any one-to-few relationship naturally becomes an array of objects.

```json
{
  "id": "order-2001",
  "type": "order",
  "customerId": "cust-337",
  "lineItems": [
    {
      "sku": "WIDGET-A",
      "name": "Standard Widget",
      "quantity": 3,
      "unitPrice": 12.99,
      "subtotal": 38.97
    },
    {
      "sku": "GADGET-B",
      "name": "Deluxe Gadget",
      "quantity": 1,
      "unitPrice": 49.99,
      "subtotal": 49.99
    }
  ],
  "total": 88.96
}
```

A few design guidelines for arrays:

- **Keep them bounded.** If you know an order will never have more than a few hundred line items, the array is fine. If items could number in the thousands, reference instead.
- **Include computed values.** The `subtotal` per line item and the `total` on the order are denormalized calculations. They save you from computing them on every read, and Cosmos DB's query language can still filter or sort on them.
- **Watch the document size.** Each element in the array adds to the document's total size. Ten line items with short descriptions? No problem. A thousand line items with embedded product images? You'll blow past the 2 MB item limit.

You can query into arrays using Cosmos DB's intra-document `JOIN` (which iterates over array elements) and array functions like `ARRAY_CONTAINS`. Chapter 8 covers the syntax in detail.

### Metadata and Type Discriminator Fields

Beyond the `type` discriminator we covered earlier, well-designed documents carry **metadata fields** that support operational concerns:

```json
{
  "id": "order-2001",
  "type": "order",
  "schemaVersion": 2,
  "customerId": "cust-337",
  "status": "shipped",
  "createdAt": "2025-03-15T08:30:00Z",
  "updatedAt": "2025-03-16T14:20:00Z",
  "ttl": 7776000,
  "lineItems": [ ... ]
}
```

- **`type`** — Discriminates entity types within a shared container. Filter queries by type to avoid processing irrelevant items.
- **`schemaVersion`** — Enables safe schema evolution, as discussed above.
- **`createdAt` / `updatedAt`** — Application-managed timestamps for business logic. (Cosmos DB's system `_ts` records the last modification in Unix seconds, but having explicit ISO 8601 timestamps is clearer for application code and reporting.)
- **`ttl`** — Time-to-live in seconds. Cosmos DB automatically deletes the item after this many seconds, measured from the item's last modification time. Chapter 6 covers TTL patterns in depth.

These fields cost a few bytes per document. The operational clarity they provide — for querying, debugging, schema management, and data lifecycle — is worth it every time.

## Anti-Patterns to Avoid

Now for the mistakes. These are the modeling choices that seem reasonable but lead to pain at scale.

### Excessively Large Documents

The hard limit is 2 MB per item (measured as the UTF-8 length of the JSON representation). But you shouldn't get anywhere near it. <!-- Source: manage-your-account/enterprise-readiness/concepts-limits.md -->

Large documents hurt in three ways:

1. **Higher RU cost on every operation.** RU charges scale roughly linearly with item size. A 100 KB point read costs about 10 RU; a 1 KB point read costs about 1 RU (point-read cost is independent of indexing policy). Scale that up to a 1 MB document and the math gets ugly fast — especially if you're reading it frequently. <!-- Source: develop-modern-applications/performance/key-value-store-cost.md -->
2. **Network latency.** Transferring a 1 MB document over the wire takes longer than transferring a 2 KB one. Cosmos DB's single-digit millisecond latency guarantee is for the server-side operation — network transfer time is on top of that.
3. **Write amplification.** If you update one field in a 1 MB document, the entire document is rewritten. (The Patch API, covered in Chapter 6, can mitigate this for specific operations, but the item still needs to be stored and indexed in full.)

> **Gotcha:** System properties (`_rid`, `_self`, `_etag`, `_ts`) are part of the stored JSON representation and count toward the 2 MB limit. They're small, but factor them in when you're calculating document sizes for items that are close to the boundary.

**The fix:** If a document is growing large because of an embedded array, split it. Move the array elements into their own items and reference them. If a document is large because of a big text field or binary data, store the bulk content in Azure Blob Storage and keep a URL reference in the Cosmos DB item.

### Deeply Nested Arrays

Cosmos DB supports nesting up to 128 levels deep — but that's a technical ceiling, not a design target. <!-- Source: manage-your-account/enterprise-readiness/concepts-limits.md --> Deeply nested structures are hard to query, hard to index efficiently, and hard to reason about in application code.

**The fix:** Flatten where possible. Instead of nesting categories three levels deep (`product.category.subcategory.subsubcategory`), use a flat `categoryPath` string (`"electronics/phones/smartphones"`) that you can query with `STARTSWITH`. If you need the hierarchy for navigation, store it as a separate lookup document.

### Unbounded Arrays

We flagged unbounded arrays in the referencing section — here's what the mistake looks like in practice:

```json
{
  "id": "post-5001",
  "type": "post",
  "title": "My Popular Blog Post",
  "comments": [
    { "id": "c-1", "author": "alice", "text": "..." },
    { "id": "c-2", "author": "bob", "text": "..." },
    ...
    { "id": "c-999999", "author": "eve", "text": "..." }
  ]
}
```

**The fix:** Reference the comments as separate items. If you want fast access to a preview, embed a small `recentComments` array (3–5 items) and store the full set separately, as shown in the hybrid model earlier in this chapter.

### One Entity Type Per Container (the "Table-Per-Entity" Trap)

Developers coming from relational databases often create separate containers for each entity type: one for customers, one for orders, one for products. This feels natural but misses a core Cosmos DB optimization: co-locating related items in the same logical partition.

When a customer and their orders share a container with `customerId` as the partition key, you can load them in a single partition query or transactional batch. With separate containers, every cross-entity operation requires multiple container round trips.

The item type pattern — mixing entity types in a single container, distinguished by a `type` field — is the standard approach. Chapter 6 covers this pattern in detail, including strategies for managing indexing policies across heterogeneous item types.

### Treating Cosmos DB Like a Relational Database

This is the meta-anti-pattern. If your data model has 30 "tables" (containers), complex cross-container queries that simulate JOINs, and no denormalization — you're fighting the platform. Cosmos DB will let you do it, but you'll pay in RUs, latency, and complexity.

If your domain genuinely requires complex relational queries, Cosmos DB may not be the right tool. Chapter 1 covered the "poor fit" scenarios honestly. But if your domain is a natural fit for documents — and most modern application backends are — the patterns in this chapter will serve you well.

---

With the mental model for document design in place, the next critical decision is *how to partition that data*. Your partition key choice determines whether your carefully modeled documents can be read and written efficiently at scale — or whether they get trapped behind a hot partition bottleneck. Chapter 5 tackles that decision head-on.
