# Chapter 26: Multi-Tenancy Patterns

Every SaaS product eventually faces the same question: how do you store data for hundreds — or thousands — of customers in one database without letting Tenant A's midnight batch job ruin Tenant B's morning? Cosmos DB gives you more options than most databases do, ranging from total isolation to maximum density. The right choice depends on how many tenants you have, how much they vary in size, and how seriously you take the words "data isolation" in your contracts.

This chapter is the canonical home for tenant isolation, throughput sharing, and fleet management in Cosmos DB. We'll reference concepts introduced earlier — hierarchical partition keys (Chapter 5), capacity models (Chapter 11), and RBAC (Chapter 17) — and expand on how each one applies specifically to multi-tenant design.

## The Isolation Spectrum

Multi-tenancy in Cosmos DB lives on a spectrum. At one end, every tenant gets their own account. At the other, all tenants share a single container, separated only by partition key values. In between, you've got container-per-tenant and database-per-tenant designs. Each point on the spectrum trades isolation for density.

| Model | Isolation | Cost |
|---|---|---|
| **Account-per-tenant** | Highest (physical) | Lowest |
| **Database-per-tenant** | High (logical) | Moderate |
| **Container-per-tenant** | Moderate | Moderate |
| **Shared container (HPK)** | Logical only | Highest |

| Model | Mgmt Overhead | Tenant Limit |
|---|---|---|
| **Account-per-tenant** | Highest | ~250/sub (1K w/ support) |
| **Database-per-tenant** | Moderate | 500 combined/account |
| **Container-per-tenant** | Moderate | 500 combined/account |
| **Shared container (HPK)** | Lowest | Unlimited |

The 500 limit counts databases and containers combined per account. Account-per-tenant carries the highest management overhead — one account per customer. The ~250 account-per-subscription limit can be raised to 1,000 via support request.

<!-- Source: concepts-limits.md (250 accounts/subscription, 500 databases+containers/account) -->
<!-- Source: nosql-multi-tenancy-vector-search.md -->

Let's walk through each one.

### Account-per-Tenant

Every tenant gets a dedicated Cosmos DB account with its own endpoint, keys, network policies, and throughput. This is the maximum isolation model. Tenant data is physically separated — there's no way for a bug in your query layer to accidentally return another tenant's documents. Each tenant can have their own geo-replication configuration, backup policy, consistency level, and customer-managed encryption keys.

The downsides are real. You're managing hundreds of accounts, each with its own monitoring, key rotation, and throughput provisioning. The default limit is 250 accounts per Azure subscription, raisable to 1,000 via a support ticket. And each idle account still costs money — a container with 400 RU/s manual throughput is your floor. <!-- Source: concepts-limits.md -->

**Choose this when:** your tenants are large enterprises with contractual isolation requirements, need per-tenant geo-replication or CMK encryption, or when regulatory compliance demands physical data separation.

### Database-per-Tenant

Each tenant gets their own database within a shared Cosmos DB account. You can provision throughput at the database level and let the tenant's containers share it, or give specific containers dedicated throughput. This gives you separate namespaces, separate throughput controls, and the ability to scope RBAC role assignments to a specific database (more on that shortly).

The limit to watch is 500 total databases and containers per account. If each tenant has one database with two containers, you're capped at around 166 tenants per account. That's fine for a B2B product with dozens of large customers, but it won't scale to thousands. <!-- Source: concepts-limits.md -->

**Choose this when:** you need per-tenant throughput isolation and RBAC scoping, but don't need the full physical separation of dedicated accounts.

### Container-per-Tenant

Similar to database-per-tenant, but each tenant gets one container inside a shared database. You provision dedicated throughput per container, giving each tenant guaranteed RU/s. RBAC can be scoped to individual containers.

Same 500-resource limit applies. If your tenants are relatively uniform and you just need throughput isolation without the overhead of managing separate accounts, this can be a good middle ground. But for high tenant counts, you'll hit the ceiling fast.

**Choose this when:** you have a moderate number of tenants (low hundreds) that need throughput guarantees but can share an account.

### Shared Container with Partition Key Isolation

This is the highest-density model. All tenants live in a single container, separated by a `tenantId` partition key. It's the most cost-efficient approach because you're sharing throughput across all tenants and managing a single container.

**Choose this when:** you have hundreds to thousands of tenants, most are small to medium, and logical isolation is sufficient. This is the default pattern for high-density SaaS applications.

The rest of this chapter focuses primarily on this model, because it's where the interesting design decisions live. If you're going with account-per-tenant, the design is straightforward — you're just multiplying the single-tenant patterns from the rest of this book across many accounts (and Cosmos DB Fleets, covered later in this chapter, helps you manage that at scale).

## Shared Container Multi-Tenancy with Partition Key Isolation

The core idea is simple: include a `tenantId` (or equivalent) as part of your partition key, and every query includes that tenant identifier. Cosmos DB routes the request to the correct logical partition, and the tenant never sees anyone else's data — as long as your application layer always includes the filter.

A typical document looks like this:

```json
{
  "id": "order-2847",
  "tenantId": "acme-corp",
  "type": "order",
  "customerId": "cust-019",
  "total": 249.99,
  "status": "shipped",
  "createdAt": "2025-06-10T14:22:00Z"
}
```

Every read, query, and write operation targets a specific `tenantId`. Point reads and queries scoped to a single tenant hit only the physical partitions that hold that tenant's data — no fan-out, no cross-partition overhead.

### The 20 GB Problem

Here's where shared-container multi-tenancy gets tricky. A single logical partition in Cosmos DB can hold a maximum of 20 GB of data and consume at most 10,000 RU/s. <!-- Source: concepts-limits.md --> For most tenants, that's plenty. But if you have even one tenant that blows past 20 GB — and in a SaaS product, you almost always will — you've got a problem. You can't add more data to that partition key, and you'll start getting errors.

This is exactly the problem hierarchical partition keys solve.

## Hierarchical Partition Keys for Multi-Tenant Workloads

Chapter 5 introduced hierarchical partition keys (HPK) as a way to break past the 20 GB logical partition limit. In a multi-tenant context, HPK is the difference between a design that works for your first 50 tenants and one that scales to your first 5,000.

With HPK, you define up to three levels of partition key hierarchy. For a multi-tenant workload, a typical pattern is:

```
/tenantId → /userId → /id
```

Or for a multi-entity container:

```
/tenantId → /entityType → /id
```

The first-level key (`tenantId`) ensures that queries scoped to a single tenant are routed only to the physical partitions holding that tenant's data — no full fan-out. The second and third levels provide the cardinality that lets a single tenant's data spread across multiple physical partitions when it exceeds 20 GB. <!-- Source: hierarchical-partition-keys.md -->

### Creating an HPK Container

Here's how you create a container with hierarchical partition keys in the .NET SDK:

```csharp
List<string> subpartitionKeyPaths = new List<string> {
    "/tenantId",
    "/userId",
    "/sessionId"
};

ContainerProperties containerProperties = new ContainerProperties(
    id: "events",
    partitionKeyPaths: subpartitionKeyPaths
);

Container container = await database.CreateContainerIfNotExistsAsync(
    containerProperties, throughput: 400);
```

<!-- Source: hierarchical-partition-keys.md -->

And in Python:

```python
container = database.create_container(
    id="events",
    partition_key=PartitionKey(
        path=["/tenantId", "/userId", "/sessionId"],
        kind="MultiHash"
    )
)
```

<!-- Source: hierarchical-partition-keys.md -->

In an ARM/Bicep template, the partition key definition looks like:

```bicep
partitionKey: {
  paths: [
    '/tenantId'
    '/userId'
    '/sessionId'
  ]
  kind: 'MultiHash'
  version: 2
}
```

<!-- Source: hierarchical-partition-keys.md -->

### Why the Lowest Level Should Have High Cardinality

The docs are clear on this: the lowest level of your hierarchical partition key should have high cardinality — ideally an ID or GUID. <!-- Source: nosql-multi-tenancy-vector-search.md --> This ensures continuous scalability beyond 20 GB per tenant. If your lowest-level key has only a handful of unique values, you'll recreate the same 20 GB ceiling at a deeper level.

A common pattern is to use the item `id` as the final level. This guarantees that no combination of keys produces a logical partition larger than a single document, effectively making the 20 GB limit irrelevant.

### The Low-Cardinality First-Level Trap {#low-cardinality-trap}

If your first-level key (`tenantId`) has very few unique values — say, five tenants — HPK can actually hurt you. Cosmos DB optimizes HPK by co-locating all documents with the same first-level key on the same physical partition (until it grows enough to split). With only five tenants, your entire dataset starts on five physical partitions, which limits your write throughput to roughly 5 × 10,000 = 50,000 RU/s until the system splits those partitions. Splits happen automatically at 50 GB but take 4–6 hours to complete. <!-- Source: hierarchical-partition-keys.md -->

For write-heavy workloads with few tenants, this is a real bottleneck. If that's your situation, you may be better off with a flat partition key that has higher cardinality, or the container-per-tenant model.

### Query Routing with HPK

Queries that include the first-level key (the tenant ID) are efficiently routed to only the physical partitions holding that tenant's data. If a tenant's data spans five physical partitions, the query hits five — not all 1,000 in the container. Specifying additional levels in the filter narrows the routing further. <!-- Source: hierarchical-partition-keys.md -->

This is the core value proposition for multi-tenant HPK: you get the density of a shared container with the query efficiency of tenant-scoped routing.

## Enforcing Tenant Data Isolation with RBAC and Resource Tokens

Partition key isolation is only as strong as your application code. If a bug in your middleware drops the `tenantId` filter from a query, you'll scan across all tenants. There are two mechanisms to add a security backstop: data-plane RBAC and resource tokens. Chapter 17 covers RBAC comprehensively — here, we'll focus on how to apply those mechanisms specifically to tenant isolation.

### Data-Plane RBAC Scoping

Cosmos DB's native data-plane RBAC lets you scope role assignments at three levels of granularity: account, database, or container. <!-- Source: how-to-connect-role-based-access-control.md, reference-data-plane-security.md -->

The scope format follows the resource hierarchy:

```
# Account-wide
/subscriptions/{sub}/resourcegroups/{rg}/providers/Microsoft.DocumentDB/databaseAccounts/{account}/

# Database-scoped
/subscriptions/{sub}/resourcegroups/{rg}/providers/Microsoft.DocumentDB/databaseAccounts/{account}/dbs/{database}

# Container-scoped
/subscriptions/{sub}/resourcegroups/{rg}/providers/Microsoft.DocumentDB/databaseAccounts/{account}/dbs/{database}/colls/{container}
```

<!-- Source: how-to-connect-role-based-access-control.md -->

For **database-per-tenant** or **container-per-tenant** models, this is powerful. You can assign each tenant's service principal (or managed identity) a role scoped to their specific database or container. The tenant's identity literally cannot read from or write to another tenant's resources — the service enforces it, regardless of what your application code does.

For **shared-container** models, RBAC scoping stops at the container level. You can't scope a role assignment to a specific partition key value within a container. This means the security boundary is your application code — specifically, the middleware or data access layer that injects `tenantId` into every operation.

### Resource Tokens (Legacy)

Resource tokens are the older mechanism for granting scoped, time-limited access to Cosmos DB resources. You create a user and permission resource in the database, and the resulting token grants access to a specific container (or even a specific partition key range). <!-- Source: security-considerations.md -->

Resource tokens can be scoped more narrowly than RBAC — down to a partition key value — which makes them useful for shared-container multi-tenancy where you want the service itself to enforce tenant boundaries. However, they come with significant operational overhead: you need a token-brokering service to generate and manage short-lived tokens, and the mechanism predates Microsoft Entra ID integration.

> **⚠️ HPK limitation:** Hierarchical partition keys aren't currently supported with the users and permissions feature. You can't assign a permission to a partial prefix of the hierarchical partition key path — only to the full key path. For example, if you've partitioned by `TenantId` → `UserId`, you can't create a permission scoped to just a `TenantId` value. You'd need to specify both `TenantId` *and* `UserId`. This makes resource tokens impractical for tenant-level isolation in HPK containers. <!-- Source: hierarchical-partition-keys.md -->

**The recommendation for new applications is to use data-plane RBAC with Microsoft Entra ID** and rely on your application's data access layer for partition-level isolation. Resource tokens are still supported but are effectively a legacy pattern. If you're building greenfield, skip them.

### Defense in Depth for Shared Containers

For the shared-container model, enforce tenant isolation at multiple levels:

1. **Application layer.** Your data access layer should require a `tenantId` on every operation and inject it into partition key values and query filters. Make it impossible to call the database without specifying a tenant.
2. **RBAC.** Scope data-plane roles to the specific container, so even if an attacker compromises credentials, they can't reach other containers in the account.
3. **Audit.** Enable diagnostic logging and monitor for queries that don't include `tenantId` in the filter predicate. If you see cross-partition fan-out queries on a container that should always be single-partition, that's a red flag.

## Throughput Management: Dedicated vs. Shared RU/s per Tenant

How you provision throughput directly affects tenant experience. A "noisy neighbor" — one tenant whose burst of writes consumes all available RU/s — can cause 429 throttling errors for everyone else sharing that throughput pool. Chapter 11 covers capacity models in depth; here we focus on the per-tenant decisions.

### Container-Level Dedicated Throughput

When each tenant has their own container (or you provision dedicated throughput for tenant-specific containers within a shared database), each tenant gets guaranteed RU/s. The upside: no noisy neighbors. The downside: you're paying for the provisioned throughput whether the tenant uses it or not. The minimum is 400 RU/s for manual throughput, or autoscale between 100–1,000 RU/s. <!-- Source: set-throughput.md, concepts-limits.md -->

This works well when your tenants have predictable workloads or when you pass the throughput cost through to each customer.

### Database-Level Shared Throughput

With shared throughput at the database level, you provision RU/s once and let up to 25 containers share it. This is useful for multi-tenant scenarios where each tenant has their own container but workloads vary. The database acts as a throughput pool — busy tenants consume more, quiet tenants consume less. <!-- Source: set-throughput.md -->

The key limitation: there are no per-container throughput guarantees. If one tenant's container monopolizes the shared throughput, others get throttled. You can mitigate this by combining shared and dedicated throughput — giving your largest tenants dedicated containers while keeping smaller ones on shared throughput. <!-- Source: set-throughput.md -->

| Model | Guarantee | Cost |
|---|---|---|
| **Dedicated** (container) | Yes, SLA-backed | Lower (pay for idle) |
| **Shared** (database) | No | Higher (pool unused) |
| **Autoscale** (either) | Scales to demand | Moderate (10% floor) |

With shared throughput, up to 25 containers share the pool; additional dedicated containers can coexist alongside. Autoscale follows the same container limits.

<!-- Source: set-throughput.md -->

### The Hybrid Approach

The most practical multi-tenant throughput strategy is a hybrid: use database-level shared throughput for the long tail of small tenants, and provision dedicated throughput for containers that serve your largest customers. Cosmos DB explicitly supports this — you can have shared and dedicated containers coexisting within the same database. <!-- Source: set-throughput.md -->

For shared-container designs (single container, partition key per tenant), throughput management is simpler but less controllable. You provision throughput on the container, and all tenants share it. The risk of noisy neighbors is real. Autoscale helps by absorbing spikes, and burst capacity (Chapter 11) can smooth out short bursts. But if a single tenant consistently dominates throughput, you have three options:

- **Throttle at the application layer.** Implement per-tenant rate limiting in your middleware before requests reach Cosmos DB.
- **Move the tenant to a dedicated container.** Graduate the heavy hitter out of the shared pool into its own container with dedicated throughput.
- **Raise the container's throughput and absorb the cost.** Sometimes the simplest fix is the right one — provision more RU/s and bill the tenant accordingly.

## Multi-Tenant Vector Search

If you're building an AI-powered SaaS application — a knowledge base, a support chatbot, a personalization engine — you'll need vector search that respects tenant boundaries. Chapter 25 covers vector search fundamentals; here's what changes in a multi-tenant context.

### The Problem with Unsegmented Vector Indexes

By default, Cosmos DB builds one DiskANN vector index per physical partition. When you run a vector similarity search without filtering, it searches across all vectors in the container. <!-- Source: gen-ai-sharded-diskann.md --> In a multi-tenant container, that means Tenant A's similarity search returns results influenced by Tenant B's embeddings — or at minimum, searches through Tenant B's vectors and wastes RU/s doing it.

### Sharded DiskANN: Tenant-Isolated Vector Indexes

**Sharded DiskANN** solves this by letting you split the vector index into per-tenant shards. You define a `vectorIndexShardKey` in your indexing policy, and Cosmos DB creates a separate DiskANN index for each unique value of that key. <!-- Source: gen-ai-sharded-diskann.md -->

Here's the indexing policy configuration:

```json
{
  "vectorIndexes": [
    {
      "path": "/embedding",
      "type": "DiskANN",
      "vectorIndexShardKey": ["/tenantId"]
    }
  ]
}
```

<!-- Source: gen-ai-sharded-diskann.md -->

With this in place, each tenant's vectors live in their own isolated DiskANN shard. Similarity searches scoped to a tenant only search that tenant's index — smaller, faster, cheaper, and with higher recall because the search space is more focused.

### Querying Sharded Vector Indexes

To search within a tenant's shard, include the shard key as a `WHERE` filter:

```sql
SELECT TOP 10 c.id, c.title, c.summary
FROM c
WHERE c.tenantId = "acme-corp"
ORDER BY VectorDistance(c.embedding, [0.12, -0.34, 0.56, ...])
```

<!-- Source: gen-ai-sharded-diskann.md -->

The `WHERE c.tenantId = "acme-corp"` clause restricts the search to the `acme-corp` shard. Without it, the query would search all shards — which defeats the purpose.

### When to Use Sharded DiskANN

Use sharded DiskANN when you're running vector searches in a multi-tenant container and you need:

- **Tenant isolation for search results.** Each tenant's similarity search only considers their own embeddings.
- **Lower latency and cost.** Searching a smaller index is faster and consumes fewer RU/s.
- **Higher recall.** A smaller, more focused index produces more accurate nearest-neighbor results.

The shard key doesn't have to be a tenant ID — it can be any property that defines a meaningful category for your search. But for multi-tenant SaaS, `tenantId` is the natural choice.

## Cosmos DB Fleets: Orchestrating Multi-Account Deployments at Scale

For organizations that choose the account-per-tenant model, managing hundreds of Cosmos DB accounts across multiple subscriptions becomes a serious operational challenge. **Azure Cosmos DB Fleets** is a purpose-built solution for this problem. <!-- Source: fleet.md -->

A fleet is a top-level resource that organizes and manages multiple Cosmos DB accounts — one per tenant — under a unified management plane. Within a fleet, accounts are grouped into **fleetspaces**, which act as logical groupings that can optionally share throughput. <!-- Source: fleet.md -->

### The Hierarchy

```
Fleet (one per multi-tenant application)
  └── Fleetspace (logical grouping of accounts with shared config)
       └── Fleetspace Account (one Cosmos DB account = one tenant)
```

Key rules:
- Each account can belong to only one fleetspace, and each fleetspace to one fleet.
- Accounts from different subscriptions and resource groups can join the same fleet.
- One fleet maps to one multi-tenant application.

<!-- Source: fleet.md -->

### Fleet Pools: Shared Throughput Across Accounts

The most important capability fleets introduce is **pools** — shared throughput that spans multiple accounts within a fleetspace. Without pools, every account must be provisioned for its peak throughput. With pools, you provision each tenant's containers with modest dedicated RU/s (the minimum entry point is 100–1,000 autoscale RU/s) and create a shared pool at the fleetspace level that any tenant can draw from when they spike. <!-- Source: fleet-pools.md -->

Here's how it works:

1. Each container in each account has its own **dedicated RU/s** — these are always guaranteed and consumed first.
2. The fleetspace has a **pool** of additional RU/s (configured with an autoscale min and max — the max can be up to 10× the min).
3. When a tenant's container exceeds its dedicated RU/s, it draws from the pool instead of getting throttled.

<!-- Source: fleet-pools.md -->

The default limits for pools:

| Limit | Value |
|---|---|
| Accounts per fleetspace | 1,000 |
| Pool RU/s max | 1,000,000 |
| Pool RU/s per partition | 5,000 |
| Total RU/s per partition | 10,000 |

The total RU/s per partition limit (10,000) combines both dedicated and pool throughput on a single physical partition.

<!-- Source: fleet.md, fleet-pools.md -->

All limits are raisable via support tickets.

There's an important configuration constraint: all accounts in a fleetspace that uses pooling must have the **same regional configuration** and the **same service tier** (single-region write / General Purpose, or multi-region write / Business Critical). You can't mix accounts with different region setups in the same pool. <!-- Source: fleet-pools.md -->

Billing is straightforward. Each hour, you're billed for the highest RU/s the pool scaled to in that hour, per region. If the pool is idle, you're billed for the minimum. <!-- Source: fleet-pools.md -->

### Fleet Analytics: Observability Across Your Tenant Fleet

When you have hundreds of accounts, you need fleet-wide visibility — not just per-account metrics. **Fleet Analytics** exports usage, cost, and configuration data for all accounts in a fleet to either **Microsoft Fabric OneLake** or **Azure Data Lake Storage Gen2**, aggregated at one-hour granularity. <!-- Source: fleet-analytics.md -->

The exported data follows a star schema with fact tables (`FactRequestHourly`, `FactResourceUsageHourly`, `FactMeterUsageHourly`, `FactAccountHourly`) and dimension tables (`DimResource`, `DimFleet`, `DimRegion`, `DimTime`, etc.). You can query it with Fabric SQL endpoints, KQL, or Spark, and build Power BI dashboards for fleet-wide cost and usage analysis. <!-- Source: fleet-analytics-schema-reference.md -->

For example, to find your top 10 tenants by RU consumption over the last 24 hours:

```sql
SELECT TOP 10
    r.ResourceId,
    SUM(f.TotalRequestChargeInRU) AS TotalRUs
FROM FactRequestHourly f
JOIN DimResource r ON f.ResourceId = r.ResourceId
WHERE f.Timestamp >= DATEADD(hour, -24, GETUTCDATE())
GROUP BY r.ResourceId
ORDER BY TotalRUs DESC
```

Practical questions fleet analytics answers:

- Which tenants are consuming the most RU/s?
- Which accounts are over-provisioned (paying for throughput they don't use)?
- When were account keys last rotated? (Yes, this is tracked in `FactAccountHourly`.)
- Which accounts have burst capacity enabled? Are any using serverless?

<!-- Source: fleet-analytics-schema-reference.md -->

Fleet analytics is currently in preview and doesn't carry a production SLA. <!-- Source: fleet-analytics.md -->

### Creating a Fleet

You can create fleets, fleetspaces, and add accounts via the Azure portal, Azure CLI, or Bicep. Here's the CLI flow:

```bash
# Create a fleet
az resource create \
    --resource-group "saas-platform-rg" \
    --name "researchhub-fleet" \
    --resource-type "Microsoft.DocumentDB/fleets" \
    --location "eastus" \
    --latest-include-preview \
    --properties "{}"
```

<!-- Source: how-to-create-fleet.md -->

And in Bicep:

```bicep
resource fleet 'Microsoft.DocumentDB/fleets@2025-10-25' = {
  name: 'researchhub-fleet'
  location: 'eastus'
  properties: {}
}

resource fleetspace 'Microsoft.DocumentDB/fleets/fleetspaces@2025-10-15' = {
  name: 'standard-tier'
  parent: fleet
  location: 'eastus'
  serviceTier: 'GeneralPurpose'
  dataRegions: [
    'eastus'
  ]
  properties: {
    fleetspaceAPIKind: 'NoSQL'
    throughputPoolConfiguration: {
      minThroughput: 100000
      maxThroughput: 500000
    }
  }
}
```

<!-- Source: how-to-create-fleet.md -->

The fleet's region doesn't determine the regions of the accounts within it — it's just the location of the management resource. <!-- Source: how-to-create-fleet.md -->

## Tenant Offboarding: Deleting Tenant Data

Multi-tenancy isn't just about onboarding. When a tenant leaves (or requests data deletion under GDPR), you need a clean way to remove their data.

For **account-per-tenant** or **container-per-tenant** models, this is simple: delete the account or container.

For **shared-container** models, Cosmos DB offers the **delete by partition key** operation, which asynchronously deletes all items with a given logical partition key value. It runs as a background operation, consuming at most 10% of the container's available RU/s on a best-effort basis. The effect is immediate for queries — deleted items stop appearing in results right away, even though the physical deletion continues in the background. <!-- Source: how-to-delete-by-partition-key.md -->

```csharp
var container = cosmosClient.GetContainer("SaaSDb", "MultiTenantData");

ResponseMessage deleteResponse = await container
    .DeleteAllItemsByPartitionKeyStreamAsync(new PartitionKey("departing-tenant"));
```

<!-- Source: how-to-delete-by-partition-key.md -->

This feature is in public preview. Enable it on your account by adding the `DeleteAllItemsByPartitionKey` capability via the CLI before using it. <!-- Source: how-to-delete-by-partition-key.md -->

## Anti-Patterns and Pitfalls

Multi-tenant Cosmos DB design has a few recurring mistakes that are worth calling out.

### Skipping HPK When You'll Obviously Need It

If you're building a SaaS product, at least one tenant will eventually exceed 20 GB. Don't start with a flat `tenantId` partition key and plan to "add HPK later" — you can't change a container's partition key after creation. Start with hierarchical partition keys from day one. The extra key level costs nothing if you don't need it, and saves a painful migration if you do.

### Treating Partition Key Isolation as a Security Boundary

A partition key is a routing mechanism, not a security mechanism. If this point didn't land earlier in the RBAC section — go reread it. Use partition keys for performance and density; use RBAC and application-layer validation for security.

### Over-Provisioning Every Tenant "Just in Case"

Provisioning each tenant's container at 10,000 RU/s because they *might* spike is a great way to burn budget. Use autoscale to handle variability, and use fleet pools for account-per-tenant models. If you're on a shared-container model, one autoscale pool handles all tenants by definition.

### Ignoring Noisy Neighbors Until It's a Production Issue

In shared-throughput models — whether database-level shared throughput or a shared container — one tenant can consume a disproportionate share of RU/s and cause 429 throttling for everyone else. Monitor per-partition throughput consumption. Set alerts on normalized RU consumption. When a tenant consistently dominates, either move them to dedicated throughput or implement application-level rate limiting per tenant.

### Using One Physical Partition for All Tenants

See [The Low-Cardinality First-Level Trap](#low-cardinality-trap) earlier in this chapter. If you have fewer than ~50 tenants, container-per-tenant may be a better model than a shared container with HPK.

### Forgetting About Observability

You can't manage what you can't measure. In a shared container, enable diagnostic logging so you can distinguish per-tenant usage patterns. In an account-per-tenant fleet, enable fleet analytics. Either way, you need to answer "which tenant is causing this throttling?" quickly — and you can't answer that question if you're not collecting the data. Chapter 18 covers monitoring in depth.

## Choosing Your Multi-Tenancy Model

There's no universal right answer, but here's a decision framework:

| Scenario | Model |
|---|---|
| < 50 tenants, strict SLAs | Account-per-tenant + Fleets |
| 50–500, moderate isolation | Container or DB per tenant |
| 500+, mostly small | Shared container + HPK |
| AI/vector + tenant isolation | Shared + sharded DiskANN |
| Regulatory/CMK/geo needs | Account-per-tenant |

For 500+ tenant scenarios, graduate large outliers to dedicated containers. Account-per-tenant is the only model with per-tenant account-level features like CMK and independent geo-replication.

The hybrid approach — shared container for the long tail, dedicated resources for your biggest customers — is what most production SaaS platforms end up building. Cosmos DB supports it natively. Start with the shared-container model and HPK, instrument your monitoring from day one, and graduate individual tenants to dedicated throughput or dedicated accounts as their requirements demand it.

Chapter 27 picks up with performance tuning — including how to identify and resolve the hot partitions and throughput bottlenecks that multi-tenant workloads inevitably produce.
