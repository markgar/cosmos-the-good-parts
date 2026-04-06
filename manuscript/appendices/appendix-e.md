# Appendix E: Service Limits and Quotas Quick Reference

Every architecture hits a ceiling eventually. This appendix puts all the important ceilings in one place so you can find them before your application does. Bookmark this page — you'll come back to it.

> **Note:** Azure Cosmos DB limits evolve. The numbers here were verified against the official documentation at time of writing, but always confirm against [the current limits page](https://learn.microsoft.com/en-us/azure/cosmos-db/concepts-limits) before making a design decision you can't easily reverse.

<!-- Primary source: manage-your-account/enterprise-readiness/concepts-limits.md -->

## Per-Item Limits

These are the constraints on individual documents (items) stored in a container. You'll encounter these most often when designing your document schema (Chapter 4) or choosing partition keys (Chapter 5).

| Resource | Limit | Notes |
| --- | --- | --- |
| Maximum item size | 2 MB | UTF-8 length of the JSON representation. This is a hard wall — no support ticket will raise it for the NoSQL API. |
| Maximum partition key value length | 2,048 bytes | 101 bytes if the large partition key feature isn't enabled. All new containers created via current SDKs enable large keys by default. |
| Maximum `id` value length | 1,023 bytes | Not 255 — that limit applies to database and container *names*. |
| Maximum nesting depth | 128 levels | Embedded objects and arrays combined. If you're anywhere near this, rethink your schema. |
| Maximum properties per item | No hard limit | Constrained only by the 2 MB total item size. |
| Maximum string property value length | No hard limit | Again, bounded by the 2 MB item size ceiling. |
| Maximum numeric precision | IEEE 754 double-precision (64-bit) | Numbers beyond this precision will lose fidelity during round-trips. |
| Allowed `id` characters | All Unicode except `/` and `\` | The service technically accepts most characters, but the SDKs and connectors (ADF, Spark, Kafka) have known issues with non-ASCII characters. Stick to alphanumeric ASCII or Base64-encode if you must use special characters. |

<!-- Source: manage-your-account/enterprise-readiness/concepts-limits.md, "Per-item limits" section -->

## Per-Container Limits

Containers are where your data lives. These limits shape how much throughput you can provision and how you configure stored procedures and unique keys. See Chapter 2 for the resource model and Chapter 11 for throughput modes.

| Resource | Limit | Notes |
| --- | --- | --- |
| Maximum RU/s (dedicated throughput) | 1,000,000 RU/s | Can be increased via Azure support ticket. |
| Maximum RU/s per physical partition | 10,000 RU/s | This is the single-partition throughput ceiling. Hot partitions hit this first. |
| Maximum logical partition size | 20 GB | The single most important limit to design around. Use hierarchical partition keys to exceed this for top-level keys. A temporary increase is available via support ticket, but SLA guarantees are voided. See Chapter 5. |
| Maximum storage per container | Unlimited | Scales horizontally across physical partitions. |
| Maximum number of distinct logical partition keys | Unlimited | — |
| Maximum database or container name length | 255 characters | — |
| Maximum stored procedures per container | 100 | Can be increased via support ticket. |
| Maximum UDFs per container | 50 | Can be increased via support ticket. |
| Maximum unique key constraints per container | 10 | Can be increased via support ticket. |
| Maximum paths per unique key constraint | 16 | Can be increased via support ticket. |
| Maximum TTL value | 2,147,483,647 seconds | ~68 years. Effectively unlimited for practical purposes. |

<!-- Source: manage-your-account/enterprise-readiness/concepts-limits.md, "Per-container limits" and "Provisioned throughput" sections -->

## Per-Database Limits (Shared Throughput)

When you provision throughput at the database level, all containers in that database share the RU/s pool. This is covered in depth in Chapter 11.

| Resource | Limit | Notes |
| --- | --- | --- |
| Maximum RU/s (shared throughput) | 1,000,000 RU/s | Can be increased via support ticket. |
| Maximum containers per shared-throughput database | 25 | Beyond 25, the minimum RU/s increases by 100 RU/s per additional container (manual) or 1,000 RU/s (autoscale). |
| Minimum RU/s — manual throughput | 400 RU/s | For the first 25 containers. Formula: `MAX(400, storage_GB × 1, highest_ever_RUs / 100, 400 + MAX(containers − 25, 0) × 100)`. |
| Minimum max RU/s — autoscale | 1,000 RU/s | For the first 25 containers. Formula: `MAX(1000, storage_GB × 10, highest_ever_RUs / 10, 1000 + MAX(containers − 25, 0) × 1000)`. |

## Minimum Throughput (Dedicated Container)

These formulas determine the floor for a container with its own provisioned throughput. They matter when you try to scale *down* and the portal won't let you go lower.

| Mode | Minimum RU/s | Formula |
| --- | --- | --- |
| Manual throughput | 400 RU/s | `MAX(400, storage_GB × 1, highest_ever_RUs / 100)` |
| Autoscale | 1,000 RU/s (max RU/s) | `MAX(1000, storage_GB × 10, highest_ever_RUs / 10)` |

<!-- Source: manage-your-account/enterprise-readiness/concepts-limits.md, "Minimum throughput limits" section -->

The "highest RU/s ever provisioned" component is the one that surprises people. If you once cranked a container to 50,000 RU/s during a migration, your minimum manual throughput is permanently 500 RU/s for that container — even after you delete all the data. The only escape is to create a new container.

## Autoscale Limits

Autoscale adds its own layer of constraints on top of the base provisioned throughput limits. Chapter 11 covers when autoscale is the right choice.

| Resource | Limit | Notes |
| --- | --- | --- |
| Maximum RU/s | User-configured `Tmax` | The ceiling you set. The system scales between `0.1 × Tmax` and `Tmax`. |
| Minimum RU/s the system scales to | `0.1 × Tmax` | You're billed for at least this much per hour, even at zero traffic. |
| Minimum `Tmax` for a container | 1,000 RU/s | Increases based on storage and highest-ever provisioned RU/s. |
| Minimum `Tmax` for a shared database | 1,000 RU/s | Plus 1,000 RU/s for each container beyond 25. |

<!-- Source: manage-your-account/enterprise-readiness/concepts-limits.md, "Limits for autoscale provisioned throughput" section -->

## Serverless Limits

Serverless is a different account type — you pick it at account creation and can't switch later. See Chapter 11 for the tradeoff analysis.

| Resource | Limit | Notes |
| --- | --- | --- |
| Maximum throughput per physical partition | 5,000 RU/s | Total container throughput = partitions × 5,000. Scales linearly as data grows across partitions. |
| Maximum logical partition size | 20 GB | Same as provisioned throughput. |
| Maximum storage per container | Unlimited | — |
| Maximum databases and containers per account | 500 | Same as provisioned accounts. |
| Maximum regions | 1 | Single region only. You cannot add regions after account creation. |
| Shared throughput databases | Not supported | Creating one returns an error. |
| Availability SLA | Aligned with single-region writes | SLA with availability zones applies in supported regions. |

<!-- Source: manage-your-account/enterprise-readiness/concepts-limits.md "Serverless" section; throughput-request-units/serverless/serverless.md; throughput-request-units/serverless/serverless-performance.md -->

## Per-Request Limits

These limits apply to individual operations — reads, writes, queries, stored procedure executions. You'll feel these in your application code. Stored procedures and server-side programming are covered in Chapter 14.

| Resource | Limit | Notes |
| --- | --- | --- |
| Maximum execution time (single operation) | 5 seconds | Applies to stored procedure execution *and* a single query page retrieval. |
| Maximum request size | 2 MB | For CRUD operations and stored procedure input. |
| Maximum response size (paginated query) | 4 MB per page | The SDK handles continuation tokens automatically — a query can return unlimited total data across pages. |
| Maximum operations in a transactional batch | 100 | All operations must target the same logical partition key. |

<!-- Source: manage-your-account/enterprise-readiness/concepts-limits.md, "Per-request limits" section -->

There's no hard limit on total query duration across pages. When a single page hits the 5-second timeout or the 4 MB response cap, Cosmos DB returns what it has plus a continuation token. Your SDK picks up where it left off.

## SQL Query Limits

These constrain the query *language* itself, not the execution engine. Chapter 9 covers indexing policies that affect query performance.

| Resource | Limit | Notes |
| --- | --- | --- |
| Maximum query text length | 512 KB | If your query is this long, you have other problems. |
| Maximum `JOIN` clauses per query | 10 | Can be increased via support ticket. These are intra-document joins, not cross-document. |
| Maximum UDFs per query | 10 | Can be increased via support ticket. |
| Maximum points per polygon (geospatial) | 4,096 | — |

## Indexing Limits

Your indexing policy determines which paths are indexed and how. Chapter 9 is the deep dive.

| Resource | Limit | Notes |
| --- | --- | --- |
| Maximum explicitly included paths | 1,500 | Can be increased via support ticket. |
| Maximum explicitly excluded paths | 1,500 | Can be increased via support ticket. |
| Maximum properties in a composite index | 8 | Each composite index can reference up to 8 property paths. |
| Maximum composite indexes per container | 100 | — |

<!-- Source: manage-your-account/enterprise-readiness/concepts-limits.md, "SQL query limits" section -->

## Control Plane Limits

The control plane manages account metadata — creating databases, updating throughput, listing containers. It has its own throughput budget that you can't increase, and it's surprisingly easy to exhaust with aggressive automation. These are per-account, per-5-minute-window unless noted.

### Resource Limits

| Resource | Limit | Notes |
| --- | --- | --- |
| Maximum accounts per subscription | 250 | Can be increased to 1,000 via support ticket. |
| Maximum databases and containers per account | 500 | Cannot be increased. The count includes both databases and containers combined (e.g., 1 database + 499 containers). |
| Maximum throughput for metadata operations | 240 RU/s | This is the internal budget for control plane metadata. Not user-configurable. |

### Request Rate Limits (per 5-minute window)

| Operation | Limit |
| --- | --- |
| List or Get keys | 500 |
| Create database or container | 500 |
| Get or List database or container | 500 |
| Update provisioned throughput | 25 |
| Regional failover | 10 per hour (single-region write accounts only) |
| All other operations (PUT, POST, PATCH, DELETE, GET) | 500 |

The throughput-update limit of 25 per 5 minutes is the one that bites automated scaling scripts. If you're programmatically adjusting throughput, batch your changes and add backoff logic.

> **Tip:** Use a singleton SDK client, and cache database and container references for the lifetime of that client instance. Every time you enumerate databases or containers, you're spending control plane budget.

<!-- Source: manage-your-account/enterprise-readiness/concepts-limits.md, "Control plane" section -->

## Per-Account Role-Based Access Control

| Resource | Limit | Notes |
| --- | --- | --- |
| Maximum custom role definitions (data plane RBAC) | 100 | — |
| Maximum role assignments (data plane RBAC) | 2,000 | — |

## Authorization Token Limits

| Resource | Limit | Notes |
| --- | --- | --- |
| Maximum primary token expiry time | 15 minutes | — |
| Minimum resource token expiry time | 10 minutes | — |
| Maximum resource token expiry time | 24 hours | Can be increased via support ticket. |
| Maximum clock skew for token authorization | 15 minutes | Keep your clocks synced. |

<!-- Source: manage-your-account/enterprise-readiness/concepts-limits.md, "Role-based access control" and "Per-request limits" sections -->

## Free Tier Limits

The free tier is a lifetime discount on a single provisioned-throughput account — not a separate SKU. Chapter 11 covers how it fits into the pricing picture.

| Resource | Limit | Notes |
| --- | --- | --- |
| Free tier accounts per Azure subscription | 1 | You must opt in at account creation. Can't be enabled after the fact. |
| Free RU/s allowance | 1,000 RU/s | Usage beyond this is billed at standard rates. |
| Free storage allowance | 25 GB | Usage beyond this is billed at standard rates. |
| Maximum containers in a shared-throughput database | 25 | Same as the standard shared-throughput limit. |
| Duration | Lifetime of the account | No expiration. |
| Serverless support | Not available | Free tier only applies to provisioned throughput accounts. |
| Regions | Single or multi-region | Free tier works with all provisioned throughput features, including global distribution. |

<!-- Source: manage-your-account/enterprise-readiness/concepts-limits.md "Azure Cosmos DB free tier account limits"; throughput-request-units/free-tier.md -->

> **Tip:** If you create a free-tier Cosmos DB account inside an Azure free account subscription, you get 1,400 RU/s and 50 GB free for the first 12 months (the Azure free account adds 400 RU/s and 25 GB on top of the Cosmos DB free tier). After 12 months, the Cosmos DB free tier discount continues indefinitely.

<!-- Source: throughput-request-units/free-tier.md -->

## Limits That Can Be Increased

Several limits can be raised by filing an Azure support ticket. Here's the consolidated list:

| Limit | Default | Increase via support ticket? |
| --- | --- | --- |
| Maximum RU/s per container or database | 1,000,000 | ✅ Yes |
| Maximum accounts per subscription | 250 | ✅ Yes (up to 1,000) |
| Maximum stored procedures per container | 100 | ✅ Yes |
| Maximum UDFs per container | 50 | ✅ Yes |
| Maximum unique key constraints per container | 10 | ✅ Yes |
| Maximum paths per unique key constraint | 16 | ✅ Yes |
| Maximum `JOIN` clauses per query | 10 | ✅ Yes |
| Maximum UDFs per query | 10 | ✅ Yes |
| Maximum included/excluded index paths | 1,500 | ✅ Yes |
| Maximum resource token expiry | 24 hours | ✅ Yes |
| Logical partition size (temporary) | 20 GB | ⚠️ Temporary increase only — SLA voided |
| Maximum databases + containers per account | 500 | ❌ No |
