# Chapter 11: Going Global — Multi-Region Distribution

Up until now, every container you've created has lived in a single Azure region. That's fine for a proof of concept, but the moment your users span continents — or the moment a regional outage threatens your uptime SLA — a single-region deployment becomes a liability. Azure Cosmos DB was designed from day one as a globally distributed database, and in this chapter you'll learn how to take advantage of that.

We'll cover how replication actually works under the hood, how to add and remove regions without downtime, how to route reads and writes for minimal latency, and how to reason about availability, failover, and data durability across every configuration option Cosmos DB offers.

## How Cosmos DB Replicates Data Across Regions

When you add a region to your Cosmos DB account, you aren't setting up a separate database and wiring up change feeds between them. Cosmos DB handles replication transparently at the platform level. Every write that lands on a physical partition in one region is automatically propagated to the corresponding partition replicas in every other region you've configured.

### Replica-Sets and Partition-Sets

To understand global distribution, you need two concepts:

- **Replica-set**: Within a single region, each physical partition is backed by a group of replicas (typically four) spread across fault domains. These replicas form a quorum — writes are acknowledged once a majority commits them. This is what gives you durability and high availability *within* a region.
- **Partition-set**: Across regions, the physical partitions that manage the same set of partition keys form a *partition-set*. Think of it as a "super replica-set" that spans geographies. A partition-set is the unit of cross-region replication.

When you write a document in, say, East US, the local replica-set commits the write via majority quorum and acknowledges it to your client. That write is then propagated asynchronously (for most consistency levels) to the corresponding physical partitions in every other region through an anti-entropy channel. The frequency and urgency of that propagation depend on your configured consistency level, the network topology between regions, and the current replication load.

The partition-set uses a two-level nested consensus protocol: one level operates within each replica-set to handle local writes, and another operates at the partition-set level to provide global ordering guarantees. This layered approach is how Cosmos DB delivers its stringent SLAs without sacrificing write throughput.

### It's All Turnkey

Adding or removing a geographic region requires a single API call, a CLI command, or a few clicks in the Azure portal. Your application doesn't need to be redeployed or paused. Cosmos DB dynamically reconfigures the partition-set topology — creating new physical partition replicas in the new region and starting data synchronization — while your application continues operating. The SDK automatically discovers the new region and begins routing requests to it.

## Availability Zones and Zone Redundancy

Before we talk about multi-*region* distribution, let's zoom into what happens *within* a single region.

Azure availability zones are physically separate datacenters within the same Azure region, each with independent power, cooling, and networking. When you enable **zone redundancy** on a Cosmos DB region, the platform distributes your partition replicas across multiple availability zones instead of keeping them all in the same datacenter.

Why does this matter? Without zone redundancy, a datacenter failure — power loss, cooling failure, network partition — can take down all four replicas of a physical partition simultaneously. With zone redundancy, your replicas survive a full zone failure with no data loss and no availability loss.

### When to Enable Zone Redundancy

- **Single-region accounts**: This is where zone redundancy provides the most value. It's your only defense against datacenter-level failures when you don't have a second region.
- **Multi-region accounts**: Zone redundancy is still valuable, particularly for your write region(s). If you're running with a single write region, losing that region to a zone-level failure is disruptive even if service-managed failover eventually kicks in. Zone redundancy prevents that scenario.
- **Multi-region write accounts**: The 25% zone redundancy pricing premium is waived for multi-region write accounts, so there's no cost reason to skip it.

You can enable zone redundancy only when adding a new region to your account (or during initial account creation). You configure it per region — you don't have to enable it everywhere, though you should where it's supported.

### Cost

Regions with zone redundancy enabled are charged at a 25% premium on provisioned RU/s. However, this premium is waived for accounts configured with multi-region writes or for collections using autoscale throughput.

## Adding and Removing Regions at Runtime

One of the most operationally powerful features of Cosmos DB is that region management is a live operation. You can add a region to handle a new market launch, remove one to cut costs, or reorder your failover priorities — all without application downtime.

When you **add a region**, Cosmos DB:

1. Creates new physical partitions in the target region.
2. Begins replicating data from existing regions.
3. Once the new region is caught up, it starts serving read traffic (and write traffic, if multi-region writes is enabled).

When you **remove a region**, Cosmos DB:

1. Stops routing traffic to the region.
2. Decommissions the replicas.
3. Your throughput bill for that region stops.

You can perform these operations through the Azure portal, Azure CLI, PowerShell, ARM/Bicep templates, or the Azure Cosmos DB resource provider REST API. The SDK automatically discovers topology changes through its service endpoint resolution, so your application seamlessly starts using the new region.

A practical tip: if you're adding a region just before a major product launch in a new geography, do it well in advance. Initial data synchronization depends on the amount of data you have, and you want the region fully caught up and ready before the traffic spike.

## Multi-Region Reads: Routing to the Nearest Region

The simplest and most impactful way to reduce read latency for a global user base is to deploy read replicas close to your users and configure the SDK to prefer the nearest one.

In the .NET SDK, you configure this with `ApplicationPreferredRegions`:

```csharp
CosmosClientOptions options = new CosmosClientOptions
{
    ApplicationPreferredRegions = new List<string>
    {
        Regions.WestUS2,
        Regions.EastUS,
        Regions.WestEurope
    }
};
```

The SDK sends reads to the first reachable region in the list. If West US 2 becomes unavailable, the SDK automatically falls back to East US, then West Europe — no code changes, no redeployment.

For applications deployed across multiple regions (for example, App Service instances in several geographies), each deployment should list its local region first in the preferred regions list. This ensures reads always go to the co-located Cosmos DB replica, giving you single-digit-millisecond latency.

With a single-write-region configuration, all writes still go to the designated write region regardless of the preferred regions list. The multi-region read pattern gives you 99.999% read availability SLA, while write availability remains at 99.99% (or 99.995% with zone redundancy). For many workloads — especially read-heavy ones — this is the sweet spot: global read performance without the complexity of multi-region writes.

## Multi-Region Writes: The 99.999% Availability Story

When you enable multi-region writes, every region in your account becomes a write region. Your application writes to the local region, and Cosmos DB handles the replication. This is the configuration that unlocks the **99.999% SLA** for both reads and writes — five nines of availability.

Enabling multi-region writes requires two changes in your application:

1. **Enable the feature on the account**: Toggle the multi-region writes setting in the portal, CLI, or ARM template.
2. **Update the SDK configuration**: Set `ApplicationPreferredRegions` (as above) so the SDK knows to write locally.

With this configuration, a user in Sydney writes to the Australia East replica, a user in London writes to UK South, and Cosmos DB asynchronously replicates those writes to all other regions.

The tradeoff? You must use a consistency level weaker than strong (strong consistency is not supported with multi-region writes), and you must handle the possibility of write-write conflicts.

### Conflict Resolution Policies

When two users in different regions update the same item at roughly the same time, you have a write-write conflict. Cosmos DB provides two built-in conflict resolution policies, configured per container at creation time:

#### Last-Write-Wins (LWW)

This is the default. Cosmos DB compares a numeric property on each conflicting write — by default, the system-managed `_ts` (timestamp) property — and the write with the highest value wins. All regions converge to the same winner.

You can customize the conflict resolution path to any numeric property on your documents. For example, if your application has its own logical timestamp or a priority field, you can tell Cosmos DB to use that instead:

```csharp
ContainerProperties properties = new ContainerProperties("myContainer", "/partitionKey")
{
    ConflictResolutionPolicy = new ConflictResolutionPolicy
    {
        Mode = ConflictResolutionMode.LastWriterWins,
        ResolutionPath = "/myCustomPriority"
    }
};
```

LWW is simple and sufficient for many workloads — especially when your application partitions writes geographically so conflicts are rare.

#### Custom Merge Procedure

For scenarios where "highest timestamp wins" isn't acceptable — financial transactions, inventory counts, collaborative editing — you can register a server-side merge stored procedure. Cosmos DB invokes this procedure exactly once for each detected conflict, within a database transaction.

If you configure the custom policy but don't register a merge procedure (or the procedure throws an exception), conflicting writes land in the **conflicts feed**. Your application can read this feed and resolve conflicts manually with application-specific logic.

> **Note:** Custom conflict resolution is available only for the NoSQL API and must be set at container creation time. You cannot change the policy on an existing container.

#### Best Practices for Multi-Region Writes

- **Keep local traffic local.** Don't send the same write to multiple regions "just in case." That creates unnecessary conflicts.
- **Avoid dependency on replication lag.** If you write to Region A and immediately read from Region B, you may not see your write yet. Design for this.
- **Be cautious with session tokens across regions.** Session tokens guarantee read-your-writes within a single region. Passing a session token from Region A to a write in Region B can cause that write to block until Region B catches up.
- **Minimize rapid updates to the same document.** Frequent updates to the same document ID across regions amplify conflict resolution overhead.

## Automatic Failover and Regional Outage Scenarios

When a region goes down, what happens to your application depends on your configuration.

### Single-Write-Region with Service-Managed Failover

This is the configuration Microsoft recommends for most production workloads. You designate one region as the write region and one or more as read regions, and you enable **service-managed failover**.

When a write-region outage occurs:

1. Cosmos DB detects the outage.
2. It promotes a secondary region to become the new write region, following your configured failover priority order.
3. The SDK detects the failover and redirects writes to the new region.

During this transition, there is a brief period of write unavailability — typically seconds to a few minutes, though in partial outage scenarios it could take up to an hour or more with manual intervention from the Cosmos DB service team.

When a read-region outage occurs, the SDK automatically redirects reads to the next available region in the preferred regions list. There is no read availability loss and no data loss.

> **Important:** After a service-managed failover promotes a secondary region to write, the original region is *not* automatically promoted back when it recovers. You must manually switch the write region back using the portal, CLI, or PowerShell once it's safe to do so.

### Multi-Region Writes

With multi-region writes, a regional outage is less disruptive. The affected region goes offline, but all other regions continue accepting both reads and writes. There may be a brief, temporary loss of write availability in the affected region only. Once the region recovers, Cosmos DB automatically reconciles any unreplicated data using the configured conflict resolution policy.

### What You Should Not Do

- **Don't trigger a manual failover during an outage.** Manual failover requires connectivity between the source and destination regions for a consistency check. During an outage, this connectivity doesn't exist, and the failover will fail.
- **Don't rely on a single region without zone redundancy for production.** It's the highest-risk configuration.

## Per-Partition Automatic Failover (PPAF) — Preview

Traditional service-managed failover operates at the *account* level — when the write region is unhealthy, the entire account fails over. **Per-Partition Automatic Failover (PPAF)** is a preview feature that brings failover granularity down to the individual *partition* level.

Instead of waiting for an entire region to be declared unhealthy, Cosmos DB can detect that specific partitions within a region are experiencing issues — perhaps a storage node failure or a hot partition scenario — and automatically fail over just those partitions to a healthy region. The remaining partitions continue operating in the original write region.

### Why PPAF Matters

Account-level failover is a blunt instrument. If 99% of your partitions are healthy in the write region but 1% are having issues, traditional failover moves *everything*. PPAF surgically moves only the affected partitions, minimizing disruption and recovery time.

### Prerequisites and Limitations

PPAF is currently in **public preview** and comes with several requirements:

- **Multi-region account**: You need at least one read region in addition to the write region.
- **NoSQL API only**: PPAF is available only for Core (SQL/NoSQL) API accounts.
- **Supported consistency levels**: Strong, Session, Consistent Prefix, and Eventual are supported. Bounded Staleness is not supported in the current preview.
- **SDK versions**: .NET SDK v3.54.0+ or Java SDK v4.75.0+.
- **Azure public cloud only**: Sovereign clouds are not eligible during the preview.
- **Business Critical tier pricing**: PPAF is part of the Business Critical Service Tier.

### Testing PPAF

You can simulate partition-level faults using a PowerShell script provided by the Cosmos DB team. The simulation injects faults on approximately 10% of partitions (up to 10, minimum 1) for a specified container, allowing you to validate that your application handles partition-level failover gracefully.

## RPO and RTO by Configuration

Recovery Point Objective (RPO) tells you how much data you could lose in a disaster. Recovery Time Objective (RTO) tells you how long you'll be without service. These numbers vary significantly depending on how you configure your Cosmos DB account.

### RPO Reference Table

| Regions | Replication Mode | Consistency Level | RPO |
|---|---|---|---|
| 1 | Single or multi-region writes | Any | < 240 minutes (depends on backup) |
| >1 | Single write region | Session, Consistent Prefix, Eventual | < 15 minutes |
| >1 | Single write region | Bounded Staleness | *K* updates or *T* seconds¹ |
| >1 | Single write region | Strong | 0 |
| >1 | Multi-region writes | Session, Consistent Prefix, Eventual | < 15 minutes |
| >1 | Multi-region writes | Bounded Staleness | *K* updates or *T* seconds¹ |

¹ For multi-region accounts, the minimum *K* is 100,000 write operations and the minimum *T* is 300 seconds.

### RTO Reference Table

| Configuration | Outage Type | RTO |
|---|---|---|
| Single region, no zone redundancy | Region outage | Full duration of outage (no automatic recovery) |
| Single region, with zone redundancy | Zone failure | 0 (transparent, no availability loss) |
| Multi-region, single write, service-managed failover | Write region outage | Seconds to minutes (up to ~1 hour in partial outage scenarios) |
| Multi-region, single write, service-managed failover | Read region outage | 0 (SDK redirects transparently) |
| Multi-region writes | Any regional outage | ~0 for unaffected regions; brief disruption in the affected region |
| Single node failure (any config) | Node outage | 0 (transparent, replica-set quorum handles it) |

### SLA Summary

| Configuration | Write Availability SLA | Read Availability SLA |
|---|---|---|
| Single region, no zone redundancy | 99.99% | 99.99% |
| Single region, with zone redundancy | 99.995% | 99.995% |
| Multi-region, single write region | 99.99% | 99.999% |
| Multi-region, single write, with zone redundancy | 99.995% | 99.999% |
| Multi-region writes (with or without zone redundancy) | 99.999% | 99.999% |

The jump from 99.99% to 99.999% may look small, but in annual downtime terms, it's the difference between about 52 minutes per year and about 5 minutes per year. That last nine is expensive — both in infrastructure cost and operational complexity — but for mission-critical global applications, it's worth it.

## Azure Government and Sovereign Cloud Regions

Cosmos DB is deployed across all four Azure cloud environments:

- **Azure Public**: The standard global cloud, available in 60+ regions worldwide.
- **Azure Government**: Available in multiple US regions for US government agencies and their partners. Supports the same global distribution features, but replication is constrained to government regions.
- **Azure Government DoD**: Available in two US regions dedicated to the Department of Defense.
- **Microsoft Azure operated by 21Vianet**: Available in China, operated by 21Vianet under a unique partnership with Microsoft.

> **Note:** Azure Germany (Microsoft Cloud Deutschland) was retired on October 29, 2021, and is no longer available.

Sovereign cloud deployments support the same multi-region replication features, but regions are isolated within their cloud boundary. You cannot replicate between Azure Public and Azure Government, for example. When planning multi-region distribution for regulated workloads, work within the available regions in your cloud environment.

One note on PPAF: the preview is currently limited to Azure public cloud regions. Sovereign cloud accounts are not eligible during the preview period.

## Putting It All Together

Here's a practical decision framework for choosing your global distribution configuration:

1. **Start with multi-region, single write, service-managed failover.** This gives you 99.999% read availability, automatic failover for write outages, and keeps conflict resolution simple. It's the right choice for most production workloads.

2. **Enable zone redundancy on your write region** — always, if supported. The availability improvement is significant and the cost is modest.

3. **Move to multi-region writes only if you need it.** Specifically: if your application requires write latency below 10ms globally, or if you need 99.999% write availability. Accept the complexity of conflict resolution.

4. **Consider PPAF** if you're running a mission-critical workload on the NoSQL API and want the most granular failover behavior available. Watch for it to move to general availability.

5. **Test your failover behavior.** Use manual failover drills (temporarily disable service-managed failover, trigger a manual failover, observe your application, then re-enable). Don't wait for a real outage to discover that your application doesn't handle region switches gracefully.

## What's Next

Global distribution gets your data close to your users, but what guarantees do those users get when they read data that's replicated worldwide? In **Chapter 12**, we'll explore **consistency levels** — the five options from strong to eventual, how each affects latency and RU cost, per-request consistency overrides, and how consistency interacts with multi-region writes. Choosing the right consistency level is one of the most nuanced decisions in distributed database design.
