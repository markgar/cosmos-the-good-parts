# Appendices

---

# Appendix A: Cosmos DB CLI and Terraform Quick Reference

## Azure CLI — Account Management

```bash
# Create a Cosmos DB account (NoSQL API, Session consistency, two regions)
az cosmosdb create \
  --name <account-name> \
  --resource-group <rg> \
  --kind GlobalDocumentDB \
  --default-consistency-level Session \
  --locations regionName=eastus failoverPriority=0 isZoneRedundant=true \
  --locations regionName=westus failoverPriority=1

# List all Cosmos DB accounts in a resource group
az cosmosdb list --resource-group <rg> --output table

# Show account details
az cosmosdb show --name <account-name> --resource-group <rg>

# Update consistency level
az cosmosdb update \
  --name <account-name> \
  --resource-group <rg> \
  --default-consistency-level BoundedStaleness

# List connection strings
az cosmosdb keys list \
  --name <account-name> \
  --resource-group <rg> \
  --type connection-strings

# List read-only keys
az cosmosdb keys list \
  --name <account-name> \
  --resource-group <rg> \
  --type read-only-keys

# Initiate failover (set new write region)
az cosmosdb failover-priority-change \
  --name <account-name> \
  --resource-group <rg> \
  --failover-policies "westus=0" "eastus=1"

# Delete account
az cosmosdb delete --name <account-name> --resource-group <rg> --yes
```

## Azure CLI — Database Operations

```bash
# Create a database
az cosmosdb sql database create \
  --account-name <account-name> \
  --resource-group <rg> \
  --name mydb

# Create a database with shared throughput
az cosmosdb sql database create \
  --account-name <account-name> \
  --resource-group <rg> \
  --name mydb \
  --throughput 400

# List databases
az cosmosdb sql database list \
  --account-name <account-name> \
  --resource-group <rg> \
  --output table

# Delete a database
az cosmosdb sql database delete \
  --account-name <account-name> \
  --resource-group <rg> \
  --name mydb --yes
```

## Azure CLI — Container Operations

```bash
# Create a container with dedicated throughput
az cosmosdb sql container create \
  --account-name <account-name> \
  --resource-group <rg> \
  --database-name mydb \
  --name mycontainer \
  --partition-key-path "/partitionKey" \
  --throughput 400

# Create a container with autoscale throughput
az cosmosdb sql container create \
  --account-name <account-name> \
  --resource-group <rg> \
  --database-name mydb \
  --name mycontainer \
  --partition-key-path "/partitionKey" \
  --max-throughput 4000

# Create with hierarchical partition key
az cosmosdb sql container create \
  --account-name <account-name> \
  --resource-group <rg> \
  --database-name mydb \
  --name mycontainer \
  --partition-key-path "/tenantId" "/userId" "/sessionId"

# Create with composite index and unique key
az cosmosdb sql container create \
  --account-name <account-name> \
  --resource-group <rg> \
  --database-name mydb \
  --name mycontainer \
  --partition-key-path "/pk" \
  --throughput 400 \
  --unique-key-policy '{"uniqueKeys":[{"paths":["/email"]}]}' \
  --idx '{"indexingMode":"consistent","automatic":true,"includedPaths":[{"path":"/*"}],"excludedPaths":[{"path":"/largeField/?"}]}'

# List containers
az cosmosdb sql container list \
  --account-name <account-name> \
  --resource-group <rg> \
  --database-name mydb \
  --output table

# Delete a container
az cosmosdb sql container delete \
  --account-name <account-name> \
  --resource-group <rg> \
  --database-name mydb \
  --name mycontainer --yes
```

## Azure CLI — Throughput Operations

```bash
# Read current throughput
az cosmosdb sql container throughput show \
  --account-name <account-name> \
  --resource-group <rg> \
  --database-name mydb \
  --name mycontainer

# Update manual throughput
az cosmosdb sql container throughput update \
  --account-name <account-name> \
  --resource-group <rg> \
  --database-name mydb \
  --name mycontainer \
  --throughput 800

# Migrate container to autoscale
az cosmosdb sql container throughput migrate \
  --account-name <account-name> \
  --resource-group <rg> \
  --database-name mydb \
  --name mycontainer \
  --throughput-type autoscale

# Migrate container to manual throughput
az cosmosdb sql container throughput migrate \
  --account-name <account-name> \
  --resource-group <rg> \
  --database-name mydb \
  --name mycontainer \
  --throughput-type manual

# Update database shared throughput
az cosmosdb sql database throughput update \
  --account-name <account-name> \
  --resource-group <rg> \
  --name mydb \
  --throughput 1000
```

## Bicep — Full Deployment Example

```bicep
@description('Cosmos DB account name')
param accountName string = 'cosmos-${uniqueString(resourceGroup().id)}'
param location string = resourceGroup().location
param databaseName string = 'mydb'
param containerName string = 'mycontainer'

resource account 'Microsoft.DocumentDB/databaseAccounts@2024-05-15' = {
  name: accountName
  location: location
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
    locations: [
      { locationName: location, failoverPriority: 0, isZoneRedundant: true }
    ]
    enableAutomaticFailover: true
    enableMultipleWriteLocations: false
    backupPolicy: {
      type: 'Periodic'
      periodicModeProperties: {
        backupIntervalInMinutes: 240
        backupRetentionIntervalInHours: 8
      }
    }
  }
}

resource database 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2024-05-15' = {
  parent: account
  name: databaseName
  properties: {
    resource: { id: databaseName }
  }
}

resource container 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-05-15' = {
  parent: database
  name: containerName
  properties: {
    resource: {
      id: containerName
      partitionKey: {
        paths: [ '/partitionKey' ]
        kind: 'Hash'
        version: 2
      }
      indexingPolicy: {
        indexingMode: 'consistent'
        automatic: true
        includedPaths: [ { path: '/*' } ]
        excludedPaths: [ { path: '/_etag/?' } ]
      }
      defaultTtl: -1
    }
    options: {
      autoscaleSettings: { maxThroughput: 4000 }
    }
  }
}

output endpoint string = account.properties.documentEndpoint
```

## Terraform — Full Deployment Example

```hcl
terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }
  }
}

provider "azurerm" { features {} }

resource "azurerm_cosmosdb_account" "main" {
  name                = "cosmos-${var.project}"
  location            = var.location
  resource_group_name = var.resource_group_name
  offer_type          = "Standard"
  kind                = "GlobalDocumentDB"

  automatic_failover_enabled = true

  consistency_policy {
    consistency_level = "Session"
  }

  geo_location {
    location          = var.location
    failover_priority = 0
    zone_redundant    = true
  }

  geo_location {
    location          = var.secondary_location
    failover_priority = 1
  }
}

resource "azurerm_cosmosdb_sql_database" "main" {
  name                = "mydb"
  resource_group_name = var.resource_group_name
  account_name        = azurerm_cosmosdb_account.main.name
}

resource "azurerm_cosmosdb_sql_container" "main" {
  name                = "mycontainer"
  resource_group_name = var.resource_group_name
  account_name        = azurerm_cosmosdb_account.main.name
  database_name       = azurerm_cosmosdb_sql_database.main.name
  partition_key_paths = ["/partitionKey"]

  autoscale_settings {
    max_throughput = 4000
  }

  indexing_policy {
    indexing_mode = "consistent"
    included_path { path = "/*" }
    excluded_path { path = "/_etag/?" }
  }

  default_ttl = -1
}

output "endpoint" {
  value = azurerm_cosmosdb_account.main.endpoint
}

output "primary_key" {
  value     = azurerm_cosmosdb_account.main.primary_key
  sensitive = true
}
```

---

# Appendix B: NoSQL Query Language Reference

## SQL Syntax Quick Reference

| Clause | Syntax | Notes |
|---|---|---|
| **SELECT** | `SELECT *`, `SELECT c.name`, `SELECT VALUE c.name` | `VALUE` unwraps to scalar/array |
| **SELECT DISTINCT** | `SELECT DISTINCT c.category` | De-duplicates results |
| **SELECT TOP** | `SELECT TOP 10 *` | Limits result count |
| **FROM** | `FROM c`, `FROM products p` | Alias optional; container is the source |
| **WHERE** | `WHERE c.price > 100` | Standard comparison, logical, arithmetic |
| **AND / OR / NOT** | `WHERE c.a = 1 AND (c.b = 2 OR c.c = 3)` | Parentheses control precedence |
| **BETWEEN** | `WHERE c.price BETWEEN 10 AND 50` | Inclusive range |
| **IN** | `WHERE c.status IN ("active", "pending")` | Set membership |
| **LIKE** | `WHERE c.name LIKE "%bike%"` | `%` = any chars, `_` = single char |
| **JOIN** | `FROM c JOIN t IN c.tags` | Intra-document join (flattens arrays) |
| **EXISTS** | `WHERE EXISTS(SELECT VALUE t FROM t IN c.tags WHERE t.k = "v")` | Subquery existence check |
| **GROUP BY** | `GROUP BY c.category` | With aggregate functions |
| **ORDER BY** | `ORDER BY c.createdAt DESC` | `ASC` (default) or `DESC`; requires index |
| **ORDER BY (multi)** | `ORDER BY c.cat ASC, c.price DESC` | Requires composite index |
| **OFFSET…LIMIT** | `OFFSET 20 LIMIT 10` | Pagination (use with ORDER BY) |

## Operators

| Category | Operators |
|---|---|
| **Comparison** | `=`, `!=`, `<`, `>`, `<=`, `>=` |
| **Arithmetic** | `+`, `-`, `*`, `/`, `%` |
| **Logical** | `AND`, `OR`, `NOT` |
| **String** | `\|\|` (concatenation), `LIKE` |
| **Ternary** | `? :` (conditional expression) |
| **Null coalescing** | `??` |
| **Bitwise** | `\|`, `&`, `^`, `<<`, `>>`, `>>>` |

## Aggregate Functions

| Function | Description |
|---|---|
| `COUNT(1)` or `COUNT(c.prop)` | Count of items/values |
| `SUM(c.amount)` | Sum of numeric values |
| `AVG(c.score)` | Average of numeric values |
| `MIN(c.price)` | Minimum value |
| `MAX(c.price)` | Maximum value |

## System Functions by Category

### String Functions

| Function | Signature |
|---|---|
| `CONCAT` | `CONCAT(str1, str2 [, strN])` |
| `CONTAINS` | `CONTAINS(str, substr [, ignoreCase])` |
| `ENDSWITH` | `ENDSWITH(str, suffix [, ignoreCase])` |
| `STARTSWITH` | `STARTSWITH(str, prefix [, ignoreCase])` |
| `INDEX_OF` | `INDEX_OF(str, substr)` |
| `LEFT` | `LEFT(str, length)` |
| `RIGHT` | `RIGHT(str, length)` |
| `SUBSTRING` | `SUBSTRING(str, startIndex, length)` |
| `LENGTH` | `LENGTH(str)` |
| `LOWER` | `LOWER(str)` |
| `UPPER` | `UPPER(str)` |
| `LTRIM` | `LTRIM(str [, chars])` |
| `RTRIM` | `RTRIM(str [, chars])` |
| `TRIM` | `TRIM(str [, chars])` |
| `REPLACE` | `REPLACE(str, find, replacement)` |
| `REPLICATE` | `REPLICATE(str, count)` |
| `REVERSE` | `REVERSE(str)` |
| `STRINGEQUALS` | `STRINGEQUALS(str1, str2 [, ignoreCase])` |
| `TOSTRING` | `TOSTRING(expr)` |
| `REGEXMATCH` | `REGEXMATCH(str, regex [, modifiers])` |
| `STRINGJOIN` | `STRINGJOIN(array, separator)` |
| `STRINGSPLIT` | `STRINGSPLIT(str, delimiter)` |

### Mathematical Functions

| Function | Signature |
|---|---|
| `ABS` | `ABS(num)` |
| `CEILING` | `CEILING(num)` |
| `FLOOR` | `FLOOR(num)` |
| `ROUND` | `ROUND(num)` |
| `TRUNC` | `TRUNC(num)` |
| `SIGN` | `SIGN(num)` |
| `SQRT` | `SQRT(num)` |
| `SQUARE` | `SQUARE(num)` |
| `POWER` | `POWER(base, exp)` |
| `EXP` | `EXP(num)` |
| `LOG` | `LOG(num [, base])` |
| `LOG10` | `LOG10(num)` |
| `RAND` | `RAND()` |
| `PI` | `PI()` |
| `NUMBERBIN` | `NUMBERBIN(num, binSize)` |
| `SIN`, `COS`, `TAN` | `SIN(radians)` |
| `ASIN`, `ACOS`, `ATAN` | `ASIN(num)` |
| `ATN2` | `ATN2(y, x)` |
| `COT` | `COT(radians)` |
| `DEGREES` | `DEGREES(radians)` |
| `RADIANS` | `RADIANS(degrees)` |
| `INTADD`, `INTSUB`, `INTMUL`, `INTDIV`, `INTMOD` | Integer arithmetic variants |
| `INTBITAND`, `INTBITOR`, `INTBITXOR`, `INTBITNOT` | Integer bitwise variants |
| `INTBITLEFTSHIFT`, `INTBITRIGHTSHIFT` | Integer bit shift variants |

### Array Functions

| Function | Signature |
|---|---|
| `ARRAY_CONCAT` | `ARRAY_CONCAT(arr1, arr2 [, arrN])` |
| `ARRAY_CONTAINS` | `ARRAY_CONTAINS(arr, value [, partialMatch])` |
| `ARRAY_CONTAINS_ALL` | `ARRAY_CONTAINS_ALL(arr, values)` |
| `ARRAY_CONTAINS_ANY` | `ARRAY_CONTAINS_ANY(arr, values)` |
| `ARRAY_LENGTH` | `ARRAY_LENGTH(arr)` |
| `ARRAY_SLICE` | `ARRAY_SLICE(arr, start [, length])` |
| `CHOOSE` | `CHOOSE(index, val1, val2 [, valN])` |
| `OBJECTTOARRAY` | `OBJECTTOARRAY(obj)` |
| `SETINTERSECT` | `SETINTERSECT(arr1, arr2)` |
| `SETUNION` | `SETUNION(arr1, arr2)` |

### Date/Time Functions

| Function | Signature |
|---|---|
| `GETCURRENTDATETIME` | `GETCURRENTDATETIME()` — ISO 8601 UTC string |
| `GETCURRENTDATETIMESTATIC` | Same value for all items in a query |
| `GETCURRENTTIMESTAMP` | `GETCURRENTTIMESTAMP()` — ms since Unix epoch |
| `GETCURRENTTIMESTAMPSTATIC` | Static version for consistent results |
| `GETCURRENTTICKS` | 100-nanosecond intervals since 0001-01-01 |
| `GETCURRENTTICKSSTATIC` | Static version for consistent results |
| `DATETIMEADD` | `DATETIMEADD(part, num, datetime)` |
| `DATETIMEDIFF` | `DATETIMEDIFF(part, start, end)` |
| `DATETIMEPART` | `DATETIMEPART(part, datetime)` |
| `DATETIMEFROMPARTS` | `DATETIMEFROMPARTS(y, m, d, h, min, s, ms)` |
| `DATETIMEBIN` | `DATETIMEBIN(datetime, part, binSize [, origin])` |
| `DATETIMETOTICKS` | `DATETIMETOTICKS(datetime)` |
| `DATETIMETOTIMESTAMP` | `DATETIMETOTIMESTAMP(datetime)` |
| `TICKSTODATETIME` | `TICKSTODATETIME(ticks)` |
| `TIMESTAMPTODATETIME` | `TIMESTAMPTODATETIME(timestamp)` |

> **Date/time parts:** `"yyyy"` (year), `"mm"` (month), `"dd"` (day), `"hh"` (hour), `"mi"` (minute), `"ss"` (second), `"ms"` (millisecond), `"mcs"` (microsecond), `"ns"` (nanosecond)

### Spatial Functions

| Function | Signature |
|---|---|
| `ST_DISTANCE` | `ST_DISTANCE(geojson1, geojson2)` — distance in meters |
| `ST_WITHIN` | `ST_WITHIN(point, polygon)` — bool |
| `ST_INTERSECTS` | `ST_INTERSECTS(geojson1, geojson2)` — bool |
| `ST_ISVALID` | `ST_ISVALID(geojson)` — bool |
| `ST_ISVALIDDETAILED` | `ST_ISVALIDDETAILED(geojson)` — { valid, reason } |
| `ST_AREA` | `ST_AREA(polygon)` — area in sq meters |

### Full-Text Search Functions

| Function | Signature |
|---|---|
| `FULLTEXTCONTAINS` | `FULLTEXTCONTAINS(path, keyword)` — bool |
| `FULLTEXTCONTAINSALL` | `FULLTEXTCONTAINSALL(path, kw1, kw2, …)` — all keywords present |
| `FULLTEXTCONTAINSANY` | `FULLTEXTCONTAINSANY(path, kw1, kw2, …)` — any keyword present |
| `FULLTEXTSCORE` | `FULLTEXTSCORE(path, keyword1, keyword2, …)` — BM25 relevance (use in ORDER BY RANK) |
| `RRF` | `RRF(score1, score2)` — reciprocal rank fusion for hybrid search |

### Vector Functions

| Function | Signature |
|---|---|
| `VECTORDISTANCE` | `VECTORDISTANCE(vec1, vec2 [, brute_force_bool] [, {distanceFunction, dataType, ...}])` |

> **Distance functions:** `cosine` (default), `euclidean`, `dotproduct`

### Type-Checking Functions

| Function | Returns `true` when… |
|---|---|
| `IS_DEFINED(expr)` | Property exists |
| `IS_NULL(expr)` | Value is `null` |
| `IS_BOOL(expr)` | Value is a boolean |
| `IS_NUMBER(expr)` | Value is a number |
| `IS_INTEGER(expr)` | Value is a 64-bit signed integer |
| `IS_FINITE_NUMBER(expr)` | Value is finite (not `Infinity`/`NaN`) |
| `IS_STRING(expr)` | Value is a string |
| `IS_ARRAY(expr)` | Value is an array |
| `IS_OBJECT(expr)` | Value is a JSON object |
| `IS_PRIMITIVE(expr)` | Value is string, bool, number, or null |

### Type-Conversion Functions

| Function | Description |
|---|---|
| `TOSTRING(expr)` | Converts to string |
| `STRINGTOBOOLEAN(str)` | Converts `"true"` / `"false"` to bool |
| `STRINGTONUMBER(str)` | Converts string to number |
| `STRINGTOOBJECT(str)` | Converts JSON string to object |
| `STRINGTOARRAY(str)` | Converts JSON string to array |
| `STRINGTONULL(str)` | Converts `"null"` to `null` |

### Conditional & Other Functions

| Function | Description |
|---|---|
| `IIF(cond, trueVal, falseVal)` | Inline conditional |
| `DOCUMENTID(item)` | Returns the internal document ID |

## Common Query Patterns

```sql
-- Point read (SDK preferred, shown for reference)
SELECT * FROM c WHERE c.id = "abc" AND c.partitionKey = "xyz"

-- Paginated results
SELECT * FROM c WHERE c.type = "order"
ORDER BY c.createdAt DESC
OFFSET 0 LIMIT 25

-- Flatten nested arrays
SELECT c.name, tag AS tagName
FROM c JOIN tag IN c.tags

-- Aggregate with grouping
SELECT c.status, COUNT(1) AS cnt, AVG(c.amount) AS avg_amt
FROM c
GROUP BY c.status

-- Cross-partition fan-out filter
SELECT * FROM c
WHERE c.createdAt >= "2024-01-01T00:00:00Z"
  AND c.createdAt <  "2025-01-01T00:00:00Z"

-- Check array membership
SELECT * FROM c
WHERE ARRAY_CONTAINS(c.roles, "admin")

-- Subquery with EXISTS
SELECT VALUE c.name FROM c
WHERE EXISTS (
  SELECT VALUE t FROM t IN c.tags WHERE t = "priority"
)
```

---

# Appendix C: Consistency Level Comparison Table

| Aspect | **Strong** | **Bounded Staleness** | **Session** | **Consistent Prefix** | **Eventual** |
|---|---|---|---|---|---|
| **Guarantee** | Linearizability | Reads lag by at most *K* versions or *T* time | Read-your-writes within session | Reads never see out-of-order writes | No ordering; replicas eventually converge |
| **Staleness bound** | 0 | *K* ops or *T* seconds (multi-region: *K* ≥ 100K, *T* ≥ 300s) | 0 (within session) | No bound (but ordered) | No bound |
| **Read RU cost** | 2× | 2× | 1× | 1× | 1× |
| **Write latency** | Highest (quorum in farthest region) | Higher (quorum within staleness window) | Low (local ack) | Low | Lowest |
| **Read latency** | Moderate | Moderate | Low | Low | Lowest |
| **Multi-region writes** | ❌ | ⚠️ Supported but not recommended | ✅ | ✅ | ✅ |
| **Typical use case** | Financial transactions | Near-strong with relaxed latency | General-purpose web/mobile (default) | Dashboards, feeds | High-throughput reads (counts, likes, IoT) |

### Decision Guidance

```
Strong:       ✓ Absolute latest data, linearizable  ✗ 2× read RUs, highest latency, single-write only
Bounded:      ✓ Strong-like with configurable lag    ✗ 2× read RUs, single-write only
Session:      ✓ Read-your-own-writes (DEFAULT)       ✓ 1× RUs, low latency, multi-region writes
Prefix:       ✓ Ordered reads, no stale ordering     ✓ 1× RUs, low latency, multi-region writes
Eventual:     ✓ Max throughput, lowest latency        ✓ 1× RUs, multi-region writes
```

---

# Appendix D: Capacity and Pricing Cheat Sheet

## RU Cost Per Operation Type

| Operation | Approximate RU Cost | Notes |
|---|---|---|
| Point read (1 KB, by ID + PK) | **1 RU** | Cheapest; always prefer over queries |
| Point read (strong/bounded) | **2 RU** | 2× for strong or bounded staleness |
| Point write (1 KB, upsert/create) | **~5–6 RU** | Scales with size and indexed properties |
| Point write (replace, 1 KB) | **~10 RU** | Slightly higher (old-index cleanup) |
| Delete (1 KB) | **~5–6 RU** | Comparable to a write |
| Simple query (single partition, indexed) | **~3–5 RU** | Equality filter on indexed property |
| Cross-partition query | **~5–50+ RU** | Multiplied by physical partitions hit |
| Full scan (no index) | **Hundreds+ RU** | Avoid in production |
| Stored procedure | **~5+ RU** | Varies with complexity |
| Transactional batch | **Sum of ops** | Atomically executed |
| Change feed read (per page) | **~1–2 RU** | Very efficient |

> RU cost scales roughly linearly with item size. A 10 KB write ≈ 50–60 RU.

## Provisioned vs. Autoscale vs. Serverless

| Aspect | **Provisioned (Manual)** | **Autoscale** | **Serverless** |
|---|---|---|---|
| Throughput model | Fixed RU/s | 10%–100% of max | Pay per RU consumed |
| Min RU/s | 400 (container) | 100 (10% of 1,000 min max) | N/A |
| Max RU/s | 1,000,000 ¹ | 1,000,000 ¹ | 5,000 burst/partition |
| Billing | Per hour at provisioned | Per hour at peak | Per RU consumed |
| Cost at steady load | Most cost-effective (if tuned) | ~1.5× manual at peak | Cheapest at low/sporadic |
| Multi-region | ✅ (RU × regions) | ✅ (RU × regions) | ❌ Single region |
| Best for | Predictable, steady | Variable, production | Dev/test, sporadic |

> ¹ Increasable via Azure support request.

## Free Tier

| Resource | Allowance |
|---|---|
| Accounts per subscription | 1 |
| Duration | Lifetime |
| Free throughput | 1,000 RU/s |
| Free storage | 25 GB |
| Max shared-throughput containers | 25 |

## Reserved Capacity

| Term | Discount | Payment |
|---|---|---|
| 1 year | ~20% | Upfront or monthly |
| 3 year | ~30% | Upfront or monthly |

Applies to provisioned throughput only. Storage billed separately.

---

# Appendix E: Service Limits and Quotas Quick Reference

## Per-Item Limits

| Resource | Limit |
|---|---|
| Maximum item size | **2 MB** (UTF-8 JSON) |
| Maximum partition key value length | **2,048 bytes** (101 bytes without large PK) |
| Maximum ID length | **1,023 bytes** |
| ID allowed characters | All Unicode except `/` and `\` |
| Maximum nesting depth | **128** levels |
| Maximum TTL value | **2,147,483,647** seconds (~68 years) |
| Numeric precision | IEEE 754 double-precision 64-bit |

## Per-Container Limits

| Resource | Limit |
|---|---|
| Max name length | **255** characters |
| Max stored procedures | **100** ¹ |
| Max UDFs | **50** ¹ |
| Max unique key constraints | **10** ¹ |
| Max paths per unique key | **16** ¹ |

> ¹ Increasable via Azure support request.

## Throughput Limits

| Resource | Provisioned | Autoscale |
|---|---|---|
| Min RU/s per container | 400 | 1,000 (max setting, scales to 100) |
| Min RU/s per database (shared) | 400 (first 25 containers) | 1,000 (first 25 containers) |
| Max RU/s per container | 1,000,000 ¹ | 1,000,000 ¹ |
| Max RU/s per physical partition | 10,000 | 10,000 |
| Max storage per logical partition | 20 GB ² | 20 GB ² |
| Max storage per container | Unlimited | Unlimited |

> ¹ Increasable via Azure support request.
> ² Use hierarchical partition keys to exceed.

## Per-Account Limits

| Resource | Limit |
|---|---|
| Max databases + containers | **500** ¹ |
| Max containers per shared-throughput DB | **25** |
| Max regions | Unlimited |
| Max custom RBAC role definitions | **100** |
| Max RBAC role assignments | **2,000** |

> ¹ Increasable to 1,000 via support request.

## Serverless-Specific Limits

| Resource | Limit |
|---|---|
| Max RU/s burst per partition | **5,000** |
| Max storage per logical partition | **20 GB** |
| Max databases + containers | **500** |
| Max regions | **1** (single region) |

## SQL Query Limits

| Resource | Limit |
|---|---|
| Max query length | **512 KB** |
| Max JOINs per query | **10** ¹ |
| Max UDFs per query | **10** ¹ |
| Max points per polygon | **4,096** |
| Max included index paths | **1,500** ¹ |
| Max excluded index paths | **1,500** ¹ |
| Max properties in composite index | **8** |
| Max composite indexes per container | **100** |

> ¹ Increasable via Azure support request.

## Per-Request Limits

| Resource | Limit |
|---|---|
| Max execution time | **5 seconds** |
| Max request size | **2 MB** |
| Max response size (per page) | **4 MB** |
| Max transactional batch operations | **100** |

> Queries exceeding limits return a continuation token — no limit on total duration across pages.

## Control Plane Rate Limits (per 5-minute window, per account)

| Operation | Limit |
|---|---|
| List / Get keys | **500** |
| Create database or container | **500** |
| Get / List databases or containers | **500** |
| Update provisioned throughput | **25** |
| Regional failover | **10 per hour** |
| All other operations | **500** |

## Authorization Token Limits

| Resource | Limit |
|---|---|
| Max primary token expiry | **15 minutes** |
| Min resource token expiry | **10 minutes** |
| Max resource token expiry | **24 hours** (default) |
| Max clock skew for token auth | **15 minutes** |
