# Outline Audit: Gaps & Repetition

---

## Missed Topics (in docs, not in outline)

### Worth adding

| Topic | Doc file | Suggested chapter |
|---|---|---|
| **Cost optimization guide** — dedicated doc on optimizing Cosmos DB spend (reserved capacity, right-sizing, TTL cleanup) | `manage-your-account\optimize-costs.md` | Ch10 or sidebar in Ch9 |
| **Scheduled throughput scaling** — Azure Functions timer to scale RU/s on a schedule (nights/weekends) | `throughput-(request-units)\provisioned-throughput\scale-on-schedule.md` | Ch10 (autoscale section) |
| **Limit total account throughput** — governance feature to cap max RU/s across an account | `throughput-(request-units)\limit-total-account-throughput.md` | Ch10 or Ch25 (governance) |
| **Best practices for scaling provisioned throughput** | `throughput-(request-units)\scaling-provisioned-throughput-best-practices.md` | Ch10 or Ch26 |
| **In-account restore (same-account PITR)** — restore without creating a new account | `manage-your-account\...\restore-in-the-same-account\` | Ch18 (only mentions restore-to-new-account today) |
| **Semantic cache** — Cosmos DB as an LLM semantic cache | `build-ai-applications\learn-core-ai-concepts\gen-ai-semantic-cache.md` | Ch24 |
| **SRE Agent** — Azure Site Reliability Engineering agent for Cosmos DB | `build-ai-applications\ai-tools\site-reliability-engineering-agent.md` | Ch24 (AI tools) |
| **Reverse ETL with Fabric Mirroring** — writing analytical results back to Cosmos DB | `analytics-with-microsoft-fabric\...\reverse-extract-transform-load.md` | Ch21 (Fabric section) |
| **Multi-tenant vector search** — combining tenancy isolation with vector search | `build-ai-applications\learn-core-ai-concepts\nosql-multi-tenancy-vector-search.md` | Ch24 or Ch25 |
| **CORS configuration** | `create-secure-solutions\how-to-configure-cross-origin-resource-sharing.md` | Ch16 (network security) |
| **Large partition keys** — using PK values up to 2 KB | `develop-modern-applications\...\large-partition-keys.md` | Ch5 |
| **VS Code extension** for Cosmos DB | `develop-modern-applications\visual-studio-code-extension.md` | Ch3 (tooling) |
| **Real-world modeling walk-throughs** — IoT partitioning, e-commerce model | `model-data-for-partitioning\real-world-examples\` | Ch5 or Ch6 |

### Lower priority (reference-weight, not narrative)

| Topic | Doc file | Notes |
|---|---|---|
| Network bandwidth | `manage-your-account\network-bandwidth.md` | Callout in Ch26 at most |
| ODBC driver | `integrate-with-azure-services\odbc-driver.md` | Footnote in Ch21 |
| Migration partners | `resources\partners-migration.md` | Appendix at best |
| Preview features access | `manage-your-account\access-previews.md` | Quick note in Ch3 |
| GitHub Copilot best practices for Cosmos DB | `develop-modern-applications\github-copilot-...-best-practices.md` | Nice-to-have in Ch19/Ch20 |

---

## Repetition in the Outline

### 🔴 Same topic taught in multiple chapters — pick one home

| Topic | Appearances | Recommendation |
|---|---|---|
| **Optimistic concurrency / ETags** | Ch6, Ch13, Ch15 | Teach once in **Ch15** (transactions). Ch6 and Ch13 cross-reference only. |
| **Resilient SDK applications** | Ch12 ("retry strategies, circuit breakers, preferred regions") and Ch20 ("preferred regions, availability strategy, custom retry") — nearly identical wording | Pick **Ch20** (SDKs) as the home. Ch12 cross-references. |
| **Cross-partition queries** | Ch5 ("when unavoidable, how to tame them") and Ch7 ("understanding their cost") | Teach mechanics in **Ch7**. Ch5 warns briefly and points to Ch7. |
| **Query Advisor** | Ch7 ("built-in recommendations") and Ch26 ("using Query Advisor to improve queries") | Teach in **Ch7**. Ch26 references it within the tuning loop. |
| **Full-text search indexing policy** | Ch8 and Ch24 both list it | **Ch8** owns indexing policies. Ch24 references Ch8. |

### 🟡 Minor overlap — tighten with cross-references

| Topic | Appearances | Recommendation |
|---|---|---|
| **Emulator** | Ch2 (mention), Ch3 (setup), Ch23 (testing) | Cut Ch2's bullet or reduce to "set up in Chapter 3." |
| **Physical vs. logical partitions** | Ch2 (explained) and Ch5 (explained deeper) | Ch2 should introduce briefly and forward-ref Ch5. |
| **OpenTelemetry** | Ch17 (consuming telemetry) and Ch20 (SDK instrumentation) | Different angles — add explicit cross-references so they don't re-explain each other. |
| **Integrated cache** | Ch10 (detailed) and Ch20 (perf tip) | Fine. Ch20 should say "see Chapter 10" not re-explain. |
