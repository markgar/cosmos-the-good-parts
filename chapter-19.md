# Chapter 19: CI/CD, DevOps, and Infrastructure as Code

Up to this point in the book you've been creating Cosmos DB resources through the portal, clicking buttons, tweaking settings, and watching things come to life in real time. That's great for learning — but it's a terrible way to run production systems. Sooner or later someone fat-fingers a partition key, someone else forgets to enable zone redundancy, and suddenly your Friday night involves an incident call instead of dinner.

This chapter is about removing humans from the deployment loop — or at least making sure they express intent through code that's reviewed, versioned, and repeatable. We'll cover Infrastructure as Code (IaC) with Bicep and Terraform, walk through strategies for evolving your schema without downtime, and wire everything into CI/CD pipelines that provision, test, and tear down Cosmos DB environments automatically.

## The IaC-First Mindset

If there's one habit that separates mature cloud teams from the rest, it's this: **never create a resource by hand that you intend to keep**. Every Cosmos DB account, database, container, indexing policy, and throughput setting should be defined in code and deployed through automation.

Why? Three reasons:

1. **Repeatability.** You can spin up identical environments for dev, staging, and production from the same template. No more "works on my subscription."
2. **Auditability.** Every change flows through pull requests. You can see exactly who changed the indexing policy on Tuesday and why.
3. **Disaster recovery.** If an entire region goes down and you need to recreate your infrastructure in another region, your IaC templates are your blueprint.

The two dominant IaC tools in the Azure ecosystem are **Bicep** (Microsoft's native ARM template language) and **Terraform** (HashiCorp's multi-cloud tool). Both are excellent choices for Cosmos DB. Let's look at each.

## Bicep: Azure-Native Infrastructure as Code

Bicep is a domain-specific language that compiles to ARM JSON templates. If your infrastructure lives entirely in Azure, Bicep is hard to beat — it has first-class support for every Azure resource type, including Cosmos DB, with IntelliSense in VS Code and type-safe parameter validation.

Here's a complete Bicep file that creates a Cosmos DB account, a database, and a container with a custom indexing policy:

```bicep
@description('Cosmos DB account name, max length 44 characters, lowercase')
param accountName string = 'sql-${uniqueString(resourceGroup().id)}'

@description('Location for the Cosmos DB account.')
param location string = resourceGroup().location

@description('The name for the database')
param databaseName string = 'orders-db'

@description('The name for the container')
param containerName string = 'orders'

@description('Maximum autoscale throughput for the container')
@minValue(1000)
@maxValue(1000000)
param autoscaleMaxThroughput int = 1000

resource account 'Microsoft.DocumentDB/databaseAccounts@2024-05-15' = {
  name: toLower(accountName)
  kind: 'GlobalDocumentDB'
  location: location
  properties: {
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
    locations: [
      {
        locationName: location
        failoverPriority: 0
        isZoneRedundant: true
      }
    ]
    databaseAccountOfferType: 'Standard'
    enableAutomaticFailover: true
  }
}

resource database 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2024-05-15' = {
  parent: account
  name: databaseName
  properties: {
    resource: {
      id: databaseName
    }
  }
}

resource container 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-05-15' = {
  parent: database
  name: containerName
  properties: {
    resource: {
      id: containerName
      partitionKey: {
        paths: ['/customerId']
        kind: 'Hash'
      }
      indexingPolicy: {
        indexingMode: 'consistent'
        includedPaths: [
          { path: '/orderDate/?' }
          { path: '/status/?' }
        ]
        excludedPaths: [
          { path: '/*' }
        ]
        compositeIndexes: [
          [
            { path: '/customerId', order: 'ascending' }
            { path: '/orderDate', order: 'descending' }
          ]
        ]
      }
      defaultTtl: -1
    }
    options: {
      autoscaleSettings: {
        maxThroughput: autoscaleMaxThroughput
      }
    }
  }
}

output accountEndpoint string = account.properties.documentEndpoint
```

A few things to notice:

- **Indexing policy is declared inline.** You're excluding `/*` and only including the paths you actually query — a pattern we discussed back in the indexing chapter. This means your indexing strategy is now version-controlled.
- **Autoscale throughput** is set at the container level. You could also set it at the database level for shared throughput scenarios.
- **Zone redundancy** is enabled on the primary location. This is the sort of setting that's easy to forget in the portal but trivial to enforce in code.

Deploy it with the Azure CLI:

```bash
az deployment group create \
  --resource-group rg-cosmos-orders \
  --template-file main.bicep \
  --parameters accountName='cosmos-orders-prod'
```

## Terraform: Multi-Cloud IaC

If your organization uses multiple cloud providers, or if your team has standardized on Terraform, the `azurerm` provider gives you full control over Cosmos DB resources. Here's the equivalent setup in Terraform:

```hcl
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
}

variable "location" {
  type    = string
  default = "East US"
}

variable "autoscale_max_throughput" {
  type    = number
  default = 1000
}

resource "azurerm_resource_group" "main" {
  name     = "rg-cosmos-orders"
  location = var.location
}

resource "azurerm_cosmosdb_account" "main" {
  name                      = "cosmos-orders-${lower(random_id.suffix.hex)}"
  location                  = var.location
  resource_group_name       = azurerm_resource_group.main.name
  offer_type                = "Standard"
  kind                      = "GlobalDocumentDB"
  automatic_failover_enabled = true

  consistency_policy {
    consistency_level = "Session"
  }

  geo_location {
    location          = var.location
    failover_priority = 0
    zone_redundant    = true
  }
}

resource "azurerm_cosmosdb_sql_database" "main" {
  name                = "orders-db"
  resource_group_name = azurerm_resource_group.main.name
  account_name        = azurerm_cosmosdb_account.main.name
}

resource "azurerm_cosmosdb_sql_container" "orders" {
  name                = "orders"
  resource_group_name = azurerm_resource_group.main.name
  account_name        = azurerm_cosmosdb_account.main.name
  database_name       = azurerm_cosmosdb_sql_database.main.name
  partition_key_paths = ["/customerId"]

  autoscale_settings {
    max_throughput = var.autoscale_max_throughput
  }

  indexing_policy {
    indexing_mode = "consistent"

    included_path {
      path = "/orderDate/?"
    }

    included_path {
      path = "/status/?"
    }

    excluded_path {
      path = "/*"
    }
  }
}

resource "random_id" "suffix" {
  byte_length = 4
}

output "account_endpoint" {
  value = azurerm_cosmosdb_account.main.endpoint
}
```

### Bicep vs. Terraform: Which Should You Pick?

There's no universal answer, but here are the trade-offs:

| Concern | Bicep | Terraform |
|---|---|---|
| **Azure support** | Same-day for new resource types | Slight lag behind ARM API updates |
| **Multi-cloud** | Azure only | AWS, GCP, Azure, and more |
| **State management** | Stateless (ARM handles it) | Requires a state file (remote backend recommended) |
| **Learning curve** | Minimal if you know ARM | Moderate; HCL is its own language |
| **Ecosystem** | Azure-native tooling | Rich provider ecosystem, modules registry |

For a pure Azure Cosmos DB project, Bicep is the path of least resistance. For a team already invested in Terraform, there's no reason to switch.

### Organizing Your IaC Files

Regardless of which tool you choose, structure matters. Don't put everything in one monolithic file. A clean layout looks like this:

```
infra/
├── main.bicep              # Orchestrator — references modules
├── modules/
│   ├── cosmos-account.bicep
│   ├── cosmos-database.bicep
│   └── cosmos-container.bicep
├── parameters/
│   ├── dev.bicepparam
│   ├── staging.bicepparam
│   └── prod.bicepparam
└── scripts/
    └── deploy.sh           # Wrapper for az deployment group create
```

Each module encapsulates one logical resource. Your `cosmos-container.bicep` module takes the indexing policy as a parameter, so different containers can have different indexing strategies without duplicating code. When a new developer joins your team, they can open `main.bicep`, see the three modules being composed together, and understand the entire infrastructure in under a minute.

For Terraform, the equivalent pattern uses separate `.tf` files per resource type and a `terraform.tfvars` per environment, with remote state backends isolating each stage.

## Deploying Indexing Policy and Throughput Changes Without Downtime

One of Cosmos DB's underappreciated strengths is that **indexing policy updates are online operations**. When you push a modified indexing policy through your IaC template, Cosmos DB performs an index transformation in the background. During the transformation:

- **Reads are unaffected.** Your application continues to serve queries normally.
- **Writes are unaffected.** New documents are indexed according to both the old and new policies until the transformation completes.
- **Queries that depend on new indexes** may return incomplete results until the transformation finishes. You can monitor progress by checking the `IndexTransformationProgress` header on any request, or by querying the resource with the SDK.

This means you can safely add composite indexes, switch from `consistent` to `lazy` indexing (or vice versa), or add spatial indexes — all through a redeployment of your Bicep or Terraform template, with zero application downtime.

**Throughput changes** are also online. Whether you're changing manual throughput values or adjusting autoscale maximums, the update takes effect immediately. But watch out for one thing: if you're switching *from manual to autoscale* (or the reverse), that's a separate operation and some IaC tools may want to recreate the resource. Test this in a non-production environment first.

A practical workflow looks like this:

1. A developer modifies the `indexingPolicy` block in your Bicep file to add a composite index.
2. They open a pull request. Your CI pipeline runs a `what-if` deployment (Bicep) or `terraform plan` to show exactly what will change.
3. Reviewers confirm the change is intentional. The PR merges.
4. Your CD pipeline deploys the updated template. Cosmos DB begins the background index transformation.
5. Monitoring alerts fire if `IndexTransformationProgress` hasn't reached 100% within your expected window.

## Schema Evolution Strategies

Cosmos DB is schemaless — you can write any JSON document to a container at any time. But "schemaless" doesn't mean "no schema." Your application code has expectations about document structure, and changing those expectations in production requires a strategy.

### Additive Changes

The safest schema evolution is **additive**: adding new properties to documents without removing or renaming existing ones. Your application code should already handle missing properties gracefully (nullable types, default values). When you deploy a new version of your app that writes a `shippingTrackingNumber` field, older documents simply won't have it — and that's fine, as long as your queries and deserialization logic account for it.

### Container Versioning

For breaking changes — renaming a partition key path, fundamentally restructuring your document hierarchy — you may need a **new container**. The pattern is:

1. Create a new container (e.g., `orders-v2`) with the updated schema and partition key via your IaC templates.
2. Deploy your application with dual-read logic: try `orders-v2` first, fall back to `orders-v1`.
3. Run a background migration (using the change feed, for example) to copy and transform documents from `v1` to `v2`.
4. Once migration is complete and verified, switch all reads and writes to `v2`.
5. Decommission `v1` after a grace period.

Because your containers are defined in IaC, both versions coexist cleanly in your templates, and removing the old one is a simple PR.

### Dual-Write Patterns

When you can't afford any migration downtime, a **dual-write** approach works well:

1. Your application writes to *both* the old and new containers simultaneously.
2. A background process backfills the new container with historical data.
3. Once backfill is complete, you cut reads over to the new container.
4. Stop writing to the old container. Remove it from your IaC templates.

This pattern is more complex and introduces a window where you're paying for double the throughput, but it guarantees zero data loss and zero read disruption.

### Version Stamps in Documents

Whichever strategy you choose, consider adding a `_schemaVersion` property to every document:

```json
{
  "id": "order-4821",
  "customerId": "C-100",
  "_schemaVersion": 2,
  "lineItems": [ ... ]
}
```

Your application can then branch deserialization logic based on the version number. This is especially valuable during container versioning and dual-write migrations, because you always know which version of the schema produced a given document. Over time, you can write a simple query to check whether any `_schemaVersion: 1` documents remain, giving you confidence that a migration is truly complete before you tear down the old container.

## Integrating Cosmos DB into CI/CD Pipelines

Now let's wire everything together. A mature CI/CD pipeline for a Cosmos DB-backed application should:

1. **Provision a test environment** for each pull request.
2. **Run integration tests** against that environment.
3. **Tear down** the environment when the PR closes.
4. **Promote** changes through dev → staging → production.

### Option 1: The Cosmos DB Emulator in CI

The fastest and cheapest way to run integration tests is the **Azure Cosmos DB Linux emulator**, available as a Docker image. It supports the NoSQL API and runs on any CI system that supports Docker containers.

The latest generation of the emulator (`vnext-preview`) is lightweight and Linux-native:

```bash
docker pull mcr.microsoft.com/cosmosdb/linux/azure-cosmos-emulator:vnext-preview
```

Here's a GitHub Actions workflow that spins up the emulator as a service container and runs your tests against it:

```yaml
name: Integration Tests

on:
  pull_request:
    branches: [main]

jobs:
  integration-tests:
    runs-on: ubuntu-latest

    services:
      cosmosdb:
        image: mcr.microsoft.com/cosmosdb/linux/azure-cosmos-emulator:vnext-preview
        ports:
          - 8081:8081

    env:
      COSMOS_ENDPOINT: "http://localhost:8081"
      COSMOS_KEY: "C2y6yDjf5/R+ob0N8A7Cgv30VRDJIWEHLM+4QDU5DE2nQ9nDuVTqobD4b8mGGyPMbIZnqyMsEcaGQy67XIw/Jw=="

    steps:
      - uses: actions/checkout@v4

      - name: Setup .NET
        uses: actions/setup-dotnet@v4
        with:
          dotnet-version: '8.0.x'

      - name: Wait for emulator
        run: |
          echo "Waiting for Cosmos DB emulator..."
          for i in $(seq 1 30); do
            curl -sf http://localhost:8081/_explorer/emulator.pem > /dev/null 2>&1 && break
            sleep 2
          done

      - name: Run integration tests
        run: dotnet test --filter Category=Integration
```

A few things worth noting:

- The emulator's **default key** is a well-known constant (the `C2y6y...` string above). It's the same for every emulator instance. Never use this key for anything other than local/CI testing.
- The `vnext-preview` emulator starts in HTTP mode by default. For .NET and Java SDKs, you'll need to either configure HTTPS mode (`--protocol https` and handle the self-signed certificate) or set `CosmosClientOptions.ConnectionMode = ConnectionMode.Gateway` with HTTP.
- GitHub Actions automatically starts and stops the service container — no manual `docker run` or cleanup needed.

For **Azure DevOps Pipelines**, you can use a similar Docker-based approach with a container job:

```yaml
# azure-pipelines.yml
trigger:
  - main

pool:
  vmImage: 'ubuntu-latest'

services:
  cosmosdb:
    image: mcr.microsoft.com/cosmosdb/linux/azure-cosmos-emulator:vnext-preview
    ports:
      - 8081:8081

steps:
  - task: UseDotNet@2
    inputs:
      version: '8.0.x'

  - script: |
      echo "Waiting for emulator..."
      until curl -sf http://localhost:8081/ > /dev/null 2>&1; do sleep 2; done
    displayName: 'Wait for Cosmos DB Emulator'

  - script: dotnet test --filter Category=Integration
    displayName: 'Run integration tests'
    env:
      COSMOS_ENDPOINT: 'http://localhost:8081'
      COSMOS_KEY: 'C2y6yDjf5/R+ob0N8A7Cgv30VRDJIWEHLM+4QDU5DE2nQ9nDuVTqobD4b8mGGyPMbIZnqyMsEcaGQy67XIw/Jw=='
```

### Option 2: Dedicated Cosmos DB Accounts per PR

The emulator is great, but it doesn't support every feature (server-side stored procedures, certain query operators, realistic RU metering). For higher-fidelity tests, provision a **real Cosmos DB account** per pull request:

```yaml
# In your CI pipeline
- name: Provision test Cosmos DB
  run: |
    az deployment group create \
      --resource-group rg-cosmos-ci \
      --template-file infra/main.bicep \
      --parameters accountName='cosmos-pr-${{ github.event.pull_request.number }}' \
                   autoscaleMaxThroughput=1000
```

**Cost controls for ephemeral environments:**

- **Use serverless throughput** instead of provisioned. You pay only for the RUs consumed during tests — often just pennies.
- **Set autoscale minimums low** (1,000 RU/s) if you must use provisioned throughput.
- **Tear down aggressively.** Add a pipeline step that deletes the resource group when the PR closes or merges. Use a scheduled pipeline as a safety net to clean up any orphaned resources older than 24 hours.
- **Use Azure tags** on your IaC resources (`environment: ci`, `pr: 1234`, `ttl: 24h`) so your cleanup scripts can find them.

```yaml
- name: Teardown test environment
  if: always()
  run: |
    az group delete \
      --name rg-cosmos-pr-${{ github.event.pull_request.number }} \
      --yes --no-wait
```

### Running Meaningful Integration Tests

Your integration tests should exercise the real data paths your application uses:

```csharp
[Fact]
[Trait("Category", "Integration")]
public async Task CreateAndQueryOrder_ReturnsExpectedResults()
{
    var client = new CosmosClient(
        Environment.GetEnvironmentVariable("COSMOS_ENDPOINT"),
        Environment.GetEnvironmentVariable("COSMOS_KEY"),
        new CosmosClientOptions
        {
            ConnectionMode = ConnectionMode.Gateway,
            HttpClientFactory = () => new HttpClient(
                new HttpClientHandler
                {
                    ServerCertificateCustomValidationCallback =
                        HttpClientHandler.DangerousAcceptAnyServerCertificateValidator
                })
        });

    var database = await client.CreateDatabaseIfNotExistsAsync("test-db");
    var container = await database.Database.CreateContainerIfNotExistsAsync(
        "orders", "/customerId");

    // Write
    var order = new { id = Guid.NewGuid().ToString(), customerId = "C-100",
                      status = "pending", orderDate = DateTime.UtcNow };
    await container.Container.CreateItemAsync(order,
        new PartitionKey(order.customerId));

    // Query
    var query = container.Container.GetItemQueryIterator<dynamic>(
        "SELECT * FROM c WHERE c.customerId = 'C-100'");
    var results = await query.ReadNextAsync();

    Assert.Single(results);
}
```

Notice the `DangerousAcceptAnyServerCertificateValidator` — that's only for the emulator's self-signed certificate. Never ship that in production code.

## Environment Promotion: Dev → Staging → Production

With IaC templates and CI/CD in place, environment promotion becomes systematic. Here's a pattern that works well:

### One Template, Many Parameter Files

Keep a single set of Bicep or Terraform files and use **environment-specific parameter files** to vary settings per stage:

```
infra/
├── main.bicep
├── modules/
│   └── cosmos.bicep
├── parameters/
│   ├── dev.bicepparam
│   ├── staging.bicepparam
│   └── prod.bicepparam
```

Each parameter file adjusts the knobs:

```bicep
// prod.bicepparam
using '../main.bicep'

param accountName = 'cosmos-orders-prod'
param autoscaleMaxThroughput = 10000
param enableZoneRedundancy = true
param backupPolicy = 'Continuous'
```

```bicep
// dev.bicepparam
using '../main.bicep'

param accountName = 'cosmos-orders-dev'
param autoscaleMaxThroughput = 1000
param enableZoneRedundancy = false
param backupPolicy = 'Periodic'
```

### The Promotion Pipeline

A typical multi-stage pipeline looks like this:

```
PR opened
  └── CI: lint IaC + unit tests + emulator integration tests
       └── Merge to main
            └── Deploy to Dev (auto)
                 └── Run smoke tests against Dev
                      └── Deploy to Staging (auto or manual gate)
                           └── Run full integration suite against Staging
                                └── Deploy to Production (manual approval)
                                     └── Monitor + rollback if needed
```

**Key principles:**

- **Dev deploys automatically** on every merge to `main`. If it breaks, you find out fast.
- **Staging mirrors production** as closely as possible — same SKU, same throughput, same consistency level. The only difference should be the data.
- **Production requires a manual approval gate** in your pipeline. This is your last chance to review the `what-if` output before changes hit real customers.
- **Rollback** is just redeploying the previous commit's IaC templates. Because Cosmos DB indexing changes are online and throughput changes are instant, most rollbacks are seamless.

### Secrets Management Across Environments

One thing you'll need to handle carefully is Cosmos DB connection strings and keys. Never hard-code them in your IaC files or pipeline definitions. Instead:

- **Store keys in Azure Key Vault** and reference them as linked secrets in your pipeline.
- **Use Managed Identity** wherever possible — your App Service, Functions, or AKS workloads can authenticate to Cosmos DB with Microsoft Entra ID, eliminating keys entirely.
- **Rotate keys on a schedule.** Since your IaC provisions the account, you can use the `az cosmosdb keys regenerate` command in a scheduled pipeline to rotate keys without manual intervention. Your application reads the latest key from Key Vault at startup.

This ensures that as changes flow from dev through staging to production, the credentials for each environment are isolated and never cross boundaries.

### State Across Environments with Terraform

If you're using Terraform, store your state in a **remote backend** (Azure Storage, Terraform Cloud) with one state file per environment:

```hcl
terraform {
  backend "azurerm" {
    resource_group_name  = "rg-terraform-state"
    storage_account_name = "tfstatecosmosbook"
    container_name       = "tfstate"
    key                  = "prod.terraform.tfstate"  # one per env
  }
}
```

This prevents any chance of your `terraform apply` for staging accidentally mutating production resources.

## Putting It All Together: A Checklist

Before you ship to production, make sure you've covered these bases:

- [ ] All Cosmos DB resources are defined in Bicep or Terraform — nothing created by hand.
- [ ] Indexing policies and throughput settings are in your IaC templates, not adjusted through the portal.
- [ ] Your CI pipeline runs integration tests against the emulator (or an ephemeral account) on every PR.
- [ ] Ephemeral test environments are torn down automatically with cost controls in place.
- [ ] You have environment-specific parameter files for dev, staging, and production.
- [ ] Production deployments require an explicit approval gate.
- [ ] Your pipeline can roll back to a previous IaC version within minutes.
- [ ] Schema evolution follows additive patterns, with container versioning or dual-write for breaking changes.

---

## What's Next

You've now seen how to treat Cosmos DB infrastructure as code, evolve your schema safely, and automate everything through CI/CD pipelines. In **Chapter 20**, we'll get hands-on with **the Cosmos DB SDKs** — CosmosClient fundamentals, CRUD operations in code, retry policies for transient errors, bulk operations mode, performance tips, Entity Framework Core integration, and OpenTelemetry instrumentation for distributed tracing.
