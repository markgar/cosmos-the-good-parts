# Chapter 3: Setting Up Cosmos DB for NoSQL

You've got the mental model — accounts, databases, containers, items, RUs, partitions. Now it's time to make it real. This chapter walks you through everything it takes to go from zero to a working Cosmos DB environment: creating an account, understanding the settings that matter (and the ones you can skip), spinning up your first database and container, and writing your first item — both through the portal and through code. We'll also spend serious time on the local emulator, because being able to develop without an internet connection or an Azure bill is a superpower you'll use daily.

## Creating a Cosmos DB Account in the Azure Portal

Every Cosmos DB journey starts with an account. The account is the top-level resource — it gives you a unique DNS endpoint, holds your region configuration, and anchors all your databases and containers. Here's how to create one.

<!-- Source: quickstart-portal.md, how-to-create-account.md -->

1. Sign in to the [Azure portal](https://portal.azure.com).
2. Type **Azure Cosmos DB** in the global search bar and select the service.
3. Click **Create**, then choose **Azure Cosmos DB for NoSQL**.
4. Fill in the **Basics** pane:

| Setting | What to Enter |
|---------|---------------|
| **Subscription** | Your Azure subscription |
| **Resource Group** | New or existing |
| **Account Name** | Globally unique; 3–44 chars* |
| **Location** | Azure region nearest your users |
| **Capacity mode** | Provisioned or Serverless |
| **Free Tier Discount** | **Apply** (if available) |

*Account name allows lowercase letters, numbers, and hyphens. It becomes your endpoint: `https://<account-name>.documents.azure.com`.

<!-- Source: how-to-create-account.md, quickstart-portal.md -->

5. Click **Review + create**, wait for validation, then click **Create**.
6. Deployment takes a couple of minutes. When it finishes, click **Go to resource**.

That's it. You have a Cosmos DB account.

A few notes on those settings:

- **Account name** can't be changed after creation — it's baked into your endpoint URL. Pick something meaningful.
- **Location** determines your primary region; you can add more regions later.
- **Capacity mode** is nearly permanent. You can convert a serverless account to provisioned throughput, but the change is irreversible — you can't switch back. Provisioned accounts can't be converted to serverless. Choose deliberately. <!-- Source: how-to-change-capacity-mode.md -->

If you're just learning, **free tier** (covered below) is the best starting point — you get 1,000 RU/s free for the lifetime of the account. If you'd rather skip the free tier commitment and just pay per request while experimenting, serverless is the alternative.

### The CLI and IaC Alternatives

The portal is fine for learning. For production, you'll want to script account creation. Here's the Azure CLI version:

```bash
az cosmosdb create \
    --resource-group msdocs-cosmos \
    --name my-cosmos-account \
    --locations regionName=westus \
    --default-consistency-level Session
```

<!-- Source: how-to-create-account.md -->

And the PowerShell equivalent:

```powershell
New-AzCosmosDBAccount `
    -ResourceGroupName "msdocs-cosmos" `
    -Name "my-cosmos-account" `
    -Location "West US" `
    -ApiKind "sql" `
    -DefaultConsistencyLevel "Session"
```

<!-- Source: how-to-create-account.md -->

Bicep and Terraform templates work too — any approach that lets you check your infrastructure into source control. We'll cover infrastructure-as-code patterns for Cosmos DB in Chapter 20.

## Understanding Account-Level Settings and Free Tier

Once your account exists, a handful of account-level settings shape how everything inside it behaves. You don't need to memorize all of them now, but you should know the important ones.

**Default consistency level.** This controls the default consistency guarantee for reads across the account. It defaults to **Session**, which is the right choice for most applications. You can always override it per-request in your SDK code. We'll cover consistency in depth in Chapter 13.

**Geo-replication.** You can add or remove Azure regions at any time from the **Replicate data globally** blade. Adding a region replicates all your data there and gives your users lower-latency reads from the nearest region. We'll cover multi-region configuration in Chapter 12.

**Multi-region writes.** Disabled by default. When enabled, every region can accept writes — not just reads. This unlocks the 99.999% read-and-write availability SLA but introduces conflict resolution complexity. Again, Chapter 12.

**Networking.** By default, your account is accessible from all networks. You can restrict access to specific virtual networks, private endpoints, or IP ranges. Chapter 17 covers this in detail.

### Free Tier

If you're learning, prototyping, or running a small workload, **free tier** is your best friend. It gives you **1,000 RU/s of throughput and 25 GB of storage, free for the lifetime of the account**. Not a trial. Not 30 days. The lifetime of the account. <!-- Source: free-tier.md -->

The rules are simple:

- One free tier account per Azure subscription. <!-- Source: free-tier.md -->
- You must opt in at account creation — you can't enable it after the fact. <!-- Source: free-tier.md -->
- Free tier is available for all API types and works with provisioned throughput, autoscale, and single or multi-region configurations. Free tier is *not* available for serverless accounts — if you chose serverless above, you can't combine it with free tier. <!-- Source: free-tier.md -->
- The free tier discount is applied as a credit. Anything beyond 1,000 RU/s or 25 GB is billed at regular rates. <!-- Source: free-tier.md -->

If you combine free tier with an Azure free account (which gives an additional 400 RU/s and 25 GB for the first 12 months), you get a combined 1,400 RU/s and 50 GB to start. After the Azure free account period expires, you keep the Cosmos DB free tier indefinitely. <!-- Source: free-tier.md -->

For the full pricing picture — provisioned vs. serverless costs, autoscale economics, reserved capacity discounts — see Chapter 11.

## Creating Databases and Containers

With your account ready, you need a database and at least one container before you can store any data. As Chapter 2 explained, a database is just a namespace — a logical grouping. The container is where the action is.

### Creating a Database and Container in the Portal

1. In your Cosmos DB account, select **Data Explorer** from the left menu.
2. Click **New Container**.
3. Fill in the dialog:

| Setting | Value |
|---------|-------|
| **Database id** | `cosmicworks` (Create new) |
| **Share throughput** | Your choice* |
| **Container id** | `products` |
| **Partition key** | `/category`† |
| **Container throughput** | Autoscale or Manual |
| **Max RU/s** (autoscale) | `1000` |

*Check this to provision RU/s at the database level, shared across up to 25 containers. Leave unchecked for dedicated container throughput.

†Choose carefully — partition keys can't be changed after creation. Autoscale scales between 10% and 100% of the max RU/s value.

<!-- Source: quickstart-portal.md, resource-model.md -->

4. Click **OK**.

You'll see the new database and container appear in the Data Explorer tree. Expand the container node to see its configuration — partition key, indexing policy, throughput settings.

### Shared vs. Dedicated Throughput

When you create a container, you need to decide whether it gets its own throughput or shares it with other containers at the database level. Here's the quick version:

- **Dedicated throughput**: This container gets its own reserved RU/s. Use this for containers with predictable, high-traffic workloads.
- **Shared throughput**: RU/s are provisioned at the database level and shared across up to 25 containers. Good for multiple small containers with similar workload patterns. <!-- Source: resource-model.md -->

You can't switch a container between shared and dedicated throughput after creation. You'd have to create a new container and copy the data. Plan this up front. <!-- Source: resource-model.md -->

### Seeding Sample Data

The examples throughout this book use a fictional retail dataset called **CosmicWorks** — the same sample data Microsoft uses in its official quickstarts and tutorials. You have three ways to populate your account with it:

- **One-click in the portal.** In Data Explorer, select **Quick Start** and choose the sample container option. This creates a `cosmicworks` database with a few hundred product documents — enough to follow along with most examples.
- **The CosmicWorks CLI tool.** For a larger dataset, install the command-line generator from [Azure-Samples/cosmicworks](https://github.com/Azure-Samples/cosmicworks). It works with both cloud accounts and the local emulator.
- **The CosmicWorks .NET library.** The [AzureCosmosDB/CosmicWorks](https://github.com/AzureCosmosDB/CosmicWorks) repository includes a data generator you can integrate into your own setup scripts. It's based on the Adventure Works schema, adapted for document modeling.

Any of these will give you a working dataset to query against as you read.

### Creating via the SDK

You can also create databases and containers programmatically. Here's the .NET approach:

```csharp
Database database = await client.CreateDatabaseIfNotExistsAsync("cosmicworks");

Container container = await database.CreateContainerIfNotExistsAsync(
    id: "products",
    partitionKeyPath: "/category",
    throughput: 400
);
```

And Python:

```python
database = client.create_database_if_not_exists("cosmicworks")

container = database.create_container_if_not_exists(
    id="products",
    partition_key=PartitionKey(path="/category"),
    offer_throughput=400
)
```

Both `CreateDatabaseIfNotExistsAsync` and `create_database_if_not_exists` are idempotent — they create the resource if it doesn't exist and return the existing one if it does. That's the method you want for application startup code, not raw `Create`, which throws if the resource already exists.

## Connection Strings, Endpoints, and Keys

To connect your application to Cosmos DB, you need two pieces of information: the **account endpoint** and an **authentication credential**.

Your account endpoint looks like this:

```
https://<account-name>.documents.azure.com:443/
```

For authentication, Cosmos DB supports two approaches:

**Primary/secondary keys.** These are long-lived, base64-encoded strings that grant full access to everything in the account. You'll find them under **Settings → Keys** in the portal. There are read-write keys and read-only keys. The full connection string (which bundles the endpoint and key together) is also available on this page and looks like:

```
AccountEndpoint=https://<account-name>.documents.azure.com:443/;AccountKey=<your-key>;
```

**Microsoft Entra ID (Azure AD) authentication.** The recommended approach for production. Instead of passing keys around, your application authenticates using an identity (managed identity, service principal, or user credential) and role-based access control (RBAC) governs what it can do. This is more secure because there are no long-lived secrets to rotate or leak.

For getting started and local development, keys are convenient. For anything beyond that, Entra ID with RBAC is the right choice. We'll cover the security implications, key rotation strategies, and RBAC configuration in Chapter 17.

> **Gotcha:** Primary and secondary keys are account-wide. Anyone with a read-write key has full access to every database, every container, every item in the account. Treat them like root passwords. Don't check them into source control. Don't put them in client-side code.

## Introduction to the Azure Cosmos DB Data Explorer

The **Data Explorer** is the built-in web UI for interacting with your Cosmos DB data. You can access it two ways:

- **In the Azure portal**: Navigate to your Cosmos DB account and select **Data Explorer** from the left menu. <!-- Source: data-explorer.md -->
- **Standalone at cosmos.azure.com**: The dedicated Data Explorer at `https://cosmos.azure.com` gives you a full-screen experience with the same capabilities, plus the ability to share query results with people who don't have portal access. <!-- Source: data-explorer.md -->

What can you do in Data Explorer?

- **Browse data.** Expand the tree to drill into databases, containers, and individual items. You can view items as JSON and filter by partition key.
- **Create and edit items.** Click **New Item** to write JSON directly, or select an existing item to modify it.
- **Run queries.** Select **New SQL Query** to open a query editor. Write SQL-like queries, execute them, and see results — including query stats like RU charge and index utilization.
- **Manage resources.** Create and delete databases, containers, and even stored procedures from the UI.
- **Customize columns.** The Custom Column Selector lets you pick which properties appear as columns in the item list — handy when your documents have many fields and you want to focus on the ones that matter. <!-- Source: data-explorer.md -->

Data Explorer is invaluable for ad-hoc exploration, quick debugging, and learning the query language. It's not a production tool — you won't build your application on it — but you'll keep it open in a browser tab constantly during development.

### A Quick Walkthrough

Let's create an item and query it, right in the portal. This will ground the concepts from Chapter 2 in something tangible.

1. In Data Explorer, expand your **cosmicworks** database and **products** container, then click **Items**.
2. Click **New Item**.
3. Replace the default JSON with:

```json
{
  "id": "surfboard-001",
  "category": "gear-surf-surfboards",
  "name": "Yamba Surfboard",
  "quantity": 12,
  "price": 850.00,
  "clearance": false
}
```

4. Click **Save**. Cosmos DB stores the item and adds system properties (`_rid`, `_self`, `_etag`, `_ts`) automatically.

5. Now run a query. Click **New SQL Query** and enter:

```sql
SELECT p.name, p.price, p.quantity
FROM products p
WHERE p.category = "gear-surf-surfboards"
```

6. Click **Execute Query**. You'll see the result set and, in the **Query Stats** tab, the RU charge for the query.

That's the full loop: create an item, query it, observe the cost. Everything else in this book is about doing this faster, cheaper, and at scale.

## The VS Code Extension for Cosmos DB

If you live in Visual Studio Code (and most developers do), the **DocumentDB for Visual Studio Code** extension brings Cosmos DB management into your editor. <!-- Source: visual-studio-code-extension.md -->

### Installation

1. Open VS Code.
2. Go to **Extensions** (Ctrl+Shift+X on Windows, Cmd+Shift+X on macOS).
3. Search for **DocumentDB for Visual Studio Code** and install it.
4. Reload VS Code if prompted.

<!-- Source: visual-studio-code-extension.md -->

### Connecting to Your Account

1. Open the **Azure** pane (the Azure icon in the Activity Bar).
2. Sign in via Microsoft Entra ID.
3. Expand your subscription to find your Cosmos DB account.

<!-- Source: visual-studio-code-extension.md -->

### What You Can Do

- **Query editor.** Right-click a container to open the Query Editor (preview). Run queries and view results in table, JSON, or tree format. The Stats tab shows query metrics and index usage — the same diagnostic data you'd see in the portal. <!-- Source: visual-studio-code-extension.md -->
- **Document editing.** Add, view, edit, and delete items directly. You can also import data from JSON files. <!-- Source: visual-studio-code-extension.md -->
- **Export results.** Download query results as CSV or JSON. <!-- Source: visual-studio-code-extension.md -->

The VS Code extension is especially useful when you're writing code and need to inspect data without leaving your editor. It doesn't replace the portal for complex tasks, but for the daily workflow of "run a query, check an item, tweak some data," it's faster.

## The Cosmos DB Emulator

This is the section where we go deep. If you need to run Cosmos DB locally — for development, testing, or CI/CD — this is the reference.

The Azure Cosmos DB emulator provides a local environment that emulates the cloud Cosmos DB service. You can develop and test without an Azure subscription, without internet access, and without incurring any service costs. When your application works against the emulator, switching to the cloud service is a connection string change. <!-- Source: emulator.md -->

There are two flavors of the emulator, and they're quite different.

### The Windows Installer (Legacy Emulator)

This is the original emulator. It's a Windows application that installs locally and runs as a Windows service. It's been around for years, it's stable, and it supports the broadest set of features.

**Installation:**

1. Download the installer from [https://aka.ms/cosmosdb-emulator](https://aka.ms/cosmosdb-emulator).
2. Run the installer with administrative privileges.
3. The emulator installs developer certificates and configures firewall rules automatically.

<!-- Source: how-to-develop-emulator.md -->

**Starting the emulator:**

After installation, the emulator starts automatically and opens a browser to the local Data Explorer at `https://localhost:8081/_explorer/index.html`. You can also start it from the Start menu or via PowerShell.

**Requirements:** <!-- Source: how-to-develop-emulator.md -->

- 64-bit Windows Server 2016/2019 or Windows 10/11
- Minimum 2 GB RAM, 10 GB disk space

**Authentication credentials:**

Every emulator instance uses the same well-known credentials by default:

- **Endpoint:** `https://localhost:8081`
- **Key:** `C2y6yDjf5/R+ob0N8A7Cgv30VRDJIWEHLM+4QDU5DE2nQ9nDuVTqobD4b8mGGyPMbIZnqyMsEcaGQy67XIw/Jw==`
- **Connection string:** `AccountEndpoint=https://localhost:8081/;AccountKey=C2y6yDjf5/R+ob0N8A7Cgv30VRDJIWEHLM+4QDU5DE2nQ9nDuVTqobD4b8mGGyPMbIZnqyMsEcaGQy67XIw/Jw==;`

<!-- Source: emulator.md -->

Yes, that key is the same for every developer on every machine. It's well-known and published in the docs. This is intentional — the emulator is for local development only and should never be used for production workloads. If you need a custom key, you can specify one at startup with the `/Key` parameter. <!-- Source: emulator.md, emulator-windows-arguments.md -->

**Command-line control:**

The Windows emulator executable (`Microsoft.Azure.Cosmos.Emulator.exe`) accepts a rich set of parameters. Here are the most useful ones:

| Parameter | Description | Default |
|-----------|-------------|---------|
| `/Port` | Gateway port | `8081` |
| `/Key` | Custom auth key* | Well-known key |
| `/DataPath` | Data file path | See note† |
| `/PartitionCount` | Max partitioned containers | `25` (max `250`) |
| `/Consistency` | Default consistency level | `Session` |
| `/NoUI` | Suppress emulator UI | — |
| `/Shutdown` | Shut down emulator | — |
| `/ResetDataPath` | Clear all emulator data | — |
| `/AllowNetworkAccess` | Enable network access* | — |

*`/Key` accepts a base-64 encoded 64-byte vector. `/AllowNetworkAccess` requires `/Key` to be set.

†Default data path: `%LocalAppData%\CosmosDBEmulator`.

<!-- Source: emulator-windows-arguments.md -->

**PowerShell module:**

The emulator ships with a PowerShell module for programmatic control:

```powershell
Import-Module "$env:ProgramFiles\Azure Cosmos DB Emulator\PSModules\Microsoft.Azure.CosmosDB.Emulator"

# Start the emulator and wait for it to be ready
Start-CosmosDbEmulator

# Check status
Get-CosmosDbEmulatorStatus

# Stop
Stop-CosmosDbEmulator
```

<!-- Source: emulator-windows-arguments.md -->

The PowerShell cmdlets accept the same configuration options as the command-line arguments — consistency level, port numbers, partition count, and so on — as named parameters on `Start-CosmosDbEmulator`.

### The Linux-Based vNext Emulator (Docker)

The newer emulator is entirely Linux-based and ships as a Docker container. It's the recommended path if you're on macOS, Linux, or if you want a container-native workflow for CI/CD pipelines. At the time of writing, it's in **preview**. <!-- Source: emulator-linux.md -->

**Prerequisites:** [Docker Desktop](https://www.docker.com/) (or any Docker-compatible runtime).

**Pull the image:**

```bash
docker pull mcr.microsoft.com/cosmosdb/linux/azure-cosmos-emulator:vnext-preview
```

<!-- Source: emulator-linux.md -->

The image is published on the Microsoft Artifact Registry (MCR) under `mcr.microsoft.com/cosmosdb/linux/azure-cosmos-emulator:vnext-preview`.

**Run the emulator:**

```bash
docker run \
    --detach \
    --publish 8081:8081 \
    --publish 1234:1234 \
    mcr.microsoft.com/cosmosdb/linux/azure-cosmos-emulator:vnext-preview
```

<!-- Source: emulator-linux.md -->

Two ports are exposed:

- **Port 8081** — the Cosmos DB gateway endpoint (same as the Windows emulator)
- **Port 1234** — the Data Explorer web UI

<!-- Source: emulator-linux.md -->

Once the container is running, the gateway endpoint is available at `http://localhost:8081` and the Data Explorer at `http://localhost:1234`. The gateway is typically available immediately; the Data Explorer may take a few seconds. <!-- Source: emulator-linux.md -->

**HTTPS mode:**

By default, the vNext emulator starts in **HTTP** mode. The .NET and Java SDKs don't support HTTP mode, so if you're using either of those, you need to start the emulator with HTTPS explicitly: <!-- Source: emulator-linux.md -->

```bash
docker run \
    --detach \
    --publish 8081:8081 \
    --publish 1234:1234 \
    mcr.microsoft.com/cosmosdb/linux/azure-cosmos-emulator:vnext-preview \
    --protocol https
```

<!-- Source: emulator-linux.md -->

For the Java SDK specifically, you'll also need to export the emulator's TLS certificate and import it into your local Java trust store:

```bash
# Export the certificate
openssl s_client -connect localhost:8081 </dev/null \
    | sed -ne '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p' > cosmos_emulator.cert

# Import into Java keystore (default password: "changeit")
keytool -cacerts -importcert -alias cosmos_emulator -file cosmos_emulator.cert
```

<!-- Source: emulator-linux.md -->

**Configuration options:**

The vNext emulator accepts configuration through command-line arguments or environment variables. Here are the key ones:

| Argument | Default | Description |
|----------|---------|-------------|
| `--port` | `8081` | Gateway port |
| `--protocol` | `http` | `https`, `http`, `https-insecure` |
| `--enable-explorer` | `true` | Toggle Data Explorer |
| `--explorer-port` | `1234` | Data Explorer port |
| `--data-path` | `/data` | Persistent data directory |
| `--key-file` | Default key | Custom auth key file path |
| `--log-level` | `info` | `quiet` thru `trace` |
| `--enable-otlp` | `false` | Enable OTLP exporter |

Each argument has a corresponding environment variable: `PORT`, `PROTOCOL`, `ENABLE_EXPLORER`, `EXPLORER_PORT`, `DATA_PATH`, `KEY_FILE`, `LOG_LEVEL`, `ENABLE_OTLP_EXPORTER`.

<!-- Source: emulator-linux.md -->

**Persisting data across container restarts:**

By default, the Docker emulator's data vanishes when the container stops. To persist data between runs, mount a volume to the data path:

```bash
docker run \
    --detach \
    --publish 8081:8081 \
    --publish 1234:1234 \
    --mount type=bind,source=./.local/data,target=/data \
    mcr.microsoft.com/cosmosdb/linux/azure-cosmos-emulator:vnext-preview
```

**Using the vNext emulator in CI/CD:**

The Docker emulator is a natural fit for continuous integration. You can run it as a GitHub Actions service container so that your integration tests hit a real Cosmos DB–compatible endpoint without provisioning cloud resources:

```yaml
services:
  cosmosdb:
    image: mcr.microsoft.com/cosmosdb/linux/azure-cosmos-emulator:vnext-preview
    ports:
      - 8081:8081
    env:
      PROTOCOL: https
```

<!-- Source: emulator-linux.md -->

GitHub Actions manages the container lifecycle — it starts before your job and tears down after. Your tests connect to `localhost:8081` using the well-known key. No Azure account needed, no cleanup, no costs.

The emulator's [GitHub repository](https://github.com/AzureCosmosDB/cosmosdb-linux-emulator-github-actions) has working examples for .NET, Python, Java, and Go on both x64 and ARM64 architectures.

### Emulator Limitations vs. the Cloud Service

The emulator is a development tool, not a miniature Cosmos DB. Understanding its limitations saves you from debugging phantom issues that only exist locally.

| Feature | Windows Emu | vNext / Docker |
|---------|-------------|----------------|
| **APIs** | All (flags for non-NoSQL) | NoSQL only |
| **Throughput** | Provisioned only | Provisioned only |
| **Consistency** | Session + Strong only* | N/A (single node) |
| **Geo-replication** | No | No |
| **Scaling** | 25 containers default† | No published limit |
| **Max `id` length** | 254 chars | Not documented |
| **Max JOINs** | 5 | Not documented |
| **Stored procs/UDFs** | Supported | **Not planned** |
| **Change feed** | Supported | Supported |
| **Batch / Bulk** | Supported | Batch only‡ |
| **Index policies** | Supported | Not yet |
| **RU reporting** | Approximate | Not yet |
| **Data Explorer** | NoSQL + MongoDB | NoSQL only |

The cloud service supports all listed features fully — this table shows only where the emulators diverge.

*The Windows emulator flags the consistency level for testing but doesn't implement actual distributed consistency. †Default: 25 fixed-size containers at 400 RU/s or 5 unlimited; 10 fixed-size recommended for stability. Max 250 fixed-size or 50 unlimited via `/PartitionCount`. ‡.NET bulk operations not supported in vNext.

<!-- Source: emulator.md, emulator-linux.md -->

A few things to highlight:

**Stored procedures, triggers, and UDFs are not planned for the vNext emulator.** If your application relies on server-side execution, you'll need the Windows emulator or the cloud service for testing. This is an intentional design choice — Microsoft is moving the ecosystem away from server-side scripts in favor of SDK-side logic.

**The emulator doesn't truly implement consistency levels.** It accepts the consistency setting and passes it through, but since there's only one node with no replication, there's nothing to actually enforce. Don't use the emulator to test consistency behavior — that requires the cloud service with multiple regions.

**The emulator's Data Explorer** works for NoSQL and MongoDB on the Windows version. The vNext emulator has its own Data Explorer on port 1234, but it's NoSQL-only. <!-- Source: emulator.md, emulator-linux.md -->

**The well-known key can't be regenerated at runtime.** If you need a different key, you must start the emulator with a custom key specified upfront (via `/Key` on Windows or `--key-file` on vNext). <!-- Source: emulator.md -->

### Which Emulator Should You Use?

Here's the decision tree:

- **On Windows, developing with any API**: Use the Windows installer. It's the most complete.
- **On macOS or Linux**: Use the vNext Docker emulator. It's your only option (aside from a VM).
- **In CI/CD pipelines**: Use the vNext Docker emulator. It's purpose-built for containers and GitHub Actions.
- **Need stored procedures or triggers locally**: Windows emulator only.
- **Want the simplest setup**: vNext Docker emulator — `docker pull` + `docker run` and you're done.

If you're on Windows and doing NoSQL-only development, either works. The vNext emulator is lighter-weight and container-friendly; the Windows emulator has broader feature coverage. For this book's purposes, all code examples that run against the emulator will use the well-known connection string, which is the same for both versions.

## Quickstart: Your First Item via the Portal and the SDK

You've already seen how to create an item in Data Explorer. Now let's do it with code — the way you'll actually work in a real application. We'll cover both C# and Python.

### Setup

For both languages, you'll need:

1. A running Cosmos DB account (cloud or emulator).
2. A database named `cosmicworks` and a container named `products` with partition key `/category`. (You created these earlier in this chapter.)
3. The account endpoint and key (from **Settings → Keys** in the portal, or the well-known emulator credentials).

### C# (.NET)

**Install the SDK:**

```bash
dotnet add package Microsoft.Azure.Cosmos
```

<!-- Source: quickstart-dotnet.md -->

**Connect and write your first item:**

```csharp
using Microsoft.Azure.Cosmos;

// For the emulator, use the well-known endpoint and key.
// For Azure, use your account endpoint and a key or DefaultAzureCredential.
string endpoint = "https://localhost:8081";
string key = "C2y6yDjf5/R+ob0N8A7Cgv30VRDJIWEHLM+4QDU5DE2nQ9nDuVTqobD4b8mGGyPMbIZnqyMsEcaGQy67XIw/Jw==";

CosmosClient client = new(endpoint, key);

Database database = client.GetDatabase("cosmicworks");
Container container = database.GetContainer("products");

// Define the item
var product = new
{
    id = "surfboard-001",
    category = "gear-surf-surfboards",
    name = "Yamba Surfboard",
    quantity = 12,
    price = 850.00,
    clearance = false
};

// Upsert it — creates the item, or replaces it if it already exists
ItemResponse<dynamic> response = await container.UpsertItemAsync(
    item: product,
    partitionKey: new PartitionKey("gear-surf-surfboards")
);

Console.WriteLine($"Status: {response.StatusCode}");
Console.WriteLine($"RU charge: {response.RequestCharge}");
```

<!-- Source: quickstart-dotnet.md (adapted for clarity) -->

A few things to note:

- **`UpsertItemAsync`** is your friend for quickstarts and idempotent writes. It creates the item if it doesn't exist, or replaces it entirely if it does. For production code, you'll sometimes prefer `CreateItemAsync` (which throws if the item exists) or `ReplaceItemAsync` (which requires an ETag for concurrency control). We'll cover these patterns in Chapter 16.
- You **pass the partition key** as a separate parameter. The SDK can extract it from the item body if you omit it, but passing it explicitly is a best practice — it avoids the overhead of parsing and makes your intent clear.
- The response includes the **RU charge** (`RequestCharge`). Get in the habit of checking this. It tells you exactly what that operation cost.

**Read the item back:**

```csharp
ItemResponse<dynamic> readResponse = await container.ReadItemAsync<dynamic>(
    id: "surfboard-001",
    partitionKey: new PartitionKey("gear-surf-surfboards")
);

Console.WriteLine($"Name: {readResponse.Resource.name}");
Console.WriteLine($"RU charge: {readResponse.RequestCharge}");
```

This is a **point read** — the cheapest, fastest operation in Cosmos DB. You provide the `id` and partition key, and the engine goes directly to the right partition and retrieves the item. Expect ~1 RU for a 1 KB document. <!-- Source: request-units.md -->

**Query items:**

```csharp
string sql = "SELECT * FROM products p WHERE p.category = @category";

QueryDefinition query = new QueryDefinition(sql)
    .WithParameter("@category", "gear-surf-surfboards");

using FeedIterator<dynamic> feed = container.GetItemQueryIterator<dynamic>(query);

while (feed.HasMoreResults)
{
    FeedResponse<dynamic> page = await feed.ReadNextAsync();
    Console.WriteLine($"Page RU charge: {page.RequestCharge}");

    foreach (var item in page)
    {
        Console.WriteLine($"  {item.name} - ${item.price}");
    }
}
```

<!-- Source: quickstart-dotnet.md (adapted) -->

Queries return paginated results. The `FeedIterator` pattern handles this — you loop through pages until `HasMoreResults` is false. Each page reports its own RU charge.

### Python

**Install the SDK:**

```bash
pip install azure-cosmos
```

<!-- Source: quickstart-python.md -->

**Connect and write your first item:**

```python
from azure.cosmos import CosmosClient, PartitionKey

# For the emulator, use the well-known endpoint and key.
endpoint = "https://localhost:8081"
key = "C2y6yDjf5/R+ob0N8A7Cgv30VRDJIWEHLM+4QDU5DE2nQ9nDuVTqobD4b8mGGyPMbIZnqyMsEcaGQy67XIw/Jw=="

client = CosmosClient(endpoint, key)

database = client.get_database_client("cosmicworks")
container = database.get_container_client("products")

# Define the item
product = {
    "id": "surfboard-001",
    "category": "gear-surf-surfboards",
    "name": "Yamba Surfboard",
    "quantity": 12,
    "price": 850.00,
    "clearance": False,
}

# Upsert it
result = container.upsert_item(product)
print(f"Item created: {result['id']}")
```

<!-- Source: quickstart-python.md (adapted) -->

**Read the item back:**

```python
item = container.read_item(
    item="surfboard-001",
    partition_key="gear-surf-surfboards"
)

print(f"Name: {item['name']}")
print(f"Price: {item['price']}")
```

**Query items:**

```python
query = "SELECT * FROM products p WHERE p.category = @category"

items = container.query_items(
    query=query,
    parameters=[{"name": "@category", "value": "gear-surf-surfboards"}],
    enable_cross_partition_query=False,
)

for item in items:
    print(f"  {item['name']} - ${item['price']}")
```

<!-- Source: quickstart-python.md (adapted) -->

Notice `enable_cross_partition_query=False`. Since we're filtering on the partition key (`category`), the query targets a single partition — no cross-partition fan-out needed. If you query without a partition key filter, you'd set this to `True` and accept the higher RU cost. Cross-partition queries are covered in Chapter 8.

### Switching from the Emulator to the Cloud

When you're ready to move from local development to your Azure account, change two values:

```python
# Before (emulator)
endpoint = "https://localhost:8081"
key = "C2y6yDjf5/R+ob0N8A7Cgv30VRDJIWEHLM+4QDU5DE2nQ9nDuVTqobD4b8mGGyPMbIZnqyMsEcaGQy67XIw/Jw=="

# After (Azure)
endpoint = "https://my-cosmos-account.documents.azure.com:443/"
key = "<your-actual-key>"
```

That's it. No code changes, no SDK differences. The connection string is the only thing that varies between the emulator and the cloud service. In production, you'll use environment variables or Azure Key Vault to manage these values — not hardcoded strings. Chapter 17 covers secrets management.

### What Just Happened?

In a few lines of code, you:

1. Connected to a Cosmos DB instance (local or cloud).
2. Created a JSON item with a partition key.
3. Read it back with a point read.
4. Queried it with SQL.

Every interaction reported its RU cost. This feedback loop — write something, measure the cost, optimize — is how you'll work with Cosmos DB throughout this book. The SDK depth in Chapter 21 will cover connection management, retry policies, bulk operations, and the many other SDK features you'll need for production applications.

Chapter 4 shifts focus to the data itself: how to think about documents, when to embed vs. reference, and the patterns that make or break a Cosmos DB data model.
