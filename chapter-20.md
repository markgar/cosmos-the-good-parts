# Chapter 20: CI/CD, DevOps, and Infrastructure as Code

Your Cosmos DB account, databases, containers, indexing policies, throughput settings — none of it should exist because someone clicked buttons in the Azure portal. Not in production. Not even in staging. If your infrastructure isn't defined in code, versioned in Git, and deployed through a pipeline, you're one misclick away from an outage and one team member's departure away from tribal knowledge loss.

This chapter is about treating Cosmos DB resources with the same discipline you'd apply to application code: define them declaratively, test them automatically, promote them through environments, and never let a human hand touch production directly.

## Managing Cosmos DB Resources in Code

The IaC-first mindset is simple: every resource that exists in Azure should trace back to a file in your repository. Cosmos DB accounts, databases, containers, indexing policies, throughput configurations, consistency settings, RBAC assignments — all of it. If it can't be reproduced by running a deployment command against a template, it shouldn't exist.

Why does this matter more for Cosmos DB than, say, a storage account? Because Cosmos DB has *irreversible decisions*:

<!-- Source: how-to-change-capacity-mode.md -->

- You can't change a container's partition key after creation (Chapter 5).
- Unique key constraints are immutable (Chapter 2).
- Switching from serverless to provisioned throughput is a one-way trip — there's no going back.

When mistakes are permanent, you need code review, pull requests, and deployment gates — not a portal session at 2 AM.

The two dominant tools for Cosmos DB IaC are **Bicep** (Azure-native) and **Terraform** (multi-cloud). Both define the same three-level resource hierarchy: account → database → container. Both support idempotent deployments — you describe the desired state, and the engine figures out what to change. The choice between them usually comes down to your team's existing toolchain, not Cosmos DB-specific capabilities.

<!-- Source: quickstart-template-bicep.md, quickstart-terraform.md -->

## Bicep: Defining the Full Stack

Bicep is Azure's domain-specific language for ARM template deployment. It compiles to JSON ARM templates but is dramatically more readable. If your organization is Azure-only, Bicep is the natural choice — it has first-class support for every Cosmos DB resource type and gets new API versions on the same day they ship.

Here's a production-realistic Bicep template that creates a Cosmos DB account, a database, and a container with a tailored indexing policy and autoscale throughput:

```bicep
@description('Cosmos DB account name, max length 44 characters, lowercase')
param accountName string

@description('Location for the Cosmos DB account.')
param location string = resourceGroup().location

@description('The primary region for the Cosmos DB account.')
param primaryRegion string

@description('The default consistency level of the Cosmos DB account.')
@allowed([
  'Eventual'
  'ConsistentPrefix'
  'Session'
  'BoundedStaleness'
  'Strong'
])
param defaultConsistencyLevel string = 'Session'

@description('Maximum autoscale throughput for the container')
@minValue(1000)
@maxValue(1000000)
param autoscaleMaxThroughput int = 4000

// --- Account ---
resource account 'Microsoft.DocumentDB/databaseAccounts@2024-02-15-preview' = {
  name: toLower(accountName)
  location: location
  kind: 'GlobalDocumentDB'
  properties: {
    consistencyPolicy: {
      defaultConsistencyLevel: defaultConsistencyLevel
    }
    locations: [
      {
        locationName: primaryRegion
        failoverPriority: 0
        isZoneRedundant: true
      }
    ]
    databaseAccountOfferType: 'Standard'
    enableAutomaticFailover: true
    disableKeyBasedMetadataWriteAccess: true
  }
}

// --- Database ---
resource database 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2024-02-15-preview' = {
  parent: account
  name: 'ordersDb'
  properties: {
    resource: {
      id: 'ordersDb'
    }
  }
}

// --- Container ---
resource container 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-02-15-preview' = {
  parent: database
  name: 'orders'
  properties: {
    resource: {
      id: 'orders'
      partitionKey: {
        paths: ['/customerId']
        kind: 'Hash'
      }
      indexingPolicy: {
        indexingMode: 'consistent'
        includedPaths: [
          { path: '/customerId/?' }
          { path: '/status/?' }
          { path: '/orderDate/?' }
        ]
        excludedPaths: [
          { path: '/*' }
        ]
        compositeIndexes: [
          [
            { path: '/status', order: 'ascending' }
            { path: '/orderDate', order: 'descending' }
          ]
        ]
      }
      defaultTtl: -1
      uniqueKeyPolicy: {
        uniqueKeys: [
          { paths: ['/orderNumber'] }
        ]
      }
    }
    options: {
      autoscaleSettings: {
        maxThroughput: autoscaleMaxThroughput
      }
    }
  }
}
```

<!-- Source: manage-with-bicep.md, quickstart-template-bicep.md -->

A few things to notice:

**The resource provider is `Microsoft.DocumentDB/databaseAccounts`.** Yes, "DocumentDB." The ARM resource provider name has stayed the same since the DocumentDB days. Every Bicep and ARM template you'll ever write for Cosmos DB uses this provider name — it has nothing to do with the newer Azure DocumentDB (vCore) product.

<!-- Source: quickstart-template-bicep.md -->

**Account names are limited to 44 characters, all lowercase.** This becomes your endpoint URL (`https://<name>.documents.azure.com`), so keep it short and meaningful. The Bicep `toLower()` function is a safety net, but don't rely on it — name your accounts deliberately.

<!-- Source: manage-with-bicep.md -->

**`disableKeyBasedMetadataWriteAccess: true`** is a production best practice. It prevents anyone with an account key from creating or modifying databases, containers, or throughput settings through the SDK or Data Explorer. All structural changes must flow through ARM (i.e., your IaC pipeline). This is exactly the governance model you want.

<!-- Source: resource-locks.md, audit-control-plane-logs.md -->

**The indexing policy uses opt-in paths.** Instead of the default "index everything" policy, this template explicitly lists only the paths the application queries against, then excludes everything else with `/*`. This reduces write RU cost and storage. Chapter 9 covers indexing policy design in depth — the point here is that the policy is *code-reviewed and versioned*, not hand-edited in the portal.

Deploy it:

```bash
az deployment group create \
  --resource-group my-rg \
  --template-file cosmos.bicep \
  --parameters accountName=myapp-orders primaryRegion=eastus
```

## Terraform: The Multi-Cloud Alternative

If your organization uses Terraform for other cloud resources — or manages infrastructure across AWS and Azure — Terraform's `azurerm` provider covers the same Cosmos DB surface area. The resource model maps directly: `azurerm_cosmosdb_account`, `azurerm_cosmosdb_sql_database`, `azurerm_cosmosdb_sql_container`.

Here's the equivalent setup in Terraform:

```hcl
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.0, < 4.0"
    }
  }
}

provider "azurerm" {
  features {}
}

resource "azurerm_cosmosdb_account" "main" {
  name                = "myapp-orders"
  location            = "East US"
  resource_group_name = azurerm_resource_group.main.name
  offer_type          = "Standard"
  kind                = "GlobalDocumentDB"

  enable_automatic_failover = true

  consistency_policy {
    consistency_level = "Session"
  }

  geo_location {
    location          = "East US"
    failover_priority = 0
    zone_redundant    = true
  }
}

resource "azurerm_cosmosdb_sql_database" "orders" {
  name                = "ordersDb"
  resource_group_name = azurerm_resource_group.main.name
  account_name        = azurerm_cosmosdb_account.main.name
}

resource "azurerm_cosmosdb_sql_container" "orders" {
  name                = "orders"
  resource_group_name = azurerm_resource_group.main.name
  account_name        = azurerm_cosmosdb_account.main.name
  database_name       = azurerm_cosmosdb_sql_database.orders.name
  partition_key_path  = "/customerId"

  autoscale_settings {
    max_throughput = 4000
  }

  indexing_policy {
    indexing_mode = "consistent"

    included_path {
      path = "/customerId/?"
    }
    included_path {
      path = "/status/?"
    }
    included_path {
      path = "/orderDate/?"
    }
    excluded_path {
      path = "/*"
    }
  }

  unique_key {
    paths = ["/orderNumber"]
  }
}
```

<!-- Source: manage-with-terraform.md, quickstart-terraform.md -->

### Bicep vs. Terraform: Which One?

| Consideration | Bicep | Terraform |
|---|---|---|
| **Azure-only shop** | Natural fit — first-class Azure support, same-day API versions | Works, but you're adding a tool just for Azure |
| **Multi-cloud** | Not applicable | Terraform's whole reason for existing |
| **State management** | None needed — ARM is the state store | Requires a remote state backend (Azure Blob, Terraform Cloud, etc.) |
| **New Cosmos DB features** | Available immediately via API version bumps | Depends on `azurerm` provider release cycle — may lag weeks or months |
| **Team familiarity** | Lower barrier for Azure-centric teams | Lower barrier for teams already using Terraform elsewhere |
| **Drift detection** | `what-if` deployments | `terraform plan` |

Neither is wrong. Pick the one your team already knows. If you're starting fresh on Azure with no Terraform investment, Bicep has less moving parts. If you're already running Terraform for everything else, adding Cosmos DB resources to your existing modules is the obvious play.

### Key IaC Constraints to Know

A few Cosmos DB-specific constraints affect how you write templates, regardless of which tool you use:

<!-- Source: manage-with-bicep.md, manage-with-terraform.md -->

- **Throughput changes require redeployment.** To change RU/s values, update the template and redeploy. Both Bicep and Terraform handle this as an in-place update — no downtime, no recreation.
- **You can't modify regions and other properties simultaneously.** Adding or removing a region is its own deployment. Don't try to change consistency level and add a region in the same template update.
- **Throughput is set in increments of 100 RU/s** for provisioned throughput. For autoscale, the max throughput starts at 1,000 RU/s and scales in increments of 1,000 RU/s.
- **Partition keys and unique key constraints are immutable.** Get them right in the template before the first deployment. Changing them means creating a new container and migrating data.

<!-- Source: request-units.md, provision-throughput-autoscale.md -->

## Deploying Indexing Policy and Throughput Changes Without Downtime

One of Cosmos DB's underappreciated features: you can update a container's indexing policy *at any time* without affecting read or write availability. The service performs an **online, in-place index transformation** — it builds the new index in the background using your provisioned RUs at a lower priority than your application traffic. No downtime, no maintenance window, no read/write interruption.

<!-- Source: index-policy.md -->

This is a big deal for IaC workflows. It means you can safely push indexing policy changes through your CI/CD pipeline without coordinating with an application deployment. Add a composite index your new query needs, deploy the template, and the transformation runs in the background.

There are a few rules to follow:

**Adding new indexed paths doesn't affect existing queries.** Queries will only use the new index once the transformation completes. During the transformation, existing queries continue to work exactly as before.

**Removing indexed paths takes effect immediately.** The query engine stops using the dropped index right away and falls back to a full scan. If you're replacing one index with another — say, swapping a single-property index for a composite index — add the new index first, wait for the transformation to complete, *then* remove the old one. Doing both in one update can break queries that depend on the index you're removing.

<!-- Source: index-policy.md, how-to-manage-indexing-policy.md -->

**Group removals into a single update.** If you need to drop multiple indexes, do it in one indexing policy change. Multiple sequential removals can produce inconsistent query results during the intermediate transformations.

**Track transformation progress** using the `x-ms-documentdb-collection-index-transformation-progress` response header, which returns a percentage from 0 to 100. In C#:

<!-- Source: how-to-manage-indexing-policy.md -->

```csharp
ContainerResponse response = await container.ReadContainerAsync(
    new ContainerRequestOptions { PopulateQuotaInfo = true });

long progress = long.Parse(
    response.Headers["x-ms-documentdb-collection-index-transformation-progress"]);

Console.WriteLine($"Index transformation: {progress}% complete");
```

You can monitor this in your deployment pipeline: after pushing an indexing policy change, poll until the transformation reaches 100% before marking the deployment as complete.

Throughput changes are even simpler — they apply instantly. Update the `throughput` or `autoscaleSettings.maxThroughput` value in your template, redeploy, and the new value takes effect with zero downtime.

## Schema Evolution Strategies

Cosmos DB is schema-agnostic — there's no `ALTER TABLE` to run when your data model changes. That flexibility is a strength, but it doesn't mean schema evolution is free. You still need a strategy for changing document shapes without breaking running applications.

Chapter 4 covered the modeling foundations. Here, we focus on the *operational* side: how to deploy schema changes safely through your pipeline.

### Additive Changes: The Easy Path

The safest schema change is an additive one: adding a new property to your documents. Because Cosmos DB doesn't enforce a schema, existing documents without the new property continue to work. Your application code just needs to handle the absence gracefully — null checks, default values, or a `type` discriminator that tells you which version of the document you're reading.

For IaC, an additive change usually means:

1. Update your application code to write the new property and tolerate its absence on reads.
2. Deploy the application.
3. If the new property needs indexing, update the indexing policy in your Bicep/Terraform template and deploy.

No data migration. No downtime. This is the 90% case.

### Container Versioning

When you need a *breaking* change — a new partition key, a different unique key constraint, a fundamentally restructured document — you can't modify the existing container. Instead, create a new container with the desired configuration alongside the old one.

The playbook:

1. Add the new container to your IaC template (e.g., `orders-v2` alongside `orders`).
2. Deploy the template. Both containers now exist.
3. Update your application to write to *both* containers (dual-write), but read from the old one.
4. Backfill historical data from the old container into the new one, applying the new schema during the copy.
5. Switch reads to the new container.
6. Stop writing to the old container.
7. Remove the old container from your template and redeploy.

This is the same blue-green pattern you'd use for a database migration in a relational world, just without the `ALTER TABLE`. The change feed (Chapter 15) is useful for step 4 — you can consume the old container's change feed to stream documents into the new container with the updated shape.

### Dual-Write Patterns

For high-traffic systems that can't tolerate a bulk backfill, the dual-write approach extends the overlap period. During the transition, every write goes to both the old and new containers. Once all historical data is migrated and the new container is caught up, you cut over reads and decommission the old container.

The critical detail: your application must handle divergence during the transition. If a document is updated in the old container but the write to the new container fails (or vice versa), you need a reconciliation mechanism. The change feed is your friend here — it guarantees you'll eventually see every write.

Keep the transition window as short as possible. Dual-write adds latency, doubles RU cost for writes, and creates an operational complexity surface that grows with time.

## Integrating Cosmos DB into CI/CD Pipelines

The templates we've written so far deploy infrastructure. But infrastructure alone doesn't tell you whether your application actually *works* against that infrastructure. The real power of CI/CD is connecting the two: provision a Cosmos DB environment, run your tests against it, and tear it down when you're done.

### Provisioning Test Environments with the Emulator

For pull request builds and local development, the **Cosmos DB emulator** is the fastest path to a test environment — no Azure subscription required, no cloud costs, no network latency.

The Linux-based emulator (vNext) runs as a Docker container, which makes it perfect for CI pipelines:

<!-- Source: emulator-linux.md -->

```bash
docker pull mcr.microsoft.com/cosmosdb/linux/azure-cosmos-emulator:vnext-preview

docker run --detach \
  --publish 8081:8081 \
  --publish 1234:1234 \
  mcr.microsoft.com/cosmosdb/linux/azure-cosmos-emulator:vnext-preview \
  --protocol https
```

The emulator runs on port `8081` with a well-known key, so your integration tests can connect without any secrets management:

<!-- Source: emulator.md -->

| Setting | Value |
|---|---|
| **Endpoint** | `https://localhost:8081/` |
| **Key** | `C2y6yDjf5/R+ob0N8A7Cgv30VRDJIWEHLM+4QDU5DE2nQ9nDuVTqobD4b8mGGyPMbIZnqyMsEcaGQy67XIw/Jw==` |

Chapter 3 covers emulator setup in detail — including the Windows installer and HTTPS configuration. Chapter 24 covers testing patterns. Here, we'll focus on the pipeline integration.

**Emulator limitations to know in CI.** The emulator is not a complete replica of the cloud service. A few differences matter for testing:

<!-- Source: emulator.md, emulator-linux.md -->

- The vNext (Linux) emulator only supports the NoSQL API in **gateway mode**.
- You can't create a container with a custom indexing policy in the vNext emulator, but the default index-everything policy handles most query patterns — ORDER BY, range filters, joins, and aggregates all work.
- Stored procedures, triggers, and UDFs are **not planned** for the vNext emulator.
- In the Windows emulator, only **Session** and **Strong** consistency levels are supported. The emulator doesn't actually implement consistency — it just flags the configured level. (The vNext emulator docs don't document this restriction.)
- The .NET and Java SDKs require HTTPS mode. Start the emulator with `--protocol https` for those SDKs.

For anything the emulator doesn't cover — advanced indexing, multi-region behavior, serverless capacity mode — you'll need a dedicated cloud account (covered in the next section).

### The Emulator in GitHub Actions

Here's a minimal GitHub Actions workflow that starts the emulator, waits for it to be ready, runs integration tests, and tears everything down:

```yaml
name: Cosmos DB Integration Tests

on: [pull_request]

jobs:
  integration-tests:
    runs-on: ubuntu-latest

    services:
      cosmosdb:
        image: mcr.microsoft.com/cosmosdb/linux/azure-cosmos-emulator:vnext-preview
        ports:
          - 8081:8081
          - 1234:1234
        env:
          PROTOCOL: https

    steps:
      - uses: actions/checkout@v4

      - name: Wait for emulator
        run: |
          for i in $(seq 1 30); do
            curl -sk https://localhost:8081/ && break || sleep 2
          done

      - name: Run integration tests
        env:
          COSMOS_ENDPOINT: "https://localhost:8081/"
          COSMOS_KEY: "C2y6yDjf5/R+ob0N8A7Cgv30VRDJIWEHLM+4QDU5DE2nQ9nDuVTqobD4b8mGGyPMbIZnqyMsEcaGQy67XIw/Jw=="
        run: dotnet test --filter Category=Integration
```

The `services` block handles the Docker lifecycle — the container starts before your steps run and is destroyed when the job completes. No cleanup scripts, no orphaned containers.

### The Emulator in Azure DevOps

For Azure DevOps, the approach depends on your agent. The Windows-hosted agent `windows-2019` comes with the emulator preinstalled. Start it with a PowerShell task:

<!-- Source: tutorial-setup-ci-cd.md -->

```yaml
trigger:
  - main

pool:
  vmImage: windows-2019

steps:
  - task: PowerShell@2
    displayName: Start Cosmos DB Emulator
    inputs:
      targetType: inline
      script: |
        Import-Module "$env:ProgramFiles\Azure Cosmos DB Emulator\PSModules\Microsoft.Azure.CosmosDB.Emulator"
        Start-CosmosDbEmulator -NoFirewall -NoUI

  - task: DotNetCoreCLI@2
    displayName: Run Integration Tests
    inputs:
      command: test
      arguments: --filter Category=Integration
    env:
      COSMOS_ENDPOINT: "https://localhost:8081/"
      COSMOS_KEY: "C2y6yDjf5/R+ob0N8A7Cgv30VRDJIWEHLM+4QDU5DE2nQ9nDuVTqobD4b8mGGyPMbIZnqyMsEcaGQy67XIw/Jw=="
```

For Linux agents, use the Docker-based vNext emulator as shown in the GitHub Actions example.

### Provisioning Dedicated Cloud Accounts for CI

When you need to test features the emulator doesn't support — autoscale, multi-region reads, vector search, specific indexing behaviors — provision a real Cosmos DB account from your pipeline. The trick is keeping costs under control.

**Strategy 1: Shared CI account with per-PR databases.** Create a single Cosmos DB account in your CI subscription (once, via IaC) and have each pipeline run create its own database within that account. Use a naming convention that includes the PR number or build ID:

```bash
az cosmosdb sql database create \
  --account-name ci-cosmos-account \
  --resource-group ci-resources \
  --name "pr-${PR_NUMBER}"
```

After tests complete, delete the database:

```bash
az cosmosdb sql database delete \
  --account-name ci-cosmos-account \
  --resource-group ci-resources \
  --name "pr-${PR_NUMBER}" \
  --yes
```

This avoids the slow (2–3 minute) account creation step on every PR while still giving each test run isolated data.

**Strategy 2: Ephemeral accounts with serverless.** If you need account-level configuration differences between test runs, create a serverless account per pipeline run. Serverless accounts have no minimum throughput cost — you only pay for the RUs your tests actually consume. Tear down the account after the run completes.

```bash
az cosmosdb create \
  --name "ci-${BUILD_ID}" \
  --resource-group ci-resources \
  --capabilities EnableServerless \
  --locations regionName=eastus

# ... run tests ...

az cosmosdb delete \
  --name "ci-${BUILD_ID}" \
  --resource-group ci-resources \
  --yes
```

### Teardown and Cost Controls for Ephemeral Environments

CI environments that aren't cleaned up are money on fire. A few safeguards:

**Always delete in a `finally` block or post-job step.** Pipelines fail. If your teardown only runs on success, you'll accumulate orphaned resources. GitHub Actions has `if: always()` for this; Azure DevOps has `condition: always()`.

```yaml
# GitHub Actions — always runs, even if tests fail
- name: Teardown test database
  if: always()
  run: |
    az cosmosdb sql database delete \
      --account-name ci-cosmos-account \
      --resource-group ci-resources \
      --name "pr-${{ github.event.pull_request.number }}" \
      --yes
```

**Tag ephemeral resources.** Apply a `purpose: ci` tag and a `created: <timestamp>` tag to every CI-created resource. Run a nightly Azure Function or scheduled pipeline that deletes anything tagged `purpose: ci` that's older than 24 hours. This catches the ones your finally block missed.

**Set subscription-level budget alerts.** Azure Cost Management can alert you when your CI subscription hits a spending threshold. Set one at 50% and another at 80% of your monthly budget. This won't prevent overspend, but it'll wake you up before the bill gets painful.

**Use Azure Policy to cap throughput in CI subscriptions.** A built-in Azure Policy can restrict the maximum RU/s that can be provisioned in a subscription or resource group. This prevents a runaway test from provisioning 100,000 RU/s by accident.

## Environment Promotion: Dev → Staging → Production

With IaC templates and a pipeline that runs tests, the last piece is promoting changes through environments safely. The pattern is straightforward:

### One Template, Many Parameter Files

Your Bicep or Terraform template is the *same* across all environments. What changes are the *parameters*: account names, region configurations, throughput levels, and network settings. In Bicep, this means separate `.bicepparam` files:

```
infra/
├── cosmos.bicep              # The template — identical everywhere
├── params/
│   ├── dev.bicepparam        # Low throughput, single region
│   ├── staging.bicepparam    # Moderate throughput, single region
│   └── prod.bicepparam       # High throughput, multi-region, zone-redundant
```

A `dev.bicepparam` might set autoscale max throughput to 1,000 RU/s in a single region. The `prod.bicepparam` bumps it to 40,000 RU/s across two regions with zone redundancy enabled.

The Terraform equivalent uses `.tfvars` files:

```
infra/
├── main.tf
├── variables.tf
├── dev.tfvars
├── staging.tfvars
└── prod.tfvars
```

### The Promotion Pipeline

A typical pipeline has three stages, each gated:

| Stage | Trigger | Cosmos DB Actions | Gate |
|---|---|---|---|
| **Dev** | Push to `main` | Deploy template with `dev` params, run smoke tests | Automatic on test pass |
| **Staging** | Dev stage passes | Deploy template with `staging` params, run full integration suite | Manual approval |
| **Production** | Manual approval | Deploy template with `prod` params, monitor index transformation progress | N/A |

The critical principle: **the same template artifact** flows through all three stages. You don't have separate templates for dev and prod — that's how configuration drift starts. The only differences are parameter values.

### What Changes and What Doesn't

Not everything in your Cosmos DB setup should change between environments. Here's a practical breakdown:

| Configuration | Same across envs? | Notes |
|---|---|---|
| Partition key paths | ✅ Yes | Must be identical — your app logic depends on it |
| Indexing policy | ✅ Yes | Queries are the same regardless of environment |
| Unique key constraints | ✅ Yes | Data integrity rules don't change per environment |
| Container names | ✅ Yes | Application code references these |
| Account name | ❌ No | Must be globally unique per environment |
| Throughput (RU/s) | ❌ No | Dev needs 1,000; prod needs 40,000 |
| Regions and zone redundancy | ❌ No | Dev is single-region; prod is multi-region |
| Consistency level | Usually ✅ | Unless you're testing consistency-specific behavior in staging |
| Network restrictions | ❌ No | Dev allows your VPN; prod locks down to specific VNets |

### Protecting Production

Two final guardrails for your production Cosmos DB account:

**Resource locks.** Apply a `CanNotDelete` lock to your production Cosmos DB account to prevent accidental deletion. In Bicep:

```bicep
resource accountLock 'Microsoft.Authorization/locks@2020-05-01' = {
  name: '${accountName}-delete-lock'
  scope: account
  properties: {
    level: 'CanNotDelete'
    notes: 'Prevent accidental deletion of production Cosmos DB account'
  }
}
```

<!-- Source: resource-locks.md -->

Resource locks work at the management plane level. They don't prevent data operations (reads, writes, queries) — just resource-level changes like deletion or modification. Combined with `disableKeyBasedMetadataWriteAccess: true`, this means structural changes to your production account can *only* happen through ARM deployments (your pipeline) and *cannot* be accidentally deleted.

**Separate CI/CD identity from production access.** Your pipeline's service principal should have Contributor access to deploy resources but should *not* have the Cosmos DB account keys. Use RBAC data-plane roles (Chapter 17) to ensure the deployment identity can manage infrastructure but can't read or write application data. Separation of duties isn't paranoia — it's hygiene.

That's the full loop: infrastructure defined in code, tested against the emulator or a cloud account in CI, promoted through environments with parameter files, and protected in production with locks and access controls. The next chapter shifts from how you deploy Cosmos DB to how you squeeze maximum performance out of it — advanced SDK patterns for bulk operations, resilience, and observability.
