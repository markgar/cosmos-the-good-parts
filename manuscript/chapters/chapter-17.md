# Chapter 17: Security and Access Control

Your Cosmos DB account stores the data your application lives and dies by. Customer profiles, financial transactions, health records, telemetry — whatever it is, someone wants to steal it, accidentally expose it, or delete it by mistake on a Friday afternoon. Security isn't a feature you bolt on at the end. It's a set of layered decisions that start the moment you create the account and never stop mattering.

This chapter covers every layer: how identities authenticate, how permissions are enforced, how the network restricts access, how data is encrypted at rest and in transit, and how governance guardrails keep your account locked down even when humans make mistakes. If you followed Chapter 3's walkthrough for creating an account and Chapter 7's guidance for connecting your SDK, you've already touched keys and connection strings. Here's where we get serious about doing that correctly.

## Authentication Options

Every request to Cosmos DB must prove who it is. The service supports three authentication mechanisms, each with different security profiles. Understanding when to use each — and when to stop using one entirely — is the most consequential security decision you'll make for your account.

### Primary and Secondary Keys

When you create a Cosmos DB account, Azure generates two keys: a **primary key** and a **secondary key**. Each is an HMAC-based authentication token that grants full read-write access to every database, container, and item in the account. There's also a pair of **read-only keys** that grant read access only. <!-- Source: create-secure-solutions/security-considerations.md -->

The service uses hash-based message authentication code (HMAC) for authorization. Each request is hashed using the secret account key, and the base-64 encoded hash is sent with the call. Cosmos DB computes its own hash from the request properties and the stored key, compares the two, and authorizes or rejects accordingly. <!-- Source: create-secure-solutions/security-considerations.md -->

Keys are simple to use, which is both their appeal and their danger:

```csharp
// This works — and it's the most common way teams start out
var client = new CosmosClient(
    "https://my-account.documents.azure.com:443/",
    "your-primary-key-here");
```

The problem is obvious: anyone who has the key has the kingdom. There's no scoping — a primary key can read and write everything. There's no audit trail tied to a specific identity — every request just looks like "someone with the key." And keys don't expire, so a leaked key stays valid until you manually rotate it.

**Use keys for:** local development, quick prototyping, and the emulator. For production workloads, move to Microsoft Entra ID.

### Resource Tokens for Scoped, Temporary Access

**Resource tokens** are the middle ground between keys and Entra ID. They're short-lived tokens scoped to a specific user's permissions on specific resources (containers, documents, stored procedures, etc.). You create a user resource and a permission resource in the database, and the service generates a token that you hand to the client. <!-- Source: create-secure-solutions/security-considerations.md -->

Resource tokens expire — the maximum lifetime is **24 hours** by default (minimum 10 minutes). <!-- Source: manage-your-account/enterprise-readiness/concepts-limits.md --> They can be read-write or read-only, and they're scoped to a single container or even a single partition key value. This makes them useful for scenarios where you need to give an end user direct (but limited) access to Cosmos DB without routing through a middle-tier API.

In practice, resource tokens have been largely superseded by Entra ID with data plane RBAC. The scoping model is powerful but the operational overhead — creating user resources, managing permission resources, refreshing tokens before expiry — adds up fast. If you're building a new application, prefer Entra ID. Resource tokens remain relevant for legacy integrations and edge cases where Entra ID isn't available.

### Microsoft Entra ID (Formerly Azure AD)

**Microsoft Entra ID** authentication is the recommended approach for production workloads. Instead of shared secrets, your application authenticates with an identity — a managed identity, service principal, or user account — and presents an OAuth 2.0 token to Cosmos DB. The service validates the token, checks the identity's role assignments, and grants or denies access accordingly. <!-- Source: create-secure-solutions/how-to-connect-role-based-access-control.md -->

The advantages over keys are substantial:

| Concern | Account Keys | Entra ID |
|---------|-------------|----------|
| **Scope** | Full account access | Per-action, per-resource |
| **Auditability** | No identity attached | Tied to a principal |
| **Expiry** | Never expires | Auto-refreshing tokens |
| **Rotation** | Manual, disruptive | No secrets to rotate |
| **Conditional access** | Not supported | MFA, IP rules, risk policies |

Here's what Entra ID authentication looks like in code. You'll use `DefaultAzureCredential` from the Azure Identity library, which automatically picks up managed identities in Azure, developer credentials locally, and service principal credentials in CI/CD:

```csharp
using Azure.Identity;
using Microsoft.Azure.Cosmos;

var credential = new DefaultAzureCredential();
var client = new CosmosClient(
    "https://my-account.documents.azure.com:443/",
    credential);
```

```python
from azure.identity import DefaultAzureCredential
from azure.cosmos import CosmosClient

credential = DefaultAzureCredential()
client = CosmosClient(
    "https://my-account.documents.azure.com:443/",
    credential)
```

```javascript
const { CosmosClient } = require("@azure/cosmos");
const { DefaultAzureCredential } = require("@azure/identity");

const credential = new DefaultAzureCredential();
const client = new CosmosClient({
    endpoint: "https://my-account.documents.azure.com:443/",
    aadCredentials: credential
});
```

If you're already using `DefaultAzureCredential` for other Azure services (Key Vault, Blob Storage, etc.), you know the pattern. It's the same across the entire Azure SDK surface area, and it's the same for Cosmos DB.

### Disabling Key-Based Authentication

Once you're confident that all your applications and tooling use Entra ID, you should **disable key-based authentication entirely**. This eliminates the risk of leaked keys being used to access your account — even if someone extracts a key from the portal or a misconfigured pipeline, it won't work. <!-- Source: create-secure-solutions/how-to-connect-role-based-access-control.md -->

You disable local auth by setting `disableLocalAuth` to `true` on the account:

```azurecli
az resource update \
    --resource-group "my-resource-group" \
    --name "my-cosmos-account" \
    --resource-type "Microsoft.DocumentDB/databaseAccounts" \
    --set properties.disableLocalAuth=true
```

Or in Bicep:

```bicep
resource account 'Microsoft.DocumentDB/databaseAccounts@2024-05-15' = {
  name: accountName
  location: location
  properties: {
    databaseAccountOfferType: 'Standard'
    disableLocalAuth: true
    // ... other properties
  }
}
```

<!-- Source: create-secure-solutions/how-to-connect-role-based-access-control.md -->

When you create a *new* account, you can disable key-based auth from the start in the Azure portal's **Security** section during account setup. For existing accounts, you flip the property and verify nothing breaks.

> **Gotcha:** Disabling local auth also prevents the Data Explorer in the Azure portal from working with account keys. Make sure the identities that need portal access have appropriate data plane RBAC assignments first.

### Key Rotation Strategies

If you're still using keys (during a migration, or for specific tooling that doesn't support Entra ID), rotate them regularly. Cosmos DB gives you two keys specifically to enable zero-downtime rotation. The procedure is: <!-- Source: create-secure-solutions/how-to-rotate-keys.md -->

1. If your app uses the **primary key**, regenerate the secondary key first.
2. Validate the new secondary key works.
3. Update your app to use the secondary key.
4. Regenerate the primary key.

The inverse works if you start from the secondary. The point is: one key is always valid and in use while you regenerate the other.

Key regeneration can take anywhere from one minute to multiple hours depending on the size of the account. Plan accordingly and don't regenerate both keys simultaneously — that's an outage. <!-- Source: create-secure-solutions/how-to-rotate-keys.md -->

A better long-term strategy: store your keys in **Azure Key Vault** rather than in app configuration directly, and use Key Vault's rotation policies to automate the cycle. This keeps secrets out of your codebase entirely. <!-- Source: create-secure-solutions/store-credentials-key-vault.md -->

## Role-Based Access Control (RBAC)

Authentication tells Cosmos DB *who you are*. Authorization tells it *what you can do*. Cosmos DB has two separate RBAC systems, and confusing them is a common mistake.

**Control plane RBAC** governs management operations — creating accounts, modifying settings, regenerating keys, managing databases and containers. This is the standard Azure RBAC you know from every other Azure service, using roles assigned via the Azure portal's **Access control (IAM)** blade. <!-- Source: create-secure-solutions/how-to-connect-role-based-access-control.md -->

**Data plane RBAC** governs data operations — reading, writing, querying, and deleting items. This is Cosmos DB's *native* role-based access control system, separate from Azure RBAC, with its own role definitions and assignment mechanism. <!-- Source: create-secure-solutions/how-to-connect-role-based-access-control.md -->

### Control Plane Roles

Control plane roles are standard Azure RBAC roles. The ones you'll see most often for Cosmos DB:

| Role | Scope |
|------|-------|
| **Cosmos DB Operator** | Manage infra; no data/key access |
| **Cosmos DB Account Reader** | Read-only metadata |
| **DocumentDB Account Contributor** | Full management incl. keys |
| **Custom roles** | Any `Microsoft.DocumentDb/*` combo |

<!-- Source: create-secure-solutions/how-to-connect-role-based-access-control.md -->

The **Cosmos DB Operator** role is a good default for operations teams. It lets them manage the infrastructure without being able to read or modify your application data, and without access to account keys. Its `notActions` explicitly exclude `listKeys`, `regenerateKey`, `listConnectionStrings`, and the data plane role definition/assignment operations. <!-- Source: create-secure-solutions/how-to-connect-role-based-access-control.md -->

### Data Plane Roles: Built-In

Cosmos DB provides two built-in data plane roles: <!-- Source: create-secure-solutions/reference/reference-data-plane-security.md -->

| Role | Key Actions |
|------|-------------|
| **Built-in Data Reader** | Read, query, change feed |
| **Built-in Data Contributor** | All container + item ops |

The Data Reader role ID is `00000000-0000-0000-0000-000000000001` and includes `readMetadata`, `items/read`, `executeQuery`, and `readChangeFeed`. The Data Contributor role ID is `00000000-0000-0000-0000-000000000002` and includes `readMetadata`, `containers/*`, and `items/*`.

The **Data Reader** can read items, execute queries, and read the change feed — but can't write or delete anything. The **Data Contributor** can do everything with data: create, read, update, delete items, execute stored procedures, manage conflicts, and read the change feed. Neither role can perform management operations like creating databases or modifying throughput. <!-- Source: create-secure-solutions/reference/reference-data-plane-security.md -->

### Custom Role Definitions

When the built-in roles don't fit — and they often won't in a production application — you create custom role definitions. A custom data plane role is a JSON document that specifies exactly which `dataActions` the role grants:

```json
{
  "RoleName": "Order Service Writer",
  "Type": "CustomRole",
  "AssignableScopes": ["/"],
  "Permissions": [{
    "DataActions": [
      "Microsoft.DocumentDB/databaseAccounts/readMetadata",
      "Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/create",
      "Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/read",
      "Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/replace",
      "Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/executeQuery",
      "Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/readChangeFeed"
    ]
  }]
}
```

<!-- Source: create-secure-solutions/reference/reference-data-plane-security.md, create-secure-solutions/how-to-connect-role-based-access-control.md -->

This role can create, read, and replace items, plus run queries and read the change feed — but it can't delete items, run stored procedures, or manage conflicts. That's the principle of least privilege in action.

Here's the full list of data actions you can combine: <!-- Source: create-secure-solutions/reference/reference-data-plane-security.md -->

| Action | Description |
|--------|------------|
| `readMetadata` | Read account/resource metadata |
| `items/create` | Create new items |
| `items/read` | Point-read by ID + partition key |
| `items/replace` | Replace existing items |
| `items/upsert` | Create or replace items |
| `items/delete` | Delete items |
| `items/unmask` | Bypass data masking |
| `executeQuery` | Execute NoSQL queries |
| `readChangeFeed` | Read the change feed |
| `executeStoredProcedure` | Execute stored procedures |
| `manageConflicts` | Manage the conflict feed |

Wildcards work too: `containers/*` covers all container-level operations, and `items/*` covers all item operations. <!-- Source: create-secure-solutions/reference/reference-data-plane-security.md -->

> **Important:** The `readMetadata` action is required in every role. The SDKs issue metadata reads during initialization to discover partition keys, indexing policies, and physical partition addresses. Without it, the SDK can't even start up. <!-- Source: create-secure-solutions/reference/reference-data-plane-security.md -->

### Assigning Roles to Identities

You create role definitions and assignments via CLI, PowerShell, Bicep, or the REST API — not the Azure portal's IAM blade (that's control plane RBAC, not data plane). Here's the CLI flow:

```bash
# Create the custom role definition
az cosmosdb sql role definition create \
    --resource-group "my-rg" \
    --account-name "my-cosmos-account" \
    --body "@role-definition.json"

# Assign it to a managed identity
az cosmosdb sql role assignment create \
    --resource-group "my-rg" \
    --account-name "my-cosmos-account" \
    --role-definition-id "<role-definition-id>" \
    --principal-id "<managed-identity-object-id>" \
    --scope "/"
```

<!-- Source: create-secure-solutions/how-to-connect-role-based-access-control.md -->

The `--scope` parameter controls granularity. You can scope an assignment to the entire account (`/`), a specific database (`/dbs/my-database`), or even a single container (`/dbs/my-database/colls/my-container`). Narrower scopes mean tighter access — a microservice that only talks to one container shouldn't have permissions on the others. <!-- Source: create-secure-solutions/how-to-connect-role-based-access-control.md -->

For multi-tenancy scenarios where different tenants need different access patterns — scoped to specific containers or partition key ranges — we'll explore the design patterns in detail in Chapter 26.

> **Gotcha:** Creating and managing data plane role definitions and assignments requires *control plane* permissions: `Microsoft.DocumentDB/databaseAccounts/sqlRoleDefinitions/write` and `Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments/write`. Make sure the identity managing RBAC has the right control plane role (like DocumentDB Account Contributor). <!-- Source: create-secure-solutions/how-to-connect-role-based-access-control.md -->

## Network Security

Authentication and authorization control *who* can access your data. Network security controls *where* requests can come from. The two layers work together — even with a valid key or token, a request blocked by network rules never reaches your data.

### IP Firewall Rules

The simplest network control. By default, your Cosmos DB account is accessible from the internet (with valid credentials). You can restrict this to a specific set of IP addresses or CIDR ranges. <!-- Source: create-secure-solutions/network-security/how-to-configure-firewall.md -->

In the portal, go to **Networking** and set **Allow access from** to **Selected networks**. Then add your allowed IP addresses. Any request from an IP outside the allowlist gets a 403 Forbidden — even if it has a valid key.

A few things to know about IP firewall:

- **Firewall changes take up to 15 minutes to propagate** and can behave inconsistently during that window. Don't make a firewall change and immediately test — wait. <!-- Source: create-secure-solutions/network-security/how-to-configure-firewall.md -->
- **The Azure portal itself needs access.** If you enable IP filtering, you may need to add the portal middleware IPs to maintain portal functionality like Data Explorer. The portal provides a one-click **Add Azure Portal Middleware IPs** button. <!-- Source: create-secure-solutions/network-security/how-to-configure-firewall.md -->
- **The `0.0.0.0` address** enables access from all Azure datacenter IP ranges. This is convenient for Azure services without fixed IPs (Stream Analytics, Functions) but it's broad — it includes *all* Azure customers' resources, not just yours. Use it sparingly. <!-- Source: create-secure-solutions/network-security/how-to-configure-firewall.md -->

### Virtual Network Service Endpoints

Service endpoints let you restrict access to a specific subnet in an Azure virtual network. Traffic from that subnet is sent to Cosmos DB with the subnet and VNet identity attached, and Cosmos DB only accepts traffic from subnets you've explicitly allowed. <!-- Source: create-secure-solutions/network-security/how-to-configure-vnet-service-endpoint.md -->

The account and VNet must be in the same Microsoft Entra ID tenant. You enable the `Microsoft.AzureCosmosDB` service endpoint on the subnet first, then add that subnet as an allowed source in your Cosmos DB account's networking configuration. <!-- Source: create-secure-solutions/network-security/how-to-configure-vnet-service-endpoint.md -->

Service endpoints are straightforward but they have a limitation: traffic still traverses the Microsoft backbone network to a *public* endpoint. The source is restricted, but the destination is still the public Cosmos DB endpoint. If your compliance requirements demand that traffic never touch a public endpoint, you need Private Link.

### Private Endpoints and Private Link

**Azure Private Link** gives your Cosmos DB account a private IP address inside your virtual network. Traffic between your VNet and Cosmos DB stays entirely on the Microsoft backbone network — it never crosses the public internet. When combined with disabling public network access, your Cosmos DB account becomes completely invisible to the internet. <!-- Source: create-secure-solutions/network-security/how-to-configure-private-endpoints.md -->

Each private endpoint is a set of private IP addresses in a subnet. Multiple IPs are created per endpoint — one for the global (region-agnostic) endpoint and one for each region where the account is deployed. <!-- Source: create-secure-solutions/network-security/how-to-configure-private-endpoints.md -->

The setup involves creating a private endpoint resource, selecting the target subresource (for NoSQL, that's `Sql`), and configuring private DNS zones so your applications resolve the Cosmos DB hostname to the private IP instead of the public one. The portal walks you through this with an automatic DNS integration option. <!-- Source: create-secure-solutions/network-security/how-to-configure-private-endpoints.md -->

Private zone names map to API types: <!-- Source: create-secure-solutions/network-security/how-to-configure-private-endpoints.md -->

| API Type | Private Zone Name |
|----------|------------------|
| NoSQL | `privatelink.documents.azure.com` |
| NoSQL (Dedicated Gateway) | `privatelink.sqlx.cosmos.azure.com` |
| Cassandra | `privatelink.cassandra.cosmos.azure.com` |
| MongoDB | `privatelink.mongo.cosmos.azure.com` |

> **Gotcha:** Private Link doesn't prevent your Cosmos DB endpoints from being *resolved* by public DNS. The filtering happens at the application level, not the network/transport layer. If you need true network isolation, combine Private Link with disabling public network access. <!-- Source: create-secure-solutions/network-security/how-to-configure-private-endpoints.md -->

For most production workloads, **Private Link with public network access disabled** is the recommended configuration. It gives you the strongest network isolation available.

### CORS Configuration

If you're calling the Cosmos DB REST API directly from a browser (rare, but it happens), you'll need to configure **Cross-Origin Resource Sharing (CORS)**. Cosmos DB supports CORS for the NoSQL API only — it's not applicable to MongoDB, Cassandra, or Gremlin since those protocols don't use HTTP for client-server communication. <!-- Source: create-secure-solutions/how-to-configure-cross-origin-resource-sharing.md -->

Configure it in the portal under the **CORS** blade by specifying a comma-separated list of allowed origins. You can use a wildcard (`*`) to allow all origins, but wildcards within domain names (like `https://*.mydomain.net`) aren't supported yet. <!-- Source: create-secure-solutions/how-to-configure-cross-origin-resource-sharing.md -->

### Network Security Perimeter (Preview)

**Network Security Perimeter (NSP)** is a newer approach to network isolation that defines a boundary around multiple Azure resources. Resources inside the perimeter can communicate with each other freely, and all access from outside the perimeter is denied by default. This is useful when your Cosmos DB account needs to talk to Key Vault, SQL databases, and other Azure services — instead of configuring private endpoints between each pair of services, you put them all inside the same perimeter. <!-- Source: create-secure-solutions/network-security/how-to-configure-nsp.md -->

NSP is in public preview and carries no SLA. It complements rather than replaces private endpoints and VNet service endpoints. The key benefits are simplified service-to-service communication inside the perimeter and centralized control over inbound and outbound access rules. <!-- Source: create-secure-solutions/network-security/how-to-configure-nsp.md -->

## Encryption

Cosmos DB encrypts your data at three levels: on the wire (in transit), on disk (at rest), and optionally in the application (client-side). You get the first two by default with zero configuration.

### Encryption at Rest

All data stored in Cosmos DB is encrypted at rest using **AES-256 encryption**, in every region where the account runs. This applies to the primary database storage on SSDs, media attachments, and backups in Azure Blob Storage. It's on by default and can't be turned off. <!-- Source: create-secure-solutions/data-encryption/database-encryption-at-rest.md -->

By default, Microsoft manages the encryption keys (service-managed keys). There's no performance impact — encryption at rest has no effect on the latency or throughput SLAs. There's no extra cost. You don't need to do anything. <!-- Source: create-secure-solutions/data-encryption/database-encryption-at-rest.md -->

### Customer-Managed Keys (CMK)

If your compliance requirements demand that you control the encryption keys — common in financial services, healthcare, and government — you can add a second layer of encryption using **customer-managed keys** stored in **Azure Key Vault**. <!-- Source: create-secure-solutions/data-encryption/how-to-setup-customer-managed-keys.md -->

CMK works *in addition to* the default service-managed encryption. Your data is encrypted with a data encryption key (DEK), and that DEK is wrapped (encrypted) with your CMK in Key Vault. Cosmos DB never sees your CMK in plaintext — it calls Key Vault to wrap and unwrap the DEK as needed.

The setup requirements: <!-- Source: create-secure-solutions/data-encryption/how-to-setup-customer-managed-keys.md -->

- Your Key Vault must have **Soft Delete** and **Purge Protection** enabled.
- Cosmos DB's first-party identity needs **Get**, **Unwrap Key**, and **Wrap Key** permissions on the key (via access policy or the **Key Vault Crypto Service Encryption User** RBAC role).
- CMK should be configured at account creation for new accounts. Existing accounts can be updated to use CMK.

> **Gotcha:** If your CMK becomes inaccessible — the key is deleted, the Key Vault firewall blocks Cosmos DB, or the access policy is removed — your data becomes inaccessible too. Purge Protection on Key Vault is critical. Treat your CMK key with the same care you'd treat the data itself.

### Always Encrypted: Client-Side Encryption

**Always Encrypted** takes a fundamentally different approach. Instead of encrypting data at the service level, your application encrypts sensitive properties *before* they leave the client. Cosmos DB stores and indexes the ciphertext — it never sees the plaintext values. Even a database administrator with full account access can't read the encrypted properties. <!-- Source: create-secure-solutions/data-encryption/how-to-always-encrypted.md -->

The encryption model uses two layers of keys:

- **Data encryption keys (DEKs)** are created per-database and stored in Cosmos DB (in wrapped form). You can create one DEK per property or share a DEK across multiple properties. The resource limit is 20 DEKs per database. <!-- Source: create-secure-solutions/data-encryption/how-to-always-encrypted.md -->
- **Customer-managed keys (CMKs)** in Azure Key Vault wrap the DEKs. Only clients with Key Vault access can unwrap the DEKs and decrypt the data.

You define an **encryption policy** on the container, specifying which properties to encrypt and whether to use **deterministic** or **randomized** encryption: <!-- Source: create-secure-solutions/data-encryption/how-to-always-encrypted.md -->

- **Deterministic encryption** produces the same ciphertext for a given plaintext value. This allows equality queries on encrypted properties but is less secure if the set of possible values is small.
- **Randomized encryption** is more secure but prevents queries on the encrypted property entirely.

The encryption policy is **immutable** — you set it at container creation and can't change it. Plan your encrypted properties carefully. Only top-level paths are supported (e.g., `/ssn`); nested paths like `/address/zipCode` aren't. <!-- Source: create-secure-solutions/data-encryption/how-to-always-encrypted.md -->

Here's a .NET example of creating a container with Always Encrypted:

```csharp
var ssnPath = new ClientEncryptionIncludedPath
{
    Path = "/ssn",
    ClientEncryptionKeyId = "my-key",
    EncryptionType = EncryptionType.Deterministic.ToString(),
    EncryptionAlgorithm = DataEncryptionAlgorithm.AeadAes256CbcHmacSha256
};

var creditCardPath = new ClientEncryptionIncludedPath
{
    Path = "/creditCard",
    ClientEncryptionKeyId = "my-key",
    EncryptionType = EncryptionType.Randomized.ToString(),
    EncryptionAlgorithm = DataEncryptionAlgorithm.AeadAes256CbcHmacSha256
};

await database.DefineContainer("customers", "/customerId")
    .WithClientEncryptionPolicy()
    .WithIncludedPath(ssnPath)
    .WithIncludedPath(creditCardPath)
    .Attach()
    .CreateAsync();
```

<!-- Source: create-secure-solutions/data-encryption/how-to-always-encrypted.md -->

Always Encrypted is supported in the **.NET**, **Java**, and **JavaScript/Node.js** SDKs (via the `Microsoft.Azure.Cosmos.Encryption`, `azure.cosmos.encryption`, and `@azure/cosmos` packages respectively). <!-- Source: create-secure-solutions/data-encryption/how-to-always-encrypted.md -->

### TLS Version Enforcement

All connections to Cosmos DB use HTTPS with TLS encryption. The minimum service-wide accepted version is **TLS 1.2**, and this is the default for new accounts. TLS 1.0 and 1.1 support has been retired as of August 31, 2025. **TLS 1.3 support** was enabled for Azure Cosmos DB effective March 31, 2025. <!-- Source: create-secure-solutions/data-encryption/self-serve-minimum-tls-enforcement.md, create-secure-solutions/data-encryption/tls-support.md -->

Cosmos DB enforces the minimum TLS version at the application layer (not lower in the network stack) because of its multi-tenant nature. You can set the minimum version per account using the `minimalTlsVersion` property:

```azurecli
az cosmosdb update \
    -n my-cosmos-account \
    -g my-resource-group \
    --minimal-tls-version Tls12
```

<!-- Source: create-secure-solutions/data-encryption/self-serve-minimum-tls-enforcement.md -->

Clients that support TLS 1.3 will automatically negotiate it when available. Azure Cosmos DB continues to support TLS 1.2 alongside TLS 1.3. TLS 1.3 brings faster handshakes, stronger cipher suites (TLS_AES_256_GCM_SHA384 and TLS_AES_128_GCM_SHA256), and mandatory Perfect Forward Secrecy. <!-- Source: create-secure-solutions/data-encryption/tls-support.md -->

> **Gotcha:** For Java developers, io.netty versions between `4.1.68.Final` and `4.1.86.Final` (inclusive) have a bug that causes TLS handshake failures when the Java runtime doesn't support TLS 1.3. This affects Azure Cosmos DB Java SDK versions 4.20.0 through 4.40.0. The fix is to upgrade to the latest SDK version. <!-- Source: create-secure-solutions/data-encryption/tls-support.md -->

## Dynamic Data Masking

**Dynamic Data Masking (DDM)** masks sensitive properties at query time for nonprivileged users, without changing the stored data. It's a server-side, policy-based feature — you define which properties to mask and which masking strategy to apply, and users without the `unmask` data action see redacted values. <!-- Source: create-secure-solutions/dynamic-data-masking.md -->

DDM is currently in **public preview** and carries no SLA. It requires Microsoft Entra ID authentication — account keys aren't supported. <!-- Source: create-secure-solutions/dynamic-data-masking.md -->

### Masking Strategies

| Strategy | Effect |
|----------|--------|
| **Default** | Strings→`XXXX`, nums→`0`, bools→`false` |
| **Custom String** | Mask substring at given position |
| **Email** | Show first char + domain suffix |

- **Custom String** example: `MaskSubstring(3,5)` turns `Washington` into `WasXXXXXon`.
- **Email** example: `alpha@microsoft.com` becomes `aXXXX@XXXXXXXXX.com`.

<!-- Source: create-secure-solutions/dynamic-data-masking.md -->

You define a masking policy on the container, specifying included paths (which properties to mask) and excluded paths. You can apply a blanket mask to all paths (`/`) and then carve out exceptions:

```json
{
  "dataMaskingPolicy": {
    "includedPaths": [
      { "path": "/" },
      { "path": "/email", "strategy": "Email" }
    ],
    "excludedPaths": [
      { "path": "/id" },
      { "path": "/department" }
    ],
    "isPolicyEnabled": true
  }
}
```

<!-- Source: create-secure-solutions/dynamic-data-masking.md -->

Privileged users — those with the `items/unmask` data action in their role — see the original, unmasked data. The built-in Data Contributor role includes unmask permissions; the built-in Data Reader does not. <!-- Source: create-secure-solutions/dynamic-data-masking.md -->

Key limitations to know: <!-- Source: create-secure-solutions/dynamic-data-masking.md -->

- DDM is limited to the NoSQL API.
- Once enabled at the account level, it can't be turned off.
- Change feed (both latest and all-versions-and-deletes modes) isn't available for low-privileged users.
- Masking slightly increases RU consumption due to extra processing at query time.
- Complex queries could occasionally expose unmasked data or enable inference of sensitive values. DDM minimizes exposure; it doesn't prevent it entirely for a determined attacker with direct database access.

## Azure Policy Support

**Azure Policy** lets you enforce organizational governance standards on your Cosmos DB resources. You can audit or deny configurations that violate your security policies — accounts without VNet filtering, accounts deployed to unapproved regions, accounts without multi-region writes. <!-- Source: create-secure-solutions/policy.md -->

Azure Cosmos DB has built-in policy definitions covering common governance scenarios. Search for "Azure Cosmos DB" in the policy definition gallery to see the full list. You can also create custom policy definitions using the `Microsoft.DocumentDB` namespace aliases. <!-- Source: create-secure-solutions/policy.md -->

A few production-relevant examples:

- **Require VNet filtering** — audit accounts that don't have `isVirtualNetworkFilterEnabled` set
- **Restrict allowed regions** — deny deployments to regions outside your approved list
- **Require multi-region writes** — audit accounts that don't have `enableMultipleWriteLocations`

One important caveat: Azure Policy is enforced at the resource provider level for management operations. The Cosmos DB SDKs can perform many management operations (creating databases, modifying throughput) through the data plane, bypassing the resource provider — and therefore bypassing any policies you've created. For critical governance rules, combine Azure Policy with the `disableKeyBasedMetadataWriteAccess` property, which forces all management operations through the resource provider. <!-- Source: create-secure-solutions/policy.md, manage-your-account/manage-azure-cosmos-db-resources/resource-locks.md -->

## Resource Locks

**Resource locks** prevent accidental deletion or modification of critical resources. You set them at the account, database, or container level, and they apply to all users and roles — including subscription owners.

Two lock levels: <!-- Source: manage-your-account/manage-azure-cosmos-db-resources/resource-locks.md -->

| Level | Effect |
|-------|--------|
| **CanNotDelete** | Read + modify, but no delete |
| **ReadOnly** | Read only — no delete or update |

Locks apply to *management plane* operations only. A ReadOnly lock on a container prevents you from deleting or modifying the container's settings, but it doesn't prevent you from writing data to the container. Data operations go through the data plane, which locks don't affect. <!-- Source: manage-your-account/manage-azure-cosmos-db-resources/resource-locks.md -->

There's a subtlety: resource locks don't work for changes made by applications using account keys unless you first enable `disableKeyBasedMetadataWriteAccess` on the account, as noted in the Azure Policy section above. Without it, an application with the account key can still modify throughput, indexing policies, and other settings despite the lock. <!-- Source: manage-your-account/manage-azure-cosmos-db-resources/resource-locks.md -->

```azurecli
# First, prevent key-based metadata writes
az cosmosdb update \
    --resource-group my-rg \
    --name my-cosmos-account \
    --disable-key-based-metadata-write-access true

# Then, apply a delete lock
az lock create \
    --resource-group my-rg \
    --name "my-cosmos-account-lock" \
    --lock-type CanNotDelete \
    --resource-type Microsoft.DocumentDB/databaseAccount \
    --resource my-cosmos-account
```

<!-- Source: manage-your-account/manage-azure-cosmos-db-resources/resource-locks.md -->

## Microsoft Defender for Azure Cosmos DB

**Microsoft Defender for Azure Cosmos DB** adds a layer of threat detection that monitors your account for anomalous activity. It's part of the broader Microsoft Defender for Cloud suite and currently supports the NoSQL API only. It's not available in Azure Government or sovereign cloud regions. <!-- Source: create-secure-solutions/defender-for-cosmos-db.md -->

Defender detects three categories of threats: <!-- Source: create-secure-solutions/defender-for-cosmos-db.md -->

- **SQL injection attempts** — Cosmos DB's query language makes many traditional SQL injection vectors impossible, but some variations can succeed. Defender catches both successful and failed attempts.
- **Anomalous database access patterns** — access from TOR exit nodes, known suspicious IPs, unusual applications, or unusual geographic locations.
- **Suspicious database activity** — unusual key-listing patterns (lateral movement techniques) and suspicious data extraction patterns.

Security alerts appear in Microsoft Defender for Cloud, and subscription administrators receive email notifications with details and recommended remediation actions. For the best forensic capability, enable **diagnostic logging** on your Cosmos DB account so you have a full audit trail of operations to correlate with any alerts.

Enabling Defender is a one-click operation in the Defender for Cloud console. It adds a per-account cost but no performance impact on your Cosmos DB workload.

## Data Residency and Compliance Certifications

Cosmos DB is available in every Azure region, including sovereign clouds (Azure Government, Azure operated by 21Vianet). Your data is stored in the regions you select — Cosmos DB doesn't move data outside your configured regions. For sovereign regions, Azure enforces data governance boundaries (geo-fencing) that ensure data stays within the applicable jurisdiction. <!-- Source: create-secure-solutions/security-considerations.md -->

For compliance certifications, Cosmos DB inherits Azure's broad certification portfolio. The specific certifications are maintained on the [Azure compliance page](https://www.microsoft.com/trustcenter/compliance/complianceofferings) and the Azure compliance document. Rather than listing certifications that may change, the practical guidance is: check the Azure Trust Center for the current list before your compliance review, and verify that your specific regulatory framework (HIPAA, SOC 2, ISO 27001, FedRAMP, PCI DSS, GDPR, etc.) is covered for the regions you're deploying to. <!-- Source: create-secure-solutions/security-considerations.md -->

## Putting It All Together

Security in Cosmos DB isn't a single setting — it's a stack. A well-secured production account typically looks like this:

1. **Authentication:** Microsoft Entra ID with local auth disabled
2. **Authorization:** Custom data plane roles following least privilege, scoped to specific containers
3. **Network:** Private Link with public network access disabled, or at minimum VNet service endpoints with IP firewall
4. **Encryption:** Default encryption at rest (always on), CMK if compliance requires it, Always Encrypted for the most sensitive properties
5. **Governance:** Azure Policy enforcing your standards, resource locks preventing accidental deletion, `disableKeyBasedMetadataWriteAccess` closing the SDK management backdoor
6. **Monitoring:** Microsoft Defender enabled, diagnostic logging configured

None of these layers is sufficient on its own. Defense in depth means a failure in one layer — a misconfigured firewall rule, a role assignment that's too broad — doesn't result in a breach because the other layers catch it.

In the next chapter, we'll shift from protecting your data to observing it — monitoring, diagnostics, and the operational visibility that keeps your Cosmos DB deployment healthy in production.
