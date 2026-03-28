# Chapter 25: Multi-Tenancy Patterns

Every SaaS company eventually faces the same question: *how do I store data for hundreds — or hundreds of thousands — of customers in Azure Cosmos DB without losing my mind (or my budget)?* The answer isn't a single pattern. It's a spectrum of isolation models, each trading off cost, security, operational complexity, and performance in different ways.

In this chapter, you'll walk through that spectrum from full isolation to full sharing. You'll learn how hierarchical partition keys unlock multi-tenant data modeling at scale, how to enforce tenant isolation at the security layer, and how to manage throughput so one noisy tenant doesn't ruin the party for everyone else. We'll also cover **Cosmos DB Fleets** — a relatively new capability purpose-built for orchestrating multi-account, multi-tenant deployments — before closing with the anti-patterns that trip up even experienced teams.

---

## The Isolation Spectrum

Multi-tenancy in Cosmos DB isn't binary. Think of it as a dial you can turn between *maximum isolation* and *maximum density*. The four common positions on that dial are:

1. **Account-per-tenant** — every tenant gets their own Cosmos DB account.
2. **Database-per-tenant** — tenants share an account but each gets a dedicated database.
3. **Container-per-tenant** — tenants share a database but each gets a dedicated container.
4. **Shared container (partition-key-per-tenant)** — all tenants coexist in the same container, separated by partition key.

Microsoft's official guidance strongly recommends two of these: **partition-key-per-tenant** for high-density B2C workloads and **account-per-tenant** for B2B scenarios requiring strong isolation. The middle two (database-per-tenant, container-per-tenant) are explicitly discouraged because they introduce scalability challenges as your customer base grows — Cosmos DB has limits on the number of databases and containers per account, and managing throughput individually across hundreds of containers becomes an operational nightmare.

### Comparison Table

| Dimension | Account-per-Tenant | Database-per-Tenant | Container-per-Tenant | Shared Container (Partition Key) |
|---|---|---|---|---|
| **Isolation level** | Physical (strongest) | Logical — separate DB | Logical — separate container | Logical — partition key only |
| **Security boundary** | Full RBAC/network per account | Shared account credentials | Shared account credentials | Shared everything |
| **Per-tenant configuration** | Geo-replication, CMK, PITR per tenant | Limited | Limited | None |
| **Throughput model** | Dedicated RU/s per account | Database-level shared or container-dedicated | Container-dedicated | Shared across tenants |
| **Cost at scale** | Highest (minimum RU/s per account) | Moderate | Moderate–High | Lowest |
| **Operational complexity** | High — many accounts to manage | Moderate | Moderate–High | Lowest |
| **Max tenants (practical)** | Thousands (with Fleets) | 500 total DBs + containers per account (shared limit) | ~25 containers per DB default | Millions |
| **Noisy-neighbor risk** | None | Moderate | Moderate | Highest |
| **Best fit** | B2B, regulated, enterprise | Rarely recommended | Rarely recommended | B2C, high-density SaaS |

> **Rule of thumb:** Start with the shared-container model unless your tenants have regulatory, compliance, or performance requirements that demand stronger isolation. If you need account-level isolation at scale, pair it with Cosmos DB Fleets (covered later in this chapter).

---

## Shared Container Multi-Tenancy with Partition Key Isolation

The shared-container model is the workhorse of multi-tenant Cosmos DB design. The idea is straightforward: every document includes a `tenantId` field, and you use that field (or a composite that includes it) as the partition key. Cosmos DB's partitioning engine guarantees that all reads and writes scoped to a single tenant hit the same logical partition, giving you single-partition query performance for tenant-scoped operations.

Here's a simple document structure:

```json
{
  "id": "order-9182",
  "tenantId": "contoso",
  "type": "order",
  "customerId": "cust-42",
  "total": 299.99,
  "createdAt": "2025-01-15T08:30:00Z"
}
```

With `/tenantId` as the partition key, a query like the following is guaranteed to execute as a single-partition query:

```sql
SELECT * FROM c
WHERE c.tenantId = 'contoso'
  AND c.type = 'order'
  AND c.createdAt > '2025-01-01'
```

### Why This Works So Well

- **Cost efficiency.** You provision RU/s once for the container, and all tenants share it. A 1,000-tenant workload doesn't need 1,000 separate throughput allocations.
- **Simplified management.** One container means one indexing policy, one set of change-feed processors, one backup configuration.
- **Elastic scaling.** As tenants grow, Cosmos DB automatically splits physical partitions behind the scenes. You don't need to re-architect.

### Where It Gets Tricky

The 20 GB logical-partition limit is the main constraint. If a single tenant's data exceeds 20 GB under a single partition key value, you'll hit a wall. This is exactly where hierarchical partition keys come in.

---

## Hierarchical Partition Keys for High-Cardinality Tenant + Entity Patterns

Hierarchical partition keys (sometimes called *subpartitioning*) let you define up to a **three-level hierarchy** for your partition key. Instead of cramming all of Contoso's data into one logical partition keyed on `tenantId = "contoso"`, you can spread it across subpartitions while still allowing efficient tenant-scoped queries.

A typical multi-tenant hierarchy looks like this:

```
Level 1: /tenantId        → "contoso"
Level 2: /entityType      → "order"
Level 3: /id              → "order-9182"
```

The lowest level should always have **high cardinality** — using the document `id` or a GUID is the recommended approach. This ensures that data fans out evenly across physical partitions even if a single tenant accumulates hundreds of gigabytes.

### Creating a Container with Hierarchical Partition Keys

Using the .NET SDK:

```csharp
var containerProperties = new ContainerProperties
{
    Id = "multi-tenant-data",
    PartitionKeyPaths = new Collection<string>
    {
        "/tenantId",
        "/entityType",
        "/id"
    }
};

var container = await database.CreateContainerIfNotExistsAsync(
    containerProperties,
    throughput: 10000
);
```

### Querying with Hierarchical Keys

The beauty of hierarchical partition keys is that you can query at any level of the hierarchy:

- **Full prefix match (single subpartition):** Supply all three key levels to target one specific subpartition.
- **Partial prefix match:** Supply just `tenantId` to fan out across all of that tenant's subpartitions — still scoped to a single tenant's data.
- **Cross-partition:** Omit the partition key entirely to scan everything (use sparingly).

```csharp
// Scoped to all of Contoso's data — efficient fan-out within tenant
var queryOptions = new QueryRequestOptions
{
    PartitionKey = new PartitionKeyBuilder()
        .Add("contoso")
        .Build()
};

var iterator = container.GetItemQueryIterator<dynamic>(
    "SELECT * FROM c WHERE c.entityType = 'order'",
    requestOptions: queryOptions
);
```

### When to Reach for HPK

Use hierarchical partition keys when:

- **A single tenant can exceed 20 GB.** The hierarchical key distributes data across multiple physical partitions while maintaining the logical grouping.
- **You have a natural entity hierarchy** (tenant → category → document) that matches your access patterns.
- **You want to avoid synthetic keys.** Before HPK, developers would concatenate fields like `"contoso_order"` into a single partition key string. HPK replaces that hack with a first-class feature.

> **Important:** If you have very few tenants and use hierarchical partitioning, all documents with the same first-level key still write to the same set of physical partitions. HPK shines when tenant data volumes are large enough to justify splitting *within* a tenant.

---

## Enforcing Tenant Data Isolation with RBAC and Resource Tokens

Partition-key isolation keeps tenant data in separate logical partitions, but it doesn't *enforce* access control at the database layer. A bug in your application code could accidentally query another tenant's data. To add defense in depth, you have two mechanisms: **Azure RBAC** and **resource tokens**.

### Azure RBAC (Microsoft Entra ID)

Azure Cosmos DB supports data-plane RBAC with Microsoft Entra ID authentication. You can create custom role definitions that grant read or write access to specific containers and assign them to service principals or managed identities. In a multi-tenant architecture, you might:

1. Create a **per-tenant managed identity** (or service principal) in Entra ID.
2. Define a custom Cosmos DB data-plane role scoped to the relevant container.
3. Assign the role to the tenant's identity.

This ensures that even if a tenant's credentials leak, they can only access resources their role permits. For the shared-container model, RBAC operates at the container level — it can restrict *which* container a principal accesses, but it cannot restrict access to a specific partition key value within a container.

### Resource Tokens

Resource tokens provide a finer-grained alternative. You create a *permission* resource on the server that scopes access to a specific partition key value within a container:

```csharp
var user = await database.CreateUserAsync(new UserProperties { Id = "tenant-contoso" });

var permissionProperties = new PermissionProperties(
    id: "contoso-readonly",
    permissionMode: PermissionMode.Read,
    container: container,
    resourcePartitionKey: new PartitionKey("contoso")
);

var permission = await user.User.CreatePermissionAsync(permissionProperties);
string resourceToken = permission.Resource.Token;
```

The resulting `resourceToken` is a short-lived token (default 1 hour, configurable up to 24 hours) that your client applications use instead of the master key. When a client authenticates with this token, Cosmos DB itself enforces that every read and write is restricted to the `"contoso"` partition — no application-level filtering required.

### Choosing Between Them

| Mechanism | Scope | Token Lifetime | Partition-Key Restriction | Identity Provider |
|---|---|---|---|---|
| **Azure RBAC** | Container/Account | Entra token lifetime | No | Microsoft Entra ID |
| **Resource tokens** | Partition key value | 24 hours (with a 1-hour default) | Yes | Cosmos DB native |

For most multi-tenant SaaS backends, the practical approach is to use **RBAC for service-to-service auth** (your API servers talking to Cosmos DB via managed identity) and implement tenant scoping in your application layer — ensuring every query includes a `WHERE c.tenantId = @currentTenant` clause, enforced by middleware. Resource tokens are valuable when you need to hand a scoped credential directly to an untrusted client (such as a mobile app or browser).

---

## Throughput Management: Dedicated vs. Shared RU/s per Tenant

Getting throughput right in a multi-tenant system is one of the trickiest operational challenges. Cosmos DB gives you two main levers:

### Container-Level (Dedicated) Throughput

Each container gets its own provisioned RU/s (manual or autoscale). In the shared-container model, all tenants compete for the same pool of RU/s. In the container-per-tenant model, each tenant's container has its own throughput — but this gets expensive fast.

### Database-Level (Shared) Throughput

You can provision RU/s at the database level, and Cosmos DB distributes them across all containers in that database. This is useful when you have multiple containers (perhaps one per entity type) and want to avoid micro-managing throughput for each one:

```csharp
var database = await client.CreateDatabaseIfNotExistsAsync(
    "multi-tenant-db",
    throughput: 20000  // shared across all containers in this DB
);
```

Containers within a shared-throughput database still have a minimum guaranteed throughput based on the formula: `max(400, number_of_physical_partitions × 100)` RU/s. You can also set individual containers within a shared-throughput database to have their own dedicated throughput if needed — this is sometimes called a *mixed* throughput model.

### Strategies by Tenant Tier

A common pattern in SaaS is to offer multiple tiers:

| Tier | Strategy |
|---|---|
| **Free / Trial** | Shared container, shared RU/s. Accept some noisy-neighbor risk. |
| **Standard** | Shared container with autoscale. Implement per-tenant rate limiting in your application layer. |
| **Premium** | Dedicated container or dedicated account. Provision autoscale RU/s tuned to the tenant's SLA. |
| **Enterprise** | Dedicated account (potentially in a dedicated subscription). Use Cosmos DB Fleets for management. |

### Autoscale Is Your Friend

For multi-tenant workloads, **autoscale** is almost always the right choice. It lets Cosmos DB scale RU/s between 10% and 100% of the configured maximum, and you pay only for the peak throughput consumed each hour. This smooths out the bursty traffic patterns that are characteristic of multi-tenant systems where not every tenant is active at the same time.

---

## Cosmos DB Fleets: Orchestrating Multi-Account Deployments at Scale

If you've chosen the account-per-tenant model for its strong isolation guarantees, you've traded density for operational complexity. Managing hundreds or thousands of Cosmos DB accounts — each with its own throughput provisioning, monitoring, and regional configuration — quickly becomes unmanageable. This is exactly the problem **Azure Cosmos DB Fleets** solves.

### What Are Fleets?

Fleets is a management layer that lets you organize multiple Cosmos DB accounts into a single logical entity. One fleet corresponds to one multi-tenant application. Within a fleet, accounts are grouped into **fleetspaces** — logical groupings where RU/s can optionally be shared.

The resource hierarchy looks like this:

```
Fleet (your multi-tenant app)
  └── Fleetspace (group of accounts with similar characteristics)
        ├── Account A (Tenant A)
        ├── Account B (Tenant B)
        └── Account C (Tenant C)
```

Key constraints: each account can belong to only one fleetspace and one fleet. If an account is already in a fleet, it must be removed before it can join another.

### Fleet Pools: Shared Throughput Across Accounts

Here's where Fleets gets really interesting. **Pools** let you create a shared pool of RU/s at the fleetspace level that any resource in any account within that fleetspace can draw from when it exceeds its dedicated throughput.

Think of it like a corporate cell phone plan with shared data. Each tenant (account) has its own dedicated data allocation, but when they blow past it during a busy period, they can dip into the shared pool instead of getting throttled.

#### How Pooling Works

- Each account retains its own **dedicated RU/s** (provisioned at the container or database level). These are guaranteed.
- The fleetspace has a **pool** of additional RU/s. Pool throughput is autoscale by default — you configure a minimum and maximum (max can be up to 10× the minimum).
- When an account exceeds its dedicated RU/s, its physical partitions can draw from the pool — up to **5,000 extra RU/s per physical partition** from the pool.
- A physical partition's total consumption (dedicated + pool) caps at **10,000 RU/s**.
- Dedicated RU/s are always consumed first.

#### The Economics

Consider an ISV with 1,000 tenants:

**Without pooling:** You overprovision every tenant to handle peak loads (say, 5,000 RU/s each) even though most tenants idle at low RU/s. That's 5,000,000 RU/s provisioned, mostly wasted.

**With pooling:** Each tenant gets low dedicated RU/s (100–1,000 autoscale). You add a fleet pool of 100,000–500,000 RU/s. When a tenant spikes, they draw from the pool. You avoid massive overprovisioning while ensuring tenants get the throughput they need during spikes.

#### Configuration Rules

There's one important constraint: all accounts in a fleetspace must have the **same regional configuration**. That means:

- Same set of Azure regions.
- Same service tier (general purpose or business critical / single-region or multi-region writes).
- Pool RU/s are not shared across regions — each region has its own pool allocation.

#### Default Fleet Limits

| Resource | Limit |
|---|---|
| Database accounts per fleetspace | 1,000 |
| Maximum pool RU/s | 1,000,000 RU/s |
| Maximum pool RU/s per physical partition | 5,000 RU/s |

These limits can be raised via an Azure Support ticket.

### Fleet Analytics: Observability at the Fleet Level

When you're managing hundreds of accounts, you need centralized visibility. **Fleet Analytics** exports cost, usage, and configuration data for all accounts in a fleet to **Microsoft Fabric** (OneLake) or an **Azure Storage account** for long-term analysis. Data is aggregated at a one-hour grain.

Once configured, you can query the data using a star-schema model with tables like `DimResource` (account metadata) and `FactRequestHourly` (usage metrics). Some powerful queries you can run:

- **Top 100 most active accounts by transactions** — join `DimResource` and `FactRequestHourly`.
- **Top 100 largest accounts by storage** — find your biggest data consumers.
- **Key rotation audit** — identify accounts where access keys haven't been rotated recently.

To set up Fleet Analytics:

1. Create a fleet in the Azure portal.
2. Navigate to **Fleet analytics** in the **Monitoring** section.
3. Select **Add destination** and choose your Fabric workspace or storage account.
4. Grant the **Cosmos DB Fleet Analytics** service principal **Contributor** access to your Fabric workspace.

Data begins flowing within about an hour.

> **Tip:** Create a dedicated Fabric workspace for Fleet Analytics, since the service principal needs Contributor access to the entire workspace.

---

## Anti-Patterns and Pitfalls in Multi-Tenant Cosmos DB Design

Let's close with the mistakes that keep coming up in multi-tenant Cosmos DB projects. These are patterns that seem reasonable at first but cause real pain at scale.

### 1. Container-per-Tenant or Database-per-Tenant

This is the most common anti-pattern. It feels natural — one tenant, one container — but it doesn't scale. Cosmos DB has default limits on containers per database and databases per account. At 500 tenants, you're already fighting limits. At 5,000, you're in trouble. Each container also carries a minimum RU/s overhead, making costs balloon even for idle tenants.

**Do this instead:** Use the shared-container model with partition-key isolation, or the account-per-tenant model with Fleets for strong isolation.

### 2. Using the Master Key in Client Applications

If you're handing out your Cosmos DB master key to client-side code so tenants can access "their" data directly, stop immediately. The master key grants full read-write access to everything in the account. A single leaked key compromises every tenant.

**Do this instead:** Use resource tokens scoped to a specific partition key, or route all access through your backend API authenticated with managed identities and Entra RBAC.

### 3. Cross-Partition Queries as a Default Access Pattern

In a shared-container model, if your queries don't include the partition key (tenantId), every query fans out across all physical partitions. This is expensive (high RU cost), slow, and defeats the purpose of partition-key isolation.

**Do this instead:** Ensure your data access layer always injects the tenantId into queries. Use middleware or a repository pattern that makes it impossible to issue a query without a tenant scope.

### 4. Ignoring the 20 GB Logical Partition Limit

If one tenant can accumulate more than 20 GB of data under a single partition key value, you'll hit a hard wall. The partition can't split, writes start failing, and you're in an emergency.

**Do this instead:** Use hierarchical partition keys from day one if there's any chance a tenant could exceed 20 GB. The cost of adding HPK upfront is negligible compared to the pain of migrating data later.

### 5. No Per-Tenant Rate Limiting

In the shared-container model, a single tenant can consume a disproportionate share of RU/s, causing 429 (throttling) responses for other tenants. Cosmos DB doesn't natively enforce per-partition-key throughput limits.

**Do this instead:** Implement rate limiting in your application tier. Track per-tenant RU consumption (the response headers include the request charge) and throttle tenants that exceed their allocation. Consider the priority-based execution feature to give higher-tier tenants preferential access during contention.

### 6. Hardcoding Tenant Configuration

Don't embed tenant-specific settings (like throughput allocations or feature flags) directly in code or environment variables. As your tenant count grows, this becomes impossible to manage.

**Do this instead:** Maintain a tenant metadata store (this can be a container in Cosmos DB itself, or Azure App Configuration) that maps tenant IDs to their configuration: tier, throughput allocation, regional preferences, feature flags, and so on.

### 7. Forgetting About Backup and Restore Scoping

Cosmos DB's continuous backup supports point-in-time restore, but in a shared-container model, you can't restore a single tenant's data independently — you restore the entire container. If a tenant asks you to roll back their data to yesterday, you have a problem.

**Do this instead:** If per-tenant restore is a requirement, consider the account-per-tenant model (which supports per-account PITR) or implement a soft-delete plus change-feed archival pattern that gives you tenant-level recoverability in the shared model.

### 8. Not Planning for Tenant Offboarding

Deleting a tenant's data from a shared container means issuing individual deletes for every document with that tenant's partition key — and paying the RU cost for each one. There's no "delete partition" operation.

**Do this instead:** Use a TTL-based approach. When a tenant is offboarded, set a short TTL on all their documents and let Cosmos DB clean them up at no RU cost. Alternatively, if you use the account-per-tenant model, offboarding is simply deleting the account.

---

## What's Next

Multi-tenancy defines how you *organize* tenant data, but how do you make sure it all runs *fast*? In **Chapter 26**, we'll dive into **performance tuning and best practices** — the performance tuning loop, direct connectivity mode for lowest latency, optimizing document size, indexing policy tuning for write-heavy workloads, query optimization walk-throughs, handling hot partitions, and capacity planning with load testing.
