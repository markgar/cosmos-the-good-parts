# Chapter 12: Going Global — Multi-Region Distribution

Your application just crossed a line. What started as a single-region deployment serving users in one geography now needs to serve customers on three continents with the same snappy response times — and it can't go down, not even during a regional Azure outage. This is the chapter where Cosmos DB's architecture pays off. Everything you've learned so far — partitioning, replica sets, throughput provisioning — was designed from the start to extend across the globe. Now we'll see how.

## How Cosmos DB Replicates Data Across Azure Regions

Chapter 2 introduced the replica set: each physical partition is backed by at least four replicas within a single region, with writes committed via a majority quorum. That's the within-region story. The global story builds on top of it with an abstraction called a **partition-set**.

<!-- Source: high-availability/global-distribution/global-distribution.md -->

A partition-set is a group of physical partitions — one from each region your account is configured for — that collectively manage the same set of partition keys. Think of it as a "super replica-set" that spans geography. If you have a container distributed across three regions, every physical partition in region A has a corresponding physical partition in regions B and C, and together those three physical partitions form one partition-set.

The math matters: if your account spans *N* Azure regions, there are at least *N* × 4 copies of all your data (four replicas per physical partition per region). A three-region account means at least 12 replicas of every partition. A five-region account: 20 or more. This redundancy is automatic — you don't configure replica counts or manage placement. The service handles it.

<!-- Source: high-availability/global-distribution/global-distribution.md -->

Under the hood, Cosmos DB uses a two-level nested consensus protocol. The first level operates within each replica-set (the familiar quorum commit inside a single region). The second level operates across the partition-set to propagate writes between regions and maintain ordering guarantees. The topology of this cross-region replication is dynamic — it adapts based on the consistency level you've chosen, geographic distance between regions, and available network bandwidth.

<!-- Source: high-availability/global-distribution/global-distribution.md -->

Machines within each data center are spread across 10–20 fault domains, so a rack failure or even a partial data center outage won't take down a physical partition's replica-set. Combined with cross-region replication, this gives you both local and global resilience without touching a configuration file.

<!-- Source: high-availability/global-distribution/global-distribution.md -->

### Single-Write vs. Multi-Write Region Configurations

When you create a multi-region account, you choose one of two topologies:

**Single-write region** — one region accepts writes; all other regions are read-only replicas. Writes arrive at the primary region, commit to a majority quorum locally, then replicate asynchronously to the read regions. This is the simpler configuration and the right starting point for most applications.

**Multi-write regions** (also called multi-master) — every region accepts writes. Writes are quorum-committed locally, then propagated to all other regions asynchronously via the partition-set's anti-entropy channel. This unlocks the highest availability tier but introduces write-write conflicts that you need a strategy for.

We'll cover both in detail in this chapter. The choice between them shapes your SLA, your conflict handling, and your consistency options.

## Availability Zones and Zone Redundancy

Before going multi-region, make sure you've hardened within your primary region. **Availability zones** (AZs) are physically separate locations within an Azure region — independent power, cooling, and networking. When you enable zone redundancy for a Cosmos DB account, the service distributes the four replicas of each physical partition across different availability zones in that region.

<!-- Source: high-availability/disaster-recovery-guidance.md -->

The benefit is straightforward: if an entire availability zone goes down — fire, power loss, network cut — your account keeps serving reads and writes from the surviving zones with no manual intervention. Without zone redundancy, all four replicas might live in the same zone, and a zone-level failure could take them all out.

You can enable availability zones when creating the account or when adding a new region. In the Azure portal, it's a toggle on the **Global Distribution** tab. It's also available via ARM, Bicep, Terraform, and the CLI. Microsoft doesn't charge additional throughput for AZ enablement, though storage costs may vary by redundancy tier — check the pricing page for current details. <!-- TODO: source needed for "Microsoft doesn't charge additional throughput for AZ enablement, though storage costs may vary by redundancy tier" -->

> **Gotcha:** Zone redundancy is a region-level setting. You configure it per region in your account — your primary write region can be zone-redundant while a secondary read region isn't (though you'd typically want both protected).

For single-region accounts, availability zones are your primary defense against infrastructure failures. For multi-region accounts, they add an extra layer of protection: a zone outage is contained within the region and doesn't trigger any cross-region failover at all.

## Adding and Removing Regions at Runtime

One of Cosmos DB's genuinely impressive capabilities is live region management. You can add or remove Azure regions from your account at any time, and your application doesn't need to be paused, redeployed, or even restarted.

<!-- Source: high-availability/global-distribution/distribute-data-globally.md -->

**Adding a region:** When you add a new region, Cosmos DB begins replicating all data to it. The region isn't marked as available until all data is fully replicated and committed. How long that takes depends on the amount of data stored in the account — gigabytes take minutes, terabytes take longer. During replication, your existing regions continue serving traffic normally.

**Removing a region:** When you remove a region, all replication across regions within the relevant partition-sets must complete before the region is marked as unavailable. The service drains gracefully.

<!-- Source: high-availability/global-distribution/distribute-data-globally.md -->

In the portal, you manage this from the **Replicate data globally** blade — click hexagons on a world map to add regions, click the trash icon to remove them. In code or infrastructure-as-code, it's a property on the account resource. A single Azure CLI command does it:

```bash
az cosmosdb update \
  --name my-cosmos-account \
  --resource-group my-rg \
  --locations regionName=eastus failoverPriority=0 isZoneRedundant=true \
  --locations regionName=westeurope failoverPriority=1 isZoneRedundant=true \
  --locations regionName=southeastasia failoverPriority=2 isZoneRedundant=false
```

A few constraints to keep in mind:

- In **single-write mode**, you can't remove the write region directly. You must fail over to a different region first, then remove the old one.
- In **multi-write mode**, you can add or remove any region as long as at least one region remains.
- If a throughput scaling operation is in progress when you add or remove a region, the scaling is paused and resumes automatically after the region operation completes.
- **Serverless accounts** are limited to a single region. If you need multi-region, you need provisioned throughput or autoscale.

<!-- Source: high-availability/global-distribution/distribute-data-globally.md -->

The provisioned throughput you've configured is replicated to every region. If you provision 10,000 RU/s and add a third region, you're now paying for 10,000 RU/s × 3 regions. Chapter 11 covered the cost implications — adding regions is a multiplicative cost increase.

## Multi-Region Reads: Routing to the Nearest Region

The simplest benefit of multi-region distribution is read latency. Once you've added regions near your users, you want each user's read requests to hit the closest replica rather than traveling across the globe to your write region.

The SDKs handle this through a **preferred regions** list (or `ApplicationRegion` in the .NET SDK). You tell the SDK which region to prefer, and it routes read operations there. If that region becomes unavailable, the SDK automatically fails over to the next region in the list.

```csharp
CosmosClient client = new CosmosClient(
    connectionString,
    new CosmosClientOptions
    {
        ApplicationRegion = Regions.WestEurope
    }
);
```

```python
client = CosmosClient(
    url=endpoint,
    credential=key,
    preferred_locations=["West Europe", "East US", "Southeast Asia"]
)
```

<!-- Source: high-availability/multi-region-writes/configure-multi-region-writes/how-to-multi-master.md, high-availability/global-distribution/tutorial-global-distribution.md -->

When you set `ApplicationRegion`, the SDK sorts all available regions by geographic proximity from that region and builds the preferred list automatically. Alternatively, you can specify `ApplicationPreferredRegions` (or `PreferredLocations` in older SDKs) to explicitly control the order. Either way, the SDK:

1. Sends reads to the first available region in the list.
2. If that region fails (connection timeout, 503, etc.), marks it as unavailable and falls to the next region.
3. Periodically re-checks marked-unavailable regions and promotes them back when they recover.

This failover is handled at the SDK layer — your application code doesn't need retry logic for regional outages. But you *do* need to set the preferred regions. If you don't configure them, all reads go to the write region, and you're paying for those extra read replicas without getting any latency benefit. Chapter 21 covers SDK performance tuning including preferred region configuration in more detail.

For **single-write region accounts**, your read availability SLA is **99.999%** when you have two or more regions. That's the same read availability SLA you'd get with multi-write, but only for reads — writes are still bound to the single write region at 99.99%.

<!-- Source: create-secure-solutions/security-considerations.md -->

## Multi-Region Writes: The 99.999% Availability Story

Multi-region writes is the most demanding — and most capable — configuration Cosmos DB offers. When you enable it, every region in your account accepts both reads *and* writes. Users in Tokyo write to the Tokyo replica. Users in Frankfurt write to the Frankfurt replica. Each write is quorum-committed locally and acknowledged to the client immediately — no cross-region round trip on the write path.

<!-- Source: high-availability/global-distribution/distribute-data-globally.md, high-availability/multi-region-writes/multi-region-writes.md -->

This unlocks the headline SLA: **99.999% read and write availability**, backed by a financial SLA. That's less than 26 seconds of total downtime per month. (The math: 0.001% of 43,200 minutes = 0.432 minutes ≈ 26 seconds.) Single-write-region multi-region accounts give you 99.99% — still excellent, but a full order of magnitude less available on paper.

<!-- Source: high-availability/global-distribution/distribute-data-globally.md -->

### The Hub and Satellite Model

Multi-region writes aren't a pure peer-to-peer topology. Behind the scenes, Cosmos DB designates a **hub region** — the first region where your account was created — and all other regions are **satellites**.

<!-- Source: high-availability/multi-region-writes/multi-region-writes.md -->

Here's how writes flow:

1. A write arrives in a satellite region and is quorum-committed locally. The client gets an acknowledgment.
2. The write is sent asynchronously to the hub region for conflict resolution.
3. Once the hub confirms no conflict (or resolves one), the write becomes a **confirmed** write and gets a conflict-resolution timestamp (`crts`).
4. Until that confirmation, the write is **tentative** — it's durable in the local region but hasn't been globally confirmed.
5. Writes that arrive directly at the hub region are confirmed immediately.

If you remove the hub region from the account, the next region (in the order you added them) is automatically promoted to hub. You don't manage this directly — it's an internal mechanism.

<!-- Source: high-availability/multi-region-writes/multi-region-writes.md -->

The practical implication: even with multi-region writes, the hub region plays a special role. Conflict resolution happens there. Change feed ordering in multi-write accounts uses the `crts` timestamp, not `_ts`. If you're consuming change feed in a multi-write account, be aware that the order of events is determined by when writes are confirmed at the hub, not when they were originally written in satellite regions.

### Conflict Resolution Policies

When two regions accept a write to the same item at roughly the same time, you have a conflict. Cosmos DB gives you two strategies, both configured at the container level when you create the container. **You can't change the conflict resolution policy after container creation.**

<!-- Source: high-availability/multi-region-writes/configure-multi-region-writes/how-to-manage-conflicts.md -->

#### Last-Writer-Wins (LWW)

The default and most common policy. Each write has a numeric value used to determine the winner — by default, the system-generated `_ts` timestamp. The write with the highest value wins; the loser is silently discarded.

You can also designate a custom numeric property as the resolution path. For example, if your documents have a `priority` field, you can use `/priority` as the conflict resolution path so that higher-priority writes always win regardless of timing:

```csharp
Container container = await database.CreateContainerIfNotExistsAsync(
    new ContainerProperties("orders", "/customerId")
    {
        ConflictResolutionPolicy = new ConflictResolutionPolicy()
        {
            Mode = ConflictResolutionMode.LastWriterWins,
            ResolutionPath = "/priority"
        }
    }
);
```

<!-- Source: high-availability/multi-region-writes/configure-multi-region-writes/how-to-manage-conflicts.md -->

LWW is simple and deterministic. It works well when conflicts are rare (most multi-region-write workloads are partitioned so that writes for a given item are geographically stable) and when "last write wins" is an acceptable semantic. For many applications — session stores, user preference updates, status changes — it's exactly right.

#### Custom Conflict Resolution

For scenarios where LWW isn't enough — merging shopping carts from two regions, combining incremental counters, applying domain-specific merge logic — you can register a **stored procedure** that Cosmos DB invokes server-side whenever a conflict is detected.

The stored procedure receives the incoming write, the existing committed item, and any conflicting items, and it decides what the final state should be. It runs transactionally within the partition, with exactly-once execution guarantees.

```javascript
function resolver(incomingItem, existingItem, isTombstone, conflictingItems) {
    var collection = getContext().getCollection();

    if (!incomingItem) {
        if (existingItem) {
            collection.deleteDocument(existingItem._self, {}, function(err) {
                if (err) throw err;
            });
        }
    } else if (isTombstone) {
        // Delete always wins in this policy
    } else {
        // Custom merge logic: pick the item with the lowest myCustomId
        if (existingItem && incomingItem.myCustomId > existingItem.myCustomId) {
            return; // existing item wins
        }
        // Replace existing with incoming
        if (existingItem) {
            collection.replaceDocument(existingItem._self, incomingItem,
                function(err) { if (err) throw err; });
        } else {
            collection.createDocument(collection.getSelfLink(), incomingItem,
                function(err) { if (err) throw err; });
        }
    }
}
```

<!-- Source: high-availability/multi-region-writes/configure-multi-region-writes/how-to-manage-conflicts.md -->

If you set the mode to `Custom` without specifying a stored procedure, conflicts are written to a **conflict feed** that your application must read and resolve manually. This gives you full control but requires you to build the resolution logic yourself — and if you don't drain the conflict feed, unresolved conflicts accumulate.

#### Choosing a Policy

For most applications, **LWW with the default `_ts` path is the right choice**. It requires no custom code, handles the common case well, and you never have to think about the conflict feed. Use custom resolution only when your domain has specific merge semantics that can't be expressed as "highest value wins."

The consistency implications of conflict resolution — how different consistency levels interact with tentative vs. confirmed writes — are covered in Chapter 13.

### When Not to Use Multi-Region Writes

Multi-region writes isn't free, and it isn't always the right choice:

- **Strong consistency is not available.** Accounts with multi-region writes can't use strong consistency. A distributed system can't provide an RPO of zero and an RTO of zero simultaneously across writable regions. If you need strong consistency, use single-write-region with multiple read regions.
- **Cost.** Multi-region writes consume more RUs per write because of the conflict resolution overhead, and you're paying for writable throughput in every region.
- **Complexity.** You need to think about conflict resolution, and your change feed behavior changes (ordering by `crts` instead of `_ts`).

<!-- Source: high-availability/consistency/consistency-levels.md -->

If your write traffic is geographically concentrated — say, 90% of writes come from one region — single-write with multi-region reads often gives you better economics and simpler operations.

## Automatic Failover and Regional Outage Scenarios

When a region goes down, what happens depends on which region is affected and how your account is configured.

### Read Region Outage

If a read-only region goes down in a single-write multi-region account, the SDK detects the failure (via backend response codes and timeouts) and automatically routes reads to the next region in the preferred regions list. Your application continues serving reads with minimal disruption — typically a single failed request before the SDK reroutes.

<!-- Source: high-availability/disaster-recovery-guidance.md, high-availability/resiliency/conceptual-resilient-sdk-applications.md -->

There are two consistency-specific wrinkles to watch for:

- **Strong consistency with only two regions:** If the read region goes down, you lose your quorum. Strong consistency requires a dynamic quorum across regions, and with only one region remaining, you can't achieve it. Both reads and writes are disrupted until you either take the failed region offline or it recovers. The mitigation: either deploy three or more regions, or perform a region offline operation to remove the failed region.
- **Bounded staleness:** If the read region is down long enough for the staleness window to be exceeded, writes to affected partitions are also impacted. The mitigation is the same: take the failed region offline.

<!-- Source: high-availability/disaster-recovery-guidance.md, high-availability/consistency/consistency-levels.md -->

### Write Region Outage (Single-Write Accounts)

This is the more serious scenario. If your only write region goes down, writes are unavailable until one of two things happens:

**Service-managed failover:** If you've enabled this option (recommended for most production accounts), Cosmos DB automatically promotes a read region to become the new write region. The failover follows the priority order you've configured. However, the timing depends on the nature of the outage — it can take up to an hour or more for the service to confirm the outage and execute the failover.

<!-- Source: high-availability/disaster-recovery-guidance.md -->

**Region offline (forced failover):** If you can't wait for service-managed failover, you can manually force a region offline from the portal or CLI. This immediately removes the failed region from the account and promotes the highest-priority read region to write. It's faster but carries a risk: any writes that were committed in the old write region but not yet replicated to other regions may be lost.

<!-- Source: high-availability/disaster-recovery-guidance.md -->

After the outage resolves, bringing the region back online is an Azure-managed operation that can take three or more business days depending on account size. Once online, the recovered region is added back as a read region — you must manually switch it back to write if desired.

> **Warning:** During a regional outage, do not perform control plane operations on the affected region (changing write regions, updating account settings, modifying network configuration). These operations can cause account inconsistency and delay recovery.

<!-- Source: high-availability/disaster-recovery-guidance.md -->

### Write Region Outage (Multi-Write Accounts)

This is the happy path. If any region goes down in a multi-write account, the remaining regions continue accepting both reads and writes. The SDKs automatically route traffic to healthy regions based on the preferred regions configuration. No manual failover is needed. No data loss occurs for writes committed in other regions.

The remaining regions continue accepting both reads and writes — the 99.999% availability guarantee in action.

<!-- Source: high-availability/disaster-recovery-guidance.md -->

### Configuring Service-Managed Failover

For single-write accounts, enabling service-managed failover is a best practice for production:

1. In the portal, navigate to your Cosmos DB account and open **Replicate data globally**.
2. Select **Service-Managed Failover** and toggle it to **ON**.
3. Arrange your read regions in priority order by dragging them. If the write region fails, the highest-priority read region is promoted.

<!-- Source: high-availability/disaster-recovery-guidance.md -->

You can also set failover priorities via the CLI or PowerShell. Test your failover configuration regularly — Cosmos DB provides a manual failover API specifically for business continuity drills.

## Per-Partition Automatic Failover (PPAF) — Preview

Traditional failover operates at the account level: when the write region fails, the entire account fails over to a new write region. **Per-Partition Automatic Failover (PPAF)** is a more granular approach currently in public preview. Instead of failing over the whole account, Cosmos DB can automatically fail over individual partitions that are in an error state.

<!-- Source: manage-your-account/manage-azure-cosmos-db-resources/how-to-configure-per-partition-automatic-failover.md -->

This matters because regional outages aren't always total. Sometimes only certain storage nodes or network paths are affected, impacting some partitions but not others. With PPAF, only the affected partitions fail over — the rest keep writing to the original region. The result is faster recovery and less disruption.

### Prerequisites for PPAF

PPAF has specific requirements in the current preview:

| Requirement | Detail |
|-------------|--------|
| **Account type** | Single-write + ≥1 read region |
| **API** | NoSQL only |
| **Consistency** | All except Bounded Staleness |
| **Cloud** | Azure public only |
| **SDK** | .NET v3.54.0+ / Java v4.75.0+ |
| **Backup** | No In-Account Restore |

Bounded Staleness support is not available during preview. Sovereign clouds are also not eligible during preview.

<!-- Source: manage-your-account/manage-azure-cosmos-db-resources/how-to-configure-per-partition-automatic-failover.md -->

### PPAF Pricing

Cosmos DB's pricing page uses two service tier labels that you won't find explained in a standalone doc anywhere:

| Service Tier | What It Actually Means | SLA |
|---|---|---|
| **General Purpose** | Single-region write accounts | Up to 99.995% |
| **Business Critical** | Multi-region write accounts | Up to 99.999% |

These aren't separate SKUs you choose — they're pricing categories that map directly to your account's write configuration. A single-write account is General Purpose. A multi-write account is Business Critical. The tier determines your per-RU/s rate: Business Critical costs roughly 2× General Purpose for autoscale throughput.

PPAF lands in the Business Critical pricing tier even though it requires a *single-write* account. The logic: PPAF gives your single-write account partition-level automatic failover — a level of availability that approaches what multi-write accounts provide. Microsoft charges the premium rate accordingly. It's not a free add-on.

<!-- Source: manage-your-account/manage-azure-cosmos-db-resources/how-to-configure-per-partition-automatic-failover.md -->

### Testing PPAF

You can simulate partition-level faults using a PowerShell script provided by Microsoft. The fault affects approximately 10% of total partitions for a specified container (minimum 1 partition, maximum 10). It can take up to 15 minutes for the fault to become effective, giving you a realistic test window. During the simulation, check the **Total Requests** metric broken down by region to confirm that write operations are occurring in the secondary region.

<!-- Source: manage-your-account/manage-azure-cosmos-db-resources/how-to-configure-per-partition-automatic-failover.md -->

PPAF is promising — it addresses the granularity gap in Cosmos DB's failover model. But as a preview feature, it comes without an SLA and shouldn't be your only disaster recovery strategy. Pair it with service-managed failover for defense in depth.

## RPO and RTO by Configuration

When planning for disaster recovery, you need to understand two metrics:

- **Recovery Point Objective (RPO):** The maximum amount of recent data you can afford to lose.
- **Recovery Time Objective (RTO):** The maximum time your application can be down.

In Cosmos DB, both RPO and RTO depend on your consistency level and region configuration. Here's the RPO table:

<!-- Source: high-availability/consistency/consistency-levels.md -->

| Config | Consistency | RPO |
|--------|-------------|-----|
| 1 region, any mode | Any | < 240 min |
| >1, single write | Session / Prefix / Eventual | < 15 min |
| >1, single write | Bounded Staleness | *K* versions or *T* sec |
| >1, single write | Strong | 0 |
| >1, multi-write | Session / Prefix / Eventual | < 15 min |
| >1, multi-write | Bounded Staleness | *K* versions or *T* sec |

> **Note:** Bounded Staleness with multi-write is technically supported but considered an anti-pattern — see Chapter 13 for details.

A few things to note:

- **Single-region accounts have the worst RPO** — up to 240 minutes. If the region goes down and data hasn't been backed up, you could lose up to 4 hours of writes. This alone is a compelling reason to add at least one additional region for any production workload.
- **Strong consistency with multi-region single-write gives you RPO = 0** — no data loss, because writes are synchronously replicated to all regions before being acknowledged.
- As noted earlier, multi-write accounts can't use strong consistency, so RPO = 0 isn't achievable.
- For bounded staleness, the minimum staleness window for multi-region accounts is 100,000 write operations or 300 seconds (5 minutes). For single-region accounts, it's 10 write operations or 5 seconds.

<!-- Source: high-availability/consistency/consistency-levels.md -->

For RTO, the specifics depend on your failover configuration:

- **Multi-write accounts:** Near-zero RTO. Traffic is automatically routed to healthy regions by the SDK.
- **Single-write with PPAF:** Fast automatic partition-level failover — seconds to low minutes.
- **Single-write with service-managed failover:** Up to an hour or more, depending on outage progression.
- **Single-write with manual region offline:** As fast as you can detect the outage and click the button.

Chapter 19 covers full disaster recovery planning, including how to combine these Cosmos DB capabilities with application-level strategies like Azure Traffic Manager and health probes.

## Azure Government and Sovereign Cloud Regions

Cosmos DB is available across four distinct Azure cloud environments:

<!-- Source: high-availability/global-distribution/distribute-data-globally.md -->

| Cloud | Availability |
|-------|-------------|
| **Azure public** | Global |
| **21Vianet** | China |
| **Azure Government** | 4 US regions |
| **Azure Gov for DoD** | 2 US regions |

For applications with data residency or regulatory requirements — ITAR, FedRAMP High, IL5 — Azure Government and DoD regions keep your data within approved boundaries. You create Cosmos DB accounts in these regions the same way you would in public Azure, but the endpoints are different (e.g., `.documents.azure.us` for Azure Government).

<!-- Source: high-availability/global-distribution/distribute-data-globally.md -->

Key constraints for sovereign clouds:

- You can replicate between regions within the same sovereign cloud, but you can't replicate between a sovereign cloud and public Azure. An Azure Government Cosmos DB account can span Azure Government regions but can't replicate to West Europe.
- Some features arrive in sovereign clouds later than public Azure. PPAF, for example, is limited to Azure public cloud regions during its preview.
- Feature availability should be validated against the sovereign cloud documentation for your specific compliance framework.

For organizations with strict data residency requirements, Azure Policy can enforce that Cosmos DB accounts aren't replicated to unapproved regions. Chapter 17 covers the security and compliance angle in more detail.

## Putting It Together: Choosing Your Global Architecture

Every multi-region Cosmos DB deployment is a point on a spectrum of complexity, cost, and resilience. Here's a decision framework:

| Scenario | Configuration |
|----------|---------------|
| Dev/test, single market | 1 region, AZ-enabled |
| Production with DR | 1 write + 1 read, AZ, auto-failover |
| Global reads, local writes | 1 write + 2+ reads, AZ |
| Global reads and writes | Multi-write, 2+ regions, AZ |

| Scenario | SLA | RPO |
|----------|-----|-----|
| Dev/test | 99.99% | < 240 min |
| Prod + DR | 99.99% W / 99.999% R | < 15 min |
| Global reads | 99.99% W / 99.999% R | 0–15 min |
| Global R+W | 99.999% R+W | < 15 min |

Relative cost scales with region count: ~1× for single region, ~2× for two, 3×+ for three or more. Multi-write adds conflict resolution overhead.

The right answer depends on your availability requirements, your budget, and where your users are. Most production applications land in the second or third row — single-write with multiple read regions gives you excellent availability, straightforward consistency, and no conflict resolution headaches. Multi-region writes is the right move when you genuinely need write availability during a regional outage or when write latency from distant regions is unacceptable.

Whatever you choose, three things are non-negotiable for production:

1. **Enable availability zones** in every region your account uses.
2. **Configure preferred regions in your SDK** so reads go to the nearest replica.
3. **Enable service-managed failover** (for single-write accounts) so recovery doesn't depend on someone being awake.

With those in place, you're ready to talk about the consistency guarantees that govern what your users see when they read data that's been replicated across these regions. That's Chapter 13.
