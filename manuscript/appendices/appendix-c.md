# Appendix C: Consistency Level Comparison Table

This is your tear-out card. Chapter 13 explains *why* each consistency level works the way it does. This appendix gives you the raw comparison so you can make decisions fast.

<!-- Primary source: high-availability/consistency/consistency-levels.md -->

## The Five Levels at a Glance

| Dimension | Strong | Bounded Staleness | Session | Consistent Prefix | Eventual |
|---|---|---|---|---|---|
| **Read guarantee** | Linearizable — always returns the most recent committed write | Reads lag by at most *K* versions or *T* seconds | Read-your-writes, write-follows-reads within a session token | No out-of-order reads for transactional batches; single-document writes see eventual consistency | May return stale or out-of-order data |
| **Write quorum** | Global Majority (all regions under normal conditions; dynamic quorum can reduce this with ≥ 3 regions) | Local Majority (3 of 4 replicas in the local region) | Local Majority | Local Majority | Local Majority |
| **Read quorum** | Local Minority (2 of 4 replicas) | Local Minority (2 of 4 replicas) | Single Replica (using session token) | Single Replica | Single Replica |
| **Read RU cost** | **2×** (minority quorum requires two replicas) | **2×** (minority quorum requires two replicas) | 1× | 1× | 1× |
| **Write RU cost** | 1× (same as all levels) | 1× | 1× | 1× | 1× |
| **Write latency** | 2 × RTT between farthest regions + 10 ms (p99). Blocked by default if regions span > 5,000 mi / 8,000 km. | < 10 ms at p99 | < 10 ms at p99 | < 10 ms at p99 | < 10 ms at p99 |
| **Read latency** | < 10 ms at p99 | < 10 ms at p99 | < 10 ms at p99 | < 10 ms at p99 | < 10 ms at p99 |
| **Multi-region writes** | **Not supported** | Supported (but an anti-pattern — see note below) | Supported | Supported | Supported |
| **Staleness bound** | None (always current) | Configurable: *K* versions or *T* time, whichever is reached first | None (consistent within session) | None (ordering preserved, but staleness unbounded) | None (no guarantees) |
| **RPO (multi-region, single write region)** | 0 | *K* & *T* | < 15 minutes | < 15 minutes | < 15 minutes |
| **Default level?** | No | No | **Yes** | No | No |

<!-- Source for quorum, RU cost, and RPO tables: high-availability/consistency/consistency-levels.md -->

## Bounded Staleness Parameters

Bounded staleness lets you configure how far reads can lag behind writes. The staleness window is defined by two parameters — whichever threshold is reached first applies.

| Parameter | Single-region account minimum | Multi-region account minimum |
|---|---|---|
| *K* (versions / updates) | 10 | 100,000 |
| *T* (time interval) | 5 seconds | 300 seconds (5 minutes) |

<!-- Source: high-availability/consistency/consistency-levels.md, "For a single-region account, the minimum value of K and T is 10 write operations or 5 seconds. For multi-region accounts, the minimum value of K and T is 100,000 write operations or 300 seconds." -->

**A note on multi-region writes with Bounded Staleness:** The docs are explicit — this is an anti-pattern. Bounded Staleness in a multi-write account creates a dependency on cross-region replication lag, which defeats the purpose of writing locally. If you're using multi-region writes, Session consistency is almost certainly what you want.

## Availability During Regional Outages

How each level behaves when a region goes down depends on your account topology.

| Scenario | Strong | Bounded Staleness | Session / Consistent Prefix / Eventual |
|---|---|---|---|
| **Read region outage (≥ 3 regions)** | SDK reroutes reads to healthy regions; dynamic quorum maintains consistency | SDK reroutes reads; writes throttled if staleness window is exceeded | SDK reroutes reads to next preferred region — no disruption |
| **Read region outage (2 regions only)** | **Write availability is also lost** — quorum can't be achieved with one remaining region. Mitigation: take the affected region offline. | Writes throttled if staleness exceeds the configured bound | SDK reroutes reads — no disruption |
| **Write region outage (single-write account)** | Requires failover (service-managed or manual region offline operation) | Requires failover | Requires failover |
| **Any region outage (multi-write account)** | N/A — Strong not supported | SDK routes to healthy regions automatically | SDK routes to healthy regions automatically |

<!-- Source: high-availability/disaster-recovery-guidance.md, "Strong Consistency - For accounts with only two regions, a read region outage impacts write availability..." and "Bounded Staleness Consistency - When the read region has an outage and the staleness window is exceeded, write operations for the partitions in the affected region are also impacted." -->

**Dynamic quorum (Strong consistency only):** With three or more regions, Cosmos DB can remove unresponsive regions from the quorum set to maintain strong consistency and write availability. The number of regions that can be removed depends on total region count — for example, one region can be removed from a three- or four-region account, and up to two from a five-region account. Regions removed from the quorum can't serve reads until they're readded.
<!-- Source: high-availability/consistency/consistency-levels.md -->

## Decision Quick Reference

**Pick Strong when** you need linearizable reads and can accept higher write latency and 2× read RU cost. Financial transactions, inventory systems with zero-tolerance for stale reads, leader election. Single-write-region accounts only.

**Pick Bounded Staleness when** you need near-strong consistency across regions but can tolerate a controlled lag. Good for single-write-region accounts where you want a guaranteed upper bound on how stale a secondary region's reads can be.

**Pick Session when** you need read-your-writes guarantees within a user's session — and you do, for most applications. This is the default for a reason. Shopping carts, user profiles, any scenario where a user writes something and immediately reads it back.

**Pick Consistent Prefix when** ordering matters but you don't need read-your-writes. Dashboards displaying a timeline of events, social feeds — cases where seeing data in the right order is more important than seeing the absolute latest data.

**Pick Eventual when** you want the lowest latency and lowest cost, and can tolerate stale or out-of-order reads. Like counters, recommendation scores, or non-threaded comments where "close enough" is fine.

---

*For the full explanation of each consistency level — mental models, code examples, and production guidance — see Chapter 13. For how consistency interacts with multi-region architecture and failover, see Chapter 12.*
