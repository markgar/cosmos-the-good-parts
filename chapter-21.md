# Chapter 21: Integrating with Azure Services

One of the greatest strengths of Azure Cosmos DB is how deeply it plugs into the broader Azure ecosystem—and beyond. Whether you're building event-driven microservices, running large-scale analytics, streaming IoT telemetry, or deploying a Next.js app on Vercel, there's almost certainly a first-class integration waiting for you. This chapter is a survey: we'll walk through each major integration, explain what it does, when to use it, and point you toward the right starting resources. Think of it as your integration map—you can dive deeper into whichever paths your architecture demands.

## Azure Functions

Azure Functions is the most natural companion to Cosmos DB in serverless architectures. The integration comes in three flavors: a **change feed trigger**, **input bindings**, and **output bindings**. Together, they let you build event-driven pipelines without managing any infrastructure.

### Change Feed Trigger

The Azure Functions trigger for Cosmos DB uses the change feed to listen for inserts and updates across partitions. When a document changes, the change feed stream fires your function automatically. This is the workhorse for reactive patterns—materializing views, sending notifications, replicating data to other stores, or kicking off downstream workflows. Under the hood, the trigger manages its own lease container to track progress, so multiple function instances can process the feed in parallel across partitions.

A key detail: the change feed publishes new and updated items but does **not** include deletes (unless you enable the "all versions and deletes" mode on newer SDK versions). If you need to react to deletions, consider soft-delete patterns with a TTL or the full-fidelity change feed.

The trigger is configured through your `function.json` (or attributes in .NET isolated worker) with the database name, container name, connection string setting, and a lease container for checkpoint tracking. You can tune `MaxItemsPerInvocation` to control batch sizes and `FeedPollDelay` to balance latency against cost. For high-throughput scenarios, the trigger scales horizontally across function instances, with each instance owning a subset of the change feed's physical partitions.

### HTTP Trigger with Input/Output Bindings

Beyond the change feed, you can bind Cosmos DB as an **input** or **output** on any trigger type—HTTP, timer, queue, you name it. An input binding reads a document by its `id` and partition key when the function executes. An output binding writes a document when the function completes. These bindings reuse a shared SDK client internally, so you get efficient connection pooling without managing `CosmosClient` lifecycle yourself.

```csharp
[Function("GetOrder")]
public IActionResult Run(
    [HttpTrigger(AuthorizationLevel.Anonymous, "get")] HttpRequest req,
    [CosmosDBInput(
        databaseName: "ecommerce",
        containerName: "orders",
        Id = "{Query.orderId}",
        PartitionKey = "{Query.customerId}",
        Connection = "CosmosDBConnection")] Order order)
{
    return order is not null
        ? new OkObjectResult(order)
        : new NotFoundResult();
}
```

This combination—change feed trigger for reactive processing, HTTP trigger with bindings for CRUD APIs—covers an enormous range of serverless use cases with minimal boilerplate.

## Azure Event Hubs and Kafka

When you need to stream Cosmos DB changes to downstream consumers at massive scale, **Azure Event Hubs** is a natural fit. The typical pattern is to use the Cosmos DB change feed (via Azure Functions or the Change Feed Processor) to read changes and publish them as events to an Event Hub. From there, any number of consumer groups—Spark Structured Streaming, Azure Stream Analytics, custom services—can process the events independently.

Because Event Hubs offers built-in Apache Kafka compatibility, this same approach works for Kafka consumers without any code changes. Your existing Kafka clients can connect directly to Event Hubs using the Kafka wire protocol, consuming Cosmos DB changes as if they were Kafka topics. This is particularly powerful in hybrid architectures where some teams run Kafka natively and others use Azure-native services. You get the durability and partitioning of Event Hubs with the ecosystem breadth of Kafka.

A common architecture pairs this integration with a fan-out pattern: the change feed trigger publishes events to an Event Hub with multiple consumer groups, each powering a different downstream use case—one for search index updates, another for analytics aggregation, a third for notifications. This decouples consumers from each other and from the Cosmos DB change feed's processing cadence.

## Azure Synapse Link

> **Important:** As of 2024, Azure Synapse Link for Cosmos DB is **no longer supported for new projects**. Microsoft recommends using **Fabric Mirroring** instead (covered in the next section). We include Synapse Link here because many existing deployments still use it and you may encounter it in production.

Azure Synapse Link is a cloud-native hybrid transactional/analytical processing (HTAP) capability. It enables near-real-time analytics over your operational data by automatically synchronizing documents from the transactional store into a fully isolated **analytical store**—a columnar representation optimized for analytical queries.

### How It Works

When you enable Synapse Link on a container, Cosmos DB maintains a column-oriented copy of your data alongside the row-oriented transactional store. This "autosync" process runs continuously with no ETL jobs or change feed processors required. You then query the analytical store directly from **Azure Synapse Analytics** using either **Synapse Apache Spark** (Scala, Python, SparkSQL, C#) or **serverless SQL pools** (T-SQL). Analytical queries hit the columnar store exclusively, so they never consume RU/s or affect your transactional workload's performance.

### When to Use It (on Existing Deployments)

Synapse Link excels when you need to run BI dashboards, machine learning training, or ad-hoc exploration over large operational datasets without building and maintaining ETL pipelines. The analytical store follows consumption-based pricing—you pay for storage and analytical read/write operations, not provisioned throughput. However, be aware of limitations: it supports only NoSQL, MongoDB, and Gremlin APIs, and it doesn't work with dedicated SQL pools.

If you're starting a new project today, skip Synapse Link and go directly to Fabric Mirroring.

## Microsoft Fabric Mirroring

**Fabric Mirroring** is the successor to Synapse Link and is now the recommended approach for analytical replication of Cosmos DB data. It provides a seamless, no-ETL experience that continuously replicates your Azure Cosmos DB data into Microsoft Fabric's OneLake in Delta Parquet format.

### Near-Real-Time Analytical Replication

Like Synapse Link, mirroring creates a complete analytical replica with workload isolation—your transactional RU/s are unaffected. But unlike Synapse Link, mirrored data lands directly in OneLake, making it immediately available to the full Fabric suite: Spark notebooks, SQL analytics endpoints, Power BI, Data Science experiences, Real-Time Intelligence, and more. There's no need to configure separate analytical store settings on each container; mirroring handles replication at the account level.

### Migrating from Synapse Link

If you're currently using Synapse Link, Microsoft provides a migration path to Fabric Mirroring. The key steps are: enable mirroring on your Cosmos DB account in the Fabric portal, validate that your data is flowing into OneLake correctly, migrate your Spark and SQL analytics workloads to Fabric equivalents, and then disable Synapse Link. Since both approaches use the same underlying change feed mechanism, the transition is relatively smooth.

## Azure Data Factory

**Azure Data Factory (ADF)** is the go-to service for bulk import and export of Cosmos DB data. The Cosmos DB for NoSQL connector in ADF supports both source and sink operations, enabling scenarios like:

- Importing JSON documents from Azure Blob Storage, Data Lake Store, or other relational databases into Cosmos DB.
- Exporting Cosmos DB documents to Blob Storage, Data Lake, SQL databases, or other destinations.
- Copying documents between Cosmos DB collections as-is.

ADF leverages the Cosmos DB bulk executor internally, so large-scale migrations can be tuned for throughput by adjusting the write batch size and provisioned RU/s. You can also use ADF's **data flows** to apply transformations—filtering, flattening nested structures, joining with reference data—during the copy operation. For one-time migrations or periodic batch exports (for example, nightly snapshots to a data lake), ADF is often the simplest path. For ongoing, real-time replication, you'd reach for the change feed or Fabric Mirroring instead.

One practical tip: when importing into Cosmos DB via ADF, temporarily scale up your container's throughput (or use autoscale) for the duration of the import, then scale back down. ADF's copy activity reports the RU consumption, so you can monitor and adjust in near real time. Also consider setting the write behavior to "upsert" if your source data might contain duplicates—this avoids 409 Conflict errors and makes re-runs idempotent.

## Azure Kubernetes Service and App Service

Cosmos DB works naturally with both **Azure Kubernetes Service (AKS)** and **Azure App Service** as the data layer for containerized and web applications.

### AKS Patterns

In AKS, the most common pattern is to connect your pods to Cosmos DB using the .NET, Java, Python, or Node.js SDK via **Service Connector** or direct environment variable configuration. Service Connector simplifies authentication by wiring up managed identities or connection strings as Kubernetes secrets. For microservices architectures, each service typically owns its own Cosmos DB container (or set of containers), and you use the SDK's built-in retry and connection pooling. The key AKS-specific consideration is configuring the SDK's `Direct` connectivity mode for lowest latency, and ensuring your pods are in the same Azure region as your Cosmos DB endpoint.

### App Service Patterns

With App Service, the story is similar: configure your Cosmos DB connection string in **Application Settings** (or use Key Vault references), and use the SDK directly. Azure App Service also supports **Service Connector** for managed identity-based authentication. For Java apps on App Service, you can use Spring Data Azure Cosmos DB (covered later in this chapter) for a higher-level abstraction.

## Azure IoT Hub

For IoT scenarios, the typical architecture routes device telemetry from **Azure IoT Hub** through to Cosmos DB for storage and querying. IoT Hub supports **message routing** to various endpoints, and while it doesn't have a direct Cosmos DB endpoint built-in, the standard pattern is to route messages to an Event Hub (or the built-in Event Hub-compatible endpoint) and then use Azure Functions with a Cosmos DB output binding to persist the telemetry.

An alternative pattern uses **Azure Stream Analytics** as the processing layer between IoT Hub and Cosmos DB. Stream Analytics can ingest directly from IoT Hub, apply windowed aggregations or anomaly detection, and write results to Cosmos DB as an output sink. This approach is especially well-suited for time-series telemetry where you want to downsample or enrich data before storage. You can partition your Cosmos DB container by device ID and use a time-based property for efficient range queries over historical telemetry.

## Azure AI Search

**Azure AI Search** (formerly Azure Cognitive Search) provides a built-in **indexer** that crawls your Cosmos DB container and populates a search index. This is the fastest path to adding full-text search, faceted navigation, filtering, and AI-powered semantic ranking on top of your Cosmos DB data.

The indexer connects to your Cosmos DB container, reads documents via the SQL query API, and maps fields to your search index schema. It supports **incremental indexing** by tracking changes using the document's `_ts` (timestamp) property, so subsequent runs only process new and modified documents. You can also configure a **soft-delete detection policy** to handle deletions.

For more advanced scenarios, you can attach **skillsets** to the indexer pipeline—for example, running OCR on image fields, extracting key phrases, or generating vector embeddings for hybrid search. This combination of Cosmos DB as the operational store and AI Search as the query layer is a powerful pattern for e-commerce catalogs, knowledge bases, and RAG (Retrieval-Augmented Generation) applications.

The indexer runs on a configurable schedule (as frequently as every five minutes) or can be triggered on-demand via the REST API. For large containers, the initial full crawl may take time, but incremental runs are fast because the indexer tracks a high-water mark using the `_ts` property. If your application needs sub-second search freshness, consider supplementing the indexer with a push-based approach using the Azure Search SDK to index documents directly from your change feed processor.

## Azure Stream Analytics

**Azure Stream Analytics** can read from Cosmos DB's change feed as an input and can write to Cosmos DB as an output—or both. As an **output sink**, Stream Analytics writes JSON documents directly to a specified container, making it straightforward to persist the results of real-time stream processing. You configure the database name, container name, and partition key in the output definition.

As a processing engine, Stream Analytics sits between event sources (IoT Hub, Event Hubs, Blob Storage) and Cosmos DB, enabling you to apply SQL-like windowed queries, temporal joins, anomaly detection, and pattern matching over streaming data before landing results in Cosmos DB. The output connector supports both `insert` and `upsert` write modes—use upsert when you're updating running aggregates or maintaining a materialized view that gets refreshed as new events arrive.

## Apache Spark Connector (OLTP)

The **Azure Cosmos DB Spark OLTP Connector** enables batch and streaming workloads between Spark and Cosmos DB's transactional store. This is distinct from the Synapse Link analytical store path—the OLTP connector reads and writes directly against the transactional store, consuming RU/s.

Use cases include:

- **Batch reads**: Loading Cosmos DB data into Spark DataFrames for ETL processing, machine learning training, or transformation before writing to Delta Lake.
- **Batch writes**: Performing reverse ETL—pushing enriched or aggregated data from a Lakehouse back into Cosmos DB for low-latency serving.
- **Structured Streaming**: Using Spark Structured Streaming with the change feed to incrementally process Cosmos DB changes.

The connector is available as a Maven package for Spark on Azure Databricks, Synapse Spark, or Fabric Spark. Configuration is straightforward—you provide the endpoint, key, database, and container, and Spark handles parallelism across physical partitions. Be mindful of RU consumption during large batch reads; consider using the analytical store (via Synapse Link or Fabric Mirroring) for heavy analytical workloads to avoid impacting transactional performance.

## Kafka Connect for Cosmos DB

If your organization runs Apache Kafka—whether self-hosted, on Confluent Cloud, or via Azure Event Hubs—the **Kafka Connect connectors for Cosmos DB** provide a managed way to stream data bidirectionally.

### Source and Sink Connectors

The **source connector** reads the Cosmos DB change feed and publishes changes to Kafka topics. The **sink connector** consumes Kafka topics and writes records to Cosmos DB containers. Both connectors support Plain JSON, JSON with schema, and Avro serialization formats.

### V1 vs. V2

There are two connector generations. **V1** (the `kafka-connect-cosmosdb` package from Microsoft's GitHub) offers at-least-once semantics for multi-task source connectors and exactly-once for the sink. **V2** (the `azure-cosmos-kafka-connect` package in the Azure SDK for Java) supports **exactly-once** semantics for both source and sink, requires Kafka 3.6.0+, and is the recommended choice for new deployments. V2 also aligns with the latest Azure Cosmos DB Java SDK for improved performance and reliability.

Configuration for both versions revolves around the `topicmap` property (mapping Kafka topics to Cosmos DB containers), the account endpoint, and the authentication key. A typical deployment pairs the source connector with a Kafka Streams or Flink application for real-time enrichment, and the sink connector for writing processed results back to Cosmos DB.

When choosing between the Kafka Connect connectors and the Event Hubs Kafka integration, consider your operational model. If you already run a Kafka Connect cluster and want change-feed-to-topic replication without custom code, the Kafka connectors are the better fit. If you're looking for a managed service and don't want to manage connector infrastructure, the Event Hubs + Functions approach from earlier in this chapter may be simpler.

## Spring Data Azure Cosmos DB

For Java developers building Spring Boot applications, **Spring Data Azure Cosmos DB** provides a first-class repository abstraction over Cosmos DB for NoSQL. The `spring-cloud-azure-starter-data-cosmos` dependency brings auto-configuration, connection management, and the familiar Spring Data repository pattern.

You define an entity class annotated with `@Container`, create a repository interface extending `ReactiveCosmosRepository` (or `CosmosRepository` for blocking I/O), and Spring Data generates the implementation at runtime. Derived query methods like `findByFirstName(String firstName)` translate directly to Cosmos DB SQL queries.

```java
@Repository
public interface UserRepository extends ReactiveCosmosRepository<User, String> {
    Flux<User> findByFirstName(String firstName);
}
```

The current library version (azure-spring-data-cosmos v6.x, via the spring-cloud-azure BOM v5.x) supports Spring Boot 3.x and Spring Data Commons, with version mapping guidance in the official documentation. For production deployments, configure direct-mode connectivity, preferred regions, and diagnostics thresholds in your `application.properties`. This integration is the recommended approach for Java microservices on Azure, whether running on App Service, AKS, or Azure Spring Apps.

## ASP.NET Session State and Cache Provider

For ASP.NET and ASP.NET Core applications, Cosmos DB can serve as a **distributed session state and caching provider** via the `Microsoft.Extensions.Caching.Cosmos` NuGet package. This package implements the `IDistributedCache` interface, so it's a drop-in replacement for Redis, SQL Server, or in-memory caches in your middleware pipeline.

The provider uses a dedicated Cosmos DB container to store session data, with each session entry as a document. It supports sliding and absolute expiration policies natively through Cosmos DB's TTL feature. The primary advantage over Redis is operational simplicity when you're already running Cosmos DB: you avoid standing up and managing a separate cache cluster. It's especially appealing for applications that need globally distributed session state, leveraging Cosmos DB's multi-region writes to keep sessions close to users worldwide. That said, for ultra-low-latency, high-throughput caching workloads, Redis may still edge ahead on raw performance.

## Cosmos DB in Microsoft Fabric (Native Database)

Beyond mirroring an external Azure Cosmos DB account, Microsoft Fabric now offers **Cosmos DB as a native Fabric database**. This is not merely a replication target—it's a fully functional NoSQL database running the same Cosmos DB engine and infrastructure, but provisioned and managed entirely within the Fabric portal.

### What Makes It Different

Cosmos DB in Fabric uses **Fabric capacity units (CUs)** instead of Azure RU/s for billing, relies exclusively on **Microsoft Entra ID** authentication (no primary/secondary keys), and comes with autonomous defaults that eliminate most tuning decisions. Data is automatically surfaced in OneLake in Delta Parquet format, so your operational data is immediately available for analytics, Power BI reports, data science notebooks, and cross-database queries—all with zero ETL.

### When to Use It

Choose Cosmos DB in Fabric when you're building new applications within the Fabric ecosystem and want a unified experience for both transactional and analytical workloads. It's ideal for teams that want to avoid managing a separate Azure Cosmos DB account and prefer Fabric's simplified operational model. Existing applications can connect using the same Cosmos DB SDKs (.NET, Java, Python, Node.js) pointed at the Fabric endpoint, with Microsoft Entra authentication. Built-in AI capabilities—vector search, full-text search, and hybrid search with Reciprocal Rank Fusion—make it a strong foundation for AI-powered applications.

## Vercel Integration

For frontend developers deploying Next.js, React, or other frameworks on **Vercel**, Azure Cosmos DB offers a first-party integration through the [Vercel Integrations Marketplace](https://vercel.com/integrations/azurecosmosdb). The integration automates the connection setup: it provisions (or connects to) a Cosmos DB account and injects the `COSMOSDB_CONNECTION_STRING`, `COSMOSDB_DATABASE_NAME`, and `COSMOSDB_CONTAINER_NAME` environment variables directly into your Vercel project.

You can also bootstrap a project from the command line using the Next.js starter template:

```bash
npx create-next-app --example with-azure-cosmos with-azure-cosmos-app
```

The starter template includes a `lib/cosmosdb.ts` file that initializes the `@azure/cosmos` JavaScript client, giving you a working Cosmos DB connection out of the box. This integration supports both NoSQL and MongoDB API accounts. For developers building full-stack serverless applications, the Vercel + Cosmos DB combination provides global edge deployment paired with a globally distributed database—a strong foundation for low-latency user experiences worldwide.

A marketplace template is also available—the **Azure Cosmos DB Next.js Starter**—which scaffolds a complete project with guided configuration. You clone it, set the integration to wire up your connection keys, provide the database and container names, and hit deploy. Within minutes you have a globally deployed full-stack app backed by Cosmos DB.

## Integration Summary

The table below maps each integration to its primary use case, giving you a quick reference for architecture decisions:

| Integration | Primary Use Case |
|---|---|
| **Azure Functions (Change Feed Trigger)** | Event-driven serverless processing of data changes |
| **Azure Functions (Input/Output Bindings)** | Serverless CRUD APIs and data pipelines |
| **Azure Event Hubs / Kafka** | High-throughput streaming of changes to downstream consumers |
| **Azure Synapse Link** | Zero-ETL HTAP analytics (legacy; use Fabric Mirroring for new projects) |
| **Microsoft Fabric Mirroring** | Near-real-time analytical replication to OneLake and the Fabric suite |
| **Azure Data Factory** | Bulk import/export and batch ETL pipelines |
| **AKS / App Service** | Application hosting with SDK-based Cosmos DB connectivity |
| **Azure IoT Hub** | Device telemetry ingestion routed to Cosmos DB |
| **Azure AI Search** | Full-text search, faceted navigation, and AI enrichment over Cosmos DB data |
| **Azure Stream Analytics** | Real-time windowed aggregation and pattern matching with Cosmos DB output |
| **Apache Spark OLTP Connector** | Batch and streaming Spark workloads against the transactional store |
| **Kafka Connect (V1/V2)** | Bidirectional Kafka ↔ Cosmos DB data streaming |
| **Spring Data Azure Cosmos DB** | Spring Boot repository pattern for Java microservices |
| **ASP.NET Session State / Cache** | Distributed session and caching via `IDistributedCache` |
| **Cosmos DB in Fabric (Native)** | Unified transactional + analytical NoSQL database within Fabric |
| **Vercel Integration** | Serverless full-stack apps with automated connection setup |

## What's Next

You've now seen how Cosmos DB connects to the broader Azure ecosystem and key third-party platforms. In **Chapter 22**, we'll tackle **migrating to Cosmos DB** — assessing your current workload for Cosmos DB fit, converting vCores to Request Units, migrating from relational and other NoSQL databases, using the desktop data migration tool, planning cutover strategies, and running server-side container copy jobs.
