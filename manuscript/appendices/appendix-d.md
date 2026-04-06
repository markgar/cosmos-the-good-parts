# Appendix D: Capacity and Pricing Cheat Sheet

This appendix is a tear-out reference for capacity planning and cost estimation. For the reasoning behind these numbers, see Chapter 10 (Request Units In Depth) and Chapter 11 (Provisioned Throughput, Autoscale, and Serverless). For current pricing, always check the [Azure Cosmos DB pricing page](https://azure.microsoft.com/pricing/details/cosmos-db/) and the [Capacity Calculator](https://cosmos.azure.com/capacitycalculator/) — the numbers below are structural, not dollar amounts.

## RU Cost per Operation Type

<!-- Source: throughput-request-units/request-units.md, develop-modern-applications/performance/key-value-store-cost.md -->

| Operation | ≈ RU Cost (1 KB item) | Notes |
|---|---|---|
| **Point read** (by id + partition key) | 1 RU | The baseline. All other costs are relative to this. |
| **Write** (insert, replace, upsert) | ≈ 5 RUs (indexing off) | With default indexing (all properties), expect higher — roughly 5–7+ RUs depending on property count and index breadth. |
| **Delete** | Same as write | Deletes are writes internally. |
| **Query** (single partition) | Varies | Depends on result count, predicates, functions, and data scanned. A simple `SELECT *` returning one item might cost 2–3 RUs; a cross-partition fan-out or a query touching thousands of items costs far more. |
| **Stored procedure / trigger** | Varies | Billed for the operations performed inside the sproc, just like individual operations would be. |

**Key scaling rules:**

- **Item size scales linearly.** A 100 KB point read costs ≈ 10 RUs. A 100 KB write costs ≈ 50 RUs (indexing off).
- **Strong and bounded staleness consistency cost ≈ 2× for reads** compared to session, consistent prefix, or eventual consistency. Writes are unaffected by consistency level.
- **Fewer indexed properties = cheaper writes.** Excluding unused paths from your indexing policy directly reduces write RU cost.
- **Every operation returns its RU charge** in the response header (`x-ms-request-charge`). Measure, don't guess.

## Capacity Model Comparison

<!-- Sources: throughput-request-units/set-throughput.md, throughput-request-units/serverless/serverless.md, throughput-request-units/autoscale-throughput/provision-throughput-autoscale.md, manage-your-account/enterprise-readiness/concepts-limits.md -->

| | **Provisioned (Manual)** | **Autoscale** | **Serverless** |
|---|---|---|---|
| **How it works** | You set a fixed RU/s value. That capacity is always available. | You set a max RU/s (`Tmax`). System scales between 10%–100% of `Tmax` based on demand. | No provisioning. You consume RUs on demand and pay per RU consumed. |
| **Minimum throughput** | 400 RU/s per container; 400 RU/s per shared-throughput database (first 25 containers) | Max of 1,000 RU/s (scales 100–1,000 RU/s) per container or shared database | None — no throughput to configure |
| **Maximum throughput** | 1,000,000 RU/s per container or database (increase via support ticket) | Unlimited max RU/s (set in increments of 1,000 RU/s) | 5,000 RU/s per physical partition; total scales with partition count |
| **Billing unit** | Per-hour, at the provisioned RU/s (regardless of actual consumption) | Per-hour, at the highest RU/s the system scaled to during that hour | Per RU consumed |
| **Autoscale rate premium** | — | 1.5× the manual rate per 100 RU/s (single-write-region accounts) | — |
| **Geo-distribution** | Unlimited regions | Unlimited regions | Single region only |
| **SLA-backed** | Yes — latency, throughput, availability, consistency | Yes — same SLAs as manual provisioned | Availability SLA with AZ; latency targets are SLOs, not SLAs |
| **Best for** | Steady, predictable workloads with ≥ 66% sustained utilization | Variable or spiky workloads; workloads where you'd rather not manage scaling | Dev/test, prototyping, low-traffic or bursty apps with long idle periods |

## Free Tier

<!-- Source: throughput-request-units/free-tier.md -->

| Detail | Value |
|---|---|
| **Free allowance** | 1,000 RU/s throughput + 25 GB storage |
| **Duration** | Lifetime of the account (not a trial) |
| **Limit** | One free-tier account per Azure subscription |
| **How it's applied** | As a billing discount — usage beyond 1,000 RU/s and 25 GB is billed at standard rates |
| **Compatible modes** | Provisioned (manual), autoscale, single-region, multi-region |
| **Not compatible with** | Serverless accounts |
| **Opt-in** | Must be selected at account creation — cannot be enabled later |

> **Tip:** If you also have an Azure free account, the discounts stack for the first 12 months: 1,400 RU/s and 50 GB combined.

## Reserved Capacity

<!-- Source: throughput-request-units/free-tier.md, overview/overview.md -->

| Detail | Value |
|---|---|
| **Discount** | Up to 63% off standard provisioned throughput pricing |
| **Commitment terms** | 1-year or 3-year reservation |
| **Applies to** | Provisioned throughput (manual and autoscale) |
| **Scope** | Applied at the billing level — not tied to a specific account or container |
| **Autoscale note** | For single-write-region autoscale, reserved capacity is applied at a 1.5× ratio (e.g., reserve 15,000 RU/s to cover 10,000 autoscale RU/s) |

Reserved capacity makes sense when you have a stable baseline of provisioned throughput you're confident you'll sustain for a year or more. Chapter 11 covers when to commit and when to stay on-demand.

## Key Billing Facts

<!-- Sources: throughput-request-units/how-to-choose-offer.md, throughput-request-units/request-units.md, throughput-request-units/autoscale-throughput/provision-throughput-autoscale.md -->

**Provisioned (manual):**
- Billed at the **highest RU/s provisioned in each clock hour**. If you scale up from 1,000 to 10,000 and back down within one hour, you pay for 10,000 for that hour.
- Increments of 100 RU/s.

**Autoscale:**
- Billed at the **highest RU/s the system scaled to** in each hour — not the max you configured, but the actual peak reached.
- Minimum bill per hour is 10% of your configured max (`0.1 × Tmax`).
- The per-RU/s rate is 1.5× the manual rate for single-write-region accounts. For multi-region write accounts, the autoscale and manual rates are the same.

**Serverless:**
- Billed per RU consumed (no idle cost beyond storage).
- Storage billed per GB-month, same as other modes.

**Multi-region (all modes):**
- Throughput cost is multiplied by the number of write regions. If you have 3 regions with multi-region writes enabled, you pay 3× the single-region throughput cost.
- With single-write + multiple read regions, each region still provisions the full RU/s, so total cost = RU/s × number of regions.
- Storage is billed per region as well.

**Storage (all modes):**
- Billed per GB-month for data + index storage. The rate is the same across provisioned, autoscale, and serverless.

> **Important:** Prices change. Everything above describes *how* billing works, not *what* it costs. For current rates, use the [Azure pricing calculator](https://azure.microsoft.com/pricing/calculator/) or the [Cosmos DB Capacity Calculator](https://cosmos.azure.com/capacitycalculator/).
