# Chapter 11: Provisioned Throughput, Autoscale, and Serverless

You've been paying for Cosmos DB since Chapter 3, but do you actually know what you're paying for? Request Units are the *currency* (Chapter 10), but your **capacity model** — how you provision and pay for those RUs — determines whether your monthly bill is pleasantly predictable or a budget-busting surprise. This chapter is where you make the money decisions.

Cosmos DB offers three capacity models: manual provisioned throughput, autoscale provisioned throughput, and serverless. Each has a different billing model, a different set of tradeoffs, and a different sweet spot. Then there are the cost levers layered on top — burst capacity, throughput buckets, reserved capacity, the free tier, and the integrated cache. By the end of this chapter, you'll know which model fits your workload and how to squeeze every dollar out of it.

## Provisioned Throughput: Manual RU/s Allocation

**Manual provisioned throughput** is the original Cosmos DB pricing model and the one most production workloads use. You tell Cosmos DB exactly how many RU/s you want, and the service reserves that capacity for you. You pay for every provisioned RU/s, every hour, whether you use them or not.

<!-- Source: throughput-request-units/set-throughput.md, throughput-request-units/how-to-choose-offer.md -->

That "whether you use them or not" part is the key tradeoff. Manual throughput gives you a fixed, predictable bill — great for budgeting — but if your traffic is spiky, you're paying for idle capacity during the valleys and possibly getting throttled during the peaks.

The minimum is **400 RU/s** for a container with dedicated throughput. The maximum is **1,000,000 RU/s** per container or database, increasable via a support ticket. You're billed per hour at the standard rate — $0.008 per 100 RU/s per hour in US regions (check the pricing page for your region). <!-- Source: manage-your-account/enterprise-readiness/concepts-limits.md, throughput-request-units/how-to-choose-offer.md -->

Manual throughput is the right choice when your workload has **steady, predictable traffic** and you consistently use 66% or more of your provisioned capacity. If you're running a high-volume transactional system that hums along at a consistent rate, manual provisioning is cheaper than autoscale. We'll see the math on that shortly.

### Database-Level vs. Container-Level Throughput

You can provision throughput at two levels: on a specific container (dedicated) or on a database (shared).

<!-- Source: throughput-request-units/set-throughput.md -->

**Container-level (dedicated) throughput** is the most common choice. The RU/s you provision are exclusively reserved for that container, backed by SLAs. If you provision 10,000 RU/s on a container, that container gets all 10,000 — no sharing, no contention from other containers.

**Database-level (shared) throughput** pools RU/s across all containers in the database. You can have up to **25 containers** sharing a single database's throughput, with no per-container minimum. This is useful when you have many small containers that don't individually justify their own dedicated capacity.

<!-- Source: throughput-request-units/set-throughput.md -->

The catch with shared throughput is that you get **no per-container guarantees**. If one container in the pool suddenly attracts heavy traffic, it can starve the others. The throughput each container actually gets depends on its partition key distribution, the number of containers, and the real-time workload across all of them.

| Aspect | Dedicated | Shared |
|--------|-----------|--------|
| **RU/s guarantee** | SLA-backed | None per container |
| **Min (manual)** | 400 RU/s | 400 RU/s for DB |
| **Min (autoscale)** | 1,000 max RU/s | 1,000 max RU/s for DB |
| **Max containers** | No limit | 25 |
| **Best for** | High-traffic | Many small containers |

> **Gotcha:** You can't convert a container from dedicated to shared throughput (or vice versa) after creation. You'd need to create a new container with the desired throughput model and copy the data. Plan before you provision. <!-- Source: throughput-request-units/set-throughput.md -->

You can also mix the two models within a single database. Provision shared throughput on the database, and then give specific high-traffic containers their own dedicated throughput. The dedicated containers don't consume any of the shared pool. <!-- Source: throughput-request-units/set-throughput.md -->

### When to Share Throughput Across Containers

Shared throughput shines in two scenarios:

1. **Multi-tenant applications** where each tenant gets its own container. If you have dozens of tenants with similar, low-volume workloads, shared throughput keeps costs down. (We'll cover multi-tenant patterns in depth in Chapter 26.)

2. **Migration workloads** where you're moving data from a self-managed NoSQL cluster and want a logical equivalent of shared compute capacity across many collections.

If any container in the group has meaningfully different traffic patterns or needs predictable performance guarantees, give it dedicated throughput.

## Autoscale Provisioned Throughput

**Autoscale** is the same provisioned throughput model, but Cosmos DB manages the scaling for you. You set a maximum RU/s (`Tmax`), and the system automatically scales between **10% of `Tmax`** and `Tmax` based on actual usage. Scaling is instantaneous — there's no warm-up delay.

<!-- Source: throughput-request-units/autoscale-throughput/provision-throughput-autoscale.md -->

Set `Tmax` to 20,000 RU/s and you get a container that scales between 2,000 and 20,000 RU/s, reacting in real time to your traffic. When traffic drops at 2 AM, you're billed for the minimum. When it spikes at noon, you've got headroom up to the max without a single 429.

The entry point for autoscale is a `Tmax` of **1,000 RU/s**, which scales between 100 and 1,000 RU/s. You can set `Tmax` in increments of 1,000 RU/s from there. <!-- Source: throughput-request-units/autoscale-throughput/provision-throughput-autoscale.md -->

### How Autoscale Billing Works

Here's the part that trips people up: the autoscale per-RU rate is **1.5× the manual rate** for single-write-region accounts. That's $0.012 per 100 RU/s per hour instead of $0.008. You're paying a premium for the convenience of automatic scaling.

<!-- Source: throughput-request-units/how-to-choose-offer.md -->

But you're only billed for the **highest RU/s the system scaled to in each hour**, not the max. So if your traffic only hits 40% of `Tmax` for most of the day, you're paying the 1.5× rate on 40% of your capacity, not 100%.

**The 66% rule of thumb:** If your workload consistently uses its full provisioned capacity for **more than 66% of the hours in a month**, manual throughput is cheaper. If utilization is below 66%, autoscale wins despite the rate premium. This is a simplified heuristic — your actual crossover depends on how your traffic distributes across hours — but it's a solid starting point. <!-- Source: throughput-request-units/how-to-choose-offer.md -->

> **Tip:** For multi-region write accounts, the autoscale rate per 100 RU/s is the *same* as the manual multi-region write rate. There's no 1.5× premium. If you have multiple write regions, autoscale costs the same as manual at peak — and less whenever the system scales down. For multi-region write accounts, autoscale is almost always the right default. <!-- Source: throughput-request-units/how-to-choose-offer.md, throughput-request-units/autoscale-throughput/provision-throughput-autoscale.md -->

### Cost Comparison: Manual vs. Autoscale

Let's make the math concrete. Suppose you provision 30,000 RU/s and look at three representative hours:

| Hour (Util.) | Manual | Autoscale |
|--------------|--------|-----------|
| 1 (6%, 3K RU/s) | $2.40 | $0.36 |
| 2 (100%, 30K RU/s) | $2.40 | $3.60 |
| 3 (11%, 3.3K RU/s) | $2.40 | $0.40 |
| **Total** | **$7.20** | **$4.36** |

<!-- Source: throughput-request-units/how-to-choose-offer.md -->

In this variable workload, autoscale saves 39%. Now flip the scenario to a steady workload averaging 88% utilization:

| Hour (Util.) | Manual | Autoscale |
|--------------|--------|-----------|
| 1 (72%, 21.6K RU/s) | $2.40 | $2.59 |
| 2 (93%, 28K RU/s) | $2.40 | $3.36 |
| 3 (100%, 30K RU/s) | $2.40 | $3.60 |
| **Total** | **$7.20** | **$9.55** |

<!-- Source: throughput-request-units/how-to-choose-offer.md -->

Same provisioned capacity, but the steady workload pays 33% *more* with autoscale. The 1.5× rate premium only helps you when traffic actually dips.

### Dynamic Scaling: Per-Region, Per-Partition Autoscale

Standard autoscale has a quirk: it scales uniformly based on the *most active* partition and region. If one partition is running hot while nine others are idle, all ten get scaled to the hot partition's level — and you pay for it.

**Dynamic scaling** fixes this by letting each physical partition and each region scale independently. It's enabled by default for all accounts created after **September 25, 2024**. For older accounts, you can enable it from the Features page in the Azure portal. <!-- Source: throughput-request-units/autoscale-throughput/provision-throughput-autoscale.md -->

Dynamic scaling is a pure win for nonuniform workloads. It doesn't change the programming model, has zero downtime to enable, and can significantly reduce costs when you have hot partitions or lightly loaded secondary regions.

### Ideal Workloads for Autoscale

- Variable or unpredictable traffic (seasonal retail, IoT daily spikes)
- New applications where you don't yet know your traffic patterns
- Infrequently used applications (internal tools, low-volume blogs)
- Dev/test workloads that only run during business hours
- Multi-region write accounts (no rate premium)

## Serverless Mode

**Serverless** throws out the entire concept of provisioned capacity. You don't set any RU/s. You just read and write, and Cosmos DB bills you for the exact RUs consumed — $0.25 per million RUs <!-- Source: Azure pricing page (region-dependent) -->, plus storage at the standard rate. No traffic? No charge (beyond storage).

<!-- Source: throughput-request-units/serverless/serverless.md, throughput-request-units/throughput-serverless.md -->

Serverless containers start with a throughput ceiling of **5,000 RU/s** per physical partition. As data grows and partitions are added, the maximum throughput grows linearly: `number of partitions × 5,000 RU/s`. <!-- Source: throughput-request-units/serverless/serverless-performance.md -->

### Serverless Limitations

Serverless comes with real constraints that rule it out for many production workloads:

- **Single region only.** You can't add regions to a serverless account. No global distribution, no multi-region failover. <!-- Source: throughput-request-units/serverless/serverless.md -->
- **No throughput SLA.** Serverless offers an SLO of less than 10 ms for point reads and less than 30 ms for writes — but that's a *service-level objective*, not a contractual guarantee. <!-- Source: throughput-request-units/throughput-serverless.md -->
- **No shared throughput databases.** Every container is independent. <!-- Source: throughput-request-units/serverless/serverless.md -->
- **No autoscale.** Throughput is demand-driven, but you can't set a max or min. <!-- Source: throughput-request-units/serverless/serverless.md -->
- **Less predictable costs.** Your bill is directly proportional to traffic. A surprise spike in usage means a surprise spike in your invoice. <!-- Source: throughput-request-units/serverless/serverless.md -->

### When Serverless Makes Sense

Serverless is the right choice for:

- **Dev/test environments** where you want zero baseline cost.
- **Prototypes and MVPs** where you don't know your traffic patterns yet.
- **Sporadic, low-traffic workloads** — internal tools, webhooks, event-driven functions that fire a few times a day.
- **Applications with low average-to-peak traffic ratios** (less than 10%). <!-- Source: throughput-request-units/serverless/serverless.md -->

The crossover point between serverless and provisioned depends on total monthly RU consumption. At low volumes, serverless is dramatically cheaper. As volume grows, the per-RU cost eventually exceeds what you'd pay with provisioned throughput:

| Scenario | Provisioned | Serverless |
|--------------|-------------|------------|
| Low (20M RU/mo) | $29.20 | $5.00 |
| Moderate (250M RU/mo) | $29.20 | $62.50 |

Both scenarios assume max 500 RU/s.

<!-- Source: throughput-request-units/throughput-serverless.md -->

At 20 million RUs per month, serverless costs 83% less. At 250 million, it costs 114% more. The breakeven is somewhere around 90–100 million RUs/month depending on your provisioned RU/s setting.

## Burst Capacity

Provisioned throughput is evenly divided across physical partitions. If you have 1,000 RU/s and two partitions, each gets 500 RU/s. Exceed that on a single partition and you get a 429. That math can be punishing for workloads with small, occasional spikes.

**Burst capacity** smooths this out. Each physical partition accumulates up to **5 minutes of idle capacity**, which can be consumed at a burst rate of up to **3,000 RU/s**. A partition with 100 RU/s provisioned that's been idle for 5 minutes accumulates 30,000 RU of burst capacity, enough to handle 3,000 RU/s for 10 seconds. <!-- Source: throughput-request-units/burst-capacity/burst-capacity.md -->

<!-- Source: throughput-request-units/burst-capacity/burst-capacity.md -->

Key facts about burst capacity:

- **No additional charge.** It's free — you're just using capacity you already paid for but weren't consuming.
- **Only for partitions with < 3,000 RU/s provisioned.** If your partition already has 3,000+ RU/s, burst capacity doesn't apply.
- **Works with both manual and autoscale provisioned throughput.** Does not apply to serverless.
- **Not guaranteed.** Burst capacity is best-effort. Cosmos DB may use it for background maintenance tasks, and availability depends on system resources. Don't architect around it as a guaranteed safety net. <!-- Source: throughput-request-units/burst-capacity/burst-capacity.md -->

To enable burst capacity, navigate to the **Features** page in your Cosmos DB account and toggle it on. It takes 15–20 minutes to take effect. <!-- Source: throughput-request-units/burst-capacity/burst-capacity.md -->

> **Gotcha:** Before relying on burst capacity, evaluate whether your partition layout can be *merged* to permanently give more RU/s per partition. Burst is a short-term buffer, not a substitute for right-sizing your throughput. <!-- Source: throughput-request-units/burst-capacity/burst-capacity.md -->

## Throughput Buckets (Preview)

When multiple workloads share a container — say, your OLTP traffic and a nightly ETL job — resource contention is a real problem. The ETL job can consume all available throughput and starve your user-facing reads. **Throughput buckets** let you carve up a container's throughput into governed slices.

<!-- Source: throughput-request-units/throughput-buckets-preview/throughput-buckets.md -->

Each bucket has a **maximum throughput percentage**, capping the fraction of the container's total throughput that workload can consume. You can configure up to **five buckets per container**, each identified by an ID from 1 to 5. Requests not assigned to a bucket consume throughput without restrictions. <!-- Source: throughput-request-units/throughput-buckets-preview/throughput-buckets.md -->

Here's how you'd assign a request to a bucket in .NET:

```csharp
// ETL operations use Bucket 2, capped at 30% of container throughput
ItemRequestOptions etlOptions = new ItemRequestOptions { ThroughputBucket = 2 };
await container.UpsertItemAsync(item, partitionKey, etlOptions);
```

<!-- Source: throughput-request-units/throughput-buckets-preview/throughput-buckets.md -->

Or apply a bucket to *all* requests from a client:

```csharp
CosmosClient etlClient = new CosmosClientBuilder(endpoint, credential)
    .WithBulkExecution(true)
    .WithThroughputBucket(2) // All requests from this client use Bucket 2
    .Build();
```

<!-- Source: throughput-request-units/throughput-buckets-preview/throughput-buckets.md -->

A few things to know about throughput buckets:

- Throughput is **not reserved** for any bucket — it's shared. Buckets only set a *ceiling*, not a floor.
- Bucket configurations can be changed once every **10 minutes**. <!-- TODO: source needed for "Bucket configurations can be changed once every 10 minutes" -->
- **Not supported** for shared throughput databases or serverless accounts. <!-- Source: throughput-request-units/throughput-buckets-preview/throughput-buckets.md -->
- Requests assigned to a bucket **can't use burst capacity**. <!-- Source: throughput-request-units/throughput-buckets-preview/throughput-buckets.md -->
- This feature is in **preview**. You'll need to register via the Preview features page on your subscription in the Azure portal. <!-- Source: throughput-request-units/throughput-buckets-preview/throughput-buckets.md -->

Throughput buckets are most useful for ISVs running multi-tenant workloads, bulk ETL jobs that shouldn't starve production traffic, and change feed processors that should yield to user-facing operations.

## Scheduled Throughput Scaling

Autoscale handles reactive scaling beautifully, but sometimes you know *exactly* when your traffic will change. A retail site ramps up at 8 AM and dies at midnight. A dev/test database only needs throughput during business hours. Rather than paying for 24 hours of provisioned capacity, you can **scale on a schedule**.

<!-- Source: throughput-request-units/provisioned-throughput/scale-on-schedule.md -->

Microsoft provides a sample Azure Functions project for exactly this: the [Azure Cosmos DB Throughput Scheduler](https://github.com/Azure-Samples/azure-cosmos-throughput-scheduler). It uses two timer-triggered functions:

- **ScaleUpTrigger** — runs at 8 AM UTC, sets throughput to your daytime level.
- **ScaleDownTrigger** — runs at 6 PM UTC, drops throughput to a minimum.

The triggers execute a PowerShell script that calls the Azure Cosmos DB resource provider to update throughput for each resource listed in a `resources.json` file. You secure it using managed identity with the **Azure Cosmos DB Operator** RBAC role. <!-- Source: throughput-request-units/provisioned-throughput/scale-on-schedule.md -->

The schedules are defined in each function's `function.json` and use standard NCRONTAB expressions, so you can customize them to any pattern — weekday business hours, weekend reductions, holiday schedules.

> **Tip:** If you're already using autoscale, scheduled scaling can adjust the *autoscale max RU/s* on a schedule instead of switching to manual. This gives you the safety net of autoscale during business hours with a tighter max overnight.

## Limiting Total Account Throughput

One of the most common Cosmos DB cost surprises comes from runaway throughput provisioning — someone creates a new container at 10,000 RU/s, someone else bumps an existing one, and suddenly your monthly bill has doubled. **Total account throughput limits** let you set a governance cap.

<!-- Source: throughput-request-units/limit-total-account-throughput.md -->

When you set a limit, any operation that would push the account's total provisioned throughput beyond it is **blocked and fails explicitly**. This includes creating new databases or containers, increasing throughput on existing resources, and even adding new regions (since each region multiplies your throughput cost).

You can set this from the **Account Throughput** settings in the Azure portal. The options are:

- **Limit to free tier amount** (1,000 RU/s) — available on free tier accounts to guarantee zero throughput charges.
- **Custom limit** — any amount you choose, as long as it's not below your currently provisioned total.
- **No limit** — the default.

<!-- Source: throughput-request-units/limit-total-account-throughput.md -->

For autoscale resources, the **maximum RU/s** counts toward the limit — not the current scaled value. This is the conservative, correct behavior: it prevents autoscale from scaling up and busting your budget. <!-- Source: throughput-request-units/limit-total-account-throughput.md -->

Programmatically, set the `properties.capacity.totalThroughputLimit` property on your account resource via ARM templates, Bicep, or the resource provider API. Set it to `-1` to disable. <!-- Source: throughput-request-units/limit-total-account-throughput.md -->

> **Note:** This feature isn't available on serverless accounts (since serverless doesn't provision throughput). <!-- Source: throughput-request-units/limit-total-account-throughput.md -->

## Best Practices for Scaling Provisioned Throughput

Scaling RU/s isn't always instant. Understanding when it's fast and when it's slow saves you from unpleasant surprises during load spikes and migrations.

<!-- Source: throughput-request-units/scaling-provisioned-throughput-best-practices.md -->

### Instant vs. Asynchronous Scaling

- **Instant scale-up:** If your requested RU/s can be served by the current physical partition layout — meaning each partition stays at or below 10,000 RU/s — the change takes effect immediately. The maximum instant scale-up is `current physical partitions × 10,000 RU/s`.
- **Asynchronous scale-up:** If the request requires new partitions (splits), the operation takes **4–6 hours**. Cosmos DB splits existing partitions in the background until it has enough to serve the requested RU/s.
- **Scale-down** is always instant. No partitions need to be added or split.

<!-- Source: throughput-request-units/scaling-provisioned-throughput-best-practices.md -->

### Keeping Partitions Even During Scale-Up

When Cosmos DB splits partitions to handle higher throughput, it doesn't split them all — only enough to meet the new RU/s target. This can leave you with uneven data distribution: one unsplit partition holding 50% of the data, two new child partitions holding 25% each.

If your workload is evenly distributed (thanks to a good partition key — Chapter 5), you want *all* partitions to split. The trick: temporarily scale to a value that forces every partition to split (a power-of-2 multiple of your current partition count × 10,000), let the splits complete, then scale back down to your target.

For example, with 2 partitions at 20,000 RU/s, scaling to 30,000 splits only one partition (giving you 3). Instead, scale to 40,000 (forcing both to split, giving you 4), then drop to 30,000 — each partition gets 7,500 RU/s with even data distribution. <!-- Source: throughput-request-units/scaling-provisioned-throughput-best-practices.md -->

### Minimum Throughput Floors

You can't scale down to zero. The minimum depends on your configuration:

**Manual throughput minimum for a container:**
`MAX(400 RU/s, current storage in GB × 1, highest RU/s ever provisioned ÷ 100)`

**Autoscale max RU/s minimum for a container:**
`MAX(1,000, current storage in GB × 10, highest RU/s ever provisioned ÷ 10)`

<!-- Source: manage-your-account/enterprise-readiness/concepts-limits.md -->

That "highest RU/s ever provisioned" factor is the sneaky one. If you once scaled a container to 100,000 RU/s for a bulk import, you can never go below 1,000 RU/s manual (or 10,000 autoscale max) on that container — even after you've deleted the data. Plan your bulk imports accordingly.

## Changing Capacity Mode

Capacity mode (serverless vs. provisioned) is chosen at account creation, and the conversion rules are asymmetric:

- **Serverless → Provisioned:** Allowed, but **irreversible**. All containers are converted in place to manual provisioned throughput using the formula `number of partitions × 5,000 RU/s`. You can switch to autoscale afterward. <!-- Source: manage-your-account/how-to-change-capacity-mode.md -->
- **Provisioned → Serverless:** Not supported. If you need serverless, create a new account and migrate your data.

<!-- Source: manage-your-account/how-to-change-capacity-mode.md -->

Within provisioned throughput, you can switch between **manual and autoscale** freely on any database or container, at any time. The initial values are calculated automatically:

- Manual → Autoscale: initial max RU/s = `MAX(1,000, current manual RU/s, highest ever ÷ 10, storage GB × 10)`, rounded to the nearest 1,000. <!-- TODO: source needed for "Manual → Autoscale initial max RU/s formula" — originally cited autoscale-faq.md which is not in the mirror -->
- Autoscale → Manual: initial RU/s = current autoscale max RU/s. <!-- TODO: source needed for "Autoscale → Manual initial RU/s formula" — originally cited autoscale-faq.md which is not in the mirror -->

## Choosing the Right Capacity Model

Here's the decision framework, distilled:

| Factor | Manual | Autoscale |
|--------|--------|-----------|
| **Traffic** | Steady | Variable, spiky |
| **Utilization** | >66% of provisioned | <66%, unpredictable |
| **Regions** | Multiple | Multiple |
| **Throughput SLA** | Yes | Yes |
| **Billing** | Fixed per hour | Peak RU/s per hour |
| **Best for** | High-volume prod | Variable prod |

| Factor | Serverless |
|--------|------------|
| **Traffic** | Sporadic, long idle |
| **Utilization** | Low total volume |
| **Regions** | Single only |
| **Throughput SLA** | No (SLO only) |
| **Billing** | Per RU consumed |
| **Best for** | Dev/test, prototypes |

Use this table as a quick reference. For the step-by-step decision tree that puts these tradeoffs into action, jump to [Putting It All Together](#putting-it-all-together) at the end of the chapter.

## Cost Optimization Strategies

Cost optimization in Cosmos DB isn't a single knob — it's a portfolio of techniques applied together.

### Right-Size Your Throughput

The single biggest cost lever. Use the **Normalized RU Consumption** metric in Azure Monitor to see how much of your provisioned capacity you're actually using. If it's consistently below 50%, you're overpaying. Scale down, or switch to autoscale and let the system right-size for you. <!-- Source: throughput-request-units/how-to-choose-offer.md -->

### Use TTL to Clean Up Stale Data

Every gigabyte of stored data raises your minimum throughput floor (1 RU/s per GB for manual, 10 RU/s per GB for autoscale max). Expired data you're no longer querying is still costing you RUs. Set TTL on containers with transient data — session records, event logs, temporary caches — to automatically delete items and reduce both storage and minimum throughput. TTL is covered in depth in Chapter 6. <!-- Source: manage-your-account/enterprise-readiness/concepts-limits.md -->

### Trim Your Indexing Policy

Cosmos DB indexes every path by default, which consumes storage and adds RU cost to writes. If you're not querying on a property, exclude it from the index. An optimized indexing policy can significantly reduce write RUs — often 30% or more depending on how many paths you exclude and the shape of your documents — and shrink index storage substantially. <!-- TODO: source needed for "often 30% or more" indexing savings claim --> Chapter 9 covers indexing policies in detail.

### Prefer Point Reads Over Queries

A point read (by `id` + partition key) is always the cheapest operation — typically 1 RU for a 1 KB item. A query that returns the same item costs more because it goes through the query engine. Design your data model so that your most common access patterns are point reads (Chapter 4). This is covered extensively in Chapter 10.

### Use the Patch API for Partial Updates

Replacing an entire document when you only need to change one field wastes RUs proportional to the full document size. The Patch API (Chapter 6) lets you update specific properties at a fraction of the cost.

## Reserved Capacity

If you've committed to Cosmos DB for production, **reserved capacity** is the single largest discount available — up to **63% off** pay-as-you-go pricing. You commit to a 1-year or 3-year reservation of a specific RU/s quantity, paid upfront or monthly, and the discount is applied automatically to matching usage. <!-- Source: throughput-request-units/free-tier.md, overview/overview.md -->

Reserved capacity works with both manual and autoscale throughput. For autoscale in single-write-region accounts, the reservation discount is applied at a **1.5× ratio** — meaning you need to purchase 15,000 RU/s of reserved capacity to cover 10,000 autoscale RU/s. Multi-region write reserved capacity works the same for both manual and autoscale. <!-- TODO: source needed for "reserved capacity 1.5× ratio for autoscale" — originally cited autoscale-faq.md which is not in the mirror -->

Reserved capacity does **not** cover serverless consumption or burst capacity usage. <!-- TODO: source needed for "reserved capacity does not cover serverless consumption or burst capacity usage" — originally cited burst-capacity-faq.md which is not in the mirror -->

The decision is straightforward: if you're running a production workload on Cosmos DB that will exist for at least a year, buy reserved capacity. The 1-year reservation gives a meaningful discount; the 3-year reservation maximizes savings. The only risk is overcommitting — you'll pay for the reservation whether you use it or not.

## The Free Tier

Cosmos DB's **free tier** gives you **1,000 RU/s and 25 GB of storage** at no charge, for the lifetime of the account. Not a trial — *forever*. You get one free tier account per Azure subscription, and you must opt in at account creation (you can't add it later). <!-- Source: throughput-request-units/free-tier.md -->

Free tier works with both manual and autoscale throughput, single or multiple write regions. The 1,000 free RU/s is applied as a discount — any throughput or storage beyond the free amount is billed at regular rates. <!-- Source: throughput-request-units/free-tier.md -->

Some configurations that stay completely free:

- One database with 1,000 RU/s shared throughput
- Two containers: one at 400 RU/s, one at 600 RU/s
- A two-region account with a single container at 500 RU/s

<!-- Source: throughput-request-units/free-tier.md -->

If you also have an **Azure free account**, the discounts stack: 1,400 RU/s and 50 GB for the first 12 months (1,000 + 400 RU/s, 25 + 25 GB). After 12 months, the Azure free account portion expires but the Cosmos DB free tier continues indefinitely. <!-- Source: throughput-request-units/free-tier.md -->

To keep costs at zero, use the total account throughput limit (covered above) and set it to 1,000 RU/s. This prevents anyone from accidentally provisioning beyond the free tier. <!-- Source: throughput-request-units/limit-total-account-throughput.md -->

Chapter 3 covered free tier setup in the context of creating your first account. Here we've covered the cost mechanics.

## The Integrated Cache and Dedicated Gateway

Every cost optimization strategy so far reduces the number of RUs you provision or consume. The **integrated cache** takes a different approach: it serves repeated reads for **zero RUs**.

<!-- Source: develop-modern-applications/performance/integrated-cache/integrated-cache.md -->

The integrated cache is an in-memory LRU cache that lives inside a **dedicated gateway** — a compute layer you provision in front of your Cosmos DB account. When a point read or query hits the cache, it's served directly from memory. No RU charge. No backend hit. For read-heavy workloads with repeated access patterns, this can dramatically cut costs.

### How It Works

The integrated cache has two parts:

- **Item cache** — caches point reads (key/value lookups by `id` + partition key). Populated by writes, updates, deletes, and cache-miss reads. Two exclusions: `ReadMany` requests populate the *query* cache as a set, not the item cache as individual items; and requests in transactional batch or bulk mode don't populate the item cache at all. <!-- Source: develop-modern-applications/performance/integrated-cache/integrated-cache.md -->
- **Query cache** — caches query results (the full result set, keyed by query text). Populated on cache miss. Different parameter values or request options are cached separately. <!-- Source: develop-modern-applications/performance/integrated-cache/integrated-cache.md -->

Both caches share the same capacity and use **Least Recently Used (LRU) eviction**. Each dedicated gateway node has its own independent cache — data cached on one node isn't necessarily available on another. <!-- Source: develop-modern-applications/performance/integrated-cache/integrated-cache.md -->

### Setting Up the Dedicated Gateway

To use the integrated cache, you provision a dedicated gateway cluster. Choose a SKU and node count:

| SKU | Memory | ~Cache Size |
|-----|--------|-------------|
| D4s (4 vCPU) | 16 GB | ~8 GB |
| D8s (8 vCPU) | 32 GB | ~16 GB |
| D16s (16 vCPU) | 64 GB | ~32 GB |

<!-- Source: develop-modern-applications/performance/integrated-cache/dedicated-gateway.md -->

Approximately **50% of each node's memory** is available for the cache; the rest is used for metadata and request routing. For development, start with a single D4s node. For production, provision three or more nodes for high availability. <!-- Source: develop-modern-applications/performance/integrated-cache/dedicated-gateway.md -->

Your application connects to the dedicated gateway using a different endpoint — replace `documents.azure.com` with `sqlx.cosmos.azure.com` in your connection string — and must use **Gateway connectivity mode** (not Direct mode). Only requests routed through the dedicated gateway can hit the cache. <!-- Source: develop-modern-applications/performance/integrated-cache/how-to-configure-integrated-cache.md -->

```csharp
CosmosClient client = new(
    "https://your-account.sqlx.cosmos.azure.com",
    credential,
    new CosmosClientOptions { ConnectionMode = ConnectionMode.Gateway }
);
```

<!-- Source: develop-modern-applications/performance/integrated-cache/how-to-configure-integrated-cache.md -->

### MaxIntegratedCacheStaleness

The `MaxIntegratedCacheStaleness` property controls how old cached data can be before a request bypasses the cache and goes to the backend. The default is **5 minutes**. The minimum is 0 (always go to backend); the maximum is 10 years. <!-- Source: develop-modern-applications/performance/integrated-cache/integrated-cache.md -->

Set it at the request level:

```csharp
// Accept cached data up to 2 hours old
ItemRequestOptions options = new()
{
    DedicatedGatewayRequestOptions = new DedicatedGatewayRequestOptions
    {
        MaxIntegratedCacheStaleness = TimeSpan.FromHours(2)
    }
};

ItemResponse<Product> response = await container.ReadItemAsync<Product>(
    id, partitionKey, options);
```

The staleness window is enforced at *read time*, not write time. Setting a 2-hour staleness doesn't mean data is cached for 2 hours — it means a read request will accept data up to 2 hours old. If the cached entry is older than your staleness window, the cache goes to the backend and refreshes. <!-- Source: develop-modern-applications/performance/integrated-cache/integrated-cache.md -->

Different clients and different requests can use different staleness values. A user-facing API might set 30 seconds; a reporting dashboard might tolerate 10 minutes.

### Bypassing the Cache

Not every read benefits from caching. One-off lookups that won't repeat just consume cache space and evict data that *would* be reused. The **bypass integrated cache** request option lets you route specific requests through the dedicated gateway without populating or reading from the cache. <!-- Source: develop-modern-applications/performance/integrated-cache/integrated-cache.md -->

### Consistency Requirements

The integrated cache serves **read** requests only under Session or Eventual consistency. Reads at stronger levels — Consistent Prefix, Bounded Staleness, or Strong — bypass the cache entirely and are served from the backend with normal RU charges. However, write operations populate the cache regardless of consistency level. <!-- Source: develop-modern-applications/performance/integrated-cache/integrated-cache.md -->

This makes sense when you think about it: stronger consistency levels require reading from the backend to guarantee freshness, which is incompatible with serving potentially stale cached data. If your account default is Session (the most common setting), you're good.

### When the Integrated Cache Makes Sense vs. External Caching

The integrated cache is the right tool when:

- Your workload has **many repeated point reads on the same items** or **repeated queries with the same parameters**
- You want to reduce RU costs without changing application code beyond the connection string
- Your hot read set fits within the dedicated gateway's memory

It's *not* the right tool when:

- Your reads rarely repeat (each request fetches different data)
- You need caching for write-heavy workloads
- You need cross-region cache coherency (each region's gateway nodes have independent caches)
- You're reading the change feed (change feed requests don't use the cache)

For workloads that need more sophisticated caching — custom eviction policies, cross-region replication, pub/sub invalidation — an external cache like **Azure Cache for Redis** is the better choice. But the integrated cache has one killer advantage: it requires almost no code changes and zero infrastructure to manage beyond the dedicated gateway itself. Chapter 21 covers SDK-level performance tips and points back here for the cache decision.

<!-- Source: develop-modern-applications/performance/integrated-cache/integrated-cache.md, develop-modern-applications/performance/integrated-cache/dedicated-gateway.md -->

### Monitoring the Integrated Cache

Once you've deployed the dedicated gateway, keep an eye on three Azure Monitor metrics: <!-- Source: develop-modern-applications/performance/integrated-cache/integrated-cache.md -->

- **`IntegratedCacheItemHitRate`** and **`IntegratedCacheQueryHitRate`** — the percentage of point reads and queries served from the cache. If both are near zero, double-check that you're using the dedicated gateway connection string, Gateway mode, and Session or Eventual consistency. Values in the 0.7–0.8 range or higher mean the cache is earning its keep.
- **`IntegratedCacheEvictedEntriesSize`** — the volume of data evicted via LRU. If this is consistently high while hit rates are low, your dedicated gateway SKU is too small for your hot working set. Scale up before adding more nodes.

These metrics are aggregated across all dedicated gateway nodes — you can't break them down per node. Find them under **Metrics** in the Azure portal (not Metrics classic).

### Dedicated Gateway in Multi-Region Accounts

When you provision a dedicated gateway on a multi-region account, identical clusters are provisioned in **every region** automatically. A two-node D8s gateway on an account with East US and North Europe means four D8s nodes total (two per region). The dedicated gateway endpoint stays the same — routing is handled transparently. <!-- Source: develop-modern-applications/performance/integrated-cache/dedicated-gateway.md -->

The cost implication is obvious: multi-region accounts pay for gateway nodes in every region. Factor this into your ROI calculation — the gateway only saves money if the RU savings from cache hits exceed the gateway's compute cost.

## Putting It All Together

There's no universal "best" capacity model — there's the one that fits your workload. Here's the decision tree:

1. **Is this a dev/test, prototype, or very low-traffic workload?** → Serverless. Zero baseline cost, no planning needed.
2. **Is traffic variable, unpredictable, or spiky?** → Autoscale. Let the system handle scaling.
3. **Is traffic steady with >66% utilization of provisioned capacity?** → Manual provisioned. Cheapest per RU.
4. **Are you running production for 1+ years?** → Add reserved capacity on top of whatever model you're using.
5. **Is this a read-heavy workload with repeated access patterns?** → Evaluate the integrated cache.
6. **Do you have multiple workloads sharing a container?** → Consider throughput buckets.
7. **Do you have predictable on/off patterns?** → Add scheduled scaling.

The biggest mistake teams make is treating capacity model selection as a one-time decision at account creation. It's not. Your workload changes, your traffic grows, your understanding of access patterns sharpens. Revisit the decision quarterly. Use Azure Monitor's Normalized RU Consumption metric as your compass. And remember: the cheapest RU is the one you don't consume — so optimize your data model (Chapter 4), partition key (Chapter 5), indexing policy (Chapter 9), and query patterns (Chapter 10) before reaching for a bigger throughput number.

Chapter 12 takes us global — how multi-region distribution works, what it costs, and how it interacts with the capacity models you just learned.
