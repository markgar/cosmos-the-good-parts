# Chapter 14: Stored Procedures, Triggers, and User-Defined Functions

Most of the code you write against Cosmos DB runs client-side — your application talks to the service over HTTPS, one request at a time. But Cosmos DB also lets you push JavaScript directly into the database engine and execute it there. Stored procedures, triggers, and user-defined functions (UDFs) give you server-side logic that runs inside the partition, next to the data, with transactional guarantees you can't get any other way.

That last point is the hook. If you need multi-item ACID transactions within a logical partition, server-side JavaScript is one of only two paths (the other is transactional batch, covered in Chapter 16). If you need to validate or enrich a document atomically before it's written, a pre-trigger does it in a single round trip. If your queries need custom computation that SQL can't express, a UDF extends the query language itself.

But server-side JavaScript also has sharp constraints. It's scoped to a single partition. It has a 5-second execution timeout. It can't import modules. It runs on the primary replica, consuming provisioned throughput. These aren't dealbreakers — they're boundaries you need to understand before you invest in the pattern.

This chapter is the canonical reference for server-side programming in Cosmos DB. We'll cover when to use it (and when not to), how to write and register each type, the transactional semantics, and the performance characteristics. For SDK registration and invocation mechanics, we'll build on the patterns from Chapter 7. For transactional batch as an alternative to stored procedures, see Chapter 16.

<!-- Source: stored-procedures-triggers-udfs.md, how-to-write-stored-procedures-triggers-udfs.md -->

## When and Why to Use Server-Side JavaScript

Server-side programming in Cosmos DB isn't a general-purpose compute layer. It's a targeted tool for a specific set of problems. Here's the honest assessment of where it earns its keep.

<!-- Source: stored-procedures-triggers-udfs.md -->

**Atomic multi-item writes.** This is the primary use case. If you need to update three items within the same logical partition and either all three succeed or none do, a stored procedure gives you that ACID guarantee. The JavaScript runtime wraps all operations in an implicit transaction — no `BEGIN TRANSACTION` or `COMMIT` statements needed. If your code throws an exception, everything rolls back.

**Reducing network round trips.** When you need to read an item, make a decision based on its contents, then write one or more items — all within the same partition — a stored procedure does it in a single network call. The reads and writes happen server-side, eliminating the latency of multiple client-server round trips.

**Pre-write validation and enrichment.** A pre-trigger can inspect or modify an item before it hits the database. Adding a timestamp, validating required fields, normalizing data — all without the client needing to remember to do it.

**Custom query logic.** UDFs extend the SQL query language with JavaScript functions. When you need a calculation that Cosmos DB's built-in functions don't support — custom tax brackets, specialized string parsing, domain-specific scoring — a UDF lets you express it inline in your query.

**Batched server-side mutations.** Bulk updates or deletes that touch many items in a single partition can be more efficient as a stored procedure than as a series of individual client-side calls, thanks to reduced network overhead and pre-compilation.

### When Not to Use Server-Side JavaScript

**Cross-partition operations.** Stored procedures and triggers are scoped to a single logical partition. If your operation needs to touch items across different partition key values, server-side JavaScript can't help. Use client-side logic or transactional batch (which also has the same-partition constraint).

**Read-heavy workloads.** Stored procedures run on the primary replica. For read-heavy operations, you're better off using the SDK client-side, where reads can be served by any replica (primary or secondary) and you can saturate throughput more efficiently. The docs are explicit: stored procedures are "best suited for operations that are write-heavy and require a transaction across a partition key value."

<!-- Source: stored-procedures-triggers-udfs.md -->

**Complex business logic.** Server-side JavaScript doesn't support importing modules. You can't `require()` lodash, use npm packages, or pull in shared libraries. Every function must be self-contained. If your logic is complex enough to need external dependencies, keep it client-side.

<!-- Source: how-to-write-stored-procedures-triggers-udfs.md -->

**Long-running operations.** The 5-second execution timeout is a hard ceiling. You can work around it with continuation patterns (covered later in this chapter), but if your operation inherently requires extended computation, it doesn't belong in a stored procedure.

<!-- Source: stored-procedures-triggers-udfs.md -->

| Use Case | Server-Side? | Alternative |
|----------|:------------:|-------------|
| Multi-item ACID (same partition) | ✅ | Transactional batch (Ch 16) |
| Reduce round trips (read→write) | ✅ | — |
| Pre-write validation | ✅ (pre-trigger) | App middleware |
| Custom calc in queries | ✅ (UDF) | Client post-processing |
| Cross-partition ops | ❌ | Client SDK |
| Read-heavy batches | ❌ | SDK queries (Ch 8) |
| Long-running compute | ❌ | Functions / client |
| Needs npm modules | ❌ | Client SDK |

## Stored Procedures

Stored procedures are the most powerful — and most constrained — piece of server-side programming. They run JavaScript inside the database engine with full ACID transaction support within a partition.

### Scope: Always Within a Single Logical Partition

This constraint is non-negotiable and worth repeating: **a stored procedure executes within the scope of exactly one logical partition key value.** When you call a stored procedure, you must pass a partition key value in the request. The procedure can only see and modify items that belong to that partition key value. Items with different partition key values are invisible to it, even if they're in the same container or even the same physical partition.

<!-- Source: how-to-write-stored-procedures-triggers-udfs.md -->

This scoping is what makes ACID transactions possible. Because a logical partition maps to a single physical partition (and therefore a single replica set), Cosmos DB doesn't need distributed transaction coordination. All reads and writes happen on the same node, against the same data, under the same lock scope. It's the same reason transactional batch has the same constraint — the architecture doesn't support cross-partition transactions.

### Writing a Stored Procedure

A stored procedure is a JavaScript function registered on a container. The function receives parameters from the caller and uses the `getContext()` API to interact with the database. Here's the anatomy:

```javascript
function createOrderWithAudit(order) {
    var context = getContext();
    var container = context.getCollection();
    var response = context.getResponse();

    // Validate input
    if (!order) throw new Error("Order is required.");
    if (!order.id) throw new Error("Order must have an id.");

    // Create the order item
    var orderAccepted = container.createDocument(
        container.getSelfLink(),
        order,
        function (err, createdOrder) {
            if (err) throw new Error("Failed to create order: " + err.message);

            // Create an audit log entry in the same partition
            var auditEntry = {
                id: "audit-" + order.id,
                customerId: order.customerId,
                type: "audit",
                action: "order_created",
                orderId: order.id,
                timestamp: new Date().toISOString()
            };

            var auditAccepted = container.createDocument(
                container.getSelfLink(),
                auditEntry,
                function (err, createdAudit) {
                    if (err) throw new Error("Failed to create audit: " + err.message);
                    response.setBody({ orderId: createdOrder.id, auditId: createdAudit.id });
                }
            );

            if (!auditAccepted) throw new Error("Audit creation not accepted.");
        }
    );

    if (!orderAccepted) throw new Error("Order creation not accepted.");
}
```

A few things to notice:

- **`getContext()`** is the entry point to everything. It gives you the collection (container), the request, and the response objects.
- **Callback-based async.** Every CRUD operation (`createDocument`, `replaceDocument`, `deleteDocument`, `queryDocuments`) is asynchronous and takes a callback. The callback pattern is how you sequence dependent operations.
- **The boolean return value.** Each CRUD method returns `true` if the operation was accepted or `false` if it wasn't — meaning the procedure is running out of time or throughput. This is the mechanism for bounded execution, which we'll cover shortly.
- **`response.setBody()`** sends data back to the caller. Whatever you pass here becomes the stored procedure's return value.

You can also use `async/await` with a Promise wrapper — the Cosmos DB JavaScript runtime supports it:

<!-- Source: how-to-write-stored-procedures-triggers-udfs.md -->

```javascript
function updateOrderStatus() {
    const asyncHelper = {
        queryDocuments(sqlQuery, options) {
            return new Promise((resolve, reject) => {
                const isAccepted = __.queryDocuments(
                    __.getSelfLink(), sqlQuery, options,
                    (err, feed, options) => {
                        if (err) reject(err);
                        resolve({ feed, options });
                    }
                );
                if (!isAccepted) reject(new Error("queryDocuments not accepted."));
            });
        },
        replaceDocument(doc) {
            return new Promise((resolve, reject) => {
                const isAccepted = __.replaceDocument(
                    doc._self, doc,
                    (err, result, options) => {
                        if (err) reject(err);
                        resolve({ result, options });
                    }
                );
                if (!isAccepted) reject(new Error("replaceDocument not accepted."));
            });
        }
    };

    async function main() {
        let { feed } = await asyncHelper.queryDocuments(
            "SELECT * FROM c WHERE c.type = 'order' AND c.status = 'pending'"
        );

        for (let order of feed) {
            order.status = "processing";
            order.updatedAt = new Date().toISOString();
            await asyncHelper.replaceDocument(order);
        }

        getContext().getResponse().setBody({ updated: feed.length });
    }

    main().catch(err => getContext().abort(err));
}
```

The `__` (double underscore) is a shorthand alias for `getContext().getCollection()` — available in the server-side runtime. And `getContext().abort(err)` explicitly rolls back the transaction and returns an error to the caller. Think of `abort()` as the async equivalent of `throw` — when you're using Promises instead of callbacks, you can't rely on a thrown exception to unwind the transaction, so `abort()` gives you explicit rollback control.

### Registering a Stored Procedure

A stored procedure must be registered on a container before you can call it. Registration is a one-time operation — once registered, you call the procedure by its ID. You can register through the Azure portal's Data Explorer, through ARM/Bicep templates, or through any of the SDKs.

Here's how registration and invocation look in the three main SDKs. If you set up your client and container references as described in Chapter 7, this is straightforward.

**C# (.NET SDK v3)**
```csharp
// Register
string sprocBody = File.ReadAllText("createOrderWithAudit.js");
await container.Scripts.CreateStoredProcedureAsync(
    new StoredProcedureProperties
    {
        Id = "createOrderWithAudit",
        Body = sprocBody
    }
);

// Execute
var order = new
{
    id = "order-5001",
    customerId = "cust-337",
    type = "order",
    status = "pending",
    total = 149.99
};

var result = await container.Scripts.ExecuteStoredProcedureAsync<dynamic>(
    "createOrderWithAudit",
    new PartitionKey("cust-337"),
    new dynamic[] { order }
);

Console.WriteLine($"Result: {result.Resource}");
Console.WriteLine($"RU charge: {result.RequestCharge}");
```

<!-- Source: how-to-use-stored-procedures-triggers-udfs.md -->

**JavaScript (Node.js SDK)**
```javascript
// Register
const fs = require("fs");
const container = client.database("cosmicworks").container("orders");
await container.scripts.storedProcedures.create({
    id: "createOrderWithAudit",
    body: fs.readFileSync("./createOrderWithAudit.js", "utf-8")
});

// Execute
const order = {
    id: "order-5001",
    customerId: "cust-337",
    type: "order",
    status: "pending",
    total: 149.99
};

const { resource: result } = await container.scripts
    .storedProcedure("createOrderWithAudit")
    .execute("cust-337", [order]);
```

**Python**
```python
# Register
with open("createOrderWithAudit.js") as f:
    sproc_body = f.read()

sproc_definition = {
    "id": "createOrderWithAudit",
    "serverScript": sproc_body,
}
container.scripts.create_stored_procedure(body=sproc_definition)

# Execute
order = {
    "id": "order-5001",
    "customerId": "cust-337",
    "type": "order",
    "status": "pending",
    "total": 149.99,
}

result = container.scripts.execute_stored_procedure(
    sproc="createOrderWithAudit",
    params=[order],
    partition_key="cust-337"
)
```

Notice the partition key is always required when executing. This isn't optional — it's how Cosmos DB knows which logical partition to run the procedure against.

### Transactional Semantics: All or Nothing

Here's the core guarantee: **all operations within a stored procedure execute as a single, implicit transaction.** If the procedure completes without throwing an exception, every read and write it performed is committed atomically. If it throws — whether your code throws deliberately or the runtime throws due to a timeout — the entire transaction rolls back. No partial writes, no orphaned state.

<!-- Source: stored-procedures-triggers-udfs.md -->

This is real ACID:

- **Atomicity:** All operations succeed together or fail together.
- **Consistency:** The data is in a valid state after the transaction completes.
- **Isolation:** No other operations see the in-flight changes until commit.
- **Durability:** Once committed, the writes are persisted.

There are no `BEGIN TRANSACTION` or `COMMIT TRANSACTION` statements. The transaction boundary is the stored procedure itself. Throwing an exception is your `ROLLBACK`. This simplicity is elegant, but it means you need to be careful about error handling — an unhandled exception in a callback will abort everything.

> **Key takeaway:** Pass data between operations through variables, not by querying for items you just wrote.

Queries within a stored procedure don't see writes made earlier in the same execution. If you create an item and then immediately query for it in the same stored procedure, the query won't return it. This applies to both SQL queries via `queryDocuments()` and the JavaScript integrated query API via `filter()`.

<!-- Source: stored-procedures-triggers-udfs.md -->

> **Note on consistency levels:** Stored procedures always execute on the primary replica, so reads within them are strongly consistent regardless of your account's default consistency level. However, the docs note that using stored procedures *with* strong consistency configured at the account level "isn't suggested as mutations are local" — the strong consistency guarantee applies to the reads *inside* the sproc, but replication to other regions still follows your configured consistency. For the full consistency model, see Chapter 13.

<!-- Source: stored-procedures-triggers-udfs.md -->

For a deeper dive into transaction concepts, optimistic concurrency with ETags, and transactional batch as a lighter-weight alternative to stored procedures, see Chapter 16.

### Handling Continuation for Large Operations

All server-side JavaScript — stored procedures, triggers, and UDFs — must complete within a **5-second timeout**. If the timeout expires, the transaction rolls back. For stored procedures that need to process more items than 5 seconds allows, you need a **continuation-based pattern**.

<!-- Source: stored-procedures-triggers-udfs.md -->

The pattern works like this: every CRUD operation returns a boolean indicating whether it was accepted. If it returns `false`, the runtime is signaling that you're running low on time or throughput. Your procedure should stop, return the progress it's made so far, and let the caller re-invoke with the remaining work.

Here's a bulk-delete procedure that uses this pattern:

```javascript
function bulkDelete(query) {
    var context = getContext();
    var container = context.getCollection();
    var response = context.getResponse();
    var deletedCount = 0;

    var accept = container.queryDocuments(
        container.getSelfLink(),
        query,
        function (err, items) {
            if (err) throw new Error("Query failed: " + err.message);
            if (items.length === 0) {
                response.setBody({ deleted: deletedCount, continuation: false });
                return;
            }
            tryDelete(items);
        }
    );

    if (!accept) {
        response.setBody({ deleted: deletedCount, continuation: true });
    }

    function tryDelete(items) {
        if (items.length === 0) {
            response.setBody({ deleted: deletedCount, continuation: false });
            return;
        }

        var item = items[0];
        var accept = container.deleteDocument(
            item._self,
            {},
            function (err) {
                if (err) throw new Error("Delete failed: " + err.message);
                deletedCount++;
                tryDelete(items.slice(1));
            }
        );

        // Operation not accepted — running out of time/RUs
        if (!accept) {
            response.setBody({ deleted: deletedCount, continuation: true });
        }
    }
}
```

The caller loops until the procedure reports no more work:

```csharp
bool hasContinuation = true;
int totalDeleted = 0;

while (hasContinuation)
{
    var result = await container.Scripts.ExecuteStoredProcedureAsync<dynamic>(
        "bulkDelete",
        new PartitionKey("cust-337"),
        new dynamic[] { "SELECT * FROM c WHERE c.type = 'audit' AND c.timestamp < '2024-01-01'" }
    );

    totalDeleted += (int)result.Resource.deleted;
    hasContinuation = (bool)result.Resource.continuation;
}

Console.WriteLine($"Total deleted: {totalDeleted}");
```

Each invocation is its own transaction — items deleted in one call are committed before the next call starts. This means the overall operation is *not* atomic across invocations. If that's a problem for your use case, you need to design your procedure to fit within a single 5-second execution.

> **Gotcha:** Scripts that repeatedly violate execution boundaries may be marked inactive by the runtime and can't be executed until they're recreated. Always respect the boolean return value and implement proper continuation logic.

<!-- Source: stored-procedures-triggers-udfs.md -->

### The RU Charging Model for Stored Procedures

Cosmos DB charges stored procedures differently from regular operations. Each execution reserves RUs upfront based on the average cost of previous invocations. This pre-reservation ensures that the procedure doesn't starve other workloads, but it means your budget utilization can be unpredictable if the RU cost varies significantly between invocations. If you're seeing budget surprises, the docs suggest considering batch or bulk requests as alternatives.
<!-- Source: how-to-write-stored-procedures-triggers-udfs.md -->

Server-side operations also consume additional throughput beyond what the individual CRUD operations cost — though the database operations within a stored procedure are slightly cheaper than equivalent client-side operations. The tradeoff is reduced network overhead versus the compute cost of running your JavaScript in the database engine. For RU optimization strategies more broadly, see Chapter 10.

## Pre-Triggers and Post-Triggers

Triggers let you hook into write operations — running JavaScript before or after an item is created, replaced, updated, or deleted. Like stored procedures, they execute on the primary replica within the scope of a single logical partition, but unlike stored procedures, they're tied to a specific operation type and fire as part of that operation's transaction.

One critical detail up front: **triggers do not fire automatically.** Unlike SQL Server or PostgreSQL triggers that run implicitly on every matching operation, Cosmos DB triggers must be explicitly specified in the request options for each operation. If your code doesn't ask for the trigger, it doesn't run. This is by design — it avoids hidden side effects and gives you explicit control.

<!-- Source: stored-procedures-triggers-udfs.md -->

### Pre-Triggers: Validate or Modify Items Before Writes

A pre-trigger runs *before* the write operation. It can inspect the incoming item, validate it, modify it, or reject it by throwing an exception. The trigger accesses the request body, not the response — because the item hasn't been written yet.

Here's a pre-trigger that ensures every order has a `createdAt` timestamp and a calculated `tax` field:

```javascript
function ensureOrderDefaults() {
    var context = getContext();
    var request = context.getRequest();
    var item = request.getBody();

    // Add timestamp if missing
    if (!item.createdAt) {
        item.createdAt = new Date().toISOString();
    }

    // Calculate tax if not provided
    if (item.subtotal && !item.tax) {
        item.tax = Math.round(item.subtotal * 0.0875 * 100) / 100;
        item.total = item.subtotal + item.tax;
    }

    // Validate required fields
    if (!item.customerId) {
        throw new Error("Order must have a customerId.");
    }

    // Write the modified item back to the request
    request.setBody(item);
}
```

<!-- Source: how-to-write-stored-procedures-triggers-udfs.md -->

Key details about pre-triggers:

- **No input parameters.** Pre-triggers get their data from the request object — specifically `context.getRequest().getBody()`.
- **Operation-specific.** When you register a trigger, you specify which operation type it applies to (`Create`, `Replace`, `Delete`). A trigger registered for `Create` can't run on a replace operation.
- **Mutate via `setBody()`.** After modifying the item, you must call `request.setBody()` to push the changes back. Otherwise your modifications are lost.

### Post-Triggers: React to Writes Atomically

A post-trigger runs *after* the operation completes but *within the same transaction.* This means if the post-trigger throws an exception, the entire operation — including the original write — rolls back. The post-trigger has access to the response body (the item as written) and can perform additional operations on the container.

<!-- Source: how-to-write-stored-procedures-triggers-udfs.md -->

Here's a post-trigger that maintains a running count in a metadata document whenever a new order is created:

```javascript
function updateOrderMetadata() {
    var context = getContext();
    var container = context.getCollection();
    var response = context.getResponse();
    var createdItem = response.getBody();

    // Query for the metadata document in this partition
    var query = {
        query: "SELECT * FROM c WHERE c.id = @metaId",
        parameters: [{ name: "@metaId", value: "metadata-" + createdItem.customerId }]
    };

    var accept = container.queryDocuments(
        container.getSelfLink(),
        query,
        function (err, items) {
            if (err) throw new Error("Metadata query failed: " + err.message);

            if (items.length === 0) {
                // Create metadata doc if it doesn't exist
                var meta = {
                    id: "metadata-" + createdItem.customerId,
                    customerId: createdItem.customerId,
                    type: "metadata",
                    orderCount: 1,
                    lastOrderId: createdItem.id
                };
                var createAccepted = container.createDocument(
                    container.getSelfLink(), meta,
                    function (err) { if (err) throw err; }
                );
                if (!createAccepted) throw new Error("Metadata create not accepted.");
            } else {
                // Update existing metadata
                var meta = items[0];
                meta.orderCount += 1;
                meta.lastOrderId = createdItem.id;
                var replaceAccepted = container.replaceDocument(
                    meta._self, meta,
                    function (err) { if (err) throw err; }
                );
                if (!replaceAccepted) throw new Error("Metadata update not accepted.");
            }
        }
    );

    if (!accept) throw new Error("Metadata query not accepted.");
}
```

The atomicity guarantee here is powerful: either the order *and* the metadata update both commit, or neither does. You'd need a stored procedure or transactional batch to get equivalent guarantees without a trigger.

### Registering and Invoking Triggers

Registration works similarly to stored procedures, but you specify the trigger type (`Pre` or `Post`) and the operation it applies to (`Create`, `Replace`, `Delete`, `All`).

**C# (.NET SDK v3)**
```csharp
// Register a pre-trigger
await container.Scripts.CreateTriggerAsync(new TriggerProperties
{
    Id = "ensureOrderDefaults",
    Body = File.ReadAllText("ensureOrderDefaults.js"),
    TriggerOperation = TriggerOperation.Create,
    TriggerType = TriggerType.Pre
});

// Register a post-trigger
await container.Scripts.CreateTriggerAsync(new TriggerProperties
{
    Id = "updateOrderMetadata",
    Body = File.ReadAllText("updateOrderMetadata.js"),
    TriggerOperation = TriggerOperation.Create,
    TriggerType = TriggerType.Post
});

// Use both triggers when creating an item
var order = new { id = "order-6001", customerId = "cust-337", type = "order", subtotal = 89.99 };

await container.CreateItemAsync(
    order,
    new PartitionKey("cust-337"),
    new ItemRequestOptions
    {
        PreTriggers = new List<string> { "ensureOrderDefaults" },
        PostTriggers = new List<string> { "updateOrderMetadata" }
    }
);
```

<!-- Source: how-to-use-stored-procedures-triggers-udfs.md -->

**JavaScript (Node.js SDK)**
```javascript
// Register
await container.scripts.triggers.create({
    id: "ensureOrderDefaults",
    body: fs.readFileSync("./ensureOrderDefaults.js", "utf-8"),
    triggerOperation: "create",
    triggerType: "pre"
});

// Invoke — specify the trigger in the request options
const order = { id: "order-6001", customerId: "cust-337", type: "order", subtotal: 89.99 };
await container.items.create(order, {
    preTriggerInclude: ["ensureOrderDefaults"],
    postTriggerInclude: ["updateOrderMetadata"]
});
```

> **Gotcha:** Even though trigger names are passed as an array (or `List`), you can only run one trigger per operation. The array type is a quirk of the API surface, not support for chaining multiple triggers.

<!-- Source: how-to-use-stored-procedures-triggers-udfs.md -->

## User-Defined Functions (UDFs) in Queries

UDFs are the simplest of the three server-side constructs. They're pure JavaScript functions — no access to the context object, no reads, no writes, no transactions. They receive input values, compute something, and return a result. Their purpose is extending the SQL query language with custom logic.

<!-- Source: stored-procedures-triggers-udfs.md -->

Because UDFs are compute-only and don't access the database, they can run on any replica — primary or secondary. This makes them fundamentally different from stored procedures and triggers, which always run on the primary.

<!-- Source: stored-procedures-triggers-udfs.md -->

### Writing and Registering a UDF

Here's a UDF that calculates a loyalty discount based on a customer's tier:

```javascript
function loyaltyDiscount(tier, subtotal) {
    if (!tier || !subtotal) return 0;

    switch (tier.toLowerCase()) {
        case "platinum": return Math.round(subtotal * 0.15 * 100) / 100;
        case "gold":     return Math.round(subtotal * 0.10 * 100) / 100;
        case "silver":   return Math.round(subtotal * 0.05 * 100) / 100;
        default:         return 0;
    }
}
```

Registration follows the same SDK pattern:

**C# (.NET SDK v3)**
```csharp
await container.Scripts.CreateUserDefinedFunctionAsync(
    new UserDefinedFunctionProperties
    {
        Id = "loyaltyDiscount",
        Body = File.ReadAllText("loyaltyDiscount.js")
    }
);
```

<!-- Source: how-to-use-stored-procedures-triggers-udfs.md -->

**JavaScript (Node.js SDK)**
```javascript
await container.scripts.userDefinedFunctions.create({
    id: "loyaltyDiscount",
    body: fs.readFileSync("./loyaltyDiscount.js", "utf-8")
});
```

**Python**
```python
with open("loyaltyDiscount.js") as f:
    udf_body = f.read()

container.scripts.create_user_defined_function({
    "id": "loyaltyDiscount",
    "serverScript": udf_body,
})
```

### Using UDFs in SELECT and WHERE Clauses

Once registered, you call a UDF in SQL queries using the `udf.` prefix. UDFs work in both `SELECT` (to compute derived values) and `WHERE` (to filter).

**In SELECT — compute a discount for each order:**

```sql
SELECT
    c.id,
    c.customerId,
    c.subtotal,
    c.loyaltyTier,
    udf.loyaltyDiscount(c.loyaltyTier, c.subtotal) AS discount,
    c.subtotal - udf.loyaltyDiscount(c.loyaltyTier, c.subtotal) AS finalPrice
FROM c
WHERE c.type = "order"
```

**In WHERE — filter to orders where the discount exceeds a threshold:**

```sql
SELECT c.id, c.subtotal, c.loyaltyTier
FROM c
WHERE c.type = "order"
    AND udf.loyaltyDiscount(c.loyaltyTier, c.subtotal) > 10.00
```

You invoke these queries through the normal SDK query methods — nothing special about how you execute a query that contains a UDF. For a detailed walkthrough of query execution patterns, see Chapter 8.

```csharp
var query = new QueryDefinition(
    "SELECT c.id, c.subtotal, udf.loyaltyDiscount(c.loyaltyTier, c.subtotal) AS discount FROM c WHERE c.type = 'order'"
);

using var iterator = container.GetItemQueryIterator<dynamic>(query);
while (iterator.HasMoreResults)
{
    var response = await iterator.ReadNextAsync();
    foreach (var item in response)
    {
        Console.WriteLine($"Order {item.id}: ${item.subtotal} - ${item.discount} discount");
    }
}
```

<!-- Source: how-to-use-stored-procedures-triggers-udfs.md -->

### UDF Limitations

UDFs keep things simple, but that simplicity comes with trade-offs:

- **No database access.** A UDF can't read or write items. It's a pure function.
- **No context object.** Unlike stored procedures and triggers, UDFs don't get `getContext()`. They receive parameters and return a value — that's it.
- **Performance impact on queries.** A UDF in a `WHERE` clause forces the engine to evaluate the JavaScript function for every candidate document, effectively bypassing the index for that predicate. <!-- Source: community-confirmed behavior; no explicit docs statement --> For large datasets, this can make queries significantly more expensive in RUs. If you can express the same filter using built-in SQL operators, prefer that. Use UDFs for logic that genuinely can't be expressed any other way.
- **No module imports.** The same restriction as stored procedures and triggers — your function must be self-contained.

## Performance Considerations

Server-side JavaScript isn't a magic performance booster, but it has genuine advantages in the right scenarios. Here's what matters.

### Pre-Compilation

Stored procedures, triggers, and UDFs are implicitly **pre-compiled to byte code** when they're registered. This means the compilation cost is paid once, at registration time, not on every invocation. Subsequent calls skip parsing and compiling, going straight to execution. This makes invocations fast and lightweight in terms of overhead — especially for frequently-called procedures.

<!-- Source: stored-procedures-triggers-udfs.md -->

### Batching Benefits

The biggest performance win from stored procedures isn't the compute — it's the network. A stored procedure that creates 50 items does it in a single round trip. The equivalent client-side code would make 50 separate HTTP requests (or use bulk mode, which batches at the SDK level). The stored procedure eliminates the network latency for each intermediate operation.

This advantage compounds when you're doing read-modify-write patterns. A client-side implementation reads an item (1 round trip), makes a decision, then writes an update (1 more round trip). A stored procedure does both without leaving the server.

### When the Trade-Offs Don't Pay Off

Server-side JavaScript isn't free. Beyond the 5-second timeout and the single-partition scope, keep these in mind:

- **Debugging is harder.** You can enable script logging by setting `EnableScriptLogging` to `true` in the request options, which gives you `console.log()` output in the response headers. But there's no step debugger, no breakpoints, no stack traces with source maps. Test your logic locally before deploying.

<!-- Source: how-to-write-stored-procedures-triggers-udfs.md -->

- **Versioning is your problem.** Stored procedures are registered by ID. Updating a procedure means replacing it — there's no built-in versioning. Treat your `.js` files as code artifacts: version them in source control, deploy them through your CI/CD pipeline, and test them against the emulator (Chapter 3) before pushing to production.
- **RU cost variance.** If your procedure's RU consumption varies wildly between invocations (say, sometimes it touches 5 items and sometimes 500), the upfront reservation based on historical averages can lead to budget unpredictability. For more stable RU costs on bulk operations, consider transactional batch or SDK bulk mode instead.

### Consider the Change Feed Instead of Post-Triggers

If your post-trigger logic is about reacting to writes — updating materialized views, sending notifications, syncing to other stores — consider the change feed instead (Chapter 15). It decouples the reaction from the write, scales independently, and doesn't risk failing your original write if the downstream logic has a problem.

Post-triggers are the better choice when the atomicity guarantee is essential: the reaction *must* succeed or the write must roll back.

| Factor | Server-Side | Client-Side |
|--------|:-----------:|:-----------:|
| Network trips | Single | Multiple (or bulk) |
| ACID transactions | ✅ Implicit | Batch only (Ch 16) |
| Debugging | `console.log` | Full debugger |
| Module imports | ❌ | Full ecosystem |
| Timeout | 5 sec | No limit |
| Partition scope | Single | Any |
| Pre-compilation | ✅ Cached | N/A |
| Replica | Primary only | Any for reads |

Server-side JavaScript in Cosmos DB is a precision tool. It solves a narrow set of problems — multi-item transactions, pre-write validation, custom query logic — and solves them well. The key is knowing which problems fit and which are better handled client-side or through the change feed. When you need atomic multi-item operations within a partition, it's indispensable. When you don't, the client SDK gives you more flexibility, better debugging, and no 5-second clock ticking in the background.

Chapter 15 introduces the change feed — a fundamentally different approach to reacting to data changes that scales independently from your write path.
