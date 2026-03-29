# Cosmos DB: The Good Parts
## Book Outline

> **Writer guidance:** Items marked with `✶ CANONICAL` are the primary home for that topic — go deep.
> Items marked with `→ see Ch X` are covered elsewhere — keep it to a sentence or two and point the reader there.
> Items marked with `✶ EXPAND HERE` within a shared topic mean this chapter should carry the bulk of the explanation.

---

## Part I: Foundations

### Chapter 1: What Is Azure Cosmos DB?
- The problem Cosmos DB solves: globally distributed, always-on applications
- A brief history: from DocumentDB to Cosmos DB
- Key value propositions
  - Single-digit millisecond latency at any scale
  - Turnkey global distribution with 99.999% availability SLA → high-level pitch here; mechanics in Ch12
  - Multi-model: document, key-value, graph, table, and vector data
  - Fully managed — no patching, tuning, or capacity planning headaches
- When to use Cosmos DB (and when not to)
  - Good fits: IoT, real-time personalization, gaming, booking, commerce
  - Poor fits: OLAP workloads, highly relational/join-heavy apps → mention Fabric Mirroring exists (Ch22) but don't explain it
- Cosmos DB vs. Azure DocumentDB (vCore) — a decision guide
- The AI era connection: why OpenAI, retailers, and IoT companies chose Cosmos DB

### Chapter 2: Core Concepts and Architecture
- The resource model: accounts → databases → containers → items
- What is a "document" in Cosmos DB? JSON items and schema flexibility → modeling depth in Ch4
- System properties: `id`, `_rid`, `_etag`, `_ts`, `_self` — what they mean and when you use them → ETags explained fully in Ch16
- Unique key constraints: enforcing uniqueness within a logical partition
- Request Units (RUs) — the universal currency of Cosmos DB → introduce the concept; deep dive in Ch10
  - How RUs are calculated (reads, writes, queries, stored procedures)
  - Why thinking in RUs matters for cost and performance
- Automatic indexing: how Cosmos DB indexes everything by default → one paragraph; full policy details in Ch9
- The logical partition: Cosmos DB's fundamental unit of scale
- Physical vs. logical partitions: a brief introduction → keep to ~2 paragraphs; deep dive in Ch5
- Replica sets and high availability within a region → brief; global distribution in Ch12
- Service limits and quotas: max item size (2 MB), partition key length, RU/s ceilings, nesting depth → table format; full reference in Appendix E

### Chapter 3: Setting Up Cosmos DB for NoSQL
- Creating a Cosmos DB account in the Azure portal
- Understanding account-level settings and free tier → pricing details in Ch11
- Creating databases and containers
- Connection strings, endpoints, and keys → security implications in Ch17
- Introduction to the Azure Cosmos DB Data Explorer
- The VS Code extension for Cosmos DB
- The Cosmos DB emulator: Windows installer vs. Linux-based vNext (Docker) ✶ CANONICAL for emulator setup
  - Emulator limitations vs. the cloud service
- Quickstart: your first item via the portal and the SDK → SDK depth in Ch21

---

## Part II: Data Modeling and Partitioning

### Chapter 4: Thinking in Documents
- The shift from relational to NoSQL thinking
- Embedding vs. referencing: the core trade-off ✶ CANONICAL
  - When to embed (one-to-few, data accessed together)
  - When to reference (one-to-many, unbounded arrays, independent updates)
- Denormalization as a feature, not a flaw
- Handling polymorphic data and schema evolution → schema evolution strategies also in Ch20 (IaC perspective); keep conceptual here
- Common document design patterns
  - Subdocuments and nested objects
  - Arrays of complex types
  - Metadata and type discriminator fields
- Anti-patterns to avoid: excessively large documents, deeply nested arrays

### Chapter 5: Partition Keys — The Most Important Decision You'll Make ✶ CANONICAL for partitioning
- Why partition key choice defines your application's performance ceiling
- Properties of a good partition key
  - High cardinality
  - Even write distribution
  - Enables efficient single-partition reads
- Partition key anti-patterns and their consequences
  - Hot partitions and throughput throttling → mention here as consequence; remediation strategies in Ch27
  - Using sequential IDs or timestamps as partition keys
- Synthetic partition keys: combining properties for better distribution
- Large partition keys: using values up to 2 KB
- Hierarchical partition keys (subpartitioning) ✶ EXPAND HERE for the concept
  - Use case: multi-tenant applications → brief example; full multi-tenancy patterns in Ch26
  - Use case: high-cardinality time-series data
- Cross-partition queries: cost warning and when they're unavoidable → see Ch8 for query mechanics and optimization
- Partition merge: recombining physical partitions after scale-down or data deletion
- Real-world partition key walk-throughs: IoT telemetry, e-commerce catalog

### Chapter 6: Advanced Data Modeling Patterns
- The item type pattern: storing multiple entity types in one container
- The lookup / reference pattern with materialized views → change feed for building views covered in Ch15
- Time-to-live (TTL) for expiring data automatically ✶ CANONICAL for TTL
- Partial document update (Patch API) ✶ CANONICAL — go deep on operations and patterns
  - Supported operations: Add, Set, Replace, Remove, Increment, Move
  - Conditional patching with predicates
  - RU savings vs. full-document Replace → Ch10 references Patch for RU savings; keep the RU angle brief here
- Working with large items: strategies for chunking and streaming
- Modeling hierarchical and tree structures
- Modeling many-to-many relationships
- Delete items by partition key: server-side bulk deletion (preview)
- Event sourcing and immutable log patterns → change feed as the event consumer covered in Ch15

---

## Part III: Querying and Indexing

### Chapter 8: Querying with the NoSQL API ✶ CANONICAL for query language and query behavior
- Introduction to Cosmos DB SQL (NoSQL query language)
- Basic SELECT, FROM, WHERE syntax
- Keywords: DISTINCT, TOP, BETWEEN, LIKE, IN
- Parameterized queries: preventing injection and enabling plan reuse
- Querying nested objects and arrays
- Aggregate functions: COUNT, SUM, MIN, MAX, AVG
- GROUP BY clause
- Pagination strategies
  - Continuation token-based pagination (recommended): iterating `FeedIterator`, storing and resuming tokens
  - OFFSET/LIMIT: use cases, cost implications, and when to avoid it
- Joins and self-joins across arrays (within a document)
- Subqueries and correlated subqueries
- Built-in system functions
  - String functions: CONTAINS, STARTSWITH, UPPER, LOWER
  - Math functions
  - Array functions
  - Date and time functions
  - Spatial functions
  - Full-text search functions: FullTextContains, FullTextContainsAll, FullTextContainsAny
  - Full-text scoring: FullTextScore (BM25) with ORDER BY RANK
  - Hybrid search: the RRF (Reciprocal Rank Fusion) function
- Computed properties: server-side derived values that can be indexed and queried
- Understanding cross-partition queries: how they work, why they cost more, and how to minimize them ✶ EXPAND HERE — Ch5 warns about them; this chapter explains the mechanics
- LINQ to SQL: querying Cosmos DB with .NET LINQ expressions
- Indexing and querying geospatial data (GeoJSON points, polygons, distance queries) → geospatial indexing policy in Ch9
- Query Advisor: built-in recommendations for optimizing query performance ✶ CANONICAL — Ch27 references this within the tuning loop
- Query metrics and diagnosing expensive queries → monitoring dashboard angle in Ch18

### Chapter 9: Indexing Policies ✶ CANONICAL for all indexing configuration
- How Cosmos DB automatic indexing works under the hood
- The default indexing policy: index all paths
- Customizing your indexing policy
  - Including and excluding specific paths
  - Range indexes for equality and range queries
  - Spatial indexes for geospatial data
  - Composite indexes: the key to efficient ORDER BY and multi-filter queries
    - Rules for composite index property order
    - Composite indexes with range filters
    - Composite indexes with aggregate functions
  - Tuple indexes for array element queries
- Disabling indexing for write-heavy bulk import scenarios
- Full-text search indexing policy ✶ CANONICAL — Ch25 references this chapter for FTS indexing
- Vector indexing policies (DiskANN) ✶ CANONICAL for vector index config — Ch25 covers the search queries and AI use cases
  - Sharded DiskANN for multi-tenant vector search
- Lazy vs. consistent indexing mode
- Global secondary indexes (preview): efficient cross-partition queries via secondary index
- Measuring index storage and RU impact

---

## Part IV: Throughput, Scaling, and Cost

### Chapter 10: Request Units In Depth ✶ CANONICAL for RU mechanics and cost optimization tactics
- Breaking down RU cost by operation type
  - Point reads (cheapest, by `id` + partition key)
  - Upserts and writes
  - Queries (and why fanout queries cost more)
  - Stored procedure and trigger execution
- Finding the RU charge for any operation (response headers and portal metrics)
- RU budgeting for your application
- Strategies to reduce RU consumption
  - Optimize query predicates and avoid full scans
  - Prefer point reads over queries for known IDs
  - Use projections to fetch only needed fields
  - Tune indexing to exclude unused paths → indexing policy details in Ch9
  - Use the Patch API for partial updates instead of full Replace → Patch API details in Ch6
- Priority-based execution: tagging requests as high or low priority

### Chapter 11: Provisioned Throughput, Autoscale, and Serverless ✶ CANONICAL for capacity models, cost optimization, and caching
- Provisioned throughput: manual RU/s allocation
  - Database-level vs. container-level throughput sharing
  - When to share throughput across containers → multi-tenancy angle in Ch26
- Autoscale provisioned throughput
  - How autoscale works (10% of max as baseline)
  - Ideal workloads: variable, unpredictable traffic
  - Cost comparison with manual provisioning
- Serverless mode
  - Billed per-operation, no minimum cost
  - Ideal workloads: dev/test, sporadic, low-traffic apps
  - Limitations: single region, no autoscale, no SLA on throughput
- Burst capacity: accumulating idle RUs and bursting up to 3,000 RU/s per partition
- Throughput buckets (preview): fine-grained throughput governance across workloads
- Scheduled throughput scaling: using Azure Functions timers for nights/weekends
- Limiting total account throughput: governance caps across an account
- Best practices for scaling provisioned throughput
- Changing capacity mode: switching between provisioned and serverless after creation
- Choosing the right capacity model
- Cost optimization strategies: right-sizing, reserved capacity, TTL cleanup, indexing trimming
- Reserved capacity for production cost savings (up to 63% discount)
- The free tier: 1,000 RU/s and 25 GB forever free
- The integrated cache and dedicated gateway ✶ CANONICAL — Ch21 mentions as a perf tip and should point here
  - Item cache (point reads) and query cache (LRU eviction)
  - MaxIntegratedCacheStaleness and bypass options
  - When integrated cache makes sense vs. external caching

---

## Part V: Global Distribution and Consistency

### Chapter 12: Going Global — Multi-Region Distribution ✶ CANONICAL for replication, failover, and global architecture
- How Cosmos DB replicates data across Azure regions
- Availability zones and zone redundancy within a region
- Adding and removing regions at runtime
- Multi-region reads: routing reads to the nearest region
- Multi-region writes: the 99.999% availability story
  - Conflict resolution policies (last-write-wins vs. custom merge) → consistency implications in Ch13
- Automatic failover and regional outage scenarios
- Per-partition automatic failover (PPAF) — preview
- Recovery Point Objective (RPO) and Recovery Time Objective (RTO) by configuration → DR planning details in Ch19
- Azure Government and sovereign cloud regions

### Chapter 13: Consistency Levels ✶ CANONICAL for the five consistency levels
- The consistency spectrum: strong vs. eventual
- The five Cosmos DB consistency levels explained
  - **Strong**: linearizable, always reads the latest write
  - **Bounded Staleness**: reads lag by at most K versions or T seconds
  - **Session**: the default; consistent within a client session
  - **Consistent Prefix**: no out-of-order reads, but can lag
  - **Eventual**: lowest latency, no ordering guarantees
- Choosing the right consistency for your workload
- Consistency and its impact on RU cost and latency
- Per-request consistency override
- How consistency interacts with multi-region writes → conflict resolution mechanics in Ch12; keep this to the consistency angle only

---

## Part VI: Server-Side Programming and Event-Driven Patterns

### Chapter 14: Stored Procedures, Triggers, and User-Defined Functions ✶ CANONICAL for server-side JavaScript
- When and why to use server-side JavaScript
- Stored procedures
  - Scope: always within a single logical partition
  - Writing and registering a stored procedure
  - Transactional semantics: all or nothing (ACID within a partition) → transaction concepts also in Ch16; keep focused on sproc mechanics here
  - Handling continuation tokens for large operations
- Pre-triggers and post-triggers
  - Pre-trigger: validate or modify items before writes
  - Post-trigger: react to writes atomically
- User-Defined Functions (UDFs) in queries
  - Writing and registering a UDF
  - Using UDFs in SELECT and WHERE clauses
- Performance considerations: pre-compilation and batching benefits

### Chapter 15: The Change Feed ✶ CANONICAL for change feed concepts, consumption, and patterns
- What is the change feed and what it captures (inserts and updates)
- Change feed modes
  - Latest version mode (default)
  - All versions and deletes mode
- Consuming the change feed
  - Change Feed Processor library (.NET, Java, Python, JavaScript)
  - Azure Functions trigger (the simplest path) → Azure Functions integration in Ch22; keep to change feed trigger mechanics here
  - Direct SDK pull model
  - Apache Spark connector for change feed
- Common change feed patterns
  - Event-driven microservices architecture
  - Real-time materialized views
  - Streaming pipelines into Azure Event Hubs or Kafka → integration details in Ch22
  - Cache invalidation
- Checkpointing and resuming from a position
- Change feed and global distribution: per-region feeds
- Monitoring change feed lag with the change feed estimator

### Chapter 16: Transactions and Optimistic Concurrency ✶ CANONICAL for ETags, optimistic concurrency, and transactional batch
- Single-item atomicity: every write is automatically atomic
- Multi-item transactions via stored procedures → sproc mechanics in Ch14; focus on transactional semantics here
- Transactional batch operations using the SDK ✶ EXPAND HERE
  - Batch semantics: all succeed or all fail
  - Constraints: same partition key for all operations in a batch
- Optimistic concurrency control with ETags
  - The if-match header pattern
  - Detecting and handling conflicts in code

---

## Part VII: Security, Monitoring, and Operations

### Chapter 17: Security and Access Control ✶ CANONICAL for auth, network security, encryption, and compliance
- Authentication options
  - Primary/secondary keys (account-level)
  - Resource tokens for scoped, temporary access
  - Microsoft Entra ID (formerly Azure AD) for identity-based auth
  - Disabling local (key-based) authentication for Entra ID-only mode
  - Key rotation strategies
- Role-based access control (RBAC)
  - Built-in roles: Cosmos DB Built-in Data Reader, Data Contributor
  - Custom role definitions
  - Assigning roles to managed identities and service principals → multi-tenancy RBAC patterns in Ch26
- Network security
  - Virtual network service endpoints
  - Private endpoints and Private Link
  - IP firewall rules
  - CORS (Cross-Origin Resource Sharing) configuration
  - Network Security Perimeter (preview)
- Encryption
  - Encryption at rest (default, Microsoft-managed keys)
  - Customer-managed keys (CMK) with Azure Key Vault
  - Always Encrypted: client-side encryption for sensitive properties
  - TLS version enforcement (minimum TLS, upcoming TLS 1.3)
- Dynamic data masking (DDM): masking sensitive properties without app changes
- Azure Policy support: built-in policies for governance (enforce CMK, restrict throughput, disable local auth)
- Resource locks: preventing accidental deletion or modification
- Microsoft Defender for Azure Cosmos DB: threat detection and security alerts
- Data residency and compliance certifications

### Chapter 18: Monitoring, Diagnostics, and Alerting ✶ CANONICAL for metrics, alerts, Log Analytics, and troubleshooting
- Azure Monitor integration for Cosmos DB
- Key metrics to watch
  - Total requests and failed requests
  - RU consumption and throttled requests (429s)
  - Latency percentiles (P50, P99)
  - Storage consumption
  - Replication latency
- Setting up alerts for throttling, availability, and latency thresholds
- Diagnostic logs and Log Analytics
  - Querying DataPlaneRequests, QueryRuntimeStatistics
  - Identifying expensive queries by RU charge
- OpenTelemetry and distributed tracing
  - Consuming Cosmos DB traces in Azure Monitor, Jaeger, or other collectors
  - SDK instrumentation setup covered in Chapter 21
- The Azure Cosmos DB Insights workbook in Azure Monitor
- Troubleshooting common issues
  - 429 Too Many Requests: causes and remedies → RU mechanics in Ch10; capacity solutions in Ch11
  - High cross-partition query cost → query optimization in Ch8
  - Hot partition detection → partition key design in Ch5; redistribution in Ch27

### Chapter 19: Backup, Restore, and Disaster Recovery ✶ CANONICAL for backup modes, PITR, and DR planning
- Periodic backup mode (the default)
  - Backup frequency and retention
  - How to request a restore from Microsoft support
- Continuous backup mode with point-in-time restore (PITR)
  - Enabling continuous backup
  - 7-day vs. 30-day retention tiers and cost differences
  - Restoring to any point within the retention window
  - Restoring a deleted container or database
  - In-account restore: restoring into the same account (no new account required)
- Disaster recovery configurations and their RTO/RPO guarantees → global distribution mechanics in Ch12; focus on DR planning here
  - Single-region: no automatic failover
  - Multi-region read: automatic failover with RTO ~minutes
  - Multi-region write: near-zero RPO/RTO
- Business continuity planning checklist

### Chapter 20: CI/CD, DevOps, and Infrastructure as Code
- Managing Cosmos DB resources in code (IaC-first mindset)
- Bicep and Terraform: defining accounts, databases, containers, and indexing policies
- Deploying indexing policy and throughput changes without downtime
- Schema evolution strategies: additive changes, container versioning, dual-write patterns → data modeling foundations in Ch4; focus on operational/deployment aspects here
- Integrating Cosmos DB into CI/CD pipelines
  - Provisioning test environments per PR with the emulator or a dedicated account → emulator setup in Ch3; testing patterns in Ch24
  - Running integration tests in pipeline stages
  - Teardown and cost controls for ephemeral environments
- Environment promotion: dev → staging → production with IaC

---

## Part VIII: Integration and Ecosystem

### Chapter 21: Using the Cosmos DB SDKs ✶ CANONICAL for SDK usage, resilience, and observability
- Overview of supported SDKs: .NET, Java, Python, JavaScript/Node.js, Go, Rust
- SDK fundamentals: CosmosClient, Database, Container
- CRUD operations in code
  - Creating and upserting items
  - Reading items (point read by id + partition key)
  - Partial document update with the Patch API → brief here; full Patch API in Ch6
  - Querying with FeedIterator / async paging
  - Deleting items
- Connection management: singleton client pattern
- Retry policies and handling transient errors (429, 503)
- Bulk executor and bulk operations mode
- Performance tips for SDK usage
  - Direct vs. Gateway connectivity mode
  - Dedicated gateway for integrated cache scenarios → see Ch11 for cache details; one-liner here
  - Connection pooling
  - Preferred region configuration
- Entity Framework Core with Cosmos DB
  - Setting up the EF Core Cosmos DB provider
  - Mapping entities and owned types to documents
  - Querying and change tracking considerations
  - Limitations vs. the raw SDK (no cross-partition queries, no bulk, no patch)
- OpenTelemetry instrumentation in the SDK ✶ CANONICAL for SDK-side telemetry setup
  - Enabling built-in tracing and metrics
  - Correlating with application-level spans
  - → consuming and dashboarding telemetry covered in Ch18
- SDK observability: Micrometer metrics (Java), diagnostic strings, and request-level diagnostics
- Designing resilient SDK applications ✶ CANONICAL — the single home for retry, resilience, and availability strategy
  - Preferred regions and availability strategy
  - Retry policies, circuit breakers, and custom retry logic
  - Connection timeout and keep-alive tuning

### Chapter 22: Integrating with Azure Services
- **Azure Functions**: the change feed trigger and HTTP trigger → change feed concepts in Ch15; focus on Functions wiring here
- **Azure Event Hubs and Kafka**: streaming Cosmos DB changes downstream → change feed patterns in Ch15; focus on Event Hubs/Kafka setup here
- **Azure Synapse Link and Synapse Analytics**: no-ETL HTAP analytics
  - Analytical store: column-format replica for analytics
  - Running Spark and serverless SQL pools over Cosmos DB data
  - Note: Synapse Link is being superseded by Microsoft Fabric Mirroring
- **Microsoft Fabric Mirroring**: near real-time analytical replication
  - Migrating from Synapse Link to Fabric Mirroring
  - Reverse ETL: writing Fabric analytical results back to Cosmos DB
- **Azure Data Factory**: bulk import/export and migration pipelines
- **Azure Kubernetes Service (AKS)** and App Service integration patterns
- **Azure IoT Hub** and time-series telemetry ingestion patterns
- **Azure Cognitive Search**: indexing Cosmos DB documents for full-text search
- **Azure Stream Analytics**: real-time stream processing with Cosmos DB output
- **Apache Spark connector**: OLTP connector for batch and streaming integration
- **Kafka Connect for Cosmos DB**: source and sink connectors (V1 and V2)
- **Spring Data Azure Cosmos DB**: Spring Boot Starter and repository pattern for Java
- **ASP.NET session state and cache provider**: using Cosmos DB as a distributed session/cache store
- **Cosmos DB in Microsoft Fabric**: native Fabric database (beyond mirroring)
- **Vercel integration**: deploying Cosmos DB-backed apps on Vercel

### Chapter 23: Migrating to Cosmos DB ✶ CANONICAL for migration tooling, strategies, and cutover
- Assessing your current workload for Cosmos DB fit
- Converting vCores to Request Units: the migration calculator
- Migrating from relational databases (SQL Server, PostgreSQL)
  - Rethinking the schema: denormalization and embedding → modeling concepts in Ch4; keep to migration-specific advice here
  - One-to-few migration patterns using Azure Data Factory
  - Using Azure Databricks for complex transformation
- Migrating from other NoSQL databases
  - DynamoDB to Cosmos DB: application migration and data migration
  - Couchbase to Cosmos DB
  - HBase to Cosmos DB
- The Desktop Data Migration Tool (dmt CLI)
- The Cosmos DB Migration Assessment tool
- Cutover strategies: blue/green migration and dual-write patterns
- Container copy jobs: server-side data copy between containers (partition key changes, throughput model changes)

### Chapter 24: Testing Cosmos DB Applications ✶ CANONICAL for testing strategies
- Testing philosophy: what to unit test vs. integration test
- Unit testing with a mocked Cosmos DB client
  - Abstracting the SDK behind a repository interface
  - Mocking CosmosClient, Container, and FeedIterator
- Integration testing with the Cosmos DB emulator → emulator setup in Ch3; focus on test workflows and CI here
  - Windows emulator vs. Linux-based vNext Docker image
  - Configuring the emulator for CI (Docker image)
  - Seeding and tearing down test data between runs
  - Verifying indexing policy behavior in tests
- End-to-end testing strategies for change feed consumers
- Testing throughput and partition key distribution with load tools
- Common testing pitfalls (singleton client leaks, emulator cold-start latency)

---

## Part IX: Advanced Topics

### Chapter 25: Vector Search and AI Applications ✶ CANONICAL for AI use cases, vector queries, and AI framework integrations
- Cosmos DB as a unified AI database: storing data and embeddings together
- What is vector search? (embeddings, similarity, RAG patterns)
- Configuring vector embeddings on a container
  - Supported vector data types (float32, int8, uint8)
  - Distance functions: cosine, Euclidean, dot product
  - Dimensions and model selection (OpenAI, Azure AI)
- Vector indexing with DiskANN → indexing policy config in Ch9; focus on search behavior and AI patterns here
  - Flat (exact search) vs. DiskANN (approximate nearest neighbor)
  - Sharded DiskANN for multi-tenant scenarios
- Running vector similarity search queries
- Hybrid search: combining vector search with keyword and filter queries
  - Weighted hybrid search with RRF
- Semantic Reranker (preview): AI-powered reranking of query results
- Full-text search: using the indexing policy and query functions → indexing in Ch9, query functions in Ch8; brief recap and AI-specific usage here
- Semantic cache: using Cosmos DB as an LLM response cache
- Building a RAG (Retrieval-Augmented Generation) application with Cosmos DB and Azure OpenAI
- Using Cosmos DB for LLM conversation history / memory caching
- Building AI agent state stores with Cosmos DB
- Managing AI agent memories: long-term and working memory patterns
- Building knowledge graphs with Cosmos DB for AI applications
- Integrating with AI frameworks
  - Semantic Kernel connector
  - LangChain integration (Python and JavaScript)
  - LlamaIndex connector
- Model Context Protocol (MCP) toolkit for Cosmos DB
- Azure SRE Agent (preview): AI-powered site reliability for Cosmos DB
- AI coding assistants: Agent Kit for GitHub Copilot, Claude Code, Gemini CLI

### Chapter 26: Multi-Tenancy Patterns ✶ CANONICAL for tenant isolation, throughput sharing, and fleet management
- The spectrum: database-per-tenant, container-per-tenant, shared container
- Shared container multi-tenancy with partition key isolation
- Hierarchical partition keys for high-cardinality tenant + entity patterns → HPK concept introduced in Ch5; expand on multi-tenant usage here
- Enforcing tenant data isolation with RBAC and resource tokens → RBAC details in Ch17; focus on tenancy-specific patterns here
- Throughput management: dedicated vs. shared (database-level) RU/s per tenant → capacity models in Ch11; focus on per-tenant decisions here
- Multi-tenant vector search: combining tenancy isolation with vector queries
- Cosmos DB Fleets: orchestrating multi-account, multi-tenant deployments at scale
  - Fleet pools and fleet analytics
- Anti-patterns and pitfalls in multi-tenant Cosmos DB design

### Chapter 27: Performance Tuning and Best Practices
- The performance tuning loop: measure → identify → optimize → validate → uses metrics from Ch18, RU analysis from Ch10
- Choosing direct connectivity mode for lowest latency → connection modes introduced in Ch21; expand on when/why here
- Optimizing document size and structure → modeling in Ch4; focus on perf impact here
- Indexing policy tuning for write-heavy workloads → indexing policy details in Ch9; focus on perf trade-offs here
- Query optimization walk-through: from expensive to efficient → query language in Ch8; this is the applied walk-through
- Leveraging Query Advisor (introduced in Chapter 8) in the tuning loop → see Ch8 for how it works; brief reference here
- Handling hot partitions at scale ✶ EXPAND HERE for remediation
  - Throughput redistribution across physical partitions
- Capacity planning and load testing with the RU calculator
- Per-language SDK best practices (.NET, Java, Python, JavaScript) → SDK fundamentals in Ch21; this is the perf-specific addendum
- When to consider multiple containers vs. a single container design
- Production readiness checklist

### Chapter 28: Capstone — Building a Production-Ready Application
> This chapter ties together concepts from across the book. Keep explanations minimal — reference the canonical chapter for each topic. The value here is seeing everything work together.
- Overview: what we're building (e.g., a multi-tenant task management API or real-time order system)
- Designing the data model and choosing the partition key → applies Ch4 + Ch5
- Implementing CRUD and query endpoints with the SDK → applies Ch21 + Ch8
- Adding change feed processing for downstream side effects → applies Ch15
- Securing the app with Entra ID and RBAC → applies Ch17
- Wiring up monitoring, alerting, and distributed tracing → applies Ch18 + Ch21
- Writing the test suite: unit, integration, and emulator-based → applies Ch24
- Deploying to Azure with Bicep and a CI/CD pipeline → applies Ch20
- Retrospective: trade-offs made and alternatives considered

---

## Appendices

### Appendix A: Cosmos DB CLI and Terraform Quick Reference
- Common Azure CLI commands for managing Cosmos DB
- Bicep and Terraform snippets for infrastructure-as-code deployments

### Appendix B: NoSQL Query Language Reference
- Quick-reference card for Cosmos DB SQL syntax
- System functions grouped by category

### Appendix C: Consistency Level Comparison Table
- Side-by-side: latency, RU cost, ordering guarantees, failover behavior

### Appendix D: Capacity and Pricing Cheat Sheet
- RU cost per operation type
- Provisioned vs. autoscale vs. serverless comparison
- Free tier and reserved capacity overview

### Appendix E: Service Limits and Quotas Quick Reference
- Per-item limits (2 MB max, partition key length, nesting depth)
- Per-container and per-database throughput limits
- Serverless limits
- Control plane rate limits
- Free tier limits
