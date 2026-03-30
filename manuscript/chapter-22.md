# Chapter 22: Integrating with Azure Services

Cosmos DB doesn't exist in a vacuum. In a real production system, it's one node in a larger architecture — taking input from IoT devices, feeding change streams to downstream processors, lighting up dashboards, training machine learning models, and serving data to frontends deployed on every platform from Kubernetes to Vercel. The good news is that the Azure ecosystem has deep, first-party integration points for nearly all of these scenarios. The not-so-good news is that the options can be overwhelming.

This chapter is a practical tour of the integrations that matter most. We'll focus on how to wire things up — configuration, gotchas, which connector version to use — and cross-reference the deeper conceptual material covered elsewhere in the book. Think of it as your field guide for connecting Cosmos DB to everything else.

## Azure Functions

Azure Functions is the most common entry point for event-driven Cosmos DB workloads. The integration comes in three flavors: a **change feed trigger**, **input bindings**, and **output bindings**. All three are supported exclusively for the API for NoSQL — other APIs require using the SDK directly inside your function code. <!-- Source: serverless-computing-database.md, change-feed-functions.md -->

### The Change Feed Trigger

The change feed trigger is the killer feature here. It wraps the change feed processor (covered in depth in Chapter 15) into a serverless function that fires every time documents are created or updated in a monitored container. You don't manage polling, lease distribution, or scaling — Functions handles all of it.

Under the hood, the trigger uses the **latest version change feed mode**, which means you get the most recent state of each changed document. It requires two containers: the **monitored container** (your data) and a **lease container** that tracks processing state across function instances. The lease container must have `/id` as its partition key. You can let Functions create it automatically by setting `CreateLeaseContainerIfNotExists` to `true` in your trigger configuration. <!-- Source: change-feed-functions.md -->

Here's a minimal C# trigger:

```csharp
[Function("ProcessOrderChanges")]
public void Run(
    [CosmosDBTrigger(
        databaseName: "ecommerce",
        containerName: "orders",
        Connection = "CosmosDBConnection",
        LeaseContainerName = "leases",
        CreateLeaseContainerIfNotExists = true)]
    IReadOnlyList<Order> changes,
    FunctionContext context)
{
    foreach (var order in changes)
    {
        // React to the change — send notification, update inventory, etc.
        _logger.LogInformation("Order {Id} changed to status {Status}", 
            order.Id, order.Status);
    }
}
```

A few things to watch out for:

- **Connection mode defaults to Gateway.** For performance-sensitive scenarios, switch to Direct/TCP by adding a `host.json` configuration. This matters when your function runs on a Premium or Dedicated plan rather than the Consumption plan, which has socket connection limits that make Gateway the safer choice. <!-- Source: how-to-configure-cosmos-db-trigger.md -->
- **Don't write back to the same container you're monitoring** without careful design — you'll create a recursive loop.
- **Multiple functions can listen to the same change feed**, but each needs its own lease container (or a distinct `LeaseContainerPrefix`).

```json
{
  "version": "2.0",
  "extensions": {
    "cosmosDB": {
      "connectionMode": "Direct",
      "protocol": "Tcp"
    }
  }
}
```

### Input and Output Bindings

**Input bindings** let a function read a specific document by `id` and partition key when it's invoked — think of an HTTP-triggered function that looks up a customer profile. **Output bindings** write documents to a container when the function completes. You can combine these freely: an HTTP trigger with an input binding to fetch data and an output binding to write a transformed result to a different container.

The change feed concepts — modes, processor mechanics, lease management — are all covered in Chapter 15. Here, you only need to know that Functions wraps all of that into a declarative binding model that takes minutes to set up.

## Azure Event Hubs and Kafka

When you need to stream Cosmos DB changes into downstream systems — analytics pipelines, notification services, partner integrations — **Azure Event Hubs** is the natural bridge. The pattern is straightforward: use a change feed trigger in Azure Functions (or the change feed processor directly) to read changes, then publish them to an Event Hub topic.

Event Hubs also exposes a **Kafka-compatible endpoint**, which means any Kafka consumer can read from it without changes. If your organization already runs Kafka consumers for stream processing, you can publish Cosmos DB changes to Event Hubs and let existing consumers pick them up seamlessly.

For the reverse direction — ingesting data from Kafka topics into Cosmos DB — see the Kafka Connect section later in this chapter. For change feed design patterns and fan-out architectures, see Chapter 15.

## Azure Synapse Link and Synapse Analytics

> **Important:** Synapse Link for Cosmos DB is no longer supported for new projects. Microsoft's guidance is explicit: use Microsoft Fabric Mirroring instead, which is now generally available. <!-- Source: synapse-link.md, configure-synapse-link.md, analytics-and-business-intelligence-overview.md -->

If you have an *existing* Synapse Link deployment, here's what you need to know to understand what you have and plan your migration.

### What Synapse Link Was

Azure Synapse Link created a **column-store analytical replica** of your transactional data — an *analytical store* — that auto-synced with your operational container in near real time. This let you run Spark jobs and serverless SQL pool queries directly against your Cosmos DB data without consuming transactional RU/s or building ETL pipelines. It was a genuine HTAP (Hybrid Transactional/Analytical Processing) capability. <!-- Source: synapse-link.md -->

You enabled it in two steps: turn on Synapse Link at the account level, then set the `AnalyticalStoreTimeToLiveInSeconds` property on each container (set to `-1` for infinite retention). The analytical store maintained a separate column-format copy of your data, completely isolated from transactional throughput. <!-- Source: configure-synapse-link.md -->

### Limitations That Drove the Replacement

Synapse Link had real constraints:

- Supported only for NoSQL, MongoDB, and Gremlin APIs (Gremlin in preview) — no Cassandra or Table
- No granular RBAC — anyone with access to the Synapse workspace could query all containers in the linked account
- Dedicated SQL pools couldn't access the analytical store
- Multi-region write accounts weren't recommended for production use with Synapse Link
<!-- Source: synapse-link.md -->

These limitations, combined with Microsoft's strategic investment in Fabric, led to Synapse Link being deprecated for new projects in favor of Fabric Mirroring.

### If You're Still on Synapse Link

Your existing deployment continues to work. But don't build new workloads on it — migrate to Fabric Mirroring instead. We'll cover the migration path in the next section.

## Microsoft Fabric Mirroring

**Fabric Mirroring** is the successor to Synapse Link, and it's the recommended path for running analytics over Cosmos DB operational data. It replicates your data continuously into **Microsoft Fabric OneLake** in near real time, stored in the open-source **Delta format**. This means your operational data is automatically available to every analytical engine in Fabric — Spark notebooks, serverless SQL (T-SQL), Power BI in DirectLake mode, and Copilot — without consuming a single RU. <!-- Source: analytics-and-business-intelligence-overview.md -->

| Characteristic | Synapse Link (deprecated) | Fabric Mirroring |
|---|---|---|
| **Status** | No new projects; existing deployments supported | GA, actively developed |
| **Destination** | Azure Synapse workspace | Microsoft Fabric OneLake (Delta format) |
| **Query engines** | Synapse Spark, serverless SQL pool | Fabric Spark, T-SQL, Power BI DirectLake |
| **RU impact** | Zero | Zero |
| **Data format** | Proprietary column store | Open-source Delta Lake |
| **Setup** | Account-level flag + per-container opt-in | Fabric workspace integration |

### Migrating from Synapse Link to Fabric Mirroring

If you're running Synapse Link today, the migration is conceptual more than mechanical:

1. **Set up Fabric Mirroring** for your Cosmos DB account in your Fabric workspace.
2. **Validate** that your analytical queries produce equivalent results against the mirrored Delta tables.
3. **Re-point** your Spark notebooks, SQL queries, and Power BI reports to the Fabric endpoints.
4. **Disable the analytical store** on your Cosmos DB containers once you've fully cut over — this stops the Synapse Link replication and eliminates the associated storage costs.

### Reverse ETL: Writing Analytical Results Back to Cosmos DB

Analytics isn't just about reading from your operational store — sometimes the insights need to flow back. **Reverse ETL** takes enriched, cleaned data from your data warehouse or lakehouse and pushes it into Cosmos DB so your applications can use it in real time. Think product recommendations, personalized pricing, fraud scores, or feature store data. <!-- Source: reverse-extract-transform-load.md -->

The architecture uses Apache Spark with the Cosmos DB OLTP connector (covered later in this chapter):

1. **Initial load**: A one-time batch job to hydrate Cosmos DB with historical enriched data from Delta tables.
2. **CDC sync**: Ongoing incremental replication using Delta Change Data Feed (CDF) — either batch-scheduled or streaming.

For the initial load, use standard provisioned throughput rather than autoscale if you'll be consistently maxing out your allocated RU/s. For the ongoing CDC sync, autoscale is the better fit since the workload is bursty by nature. Always use throughput control to prevent the sync job from starving your operational workload — see the Spark Connector section later in this chapter for configuration details. <!-- Source: reverse-extract-transform-load.md -->

## Azure Data Factory

**Azure Data Factory (ADF)** is Azure's managed ETL/ELT orchestration service, and it has a native Cosmos DB connector for both reading and writing. It supports copying data from 85+ sources into Cosmos DB and can perform relational-to-hierarchical mapping transformations in code-free mapping data flows. <!-- Source: analytics-and-business-intelligence-use-cases.md -->

ADF is the workhorse for two main scenarios:

- **Bulk import/export**: Loading large datasets from blob storage, SQL databases, or other sources into Cosmos DB containers — or extracting data out for archival or analysis.
- **Migration pipelines**: Moving data from legacy databases into Cosmos DB as part of a migration project.

Since migration is a deep topic with its own chapter, we'll keep ADF coverage here brief. Chapter 23 covers migration strategies, ADF pipeline configuration, and the Desktop Data Migration Tool in detail. The key thing to know is that ADF natively understands Cosmos DB's partitioning and can parallelize writes across partitions for high-throughput bulk loads.

## Azure Kubernetes Service and App Service

There's no special connector to install for running Cosmos DB workloads on **AKS** or **Azure App Service** — you use the standard SDK (Chapter 7). But there are integration patterns worth calling out.

### AKS Patterns

For Spring Boot on AKS, Microsoft provides a reference architecture that packages a Cosmos DB-backed REST API as a Docker image, pushes it to Azure Container Registry, and deploys it to an AKS cluster. The application uses **Spring Data Azure Cosmos DB** (covered later in this chapter) for data access. <!-- Source: tutorial-springboot-azure-kubernetes-service.md -->

Key considerations for Cosmos DB on Kubernetes:

- **Connection management**: The Cosmos DB SDK maintains persistent connections. Set the SDK to singleton per application instance — don't create a new client per request.
- **Preferred regions**: Configure the SDK's preferred region list to match the Azure region where your AKS cluster runs, minimizing cross-region latency.
- **Workload Identity**: Use Azure Workload Identity (federated credentials) to authenticate to Cosmos DB via Microsoft Entra ID, avoiding secrets in your pod configuration. Chapter 17 covers Entra ID authentication in depth.

### App Service Patterns

On App Service, the same rules apply: singleton SDK client, preferred region matching your App Service region, and managed identity for authentication. App Service's built-in autoscaling pairs well with Cosmos DB's autoscale throughput — your compute and data tiers scale independently but in response to the same traffic patterns.

## Azure IoT Hub

IoT is one of Cosmos DB's strongest use cases. The canonical pattern routes telemetry from **Azure IoT Hub** into Cosmos DB for hot-path storage, using either a direct IoT Hub routing rule or an intermediate processor like Azure Functions or Stream Analytics.

The data modeling challenge with IoT is volume and partition key choice. Devices generate data every second — 50,000 sensors at one-second intervals produce 4.32 billion records per day. A flat `deviceId` partition key hits the 20 GB logical partition limit within months. The recommended approach is a **hierarchical partition key** with `deviceId` as the first level and a timestamp bucket (e.g., date/hour/minute) as the second level. This keeps device data collocated on the same physical partitions for efficient queries while avoiding the 20 GB ceiling. <!-- Source: design-partitioning-iot.md -->

For real-time analytics on IoT data, pair Cosmos DB with Fabric Mirroring — operational writes stay fast, and your data science team gets near real-time access to the full telemetry dataset without touching your transactional throughput.

Chapter 5 covers hierarchical partition keys in depth, including the cardinality considerations that matter for IoT workloads.

## Azure AI Search

If you need full-text search, faceted navigation, or fuzzy matching over your Cosmos DB data, **Azure AI Search** (formerly Azure Cognitive Search) is the natural companion. AI Search provides a built-in **indexer** that connects directly to a Cosmos DB container, reads documents on a schedule, and indexes them into a search index.

The indexer tracks changes using Cosmos DB's `_ts` (timestamp) system property. It can also detect soft-deleted documents if you use a deletion detection policy. Configure the indexer data source by pointing it at your Cosmos DB account endpoint and specifying the database, container, and a SQL query to select which fields to index.

A few practical notes:

- **Indexer frequency**: You set a polling schedule (e.g., every 5 minutes). This isn't real-time — if you need sub-minute latency, use the change feed to push updates to AI Search via a function.
- **Field mappings**: Map Cosmos DB document properties to search index fields. Nested objects need to be flattened or handled with complex type mappings.
- **Cost awareness**: AI Search charges separately for storage and query volume. The indexer reads from Cosmos DB consume RU/s against your container's throughput.

For Cosmos DB's native full-text and vector search capabilities (which don't require an external service), see Chapter 25.

## Azure Stream Analytics

**Azure Stream Analytics** is a real-time stream processing engine that supports Cosmos DB as both an input (reference data) and an output (stream sink). The most common pattern is to write the results of a continuous query — aggregations, windowed computations, anomaly detection — into a Cosmos DB container. <!-- Source: analytics-and-business-intelligence-use-cases.md -->

Stream Analytics is a good fit when you need SQL-like transformations on streaming data from IoT Hub or Event Hubs and want the processed results to land in Cosmos DB for low-latency serving. It handles windowing functions (tumbling, hopping, sliding), temporal joins, and late-arriving event handling — all things that are painful to build from scratch.

When configuring the Cosmos DB output binding, pay attention to the **partition key** setting and the **write strategy** (create vs. upsert). Mismatching the partition key between your Stream Analytics output and your container definition is a common source of errors.

## Apache Spark Connector (OLTP)

The **Azure Cosmos DB Spark connector** is a first-party connector for reading and writing data from Cosmos DB's transactional store using Apache Spark. It's distinct from the Synapse Link analytical store connector — this one operates against your live operational data and consumes RU/s. Use it in Azure Databricks, Fabric Spark, or any Spark 3.4+ environment. <!-- Source: tutorial-spark-connector.md -->

### Setup

Install the connector from Maven Central — look for the artifact with group ID `com.azure.cosmos.spark` and an artifact ID prefixed with `azure-cosmos-spark_3-4` (matching your Spark version). Then configure it in your notebook:

```python
config = {
    "spark.cosmos.accountEndpoint": "<nosql-account-endpoint>",
    "spark.cosmos.accountKey": "<nosql-account-key>",
    "spark.cosmos.database": "cosmicworks",
    "spark.cosmos.container": "products"
}
```
<!-- Source: tutorial-spark-connector.md -->

You can also use the **Catalog API** to manage Cosmos DB resources directly from Spark SQL:

```python
spark.conf.set("spark.sql.catalog.cosmosCatalog", 
    "com.azure.cosmos.spark.CosmosCatalog")
spark.conf.set("spark.sql.catalog.cosmosCatalog.spark.cosmos.accountEndpoint", 
    config["spark.cosmos.accountEndpoint"])
spark.conf.set("spark.sql.catalog.cosmosCatalog.spark.cosmos.accountKey", 
    config["spark.cosmos.accountKey"])

# Create a container from Spark
spark.sql("""
    CREATE TABLE IF NOT EXISTS cosmosCatalog.cosmicworks.products 
    USING cosmos.oltp 
    TBLPROPERTIES(partitionKeyPath = '/category', autoScaleMaxThroughput = '1000')
""")
```

### Change Feed via Spark Structured Streaming

The Spark connector can also read the change feed as a Spark Structured Streaming source. This is the right choice when your change feed processing involves complex transformations, joins with other datasets, or needs to run at large scale across a distributed Spark cluster. The connector uses the **pull model** underneath and includes built-in **checkpointing** for fault tolerance — a capability not available when using the SDKs directly. <!-- Source: change-feed-spark.md -->

```python
changeFeedConfig = {
    "spark.cosmos.accountEndpoint": "https://<account>.documents.azure.com:443/",
    "spark.cosmos.accountKey": "<key>",
    "spark.cosmos.database": "ecommerce",
    "spark.cosmos.container": "orders",
    "spark.cosmos.changeFeed.startFrom": "Beginning",
    "spark.cosmos.changeFeed.mode": "LatestVersion",
    "spark.cosmos.changeFeed.itemCountPerTriggerHint": "50000",
    "spark.cosmos.read.partitioning.strategy": "Restrictive"
}

changeFeedDF = spark \
    .readStream \
    .format("cosmos.oltp.changeFeed") \
    .options(**changeFeedConfig) \
    .load()
```
<!-- Source: change-feed-spark.md -->

### Throughput Control

When running batch or streaming Spark jobs against Cosmos DB, always configure **throughput control** to prevent your analytics workload from starving your operational traffic. You create a metadata container with partition key `/groupId` and TTL enabled, then reference it in your Spark configuration:

```python
throughput_config = {
    "spark.cosmos.throughputControl.enabled": "true",
    "spark.cosmos.throughputControl.name": "SparkBatchJob",
    "spark.cosmos.throughputControl.targetThroughputThreshold": "0.95",
    "spark.cosmos.throughputControl.globalControl.database": "cosmicworks",
    "spark.cosmos.throughputControl.globalControl.container": "ThroughputControl"
}
```
<!-- Source: throughput-control-spark.md -->

The `targetThroughputThreshold` setting caps this Spark job at 95% of available throughput. For serverless accounts, you must use an absolute `targetThroughput` value instead of a percentage threshold. <!-- Source: throughput-control-spark.md -->

## Kafka Connect for Cosmos DB

If your architecture centers on Apache Kafka, the **Kafka Connect Cosmos DB connector** gives you source and sink connectors for bidirectional data flow. There are two major versions, and you should be on V2.

### V1 vs. V2

| Feature | V1 (Legacy) | V2 (Current) |
|---|---|---|
| **Source delivery semantics** | At-least-once (multi-task) / Exactly-once (single task) | Exactly-once |
| **Sink delivery semantics** | Exactly-once | Exactly-once |
| **Change feed implementation** | Change feed processor (lease container) | Pull model (Kafka offset topics) |
| **Multi-container support** | One container per connector instance | Multiple containers per connector |
| **Authentication** | Key-based only | Key-based + Entra ID (service principal) |
| **Throughput control** | Not supported | Supported |
| **Supported Kafka versions** | Older | 3.6.0+ |

<!-- Source: kafka-connector-v2.md, kafka-connector.md, how-to-migrate-from-kafka-connector-v1-to-v2.md -->

V2 is a significant architectural improvement. It uses Kafka's native offset management instead of a Cosmos DB lease container, upgrades the source connector to exactly-once delivery regardless of task count, and handles multiple containers in a single connector instance. The sink connector already supported exactly-once in V1, so that's unchanged. If you're still on V1, migrate — the V1 connector is legacy. <!-- Source: kafka-connector.md, how-to-migrate-from-kafka-connector-v1-to-v2.md -->

### Sink Connector Configuration

The sink connector writes data from Kafka topics into Cosmos DB containers. A minimal V2 configuration:

```json
{
  "name": "cosmosdb-sink-connector",
  "config": {
    "connector.class": "com.azure.cosmos.kafka.connect.CosmosSinkConnector",
    "tasks.max": "5",
    "topics": "orders",
    "value.converter": "org.apache.kafka.connect.json.JsonConverter",
    "value.converter.schemas.enable": "false",
    "key.converter": "org.apache.kafka.connect.json.JsonConverter",
    "key.converter.schemas.enable": "false",
    "azure.cosmos.account.endpoint": "<endpoint>",
    "azure.cosmos.account.key": "<key>",
    "azure.cosmos.sink.database.name": "ecommerce",
    "azure.cosmos.sink.containers.topicMap": "orders#orders"
  }
}
```
<!-- Source: kafka-connector-sink-v2.md -->

### Source Connector Configuration

The source connector reads the Cosmos DB change feed and publishes changes to Kafka topics:

```json
{
  "name": "cosmosdb-source-connector",
  "config": {
    "connector.class": "com.azure.cosmos.kafka.connect.CosmosSourceConnector",
    "tasks.max": "5",
    "azure.cosmos.account.endpoint": "<endpoint>",
    "azure.cosmos.account.key": "<key>",
    "azure.cosmos.source.database.name": "ecommerce",
    "azure.cosmos.source.containers.includedList": "orders",
    "azure.cosmos.source.containers.topicMap": "orders-changes#orders",
    "azure.cosmos.source.changeFeed.startFrom": "Beginning",
    "azure.cosmos.source.changeFeed.mode": "LatestVersion",
    "azure.cosmos.source.metadata.storage.type": "Cosmos",
    "azure.cosmos.source.metadata.storage.name": "kafka-metadata"
  }
}
```
<!-- Source: kafka-connector-source-v2.md -->

Both connectors support Plain JSON, JSON with schema, and AVRO data formats. Configure your preferred region list to co-locate with your Kafka cluster for best performance. <!-- Source: kafka-connector-v2.md -->

### V1 to V2 Migration

The migration involves breaking changes:

1. Stop the V1 connector and back up any lease container data.
2. Deploy V2 JARs and remove V1 JARs from the plugin path.
3. Rewrite your configuration — property names changed from `connect.cosmos.*` to `azure.cosmos.*`.
4. V2 uses Kafka's internal offset topics instead of a Cosmos DB lease container, so offsets are **not transferable**. You'll restart from the beginning or from "now."
<!-- Source: how-to-migrate-from-kafka-connector-v1-to-v2.md -->

## Spring Data Azure Cosmos DB

For Java developers on Spring Boot, **Spring Data Azure Cosmos DB** provides the familiar Spring Data repository abstraction over Cosmos DB for NoSQL. The current major version is **v5**, which supports both sync and reactive (async) APIs from the same Maven artifact. <!-- Source: sdk-java-spring-data-v5.md -->

The Spring Boot Starter handles CosmosClient lifecycle, connection pooling, and configuration via `application.properties`:

```properties
azure.cosmos.uri=https://<account>.documents.azure.com:443/
azure.cosmos.key=<key>
azure.cosmos.database=ecommerce
azure.cosmos.populateQueryMetrics=true
```

Define your repository the same way you would for any Spring Data provider:

```java
@Container(containerName = "products", partitionKeyPath = "/category")
public class Product {
    @Id
    private String id;
    private String category;
    private String name;
    private double price;
    // getters, setters
}

public interface ProductRepository 
    extends CosmosRepository<Product, String> {
    
    List<Product> findByCategory(String category);
}
```

Spring Data Azure Cosmos DB works on AKS, App Service, or any container runtime that hosts Spring Boot applications. It exposes the Spring Data interface for database and container management, CRUD operations, and derived query methods — a productive option if your team already thinks in Spring idioms. (Azure Spring Apps, previously listed as a supported host, is being retired with end of support in March 2025. AKS and App Service are the go-forward options for managed Spring Boot hosting on Azure.) <!-- Source: sdk-java-spring-data-v5.md -->

## ASP.NET Session State and Cache Provider

Cosmos DB ships a first-party NuGet package — `Microsoft.Extensions.Caching.Cosmos` — that implements the ASP.NET Core `IDistributedCache` interface. This means you can use Cosmos DB as a **session state store** and a **general-purpose distributed cache** with the same API you'd use for Redis or SQL Server distributed cache. <!-- Source: session-state-and-caching-provider.md -->

```csharp
services.AddCosmosCache((CosmosCacheOptions cacheOptions) =>
{
    CosmosClientBuilder clientBuilder = new CosmosClientBuilder(
        "<nosql-account-endpoint>",
        new DefaultAzureCredential()
    ).WithApplicationRegion("West US");

    cacheOptions.ContainerName = "sessionCache";
    cacheOptions.DatabaseName = "webapp";
    cacheOptions.ClientBuilder = clientBuilder;
    cacheOptions.CreateIfNotExists = true;
});

services.AddSession(options =>
{
    options.IdleTimeout = TimeSpan.FromSeconds(3600);
    options.Cookie.IsEssential = true;
});
```
<!-- Source: session-state-and-caching-provider.md -->

If you provide an existing container, make sure it has **time to live (TTL) enabled** — the provider uses TTL for session expiration. If you let it create the container via `CreateIfNotExists`, TTL is configured automatically. <!-- Source: session-state-and-caching-provider.md -->

Why choose Cosmos DB over Redis for session state? A few scenarios where it makes sense:

- You already have a Cosmos DB account and want to avoid managing a separate Redis instance.
- You need **global distribution** for your session data — users in Tokyo and Berlin hitting the same session store with low latency.
- You need the stronger consistency guarantees that Cosmos DB offers over a typical Redis deployment.

Use **Session consistency** if you can make requests sticky, or **Bounded Staleness / Strong** if you need any instance to read the latest session data without stickiness. <!-- Source: session-state-and-caching-provider.md -->

## Cosmos DB in Microsoft Fabric

Beyond Mirroring (which replicates your *existing* Azure Cosmos DB data into Fabric), Microsoft offers **Cosmos DB in Microsoft Fabric** — a native Fabric database product. This isn't replication; it's a Cosmos DB account that lives *inside* Fabric, tightly integrated with the Fabric experience. <!-- Source: analytics-and-business-intelligence-overview.md -->

Cosmos DB in Fabric uses the same engine and infrastructure as Azure Cosmos DB for NoSQL. Your application code, data model, and performance characteristics are identical — the difference is where you manage the resource. It's purpose-built for the Fabric ecosystem, with simplified provisioning and direct access from Fabric's analytical tools. <!-- Source: analytics-and-business-intelligence-overview.md -->

Use cases for Cosmos DB in Fabric:

- **Low-latency serving layer**: Serve Power BI reports and dashboards that need to handle thousands of concurrent users with consistently low latency.
- **AI application backends**: Build AI-powered apps inside the Fabric ecosystem with Cosmos DB as the operational data store.
- **Simplified management**: Skip the Azure portal entirely and manage your Cosmos DB database from within the Fabric workspace.

If you're already invested in the Fabric ecosystem and starting a new project, Cosmos DB in Fabric is worth evaluating. If you're running an existing Azure Cosmos DB account and just need analytics, Mirroring is the simpler path.

## Vercel Integration

For frontend developers deploying Next.js or other frameworks on **Vercel**, there's a first-party integration in the Vercel Marketplace that connects your Vercel project to a Cosmos DB account. The integration injects the necessary environment variables (`COSMOSDB_CONNECTION_STRING`, `COSMOSDB_DATABASE_NAME`, `COSMOSDB_CONTAINER_NAME`) into your Vercel project automatically. <!-- Source: vercel-integration.md -->

You can set it up in two ways:

1. **Vercel Integrations Marketplace**: Visit the Azure Cosmos DB integration page on Vercel, select your projects, authenticate with your Microsoft account, and either connect an existing Cosmos DB account or create a new Try Cosmos DB account.
2. **Command line**: Bootstrap a new Next.js project with `npx create-next-app --example with-azure-cosmos`, configure your environment variables, and deploy.
<!-- Source: vercel-integration.md -->

The integration currently supports the NoSQL and MongoDB APIs. In your application code, you use the `@azure/cosmos` JavaScript SDK as you would in any Node.js environment — the Vercel integration just handles credential plumbing so you don't have to manage connection strings in your deployment configuration manually. <!-- Source: vercel-integration.md -->

## Choosing the Right Integration

With this many integration options, it helps to start from the problem rather than the tool:

| I need to... | Use... |
|---|---|
| React to document changes in real time | Azure Functions trigger (Ch 15 + this chapter) |
| Run analytics over operational data | Fabric Mirroring |
| Stream changes to Kafka consumers | Kafka Connect V2 source connector |
| Ingest from Kafka topics | Kafka Connect V2 sink connector |
| Bulk import data from SQL/files | Azure Data Factory (Ch 23) |
| Process streaming data with SQL-like transforms | Azure Stream Analytics |
| Full-text search and faceted navigation | Azure AI Search indexer |
| Batch/streaming Spark integration | Apache Spark OLTP connector |
| Session state / distributed cache (.NET) | `Microsoft.Extensions.Caching.Cosmos` |
| Spring Boot data access (Java) | Spring Data Azure Cosmos DB v5 |
| Serverless frontend on Vercel | Vercel Marketplace integration |
| Native Fabric database | Cosmos DB in Microsoft Fabric |
| Write analytical results back to Cosmos DB | Reverse ETL via Spark + Delta |

The Azure ecosystem around Cosmos DB is broad, but the good news is that most of these integrations are well-tested, first-party, and follow the same patterns: configure a connection, set a throughput budget, and let the managed service handle the hard parts. The work — as always with Cosmos DB — is in choosing the right partition key, managing your RU budget, and designing your data model to support the access patterns these integrations enable. Those foundational decisions, covered in Chapters 4, 5, and 10, are what make or break any integration you wire up here.
