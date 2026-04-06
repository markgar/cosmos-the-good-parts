# Chapter 19: Backup, Restore, and Disaster Recovery

It's 2 AM on a Tuesday. A well-meaning deployment script runs a bulk delete against production — wrong container. Two hundred thousand customer records vanish in seconds. Or maybe it's something less dramatic: a region-wide Azure outage knocks your primary write region offline for an hour. In both cases, the question is the same: *how fast can you get back to normal, and how much data do you lose?*

Cosmos DB gives you strong answers to both questions — but only if you've configured the right backup mode and understand how regional failover interacts with your recovery objectives. This chapter is where those pieces come together. We'll cover the two backup modes (periodic and continuous), how to actually perform a restore, and how to build a disaster recovery plan that matches your application's tolerance for downtime and data loss.

Chapter 12 covered the mechanics of multi-region distribution, failover, and the RPO/RTO table. This chapter focuses on the operational side: configuring backups, executing restores, and building the business continuity checklist that ties it all together.

## Periodic Backup Mode: The Default

Every new Cosmos DB account starts in **periodic backup mode** unless you explicitly choose otherwise. It's the zero-configuration option — backups happen automatically in the background, and you never interact with them directly until you need a restore.

<!-- Source: manage-your-account/back-up-and-restore/periodic-backup/periodic-backup-restore-introduction.md -->

### How Periodic Backups Work

Cosmos DB takes a full snapshot of your data every **4 hours** by default, retaining the **latest two backups**. These snapshots are stored in Azure Blob Storage, completely separate from your database's live storage. The process runs in the background without consuming any of your provisioned throughput (RUs) and without affecting the performance or availability of your database operations.

<!-- Source: manage-your-account/back-up-and-restore/periodic-backup/periodic-backup-restore-introduction.md -->

The backup is taken in the **write region** of your account. The snapshot is stored in Blob Storage in that same region, then replicated to the paired region via geo-redundant storage (GRS) by default. You can't access the backup blobs directly — they're fully managed by the platform.

Here's the important detail: if a container or database is deleted, Cosmos DB retains the existing snapshots for **30 days**, even though your normal retention might be shorter. This gives you a window to discover the problem and request a restore.

<!-- Source: manage-your-account/back-up-and-restore/periodic-backup/periodic-backup-restore-introduction.md -->

### Configuring Backup Interval and Retention

The defaults (4-hour interval, two copies retained) are fine for many workloads, but you can tune both:

<!-- Source: manage-your-account/back-up-and-restore/periodic-backup/periodic-backup-modify-interval-retention.md -->

| Setting | Range | Default |
|---------|-------|---------|
| **Backup interval** | 1–24 hours | 4 hours |
| **Retention** | 2× interval to 720 hrs | 8 hours |
| **Copies retained** | 2 (free) + extra at cost | 2 |
| **Storage redundancy** | GRS, ZRS, or LRS | GRS |

Retention must be at least twice the backup interval, up to a max of 720 hours. The default 8 hours reflects two copies at a 4-hour interval. Additional copies beyond the included two incur extra cost. Storage redundancy defaults to geo-redundant (GRS) where available; zone-redundant (ZRS) and locally redundant (LRS) are also options.

You can change these settings at any time — during account creation or afterward — via the portal, CLI, or PowerShell. The configuration applies at the account level; every container in the account gets the same backup schedule.

```bash
az cosmosdb update \
    --resource-group myapp-rg \
    --name myapp-cosmos \
    --backup-interval 480 \
    --backup-retention 24
```

<!-- Source: manage-your-account/back-up-and-restore/periodic-backup/periodic-backup-modify-interval-retention.md -->

Two backups are included at no extra charge. If you increase retention beyond two copies, you pay for the additional backup storage. The pricing depends on data size and region — check the Cosmos DB pricing page for current rates.

### Backup Storage Redundancy

By default, periodic backups use **geo-redundant storage (GRS)**, which replicates your backup data to the Azure paired region. This protects against a regional disaster taking out both your live data and its backups simultaneously.

<!-- Source: manage-your-account/back-up-and-restore/periodic-backup/periodic-backup-storage-redundancy.md -->

You have three options:

- **Geo-redundant (GRS):** Backup replicated asynchronously to the paired region. Best protection against regional disasters.
- **Zone-redundant (ZRS):** Backup replicated synchronously across three availability zones within the same region. Good when data residency requirements prevent cross-region replication.
- **Locally redundant (LRS):** Three copies within a single physical location. Cheapest, but no protection against zone or regional failures.

Choose based on your compliance and residency requirements. If regulations prohibit your data from leaving a specific region, switch from GRS to ZRS or LRS. Just understand the tradeoff: you're trading regional disaster resilience for data locality.

### How to Request a Restore (Periodic Mode)

This is the part that catches people off guard: **you can't self-service a periodic backup restore.** You have to file a support ticket with Microsoft.

<!-- Source: manage-your-account/back-up-and-restore/periodic-backup/periodic-backup-request-data-restore.md -->

Here's the process:

1. **Immediately increase your backup retention to at least 7 days.** Do this within 8 hours of discovering the problem. Since the backup process keeps running on the live container, existing backups get overwritten as new ones are taken. Extending retention buys time for the Cosmos DB team to find and restore the right snapshot.
2. **File a support ticket** through the Azure portal or call Azure Support. Select "Backup and Restore" as the problem type.
3. **Provide precise details:** subscription ID, account name, database names, container names, and the point-in-time (in UTC) you want to restore to. The more precise the timestamp, the better the outcome.
4. **Wait for the restore.** The Cosmos DB team restores your data into a **new account**. You can't restore into the existing account with periodic mode.

<!-- Source: manage-your-account/back-up-and-restore/periodic-backup/periodic-backup-request-data-restore.md -->

The restored account gets a name like `<original-name>-restored1`. It has the same provisioned throughput, indexing policies, and consistency settings as the original — but it's a single-region account in the write region, regardless of how many regions the source had. Several settings are **not** restored — see the business continuity checklist at the end of this chapter for the full list of what you'll need to reconfigure manually.

<!-- Source: manage-your-account/back-up-and-restore/periodic-backup/periodic-backup-restore-introduction.md, manage-your-account/back-up-and-restore/periodic-backup/periodic-backup-request-data-restore.md -->

After verifying the restored data, migrate it back to your original account using Azure Data Factory, the change feed, or custom code. Then delete the restored account to stop paying for its throughput and storage.

> **Gotcha:** Azure Support for restore requests requires a **Standard** or **Developer** support plan (or higher). The Basic plan doesn't include it. If you're running production workloads on Cosmos DB and still on Basic support, fix that before you have an incident.

### When Periodic Mode Makes Sense

Periodic backup is adequate for workloads where:

- You're comfortable with the possibility of losing up to one backup interval worth of data (worst case: 4 hours with defaults).
- You can tolerate the time it takes to file a support ticket and wait for a restore.
- Cost minimization is a priority — though the 7-day continuous tier is also free for backup storage, so weigh both options.

For most production applications, continuous backup is the better choice. Let's look at why.

## Continuous Backup Mode with Point-in-Time Restore (PITR)

**Continuous backup mode** replaces the periodic snapshot approach with a continuous log-based backup that lets you restore to *any second* within a retention window — 7 or 30 days, depending on your tier. No support tickets. No waiting for a human. Self-service restore via the portal, CLI, or PowerShell.

<!-- Source: manage-your-account/back-up-and-restore/continuous-backup/continuous-backup-restore-introduction.md -->

This is the backup mode you should default to for any application where data loss matters.

### Enabling Continuous Backup

You choose continuous backup mode when creating the account. In the Azure portal, it's on the **Backup Policy** tab during account creation — select **Continuous** and pick your tier.

<!-- Source: manage-your-account/back-up-and-restore/continuous-backup/provision-account-continuous-backup.md -->

Via the CLI:

```bash
az cosmosdb create \
    --name myapp-cosmos \
    --resource-group myapp-rg \
    --locations regionName=eastus \
    --backup-policy-type Continuous \
    --continuous-tier "Continuous7Days" \
    --default-consistency-level Session
```

If you don't specify a tier, it defaults to **Continuous30Days**.

<!-- Source: manage-your-account/back-up-and-restore/continuous-backup/provision-account-continuous-backup.md -->

Already have an account on periodic mode? You can migrate to continuous — but it's a **one-way operation**. Once you switch, you can't go back to periodic.

<!-- Source: manage-your-account/back-up-and-restore/continuous-backup/migrate-continuous-backup.md -->

```bash
az cosmosdb update \
    --resource-group myapp-rg \
    --name myapp-cosmos \
    --backup-policy-type Continuous \
    --continuous-tier "Continuous7Days"
```

Migration time depends on the data size. You can track progress via `az cosmosdb show` — look for the `migrationState` property in the `backupPolicy` object. When it shows `null` and the type shows `Continuous`, the migration is complete.

<!-- Source: manage-your-account/back-up-and-restore/continuous-backup/migrate-continuous-backup.md -->

### 7-Day vs. 30-Day Retention Tiers

Continuous backup comes in two tiers with meaningfully different cost profiles:

<!-- Source: manage-your-account/back-up-and-restore/continuous-backup/continuous-backup-restore-introduction.md -->

| | **7-Day** | **30-Day** |
|---|---|---|
| **Retention** | 7 days | 30 days |
| **Backup storage** | Free | $0.20/GB × regions/mo |
| **Restore cost** | $0.15/GB per restore | $0.15/GB per restore |
| **Default tier** | No | Yes |

The 7-day tier is a compelling default for many applications. You get self-service PITR with no backup storage charges — you only pay when you actually perform a restore. For a 1 TB account across two regions on the 30-day tier, backup storage alone runs $400/month. That's a meaningful line item.

The 30-day tier is worth the cost when your compliance requirements or data recovery policies demand a longer retention window — regulated industries, audit requirements, or applications where problems might not surface for weeks.

You can switch between tiers at any time. But be careful:

- **Switching from 30-day to 7-day:** You immediately lose the ability to restore to any point older than 7 days.
- **Switching from 7-day to 30-day:** You can only restore data from the last 7 days until new backups accumulate past that window.

<!-- Source: manage-your-account/back-up-and-restore/continuous-backup/migrate-continuous-backup.md -->

### How Continuous Backups Are Stored

Unlike periodic mode (which takes full snapshots at intervals), continuous mode takes backups in **every region** where your account exists. Each region's backup is stored in Azure Blob Storage in that same region — locally redundant by default, or zone-redundant if the region has availability zones enabled.

<!-- Source: manage-your-account/back-up-and-restore/continuous-backup/continuous-backup-restore-introduction.md -->

Mutations are backed up asynchronously within **100 seconds**. If the backup storage is temporarily unavailable, mutations are persisted locally until the storage comes back, then flushed — so no data is lost in the backup stream.

<!-- Source: manage-your-account/back-up-and-restore/continuous-backup/continuous-backup-restore-introduction.md -->

> **Gotcha:** You can't change the backup storage redundancy for continuous mode accounts. It's automatically determined by the region's availability zone configuration. This is different from periodic mode, where you can choose GRS, ZRS, or LRS.

### Restoring to a Point in Time

The core value of continuous backup is the ability to pick any second within your retention window and restore to that exact moment. You can restore the entire account, specific databases, or specific containers.

#### Restoring into a New Account

The default restore path creates a **new Cosmos DB account** containing your data as it existed at the specified timestamp:

<!-- Source: manage-your-account/back-up-and-restore/continuous-backup/restore/restore-account-continuous-backup.md -->

**Via the portal:**

1. Navigate to your Cosmos DB account → **Point In Time Restore**.
2. Enter the **Restore Point (UTC)** — any timestamp within the retention window.
3. Choose the **Location** — this must be a region where the source account existed at that timestamp.
4. Select whether to restore the entire account or specific databases/containers.
5. Specify a **Resource Group** and **Target Account Name** for the new account.
6. Click **Submit**.

**Via the CLI** (restoring a deleted account):

```bash
az cosmosdb restore \
    --resource-group myapp-rg \
    --account-name myapp-cosmos-restored \
    --target-database-account-name myapp-cosmos \
    --restore-timestamp "2025-01-15T14:30:00Z" \
    --location eastus
```

The restore cost is a one-time charge of approximately **$0.15/GB** based on the data size. Restoring 1 TB costs about $150.

<!-- Source: manage-your-account/back-up-and-restore/continuous-backup/continuous-backup-restore-introduction.md -->

The same limitations from periodic restore apply here — several account-level settings are not carried over, and the new account starts as single-region. See the business continuity checklist at the end of this chapter for the full list of what needs reconfiguring.

<!-- Source: manage-your-account/back-up-and-restore/continuous-backup/continuous-backup-restore-introduction.md -->

> **Tip:** Use the event feed in the portal to discover *when* a deletion or modification happened. The event feed lists create, replace, and delete operations on databases and containers in chronological order — helpful when you know something went wrong but aren't sure exactly when.

#### Restoring a Deleted Container or Database

One of the most common restore scenarios is recovering an accidentally deleted container or database. With continuous backup, you can restore deleted containers and databases within the configured retention window — 7 days on the 7-day tier, 30 days on the 30-day tier.

<!-- Source: manage-your-account/back-up-and-restore/continuous-backup/continuous-backup-restore-introduction.md -->

Deleted *accounts* are different: you can restore a deleted account within **30 days of deletion regardless of which tier you were on**. Navigate to the Azure Cosmos DB service page in the portal (not a specific account), click **Restore**, and you'll see a list of deleted accounts that are still within their 30-day restorable window.

<!-- Source: manage-your-account/back-up-and-restore/continuous-backup/restore/restore-account-continuous-backup.md -->

### In-Account Restore: Same Account, No Migration

The newer and often more convenient restore path is **in-account restore**, which restores a deleted database or container directly back into the same account. No new account to create, no data migration, no re-configuring network rules.

<!-- Source: manage-your-account/back-up-and-restore/continuous-backup/restore/restore-in-the-same-account/restore-in-account-continuous-backup-introduction.md -->

This is the preferred approach for the most common accident: "someone deleted a container they shouldn't have." Instead of standing up a whole new account, you restore the deleted resource in place.

**How it works:**

1. Navigate to your Cosmos DB account → **Point In Time Restore** → **Restore to same account** tab.
2. Search the event feed for the deletion event.
3. Select the deleted resource and specify a restore timestamp (must be before the deletion).
4. Click **Restore**.

The restored resource gets the same name and resource ID as the original. Cosmos DB distinguishes between the original and restored versions using a `CollectionInstanceId` field internally — useful for debugging restore operations or distinguishing the original from the restored resource in diagnostic logs.

<!-- Source: manage-your-account/back-up-and-restore/continuous-backup/restore/restore-in-the-same-account/restore-in-account-continuous-backup-introduction.md -->

**Via the CLI** (restoring a deleted container):

```bash
# First, find the instance ID of your account
az cosmosdb restorable-database-account list \
    --account-name myapp-cosmos

# Then restore the deleted container
az cosmosdb sql container create \
    --resource-group myapp-rg \
    --account-name myapp-cosmos \
    --database-name orders-db \
    --name deleted-container \
    --restore-parameters restoreSource="<instance-id>" \
                         restoreTimestampInUtc="2025-01-15T14:30:00Z"
```

**Key constraints for in-account restore:**

<!-- Source: manage-your-account/back-up-and-restore/continuous-backup/restore/restore-in-the-same-account/restore-in-account-continuous-backup-introduction.md, manage-your-account/back-up-and-restore/continuous-backup/restore/how-to-restore-in-account-continuous-backup.md -->

- You can only restore **deleted** resources. You can't overwrite a live container with an earlier version of itself — for that, use the new-account restore path.
- Shared-throughput containers can't be restored individually. The entire shared-throughput database must be restored.
- The parent database must exist before you can restore a child container. Restore the database first if both were deleted.
- No more than **three** restore operations can run in parallel on the same account.
- Same-account restore can't run while account-level operations (add region, remove region, failover) are in progress.
- After restore, session tokens and continuation tokens from client applications become invalid. Restart your SDK clients to refresh cached tokens.
- Change feed listeners on the restored resource must restart from the beginning — the restored resource only carries change feed events from its new lifetime, not the original's.

### Multi-Region Write Accounts and Continuous Backup

Multi-region write accounts add a nuance to continuous backup that's worth understanding. In a multi-write account, all writes go through a **hub region** for conflict resolution. Satellite regions send their writes to the hub for confirmation, and the satellite only backs up documents after the hub confirms them.

<!-- Source: manage-your-account/back-up-and-restore/continuous-backup/continuous-backup-restore-introduction.md -->

This means: if you restore a multi-write account to a timestamp *T*, you only get documents that the hub region had confirmed by *T*. Writes that were in flight from a satellite region — submitted but not yet confirmed by the hub — won't appear in the restore. For most practical purposes, this is a non-issue (confirmation happens in under 100 seconds), but it's worth knowing for tight restore windows.

One additional wrinkle: collections with custom conflict resolution policies are reset to **last-writer-wins based on timestamp** after a restore. If you use custom conflict resolution, you'll need to reconfigure it on the restored account.

### What Continuous Backup Doesn't Cover

A few things to keep in mind:

- **Analytical store and mirrored data are not backed up.** If you're using Azure Synapse Link (deprecated, but still in use) or Microsoft Fabric mirroring, only the transactional store is included in backups. The analytical store and Fabric-side replicas will repopulate from the transactional store after restore, but there may be a delay.
- **The restored account may not preserve your original throughput settings** as of the restore point.
- **TTL-expired documents are not restored.** If your container has a TTL policy, documents that expired before the restore point are gone. Additionally, the restore process restores the TTL configuration itself — so if you restore without disabling TTL, documents may start expiring again immediately. Use the `--disable-ttl` flag during restore to prevent this.

<!-- Source: manage-your-account/back-up-and-restore/continuous-backup/continuous-backup-restore-introduction.md -->

## Periodic vs. Continuous: Which Should You Choose?

| | **Periodic** | **Continuous** |
|---|---|---|
| **Granularity** | Nearest snapshot | Any second in window |
| **Restore method** | Support ticket | Self-service (portal/CLI) |
| **Restore target** | New account only | New or same account |
| **Backup cost** | Free (2 copies) | 7-day free; 30-day paid |
| **Restore cost** | None | $0.15/GB |
| **Migration** | → Continuous (one-way) | Can't revert to periodic |

The 30-day continuous tier charges $0.20/GB × number of regions per month for backup storage. You can switch between the 7-day and 30-day tiers at any time, but switching from continuous back to periodic is not possible.

For new production accounts, **continuous 7-day** is the sensible default. You get self-service PITR with no backup storage costs. Upgrade to 30-day if compliance demands it. Reserve periodic mode for non-critical environments where you want the absolute simplest (and cheapest) configuration and can tolerate filing a support ticket if something goes wrong.

## Disaster Recovery Configurations

Backup and restore protect you from accidental data loss — the "oops" scenarios. Disaster recovery protects you from regional outages — the infrastructure scenarios. They're complementary, not interchangeable.

Chapter 12 covered the mechanics of multi-region replication, failover types, and the RPO/RTO table in detail. Here we focus on the *planning* side: which configuration matches which business requirement, and what you need to prepare ahead of time.

### Single-Region Accounts: No Automatic Failover

A single-region Cosmos DB account has **no automatic failover capability**. If the region goes down, your account is unavailable for reads and writes until the region recovers. With availability zones enabled, you can survive a single-zone outage, but a full regional outage means you wait.

<!-- Source: high-availability/disaster-recovery-guidance.md -->

Your options during a single-region outage:

1. **Wait for Azure to restore the region.** Monitor via the Service Health page and your account's Resource Health.
2. **Request an account restore to a different region** via Azure Support (periodic mode) or self-service (continuous mode). This creates a new account in a healthy region, but it's not instant.

The RPO for a single-region account is **< 240 minutes** — that's up to 4 hours of potential data loss, regardless of consistency level. The RTO is entirely dependent on how long Azure takes to restore the region.

<!-- Source: high-availability/consistency/consistency-levels.md -->

> **Important:** Single-region is acceptable for dev/test and non-critical workloads. For anything where downtime costs money, add at least one more region.

### Multi-Region with Single Write: Automatic Failover

Adding read regions gives you two things: lower read latency for geographically distributed users, and **automatic failover** when the write region goes down.

<!-- Source: high-availability/disaster-recovery-guidance.md -->

With **service-managed failover** enabled, Cosmos DB automatically promotes a read region to become the new write region when it detects a write region outage. The failover follows the priority order you've configured. However — and this is important — the timing depends on the outage's nature and progression. **Failover can take up to one hour or more.**

<!-- Source: high-availability/disaster-recovery-guidance.md -->

If you can't wait, you can manually trigger a **region offline operation**, which immediately removes the failed region and promotes the next in the priority list. This is faster but carries risk: writes committed in the old write region but not yet replicated may be lost.

The RPO depends on your consistency level (see the table in Chapter 12):

- **Strong consistency:** RPO = 0 (no data loss), but requires synchronous replication that adds write latency.
- **Session/Consistent Prefix/Eventual:** RPO < 15 minutes.
- **Bounded Staleness:** RPO = the configured staleness window (*K* versions or *T* seconds).

The RTO for service-managed failover is on the order of **minutes to ~1 hour**, depending on outage detection speed. For manual region-offline, it's as fast as you can detect the outage and execute the operation.

### Multi-Region Write: Near-Zero Downtime

Multi-region write accounts are the highest availability configuration Cosmos DB offers. Every region accepts both reads and writes, and the SDKs automatically route traffic away from unhealthy regions. No manual failover needed. No promotion dance. No waiting.

<!-- Source: high-availability/disaster-recovery-guidance.md -->

The tradeoff: multi-write accounts can't use strong consistency, so RPO = 0 is not achievable. With Session, Consistent Prefix, or Eventual consistency, the RPO is less than 15 minutes. In practice, replication lag is typically seconds, so actual data loss during a regional outage is minimal — but it's not zero.

The RTO is effectively **near-zero** for applications with properly configured SDKs. Traffic routes to healthy regions automatically. Your application keeps running.

**Single region:**

| Metric | Value |
|--------|-------|
| RTO | Region recovery time |
| RPO (all consistency levels) | < 240 min |
| Auto failover | No |

**Multi-region, single write:**

| Metric | Value |
|--------|-------|
| RTO | Minutes to ~1 hour |
| RPO (Session/CP/Eventual) | < 15 min |
| RPO (Bounded Staleness) | *K* & *T*¹ |
| RPO (Strong) | 0 |
| Auto failover | Yes (service-managed) |

**Multi-region, multi-write:**

| Metric | Value |
|--------|-------|
| RTO | Near-zero |
| RPO (Session/CP/Eventual) | < 15 min |
| RPO (Bounded Staleness) | *K* & *T*¹ |
| RPO (Strong) | N/A |
| Auto failover | Yes (automatic) |

¹ *K* = the configured maximum version lag; *T* = the configured maximum time lag. For multi-region accounts the minimum is 100,000 operations or 300 seconds.

<!-- Source: high-availability/consistency/consistency-levels.md -->

## Business Continuity Planning Checklist

Knowing the features is one thing. Having a plan is another. Here's a practical checklist for Cosmos DB business continuity:

### 1. Choose Your Backup Mode Deliberately

Don't accept the periodic default without thinking about it. For any account where accidental data loss is unacceptable, enable continuous backup. The 7-day tier is free for backup storage — the only reason not to use it is if you need to support a scenario that continuous backup doesn't cover (like API for Cassandra, which isn't supported).

### 2. Enable Multi-Region Deployment for Production

Single-region accounts are single points of failure. Add at least one read region to enable automatic failover. The cost of a second region is meaningful, but compare it to the cost of your application being completely offline for the duration of a regional outage.

### 3. Enable Service-Managed Failover (Single-Write Accounts)

If you're running a single-write configuration, toggle on service-managed failover. It's a checkbox in the portal under **Replicate data globally**. Without it, write-region outages require manual intervention.

```bash
az cosmosdb update \
    --resource-group myapp-rg \
    --name myapp-cosmos \
    --enable-automatic-failover true
```

### 4. Configure Preferred Regions in Your SDK

Failover only helps if your SDK knows where to route traffic. Set the preferred regions list to match your deployment topology. Chapter 12 covered this in detail — the SDK automatically retries operations in the next preferred region when the current one becomes unavailable.

### 5. Test Your Failover Regularly

Cosmos DB provides a manual failover API specifically for business continuity drills. Use it. Run a test failover at least quarterly and verify that your application handles the transition gracefully — reconnections, cache invalidation, region routing.

### 6. Document Your Restore Procedures

A backup you can't restore in an emergency is not a backup. Document the exact steps:

- Who has the RBAC permissions to trigger a restore? (You need the `CosmosRestoreOperator` and `Cosmos DB Operator` roles for continuous backup restores.)
- What's the target resource group for a restored account?
- What configurations need to be reapplied after restore (firewall rules, VNET settings, RBAC assignments, stored procedures)?
- Who's responsible for verifying the restored data and migrating it back to the original account?

<!-- Source: manage-your-account/back-up-and-restore/continuous-backup/continuous-backup-restore-permissions.md -->

### 7. Monitor and Alert on Availability

Set up Azure Monitor alerts for your Cosmos DB account's availability metrics. Configure Service Health alerts to get email notifications when Azure detects an outage affecting your subscription. Don't rely on users reporting problems as your monitoring strategy.

### 8. Understand What's Not Backed Up

Regardless of backup mode, these items are **never** included in a restore:

- Firewall rules, VNET settings, and private endpoint configurations
- Data plane RBAC assignments
- Stored procedures, triggers, and UDFs
- Multi-region configuration (restored accounts start single-region)
- Managed identity settings
- Analytical store data (Synapse Link)
- Materialized views

<!-- Source: manage-your-account/back-up-and-restore/periodic-backup/periodic-backup-restore-introduction.md, manage-your-account/back-up-and-restore/periodic-backup/periodic-backup-request-data-restore.md, manage-your-account/back-up-and-restore/continuous-backup/continuous-backup-restore-introduction.md -->

Treat these as infrastructure-as-code artifacts. Define them in Bicep, Terraform, or ARM templates so you can reapply them to a restored account in minutes, not hours. Chapter 20 covers IaC patterns for Cosmos DB in detail.

### 9. Align Backup Mode with Your RTO/RPO Requirements

Map your business requirements to the technical capabilities:

| Goal | Configuration |
|------|---------------|
| RPO < 15 min, RTO < 1 hr | Multi-region, auto failover |
| RPO = 0 | Strong consistency |
| RTO ≈ 0 | Multi-region write |
| Self-service restore | Continuous backup |
| 30-day restore window | Continuous 30-day tier |
| Lowest cost | Single region, periodic |

All RPO/RTO goals above assume multi-region deployment with continuous backup unless otherwise noted. The RPO < 15 min configuration uses single-write with service-managed failover. RPO = 0 requires single-write with strong consistency. The lowest-cost option suits non-critical workloads that can tolerate filing a support ticket for restores.

### 10. Don't Confuse Backup with DR

Backup protects against data-level problems: accidental deletes, bad deployments, data corruption. Disaster recovery protects against infrastructure-level problems: regional outages, availability zone failures. You need both. A multi-region account with automatic failover doesn't help if someone drops your production container. A continuous backup doesn't help if your only region goes offline and you need to keep serving traffic.

The combination — continuous backup *plus* multi-region deployment with automatic failover — gives you the strongest posture across both categories of failure.

Next up, Chapter 20 digs into the operational tooling that keeps your Cosmos DB environment healthy: CI/CD pipelines, infrastructure as code, and managing schema evolution without downtime.
