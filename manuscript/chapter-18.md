# Chapter 18: Monitoring, Diagnostics, and Alerting

You shipped your Cosmos DB application to production. The partition key is well-chosen, the indexing policy is tuned, the consistency level is right for your workload. Congratulations — now your job changes. The question is no longer "does this work?" but "how do I know when it stops working, and why?"

Monitoring a managed database is different from monitoring a VM-hosted one. You don't have access to CPU counters, disk IOPS, or memory pressure on the nodes running your data. Instead, Cosmos DB surfaces a curated set of metrics and logs through **Azure Monitor** — the same platform that monitors every other Azure service. Your job is to know which metrics matter, how to set up alerts before your users feel pain, and how to dig into diagnostic logs when something goes sideways.

This chapter is the canonical reference for all of that: the metrics, the alerts, the diagnostic log tables, the KQL queries that tell you exactly which query is eating your budget, and the Insights workbook that gives you a heads-up display for your entire account.

## Azure Monitor Integration for Cosmos DB

Azure Monitor is the backbone of Cosmos DB observability. Every Cosmos DB account automatically emits **platform metrics** — no configuration required. These metrics flow into the Azure Monitor time-series database and are available in Metrics Explorer, dashboards, and alert rules the moment your account exists. <!-- Source: monitor.md -->

The key thing to understand is the split between **metrics** and **logs**:

- **Metrics** are lightweight, numeric time-series data (RU consumption, latency, request counts). They're collected automatically at 1-minute granularity by default and retained in the Azure Monitor metrics store. They're great for dashboards, alerts, and trend analysis.
- **Resource logs** (diagnostic logs) are detailed, per-request records of data plane operations — every read, write, and query your application makes. These are *not* collected by default. You must create a **diagnostic setting** to route them to a destination (Log Analytics workspace, Storage account, or Event Hubs) before they start flowing.

<!-- Source: monitor.md -->

That distinction trips people up. Metrics give you the "what" — your container is throttling, latency spiked at 2 AM. Logs give you the "why" — the specific queries, the specific partition keys, the specific operations that caused the spike. You need both.

### Setting Up Diagnostic Settings

To start collecting resource logs, navigate to your Cosmos DB account in the Azure portal, open **Monitoring > Diagnostic settings**, and click **Add diagnostic setting**. You'll choose which log categories to enable and where to send them.

The log categories you care about for the NoSQL API are:

| Category | Log Analytics Table | What It Captures | Enable For |
|----------|-------------------|-----------------|------------|
| **DataPlaneRequests** | `CDBDataPlaneRequests` | Every data plane operation (reads, writes, queries) with RU charge, duration, status code, partition ID | Troubleshooting sessions — detailed but expensive at scale |
| **QueryRuntimeStatistics** | `CDBQueryRuntimeStatistics` | Query text and execution statistics (requires full-text query to be enabled for unobfuscated SQL) | Identifying expensive queries by RU charge and text |
| **PartitionKeyRUConsumption** | `CDBPartitionKeyRUConsumption` | RU consumption broken down by logical and physical partition — your weapon for finding hot partitions | Always-on for any workload where hot partitions are a risk |
| **PartitionKeyStatistics** | `CDBPartitionKeyStatistics` | Storage consumption by logical partition key. Statistics are approximate (based on sub-sampling) and partition keys below 1 GB may not appear | Capacity planning — tracking large partition growth toward the 20 GB limit |
| **ControlPlaneRequests** | `CDBControlPlaneRequests` | Account management operations: region changes, failovers, key rotations, throughput updates | Always-on — low volume, essential audit trail |
| **DataPlaneRequests5M** | `CDBDataPlaneRequests5M` | Aggregated data plane logs in 5-minute intervals — up to 95% cheaper than per-request logs | Always-on for production — your cost-effective operational baseline |
| **DataPlaneRequests15M** | `CDBDataPlaneRequests15M` | Same as above, aggregated to 15-minute intervals | Alternative to 5M when you need even lower ingestion costs |

<!-- Source: monitor-reference.md, monitor-resource-logs.md, monitor-aggregated-logs.md -->

Two recommendations: always send logs to a **Log Analytics workspace** in **resource-specific** mode (not the legacy AzureDiagnostics mode). Resource-specific tables have cleaner schemas, faster queries, and better ingestion performance. And enable the **aggregated log tables** (`DataPlaneRequests5M` or `DataPlaneRequests15M`) for production workloads — they give you the operational visibility you need at a fraction of the cost of per-request logging. Reserve the detailed `DataPlaneRequests` category for troubleshooting sessions where you need per-operation granularity.

You can create diagnostic settings through the portal, Azure CLI, Bicep, or ARM templates. Here's the CLI version:

```bash
az monitor diagnostic-settings create \
  --resource $(az cosmosdb show \
    --resource-group "myResourceGroup" \
    --name "my-cosmos-account" \
    --query "id" --output "tsv") \
  --workspace $(az monitor log-analytics workspace show \
    --resource-group "myResourceGroup" \
    --name "my-log-workspace" \
    --query "id" --output "tsv") \
  --name "production-diagnostics" \
  --export-to-resource-specific true \
  --logs '[
    { "category": "DataPlaneRequests", "enabled": true },
    { "category": "QueryRuntimeStatistics", "enabled": true },
    { "category": "PartitionKeyRUConsumption", "enabled": true },
    { "category": "PartitionKeyStatistics", "enabled": true },
    { "category": "ControlPlaneRequests", "enabled": true }
  ]'
```

<!-- Source: monitor-resource-logs.md -->

> **Gotcha:** By default, query text in `QueryRuntimeStatistics` is obfuscated to protect PII. If you need to see the actual SQL, you must explicitly enable **Diagnostics full-text query** on your account under **Settings > Features**. This incurs additional logging costs, so enable it for troubleshooting and disable it when you're done. <!-- Source: monitor-resource-logs.md -->

## Key Metrics to Watch

Cosmos DB exposes dozens of metrics. Most of them are operational noise for day-to-day monitoring. Here are the ones that matter — the metrics that should live on your dashboard and feed your alert rules.

### Total Requests and Failed Requests

The **Total Requests** metric (`TotalRequests`) counts every request to your account, broken down by dimensions including `StatusCode`, `OperationType`, `DatabaseName`, `CollectionName`, and `Region`. Filter by status code 429 to see rate-limited requests; filter by 5xx codes to see server-side failures (rare, but worth tracking). <!-- Source: monitor-reference.md -->

This is your first-line health indicator. A sudden spike in total requests might mean a new feature shipped, a traffic spike hit, or a runaway retry loop. A spike in 429s means you're hitting your throughput ceiling.

### RU Consumption

Two metrics cover RU usage:

**Total Request Units** (`TotalRequestUnits`) gives you the raw sum of RUs consumed across all operations. Split by `OperationType` to see whether reads, writes, or queries are dominating your spend. Split by `CollectionName` to find which container is the most expensive. <!-- Source: monitor-request-unit-usage.md -->

**Normalized RU Consumption** (`NormalizedRUConsumption`) is the more actionable metric. It's a percentage (0–100%) representing how close the busiest physical partition is to its throughput limit in any given minute. This metric is defined as the *maximum* RU/s utilization across all partition key ranges in each 1-minute window. <!-- Source: monitor-normalized-request-units.md -->

Here's the mental model: if you have a container with 20,000 RU/s spread across two physical partitions (10,000 RU/s each), and one partition consumed 8,000 RU/s in a given second while the other consumed 3,000, normalized RU consumption for that interval is 80% (8,000 / 10,000). The overall container might only be using 55% of its total throughput, but the hot partition is at 80%.

When normalized RU consumption sustains 100%, any additional requests to that partition key range in that second get a 429. But here's the nuance: momentary spikes to 100% aren't necessarily a problem. The SDKs automatically retry 429s (up to 9 times by default), and if your end-to-end latency is acceptable and only 1–5% of requests return 429s, your throughput is being well-utilized. No action needed. <!-- Source: monitor-normalized-request-units.md -->

If normalized RU consumption is *consistently* 100% across multiple partition key ranges and your 429 rate exceeds 5%, it's time to increase throughput or investigate whether a hot partition is the root cause (more on that in the troubleshooting section).

### Throttled Requests (429s)

You can track 429s by filtering `TotalRequests` where `StatusCode == 429`. This gives you a count of rate-limited operations per minute, split by database, container, region, and operation type. Pair this with normalized RU consumption to distinguish between "healthy full utilization" (low 429 rate, high normalized RU) and "genuine throughput starvation" (high 429 rate sustained over time). <!-- Source: monitor-reference.md -->

### Latency Percentiles

Cosmos DB provides server-side latency metrics for both connection modes:

- **Server Side Latency Direct** (`ServerSideLatencyDirect`) — latency for requests using direct connectivity mode
- **Server Side Latency Gateway** (`ServerSideLatencyGateway`) — latency for requests using gateway connectivity mode

<!-- Source: monitor-server-side-latency.md, monitor-reference.md -->

Both support Average, Minimum, Maximum, and Total (Sum) aggregations, and can be split by `DatabaseName`, `CollectionName`, `Region`, and `OperationType`. To get P50 and P99 latency, you'll need to use diagnostic logs and KQL — the built-in metrics give you average, min, max, and sum — not percentile distributions. <!-- Source: monitor-reference.md -->

The important distinction: these are **server-side** latency metrics — the time Cosmos DB spends processing your request on the backend, *not* end-to-end latency including network round trips. If you see low server-side latency but high end-to-end latency in your application, the problem is in your network path or SDK configuration, not in Cosmos DB itself. For the NoSQL API, use the Direct metric if you're using direct mode (the default and recommended mode in .NET and Java) and the Gateway metric if you're using gateway mode.

> **Note:** The old unified `ServerSideLatency` metric is deprecated and will be removed. Use the Direct and Gateway variants instead. <!-- Source: monitor-reference.md -->

### Storage Consumption

**Data Usage** (`DataUsage`) reports the total bytes stored in each container, split by database, collection, and region. **Index Usage** (`IndexUsage`) shows how much storage your indexes consume. **Document Count** (`DocumentCount`) gives you the total item count.

These metrics are emitted at 5-minute granularity. They're important for capacity planning and cost tracking, but they won't change fast enough to drive real-time alerts — they're dashboard metrics.

### Replication Latency

For multi-region accounts, **P99 Replication Latency** (`ReplicationLatency`) measures the time it takes for a write in the source region to be acknowledged in each target region, at the 99th percentile. It's split by `SourceRegion` and `TargetRegion`. <!-- Source: monitor-reference.md -->

This is a critical metric for globally distributed applications. If replication latency spikes, reads in secondary regions may be returning stale data (depending on your consistency level). It can also indicate a regional issue or a throughput bottleneck in the target region.

### The Dashboard Essentials

Here's what belongs on your production monitoring dashboard:

| Metric | Aggregation | Why |
|--------|------------|-----|
| Total Requests | Count, split by StatusCode | Overall traffic and error rates |
| Total Requests (429 only) | Count, split by CollectionName | Throttling by container |
| Normalized RU Consumption | Max, split by PartitionKeyRangeId | Hotspot detection |
| Total Request Units | Sum, split by OperationType | Cost attribution |
| Server Side Latency (Direct or Gateway) | Avg and Max | Performance baseline |
| Data Usage | Total | Storage growth tracking |
| Replication Latency (multi-region) | Max, split by TargetRegion | Geo-replication health |
| Service Availability | Avg | Uptime tracking |

## Setting Up Alerts

Metrics on a dashboard are useful. Alerts that wake you up (or, better, trigger automated remediation) before your users feel pain are essential.

Azure Monitor supports three types of alerts relevant to Cosmos DB:

- **Metric alerts** evaluate a metric against a threshold at regular intervals. These are your primary tool — fast, cheap, and reliable.
- **Log alerts** run a KQL query against your Log Analytics data on a schedule. More flexible but slower (there's always some ingestion latency).
- **Activity log alerts** fire on control-plane events like key rotations, region failovers, or account changes.

<!-- Source: monitor.md -->

### Recommended Alert Rules

Here are the alerts every production Cosmos DB deployment should have:

| Alert | Type | Condition | Why |
|-------|------|-----------|-----|
| **Throttling spike** | Metric | `TotalRequests` where StatusCode = 429, Count > 100 over 5 min | Detects sustained rate limiting beyond healthy SDK retry levels |
| **Normalized RU saturation** | Metric | `NormalizedRUConsumption` Max > 90% for 15 min | Early warning before 429s become widespread |
| **High server-side latency** | Metric | `ServerSideLatencyDirect` Avg > 10 ms for 5 min | SLA threshold for point operations — investigate if consistently breached |
| **Replication lag** | Metric | `ReplicationLatency` Max > 1000 ms for 10 min | Geo-replication falling behind |
| **Region failover** | Metric | `RegionFailover` Count > 0 | Detects automatic or manual failover events |
| **Service availability drop** | Metric | `ServiceAvailability` Avg < 99.9% over 1 hour | Catches availability dips across any dimension |
| **Key rotation** | Activity log | Event: Informational, Status: started | Notification when account keys are rotated — so you can update your apps |
| **Logical partition approaching limit** | Log alert | KQL on `CDBPartitionKeyStatistics` where `SizeKb > 18874368` (18 GB) | Warns before a logical partition hits the 20 GB limit |

<!-- Source: monitor.md, create-alerts.md -->

### Creating a Metric Alert: A Walkthrough

Let's walk through creating the throttling alert:

1. In the Azure portal, navigate to **Monitor > Alerts** and click **Create > Alert rule**.
2. Under **Scope**, select your Cosmos DB account.
3. Under **Condition**, select the **Total Requests** signal.
4. Add a filter: set **StatusCode** dimension to **429**.
5. Set the **Aggregation type** to **Total**, **Operator** to **Greater than**, and **Threshold** to **100**.
6. Set the **Aggregation granularity** to 5 minutes.
7. Under **Actions**, create or select an action group — email, SMS, webhook, Azure Function, Logic App, or ITSM connector.
8. Name the rule, set severity (Sev 2 is appropriate for throttling), and save.

<!-- Source: create-alerts.md -->

> **Practical note:** Don't alert on *every* 429. As noted in the metrics section above, a low 429 rate is healthy — it means you're fully utilizing your provisioned throughput. Set thresholds that catch sustained throttling, not transient spikes.

For dynamic workloads where "normal" traffic varies dramatically, consider using Azure Monitor's **dynamic thresholds** instead of static ones. Dynamic thresholds use machine learning to learn your metric's behavior pattern and alert only on deviations from the norm — useful for workloads with strong daily or weekly seasonality.

## Diagnostic Logs and Log Analytics

Metrics tell you something is wrong. Diagnostic logs tell you *what* — the specific queries, partitions, and operations behind the metric spikes. This is where Log Analytics and KQL (Kusto Query Language) become your primary investigation tools.

### The Key Tables

With resource-specific diagnostic settings, your logs land in dedicated tables in your Log Analytics workspace:

**`CDBDataPlaneRequests`** — the workhorse table. Every data plane operation gets a row: the operation name, status code, duration in milliseconds, RU charge, partition ID, client IP, user agent, request and response length. This is where you start any investigation.

**`CDBQueryRuntimeStatistics`** — stores the SQL query text and execution statistics for query operations. Each record is linked to `CDBDataPlaneRequests` via the `ActivityId` field, so you can join them to see both the query text and its RU cost.

**`CDBPartitionKeyRUConsumption`** — RU consumption broken down by logical partition key and physical partition (partition key range). This is how you identify hot partitions from a throughput perspective.

**`CDBPartitionKeyStatistics`** — storage size per logical partition key. Use this to find partitions approaching the 20 GB limit.

<!-- Source: monitor-reference.md, diagnostic-queries.md -->

### Essential KQL Queries

Here are the queries you'll reach for most often. All examples use the resource-specific tables.

**Find the top 10 most expensive queries by RU charge in the last 24 hours:**

```kusto
let topRequestsByRUcharge = CDBDataPlaneRequests
| where TimeGenerated > ago(24h)
| project RequestCharge, TimeGenerated, ActivityId;
CDBQueryRuntimeStatistics
| project QueryText, ActivityId, DatabaseName, CollectionName
| join kind=inner topRequestsByRUcharge on ActivityId
| project DatabaseName, CollectionName, QueryText, RequestCharge, TimeGenerated
| order by RequestCharge desc
| take 10
```

<!-- Source: diagnostic-queries.md -->

This is your single most useful query. Run it weekly. The results will almost always point to one or two queries that are burning more RUs than everything else combined. Those are the queries to optimize (see Chapter 8).

**Find queries consuming more than 100 RUs per execution:**

```kusto
CDBDataPlaneRequests
| where todouble(RequestCharge) > 100.0
| project ActivityId, RequestCharge
| join kind=inner (
    CDBQueryRuntimeStatistics
    | project ActivityId, QueryText
) on $left.ActivityId == $right.ActivityId
| order by RequestCharge desc
| limit 100
```

<!-- Source: monitor-logs-basic-queries.md -->

**Identify which queries are being throttled (returning 429):**

```kusto
let throttledRequests = CDBDataPlaneRequests
| where StatusCode == "429"
| project OperationName, TimeGenerated, ActivityId;
CDBQueryRuntimeStatistics
| project QueryText, ActivityId, DatabaseName, CollectionName
| join kind=inner throttledRequests on ActivityId
| project DatabaseName, CollectionName, QueryText, OperationName, TimeGenerated
```

<!-- Source: diagnostic-queries.md -->

**Get P50 and P99 latency by operation type over the last 2 days:**

```kusto
CDBDataPlaneRequests
| where TimeGenerated >= ago(2d)
| summarize
    P50_Latency = percentile(todouble(DurationMs), 50),
    P99_Latency = percentile(todouble(DurationMs), 99),
    P50_RUCharge = percentile(todouble(RequestCharge), 50),
    P99_RUCharge = percentile(todouble(RequestCharge), 99),
    RequestCount = count()
  by OperationName, CollectionName, bin(TimeGenerated, 1h)
```

<!-- Source: monitor-logs-basic-queries.md -->

**Find RU consumption by physical partition to detect hot partitions:**

```kusto
CDBPartitionKeyRUConsumption
| where TimeGenerated >= now(-1d)
| where DatabaseName == "MyDatabase" and CollectionName == "MyContainer"
| summarize TotalRU = sum(todouble(RequestCharge)) by toint(PartitionKeyRangeId)
| render columnchart
```

<!-- Source: diagnostic-queries.md -->

If one `PartitionKeyRangeId` is consuming dramatically more RUs than the others, you've found your hot partition. The next step is identifying the logical partition key behind it — drill into the `PartitionKey` column in the same table:

```kusto
CDBPartitionKeyRUConsumption
| where TimeGenerated >= now(-1d)
| where DatabaseName == "MyDatabase" and CollectionName == "MyContainer"
| summarize TotalRU = sum(todouble(RequestCharge)) by PartitionKey, PartitionKeyRangeId
| order by TotalRU desc
| take 20
```

<!-- Source: diagnostic-queries.md -->

**Find logical partitions with significant storage consumption:**

```kusto
CDBPartitionKeyStatistics
| where todouble(SizeKb) > 800000
| project RegionName, DatabaseName, CollectionName, PartitionKey, SizeKb
```

<!-- Source: monitor-logs-basic-queries.md (query adapted — original has no descriptive framing) -->

> **Note:** The 800,000 KB (~781 MB) threshold comes from the docs and serves as a starting point. Adjust it to match your own alerting needs. For example, if you want early warning when a partition approaches the 20 GB logical partition limit, filter on `SizeKb > 14680064` (70% of 20 GB) — which is what the official alerting guide recommends. <!-- Source: how-to-alert-on-logical-partition-key-storage-size.md -->

### Using Aggregated Logs for Cost-Effective Monitoring

Per-request logging in `CDBDataPlaneRequests` is detailed but expensive at scale. If your account handles millions of requests per hour, the Log Analytics ingestion cost can rival the Cosmos DB bill itself.

The **aggregated diagnostics logs** feature addresses this. The `CDBDataPlaneRequests5M` and `CDBDataPlaneRequests15M` tables roll up data plane operations into 5-minute and 15-minute buckets, giving you summary statistics (total RU charge, max/avg duration, sample count, total request/response length) per operation type, partition, and status code. Microsoft estimates up to **95% reduction in logging costs** compared to per-request logging. <!-- Source: monitor-aggregated-logs.md -->

Here's a typical investigation using the 5-minute aggregated table:

```kusto
// Are we experiencing latency spikes on a specific operation?
CDBDataPlaneRequests5M
| where DatabaseName == "OrdersDB" and CollectionName == "Transactions"
| summarize
    TotalDurationMs = sum(TotalDurationMs),
    MaxDurationMs = max(MaxDurationMs),
    AvgDurationMs = max(AvgDurationMs)
  by OperationName, TimeGenerated
| render timechart

// What's our throttled percentage?
CDBDataPlaneRequests5M
| where DatabaseName == "OrdersDB" and CollectionName == "Transactions"
| summarize
    ThrottledOps = sumif(SampleCount, StatusCode == 429),
    TotalOps = sum(SampleCount)
  by TimeGenerated, OperationName
| extend ThrottledPct = ThrottledOps * 1.0 / TotalOps
```

<!-- Source: monitor-aggregated-logs.md -->

The recommended approach for production: enable aggregated logs (`DataPlaneRequests5M`) for always-on monitoring, and turn on the detailed `DataPlaneRequests` category only when you need to drill into specific operations during a troubleshooting session.

## OpenTelemetry and Distributed Tracing

Azure Monitor metrics and logs give you Cosmos DB-side observability. But in a microservices architecture, you need to trace a request from the moment it enters your API gateway, through your application logic, into Cosmos DB, and back. That's **distributed tracing**, and the Cosmos DB SDKs support it through **OpenTelemetry**. <!-- Source: sdk-observability.md -->

The .NET SDK (v3, version 3.36.0+) and Java SDK (v4, version 4.43.0+) emit OpenTelemetry-compatible traces that follow the OpenTelemetry database specification. Each Cosmos DB operation produces a span with attributes including the database name, container name, operation type, status code, RU charge, connection mode, and regions contacted. <!-- Source: sdk-observability.md -->

| Trace Attribute | Description |
|----------------|-------------|
| `db.system` | Always `cosmosdb` |
| `db.name` | Database name |
| `db.cosmosdb.container` | Container name |
| `db.operation` | Operation name (e.g., `CreateItemAsync`) |
| `db.cosmosdb.request_charge` | RUs consumed |
| `db.cosmosdb.status_code` | HTTP status code |
| `db.cosmosdb.sub_status_code` | Sub-status code |
| `db.cosmosdb.connection_mode` | `direct` or `gateway` |
| `db.cosmosdb.regions_contacted` | Regions involved |
| `db.cosmosdb.client_id` | Unique client instance ID |

<!-- Source: sdk-observability.md -->

These traces can be exported to Azure Monitor (Application Insights), Jaeger, Zipkin, or any other OpenTelemetry-compatible collector. The key line is adding the `Azure.Cosmos.Operation` source to your trace provider:

```csharp
var traceProvider = Sdk.CreateTracerProviderBuilder()
    .AddSource("Azure.Cosmos.Operation")
    .AddAzureMonitorTraceExporter(o =>
        o.ConnectionString = appInsightsConnectionString)
    .Build();
```

<!-- Source: sdk-observability.md -->

The SDK can also automatically emit diagnostics for failed requests and high-latency operations — you configure latency thresholds and telemetry options on `CosmosClientOptions`. We'll cover the full SDK instrumentation setup — including threshold configuration, Java setup, Application Insights integration, and advanced tracing patterns — in Chapter 21. The point here is that Cosmos DB's tracing story fits cleanly into the OpenTelemetry ecosystem. You don't need a proprietary monitoring stack.

## The Azure Cosmos DB Insights Workbook

If you want a monitoring experience without writing any KQL or configuring custom dashboards, the **Azure Cosmos DB Insights** workbook is the fastest path to visibility. It's a built-in Azure Monitor workbook that provides an at-scale view of performance, failures, capacity, and operational health across all your Cosmos DB accounts. <!-- Source: insights-overview.md -->

You can access it two ways:

1. **From your Cosmos DB account:** Navigate to **Monitoring > Insights** in the account blade. This shows metrics scoped to that account.
2. **From Azure Monitor:** Navigate to **Monitor > Insights Hub > Azure Cosmos DB**. This gives you a cross-account, cross-subscription view.

The workbook is organized into tabs:

- **Overview** — Total requests, failed requests (429s), normalized RU consumption, and data/index usage. This is your at-a-glance health check.
- **Throughput** — Total RUs consumed and failed (429) requests, with drill-down per container.
- **Requests** — Request distribution by status code and operation type. Filters to specific containers.
- **Storage** — Document count, data usage, and index usage over time.
- **Availability** — Percentage of successful requests per hour. This maps to the SLA definition.
- **Latency** — Server-side read and write latency across regions. Splits by operation type for latency attribution.
- **System** — Metadata request counts and throttled metadata requests.
- **Management Operations** — Control plane operations: account creation, deletion, key updates, network changes.

<!-- Source: insights-overview.md -->

The workbook requires no additional configuration — it's free and uses the same platform metrics that Azure Monitor collects automatically. You can filter by time range, database, and container. You can customize it, fork it into your own workbook, and pin individual charts to Azure dashboards.

For quick operational health checks — "is anything on fire right now?" — Insights is hard to beat. For deep investigations, you'll graduate to KQL queries in Log Analytics.

## Troubleshooting Common Issues

Monitoring is only useful if you know what to do when the metrics turn red. Here are the three most common Cosmos DB operational issues and how to use your monitoring tools to diagnose them.

### 429 Too Many Requests

A 429 means a partition hit its throughput ceiling for that second. The SDKs retry automatically (up to 9 times), so many 429s never bubble up to your application. The question is: are the retries succeeding with acceptable latency, or is the throttling sustained enough to degrade the user experience?

**Diagnosis workflow:**

1. Check `NormalizedRUConsumption` in Metrics Explorer with Max aggregation, split by `PartitionKeyRangeId`. If one partition range is consistently at 100% while others are low, you have a **hot partition** problem — not a total throughput problem. Adding RUs won't help if the traffic is concentrated on a single partition key value.
2. Check the throttled percentage in your Insights workbook under **Requests > Total Requests by Status Code**. As noted in the metrics section above, a low 429 rate with acceptable end-to-end latency is healthy. No action needed.
3. If 429s are sustained and above 5%, determine what's causing the RU consumption: use the `CDBDataPlaneRequests` table to find which operations are consuming the most RUs (see the KQL queries above).

**Remediation** depends on the root cause. If the workload is genuinely hitting the throughput ceiling evenly, increase RUs (Chapter 10 covers RU mechanics; Chapter 11 covers capacity planning). If a hot partition is the culprit, the fix is a better partition key (Chapter 5) or partition key redistribution strategies (Chapter 27). If a single expensive query is blowing the budget, optimize it (Chapter 8).

### High Cross-Partition Query Cost

Your monitoring shows that a particular query is consuming hundreds or thousands of RUs per execution. Cross-partition queries fan out to every physical partition, and each partition charges RUs independently.

**Diagnosis workflow:**

1. Use the "top 10 most expensive queries" KQL query from earlier in this chapter to identify the offending query text and its RU charge.
2. Check the `OperationName` — if it's `Query` (not `ReadItem`), the operation is a SQL query that likely requires cross-partition execution.
3. Look at the `RequestCharge` relative to the query's result set. A query returning 10 items but charging 500 RUs is scanning far more data than it returns — likely a missing index path or a filter that can't use an index.

**Remediation:** This is a query optimization problem, covered in depth in Chapter 8. The most common fixes are adding the right properties to your indexing policy, restructuring queries to target single partitions, or redesigning the data model to colocate the data needed by the query.

### Hot Partition Detection

Hot partitions are the most insidious performance problem in Cosmos DB because they can throttle specific users or workloads while the overall account looks healthy. You'll see normalized RU consumption at 100% on one partition range while others idle at 10%.

**Diagnosis workflow:**

1. In the Insights workbook, navigate to **Throughput > Normalized RU Consumption (%) By PartitionKeyRangeID**. Filter to the specific database and container. If one `PartitionKeyRangeId` is consistently far above the others, that's your hot partition.
2. To find the logical partition key behind the hot partition, run the partition-key RU consumption query from the Essential KQL Queries section earlier in this chapter — it breaks down RU consumption by `PartitionKey` and `PartitionKeyRangeId`, so you can see exactly which logical key is driving the load.

3. For storage-based hotspots (approaching the 20 GB logical partition limit), check `CDBPartitionKeyStatistics` for outlier partition keys.

**Remediation:** Hot partitions are fundamentally a partition key design issue. Chapter 5 covers how to choose high-cardinality keys that distribute traffic evenly. If you're stuck with a bad partition key on an existing container, Chapter 27 covers throughput redistribution and migration strategies.

---

With your metrics flowing, your alerts configured, your diagnostic logs feeding KQL queries, and the Insights workbook on a screen near your desk, you're equipped to keep your Cosmos DB deployment healthy. But observability is only half of operational readiness. The next chapter covers the other half — what happens when things go truly wrong: backup strategies, point-in-time restore, and disaster recovery planning.
