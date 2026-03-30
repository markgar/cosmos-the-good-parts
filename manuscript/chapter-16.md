# Chapter 16: Transactions and Optimistic Concurrency

Every database has to answer two hard questions. First: when you need to change multiple things at once, can you guarantee they all succeed or all fail together? Second: when two clients try to change the same item at the same time, who wins — and how does the loser find out?

In a relational database, you'd wrap both problems in a `BEGIN TRANSACTION` / `COMMIT` block and move on. Cosmos DB can't do that — there's no global transaction coordinator spanning partitions, containers, or even items with different partition keys. But it does give you powerful primitives for both problems, and understanding exactly where those primitives work (and where they don't) is what separates an application that loses data from one that doesn't.

This chapter is the canonical reference for three things: how single-item atomicity works by default, how to get multi-item transactions through transactional batches and stored procedures, and how to use ETags for optimistic concurrency control. If Chapter 7 showed you the basic CRUD operations and Chapter 14 taught you stored procedure mechanics, this chapter ties those threads together into the transactional guarantees you can actually rely on.

## Single-Item Atomicity: Transactions You Get for Free

Every individual write operation in Cosmos DB — create, replace, upsert, delete, patch — is **automatically atomic**. If you replace a document, the entire document is committed or nothing is. There's no scenario where half the properties update and the other half don't. You don't need to request this behavior; it's always on.

<!-- Source: database-transactions-optimistic-concurrency.md -->

This matters because some other NoSQL stores *can* produce partial writes during failures. Cosmos DB provides full ACID guarantees with snapshot isolation for every operation within a logical partition — atomic, consistent, isolated, and durable once acknowledged.

<!-- Source: database-transactions-optimistic-concurrency.md -->

Here's the operation-to-transaction mapping that matters:

| Operation | Type | Scope |
|-----------|------|-------|
| Insert (no trigger) | Single-item write | Automatic |
| Replace (no trigger) | Single-item write | Automatic |
| Upsert (no trigger) | Single-item write | Automatic |
| Delete (no trigger) | Single-item write | Automatic |
| Patch (no trigger) | Single-item write | Automatic |
| Write *with* trigger | Multi-item | Automatic |
| Stored procedure | Multi-item read/write | Explicit |
| Transactional batch | Multi-item read/write | Explicit |
| Single-item read | Single-item read | Automatic |

- **Write with trigger:** any insert, replace, upsert, or delete that fires a trigger — the trigger logic participates in the transaction.
- **Explicit scope:** for stored procedures, you write the transactional logic; for batches, you build the operation set.

<!-- Source: database-transactions-optimistic-concurrency.md -->

The key insight: if your use case only ever needs to modify one item at a time, you already have ACID transactions. No stored procedures, no batch API, no special configuration. This covers a surprising number of real-world scenarios — updating a user profile, recording a single event, changing an order status.

The question becomes: what happens when you need to change *more than one* item atomically?

## Multi-Item Transactions: Two Paths, One Constraint

Cosmos DB offers two mechanisms for multi-item ACID transactions: **stored procedures** (server-side JavaScript) and **transactional batch** (client-side SDK). Both are subject to the same fundamental constraint:

> **All operations in a multi-item transaction must target items within the same logical partition.**

This isn't a temporary limitation — it's an architectural reality. Each logical partition is hosted on a single replica set, and ACID transactions require all participants to be on the same replica. Cross-partition transactions would require a distributed transaction coordinator (two-phase commit), which Cosmos DB's architecture intentionally avoids because it would destroy the latency and availability guarantees the service is built on.

<!-- Source: database-transactions-optimistic-concurrency.md, stored-procedures-triggers-udfs.md -->

If you need atomic operations across different partition keys, you're looking at application-level compensation patterns — sagas, outbox patterns, idempotent retries. Those are real solutions, but they're not database transactions. Plan your partition key accordingly (Chapter 5), and co-locate items that must be transactionally consistent.

### Stored Procedures: Server-Side Transactions

Chapter 14 covers stored procedure mechanics — how to write, register, and execute them. Here, we focus on the transactional semantics.

When a stored procedure executes, the JavaScript runtime wraps all operations in an ambient ACID transaction with snapshot isolation. There's no explicit `BEGIN TRANSACTION` or `COMMIT` — those are implicit. If the procedure completes without throwing an exception, all writes commit atomically. If any exception is thrown, the entire transaction rolls back. Throwing an exception in a stored procedure is the equivalent of `ROLLBACK TRANSACTION` in SQL Server.

<!-- Source: stored-procedures-triggers-udfs.md -->

A few transactional behaviors to know:

**Snapshot isolation.** The stored procedure's operations run under snapshot isolation. The docs specifically note that queries executed within a stored procedure — both SQL queries via `getContext().getCollection().queryDocuments()` and integrated language queries via `getContext().getCollection().filter()` — may not see changes made by the same transaction. This is a quirk of the JavaScript runtime's query pipeline, not a general property of snapshot isolation. Point reads of items you've just written *may* behave differently, but treat queries within a sproc as reading from a frozen snapshot.

<!-- Source: stored-procedures-triggers-udfs.md -->

**Implicit ETag checking.** The `_etag` values are implicitly checked for all items touched by a stored procedure. If an external write modifies an item between the procedure's read and write of that same item, the conflicting ETag causes the transaction to roll back and throw an exception. This is the same optimistic concurrency mechanism we'll cover later in this chapter, but it happens automatically inside stored procedures — you don't need to set `if-match` headers.

<!-- Source: database-transactions-optimistic-concurrency.md -->

**Bounded execution.** Stored procedures must complete within 5 seconds. If they don't, the transaction is rolled back. For large operations, you need a continuation-based pattern where the procedure processes a batch, returns a continuation token, and the client calls it again. Each invocation is its own transaction.

<!-- Source: stored-procedures-triggers-udfs.md, concepts-limits.md -->

**Strong consistency reads.** Stored procedures always execute on the primary replica, so reads within a procedure get strong consistency regardless of your account's default consistency level. One caveat: in a multi-region account, sproc writes are local to the region, so "strong consistency reads inside a sproc" doesn't mean globally consistent behavior. The docs explicitly note that using stored procedures with strong consistency isn't suggested because mutations are local.

<!-- Source: stored-procedures-triggers-udfs.md -->

Stored procedures are the right choice when you need custom transactional logic — conditional writes based on reads, counter updates that depend on current values, or complex multi-item mutations that aren't expressible as a batch of independent operations. But they come with the JavaScript requirement and the operational overhead of managing server-side code (versioning, deployment, debugging). For simpler "all succeed or all fail" semantics, transactional batch is the better tool.

## Transactional Batch Operations

**Transactional batch** is the SDK-native way to execute multiple point operations as a single atomic unit. It was introduced specifically to address the cases where stored procedures are overkill — you just want a set of creates, replaces, deletes, patches, or reads to either all succeed or all fail, without writing JavaScript.

<!-- Source: transactional-batch.md -->

The docs highlight four advantages of transactional batch over stored procedures:

| | Batch | Stored Procedure |
|---|---|---|
| **Language** | Your SDK language | JavaScript only |
| **Versioning** | In app code, via CI/CD | Deployed separately |
| **Performance** | Up to 30% lower latency | Higher JS runtime overhead |
| **Serialization** | Custom per operation | JSON via JS runtime |

<!-- Source: transactional-batch.md -->

### How It Works

You build a batch by adding operations one at a time, then execute the whole thing in a single call. The SDK serializes all operations into one payload, sends it as a single request to Cosmos DB, and the service executes them within a transactional scope. You get back a single response with individual results for each operation.

The rules are simple:

1. **Same partition key.** Every operation in the batch must target the same partition key value. You specify it when creating the batch, and it applies to all operations.
2. **All succeed or all fail.** If any operation fails, the entire batch rolls back. The failed operation gets its specific error code; all other operations get HTTP 424 (Failed Dependency).
3. **Bounded size and count.** There are caps on how many operations a batch can contain and the total payload size. See the limits table later in this section for the specific numbers.
4. **Bounded execution time.** The batch must complete within a fixed timeout or it rolls back.

<!-- Source: transactional-batch.md -->

Supported operations within a batch include create, read, replace, upsert, delete, and patch. You can mix and match — a single batch can create one item, replace another, delete a third, and patch a fourth, as long as they all share a partition key.

### C# Example: Order with Line Items

Here's a realistic scenario: creating an order and its associated inventory adjustment in a single atomic operation. Both items share a partition key of `"cust-337"`.

```csharp
PartitionKey partitionKey = new PartitionKey("cust-337");

TransactionalBatch batch = container.CreateTransactionalBatch(partitionKey);

var order = new
{
    id = "order-5001",
    customerId = "cust-337",
    type = "order",
    status = "confirmed",
    total = 149.97m,
    orderDate = DateTime.UtcNow
};

var loyaltyUpdate = new
{
    id = "loyalty-cust-337",
    customerId = "cust-337",
    type = "loyalty",
    pointsBalance = 1500
};

batch.CreateItem(order);
batch.ReplaceItem("loyalty-cust-337", loyaltyUpdate);

using TransactionalBatchResponse response = await batch.ExecuteAsync();

if (response.IsSuccessStatusCode)
{
    TransactionalBatchOperationResult<dynamic> orderResult =
        response.GetOperationResultAtIndex<dynamic>(0);
    Console.WriteLine($"Order created: {orderResult.StatusCode}");

    TransactionalBatchOperationResult<dynamic> loyaltyResult =
        response.GetOperationResultAtIndex<dynamic>(1);
    Console.WriteLine($"Loyalty updated: {loyaltyResult.StatusCode}");
}
else
{
    Console.WriteLine($"Batch failed: {response.StatusCode}");
    // Inspect individual operation results to find the failure
    for (int i = 0; i < response.Count; i++)
    {
        TransactionalBatchOperationResult result = response[i];
        Console.WriteLine($"  Operation {i}: {result.StatusCode}");
    }
}
```

If the loyalty record doesn't exist (maybe the `id` is wrong), the replace fails with 404 and the order creation rolls back. Neither item is written. That's the guarantee.

### Python Example: Batch with Mixed Operations

Python's transactional batch uses a tuple-based syntax. Each operation is a tuple of `(operation_type, args_tuple, kwargs_dict)`:

```python
from azure.cosmos import CosmosClient, PartitionKey, exceptions

# Items sharing partition key "road-bikes"
new_product = {
    "id": "product-9001",
    "category": "road-bikes",
    "type": "product",
    "name": "Apex Carbon Frameset",
    "price": 2499.00
}

updated_part = {
    "id": "part-4010",
    "category": "road-bikes",
    "type": "part",
    "name": "Carbon Fork v2",
    "productId": "product-9001"
}

batch_operations = [
    ("create", (new_product,), {}),
    ("upsert", (updated_part,), {}),
    ("read", ("part-4011",), {}),
    ("delete", ("part-4012",), {}),
]

try:
    results = container.execute_item_batch(
        batch_operations=batch_operations,
        partition_key="road-bikes"
    )
    print(f"Batch succeeded with {len(results)} operations")
except exceptions.CosmosBatchOperationError as e:
    print(f"Operation {e.error_index} failed: "
          f"{e.operation_responses[e.error_index]}")
```

<!-- Source: transactional-batch.md -->

Notice the Python SDK raises a `CosmosBatchOperationError` on failure rather than returning a response object you inspect. The exception gives you the index of the failed operation and all operation responses so you can determine what went wrong.

### Patch Operations in a Batch

You can include Patch operations in a transactional batch, which combines the efficiency of partial updates with the atomicity of multi-item transactions. Chapter 6 introduced the Patch API; here it participates in a batch:

```csharp
PartitionKey partitionKey = new PartitionKey("road-bikes");

TransactionalBatch batch = container.CreateTransactionalBatch(partitionKey);

batch.PatchItem(
    id: "product-100",
    patchOperations: new[]
    {
        PatchOperation.Increment("/inventory/quantity", -1)
    }
);

batch.PatchItem(
    id: "product-200",
    patchOperations: new[]
    {
        PatchOperation.Increment("/inventory/quantity", -1)
    }
);

batch.CreateItem(new
{
    id = $"reservation-{Guid.NewGuid()}",
    category = "road-bikes",
    type = "reservation",
    productIds = new[] { "product-100", "product-200" },
    reservedAt = DateTime.UtcNow
});

using TransactionalBatchResponse response = await batch.ExecuteAsync();
```

Three operations — two inventory decrements and a reservation creation — committed atomically. If either product doesn't exist, nothing changes.

In Python, you can combine patch operations with conditional predicates and ETag matching within a batch:

```python
batch_operations = [
    ("replace", (item_id, item_body), {"if_match_etag": etag}),
    ("patch", (other_item_id, patch_ops), {"filter_predicate": "FROM c WHERE c.status = 'active'"}),
]
```

<!-- Source: transactional-batch.md -->

### Error Handling: The 424 Pattern

When a batch fails, exactly one operation has the actual error status code — 404, 409, 412, whatever caused the failure. Every *other* operation in the batch gets **HTTP 424 (Failed Dependency)**. This tells you "I didn't fail on my own — I was rolled back because something else in the batch failed."

Your error-handling code should scan the individual results for the non-424 status code to identify the root cause:

```csharp
if (!response.IsSuccessStatusCode)
{
    for (int i = 0; i < response.Count; i++)
    {
        var result = response[i];
        if ((int)result.StatusCode != 424)
        {
            Console.WriteLine($"Root cause at index {i}: HTTP {(int)result.StatusCode}");
        }
    }
}
```

Common failure causes:

| Status | Meaning |
|--------|---------|
| **404** | Item not found |
| **409** | Conflict — duplicate `id` |
| **412** | ETag mismatch |
| **413** | Payload exceeds 2 MB |

A 404 means a read, replace, delete, or patch targeted a nonexistent item. A 409 means a create tried to insert an item with an `id` that already exists. A 412 indicates a precondition failure on a conditional operation (ETag-based). A 413 means the batch payload exceeded the 2 MB limit.

<!-- Source: transactional-batch.md -->

### Transactional Batch Limits

| Constraint | Limit |
|-----------|-------|
| Max operations per batch | 100 |
| Max payload size | 2 MB |
| Max execution time | 5 seconds |
| Partition key scope | Single partition key |

<!-- Source: transactional-batch.md -->

The 100-operation limit is generous for most use cases. If you genuinely need more, split into multiple batches — but remember, each batch is its own transaction. There's no way to make two separate batches atomic with respect to each other.

### When to Use Transactional Batch vs. Stored Procedures

Use transactional batch when:
- You need a set of independent operations to succeed or fail together.
- The operations don't require reading an item and making decisions based on its current value within the same transaction.
- You want your transaction logic in your application code, not in server-side JavaScript.

Use stored procedures when:
- You need to read an item, make a conditional decision, then write — all within a single transaction.
- You need custom transactional logic that goes beyond "execute these operations atomically."
- You need server-side reads with guaranteed strong consistency regardless of account settings.

For the vast majority of "all-or-nothing" multi-item writes, transactional batch is the right choice. It's simpler, faster than stored procedures, and keeps your code in one place.

## Optimistic Concurrency Control with ETags

Now for the second hard problem: concurrent writes to the same item.

Imagine two service instances read the same inventory item, both see `quantity: 10`, both decrement it to 9, and both write back. You just sold two units but only decremented once. This is the **lost update** problem, and it plagues every system that doesn't have a concurrency strategy.

Cosmos DB's answer is **optimistic concurrency control (OCC)** using the `_etag` system property. The word "optimistic" means you don't lock the item when you read it — you proceed optimistically, assuming no one else will modify it, and check at write time whether that assumption held.

<!-- Source: database-transactions-optimistic-concurrency.md -->

### How ETags Work

Every item in Cosmos DB has a system-generated `_etag` property (introduced in Chapter 2). The value changes every time the item is updated — any write to the item produces a new ETag. You can think of it as a version stamp.

```json
{
    "id": "product-100",
    "category": "road-bikes",
    "name": "Apex Carbon Frameset",
    "inventory": { "quantity": 10 },
    "_etag": "\"00005e03-0000-0700-0000-66a1b2c30000\""
}
```

When you read an item, you get the current `_etag`. When you write the item back, you can attach the ETag as an `if-match` condition. The server compares the ETag you sent against the item's current ETag:

- **Match:** The item hasn't changed since you read it. The write proceeds, and the server generates a new ETag.
- **Mismatch:** Someone else modified the item after your read. The server rejects the write with **HTTP 412 Precondition Failure**.

<!-- Source: database-transactions-optimistic-concurrency.md, faq.md -->

This is the same pattern as HTTP conditional requests (RFC 7232), applied to database writes. The `_etag` is the entity tag; `if-match` is the precondition header.

### The If-Match Pattern in C\#

```csharp
// Step 1: Read the item and capture the ETag
ItemResponse<Product> readResponse = await container.ReadItemAsync<Product>(
    id: "product-100",
    partitionKey: new PartitionKey("road-bikes")
);

Product product = readResponse.Resource;
string etag = readResponse.ETag;

// Step 2: Modify the item in memory
product.Inventory.Quantity -= 1;

// Step 3: Write it back with the ETag as a precondition
try
{
    ItemResponse<Product> writeResponse = await container.ReplaceItemAsync(
        item: product,
        id: product.Id,
        partitionKey: new PartitionKey("road-bikes"),
        requestOptions: new ItemRequestOptions { IfMatchEtag = etag }
    );
    Console.WriteLine($"Updated successfully. New ETag: {writeResponse.ETag}");
}
catch (CosmosException ex) when (ex.StatusCode == System.Net.HttpStatusCode.PreconditionFailed)
{
    Console.WriteLine("Conflict detected — someone else modified this item.");
    // Re-read, re-apply business logic, retry
}
```

The `IfMatchEtag` property on `ItemRequestOptions` maps to the `if-match` HTTP header. If the item was modified between your read and your write, you get a `CosmosException` with status code 412.

### The If-Match Pattern in Python

```python
from azure.cosmos import exceptions

# Step 1: Read the item
response = container.read_item(
    item="product-100",
    partition_key="road-bikes"
)

product = response
etag = response.get("_etag")

# Step 2: Modify the item
product["inventory"]["quantity"] -= 1

# Step 3: Write it back with ETag precondition
try:
    container.replace_item(
        item="product-100",
        body=product,
        if_match=etag
    )
    print("Updated successfully.")
except exceptions.CosmosHttpResponseError as e:
    if e.status_code == 412:
        print("Conflict detected — re-read and retry.")
    else:
        raise
```

### The If-Match Pattern in JavaScript

```javascript
// Step 1: Read the item
const { resource: product, etag } = await container
    .item("product-100", "road-bikes")
    .read();

// Step 2: Modify the item
product.inventory.quantity -= 1;

// Step 3: Write it back with ETag precondition
try {
    const { resource: updated } = await container
        .item("product-100", "road-bikes")
        .replace(product, { ifMatch: etag });
    console.log("Updated successfully.");
} catch (error) {
    if (error.code === 412) {
        console.log("Conflict detected — re-read and retry.");
    } else {
        throw error;
    }
}
```

All three examples follow the same pattern: **read → capture ETag → modify → conditional write → handle conflict**. The only differences are API surface names.

### Building a Retry Loop

A single if-match check isn't enough in a high-contention scenario. You need a retry loop that re-reads, re-applies your business logic, and tries again. Here's a production-ready pattern in C#:

```csharp
public async Task<Product> DecrementInventoryAsync(
    Container container,
    string productId,
    string category,
    int quantity,
    int maxRetries = 5)
{
    for (int attempt = 0; attempt < maxRetries; attempt++)
    {
        // Read current state
        ItemResponse<Product> readResponse = await container.ReadItemAsync<Product>(
            id: productId,
            partitionKey: new PartitionKey(category)
        );

        Product product = readResponse.Resource;

        if (product.Inventory.Quantity < quantity)
            throw new InvalidOperationException("Insufficient inventory.");

        product.Inventory.Quantity -= quantity;

        try
        {
            ItemResponse<Product> writeResponse = await container.ReplaceItemAsync(
                item: product,
                id: productId,
                partitionKey: new PartitionKey(category),
                requestOptions: new ItemRequestOptions { IfMatchEtag = readResponse.ETag }
            );

            return writeResponse.Resource;
        }
        catch (CosmosException ex) when (ex.StatusCode == System.Net.HttpStatusCode.PreconditionFailed)
        {
            // Another writer got there first — loop and try again
            if (attempt == maxRetries - 1)
                throw new InvalidOperationException(
                    $"Failed to update {productId} after {maxRetries} attempts due to contention.");
        }
    }

    throw new InvalidOperationException("Unreachable.");
}
```

A few things to notice:

- **Re-read on every retry.** You must fetch the latest version — you can't reuse the stale data from the previous attempt. The ETag from the new read becomes the precondition for the next write attempt.
- **Re-apply business logic.** The inventory check (`quantity < requested`) runs against the fresh data. Maybe another writer decremented the stock to zero — your retry needs to detect that.
- **Bounded retries.** Don't loop forever. If contention is so high that you can't land a write in 5 attempts, something is structurally wrong — maybe the item is a hot partition key, or you need a different approach (like using the Patch API's `Increment` operation, which is atomic and doesn't require read-modify-write).

> **Gotcha:** The SDK does *not* automatically retry 412 errors. As Chapter 7 explained, 412 Precondition Failed is a business-logic decision — the SDK can't know how to resolve the conflict. You must handle it yourself.

### The If-None-Match Pattern

There's a complementary header: `if-none-match`. Instead of saying "update only if the ETag matches," it says "update only if the ETag does *not* match." The most common use is with the wildcard value `*`:

```csharp
// Insert ONLY if no item with this id exists — turns an upsert into a conditional insert
try
{
    ItemResponse<Product> response = await container.UpsertItemAsync(
        item: product,
        partitionKey: new PartitionKey("road-bikes"),
        requestOptions: new ItemRequestOptions { IfNoneMatchEtag = "*" }
    );
}
catch (CosmosException ex) when (ex.StatusCode == System.Net.HttpStatusCode.PreconditionFailed)
{
    Console.WriteLine("Item already exists — upsert was blocked by if-none-match.");
}
```

<!-- Source: database-transactions-optimistic-concurrency.md -->

The `IfNoneMatchEtag = "*"` tells the server "only succeed if *no* version of this item exists." On `UpsertItemAsync`, this effectively turns the upsert into a conditional insert: if the item is absent, it's created; if the item already exists, the server returns **HTTP 412 Precondition Failed** instead of overwriting. Note that `CreateItemAsync` doesn't need this trick — it already returns 409 Conflict when the item exists. The `if-none-match: *` pattern is specifically useful with upsert, where you want insert-if-absent semantics without the overwrite behavior.

### ETags in Transactional Batches

You can combine ETag-based concurrency with transactional batches. Each operation in a batch can carry its own `if-match` condition:

```csharp
TransactionalBatch batch = container.CreateTransactionalBatch(
    new PartitionKey("road-bikes")
);

batch.ReplaceItem(
    id: "product-100",
    item: updatedProduct,
    requestOptions: new TransactionalBatchItemRequestOptions
    {
        IfMatchEtag = productEtag
    }
);

batch.ReplaceItem(
    id: "product-200",
    item: updatedAccessory,
    requestOptions: new TransactionalBatchItemRequestOptions
    {
        IfMatchEtag = accessoryEtag
    }
);

using TransactionalBatchResponse response = await batch.ExecuteAsync();
```

If either ETag check fails, the entire batch rolls back. This gives you atomic multi-item updates *with* concurrency protection — the strongest guarantee available in Cosmos DB without writing a stored procedure.

### ETags in Stored Procedures

Inside stored procedures, ETag checking is implicit — see the "Implicit ETag checking" note in the stored procedures section earlier in this chapter.

### When Not to Use Optimistic Concurrency

Optimistic concurrency assumes conflicts are *rare*. The strategy works beautifully when most writes don't collide — which is the case in well-partitioned Cosmos DB workloads where each item is typically modified by one client at a time.

It breaks down when:

- **A single item is a write hotspot.** If dozens of clients are constantly updating the same item (a global counter, a shared queue pointer), the retry loop turns into a spin loop where most attempts fail. For atomic counters, use the Patch API's `Increment` operation instead — it's a server-side atomic increment that doesn't require read-modify-write.
- **The business logic between read and write is expensive.** If your "modify" step involves calling external APIs, running ML inference, or doing heavy computation, repeating it on every retry wastes significant resources. Consider moving the expensive work *before* the read-modify-write cycle, or restructuring so the write is a simple, cheap operation.
- **You're in a multi-region write configuration.** OCC with `if-match` works against the *local* region's replica. Two clients in different regions can both succeed with their `if-match` writes, and the conflict is resolved later by the conflict resolution policy (Chapter 12). The ETag protects you from concurrent writes within a region, not across regions.

    If you need cross-region write protection, you have two options: use strong consistency (which disables multi-region writes entirely) or implement application-level conflict resolution that can detect and reconcile divergent writes after the fact.

<!-- Source: database-transactions-optimistic-concurrency.md -->

### Optimistic Concurrency vs. the Patch API

Chapter 6 introduced the Patch API's conditional predicates — a server-side `WHERE` clause that rejects the update if the predicate doesn't match. There's overlap with ETag-based concurrency, but they solve different problems:

| | ETag + If-Match | Patch Predicate |
|---|---|---|
| **Checks** | Any change to item | Specific field value |
| **Prior read?** | Yes — need the ETag | No — runs server-side |
| **Granularity** | Entire item version | Specific fields |
| **Best for** | Read-modify-write | Atomic field updates |

If you're decrementing inventory, a conditional Patch (`FROM c WHERE c.inventory.quantity > 0` with an `Increment` of `-1`) is better than a read-modify-write with ETag checking. It's one round-trip instead of two, and there's no retry loop needed — the server handles the atomicity.

If you're replacing an entire document based on complex client-side logic, ETags are the right tool because the predicate approach can't express "the entire document hasn't changed."

## Putting It All Together: A Transaction Decision Framework

When you're staring at a Cosmos DB write scenario and wondering which transactional primitive to reach for, here's the decision tree:

**Modifying a single item?**
→ Just write it. Single-item atomicity is automatic. Add an `if-match` ETag if you need to prevent lost updates.

**Modifying a single field atomically?**
→ Use the Patch API. Add a conditional predicate if the update should only apply when a condition is met. No read required.

**Modifying multiple items that share a partition key, with simple "all or nothing" semantics?**
→ Use transactional batch. It's the most natural fit for multi-item atomicity without custom logic.

**Modifying multiple items with conditional logic that depends on reading items first?**
→ Use a stored procedure. The server-side transaction gives you read-decide-write within a single atomic scope.

**Modifying items across different partition keys?**
→ No database-level transaction exists. Use application-level patterns: saga, outbox, or idempotent compensation. Design your partition key to minimize how often you need this.

The next chapter shifts from protecting data integrity to protecting data access — Chapter 17 covers security and access control, including authentication, RBAC, and network security.
