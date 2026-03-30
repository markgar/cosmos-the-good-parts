# Chapter 6: Advanced Data Modeling Patterns

Chapter 4 taught you to think in documents. Chapter 5 taught you to partition them. Now it's time to put those foundations to work with the patterns that experienced Cosmos DB developers reach for every day — patterns that go beyond simple embedding and referencing into the techniques that make real applications fast, cheap, and maintainable.

Some of these patterns are structural: how you organize multiple entity types in a single container, how you model trees and many-to-many relationships. Others are operational: how you expire data automatically, how you update a single field without replacing an entire document, how you nuke an entire partition's data in one call. All of them assume you've internalized the partition key decision from Chapter 5 — because every pattern here interacts with that choice.

## The Item Type Pattern

If you're coming from relational databases, your instinct is one table per entity: a `Customers` table, an `Orders` table, a `Reviews` table. In Cosmos DB, that instinct leads to a container-per-entity model that's often more expensive and harder to work with than the alternative.

The **item type pattern** stores multiple entity types in the same container, distinguished by a `type` property (or `docType`, `entityType` — pick a name and be consistent). This isn't a hack. It's the recommended approach when entities share a partition key and are frequently accessed together.

<!-- Source: modeling-data.md -->

Here's an e-commerce container partitioned by `customerId`, holding both customer profiles and their orders:

```json
{
  "id": "cust-337",
  "customerId": "cust-337",
  "type": "customer",
  "firstName": "Priya",
  "lastName": "Kapoor",
  "email": "priya@example.com",
  "loyaltyTier": "gold"
}

{
  "id": "order-2001",
  "customerId": "cust-337",
  "type": "order",
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
  "customerId": "cust-337",
  "type": "order",
  "status": "pending",
  "orderDate": "2025-04-01T14:15:00Z",
  "lineItems": [
    { "sku": "DOOHICKEY-C", "quantity": 2, "unitPrice": 24.50 }
  ],
  "total": 49.00
}
```

All three items share the same partition key value (`cust-337`), which means:

- A single partition query can fetch the customer and all their orders in one round trip.
- A transactional batch (Chapter 16) can atomically create an order and update the customer's `loyaltyTier` — impossible if they lived in separate containers.
- You're not paying the overhead of separate containers, each with its own minimum throughput.

### Querying Polymorphic Data

The `type` field is your discriminator. Filter on it to get exactly the entity type you need:

```sql
-- All orders for a customer
SELECT * FROM c WHERE c.customerId = "cust-337" AND c.type = "order"

-- Just the customer profile
SELECT * FROM c WHERE c.customerId = "cust-337" AND c.type = "customer"

-- Everything in the partition (customer + all orders)
SELECT * FROM c WHERE c.customerId = "cust-337"
```

Chapter 8 covers querying in depth, including how to structure queries against containers with mixed item types. Chapter 9 covers indexing policies — which becomes relevant when different entity types have different property shapes and you want to avoid indexing fields that only exist on one type.

### When to Use the Item Type Pattern

Use it when entities share a natural partition key and are frequently accessed together. The customer-orders example is classic. So are:

- **Blog posts and comments** partitioned by `postId`
- **Products and reviews** partitioned by `productId`
- **Devices and telemetry events** partitioned by `deviceId`

Don't force it when entities have no natural affinity. If customers and products have completely different access patterns and no shared partition key, separate containers are fine. The goal is co-location for related data, not cramming everything into one container for the sake of minimalism.

> **Tip:** Choose a consistent name for your type discriminator and stick with it across all containers in your application. Most teams use `type`, and that's what we'll use throughout this book. Whatever you pick, include it in every item — it costs almost nothing in storage and saves you from ambiguous query results.

## The Lookup Pattern with Materialized Views

Sometimes you need to query the same data by different keys. An order might need to be looked up by `customerId` (the partition key) or by `orderDate` for a dashboard. A product might be fetched by `productId` (partition key) or browsed by `categoryId`.

The **lookup pattern** solves this by maintaining a second copy of the data — a **materialized view** — optimized for the alternate access pattern. You create a separate container (or separate items in the same container) with a different partition key, and keep it in sync with the source data.

Here's the idea. Your primary `orders` container is partitioned by `customerId`:

```json
{
  "id": "order-2001",
  "customerId": "cust-337",
  "type": "order",
  "orderDate": "2025-03-15",
  "total": 88.96
}
```

A secondary `ordersByDate` container is partitioned by `orderDate`:

```json
{
  "id": "order-2001",
  "orderDate": "2025-03-15",
  "customerId": "cust-337",
  "type": "orderByDate",
  "total": 88.96
}
```

Now the dashboard query — "show me all orders placed on March 15" — is a single-partition query against the second container instead of a cross-partition fan-out against the first.

The critical question is: *how do you keep the view in sync?* The answer is the **change feed** — Cosmos DB's built-in event stream that emits every insert and update. A change feed processor reads new or modified orders from the primary container and writes the corresponding items to the secondary container. Chapter 15 covers the change feed in depth, including exactly how to build and operate materialized view pipelines. For now, know that this pattern exists and that it's the standard way to support multiple access patterns without expensive cross-partition queries.

> **Gotcha:** Materialized views introduce **eventual consistency** between the source and the view. The change feed processor introduces a small lag — typically milliseconds to low seconds. If your application requires the view to be instantly consistent with the source, this pattern isn't the right fit. For most read-heavy dashboards and search scenarios, the lag is invisible to users.

## Time-to-Live (TTL): Expiring Data Automatically

Data doesn't always need to live forever. Session tokens, shopping carts, audit logs, temporary cache entries, one-time-use invite codes — all of these have a natural lifespan. Instead of building a cleanup job that queries for stale data and deletes it (burning RUs the whole way), you can let Cosmos DB handle it with **time-to-live (TTL)**.

<!-- Source: time-to-live.md -->

TTL lets you set an expiration period on items, measured in seconds from the item's last modified time (`_ts`). When the clock runs out, Cosmos DB deletes the item automatically as a background task — no client-side delete call required.

### How TTL Works

TTL operates at two levels: the **container** and the **item**.

**Container-level TTL** is set via the `DefaultTimeToLive` property and controls the baseline behavior:

| `DefaultTimeToLive` value | Behavior |
|---|---|
| Not set (null) | TTL is **disabled**. Items never expire. Item-level `ttl` properties are ignored. |
| `-1` | TTL is **enabled** but items don't expire by default. Individual items *can* opt in to expiration by setting their own `ttl`. |
| A positive integer *n* | TTL is **enabled**. All items expire *n* seconds after their last modification — unless they override with their own `ttl`. |

<!-- Source: time-to-live.md -->

**Item-level TTL** is set via a `ttl` property on individual items. It only takes effect when the container's `DefaultTimeToLive` is present and not null. When set, it overrides the container default for that specific item.

| Container `DefaultTimeToLive` | Item `ttl` | What happens |
|---|---|---|
| `1000` (seconds) | Not present | Item expires after 1,000 seconds |
| `1000` | `-1` | Item **never** expires |
| `1000` | `2000` | Item expires after 2,000 seconds |
| `-1` | Not present | Item never expires |
| `-1` | `2000` | Item expires after 2,000 seconds |
| Null (not set) | `2000` | Item **never** expires (container TTL disabled; item `ttl` is ignored) |

<!-- Source: time-to-live.md -->

The maximum TTL value is **2,147,483,647 seconds** — approximately 68 years. That's the upper bound of a signed 32-bit integer.

<!-- Source: concepts-limits.md -->

> **Gotcha:** You can't set an item's `ttl` to `null`. The value must be a positive integer, `-1`, or simply absent from the item. If you want an item to use the container default, omit the `ttl` property entirely.

<!-- Source: time-to-live.md -->

### The Deletion Mechanics

Expired items are deleted as a **background task**. There are a few important details here:

1. **Expired items vanish from queries immediately.** Even before the background process physically removes the data, expired items no longer appear in query results. Your application sees a clean view.

2. **Deletions use leftover RUs.** For provisioned throughput accounts, the background deletion process consumes RUs that haven't been used by your application's requests. If your container is running hot — all RUs consumed by normal traffic — expired items won't be physically deleted until there's headroom. They still won't appear in queries, but the storage won't be reclaimed until the deletion catches up.

3. **Serverless accounts are charged for deletions.** Unlike provisioned accounts where TTL deletions ride on leftover capacity, serverless accounts are billed for TTL deletions at the same rate as regular delete operations.

<!-- Source: time-to-live.md -->

### Configuring TTL

You can enable TTL when creating a container or update it later. Here's how to create a container with a 90-day default TTL:

```csharp
ContainerProperties properties = new()
{
    Id = "sessions",
    PartitionKeyPath = "/userId",
    DefaultTimeToLive = 90 * 24 * 60 * 60  // 90 days in seconds
};

Container container = await database.CreateContainerAsync(properties);
```

<!-- Source: how-to-time-to-live.md -->

To enable TTL without a default expiration (allowing individual items to opt in):

```csharp
ContainerProperties properties = new()
{
    Id = "events",
    PartitionKeyPath = "/deviceId",
    DefaultTimeToLive = -1  // Enabled, no default expiration
};
```

And here's an item-level override — a session token that expires in 30 minutes:

```json
{
  "id": "session-abc123",
  "userId": "user-42",
  "type": "session",
  "token": "eyJhbGciOiJIUzI1NiIs...",
  "ttl": 1800
}
```

### Resetting the Clock

TTL is measured from the item's `_ts` (last modified timestamp). Any write or update to the item resets `_ts` to the current time, which restarts the TTL countdown. This is exactly what you want for session management: every time a user makes a request, you touch the session item, and the 30-minute inactivity timer resets.

If you need to change the TTL value itself — say, extending a premium user's session to 60 minutes — update the `ttl` property via a replace or patch operation.

### Practical TTL Patterns

**Session store.** Set container `DefaultTimeToLive` to your inactivity timeout (e.g., 1800 seconds for 30 minutes). Each user request touches the session item, resetting `_ts`. Inactive sessions auto-expire.

**Soft-delete with deferred cleanup.** Instead of hard-deleting items, mark them with a `deleted: true` flag and set `ttl` to a retention period (say, 30 days). This gives you a grace period for recovery while ensuring eventual cleanup. This pattern is especially useful with the change feed — the change feed in latest version mode doesn't capture hard deletes, but it *does* capture the soft-delete update.

**Event log with rolling window.** Set a container-level TTL (e.g., 7 days) for an event log container. Events older than 7 days are automatically purged. No scheduled cleanup job, no stale data accumulation.

**Mixed-TTL entities.** Set container `DefaultTimeToLive` to `-1` (enabled, no default). Then set per-item `ttl` values based on entity type: shopping carts expire in 24 hours (`ttl: 86400`), completed orders never expire (`ttl: -1` or omit the property), and abandoned checkout sessions expire in 1 hour (`ttl: 3600`). This works naturally with the item type pattern.

## Partial Document Update (Patch API)

Imagine you need to increment a product's inventory count by 10. Without the Patch API, here's what your application does:

1. Read the entire document (1 RU for a small item, more for larger ones).
2. Deserialize it into an object.
3. Change the `quantity` field.
4. Serialize and send the entire document back as a Replace operation.
5. If another process modified the document between your read and write, handle the conflict (optimistic concurrency check, retry).

That's a full round trip, the entire document transmitted both directions, and a race condition you have to manage. For a single field change.

The **Patch API** (formally called **partial document update**) lets you send just the change: "increment `/inventory/quantity` by 10." One call, no read required, no full document transmitted. The server applies the change atomically.

<!-- Source: partial-document-update.md -->

### Supported Operations

The Patch API supports six operations, inspired by (but not identical to) JSON Patch RFC 6902:

<!-- Source: partial-document-update.md -->

| Operation | What it does | Behavior if target doesn't exist |
|---|---|---|
| **Add** | Adds a new property, or inserts an element into an array at a given index. If the property already exists, replaces its value. | Creates the property |
| **Set** | Similar to Add, but for arrays: updates the element at the specified index rather than inserting. | Creates the property (except for arrays) |
| **Replace** | Updates the value of an existing property. Strict replace-only semantics. | **Errors** — the target must exist |
| **Remove** | Deletes a property or array element. | **Errors** — the target must exist |
| **Increment** | Increments a numeric field by a specified value (positive or negative). | Creates the field and sets it to the specified value |
| **Move** | Removes a value from one location and adds it to another. | **Errors** if the source doesn't exist; creates the destination if needed |

<!-- Source: partial-document-update.md -->

The practical differences between Add, Set, and Replace matter when you're working with arrays:

- **Add** at an array index *inserts* a new element, shifting existing elements after it. `Add` with the `-` index appends to the end.
- **Set** at an array index *replaces* the existing element at that index.
- **Replace** on an array that doesn't exist will fail. It's the safest option when you expect the property to already be there.

> **Tip:** Use `Replace` when you want to assert that a property exists — it acts as a guard. If someone deleted the field you're trying to update, `Replace` will error rather than silently recreating it.

### Patch in Action

Here's a product document before patching:

```json
{
  "id": "product-100",
  "categoryId": "road-bikes",
  "name": "R-410 Road Bicycle",
  "price": 455.95,
  "inventory": {
    "quantity": 15
  },
  "used": false,
  "tags": ["r-series"]
}
```

A single patch call that combines multiple operations:

```csharp
List<PatchOperation> operations = new()
{
    PatchOperation.Add("/color", "silver"),
    PatchOperation.Remove("/used"),
    PatchOperation.Set("/price", 355.45),
    PatchOperation.Increment("/inventory/quantity", 10),
    PatchOperation.Add("/tags/-", "featured-bikes"),
    PatchOperation.Move("/color", "/inventory/color")
};

ItemResponse<Product> response = await container.PatchItemAsync<Product>(
    id: "product-100",
    partitionKey: new PartitionKey("road-bikes"),
    patchOperations: operations
);
```

<!-- Source: partial-document-update.md, partial-document-update-getting-started.md -->

After patching:

```json
{
  "id": "product-100",
  "categoryId": "road-bikes",
  "name": "R-410 Road Bicycle",
  "price": 355.45,
  "inventory": {
    "quantity": 25,
    "color": "silver"
  },
  "tags": ["r-series", "featured-bikes"]
}
```

Six changes in one atomic operation. No read-modify-write cycle. No conflict to manage.

You can combine up to **10 patch operations** in a single patch specification. If you need more, split them across multiple calls.

<!-- Source: partial-document-update-faq.md -->

### Conditional Patching with Predicates

What if you only want to apply a price change to items that haven't been marked as discontinued? The Patch API supports **conditional updates** via a SQL-like filter predicate:

```csharp
PatchItemRequestOptions options = new()
{
    FilterPredicate = "FROM products p WHERE p.used = false"
};

List<PatchOperation> operations = new()
{
    PatchOperation.Replace("/price", 299.99)
};

ItemResponse<Product> response = await container.PatchItemAsync<Product>(
    id: "product-100",
    partitionKey: new PartitionKey("road-bikes"),
    patchOperations: operations,
    requestOptions: options
);
```

<!-- Source: partial-document-update-getting-started.md -->

If the predicate doesn't match — say `used` is `true` — the operation fails with a precondition failure. The document is untouched. This is server-side conditional logic without the read-check-write round trip.

Conditional patching is powerful for scenarios like:

- **Preventing double-processing:** "Set `status` to `processed` only if it's currently `pending`."
- **Stock management:** "Decrement `quantity` by 1 only if `quantity > 0`."
- **Feature flags:** "Add the `premiumFeatures` property only if `subscriptionTier = 'premium'`."

### Patch in Transactional Batches

Patch operations can participate in transactional batches — multiple operations against items within the same partition key, committed atomically. This is covered in depth in Chapter 16, but here's a taste:

```csharp
TransactionalBatch batch = container.CreateTransactionalBatch(
    partitionKey: new PartitionKey("road-bikes")
);

batch.PatchItem(
    id: "product-100",
    patchOperations: new[] { PatchOperation.Increment("/inventory/quantity", -1) }
);
batch.PatchItem(
    id: "product-200",
    patchOperations: new[] { PatchOperation.Increment("/inventory/quantity", -1) }
);

TransactionalBatchResponse response = await batch.ExecuteAsync();
```

Either both inventory decrements succeed or neither does. Combined with conditional predicates, this gives you atomic, conditional multi-document updates within a partition.

### Patch and Multi-Region Conflict Resolution

If you're running multi-region writes, the Patch API has a significant advantage over full-document Replace. Patch operations resolve conflicts at the **path level**, not the document level. Two concurrent patches to the same document from different regions — one setting `/level` to `"platinum"`, another removing an element from `/phone` — are automatically merged because they target different paths.

<!-- Source: partial-document-update.md -->

With a full Replace, the same scenario would trigger document-level Last Write Wins, and one region's change would be lost. Path-level conflict resolution is a compelling reason to use Patch over Replace in multi-region write configurations.

If two patches target the *same* path from different regions, the regular conflict resolution policies apply (Last Write Wins by default).

### RU Savings

The Patch API avoids sending the full document over the wire and eliminates the read step of a read-modify-write cycle. The per-operation RU cost of a Patch is similar to a Replace — don't expect a dramatically cheaper single call. The real savings come from dropping the read: a Patch is one round-trip instead of two, which cuts the total RU cost roughly in half compared to a read-then-replace. Chapter 10 quantifies this in detail.

### What You Can't Patch

A few constraints to know:

- **System properties** (`_rid`, `_ts`, `_etag`, `_self`) cannot be modified via Patch. These are managed by the service.
- **The `id` and partition key** of an item can't be changed. If you need to change either, you must delete and recreate the item.
- **The `ttl` property *can* be patched.** This is a handy way to extend or shorten an item's lifespan without a full replace.

<!-- Source: partial-document-update-faq.md -->

### When to Use Patch vs. Replace

| Scenario | Use Patch | Use Replace |
|---|---|---|
| Changing 1–2 fields on a large document | ✅ | ❌ Wasteful |
| Incrementing a counter | ✅ Server-side atomic | ❌ Race condition risk |
| Conditional update based on current state | ✅ With filter predicate | ❌ Requires read + ETag check |
| Rewriting most fields on a small document | ❌ Overhead of specifying each op | ✅ Simpler |
| Restructuring the document shape | ❌ May exceed 10-operation limit | ✅ One call |
| Multi-region writes with concurrent changes | ✅ Path-level conflict resolution | ❌ Document-level LWW |

For SDK-specific Patch API syntax in Java, Python, and Node.js, see Chapter 7.

## Working with Large Items

The maximum item size in Cosmos DB is **2 MB**, measured as the UTF-8 length of the JSON representation. That's a hard limit — the service will reject writes that exceed it. And you'll feel the cost of large items long before you hit the ceiling: RU charges scale with document size, so a 500 KB item costs significantly more per read and write than a 5 KB one.

<!-- Source: concepts-limits.md -->

When your data naturally exceeds what fits comfortably in a single item, you have three strategies.

### Strategy 1: Offload Binary Data to Blob Storage

This is the most common case. If your items include images, PDFs, video thumbnails, or any binary payload, don't store them in Cosmos DB. Store them in **Azure Blob Storage** and keep a URL reference in your Cosmos DB item:

```json
{
  "id": "doc-5001",
  "tenantId": "contoso",
  "type": "contract",
  "title": "Master Services Agreement",
  "signedDate": "2025-01-15",
  "documentUrl": "https://contosodocs.blob.core.windows.net/contracts/doc-5001.pdf",
  "thumbnailUrl": "https://contosodocs.blob.core.windows.net/contracts/doc-5001-thumb.png",
  "fileSizeBytes": 2458900
}
```

Cosmos DB handles the structured metadata (fast queries, indexes, partition-aware reads). Blob Storage handles the blob (cheap, unlimited size, CDN-friendly). This is almost always the right answer for binary content.

### Strategy 2: Chunk Large Structured Data

What if the large data isn't binary — it's a massive JSON array? A sensor that produces 50,000 readings per day, a document with a deeply nested regulatory structure, a product with thousands of variant SKUs.

The chunking pattern splits the data into multiple items linked by a shared identifier:

```json
{
  "id": "readings-device42-2025-06-15-chunk-0",
  "deviceId": "device-42",
  "type": "telemetryChunk",
  "date": "2025-06-15",
  "chunkIndex": 0,
  "totalChunks": 5,
  "readings": [
    { "ts": "2025-06-15T00:00:01Z", "temp": 22.1, "humidity": 61 },
    { "ts": "2025-06-15T00:00:02Z", "temp": 22.1, "humidity": 61 }
  ]
}
```

Each chunk stays under the 2 MB limit. To reconstruct the full dataset, query by `deviceId`, `date`, and `type`, ordered by `chunkIndex`. Since all chunks share the same partition key (`deviceId`), this is a single-partition query — fast and cheap.

### Strategy 3: Trim What You Store

Sometimes the answer is simpler: don't store data you don't need. Strip verbose logging fields before writing. Compress or abbreviate repeated values. Store computed summaries instead of raw detail. If your application only ever queries the last 100 readings, don't store all 50,000 in the item — store the last 100 and archive the rest to cold storage or an analytical system (Chapter 22 covers Fabric Mirroring for this).

> **Tip:** Monitor your average item size using Azure Monitor metrics. If items are consistently growing toward 100 KB+, it's time to evaluate whether you're embedding data that should be referenced, or storing blobs that belong in Blob Storage. Every extra kilobyte shows up on your RU bill.

## Modeling Hierarchical and Tree Structures

Organizational charts, category taxonomies, folder structures, nested comment threads — many domains have naturally hierarchical data. There are two common approaches in Cosmos DB.

### Materialized Path

Store each node as a separate item with a `path` property that encodes its position in the tree:

```json
{
  "id": "cat-electronics",
  "type": "category",
  "name": "Electronics",
  "path": "/electronics",
  "depth": 1,
  "parentId": null
}

{
  "id": "cat-laptops",
  "type": "category",
  "name": "Laptops",
  "path": "/electronics/laptops",
  "depth": 2,
  "parentId": "cat-electronics"
}

{
  "id": "cat-gaming-laptops",
  "type": "category",
  "name": "Gaming Laptops",
  "path": "/electronics/laptops/gaming",
  "depth": 3,
  "parentId": "cat-laptops"
}
```

The `path` field makes subtree queries trivial with a `STARTSWITH` function:

```sql
-- All subcategories under Electronics
SELECT * FROM c WHERE STARTSWITH(c.path, "/electronics") AND c.type = "category"
```

This query leverages a range index on `path` and returns the entire subtree in a single query. Moving a branch means updating the `path` of every descendant, which is expensive — but category trees rarely restructure.

### Embedded Children (Shallow Trees)

For trees with limited depth and a small number of nodes — a product configuration with 3 levels and a few dozen options — embed the entire tree in a single document:

```json
{
  "id": "config-laptop-builder",
  "type": "productConfig",
  "productId": "laptop-x1",
  "options": {
    "processor": {
      "label": "Processor",
      "choices": [
        {
          "id": "i7",
          "label": "Intel Core i7",
          "subOptions": {
            "ram": {
              "label": "Memory",
              "choices": [
                { "id": "16gb", "label": "16 GB", "priceAdj": 0 },
                { "id": "32gb", "label": "32 GB", "priceAdj": 150 }
              ]
            }
          }
        }
      ]
    }
  }
}
```

One point read gives you the entire configuration tree. This works well when the tree is small, rarely changes, and is always read as a unit. Cosmos DB supports nesting up to **128 levels** deep — far more than any sane tree structure needs.

<!-- Source: concepts-limits.md -->

**When to use which:** Materialized path for wide or deep trees that are queried at multiple levels and updated at individual nodes (category taxonomies, org charts). Embedded children for small, shallow trees that are always read as a whole (configuration hierarchies, menu structures).

## Modeling Many-to-Many Relationships

In relational databases, many-to-many relationships get a join table. In Cosmos DB, you don't have JOINs across documents, so you need a different approach.

<!-- Source: modeling-data.md -->

### Embed Reference Arrays on Both Sides

The most common pattern: each entity stores an array of IDs referencing the related entities.

```json
{
  "id": "author-a1",
  "type": "author",
  "name": "Thomas Andersen",
  "bookIds": ["book-b1", "book-b2", "book-b3"]
}

{
  "id": "book-b1",
  "type": "book",
  "title": "Azure Cosmos DB 101",
  "authorIds": ["author-a1", "author-a2"]
}
```

<!-- Source: modeling-data.md -->

Given an author, you can immediately see their book IDs. Given a book, you can see its author IDs. To load the full details, you issue a second query — `SELECT * FROM c WHERE c.id IN ("book-b1", "book-b2", "book-b3")` — which is a single partition query if the books share a partition key, or a cross-partition query if they don't.

### Denormalize Summary Data

If your application's UI shows an author with their book titles (not just IDs), embed the most commonly needed fields:

```json
{
  "id": "author-a1",
  "type": "author",
  "name": "Thomas Andersen",
  "books": [
    { "id": "book-b1", "title": "Azure Cosmos DB 101" },
    { "id": "book-b2", "title": "Cosmos DB for RDBMS Users" }
  ]
}
```

This eliminates the second query at the cost of maintaining the denormalized `title` when it changes. For data that changes rarely (book titles, product names), this is a good trade-off. Keep the copies in sync using the change feed (Chapter 15).

### When the Relationship Is the Entity

Sometimes the relationship itself carries data — a user's enrollment in a course includes a grade and an enrollment date. In that case, model the relationship as its own item:

```json
{
  "id": "enrollment-u42-c101",
  "type": "enrollment",
  "userId": "user-42",
  "courseId": "course-101",
  "enrolledDate": "2025-03-01",
  "grade": "A",
  "completed": true
}
```

This is the document equivalent of a join table, and it works when:

- The relationship has its own properties (grade, date, status).
- The number of relationships is large or unbounded.
- You need to query the relationship itself (e.g., "all enrollments completed this month").

Choose a partition key that aligns with your primary query pattern. If you mostly query by user, partition by `userId`. If you mostly query by course, partition by `courseId`. If you need both, consider a materialized view (back to the lookup pattern from earlier in this chapter).

## Delete Items by Partition Key

Deleting items one at a time is fine when you're removing a handful. But what if you need to delete all data for a churned tenant, all expired events for a device, or all test data from a staging run? Querying for every item's `id` and issuing individual deletes is slow, expensive, and fragile.

The **delete by partition key** operation lets you delete all items sharing a logical partition key value in a single API call. You provide the partition key value, and Cosmos DB handles the rest.

<!-- Source: how-to-delete-by-partition-key.md -->

```csharp
Container container = cosmosClient.GetContainer("SaasDb", "TenantData");

ResponseMessage response = await container.DeleteAllItemsByPartitionKeyStreamAsync(
    new PartitionKey("tenant-contoso")
);

if (response.IsSuccessStatusCode)
{
    Console.WriteLine("Deletion started for tenant-contoso");
}
```

<!-- Source: how-to-delete-by-partition-key.md -->

### How It Works

The operation runs as an **asynchronous background task**. A few key behaviors:

- **Immediate visibility.** Deleted items stop appearing in queries and read operations right away, even while physical deletion is still in progress.
- **Throttle-aware.** The operation consumes at most **10% of the container's total RU/s** on a best-effort basis. The other 90% remains available for your normal workload. If your container has 10,000 RU/s provisioned, the deletion will use up to 1,000 RU/s; the remaining 9,000 RU/s stays available for reads, writes, and queries.
- **New writes are safe.** If you write a new item with the same partition key while the delete is in progress, the new item is not affected — only items that existed when the operation started are deleted.

<!-- Source: how-to-delete-by-partition-key.md -->

> **Important:** This feature is in **public preview** and requires you to enable the `DeleteAllItemsByPartitionKey` capability on your account before use. Preview features don't carry an SLA.

<!-- Source: how-to-delete-by-partition-key.md -->

### Limitations

- **Hierarchical partition keys** are supported, but you must specify the *complete* partition key — all levels. You can't delete by just the first level (e.g., only by `tenantId` without also specifying `userId` and `sessionId`). If your deletion pattern is "all data for a tenant regardless of sub-keys," you'll need a different approach (like TTL or an iterative delete loop).
- **Aggregate queries during deletion** may still include items that are in the process of being deleted. Point reads and non-aggregate queries correctly exclude them.

<!-- Source: how-to-delete-by-partition-key.md -->

### When to Use It

This feature shines for multi-tenant data cleanup — a tenant leaves, you nuke their partition. It's also useful for data lifecycle management when TTL alone isn't sufficient (e.g., you need to delete a tenant's data on demand, not on a fixed schedule).

For bulk operations across multiple partition keys, Chapter 21 covers advanced SDK patterns including bulk mode.

## Event Sourcing and Immutable Log Patterns

In traditional CRUD systems, you overwrite the current state. A customer changes their address, and the old address is gone. An order status moves from "pending" to "shipped," and the pending state is lost.

**Event sourcing** flips this model. Instead of storing current state, you store every state *change* as an immutable event. The current state is derived by replaying events in order.

Cosmos DB is a natural fit for the event store side of this pattern:

```json
{
  "id": "evt-10001",
  "streamId": "cart-user42",
  "type": "event",
  "eventType": "ItemAdded",
  "timestamp": "2025-06-15T10:30:00Z",
  "sequenceNumber": 1,
  "data": {
    "sku": "WIDGET-A",
    "quantity": 1,
    "unitPrice": 12.99
  }
}

{
  "id": "evt-10002",
  "streamId": "cart-user42",
  "type": "event",
  "eventType": "ItemAdded",
  "timestamp": "2025-06-15T10:31:00Z",
  "sequenceNumber": 2,
  "data": {
    "sku": "GADGET-B",
    "quantity": 2,
    "unitPrice": 49.99
  }
}

{
  "id": "evt-10003",
  "streamId": "cart-user42",
  "type": "event",
  "eventType": "ItemRemoved",
  "timestamp": "2025-06-15T10:35:00Z",
  "sequenceNumber": 3,
  "data": {
    "sku": "WIDGET-A"
  }
}
```

Partition by `streamId` (e.g., `cart-user42`), and all events for an entity stream land in the same partition — queryable in order by `sequenceNumber`, writable at high throughput.

<!-- Source: change-feed-design-patterns.md -->

### Why Cosmos DB Works for Event Sourcing

- **Append-only writes are fast.** Events are inserts, never updates. Cosmos DB's write path is optimized for this.
- **Ordering is guaranteed within a partition key.** The change feed delivers events in order within a partition key value — exactly the ordering guarantee event sourcing requires.
- **The change feed *is* the event stream.** Once events are written to Cosmos DB, the change feed lets downstream consumers (materialized view builders, notification services, analytics pipelines) process them without polling or secondary message infrastructure.
- **Horizontal scalability.** Thousands of independent event streams, each in its own partition, scale out naturally.

### The Consumer Side

The write side of event sourcing is straightforward: insert events into Cosmos DB. The read side — building materialized views, deriving current state, triggering side effects — is where the change feed comes in. A change feed processor reads new events and updates a "current state" view:

- Event: `ItemAdded(WIDGET-A)` → View: `{ cart: [WIDGET-A] }`
- Event: `ItemAdded(GADGET-B)` → View: `{ cart: [WIDGET-A, GADGET-B] }`
- Event: `ItemRemoved(WIDGET-A)` → View: `{ cart: [GADGET-B] }`

The view is eventually consistent with the event log — but for most applications, the sub-second lag is invisible. Chapter 15 covers the change feed processor in full, including error handling, lease management, and exactly-once processing patterns.

### Practical Considerations

**Snapshots.** Replaying all events from the beginning gets expensive as the stream grows. Periodically persist a "snapshot" item that captures current state at a given sequence number. Future replays start from the snapshot instead of from event zero.

**TTL for old events.** If you don't need the full event history forever, use TTL to expire events older than your retention window. The snapshot pattern makes this safe — as long as your most recent snapshot is within the retention window, you can always reconstruct current state.

**All-versions-and-deletes mode.** If your event sourcing pattern includes item deletions (e.g., a hard-delete after TTL expiration), be aware that the default change feed mode (latest version) does *not* capture deletes. The all-versions-and-deletes mode does, but has its own retention constraints. Chapter 15 covers both modes.

---

With these patterns in your toolkit — item types, materialized views, TTL, Patch, chunking, trees, many-to-many relationships, partition key deletion, and event sourcing — you can model most real-world domains effectively in Cosmos DB. The next chapter shifts from *modeling* data to *working* with it: Chapter 7 dives into the Cosmos DB SDKs, where you'll see these patterns come to life in code.
