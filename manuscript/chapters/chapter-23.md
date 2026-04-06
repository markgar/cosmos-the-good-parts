# Chapter 23: Migrating to Cosmos DB

Nobody migrates a database for fun. You migrate because the current system can't keep up — it doesn't scale, it costs too much to operate, it can't reach users in other regions, or it's holding your team back from shipping. The good news is that getting data *into* Cosmos DB is a well-trodden path. The bad news is that the migration itself is the easy part. The hard part is everything around it: deciding what to move, reshaping data models, estimating throughput, and cutting over without losing data or sleep.

This chapter covers the full migration lifecycle. We'll start with assessing whether Cosmos DB is the right target, work through the tooling for relational and NoSQL source databases, and finish with the cutover strategies that keep your application running while you swap out the data layer underneath it.

## Assessing Your Current Workload for Cosmos DB Fit

Before you plan a migration, step back and ask a harder question: should you migrate this workload at all?

Not every application benefits from Cosmos DB. We covered the decision framework in Chapter 1, but during a migration assessment you need to get more specific. Walk through your current workload and score it against these criteria:

**Access patterns.** Cosmos DB excels at point reads by `id` + partition key and targeted queries within a single logical partition. If your workload is dominated by these patterns — session lookups, user profile fetches, order retrieval by customer — you're in good shape. If your workload relies on ad-hoc multi-table joins, full-table scans, or complex aggregations, you'll be fighting the engine.

**Data relationships.** Count the foreign key relationships in your schema. One-to-few relationships (an order with a handful of line items) embed beautifully into documents. One-to-many relationships where the "many" side is unbounded (a user with millions of activity log entries) require a different partition strategy. Many-to-many relationships need reference documents and application-side joins. If your ER diagram looks like a spider web, that's a warning sign — not a deal-breaker, but a signal that the modeling work (Chapter 4) will be substantial.

**Throughput characteristics.** Is the load steady or spiky? How much read vs. write? Cosmos DB handles both patterns well, but the capacity mode you choose (provisioned, autoscale, or serverless — covered in Chapter 11) depends on the answer. Gather your current IOPS, CPU utilization, and peak request rates. You'll need them for the next step.

**Latency requirements.** If you need single-digit millisecond reads at the 99th percentile, Cosmos DB delivers that with an SLA. If your current latency target is "under 500 ms and nobody cares," you might be overpaying for Cosmos DB's guarantees. <!-- Source: high-availability/global-distribution/distribute-data-globally.md -->

**Compliance and residency.** Cosmos DB supports data residency with per-region control. If your data must stay in specific geographies, verify that the required Azure regions are available before you commit. <!-- Source: high-availability/global-distribution/distribute-data-globally.md -->

## Converting vCores to Request Units

The first concrete question every migration team asks: "We have X vCores today — how many RU/s do we need?"

Microsoft provides a formula based on experience with thousands of migrations. For the NoSQL API: <!-- Source: throughput-request-units/convert-vcore-to-request-unit.md -->

```
Provisioned RU/s = C × T / R
```

Where:

| Variable | Meaning |
|----------|---------|
| **T** | Total vCores across replicas |
| **R** | Replication factor |
| **C** | 600 RU/s per vCore (NoSQL) |

The formula accounts for the fact that Cosmos DB handles its own replication (with a 4× replication factor internally), so you divide out the replication you're already paying for in your source system. If you don't know your replication factor, use **R = 3** as a reasonable default. <!-- Source: throughput-request-units/convert-vcore-to-request-unit.md -->

### Worked Example

Say you're running a sharded cluster with three replica sets, each using four-core servers and a replication factor of 3:

- **T** = 3 replica sets × 3 replicas × 4 cores = 36 vCores
- **R** = 3

```
Provisioned RU/s = 600 × 36 / 3 = 7,200 RU/s
```

Here's a quick reference table for common configurations (assuming R = 3): <!-- Source: throughput-request-units/convert-vcore-to-request-unit.md -->

| Total vCores | Estimated RU/s (NoSQL API) |
|-------------|---------------------------|
| 3 | 600 |
| 6 | 1,200 |
| 12 | 2,400 |
| 24 | 4,800 |
| 48 | 9,600 |
| 96 | 19,200 |
| 192 | 38,400 |
| 384 | 76,800 |

**A critical nuance for cloud-managed databases:** many managed services advertise a vCore count that's actually per-replica, not total. If your managed database says "4 vCores" but runs a three-node replica set behind the scenes, your true T is 12, not 4. Check the fine print. <!-- Source: throughput-request-units/convert-vcore-to-request-unit.md -->

### The Capacity Planner

The vCore formula gives you a rough starting point. For a more precise estimate, use the **Azure Cosmos DB Capacity Planner** at [cosmos.azure.com/capacitycalculator](https://cosmos.azure.com/capacitycalculator/). <!-- Source: throughput-request-units/provisioned-throughput/estimate-ru-with-capacity-planner.md -->

The planner has two modes:

- **Basic mode** — plug in your item size, expected point reads/sec, creates/sec, updates/sec, queries/sec, and number of regions. It gives you a ballpark RU/s and monthly cost estimate.
- **Advanced mode** — requires signing in, but lets you tune indexing policy, consistency level, workload variability (steady vs. spiky), and upload sample JSON documents for more accurate item size estimates.

The advanced mode is worth the extra effort for production migrations. Upload a representative sample document and set your consistency level to whatever you plan to use — **Strong** and **Bounded Staleness** require roughly double the read RU/s compared to **Session**, **Consistent Prefix**, or **Eventual**. <!-- Source: throughput-request-units/provisioned-throughput/estimate-ru-with-capacity-planner.md -->

Both tools are estimates. After migration, you'll tune based on real metrics (Chapter 18 covers monitoring). Start with the estimate, provision with autoscale to absorb the initial load, and right-size once you have production telemetry.

## Migrating from Relational Databases

Relational migrations — from SQL Server, PostgreSQL, or similar — are the most common and the most work. The data movement is the easy part. The hard part is rethinking your schema.

### Rethinking the Schema

A relational database stores an `Orders` table and an `OrderDetails` table with a foreign key between them. A Cosmos DB container stores an order document with its line items embedded as an array. That shift — from normalized, join-dependent tables to denormalized, self-contained documents — is the central challenge of a relational migration.

We covered the modeling principles in depth in Chapter 4: when to embed vs. reference, the one-to-few sweet spot for embedding, and the gotchas of unbounded arrays. Here, we'll focus on the migration-specific advice:

**Map your joins to embedding candidates.** For every JOIN in your most common queries, ask: could this child data be embedded in the parent document? If the relationship is one-to-few (an order with 5–20 line items), embedding almost always wins. If it's one-to-thousands, you need a reference pattern.

**Don't try to migrate table-for-table.** The worst thing you can do is create one Cosmos DB container per SQL table and try to join them at the application level. You'll pay more RU/s, get worse latency, and hate every minute of it. Invest the time to design your document model *before* you move a single row.

**Prototype with a subset first.** Microsoft's own migration guidance recommends migrating a subset of data first to validate partition key choice, query performance, and data modeling before committing to a full migration. <!-- Source: migrate-data/migrate.md -->

### One-to-Few Patterns with Azure Data Factory

For straightforward relational-to-document transformations, **Azure Data Factory** (ADF) is the standard tool. The trick is getting the nested JSON right, because ADF's copy activity can't directly produce nested arrays from a SQL JOIN in a single step. <!-- Source: migrate-data/migrate-relational-data.md -->

The proven pattern uses a two-step pipeline:

**Step 1: SQL to blob as JSON.** Use a SQL query with `FOR JSON PATH` and `OPENJSON` to produce one JSON object per row, with child records embedded as arrays. Write the output to Azure Blob Storage as a text file.

```sql
SELECT [value] FROM OPENJSON(
  (SELECT
    id = o.OrderID,
    o.OrderDate,
    o.FirstName,
    o.LastName,
    o.Address,
    o.City,
    o.State,
    o.PostalCode,
    o.Country,
    o.Phone,
    o.Total,
    (SELECT OrderDetailId, ProductId, UnitPrice, Quantity
     FROM OrderDetails od
     WHERE od.OrderId = o.OrderId
     FOR JSON AUTO) AS OrderDetails
   FROM Orders o FOR JSON PATH)
)
```

<!-- Source: migrate-data/migrate-relational-data.md -->

**Step 2: Blob to Cosmos DB.** A second ADF copy activity reads the JSON text file from Blob Storage and writes directly to Cosmos DB as properly structured documents.

The intermediate blob step is a workaround for ADF's inability to produce nested JSON in a single copy activity. It's inelegant but reliable. If you're already comfortable with ADF from Chapter 22's integration coverage, this is familiar territory.

### Azure Databricks for Complex Transformations

When your transformation logic goes beyond what SQL `FOR JSON` can express — conditional embedding, data enrichment from multiple sources, type conversions, deduplication — **Azure Databricks** gives you the full power of Spark.

The pattern works in both Scala and Python. Here's the Python approach: <!-- Source: migrate-data/migrate-relational-data.md -->

1. Read from your source database using JDBC into a Spark DataFrame.
2. Read child tables into separate DataFrames.
3. Join, transform, and nest the data programmatically using Spark's `struct` and `array` functions.
4. Write the result to Cosmos DB using the **Azure Cosmos DB Spark connector**.

```python
# Read orders and order details from SQL Server
orders = spark.read.jdbc(url=jdbc_url, table="Orders",
                         properties=connection_properties)
details = spark.read.jdbc(url=jdbc_url, table="OrderDetails",
                          properties=connection_properties)

# Group details by OrderId and collect as array
from pyspark.sql.functions import collect_list, struct

nested_details = details.groupBy("OrderId").agg(
    collect_list(
        struct("OrderDetailId", "ProductId", "UnitPrice", "Quantity")
    ).alias("OrderDetails")
)

# Join and write to Cosmos DB
orders_with_details = orders.join(nested_details, "OrderId", "left")
orders_with_details.write \
    .format("cosmos.oltp") \
    .options(**write_config) \
    .mode("append") \
    .save()
```

Databricks is the better choice when you need to process large datasets (hundreds of GB to TB), your transformation logic is complex, or your source database isn't SQL Server (PostgreSQL, MySQL, Oracle all work via JDBC).

## Migrating from Other NoSQL Databases

NoSQL-to-Cosmos DB migrations are structurally simpler because the data is already document-shaped (or close to it). The challenge shifts from schema transformation to mapping concepts and refactoring application code.

### DynamoDB to Cosmos DB

DynamoDB is the most common source for AWS-to-Azure migrations. Microsoft documents two distinct tracks: **data migration** (getting the bits across) and **application migration** (rewriting the data access layer). <!-- Source: migrate-data/dynamodb-data-migration-cosmos-db.md, migrate-data/dynamo-to-cosmos.md -->

**Concept mapping first.** The terminology shift is straightforward:

| DynamoDB | Cosmos DB |
|----------|-----------|
| Table | Container |
| Item | Document |
| Partition key (HASH) | Partition key |
| Sort key (RANGE) | Composite index |
| Read/Write Capacity Units | Request Units (RU/s) |
| Streams | Change feed |
| Global Tables | Multi-region writes |

- **Sort key → composite index:** Cosmos DB doesn't require a sort key. Use composite indexes for sorted queries.
- **Capacity units → RUs:** A single RU currency covers both reads and writes.
- **Global Tables → multi-region writes:** Configured at the account level.

<!-- Source: migrate-data/dynamo-to-cosmos.md -->

One difference that catches people: DynamoDB has separate read and write capacity units. Cosmos DB has a single **Request Unit** currency that's fungible — the same RU/s budget serves both reads and writes. That actually simplifies capacity planning.

**Data migration — the offline path.** The recommended approach uses a three-stage pipeline: <!-- Source: migrate-data/dynamodb-data-migration-cosmos-db.md -->

1. **Export from DynamoDB to S3** using DynamoDB's built-in export feature (DynamoDB JSON format).
2. **Transfer S3 → Azure Data Lake Storage Gen2** using an Azure Data Factory pipeline.
3. **Transform and load into Cosmos DB** using Spark on Azure Databricks with the Cosmos DB Spark connector.

The Databricks step handles the DynamoDB-specific JSON format (which wraps every attribute in a type descriptor like `{"S": "value"}`) and flattens it into clean Cosmos DB documents.

**Data migration — the online path.** If you can't afford downtime, use DynamoDB Streams or Kinesis Data Streams as a CDC source. Process the stream with Lambda or Flink and write to Cosmos DB in near real-time. This requires custom code and careful handling of ordering guarantees. <!-- Source: migrate-data/dynamodb-data-migration-cosmos-db.md -->

**Application migration.** The code changes are more mechanical than you'd expect. DynamoDB's `PutItem` becomes `CreateItemAsync`. `GetItem` with a hash+range becomes a point read with `id` + partition key. The Cosmos DB SDK provides type safety via POCOs or model classes — no more casting `AttributeValue` objects. The biggest code-level win is that Cosmos DB queries use SQL syntax, so range scans that required `ScanRequest` in DynamoDB become straightforward `SELECT ... WHERE ... BETWEEN` queries. <!-- Source: migrate-data/dynamo-to-cosmos.md -->

### Couchbase to Cosmos DB

Couchbase migrations are conceptually the simplest because both databases store JSON documents. The mapping is: <!-- Source: migrate-data/couchbase-cosmos-migration.md -->

| Couchbase | Cosmos DB |
|-----------|-----------|
| Couchbase server | Account |
| Bucket | Database |
| Bucket (also) | Container |
| JSON Document | Item |

The structural difference that matters: Couchbase stores the document ID externally (as metadata on the bucket), while Cosmos DB requires an `id` field *inside* the document. Your migration pipeline needs to inject the Couchbase document ID into each document's `id` property. <!-- Source: migrate-data/couchbase-cosmos-migration.md -->

Couchbase's top-level collection wrapper (a type-discriminator envelope around the actual data) can also be flattened. In Couchbase you might have `{"TravelDocument": {"Country": "India", ...}}`. In Cosmos DB, the container name provides the context, so the document becomes `{"id": "99FF4444", "Country": "India", ...}` — simpler and cheaper to store. <!-- Source: migrate-data/couchbase-cosmos-migration.md -->

**Query translation.** Couchbase N1QL queries translate to Cosmos DB SQL with a few adjustments. The `META().id` accessor becomes the `c.id` property. The `ANY ... SATISFIES` pattern becomes a `JOIN` on a subdocument. `LIMIT ... OFFSET` order is reversed — Cosmos DB uses `OFFSET` first, then `LIMIT`. <!-- Source: migrate-data/couchbase-cosmos-migration.md -->

**Data transfer.** Azure Data Factory with a Couchbase source connector and Cosmos DB sink is the recommended approach for bulk data transfer. <!-- Source: migrate-data/couchbase-cosmos-migration.md -->

### HBase to Cosmos DB

HBase is the most architecturally different source you'll encounter. It's a wide-column store built on HDFS, organized by RowKey and Column Families. The mapping to Cosmos DB requires flattening the column family structure into JSON properties. <!-- Source: migrate-data/migrate-hbase.md -->

| HBase | Cosmos DB |
|-------|-----------|
| Cluster | Account |
| Namespace | Database |
| Table | Container |
| Row (RowKey) | Item |
| Column Family | Flattened into properties |
| Version (Timestamp) | Use change feed instead |

<!-- Source: migrate-data/migrate-hbase.md -->

**The RowKey trap.** HBase sorts data by RowKey and distributes it via range partitioning. Cosmos DB hash-distributes by partition key. Using the same RowKey as your partition key typically won't give optimal performance. Spend time designing your partition key separately — the principles from Chapter 5 apply in full. <!-- Source: migrate-data/migrate-hbase.md -->

**Migration tooling.** For HBase versions before 2.0, Azure Data Factory has a built-in HBase connector. For HBase 2.0+, use Apache Spark with the HBase Connector to read data into DataFrames, then write to Cosmos DB via the Spark connector. <!-- Source: migrate-data/migrate-hbase.md -->

| Approach | Version | Best For |
|----------|---------|----------|
| Azure Data Factory | < 2.0 | Large datasets, low-code |
| Spark (HBase + Cosmos) | All | Complex transforms |
| Custom bulk executor | All | Max flexibility |

<!-- Source: migrate-data/migrate-hbase.md -->

If you're running Apache Phoenix on your HBase cluster, gather your Phoenix table schemas, indexes, and primary key definitions before starting. These inform your Cosmos DB container design and indexing policy. <!-- Source: migrate-data/migrate-hbase.md -->

## The Desktop Data Migration Tool

The **Azure Cosmos DB Desktop Data Migration Tool** (commonly called `dmt`) is an open-source, command-line utility for moving data into and out of Cosmos DB. It's the Swiss Army knife for smaller migrations, testing, and one-off data loading. <!-- Source: migrate-data/how-to-migrate-desktop-tool.md -->

The tool is built on an extension model — sources and sinks are pluggable. Current extensions support: <!-- Source: migrate-data/how-to-migrate-desktop-tool.md -->

| Sources | Sinks |
|---------|-------|
| Azure Cosmos DB for NoSQL | Azure Cosmos DB for NoSQL |
| JSON files | Azure Cosmos DB for Table |
| CSV files | Azure AI Search |
| MongoDB | |
| SQL Server | |
| PostgreSQL | |
| Azure Blob Storage | |
| Parquet files | |
| AWS S3 | |

### Running dmt

The tool requires **.NET 8.0** or later. You can download a prebuilt binary from the [GitHub releases page](https://github.com/azurecosmosdb/data-migration-desktop-tool/releases) for Windows, macOS, or Linux (x64 and ARM64). There's also a Docker image: <!-- Source: migrate-data/how-to-migrate-desktop-tool.md -->

```bash
docker pull mcr.microsoft.com/azurecosmosdb/linux/azure-cosmos-dmt:latest
```

Configuration lives in a `migrationsettings.json` file:

```json
{
    "Source": "JSON",
    "Sink": "Cosmos-nosql",
    "SourceSettings": {
        "FilePath": "/data/products.json"
    },
    "SinkSettings": {
        "ConnectionString": "AccountEndpoint=https://myaccount.documents.azure.com:443/;AccountKey=...",
        "Database": "inventory",
        "Container": "products",
        "PartitionKeyPath": "/categoryId",
        "RecreateContainer": false,
        "IncludeMetadataFields": false
    }
}
```

<!-- Source: migrate-data/how-to-migrate-desktop-tool.md -->

Run it:

```bash
dmt run --settings migrationsettings.json
```

Or with Docker:

```bash
docker run -v $(pwd)/config:/config -v $(pwd)/data:/data \
  mcr.microsoft.com/azurecosmosdb/linux/azure-cosmos-dmt:latest \
  run --settings /config/migrationsettings.json
```

<!-- Source: migrate-data/how-to-migrate-desktop-tool.md -->

### Batch Operations

A single `migrationsettings.json` can define multiple migration operations using the `Operations` array. This is useful when migrating multiple tables or collections in one run: <!-- Source: migrate-data/how-to-migrate-desktop-tool.md -->

```json
{
  "Source": "json",
  "Sink": "cosmos-nosql",
  "SinkSettings": {
    "ConnectionString": "AccountEndpoint=https://myaccount.documents.azure.com:443/;AccountKey=..."
  },
  "Operations": [
    {
      "SourceSettings": { "FilePath": "products.json" },
      "SinkSettings": {
        "Database": "StoreDB",
        "Container": "products",
        "PartitionKeyPath": "/categoryId"
      }
    },
    {
      "SourceSettings": { "FilePath": "customers.json" },
      "SinkSettings": {
        "Database": "StoreDB",
        "Container": "customers",
        "PartitionKeyPath": "/customerId"
      }
    }
  ]
}
```

<!-- Source: migrate-data/how-to-migrate-desktop-tool.md -->

The `dmt` tool is ideal for development workflows, proof-of-concept migrations, and moving small-to-medium datasets (up to tens of GB). For production migrations at scale, use ADF or Databricks — they offer checkpointing, parallelism, and monitoring that `dmt` doesn't.

## Assessing Migration Readiness

You might expect a single "migration assessment tool" that scores your workload and tells you whether Cosmos DB is a good fit. As of this writing, there isn't a standalone first-party tool dedicated to that purpose. What you *do* have is a set of tools and practices that, combined, give you a thorough assessment:

1. **The Capacity Planner and vCore-to-RU formula** — both covered earlier in this chapter — give you throughput and cost estimates from your workload profile or existing hardware specs.
2. **Proof-of-concept validation** — migrate a subset of data, run your most critical queries, and measure actual RU consumption. This is the most reliable "assessment" and it's what Microsoft recommends. <!-- Source: migrate-data/migrate.md -->
3. **Partner ecosystem** — Microsoft maintains a list of migration partners (Striim, Pragmatic Works, Altoros, and others) who offer assessment services and tooling for large-scale migrations. <!-- Source: resources/partners-migration.md -->

If a dedicated assessment tool ships after this book's publication, check Microsoft's migration documentation for the latest.

## Cutover Strategies

You've transformed your data, validated your model, tested your queries. Now comes the hardest part: switching production traffic from the old database to Cosmos DB without dropping requests or losing data.

There are two primary strategies, and they're not mutually exclusive.

### Blue/Green Migration

In a blue/green migration, you run your old system (blue) and your new Cosmos DB system (green) in parallel. Traffic is routed to blue while you migrate data to green. Once the data is fully synchronized and validated, you flip traffic to green — typically by updating a DNS record, load balancer target, or feature flag.

The process:

1. **Provision your Cosmos DB environment** with the target containers, indexing policies, and throughput.
2. **Perform a bulk data migration** from the source database to Cosmos DB using one of the tools covered in this chapter.
3. **Keep the source as the system of record** during migration. All writes continue hitting the old database.
4. **Validate.** Compare document counts, run key queries against both systems, verify data integrity.
5. **Switch.** Route traffic to Cosmos DB. The old system becomes a fallback.
6. **Monitor and soak.** Watch error rates, latency percentiles, and RU consumption for at least 24–48 hours.
7. **Decommission** the old system once you're confident.

Blue/green is the lowest-risk strategy when you can tolerate a brief period of read-only operation on the source during final sync. If your application requires zero downtime and continuous writes, you need dual-write.

### Dual-Write Pattern

In a dual-write migration, your application writes to *both* the old database and Cosmos DB simultaneously during the transition period. Reads gradually shift from the old system to Cosmos DB as confidence grows.

The implementation typically uses one of these approaches:

- **Application-level dual-write.** Your application code writes to both databases on every mutation. Simple to understand, but you need to handle failures carefully — if the Cosmos DB write succeeds but the legacy write fails (or vice versa), you have an inconsistency. Wrap both writes in a retry-aware pattern and log discrepancies for reconciliation.
- **Change-feed-driven replication.** Write to the source database only, but use a CDC mechanism (SQL Server Change Tracking, PostgreSQL logical replication, DynamoDB Streams) to replicate changes to Cosmos DB in near real-time. This avoids the consistency headaches of application-level dual-write, but adds latency between systems.
- **Cosmos DB change feed as the reverse pipe.** Once you switch writes to Cosmos DB, use the change feed (Chapter 15) to replicate back to the legacy system during a grace period. This lets legacy read paths continue working while you migrate consumers.

Dual-write is harder to implement correctly than blue/green, but it's the right choice when you can't afford any downtime and your writes must continue uninterrupted throughout the migration.

**A practical tip:** whichever strategy you choose, build a reconciliation process. After migration, compare a statistically significant sample of records between the old and new systems. Checksums, document counts, and spot-checking business-critical records are the minimum.

## Container Copy Jobs

Sometimes the migration isn't from an external database — it's within Cosmos DB itself. You need to change a partition key, switch from database-level to container-level throughput, adopt hierarchical partition keys, update unique key constraints, or rename a container. None of these changes can be made in-place. You need to create a new container with the desired settings and copy the data over. <!-- Source: develop-modern-applications/operations-on-containers-and-items/container-copy.md -->

**Container copy jobs** are a server-side feature that handles this without external tooling. The platform allocates dedicated compute instances for the destination Cosmos DB account to perform the copy. <!-- Source: develop-modern-applications/operations-on-containers-and-items/container-copy.md -->

### Offline vs. Online Copy

Container copy supports two modes: <!-- Source: develop-modern-applications/operations-on-containers-and-items/container-copy.md -->

| Mode | Mechanism | Use When |
|------|-----------|----------|
| **Offline** | Latest-version change feed | Maintenance window OK |
| **Online** | All-versions-and-deletes feed | Zero-downtime required |

- **Offline:** Quiesce writes to the source container before starting the copy.
- **Online:** Copies existing data, then continuously replicates incremental changes. Requires continuous backup and the all-versions-and-deletes change feed mode enabled on the source account. Doubles write RU cost on the source during copy.

Online copy requires continuous backup and the "All version and delete change feed mode" preview feature enabled on the source account. It also charges **double RU/s on all writes** to the source account during the copy, because the system must preserve both previous and current versions of changes. <!-- Source: develop-modern-applications/operations-on-containers-and-items/container-copy.md -->

### Running a Container Copy Job

Container copy jobs are managed via Azure CLI. The workflow: <!-- Source: develop-modern-applications/operations-on-containers-and-items/container-copy.md -->

**Offline copy:**

1. **Create the target container** with your desired settings (new partition key, throughput model, unique keys, etc.).
2. **Stop writes to the source** by pausing application instances or clients that connect to it.
3. **Create the copy job** using the CLI.
4. **Monitor progress** and wait until the job completes.
5. **Redirect your application** to the target container.

**Online copy:**

1. **Create the target container** with your desired settings.
2. **Create the copy job** using the CLI.
3. **Monitor progress** — the job copies existing data and continuously replicates incremental changes.
4. Once all documents are copied, **stop writes to the source** and call the completion API.
5. **Redirect your application** to the target container.

### Key Details

- **Default compute:** the platform allocates two 4-vCPU, 16-GB server-side instances per account. <!-- Source: develop-modern-applications/operations-on-containers-and-items/container-copy.md -->
- **Throughput tip:** set the target container's throughput to at least **2× the source container's throughput** for faster completion. <!-- Source: develop-modern-applications/operations-on-containers-and-items/container-copy.md -->
- **Concurrency:** multiple copy jobs can exist in an account, but they run **consecutively**, not in parallel. <!-- Source: develop-modern-applications/operations-on-containers-and-items/container-copy.md -->
- **Multi-region:** the job runs in the write region. If a region failover occurs during the copy, incomplete jobs will fail and need to be re-created. <!-- Source: develop-modern-applications/operations-on-containers-and-items/container-copy.md -->
- **TTL behavior:** TTL counters reset in the destination container. A document that was halfway through its TTL in the source starts fresh in the target. <!-- Source: develop-modern-applications/operations-on-containers-and-items/container-copy.md -->
- **Partition key conflicts:** when changing partition keys, ensure that the new partition key + `id` combination is unique across all documents. If two source documents with different old partition keys map to the same new partition key and share an `id`, the copy will fail with an insertion error. <!-- Source: develop-modern-applications/operations-on-containers-and-items/container-copy.md -->
- **20 GB partition limit:** if your new partition key groups more than 20 GB of data into a single logical partition, the job fails. Hierarchical partition keys (Chapter 5) can help you avoid this. <!-- Source: develop-modern-applications/operations-on-containers-and-items/container-copy.md -->
- **No SLA on duration.** Container copy is best-effort — there's no guarantee on how long a job takes. <!-- Source: develop-modern-applications/operations-on-containers-and-items/container-copy.md -->

Container copy jobs are the right tool for in-account reshaping. For cross-account migrations or migrations that require data transformation, use the other tools in this chapter.

## Migration Tool Decision Matrix

With all the tools covered, here's how to pick:

| Scenario | Tool |
|----------|------|
| Small dataset, dev/test | `dmt` |
| Relational → simple denorm | ADF (two-step pipeline) |
| Complex transforms, 100+ GB | Databricks + Spark |
| DynamoDB offline | S3 → ADF → Databricks |
| DynamoDB online | Streams/Kinesis → custom |
| Couchbase | ADF + Couchbase connector |
| HBase < 2.0 | ADF + HBase connector |
| HBase ≥ 2.0 | Spark + HBase + Cosmos |
| Re-partition within Cosmos | Container copy jobs |
| 100+ TB scale | Custom bulk executor + ADLS |

For the terabyte-scale scenario, Microsoft's guidance boils down to: <!-- Source: migrate-data/migrate.md -->

- Partition source data into ~200 MB files in Azure Data Lake Storage.
- Run the bulk executor library across multiple VMs, each consuming up to 500,000 RU/s per node.
- Track progress via a metadata collection so you can resume from failures.
- Set indexing mode to `none` during import and re-enable it afterward to save RU/s during ingestion.
- Pre-provision throughput well above steady-state, then scale down after the load completes.

The migration itself is a means to an end. Once your data is in Cosmos DB and your application is pointing at it, the real work begins — monitoring, tuning, and evolving your data model as your application grows. Chapter 24 picks up with how to test your Cosmos DB applications to make sure everything works before (and after) you go live.
