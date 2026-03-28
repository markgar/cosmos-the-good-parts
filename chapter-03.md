# Chapter 3: Setting Up Cosmos DB for NoSQL

It's time to get your hands dirty. In this chapter, you'll go from zero to a working Cosmos DB environment — an account in Azure, a database, a container, and your first document written and read back through code. By the end, you'll have a local emulator running too, so you can develop offline without burning through cloud resources.

Let's start at the beginning: creating an account.

## Creating a Cosmos DB Account in the Azure Portal

Open the [Azure portal](https://portal.azure.com) and type **Azure Cosmos DB** in the global search bar. Select **Azure Cosmos DB** from the results, then click **+ Create**. You'll be presented with a list of API options — select **Azure Cosmos DB for NoSQL** and click **Create**.

The account creation blade walks you through several tabs. Here's what matters on the **Basics** tab:

- **Subscription and Resource Group**: Pick your subscription and either select an existing resource group or create one. Resource groups are just logical containers for your Azure resources — use whatever naming convention your team follows.
- **Account Name**: This must be globally unique. It becomes part of your account's URI (e.g., `https://youraccountname.documents.azure.com:443/`). Stick to lowercase letters, numbers, and hyphens.
- **Location**: Choose the Azure region closest to your users. This is your account's primary region. You can add more regions later for global distribution.
- **Capacity mode**: Choose between **Provisioned throughput** and **Serverless**. For learning and development, either works. Provisioned throughput is the traditional model where you allocate Request Units per second (RU/s). Serverless bills you per-request with no upfront provisioning — great for bursty or unpredictable workloads.
- **Apply Free Tier Discount**: If available, set this to **Apply**. More on this in a moment.

The remaining tabs — **Global Distribution**, **Networking**, **Backup Policy**, **Encryption**, and **Tags** — can generally be left at their defaults for a development account. Click **Review + create**, verify your settings, and hit **Create**. Deployment typically takes two to five minutes.

## Understanding Account-Level Settings and Free Tier

Before you move on, let's talk about a few account-level settings that are easy to overlook but important to understand.

### The Free Tier

Azure Cosmos DB offers a **lifetime free tier** — and yes, "lifetime" means exactly that. It lasts indefinitely for the life of the account. When free tier is enabled, you get:

- **1,000 RU/s** of provisioned throughput
- **25 GB of storage**

These are applied as a discount. Any throughput or storage beyond those limits is billed at the standard rate. The catch? You can have **at most one free tier account per Azure subscription**. You must opt in at account creation time — you can't enable it after the fact. If you don't see the option, it means another account in the subscription already has it.

> **Tip**: If you're also using an Azure free account, the discounts stack. For the first 12 months, you get a combined 1,400 RU/s (1,000 from Cosmos DB free tier + 400 from the Azure free account) and 50 GB of storage. After 12 months, the Azure free account credits expire, but the Cosmos DB free tier continues indefinitely.

### Other Account-Level Settings Worth Knowing

- **Consistency Level**: The default is **Session**, which is the most popular choice and a sensible default. We'll cover consistency in depth in a later chapter — for now, Session gives you read-your-own-writes consistency within a session, which is what most applications expect.
- **Geo-Redundancy**: Disabled by default on new accounts. You can enable it later to replicate data across regions.
- **Multi-Region Writes**: Also disabled by default. Enabling it allows writes in multiple regions simultaneously. There's a cost and complexity trade-off here that we'll explore in the chapter on global distribution.
- **Total Account Throughput Limit**: An optional safety net that caps how many RU/s can be provisioned across the entire account. Useful for avoiding surprise bills during development.

## Creating Databases and Containers

With your account deployed, it's time to create the two resources you'll interact with most: **databases** and **containers**.

### Databases

A database in Cosmos DB is a namespace — a logical grouping of containers. It's analogous to a database in SQL Server or a database in MongoDB. You can have multiple databases per account.

Databases can also hold **shared throughput**. If you provision throughput at the database level (say, 400 RU/s), that throughput is shared across all containers in the database. This is a cost-effective approach when you have many containers with modest individual needs. A shared throughput database supports up to 25 containers by default. Additional containers can be added, but each one beyond 25 increases the database's minimum required throughput by 100 RU/s (manual) or 1,000 RU/s (autoscale).

### Containers

A container is where your data lives. It's the Cosmos DB equivalent of a table (in SQL terms) or a collection (in MongoDB terms). Every container requires a **partition key** — this is a JSON property path that determines how your data is distributed across physical partitions. Choosing a good partition key is one of the most important decisions you'll make, and we'll dedicate a full chapter to it. For now, pick something with high cardinality — like `/id`, `/userId`, or `/tenantId`.

### Creating Both via the Portal

In your Cosmos DB account blade, click **Data Explorer** in the left navigation. Then click **New Container**. The dialog lets you:

1. **Create a new database** or select an existing one. Check "Provision throughput" if you want shared throughput at the database level.
2. **Name your container** and specify the **partition key** (e.g., `/categoryId`).
3. **Set throughput** — either at the database level (shared) or the container level (dedicated). For a development setup, 400 RU/s is the minimum for provisioned throughput.

Click **OK**, and within seconds your database and container are ready. It's fast — there's no schema to define, no columns to declare. You're working with a document database: the schema is whatever JSON you write into it.

## Connection Strings, Endpoints, and Keys

To connect to your Cosmos DB account from code, you need two things: an **endpoint URI** and an **authentication credential**. Let's find them.

### Finding Your Credentials

Navigate to your Cosmos DB account in the portal and select **Keys** from the left navigation menu. You'll see:

- **URI**: Your account's endpoint, in the format `https://youraccountname.documents.azure.com:443/`. This is the endpoint you pass to the SDK.
- **Primary Key** and **Secondary Key**: These are your read-write authorization keys. They're long Base64-encoded strings.
- **Primary Connection String** and **Secondary Connection String**: These combine the endpoint and key into a single string, formatted as `AccountEndpoint=https://...;AccountKey=...;`. Some SDKs and tools accept this format directly.
- **Read-only Keys**: A separate pair of keys that only allow read operations. Use these for applications or services that should never write data.

### Why Two Keys?

The primary and secondary keys exist to support **zero-downtime key rotation**. The pattern is:

1. Your app uses the primary key.
2. You regenerate the secondary key (the old secondary is invalidated).
3. You update your app to use the new secondary key.
4. You regenerate the primary key.

This way, one key is always valid while the other is being rotated. In production, store your keys in **Azure Key Vault** — never hardcode them.

### Microsoft Entra ID (The Better Way)

For production workloads, Microsoft recommends using **Microsoft Entra ID** (formerly Azure Active Directory) with role-based access control (RBAC) instead of keys. This eliminates shared secrets entirely and integrates with your organization's identity management. We'll cover this in the security chapter. For now, keys are fine for development.

## Introduction to the Azure Cosmos DB Data Explorer

The **Data Explorer** is your built-in tool for interacting with Cosmos DB data. You can access it two ways:

1. **Inside the Azure portal**: Navigate to your account and select **Data Explorer** from the left menu.
2. **Standalone at [cosmos.azure.com](https://cosmos.azure.com)**: A full-screen, dedicated version with more real estate and a few extra features.

The standalone version is genuinely useful — it gives you more screen space for query results and doesn't require navigating through the portal's nested blades.

### What Can You Do in Data Explorer?

- **Browse containers and items**: Expand the tree on the left to navigate databases → containers → items. Click any item to view and edit its JSON.
- **Run SQL queries**: Select a container, click **New SQL Query**, and write queries using the Cosmos DB SQL syntax (which we'll cover extensively in the querying chapter). Results appear below with execution stats including RU cost.
- **Create and delete resources**: Databases, containers, and individual items — all manageable from here.
- **Configure RU thresholds**: In the Settings, you can set a maximum RU cost for queries to prevent accidentally running expensive operations. The default threshold is 5,000 RU.
- **Custom columns**: For NoSQL API accounts, you can customize the items view to show specific JSON properties as columns — helpful when browsing large datasets.
- **Upload items**: Import JSON documents directly from a file.

Data Explorer is excellent for exploration and ad hoc queries. For anything automated or repeatable, you'll want the SDK.

## The Cosmos DB Emulator

Not every line of code needs to talk to the cloud. The Azure Cosmos DB emulator gives you a local instance that faithfully simulates the Cosmos DB service, letting you develop and test without an Azure subscription and without incurring costs.

There are two flavors: the **Windows installer** (the classic emulator) and the **Linux-based vNext** emulator (a Docker image). Let's look at both.

### Windows Installer (Classic)

The Windows emulator is a native application that runs on 64-bit Windows 10, Windows 11, and Windows Server 2016/2019. Minimum requirements are modest: 2 GB RAM and 10 GB of free disk space.

**Installation:**

1. Download the installer from [https://aka.ms/cosmosdb-emulator](https://aka.ms/cosmosdb-emulator).
2. Run the installer with **administrative privileges**.
3. The emulator automatically installs developer certificates and configures firewall rules.

Once running, the emulator listens on `https://localhost:8081` and launches a local Data Explorer in your browser at `https://localhost:8081/_explorer/index.html`. The default authorization key is a well-known string used by all emulator instances:

```
C2y6yDjf5/R+ob0N8A7Cgv30VRDJIWEHLM+4QDU5DE2nQ9nDuVTqobD4b8mGGyPMbIZnqyMsEcaGQy67XIw/Jw==
```

The Windows emulator supports the NoSQL API, MongoDB API, Table API, Apache Gremlin API, and Apache Cassandra API.

### Linux-Based vNext Emulator (Docker)

The next-generation emulator is entirely Linux-based and runs as a Docker container. It's cross-platform, supports both x64 and ARM64 architectures, and is the direction Microsoft is investing in going forward.

> **Important**: The vNext emulator is currently in **preview** and only supports the **API for NoSQL** in **gateway mode**.

**Pull and run:**

```bash
# Pull the image
docker pull mcr.microsoft.com/cosmosdb/linux/azure-cosmos-emulator:vnext-preview

# Run the container
docker run --detach \
  --publish 8081:8081 \
  --publish 1234:1234 \
  mcr.microsoft.com/cosmosdb/linux/azure-cosmos-emulator:vnext-preview
```

The emulator runs two services inside the container:

- **Port 8081**: The Cosmos DB endpoint (the API you connect to from code)
- **Port 1234**: The Data Explorer (browse to `http://localhost:1234` in your browser)

The gateway endpoint is usually available immediately; the Data Explorer may take a few seconds to start.

**A note on HTTPS**: The vNext emulator defaults to HTTP. If you're using the **.NET or Java SDK**, you'll need to explicitly enable HTTPS, because those SDKs don't support HTTP mode with the emulator:

```bash
docker run --detach \
  --publish 8081:8081 \
  --publish 1234:1234 \
  mcr.microsoft.com/cosmosdb/linux/azure-cosmos-emulator:vnext-preview \
  --protocol https
```

### Emulator Limitations vs. the Cloud Service

The emulator is great for development, but it's not a full replica of the cloud service. Here are the key limitations to be aware of:

| Limitation | Details |
|---|---|
| **Single region only** | No multi-region replication or geo-redundancy. You can't test global distribution scenarios. |
| **No multi-region writes** | Write operations are single-region only. |
| **Limited feature set (vNext)** | The vNext emulator doesn't support stored procedures, triggers, UDFs, custom index policies, or request unit accounting. |
| **Gateway mode only (vNext)** | The vNext emulator only supports gateway connection mode — no direct mode. |
| **No SLA guarantees** | The emulator doesn't enforce the performance SLAs of the cloud service. |
| **No serverless mode** | The emulator runs in provisioned throughput mode only. |

The Windows emulator has broader feature support than the vNext Docker image (including stored procedures and direct mode), but it's Windows-only. Pick the one that fits your development environment.

> **Bottom line**: Use the emulator for unit tests, local development, and CI/CD pipelines. Test against the real cloud service before shipping to production.

## Quickstart: Your First Item via the Portal and the SDK

Let's put it all together. We'll create a simple item via the portal, then do the same thing from code.

### Via the Portal

1. Go to **Data Explorer** in your Cosmos DB account (or emulator).
2. Expand your database, then your container.
3. Click **Items**, then **New Item**.
4. The editor shows a skeleton JSON document with a system-generated `id`. Replace it with:

```json
{
    "id": "item-1",
    "categoryId": "gear-surf-surfboards",
    "name": "Yamba Surfboard",
    "quantity": 12,
    "sale": false
}
```

5. Click **Save**. Cosmos DB adds system properties like `_rid`, `_self`, `_etag`, `_ts`, and `_attachments` — those are internal metadata you don't need to manage.
6. To read it back, click **New SQL Query** and run:

```sql
SELECT * FROM c WHERE c.id = 'item-1'
```

You'll see your document in the results, along with the query's RU charge.

### Via the .NET SDK (C#)

Now let's do the same thing in code. First, install the SDK:

```bash
dotnet add package Microsoft.Azure.Cosmos
```

Here's a complete example that connects to Cosmos DB, creates a database and container if they don't exist, inserts an item, and reads it back:

```csharp
using Microsoft.Azure.Cosmos;

// Tip: In production, use a singleton CosmosClient for the lifetime of your app.
using CosmosClient client = new(
    accountEndpoint: "https://youraccountname.documents.azure.com:443/",
    authKeyOrResourceToken: "<your-primary-key>"
);

// Create database if it doesn't exist
Database database = await client.CreateDatabaseIfNotExistsAsync(
    id: "adventure-works"
);

// Create container if it doesn't exist
Container container = await database.CreateContainerIfNotExistsAsync(
    id: "products",
    partitionKeyPath: "/categoryId"
);

// Define an item
var product = new
{
    id = "item-1",
    categoryId = "gear-surf-surfboards",
    name = "Yamba Surfboard",
    quantity = 12,
    sale = false
};

// Insert the item
ItemResponse<dynamic> createResponse = await container.CreateItemAsync(
    item: product,
    partitionKey: new PartitionKey("gear-surf-surfboards")
);
Console.WriteLine($"Created item. Status: {createResponse.StatusCode}, Cost: {createResponse.RequestCharge} RU");

// Read it back by ID and partition key
ItemResponse<dynamic> readResponse = await container.ReadItemAsync<dynamic>(
    id: "item-1",
    partitionKey: new PartitionKey("gear-surf-surfboards")
);
Console.WriteLine($"Read item. Status: {readResponse.StatusCode}, Cost: {readResponse.RequestCharge} RU");
```

A few things to notice:

- **`CosmosClient` should be a singleton.** Creating one is expensive (it establishes connections, discovers topology). Create it once and reuse it throughout your application's lifetime.
- **Both `id` and the partition key are required** for point reads. The `ReadItemAsync` call is the most efficient way to retrieve a single document — it's a single-partition, single-document lookup that typically costs just 1 RU.
- **Every response includes a `RequestCharge`** property that tells you exactly how many RU the operation consumed. Get in the habit of checking this.

### Connecting to the Emulator from Code

If you're using the emulator instead of the cloud, just swap out the endpoint and key:

```csharp
using CosmosClient client = new(
    accountEndpoint: "https://localhost:8081",
    authKeyOrResourceToken: "C2y6yDjf5/R+ob0N8A7Cgv30VRDJIWEHLM+4QDU5DE2nQ9nDuVTqobD4b8mGGyPMbIZnqyMsEcaGQy67XIw/Jw==",
    new CosmosClientOptions
    {
        // Required for the vNext emulator with self-signed certs
        HttpClientFactory = () =>
        {
            HttpMessageHandler handler = new HttpClientHandler
            {
                ServerCertificateCustomValidationCallback =
                    HttpClientHandler.DangerousAcceptAnyServerCertificateValidator
            };
            return new HttpClient(handler);
        },
        ConnectionMode = ConnectionMode.Gateway
    }
);
```

> **Warning**: The `DangerousAcceptAnyServerCertificateValidator` disables TLS certificate validation. This is acceptable for local development with the emulator — never use it in production.

### Via the Python SDK

For Python developers, here's the equivalent quickstart. Install the SDK first:

```bash
pip install azure-cosmos
```

```python
from azure.cosmos import CosmosClient, PartitionKey

# Connect
client = CosmosClient(
    url="https://youraccountname.documents.azure.com:443/",
    credential="<your-primary-key>"
)

# Create database and container
database = client.create_database_if_not_exists(id="adventure-works")
container = database.create_container_if_not_exists(
    id="products",
    partition_key=PartitionKey(path="/categoryId")
)

# Insert an item
product = {
    "id": "item-1",
    "categoryId": "gear-surf-surfboards",
    "name": "Yamba Surfboard",
    "quantity": 12,
    "sale": False
}
response = container.create_item(body=product)
print(f"Created item: {response['id']}")

# Read it back
item = container.read_item(item="item-1", partition_key="gear-surf-surfboards")
print(f"Read item: {item['name']}, Quantity: {item['quantity']}")
```

The Python SDK follows the same hierarchy: `CosmosClient` → `DatabaseProxy` → `ContainerProxy`. The API surface feels natural to Python developers, with methods like `create_item`, `read_item`, `query_items`, and `upsert_item`.

### Via the Node.js SDK

And for the JavaScript crowd:

```bash
npm install @azure/cosmos
```

```javascript
const { CosmosClient } = require("@azure/cosmos");

const client = new CosmosClient({
  endpoint: "https://youraccountname.documents.azure.com:443/",
  key: "<your-primary-key>"
});

async function main() {
  // Create database and container
  const { database } = await client.databases.createIfNotExists({ id: "adventure-works" });
  const { container } = await database.containers.createIfNotExists({
    id: "products",
    partitionKey: { paths: ["/categoryId"] }
  });

  // Insert an item
  const { resource: created } = await container.items.create({
    id: "item-1",
    categoryId: "gear-surf-surfboards",
    name: "Yamba Surfboard",
    quantity: 12,
    sale: false
  });
  console.log(`Created item: ${created.id}`);

  // Read it back
  const { resource: item } = await container.item("item-1", "gear-surf-surfboards").read();
  console.log(`Read item: ${item.name}, Quantity: ${item.quantity}`);
}

main().catch(console.error);
```

Regardless of which SDK you use, the pattern is the same: create a client, get a reference to a database and container, then perform operations. Cosmos DB's SDKs are available for .NET, Java, Python, Node.js, and Go — all following this same logical structure.

## What's Next

You now have a working Cosmos DB environment — whether in the cloud, running locally on the emulator, or both. You've created your first database, your first container, and your first document, and you've seen how the SDK maps to those operations in multiple languages.

In **Chapter 4**, we'll dive into the data model itself. We'll explore how to think about your documents, when to embed versus reference, and how to choose a partition key that won't come back to haunt you at scale. The decisions you make at the modeling stage will echo through every query and every RU charge — so let's get them right.
