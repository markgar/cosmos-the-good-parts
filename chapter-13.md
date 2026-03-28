# Chapter 13: Stored Procedures, Triggers, and User-Defined Functions

So far in this book, every operation you've performed against Cosmos DB has originated from your application code — reads, writes, queries, all traveling across the network to the database and back. But what if you could push logic *into* the database engine itself, execute it right next to the data, and wrap multiple operations in a genuine ACID transaction?

That's exactly what server-side programming in Cosmos DB gives you. Using JavaScript, you can author **stored procedures**, **triggers**, and **user-defined functions (UDFs)** that run directly inside the database engine. In this chapter, you'll learn when these constructs make sense, how to write and register them, and — just as importantly — when to reach for other tools instead.

## When and Why to Use Server-Side JavaScript

Cosmos DB's database engine natively hosts a JavaScript runtime. When you register a stored procedure, trigger, or UDF, your code executes within the same process that manages the data. This architecture gives you several advantages:

- **True ACID transactions.** Stored procedures and triggers execute within an ambient transaction with snapshot isolation. If any operation throws an exception, the entire transaction rolls back — all or nothing. Outside of server-side code, the only other way to get multi-item transactions is the transactional batch API.
- **Reduced network round-trips.** Instead of reading an item, modifying it on the client, and writing it back — incurring latency on each hop — a stored procedure can do all of that in a single call.
- **Pre-compilation.** Stored procedures, triggers, and UDFs are implicitly pre-compiled to byte code when you register them. Each subsequent invocation skips compilation overhead entirely.
- **Batching.** You can group writes (like bulk inserts) into a single stored procedure call, reducing both network traffic and the per-operation transaction overhead.

That said, server-side code isn't a silver bullet. Here are the constraints to keep in mind:

- **Single partition scope.** Stored procedures and triggers are always scoped to a single logical partition. You must supply a partition key value when you execute them, and they cannot read or write items in other partitions.
- **JavaScript only.** You can't import external modules. The runtime provides a specific server-side SDK (the `__` or `getContext()` API) — and that's it.
- **Bounded execution.** The runtime enforces time and resource limits. Long-running procedures must handle continuation gracefully.
- **RU variance.** Stored procedures consume RUs based on the complexity of their operations, and Cosmos DB reserves the *average* RU cost upfront. If your procedure's RU consumption varies widely between executions, this can affect budget utilization.

> **When to choose server-side code:** Use stored procedures when you need atomic multi-item writes within a partition — for example, transferring a balance between two documents, or bulk-inserting a batch of related items. Use triggers for lightweight validation or metadata bookkeeping that must happen atomically with a write. Use UDFs to encapsulate reusable calculation logic in queries.
>
> **When to choose something else:** For cross-partition operations, use the transactional batch API or handle coordination in your application. For read-heavy workloads, querying from the client SDK is generally more efficient. For simple write transactions, the transactional batch feature in the .NET, Java, and Python SDKs offers better language integration and versioning.

## Stored Procedures

A stored procedure is a JavaScript function registered on a container. When you execute it, you supply a partition key, and the procedure runs transactionally against items within that single logical partition.

### The Execution Context

Every stored procedure accesses the database through the **context object**, retrieved via `getContext()`. From there, you can get:

- `getContext().getCollection()` — the container, used for CRUD and query operations.
- `getContext().getResponse()` — the response object, used to return data to the caller.
- `getContext().getRequest()` — available inside triggers to inspect or modify the incoming request.

### A Simple Example

Here's the classic starting point — a stored procedure that returns a greeting:

```javascript
function helloWorld() {
    var context = getContext();
    var response = context.getResponse();
    response.setBody("Hello, World");
}
```

You register this on a container, execute it with a partition key, and get back `"Hello, World"`. Not terribly useful, but it illustrates the structure: get the context, do your work, set the response body.

### Bulk Insert with Continuation Tokens

Let's look at a more realistic scenario. Suppose you need to insert a batch of order line items that all share the same `orderId` (your partition key). You want them inserted atomically — either all of them land, or none do.

Here's a stored procedure that handles bulk insertion with **bounded execution**:

```javascript
function bulkInsert(items) {
    var container = getContext().getCollection();
    var containerLink = container.getSelfLink();
    var count = 0;

    if (!items) throw new Error("The items array is undefined or null.");

    var itemsLength = items.length;
    if (itemsLength === 0) {
        getContext().getResponse().setBody(0);
        return;
    }

    tryCreate(items[count], callback);

    function tryCreate(item, callback) {
        var isAccepted = container.createDocument(containerLink, item, callback);

        // If the request was not accepted, we've hit the execution budget.
        // Return the count so the client knows where to resume.
        if (!isAccepted) getContext().getResponse().setBody(count);
    }

    function callback(err, item, options) {
        if (err) throw err;

        count++;

        if (count >= itemsLength) {
            // All items created successfully.
            getContext().getResponse().setBody(count);
        } else {
            // Create the next item.
            tryCreate(items[count], callback);
        }
    }
}
```

There are two critical patterns in this code:

1. **The `isAccepted` check.** Every CRUD method on the collection object (`createDocument`, `replaceDocument`, `queryDocuments`, etc.) returns a boolean. If it returns `false`, the runtime has run out of execution budget (time or RUs). Your procedure must gracefully stop and return enough information for the client to resume.

2. **The callback chain.** Operations are asynchronous. You pass a callback to `createDocument`, and inside that callback, you trigger the next create. This sequential chaining is the standard pattern for server-side JavaScript in Cosmos DB.

### Handling Continuation on the Client

When `isAccepted` returns `false`, the stored procedure returns the count of items it managed to insert. Your client code then needs to call the procedure again with the remaining items:

```csharp
var items = GetOrderLineItems(); // Your full batch
int totalInserted = 0;

while (totalInserted < items.Count)
{
    var batch = items.Skip(totalInserted).ToArray();

    var result = await container.Scripts.ExecuteStoredProcedureAsync<int>(
        "bulkInsert",
        new PartitionKey("order-4567"),
        new dynamic[] { batch });

    totalInserted += result.Resource;
}
```

Each call to the stored procedure is its own transaction. If you need the *entire* set to be atomic, you'll need to size your batches to fit within the execution budget — or use the transactional batch API if it suits your operation types.

### Transactional Semantics: All or Nothing

Within a single execution of a stored procedure, all operations participate in an ACID transaction with snapshot isolation. This means:

- **Atomicity:** If your procedure throws an exception (or you call `getContext().abort()`), every write performed during that execution is rolled back.
- **Consistency:** Reads within the procedure see a consistent snapshot of the partition's data.
- **Isolation:** The procedure operates under snapshot isolation — other concurrent operations won't see intermediate states.
- **Durability:** Once the procedure completes without error, all writes are committed and durable.

This is the primary reason stored procedures exist. When you need to read two items, modify them based on each other, and write them both back — all without risking a partial update — a stored procedure gives you that guarantee within a partition.

### Registering and Executing from C\#

Here's how to register and execute a stored procedure using the .NET SDK v3:

```csharp
// Register the stored procedure
StoredProcedureResponse spResponse = await container.Scripts
    .CreateStoredProcedureAsync(new StoredProcedureProperties
    {
        Id = "bulkInsert",
        Body = File.ReadAllText(@"js\bulkInsert.js")
    });

// Execute it
dynamic[] newItems = new dynamic[]
{
    new { id = "line-1", orderId = "order-4567", product = "Widget A", qty = 3 },
    new { id = "line-2", orderId = "order-4567", product = "Widget B", qty = 1 }
};

var result = await container.Scripts.ExecuteStoredProcedureAsync<int>(
    "bulkInsert",
    new PartitionKey("order-4567"),
    new dynamic[] { newItems });

Console.WriteLine($"Inserted {result.Resource} items. Cost: {result.RequestCharge} RUs");
```

Note the partition key in the `ExecuteStoredProcedureAsync` call. This is mandatory — it tells the engine which logical partition to scope the transaction to.

## Pre-Triggers and Post-Triggers

Triggers let you execute JavaScript automatically before or after a write operation. Unlike stored procedures, you don't call triggers directly. Instead, you *specify* them as part of a write request, and the engine runs them within the same transaction as the write.

Two important rules:

1. **Triggers are not automatic.** You must explicitly name the trigger in your request options. They won't fire on their own just because they're registered.
2. **One trigger per type per operation.** You can include one pre-trigger and one post-trigger per request.

### Pre-Triggers: Validate or Modify Before the Write

A pre-trigger runs *before* the item is written. It has access to the request body and can inspect, validate, or modify it. If it throws an exception, the write is aborted.

Here's a pre-trigger that ensures every new item has a `createdAt` timestamp:

```javascript
function ensureCreatedTimestamp() {
    var context = getContext();
    var request = context.getRequest();

    // Get the item about to be created
    var itemToCreate = request.getBody();

    // Add a timestamp if one isn't present
    if (!("createdAt" in itemToCreate)) {
        itemToCreate["createdAt"] = new Date().toISOString();
    }

    // Validate required fields
    if (!itemToCreate["name"]) {
        throw new Error("Item must have a 'name' property.");
    }

    // Write the modified item back to the request
    request.setBody(itemToCreate);
}
```

The key method here is `request.setBody()`. After you modify the item, you must call this to update the request body — otherwise your changes are lost.

To register and invoke this pre-trigger from C#:

```csharp
// Register
await container.Scripts.CreateTriggerAsync(new TriggerProperties
{
    Id = "ensureCreatedTimestamp",
    Body = File.ReadAllText(@"js\ensureCreatedTimestamp.js"),
    TriggerOperation = TriggerOperation.Create,
    TriggerType = TriggerType.Pre
});

// Use the trigger when creating an item
var newItem = new { id = "item-1", orderId = "order-4567", name = "Widget A" };

await container.CreateItemAsync(
    newItem,
    new PartitionKey("order-4567"),
    new ItemRequestOptions
    {
        PreTriggers = new List<string> { "ensureCreatedTimestamp" }
    });
```

When this executes, the engine calls your pre-trigger, which stamps `createdAt` onto the item, validates that `name` is present, and then the write proceeds — all within a single transaction.

### Post-Triggers: React to Writes Atomically

A post-trigger runs *after* the item has been written but *within the same transaction*. This makes it ideal for maintaining metadata, audit logs, or aggregate documents that must stay consistent with the data they describe.

Here's a post-trigger that maintains a running count of items in a metadata document:

```javascript
function updateItemCount() {
    var context = getContext();
    var container = context.getCollection();
    var response = context.getResponse();

    // The item that was just created
    var createdItem = response.getBody();

    // Query for the metadata document
    var filterQuery = 'SELECT * FROM root r WHERE r.id = "_metadata"';
    var accept = container.queryDocuments(
        container.getSelfLink(),
        filterQuery,
        function (err, items, responseOptions) {
            if (err) throw new Error("Error: " + err.message);
            if (items.length !== 1) throw new Error("Metadata document not found.");

            var metadata = items[0];
            metadata.itemCount += 1;
            metadata.lastItemId = createdItem.id;

            var acceptReplace = container.replaceDocument(
                metadata._self,
                metadata,
                function (err, replaced) {
                    if (err) throw new Error("Unable to update metadata.");
                });

            if (!acceptReplace) throw new Error("Unable to update metadata, abort.");
        });

    if (!accept) throw new Error("Unable to query metadata, abort.");
}
```

Because the post-trigger participates in the same transaction as the write, if the metadata update fails, the original item creation is also rolled back. This gives you cross-document consistency within the partition without any client-side coordination.

To invoke it:

```csharp
await container.CreateItemAsync(
    newItem,
    new PartitionKey("order-4567"),
    new ItemRequestOptions
    {
        PostTriggers = new List<string> { "updateItemCount" }
    });
```

## User-Defined Functions (UDFs)

User-defined functions are pure JavaScript functions that you can call from within SQL queries. Unlike stored procedures and triggers, UDFs are read-only — they can't modify data. Their purpose is to encapsulate computation logic that you'd otherwise have to duplicate in application code or express awkwardly in SQL.

### Writing and Registering a UDF

Here's a UDF that calculates a tiered discount based on quantity:

```javascript
function calculateDiscount(quantity, unitPrice) {
    if (quantity == undefined || unitPrice == undefined)
        throw "Both quantity and unitPrice are required.";

    var discount;
    if (quantity >= 100) {
        discount = 0.20;  // 20% off for large orders
    } else if (quantity >= 25) {
        discount = 0.10;  // 10% off for medium orders
    } else {
        discount = 0.0;   // No discount
    }

    return unitPrice * quantity * (1 - discount);
}
```

Register it from C#:

```csharp
await container.Scripts.CreateUserDefinedFunctionAsync(
    new UserDefinedFunctionProperties
    {
        Id = "calculateDiscount",
        Body = File.ReadAllText(@"js\calculateDiscount.js")
    });
```

### Using UDFs in Queries

Once registered, you can reference UDFs in SQL queries using the `udf.` prefix:

```sql
SELECT
    c.productName,
    c.quantity,
    c.unitPrice,
    udf.calculateDiscount(c.quantity, c.unitPrice) AS totalAfterDiscount
FROM c
WHERE c.orderId = "order-4567"
```

You can also use UDFs in `WHERE` clauses to filter results:

```sql
SELECT c.productName, c.quantity
FROM c
WHERE udf.calculateDiscount(c.quantity, c.unitPrice) > 500
```

This pushes the discount logic into the query engine so it's evaluated server-side per document. The UDF runs in the same read transaction as the query.

> **A note on performance:** UDFs are invoked once per document evaluated by the query. For large result sets, this can add up. If your UDF is simple arithmetic, consider whether you can express it directly in SQL. UDFs shine when the logic is complex enough that SQL can't express it cleanly — tiered calculations, string manipulations, custom validation rules.

## Optimistic Concurrency with ETags in Server-Side Logic

Every item in Cosmos DB has a system-managed `_etag` property that changes whenever the item is updated. This is the foundation of **optimistic concurrency control (OCC)** — and it works inside stored procedures too.

When a stored procedure reads an item and then replaces it, the engine implicitly checks the `_etag` of all written items. If another operation modified the item between the procedure's read and write, the `_etag` won't match, and the entire transaction rolls back with a conflict error.

Here's how this looks in practice:

```javascript
function conditionalUpdate(itemId, expectedEtag, updates) {
    var context = getContext();
    var container = context.getCollection();
    var response = context.getResponse();

    var query = {
        query: "SELECT * FROM c WHERE c.id = @id",
        parameters: [{ name: "@id", value: itemId }]
    };

    var accept = container.queryDocuments(
        container.getSelfLink(),
        query,
        function (err, items) {
            if (err) throw new Error(err.message);
            if (items.length !== 1) throw new Error("Item not found.");

            var item = items[0];

            // Check the ETag matches what the client expects
            if (item._etag !== expectedEtag) {
                throw new Error("ETag mismatch — item was modified by another operation.");
            }

            // Apply updates
            for (var key in updates) {
                if (updates.hasOwnProperty(key)) {
                    item[key] = updates[key];
                }
            }

            var acceptReplace = container.replaceDocument(
                item._self,
                item,
                function (err, replaced) {
                    if (err) throw new Error(err.message);
                    response.setBody(replaced);
                });

            if (!acceptReplace) throw new Error("Replace was not accepted.");
        });

    if (!accept) throw new Error("Query was not accepted.");
}
```

In this example, the client passes the `_etag` value it received when it last read the item. The stored procedure checks it explicitly before applying updates. But even without that explicit check, the Cosmos DB engine would catch the conflict at commit time because `_etag` values are implicitly checked for all items written within a stored procedure. If any conflict is detected, the transaction rolls back and throws an exception.

From the client side, you handle the conflict by catching the exception and retrying with a fresh read:

```csharp
try
{
    var result = await container.Scripts.ExecuteStoredProcedureAsync<dynamic>(
        "conditionalUpdate",
        new PartitionKey("order-4567"),
        new dynamic[] { "item-1", currentEtag, new { status = "shipped" } });
}
catch (CosmosException ex) when (ex.StatusCode == System.Net.HttpStatusCode.PreconditionFailed)
{
    // ETag mismatch — re-read and retry
}
```

## Performance Considerations

Understanding the performance characteristics of server-side code helps you decide when to use it — and when to avoid it.

### Pre-Compilation

When you register a stored procedure, trigger, or UDF, Cosmos DB compiles the JavaScript to byte code and caches it. Subsequent invocations skip the compilation step entirely. This makes stored procedures particularly efficient for operations you execute frequently — the overhead is essentially just the RU cost of the data operations themselves.

### Batching Benefits

The biggest performance win from stored procedures comes from batching. Consider inserting 50 items individually from a client:

- 50 network round-trips
- 50 separate transactions
- 50 sets of request/response overhead

With a bulk-insert stored procedure:

- 1 network round-trip
- 1 transaction
- 1 set of request/response overhead

The RU cost for the data operations is roughly the same either way, but you eliminate the per-request overhead and network latency.

### Bounded Execution and Timeouts

The JavaScript runtime enforces an execution budget. If your procedure exceeds it, CRUD operations start returning `false` for `isAccepted`. This is not an error — it's by design. The procedure must return cleanly so the client can continue with the next batch.

Design your stored procedures with this in mind:

- **Always check `isAccepted`.** If you ignore it and try to keep going, the runtime will eventually terminate your procedure.
- **Return progress indicators.** Return a count, a continuation token, or the ID of the last processed item so the client knows where to resume.
- **Keep individual procedures focused.** A procedure that tries to do too much is more likely to hit execution limits and harder to debug.

### When *Not* to Use Stored Procedures

The official guidance is clear: stored procedures are best suited for **write-heavy operations that require transactions within a partition key**. They're not the right tool for:

- **Read-heavy workloads.** Queries from the client SDK are more efficient for large reads because results stream back asynchronously.
- **Cross-partition operations.** The single-partition scope is a hard constraint.
- **Complex business logic.** Without module imports, debugging tools, or a rich standard library, complex logic is better handled in your application tier.
- **Operations with high RU variance.** Because the engine reserves the average RU cost upfront, wide variance in RU consumption can lead to inefficient budget utilization.

Also keep in mind that the **transactional batch** API (available in the .NET, Java, Python, and Go SDKs) offers multi-item ACID transactions within a partition using your native language — without writing JavaScript. For many scenarios that once required stored procedures, transactional batch is now the better choice. We'll cover transactional batch in detail in Chapter 15.

## Summary

Server-side JavaScript in Cosmos DB gives you three tools:

| Feature | Purpose | Scope | Modifies Data? |
|---|---|---|---|
| **Stored Procedures** | Multi-operation transactional logic | Single partition | Yes |
| **Pre-Triggers** | Validate or enrich items before writes | Single partition | Yes (the incoming item) |
| **Post-Triggers** | React to writes atomically | Single partition | Yes (other items) |
| **UDFs** | Custom logic inside SQL queries | Query scope | No (read-only) |

All four execute within the database engine, benefit from pre-compilation, and run under snapshot isolation within their logical partition. Stored procedures and triggers provide ACID guarantees — if anything throws, everything rolls back.

The key decisions are:

1. **Do you need multi-item transactions?** If yes, and it's within a single partition, stored procedures or transactional batch are your options.
2. **Do you need validation or enrichment at write time?** Pre-triggers are a clean solution, but remember they must be specified explicitly on each request.
3. **Do you need consistent side effects from writes?** Post-triggers give you atomic metadata updates.
4. **Do you need custom computation in queries?** UDFs keep that logic server-side and reusable.

## What's Next

In Chapter 14, we'll shift from server-side logic to the **change feed** — Cosmos DB's built-in mechanism for reacting to data changes asynchronously. Where triggers give you synchronous, transactional reactions within a partition, the change feed opens up an entirely different pattern: event-driven architectures, materialized views, and real-time data pipelines that can span your entire database. You'll learn how to consume the change feed with the change feed processor, Azure Functions, and custom pull-based readers.
