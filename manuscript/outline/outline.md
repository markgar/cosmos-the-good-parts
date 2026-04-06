# Azure Cosmos DB: A Developer's Complete Guide — Outline

> **Auto-generated from chapter headings.** This is the source of truth for chapter structure, scope, and cross-reference checks. Update this file when chapters are reorganized.

---

## Frontmatter

### Preface
- Who This Book Is For
- How This Book Is Organized
- How to Read It
- How This Book Was Written
- Conventions
- Source Code and Errata

---

## Part I: Foundations

### Chapter 1: What Is Azure Cosmos DB?
- A Brief History: From DocumentDB to Cosmos DB
- Key Value Propositions
  - Single-Digit Millisecond Latency at Any Scale
  - Turnkey Global Distribution
  - Multi-Model: One Database, Many Data Shapes
  - Fully Managed — No Patching, Tuning, or Capacity Planning Headaches
- When to Use Cosmos DB (and When Not To)
  - Good Fits
  - Poor Fits
- Cosmos DB vs. Azure DocumentDB (vCore)
- The AI Era Connection

### Chapter 2: Core Concepts and Architecture
- The Resource Model: Accounts, Databases, Containers, and Items
  - Account
  - Database
  - Container
  - Item
- What Is a "Document" in Cosmos DB?
- System Properties
- Unique Key Constraints
- Request Units: The Universal Currency
  - What Is a Request Unit?
  - What Affects RU Cost?
  - How You Pay for RUs
- Automatic Indexing
- The Logical Partition: Cosmos DB's Unit of Scale
- Physical vs. Logical Partitions
- Replica Sets and High Availability
- Service Limits and Quotas
  - Item Limits
  - Container and Database Limits
  - Throughput Limits
  - Request Limits

### Chapter 3: Setting Up Cosmos DB for NoSQL
- Creating a Cosmos DB Account in the Azure Portal
  - The CLI and IaC Alternatives
- Understanding Account-Level Settings and Free Tier
  - Free Tier
- Creating Databases and Containers
  - Creating a Database and Container in the Portal
  - Shared vs. Dedicated Throughput
  - Seeding Sample Data
  - Creating via the SDK
  - Should You Create Resources in Code or in CI/CD?
- Connection Strings, Endpoints, and Keys
- Introduction to the Azure Cosmos DB Data Explorer
  - A Quick Walkthrough
- The VS Code Extension for Cosmos DB
  - Installation
  - Connecting to Your Account
  - What You Can Do
- The Cosmos DB Emulator
  - The Windows Installer (Legacy Emulator)
  - The Linux-Based vNext Emulator (Docker)
  - Emulator Limitations vs. the Cloud Service
  - Which Emulator Should You Use?
- Quickstart: Your First Item via the Portal and the SDK
  - Setup
  - C# (.NET)
  - Python
  - Switching from the Emulator to the Cloud
  - What Just Happened?

---

## Part II: Data Modeling and Partition Strategy

### Chapter 4: Thinking in Documents
- The Shift from Relational to NoSQL Thinking
- Embedding vs. Referencing: The Core Trade-Off
  - Embedding: One Document, One Read
  - When to Embed
  - Referencing: Separate Documents, Linked by ID
  - When to Reference
  - The Decision Framework
- Denormalization as a Feature, Not a Flaw
  - What You're Actually Trading
  - The Relational Safety Net You Don't Have
- Handling Polymorphic Data and Schema Evolution
  - Polymorphic Data and Type Discriminators
  - Schema Evolution
- Common Document Design Patterns
  - Subdocuments and Nested Objects
  - Arrays of Complex Types
  - Metadata and Type Discriminator Fields
- Anti-Patterns to Avoid
  - Excessively Large Documents
  - Deeply Nested Arrays
  - Unbounded Arrays
  - One Entity Type Per Container (the "Table-Per-Entity" Trap)
  - Treating Cosmos DB Like a Relational Database

### Chapter 5: Partition Keys — The Most Important Decision You'll Make
- Why Partition Key Choice Defines Your Performance Ceiling
- Properties of a Good Partition Key
  - High Cardinality
  - Even Write Distribution
  - Efficient Single-Partition Reads
  - The Decision Matrix
- Partition Key Anti-Patterns and Their Consequences
  - Hot Partitions and Throughput Throttling
  - Sequential IDs or Timestamps as Partition Keys
- Synthetic Partition Keys: Combining Properties for Better Distribution
  - Concatenation
  - Random Suffix
  - Precalculated Suffix
- Large Partition Keys: Values Up to 2 KB
- Hierarchical Partition Keys (Subpartitioning)
  - The Problem HPK Solves
  - How It Works
  - Query Routing with HPK
  - Use Case: Multi-Tenant Applications
  - Use Case: High-Cardinality Time-Series Data
  - Important HPK Considerations
  - HPK vs. Synthetic Keys: When to Choose Which
- Cross-Partition Queries: Cost Warning and When They're Unavoidable
- Partition Merge: Recombining Physical Partitions After Scale-Down
  - Why Merge Matters
  - The Caveats
- Real-World Partition Key Walk-Throughs
  - IoT Telemetry Platform
  - E-Commerce Catalog

### Chapter 6: Advanced Data Modeling Patterns
- The Item Type Pattern
  - Querying Polymorphic Data
  - When to Use the Item Type Pattern
- The Lookup Pattern with Materialized Views
- Time-to-Live (TTL): Expiring Data Automatically
  - How TTL Works
  - The Deletion Mechanics
  - Configuring TTL
  - Resetting the Clock
  - Practical TTL Patterns
- Partial Document Update (Patch API)
  - Supported Operations
  - Patch in Action
  - Conditional Patching with Predicates
  - Patch in Transactional Batches
  - Patch and Multi-Region Conflict Resolution
  - RU Savings
  - What You Can't Patch
  - When to Use Patch vs. Replace
- Working with Large Items
  - Strategy 1: Offload Binary Data to Blob Storage
  - Strategy 2: Chunk Large Structured Data
  - Strategy 3: Trim What You Store
- Modeling Hierarchical and Tree Structures
  - Materialized Path
  - Embedded Children (Shallow Trees)
- Modeling Many-to-Many Relationships
  - Embed Reference Arrays on Both Sides
  - Denormalize Summary Data
  - When the Relationship Is the Entity
- Delete Items by Partition Key
  - How It Works
  - Limitations
  - When to Use It
- Event Sourcing and Immutable Log Patterns
  - Why Cosmos DB Works for Event Sourcing
  - The Consumer Side
  - Practical Considerations

---

## Part III: Querying, Indexing, and Throughput

### Chapter 7: Using the Cosmos DB SDKs
- Overview of Supported SDKs
- SDK Fundamentals: CosmosClient, Database, Container
  - The Object Model
- CRUD Operations in Code
  - Creating and Upserting Items
  - Reading Items (Point Read)
  - Partial Document Update with the Patch API
  - Querying with FeedIterator and Async Paging
  - Deleting Items
- Connection Management: The Singleton Client Pattern
- Direct vs. Gateway Connectivity Mode
  - Gateway Mode
  - Direct Mode
  - When to Use Which
  - How Direct Mode Works Under the Hood
- Reading the RU Charge from Response Headers
- Retry Policies and Handling Transient Errors
  - What the SDK Retries Automatically
  - HTTP 429: Rate Limiting
  - Timeout and Connectivity Failures (408, 503)
  - ETag Conflicts (412)
- LINQ to SQL: Querying Cosmos DB with .NET LINQ Expressions
- Putting It All Together: Per-Request Options
- What's Next

### Chapter 8: Querying with the NoSQL API
- Introduction to Cosmos DB SQL (NoSQL Query Language)
- Basic SELECT, FROM, WHERE Syntax
  - The Simplest Query
  - Projection
  - Filtering with WHERE
- Keywords: DISTINCT, TOP, BETWEEN, LIKE, IN
  - DISTINCT
  - TOP
  - BETWEEN
  - LIKE
  - IN
- Parameterized Queries
- Querying Nested Objects and Arrays
  - Nested Object Properties
  - Array Elements by Index
  - Checking Array Contents
- Aggregate Functions: COUNT, SUM, MIN, MAX, AVG
- GROUP BY
- Pagination Strategies
  - Continuation Token-Based Pagination (Recommended)
  - OFFSET/LIMIT
- Joins and Self-Joins Across Arrays
  - Multiple JOINs
  - Filtering on Array Elements
- Subqueries and Correlated Subqueries
  - Subquery as an Expression
  - Subquery in WHERE
  - Correlated Subqueries for JOIN Optimization
- Built-in System Functions
  - String Functions
  - Math Functions
  - Array Functions
  - Date and Time Functions
  - Spatial Functions
  - Full-Text Search Functions
  - Full-Text Scoring: FullTextScore and ORDER BY RANK
  - Hybrid Search: The RRF Function
- Computed Properties
- Indexing and Querying Geospatial Data
  - Storing Geospatial Data
  - Distance Queries
  - Within Queries
  - Spatial Indexing
- Understanding Cross-Partition Queries
  - How They Work
  - The RU Math
  - When It Matters (and When It Doesn't)
  - How to Minimize Cross-Partition Queries
  - The SDK's Parallel Execution
- Query Advisor: Built-in Optimization Recommendations

### Chapter 9: Indexing Policies
- How Cosmos DB Automatic Indexing Works Under the Hood
- The Default Indexing Policy
- Customizing Your Indexing Policy
  - Including and Excluding Specific Paths
  - Range Indexes for Equality and Range Queries
  - Spatial Indexes for Geospatial Data
  - Composite Indexes
  - Tuple Indexes for Array Element Queries
- Disabling Indexing for Write-Heavy Bulk Import Scenarios
- Full-Text Search Indexing Policy
  - The Full-Text Policy (Container Level)
  - The Full-Text Index (Indexing Policy)
- Vector Indexing Policies (DiskANN)
  - Container Vector Policy
  - Vector Index Types
  - Tuning Vector Index Build Parameters
  - Sharded DiskANN for Multi-Tenant Vector Search
- Lazy vs. Consistent Indexing Mode
- Global Secondary Indexes (Preview)
  - How GSIs Work
  - GSI Trade-offs
- Measuring Index Storage and RU Impact
  - Tracking Index Size
  - Using Index Metrics to Find What's Missing
  - The Index Transformation Process
  - The Write Cost Trade-off
  - Limits at a Glance

### Chapter 10: Request Units In Depth
- Breaking Down RU Cost by Operation Type
  - Point Reads: The Cheapest Operation in Cosmos DB
  - Writes: Creates, Replaces, Upserts, and Deletes
  - Queries: The Cost Spectrum
  - Stored Procedures and Triggers
- Finding the RU Charge for Any Operation
  - Response Headers: The x-ms-request-charge Header
  - Azure Portal: Query Stats
  - Azure Monitor Metrics
- RU Budgeting for Your Application
  - The Capacity Calculator
  - Multi-Region Cost Multiplier
- Strategies to Reduce RU Consumption
  - Prefer Point Reads Over Queries for Known IDs
  - Optimize Query Predicates and Avoid Full Scans
  - Use Projections to Fetch Only Needed Fields
  - Tune Indexing to Exclude Unused Paths
  - Use the Patch API for Partial Updates
  - Quick Reference: RU Optimization Tactics
- Priority-Based Execution
  - How It Works
  - Enabling and Using Priority-Based Execution
  - SDK Version Requirements
  - When to Use It
  - Limitations

### Chapter 11: Provisioned Throughput, Autoscale, and Serverless
- Provisioned Throughput: Manual RU/s Allocation
  - Database-Level vs. Container-Level Throughput
  - When to Share Throughput Across Containers
- Autoscale Provisioned Throughput
  - How Autoscale Billing Works
  - Cost Comparison: Manual vs. Autoscale
  - Dynamic Scaling: Per-Region, Per-Partition Autoscale
  - Ideal Workloads for Autoscale
- Serverless Mode
  - Serverless Limitations
  - When Serverless Makes Sense
- Burst Capacity
- Throughput Buckets (Preview)
- Scheduled Throughput Scaling
- Limiting Total Account Throughput
- Best Practices for Scaling Provisioned Throughput
  - Instant vs. Asynchronous Scaling
  - Keeping Partitions Even During Scale-Up
  - Minimum Throughput Floors
- Changing Capacity Mode
- Choosing the Right Capacity Model
- Cost Optimization Strategies
  - Right-Size Your Throughput
  - Use TTL to Clean Up Stale Data
  - Trim Your Indexing Policy
  - Prefer Point Reads Over Queries
  - Use the Patch API for Partial Updates
- Reserved Capacity
- The Free Tier
- The Integrated Cache and Dedicated Gateway
  - How It Works
  - Setting Up the Dedicated Gateway
  - MaxIntegratedCacheStaleness
  - Bypassing the Cache
  - Consistency Requirements
  - When the Integrated Cache Makes Sense vs. External Caching
  - Monitoring the Integrated Cache
  - Dedicated Gateway in Multi-Region Accounts
- Putting It All Together

---

## Part IV: Global Distribution and Consistency

### Chapter 12: Going Global — Multi-Region Distribution
- How Cosmos DB Replicates Data Across Azure Regions
  - Single-Write vs. Multi-Write Region Configurations
- Availability Zones and Zone Redundancy
- Adding and Removing Regions at Runtime
- Multi-Region Reads: Routing to the Nearest Region
- Multi-Region Writes: The 99.999% Availability Story
  - The Hub and Satellite Model
  - Conflict Resolution Policies
  - When Not to Use Multi-Region Writes
- Automatic Failover and Regional Outage Scenarios
  - Read Region Outage
  - Write Region Outage (Single-Write Accounts)
  - Write Region Outage (Multi-Write Accounts)
  - Configuring Service-Managed Failover
- Per-Partition Automatic Failover (PPAF) — Preview
  - Prerequisites for PPAF
  - PPAF Pricing
  - Testing PPAF
- RPO and RTO by Configuration
- Azure Government and Sovereign Cloud Regions
- Putting It Together: Choosing Your Global Architecture

### Chapter 13: Consistency Levels
- The Consistency Spectrum
- The Five Consistency Levels Explained
  - Strong Consistency
  - Bounded Staleness
  - Session Consistency
  - Consistent Prefix
  - Eventual Consistency
- Choosing the Right Consistency for Your Workload
- Consistency and Its Impact on RU Cost and Latency
  - Read Cost
  - Write Cost
  - Read Latency
  - The Throughput Impact
- Per-Request Consistency Override
- How Consistency Interacts with Multi-Region Writes
  - Strong Consistency Is Off the Table
  - Bounded Staleness Isn't Worth It
  - Session Is the Sweet Spot for Multi-Region Writes
  - Consistency and Data Durability
- In Practice: Consistency Is Often Stronger Than You Asked For

---

## Part V: Server-Side Programming and Event-Driven Patterns

### Chapter 14: Stored Procedures, Triggers, and User-Defined Functions
- When and Why to Use Server-Side JavaScript
  - When Not to Use Server-Side JavaScript
- Stored Procedures
  - Scope: Always Within a Single Logical Partition
  - Writing a Stored Procedure
  - Registering a Stored Procedure
  - Transactional Semantics: All or Nothing
  - Handling Continuation for Large Operations
  - The RU Charging Model for Stored Procedures
- Pre-Triggers and Post-Triggers
  - Pre-Triggers: Validate or Modify Items Before Writes
  - Post-Triggers: React to Writes Atomically
  - Registering and Invoking Triggers
- User-Defined Functions (UDFs) in Queries
  - Writing and Registering a UDF
  - Using UDFs in SELECT and WHERE Clauses
  - UDF Limitations
- Performance Considerations
  - Pre-Compilation
  - Batching Benefits
  - When the Trade-Offs Don't Pay Off
  - Consider the Change Feed Instead of Post-Triggers

### Chapter 15: The Change Feed
- What the Change Feed Captures
  - Sort Order
- Change Feed Modes
  - Latest Version Mode (Default)
  - All Versions and Deletes Mode (Preview)
  - Choosing Between Modes
- Consuming the Change Feed
  - Azure Functions Trigger
  - Change Feed Processor
  - SDK Pull Model
  - Apache Spark Connector
  - Which Consumer Should You Choose?
- Common Change Feed Patterns
  - Event-Driven Microservices
  - Real-Time Materialized Views
  - Streaming Pipelines into Event Hubs or Kafka
  - Cache Invalidation
- Checkpointing and Resuming from a Position
- Change Feed and Global Distribution
- Monitoring Change Feed Lag with the Change Feed Estimator

### Chapter 16: Transactions and Optimistic Concurrency
- Single-Item Atomicity: Transactions You Get for Free
- Multi-Item Transactions: Two Paths, One Constraint
  - Stored Procedures: Server-Side Transactions
- Transactional Batch Operations
  - How It Works
  - C# Example: Order with Line Items
  - Python Example: Batch with Mixed Operations
  - Patch Operations in a Batch
  - Error Handling: The 424 Pattern
  - Transactional Batch Limits
  - When to Use Transactional Batch vs. Stored Procedures
- Optimistic Concurrency Control with ETags
  - How ETags Work
  - The If-Match Pattern in C#
  - The If-Match Pattern in Python
  - The If-Match Pattern in JavaScript
  - Building a Retry Loop
  - The If-None-Match Pattern
  - ETags in Transactional Batches
  - ETags in Stored Procedures
  - When Not to Use Optimistic Concurrency
  - Optimistic Concurrency vs. the Patch API
- Putting It All Together: A Transaction Decision Framework

---

## Part VI: Security, Monitoring, and Operations

### Chapter 17: Security and Access Control
- Authentication Options
  - Primary and Secondary Keys
  - Resource Tokens for Scoped, Temporary Access
  - Microsoft Entra ID (Formerly Azure AD)
  - Disabling Key-Based Authentication
  - Key Rotation Strategies
- Role-Based Access Control (RBAC)
  - Control Plane Roles
  - Data Plane Roles: Built-In
  - Custom Role Definitions
  - Assigning Roles to Identities
- Network Security
  - IP Firewall Rules
  - Virtual Network Service Endpoints
  - Private Endpoints and Private Link
  - CORS Configuration
  - Network Security Perimeter (Preview)
- Encryption
  - Encryption at Rest
  - Customer-Managed Keys (CMK)
  - Always Encrypted: Client-Side Encryption
  - TLS Version Enforcement
- Dynamic Data Masking
  - Masking Strategies
- Azure Policy Support
- Resource Locks
- Microsoft Defender for Azure Cosmos DB
- Data Residency and Compliance Certifications
- Putting It All Together

### Chapter 18: Monitoring, Diagnostics, and Alerting
- Azure Monitor Integration for Cosmos DB
  - Setting Up Diagnostic Settings
- Key Metrics to Watch
  - Total Requests and Failed Requests
  - RU Consumption
  - Throttled Requests (429s)
  - Latency Percentiles
  - Storage Consumption
  - Replication Latency
  - The Dashboard Essentials
- Setting Up Alerts
  - Recommended Alert Rules
  - Creating a Metric Alert: A Walkthrough
- Diagnostic Logs and Log Analytics
  - The Key Tables
  - Essential KQL Queries
  - Using Aggregated Logs for Cost-Effective Monitoring
- OpenTelemetry and Distributed Tracing
- The Azure Cosmos DB Insights Workbook
- Troubleshooting Common Issues
  - 429 Too Many Requests
  - High Cross-Partition Query Cost
  - Hot Partition Detection
- A Copilot Agent for Cosmos DB Troubleshooting
  - What the Agent Knows
  - Setting It Up
  - Making It Your Own

### Chapter 19: Backup, Restore, and Disaster Recovery
- Periodic Backup Mode: The Default
  - How Periodic Backups Work
  - Configuring Backup Interval and Retention
  - Backup Storage Redundancy
  - How to Request a Restore (Periodic Mode)
  - When Periodic Mode Makes Sense
- Continuous Backup Mode with Point-in-Time Restore (PITR)
  - Enabling Continuous Backup
  - 7-Day vs. 30-Day Retention Tiers
  - How Continuous Backups Are Stored
  - Restoring to a Point in Time
  - In-Account Restore: Same Account, No Migration
  - Multi-Region Write Accounts and Continuous Backup
  - What Continuous Backup Doesn't Cover
- Periodic vs. Continuous: Which Should You Choose?
- Disaster Recovery Configurations
  - Single-Region Accounts: No Automatic Failover
  - Multi-Region with Single Write: Automatic Failover
  - Multi-Region Write: Near-Zero Downtime
- Business Continuity Planning Checklist
  - 1. Choose Your Backup Mode Deliberately
  - 2. Enable Multi-Region Deployment for Production
  - 3. Enable Service-Managed Failover (Single-Write Accounts)
  - 4. Configure Preferred Regions in Your SDK
  - 5. Test Your Failover Regularly
  - 6. Document Your Restore Procedures
  - 7. Monitor and Alert on Availability
  - 8. Understand What's Not Backed Up
  - 9. Align Backup Mode with Your RTO/RPO Requirements
  - 10. Don't Confuse Backup with DR

---

## Part VII: DevOps, Advanced SDK, and Integrations

### Chapter 20: CI/CD, DevOps, and Infrastructure as Code
- Managing Cosmos DB Resources in Code
- Bicep: Defining the Full Stack
- Terraform: The Multi-Cloud Alternative
  - Bicep vs. Terraform: Which One?
  - Key IaC Constraints to Know
- Deploying Indexing Policy and Throughput Changes Without Downtime
- Schema Evolution Strategies
  - Additive Changes: The Easy Path
  - Container Versioning
  - Dual-Write Patterns
- Integrating Cosmos DB into CI/CD Pipelines
  - Provisioning Test Environments with the Emulator
  - The Emulator in GitHub Actions
  - The Emulator in Azure DevOps
  - Provisioning Dedicated Cloud Accounts for CI
  - Teardown and Cost Controls for Ephemeral Environments
- Environment Promotion: Dev → Staging → Production
  - One Template, Many Parameter Files
  - The Promotion Pipeline
  - What Changes and What Doesn't
  - Protecting Production

### Chapter 21: Advanced SDK Patterns
- Bulk Operations
  - Bulk Mode in the .NET SDK
  - Bulk Mode in the Java SDK
  - Bulk Operations in the JavaScript SDK
  - The Legacy Bulk Executor Library
- Performance Tips for High-Throughput Scenarios
  - Use Direct Mode (When You Can)
  - Connection Tuning
  - Preferred Regions
  - The Singleton Rule
  - Other High-Impact Tips
- Entity Framework Core with Cosmos DB
  - Setting Up the Provider
  - Mapping Entities and Owned Types
  - Querying and Change Tracking
  - Limitations vs. the Raw SDK
- OpenTelemetry Instrumentation
  - Enabling Tracing
  - Trace Attributes
  - Diagnostic Logs for Slow and Failed Requests
  - Correlating with Application Spans
  - A Note on OTel Metrics vs. Tracing
- SDK Observability Beyond OpenTelemetry
  - Micrometer Metrics (Java)
  - Diagnostic Strings and Request-Level Diagnostics
- Designing Resilient SDK Applications
  - Understanding What the SDK Retries For You
  - Preferred Regions and Cross-Region Failover
  - Threshold-Based Availability Strategy
  - Partition-Level Circuit Breaker
  - Excluded Regions (Per-Request Routing)
  - Connection Timeout and Keep-Alive Tuning

### Chapter 22: Integrating with Azure Services
- Azure Functions
  - The Change Feed Trigger
  - Input and Output Bindings
- Azure Event Hubs and Kafka
- Azure Synapse Link and Synapse Analytics
  - What Synapse Link Was
  - Limitations That Drove the Replacement
  - If You're Still on Synapse Link
- Microsoft Fabric Mirroring
  - Migrating from Synapse Link to Fabric Mirroring
  - Reverse ETL: Writing Analytical Results Back to Cosmos DB
- Azure Data Factory
- Azure Kubernetes Service and App Service
  - AKS Patterns
  - App Service Patterns
- Azure IoT Hub
- Azure AI Search
- Azure Stream Analytics
- Apache Spark Connector (OLTP)
  - Setup
  - Change Feed via Spark Structured Streaming
  - Throughput Control
- Kafka Connect for Cosmos DB
  - V1 vs. V2
  - Sink Connector Configuration
  - Source Connector Configuration
  - V1 to V2 Migration
- Spring Data Azure Cosmos DB
- ASP.NET Session State and Cache Provider
- Cosmos DB in Microsoft Fabric
- Vercel Integration
- Choosing the Right Integration

---

## Part VIII: Migration, Testing, and Specialized Patterns

### Chapter 23: Migrating to Cosmos DB
- Assessing Your Current Workload for Cosmos DB Fit
- Converting vCores to Request Units
  - Worked Example
  - The Capacity Planner
- Migrating from Relational Databases
  - Rethinking the Schema
  - One-to-Few Patterns with Azure Data Factory
  - Azure Databricks for Complex Transformations
- Migrating from Other NoSQL Databases
  - DynamoDB to Cosmos DB
  - Couchbase to Cosmos DB
  - HBase to Cosmos DB
- The Desktop Data Migration Tool
  - Running dmt
  - Batch Operations
- Assessing Migration Readiness
- Cutover Strategies
  - Blue/Green Migration
  - Dual-Write Pattern
- Container Copy Jobs
  - Offline vs. Online Copy
  - Running a Container Copy Job
  - Key Details
- Migration Tool Decision Matrix

### Chapter 24: Testing Cosmos DB Applications
- Testing Philosophy: What to Unit Test vs. Integration Test
- Unit Testing with a Mocked Cosmos DB Client
  - Abstracting the SDK Behind a Repository Interface
  - Mocking CosmosClient, Container, and FeedIterator
- Integration Testing with the Cosmos DB Emulator
  - Windows Emulator vs. Linux-Based vNext Docker Image
  - Configuring the Emulator for CI (Docker Image)
  - Seeding and Tearing Down Test Data Between Runs
  - Verifying Indexing Policy Behavior in Tests
- End-to-End Testing Strategies for Change Feed Consumers
- Testing Throughput and Partition Key Distribution with Load Tools
  - Verifying Partition Key Distribution
  - Load Testing with the Benchmarking Tool
- Common Testing Pitfalls
  - Singleton Client Leaks in Tests
  - Emulator Cold-Start Latency
  - Testing Against the Emulator vs. the Cloud
  - Forgetting to Dispose the FeedIterator
  - Non-Deterministic Test Data

### Chapter 25: Vector Search and AI Applications
- Cosmos DB as a Unified AI Database
- What Is Vector Search?
- Configuring Vector Embeddings on a Container
  - Vector Data Types
  - Distance Functions
  - Dimensions and Model Selection
- Vector Indexing with DiskANN
  - Flat: Exact Search
  - DiskANN: Approximate Nearest Neighbor at Scale
  - Sharded DiskANN for Multi-Tenant Scenarios
- Running Vector Similarity Search Queries
- Hybrid Search: Combining Vector and Full-Text Queries
  - Weighted Hybrid Search
- Semantic Reranker (Preview)
- Full-Text Search for AI Workloads
- Semantic Cache: Cosmos DB as an LLM Response Cache
- Building a RAG Application
- LLM Conversation History and Memory
- Building AI Agent State Stores
- Managing AI Agent Memories
- Building Knowledge Graphs for AI
- Integrating with AI Frameworks
  - Semantic Kernel
  - LangChain
  - LlamaIndex
- Model Context Protocol (MCP) Toolkit
- Azure SRE Agent (Preview)
- AI Coding Assistants: The Agent Kit

### Chapter 26: Multi-Tenancy Patterns
- The Isolation Spectrum
  - Account-per-Tenant
  - Database-per-Tenant
  - Container-per-Tenant
  - Shared Container with Partition Key Isolation
- Shared Container Multi-Tenancy with Partition Key Isolation
  - The 20 GB Problem
- Hierarchical Partition Keys for Multi-Tenant Workloads
  - Creating an HPK Container
  - Why the Lowest Level Should Have High Cardinality
  - The Low-Cardinality First-Level Trap
  - Query Routing with HPK
- Enforcing Tenant Data Isolation with RBAC and Resource Tokens
  - Data-Plane RBAC Scoping
  - Resource Tokens (Legacy)
  - Defense in Depth for Shared Containers
- Throughput Management: Dedicated vs. Shared RU/s per Tenant
  - Container-Level Dedicated Throughput
  - Database-Level Shared Throughput
  - The Hybrid Approach
- Multi-Tenant Vector Search
  - The Problem with Unsegmented Vector Indexes
  - Sharded DiskANN: Tenant-Isolated Vector Indexes
  - Querying Sharded Vector Indexes
  - When to Use Sharded DiskANN
- Cosmos DB Fleets: Orchestrating Multi-Account Deployments at Scale
  - The Hierarchy
  - Fleet Pools: Shared Throughput Across Accounts
  - Fleet Analytics: Observability Across Your Tenant Fleet
  - Creating a Fleet
- Tenant Offboarding: Deleting Tenant Data
- Anti-Patterns and Pitfalls
  - Skipping HPK When You'll Obviously Need It
  - Treating Partition Key Isolation as a Security Boundary
  - Over-Provisioning Every Tenant "Just in Case"
  - Ignoring Noisy Neighbors Until It's a Production Issue
  - Using One Physical Partition for All Tenants
  - Forgetting About Observability
- Choosing Your Multi-Tenancy Model

### Chapter 27: Performance Tuning and Best Practices
- The Performance Tuning Loop
- Choosing Direct Connectivity Mode for Lowest Latency
  - How Direct Mode Connections Work
  - When to Stick with Gateway Mode
- Optimizing Document Size and Structure
  - Practical Trimming Strategies
- Indexing Policy Tuning for Write-Heavy Workloads
  - The Include-Everything vs. Exclude-and-Opt-In Strategy
  - Indexing Mode: None
  - Use Index Metrics to Validate
- Query Optimization Walk-Through: From Expensive to Efficient
  - The Starting Point
  - Step 1: Add a Partition Key Filter
  - Step 2: Ensure the Filter Uses an Index
  - Step 3: Project Only What You Need
  - Step 4: Check the Execution Metrics
  - Step 5: Consider an Optimistic Direct Execution Path
- Leveraging Query Advisor in the Tuning Loop
- Handling Hot Partitions at Scale
  - Detecting Hot Partitions
  - Remediation Strategy 1: Fix the Partition Key
  - Remediation Strategy 2: Throughput Redistribution Across Physical Partitions
  - Remediation Strategy 3: Scale Up the Container
- Capacity Planning and Load Testing with the Capacity Planner
  - Load Testing in Practice
- Per-Language SDK Best Practices
  - .NET SDK v3
  - Java SDK v4
  - Python SDK
  - JavaScript/Node.js SDK
  - Cross-SDK Summary
- When to Consider Multiple Containers vs. a Single Container
- Production Readiness Checklist

### Chapter 28: Capstone — Building a Production-Ready Application
- What We're Building
- Designing the Data Model
  - Choosing the Partition Key
- Implementing CRUD and Query Endpoints
  - The Singleton Client
  - Point Reads and Upserts
  - Querying Tasks
- Adding Change Feed Processing
  - Setting Up the Processor
  - Why Not Azure Functions?
- Securing the App with Entra ID and RBAC
  - The Role Assignment
  - Disabling Key-Based Auth
- Wiring Up Monitoring, Alerting, and Distributed Tracing
  - OpenTelemetry Distributed Tracing
  - Azure Monitor Alerts
  - Diagnostic Logs for Query Analysis
- Writing the Test Suite
  - Unit Tests: Mock the SDK
  - Integration Tests: The Docker Emulator
  - CI Pipeline Integration
- Deploying to Azure with Bicep
  - The Bicep Template
  - Deploying the Template
- Retrospective: Trade-offs Made and Alternatives Considered

---

## Appendices

### Appendix A: Cosmos DB CLI and Terraform Quick Reference
- Azure CLI Commands
  - Account Management
  - Failover
  - Keys and Connection Strings
  - Database Operations
  - Container Operations
  - Resource Locks
- Bicep Snippets
  - Account with Multi-Region and Configurable Consistency
  - Database and Container with Autoscale Throughput
  - Stored Procedure, Trigger, and UDF
  - Free Tier Account
  - RBAC Role Definition and Assignment
- Terraform Snippets
  - Account with Multi-Region and Consistency Policy
  - Database and Container with Autoscale
  - Database and Container with Manual Throughput
  - Stored Procedure, Trigger, and UDF
  - Free Tier Account
  - RBAC Role Definition and Assignment
- Bicep vs. Terraform at a Glance

### Appendix B: NoSQL Query Language Reference
- Query Clause Reference
  - SELECT
  - DISTINCT
  - TOP
  - FROM
  - WHERE
  - ORDER BY
  - GROUP BY
  - OFFSET LIMIT
  - EXISTS
  - IN
  - BETWEEN
  - LIKE
  - JOIN (Intra-Document)
  - Subqueries
- Operators
  - Comparison Operators
  - Logical Operators
  - Arithmetic Operators
  - Other Operators
- Aggregate Functions
- System Functions by Category
  - String Functions
  - Mathematical Functions
  - Array Functions
  - Type-Checking Functions
  - Date and Time Functions
  - Spatial Functions
  - Vector Search Function
  - Full-Text Search Functions
  - Hybrid Search (RRF)
- Index Efficiency at a Glance
- Per-Request Query Limits

### Appendix C: Consistency Level Comparison Table
- The Five Levels at a Glance
- Bounded Staleness Parameters
- Availability During Regional Outages
- Decision Quick Reference

### Appendix D: Capacity and Pricing Cheat Sheet
- RU Cost per Operation Type
- Capacity Model Comparison
- Free Tier
- Reserved Capacity
- Key Billing Facts

### Appendix E: Service Limits and Quotas Quick Reference
- Per-Item Limits
- Per-Container Limits
- Per-Database Limits (Shared Throughput)
- Minimum Throughput (Dedicated Container)
- Autoscale Limits
- Serverless Limits
- Per-Request Limits
- SQL Query Limits
- Indexing Limits
- Control Plane Limits
  - Resource Limits
  - Request Rate Limits (per 5-minute window)
- Per-Account Role-Based Access Control
- Authorization Token Limits
- Free Tier Limits
- Limits That Can Be Increased
