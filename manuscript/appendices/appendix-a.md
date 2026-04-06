# Appendix A: Cosmos DB CLI and Terraform Quick Reference

This appendix is a copy-paste reference card for managing Azure Cosmos DB for NoSQL from the command line and through infrastructure as code. It covers Azure CLI commands, Bicep templates, and Terraform configurations for the resources you'll deploy most often. For the full CI/CD story — pipelines, environment promotion, and deployment strategies — see Chapter 20.

> **Important:** Cosmos DB account names must be globally unique, lowercase, contain only letters, numbers, and hyphens, and be between 3–44 characters long. This applies regardless of which tool you use to create them.
<!-- Source: manage-your-account/manage-azure-cosmos-db-resources/manage-with-cli.md -->

---

## Azure CLI Commands

All commands use the `az cosmosdb` command group. You need Azure CLI 2.22.1 or later. Set these variables once and reuse them throughout your session:
<!-- Source: manage-your-account/manage-azure-cosmos-db-resources/manage-with-cli.md -->

```bash
resourceGroupName='myResourceGroup'
accountName='mycosmosaccount'
databaseName='ordersDb'
containerName='orders'
```

### Account Management

| Command | Description |
|---------|-------------|
| `az cosmosdb create` | Create account |
| `az cosmosdb show` | Get account details |
| `az cosmosdb list` | List accounts |
| `az cosmosdb update` | Update account properties |
| `az cosmosdb delete` | Delete account |

**Create an account** with Session consistency and two regions (see Chapter 3 for portal-based setup):

```bash
az cosmosdb create \
    -n $accountName \
    -g $resourceGroupName \
    --default-consistency-level Session \
    --locations regionName='East US' failoverPriority=0 isZoneRedundant=False \
    --locations regionName='West US' failoverPriority=1 isZoneRedundant=False
```
<!-- Source: manage-your-account/manage-azure-cosmos-db-resources/manage-with-cli.md -->

**Add a region** to an existing account:

```bash
az cosmosdb update -n $accountName -g $resourceGroupName \
    --locations regionName='East US' failoverPriority=0 isZoneRedundant=False \
    --locations regionName='West US' failoverPriority=1 isZoneRedundant=False \
    --locations regionName='South Central US' failoverPriority=2 isZoneRedundant=False
```

> **Gotcha:** You can't add/remove regions and change other account properties in the same operation. Region modifications must be a separate `az cosmosdb update` call.
<!-- Source: manage-your-account/manage-azure-cosmos-db-resources/manage-with-cli.md -->

**Enable multi-region writes:**

```bash
accountId=$(az cosmosdb show -g $resourceGroupName -n $accountName --query id -o tsv)
az cosmosdb update --ids $accountId --enable-multiple-write-locations true
```

### Failover

| Command | Description |
|---------|-------------|
| `az cosmosdb update` | Enable auto-failover |
| `az cosmosdb failover-priority-change` | Set/change priorities |

Use `--enable-automatic-failover true` with `update` to enable service-managed failover.

**Set failover priority:**

```bash
accountId=$(az cosmosdb show -g $resourceGroupName -n $accountName --query id -o tsv)
az cosmosdb failover-priority-change --ids $accountId \
    --failover-policies 'East US=0' 'South Central US=1' 'West US=2'
```

**Trigger manual failover** — change which region has `failoverPriority=0`:

```bash
az cosmosdb failover-priority-change --ids $accountId \
    --failover-policies 'West US=0' 'South Central US=1' 'East US=2'
```

### Keys and Connection Strings

| Command | Description |
|---------|-------------|
| `az cosmosdb keys list` | List all keys |
| `... --type read-only-keys` | Read-only keys only |
| `... --type connection-strings` | Connection strings |
| `az cosmosdb keys regenerate` | Regenerate a key |

All commands require `-n $accountName -g $resourceGroupName`. Regenerate accepts `--key-kind`: primary, primaryReadonly, secondary, secondaryReadonly.

For key rotation (see Chapter 17 for the security implications):

```bash
# Regenerate the secondary key
# Valid --key-kind values: primary, primaryReadonly, secondary, secondaryReadonly
az cosmosdb keys regenerate \
    -n $accountName \
    -g $resourceGroupName \
    --key-kind secondary
```
<!-- Source: manage-your-account/manage-azure-cosmos-db-resources/manage-with-cli.md -->

### Database Operations

All commands below use the `az cosmosdb sql database` prefix.

| Subcommand | Description |
|------------|-------------|
| `create` | Create a database |
| `show` | Show database details |
| `list` | List databases |
| `delete` | Delete a database |
| `throughput show` | Show throughput |
| `throughput update` | Update throughput |
| `throughput migrate` | Switch manual ↔ autoscale |

**Create a database:**

```bash
az cosmosdb sql database create \
    -a $accountName \
    -g $resourceGroupName \
    -n $databaseName
```

**Create a database with shared throughput** (see Chapter 11 for when shared throughput makes sense):

```bash
az cosmosdb sql database create \
    -a $accountName \
    -g $resourceGroupName \
    -n $databaseName \
    --throughput 400
```

**Migrate a database to autoscale:**

```bash
az cosmosdb sql database throughput migrate \
    -a $accountName \
    -g $resourceGroupName \
    -n $databaseName \
    -t 'autoscale'
```

### Container Operations

All commands below use the `az cosmosdb sql container` prefix.

| Subcommand | Description |
|------------|-------------|
| `create` | Create a container |
| `show` | Show container details |
| `list` | List containers |
| `update` | Update properties |
| `delete` | Delete a container |
| `throughput show` | Show throughput |
| `throughput update` | Update throughput |
| `throughput migrate` | Switch manual ↔ autoscale |

**Create a container** with a partition key and 400 RU/s (see Chapter 5 for partition key guidance):

```bash
az cosmosdb sql container create \
    -a $accountName -g $resourceGroupName \
    -d $databaseName -n $containerName \
    -p '/customerId' --throughput 400
```

**Create a container with autoscale** (max 4000 RU/s):

```bash
az cosmosdb sql container create \
    -a $accountName -g $resourceGroupName \
    -d $databaseName -n $containerName \
    -p '/customerId' --max-throughput 4000
```
<!-- Source: manage-your-account/manage-azure-cosmos-db-resources/manage-with-cli.md -->

**Enable TTL** on an existing container (86400 seconds = 1 day):

```bash
az cosmosdb sql container update \
    -g $resourceGroupName \
    -a $accountName \
    -d $databaseName \
    -n $containerName \
    --ttl=86400
```

**Migrate a container to autoscale:**

```bash
az cosmosdb sql container throughput migrate \
    -a $accountName \
    -g $resourceGroupName \
    -d $databaseName \
    -n $containerName \
    -t 'autoscale'
```

**Update container throughput** (manual):

```bash
newRU=1000

# Check minimum throughput first — you can't go below it
minRU=$(az cosmosdb sql container throughput show \
    -g $resourceGroupName -a $accountName -d $databaseName \
    -n $containerName --query resource.minimumThroughput -o tsv)

if [ $minRU -gt $newRU ]; then
    newRU=$minRU
fi

az cosmosdb sql container throughput update \
    -a $accountName \
    -g $resourceGroupName \
    -d $databaseName \
    -n $containerName \
    --throughput $newRU
```

### Resource Locks

Prevent accidental deletion of critical databases or containers:

```bash
# Lock a database
az lock create --name "$databaseName-Lock" \
    --resource-group $resourceGroupName \
    --resource-type Microsoft.DocumentDB/sqlDatabases \
    --lock-type CanNotDelete \
    --parent "databaseAccounts/$accountName" \
    --resource $databaseName

# Lock a container
az lock create --name "$containerName-Lock" \
    --resource-group $resourceGroupName \
    --resource-type Microsoft.DocumentDB/containers \
    --lock-type CanNotDelete \
    --parent "databaseAccounts/$accountName/sqlDatabases/$databaseName" \
    --resource $containerName
```
<!-- Source: manage-your-account/manage-azure-cosmos-db-resources/manage-with-cli.md -->

> **Tip:** Use `--lock-type ReadOnly` instead of `CanNotDelete` to also prevent throughput changes — useful for production containers where accidental scaling could blow your budget.

---

## Bicep Snippets

Bicep is Azure's native IaC language. It compiles down to ARM templates but is far more readable. Deploy any of these with:

```bash
az deployment group create \
    --resource-group myResourceGroup \
    --template-file main.bicep \
    --parameters primaryRegion='eastus' secondaryRegion='westus'
```

> **Important:** To change throughput (RU/s) values, redeploy the Bicep file with updated values. You can't modify throughput independently of a deployment.
<!-- Source: manage-your-account/manage-azure-cosmos-db-resources/manage-with-bicep.md -->

### Account with Multi-Region and Configurable Consistency

This is the foundation for most production deployments. It creates a NoSQL account in two regions with configurable consistency and automatic failover.

```bicep
@description('Cosmos DB account name, max length 44 characters, lowercase')
param accountName string = 'sql-${uniqueString(resourceGroup().id)}'

@description('Location for the Cosmos DB account.')
param location string = resourceGroup().location

@description('The primary region for the Cosmos DB account.')
param primaryRegion string

@description('The secondary region for the Cosmos DB account.')
param secondaryRegion string

@description('The default consistency level of the Cosmos DB account.')
@allowed([
  'Eventual'
  'ConsistentPrefix'
  'Session'
  'BoundedStaleness'
  'Strong'
])
param defaultConsistencyLevel string = 'Session'

@description('Max stale requests. Required for BoundedStaleness. Valid ranges, Single Region: 10 to 2,147,483,647. Multi Region: 100,000 to 2,147,483,647.')
@minValue(10)
@maxValue(2147483647)
param maxStalenessPrefix int = 100000

@description('Max lag time (seconds). Required for BoundedStaleness. Valid ranges, Single Region: 5 to 84,600. Multi Region: 300 to 86,400.')
@minValue(5)
@maxValue(86400)
param maxIntervalInSeconds int = 300

@description('Enable system managed failover for regions')
param systemManagedFailover bool = true

var consistencyPolicy = {
  Eventual: {
    defaultConsistencyLevel: 'Eventual'
  }
  ConsistentPrefix: {
    defaultConsistencyLevel: 'ConsistentPrefix'
  }
  Session: {
    defaultConsistencyLevel: 'Session'
  }
  BoundedStaleness: {
    defaultConsistencyLevel: 'BoundedStaleness'
    maxStalenessPrefix: maxStalenessPrefix
    maxIntervalInSeconds: maxIntervalInSeconds
  }
  Strong: {
    defaultConsistencyLevel: 'Strong'
  }
}

var locations = [
  {
    locationName: primaryRegion
    failoverPriority: 0
    isZoneRedundant: false
  }
  {
    locationName: secondaryRegion
    failoverPriority: 1
    isZoneRedundant: false
  }
]

resource account 'Microsoft.DocumentDB/databaseAccounts@2024-02-15-preview' = {
  name: toLower(accountName)
  kind: 'GlobalDocumentDB'
  location: location
  properties: {
    consistencyPolicy: consistencyPolicy[defaultConsistencyLevel]
    locations: locations
    databaseAccountOfferType: 'Standard'
    enableAutomaticFailover: systemManagedFailover
  }
}
```
<!-- Source: manage-your-account/manage-azure-cosmos-db-resources/manage-with-bicep.md -->

### Database and Container with Autoscale Throughput

Add this below the account resource. The container includes an indexing policy, composite index, TTL, and unique key constraint — the settings you'll configure most often in practice.

```bicep
@description('The name for the database')
param databaseName string

@description('The name for the container')
param containerName string

@description('Maximum autoscale throughput for the container')
@minValue(1000)
@maxValue(1000000)
param autoscaleMaxThroughput int = 1000

resource database 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2024-02-15-preview' = {
  parent: account
  name: databaseName
  properties: {
    resource: {
      id: databaseName
    }
  }
}

resource container 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-02-15-preview' = {
  parent: database
  name: containerName
  properties: {
    resource: {
      id: containerName
      partitionKey: {
        paths: [
          '/customerId'
        ]
        kind: 'Hash'
      }
      indexingPolicy: {
        indexingMode: 'consistent'
        includedPaths: [
          {
            path: '/*'
          }
        ]
        excludedPaths: [
          {
            path: '/_etag/?'
          }
        ]
        compositeIndexes: [
          [
            {
              path: '/orderDate'
              order: 'descending'
            }
            {
              path: '/totalAmount'
              order: 'descending'
            }
          ]
        ]
      }
      defaultTtl: 86400
      uniqueKeyPolicy: {
        uniqueKeys: [
          {
            paths: [
              '/email'
            ]
          }
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
<!-- Source: manage-your-account/manage-azure-cosmos-db-resources/manage-with-bicep.md -->

### Stored Procedure, Trigger, and UDF

These resources are children of the container. Add them after the container definition.

```bicep
resource storedProcedure 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/storedProcedures@2022-05-15' = {
  parent: container
  name: 'myStoredProcedure'
  properties: {
    resource: {
      id: 'myStoredProcedure'
      body: 'function () { var context = getContext(); var response = context.getResponse(); response.setBody(\'Hello, World\'); }'
    }
  }
}

resource trigger 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/triggers@2022-05-15' = {
  parent: container
  name: 'validateTimestamp'
  properties: {
    resource: {
      id: 'validateTimestamp'
      triggerType: 'Pre'
      triggerOperation: 'Create'
      body: 'function validateToDoItemTimestamp(){var context=getContext();var request=context.getRequest();var itemToCreate=request.getBody();if(!(\'timestamp\'in itemToCreate)){var ts=new Date();itemToCreate[\'timestamp\']=ts.getTime();}request.setBody(itemToCreate);}'
    }
  }
}

resource userDefinedFunction 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/userDefinedFunctions@2022-05-15' = {
  parent: container
  name: 'calculateTax'
  properties: {
    resource: {
      id: 'calculateTax'
      body: 'function tax(income){if(income==undefined)throw\'no input\';if(income<1000)return income*0.1;else if(income<10000)return income*0.2;else return income*0.4;}'
    }
  }
}
```
<!-- Source: manage-your-account/manage-azure-cosmos-db-resources/manage-with-bicep.md -->

### Free Tier Account

One free-tier account per Azure subscription. Includes 1000 RU/s and 25 GB of storage at no cost.

```bicep
resource account 'Microsoft.DocumentDB/databaseAccounts@2023-11-15' = {
  name: toLower(accountName)
  location: location
  properties: {
    enableFreeTier: true
    databaseAccountOfferType: 'Standard'
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
    locations: [
      {
        locationName: location
      }
    ]
  }
}
```
<!-- Source: manage-your-account/manage-azure-cosmos-db-resources/manage-with-bicep.md -->

### RBAC Role Definition and Assignment

For keyless authentication with Microsoft Entra ID (see Chapter 17):

```bicep
@description('Object ID of the Microsoft Entra identity. Must be a GUID.')
param principalId string

var roleDefinitionId = guid('sql-role-definition-', principalId, databaseAccount.id)
var roleAssignmentId = guid(roleDefinitionId, principalId, databaseAccount.id)

resource sqlRoleDefinition 'Microsoft.DocumentDB/databaseAccounts/sqlRoleDefinitions@2024-11-15' = {
  parent: databaseAccount
  name: roleDefinitionId
  properties: {
    roleName: 'Read Write Role'
    type: 'CustomRole'
    assignableScopes: [
      databaseAccount.id
    ]
    permissions: [
      {
        dataActions: [
          'Microsoft.DocumentDB/databaseAccounts/readMetadata'
          'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/*'
        ]
      }
    ]
  }
}

resource sqlRoleAssignment 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-11-15' = {
  parent: databaseAccount
  name: roleAssignmentId
  properties: {
    roleDefinitionId: sqlRoleDefinition.id
    principalId: principalId
    scope: databaseAccount.id
  }
}
```
<!-- Source: manage-your-account/manage-azure-cosmos-db-resources/manage-with-bicep.md -->

---

## Terraform Snippets

These use the `azurerm` provider. Start every Terraform project with the provider block:

```hcl
terraform {
  required_version = ">= 1.0"

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
```
<!-- Source: manage-your-account/manage-azure-cosmos-db-resources/manage-with-terraform.md -->

### Account with Multi-Region and Consistency Policy

```hcl
resource "azurerm_resource_group" "cosmos" {
  name     = "rg-cosmos-orders"
  location = "East US"
}

resource "azurerm_cosmosdb_account" "orders" {
  name                      = "cosmos-orders-prod"
  location                  = azurerm_resource_group.cosmos.location
  resource_group_name       = azurerm_resource_group.cosmos.name
  offer_type                = "Standard"
  kind                      = "GlobalDocumentDB"
  enable_automatic_failover = true

  geo_location {
    location          = "East US"
    failover_priority = 0
  }

  geo_location {
    location          = "West US"
    failover_priority = 1
  }

  consistency_policy {
    consistency_level       = "Session"
  }
}
```
<!-- Source: manage-your-account/manage-azure-cosmos-db-resources/manage-with-terraform.md -->

### Database and Container with Autoscale

```hcl
variable "max_throughput" {
  type        = number
  default     = 4000
  description = "Autoscale max throughput (1,000–1,000,000, increments of 100)"

  validation {
    condition     = var.max_throughput >= 4000 && var.max_throughput <= 1000000
    error_message = "Autoscale max throughput must be between 4,000 and 1,000,000."
  }

  validation {
    condition     = var.max_throughput % 100 == 0
    error_message = "Max throughput must be in increments of 100."
  }
}

resource "azurerm_cosmosdb_sql_database" "orders" {
  name                = "ordersDb"
  resource_group_name = azurerm_resource_group.cosmos.name
  account_name        = azurerm_cosmosdb_account.orders.name

  autoscale_settings {
    max_throughput = var.max_throughput
  }
}

resource "azurerm_cosmosdb_sql_container" "orders" {
  name                  = "orders"
  resource_group_name   = azurerm_resource_group.cosmos.name
  account_name          = azurerm_cosmosdb_account.orders.name
  database_name         = azurerm_cosmosdb_sql_database.orders.name
  partition_key_path    = "/customerId"
  partition_key_version = 1

  autoscale_settings {
    max_throughput = var.max_throughput
  }

  indexing_policy {
    indexing_mode = "consistent"

    included_path {
      path = "/*"
    }

    excluded_path {
      path = "/excluded/?"
    }
  }

  unique_key {
    paths = ["/email"]
  }
}
```
<!-- Source: manage-your-account/manage-azure-cosmos-db-resources/manage-with-terraform.md -->

### Database and Container with Manual Throughput

Use `throughput` instead of `autoscale_settings` when you want fixed RU/s (see Chapter 11 for the tradeoffs):

```hcl
resource "azurerm_cosmosdb_sql_database" "orders" {
  name                = "ordersDb"
  resource_group_name = azurerm_resource_group.cosmos.name
  account_name        = azurerm_cosmosdb_account.orders.name
  throughput          = 400
}

resource "azurerm_cosmosdb_sql_container" "orders" {
  name                  = "orders"
  resource_group_name   = azurerm_resource_group.cosmos.name
  account_name          = azurerm_cosmosdb_account.orders.name
  database_name         = azurerm_cosmosdb_sql_database.orders.name
  partition_key_path    = "/customerId"
  partition_key_version = 1
  throughput            = 400

  indexing_policy {
    indexing_mode = "consistent"

    included_path {
      path = "/*"
    }

    excluded_path {
      path = "/_etag/?"
    }
  }
}
```
<!-- Source: manage-your-account/manage-azure-cosmos-db-resources/manage-with-terraform.md -->

### Stored Procedure, Trigger, and UDF

```hcl
resource "azurerm_cosmosdb_sql_stored_procedure" "hello" {
  name                = "helloWorld"
  resource_group_name = azurerm_resource_group.cosmos.name
  account_name        = azurerm_cosmosdb_account.orders.name
  database_name       = azurerm_cosmosdb_sql_database.orders.name
  container_name      = azurerm_cosmosdb_sql_container.orders.name

  body = "function () { var context = getContext(); var response = context.getResponse(); response.setBody('Hello, World'); }"
}

resource "azurerm_cosmosdb_sql_trigger" "validate_timestamp" {
  name         = "validateTimestamp"
  container_id = azurerm_cosmosdb_sql_container.orders.id
  body         = "function validateToDoItemTimestamp(){var context=getContext();var request=context.getRequest();var itemToCreate=request.getBody();if(!('timestamp'in itemToCreate)){var ts=new Date();itemToCreate['timestamp']=ts.getTime();}request.setBody(itemToCreate);}"
  operation    = "Create"
  type         = "Pre"
}

resource "azurerm_cosmosdb_sql_function" "calculate_tax" {
  name         = "calculateTax"
  container_id = azurerm_cosmosdb_sql_container.orders.id
  body         = "function tax(income){if(income==undefined)throw'no input';if(income<1000)return income*0.1;else if(income<10000)return income*0.2;else return income*0.4;}"
}
```
<!-- Source: manage-your-account/manage-azure-cosmos-db-resources/manage-with-terraform.md -->

### Free Tier Account

```hcl
resource "azurerm_cosmosdb_account" "free" {
  name                      = "cosmos-dev-free"
  location                  = azurerm_resource_group.cosmos.location
  resource_group_name       = azurerm_resource_group.cosmos.name
  offer_type                = "Standard"
  kind                      = "GlobalDocumentDB"
  enable_automatic_failover = false
  enable_free_tier          = true

  geo_location {
    location          = azurerm_resource_group.cosmos.location
    failover_priority = 0
  }

  consistency_policy {
    consistency_level = "Session"
  }
}
```
<!-- Source: manage-your-account/manage-azure-cosmos-db-resources/manage-with-terraform.md -->

### RBAC Role Definition and Assignment

```hcl
data "azurerm_client_config" "current" {}

resource "azurerm_cosmosdb_sql_role_definition" "read_write" {
  name                = "ordersReadWrite"
  resource_group_name = azurerm_resource_group.cosmos.name
  account_name        = azurerm_cosmosdb_account.orders.name
  type                = "CustomRole"
  assignable_scopes   = [azurerm_cosmosdb_account.orders.id]

  permissions {
    data_actions = [
      "Microsoft.DocumentDB/databaseAccounts/readMetadata",
      "Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/*"
    ]
  }
}

resource "azurerm_cosmosdb_sql_role_assignment" "app" {
  resource_group_name = azurerm_resource_group.cosmos.name
  account_name        = azurerm_cosmosdb_account.orders.name
  role_definition_id  = azurerm_cosmosdb_sql_role_definition.read_write.id
  principal_id        = data.azurerm_client_config.current.object_id
  scope               = azurerm_cosmosdb_account.orders.id
}
```
<!-- Source: manage-your-account/manage-azure-cosmos-db-resources/manage-with-terraform.md -->

---

## Bicep vs. Terraform at a Glance

| Aspect | Bicep | Terraform |
|--------|-------|-----------|
| **Provider** | Native ARM | `azurerm` (HashiCorp) |
| **State** | Azure-managed | Self-managed `.tfstate` |
| **Multi-cloud** | Azure only | Any cloud |
| **Resources** | `Microsoft.DocumentDB/...` | `azurerm_cosmosdb_...` |
| **Throughput** | Redeploy template | `terraform apply` |
| **RBAC** | `sqlRoleDefinitions` | `..._sql_role_definition` |

- **Resource types:** Bicep uses `Microsoft.DocumentDB/databaseAccounts` and child resources. Terraform uses `azurerm_cosmosdb_account`, `azurerm_cosmosdb_sql_database`, `azurerm_cosmosdb_sql_container`, etc.
- **State management:** Terraform requires a remote backend (Azure Storage, Terraform Cloud) for team use. Bicep state is handled by Azure Resource Manager automatically.
- **RBAC:** Bicep uses `sqlRoleDefinitions` / `sqlRoleAssignments` child resources. Terraform uses `azurerm_cosmosdb_sql_role_definition` / `azurerm_cosmosdb_sql_role_assignment`.

Both tools are fully capable for Cosmos DB deployments. If your team is Azure-only, Bicep's zero-config state management is hard to beat. If you're multi-cloud or already standardized on Terraform, stick with what you know. Chapter 20 covers how to wire either into a CI/CD pipeline.
