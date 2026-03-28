# Chapter 16: Security and Access Control

If you've followed along from the beginning of this book, you've built databases, modeled documents, tuned queries, and configured global distribution. But none of that matters if an attacker can read your data—or if a well-meaning teammate accidentally deletes your production account on a Friday afternoon. Security in Azure Cosmos DB isn't a single switch you flip; it's a layered system that spans authentication, authorization, network isolation, encryption, and governance. In this chapter, you'll learn how each layer works and how to combine them into a defense-in-depth strategy for your NoSQL workloads.

## Authentication Options

Authentication answers a simple question: *who are you?* Azure Cosmos DB gives you three mechanisms to prove identity, each suited to different scenarios.

### Primary and Secondary Keys

Every Cosmos DB account is provisioned with two read-write keys and two read-only keys. These are long-lived, account-level credentials—think of them as the root password for your database. You pass a key in the `Authorization` header of every REST request (the SDKs handle this for you), and Cosmos DB validates it server-side.

The dual-key design exists for one reason: zero-downtime key rotation. At any given moment your application uses one key, while the other sits idle as a backup. When it's time to rotate, you switch your app to the idle key, regenerate the one you were using, and you've completed a rotation without a single dropped request. We'll cover the full procedure in a moment.

Keys are simple but coarse. They grant full access to every database and container in the account (or full read access, in the case of read-only keys). There's no way to scope a key to a single container, a single user, or a time window. For anything beyond quick prototyping or trusted backend services, you'll want a more granular option.

### Resource Tokens

Resource tokens provide scoped, temporary access to specific Cosmos DB resources. Your backend application authenticates a user, determines what they should see, and then requests a resource token from Cosmos DB tied to a specific container or even a specific partition key value. The token has a configurable time-to-live. The default TTL is one hour. The service quotas page lists 24 hours as the maximum, but the REST API and SDK documentation consistently cite five hours (18,000 seconds) as the override maximum. When in doubt, test with your SDK version and consult the latest documentation. You hand it to the client, and the client talks directly to Cosmos DB—but can only access the resources the token permits.

This pattern works well for mobile or browser-based apps that need direct database access without proxying every request through your API tier. The trade-off is complexity: your backend must implement the token-brokering logic, and you need to handle token expiration gracefully.

### Microsoft Entra ID (Formerly Azure AD)

Microsoft Entra ID is the recommended authentication mechanism for production workloads. Instead of managing shared secrets, you authenticate using Azure identities—user accounts, service principals, or managed identities—and Cosmos DB validates the bearer token issued by Entra ID.

The benefits are significant. You get centralized identity management, conditional access policies, audit logs, and no secrets to rotate (managed identities handle credential lifecycle automatically). Entra ID integrates with Cosmos DB's native role-based access control (RBAC), which we'll cover in the next section, giving you fine-grained data-plane permissions that keys simply can't provide.

### Disabling Local (Key-Based) Authentication

Once you've migrated all your workloads to Entra ID, you can—and should—disable key-based authentication entirely. This removes the attack surface of leaked keys and ensures that every request is backed by an auditable identity.

Here's how to disable local auth with the Azure CLI:

```azurecli
az resource update \
    --resource-group "myResourceGroup" \
    --name "myCosmosAccount" \
    --resource-type "Microsoft.DocumentDB/databaseAccounts" \
    --set properties.disableLocalAuth=true
```

After running this command, any attempt to connect using an account key or connection string will fail with a `403 Forbidden` response. The keys still exist on the account (they aren't deleted), but Cosmos DB simply refuses to honor them. If you need to re-enable key-based auth—say, for a legacy migration tool—set the property back to `false`.

> **Tip:** Azure provides a built-in policy called *"Configure Cosmos DB database accounts to disable local authentication"* that can enforce this setting across your entire subscription using Azure Policy. We'll revisit this in the governance section later in this chapter.

You can also set `disableLocalAuth: true` in a Bicep or ARM template at account creation time, ensuring new accounts are born secure:

```bicep
resource account 'Microsoft.DocumentDB/databaseAccounts@2024-05-15' = {
  name: accountName
  location: location
  properties: {
    databaseAccountOfferType: 'Standard'
    locations: [ { locationName: location } ]
    disableLocalAuth: true
  }
}
```

### Key Rotation Strategies

If you're still using keys (and many teams are, at least partially), regular rotation is essential. Cosmos DB makes this straightforward thanks to the primary/secondary key pattern.

The procedure when your application currently uses the **primary key**:

1. Regenerate the **secondary key** in the Azure portal or CLI.
2. Validate that the new secondary key works against your account.
3. Update your application configuration to use the secondary key.
4. Once all instances are using the secondary key, regenerate the **primary key**.

To regenerate a key via the CLI:

```azurecli
az cosmosdb keys regenerate \
    --name "myCosmosAccount" \
    --resource-group "myResourceGroup" \
    --key-kind secondary
```

Key regeneration can take anywhere from one minute to multiple hours depending on the size of the account, so always validate before cutting over.

Azure Cosmos DB also offers an **Account Key Usage Metadata** feature (currently in preview) that shows when each key was last used. This is invaluable before rotation—you can confirm that no workload is still using the key you're about to regenerate, preventing accidental outages.

The ultimate key rotation strategy? Stop using keys altogether and migrate to Entra ID.

## Role-Based Access Control (RBAC)

Authentication tells Cosmos DB *who* you are. Authorization—via RBAC—tells it *what you're allowed to do*. Cosmos DB supports RBAC at two levels: the **control plane** (managing account infrastructure via Azure Resource Manager) and the **data plane** (reading and writing your actual data).

### Control Plane Roles

Control plane RBAC uses standard Azure role definitions. The most relevant built-in roles are:

| Role | What It Grants |
|------|---------------|
| **Cosmos DB Operator** | Manage accounts, databases, and containers. Cannot access data, keys, or connection strings. |
| **Cosmos DB Account Reader** | Read account metadata only. |
| **DocumentDB Account Contributor** | Full management of Cosmos DB accounts including keys. |

These roles are assigned through Azure's standard RBAC system using `az role assignment create` or the Azure portal.

### Data Plane Roles: Built-in Definitions

For data-plane access (the queries your application actually runs), Cosmos DB provides a native RBAC system with two built-in roles:

| Role | ID | Permissions |
|------|----|-------------|
| **Cosmos DB Built-in Data Reader** | `00000000-0000-0000-0000-000000000001` | Read metadata, read items, execute queries |
| **Cosmos DB Built-in Data Contributor** | `00000000-0000-0000-0000-000000000002` | Read metadata, read/write/delete items, execute queries, manage the change feed, execute stored procedures |

These built-in roles cover the most common scenarios. The **Data Reader** is perfect for reporting services, analytics pipelines, or any workload that should never modify data. The **Data Contributor** is what your CRUD application needs.

### Custom Role Definitions

When the built-in roles are too broad or too narrow, you can create custom data-plane role definitions. A custom role specifies a set of `dataActions` (there is no `notDataActions` support—anything not explicitly allowed is denied) and one or more assignable scopes.

Here's an example Azure CLI command that creates a custom role allowing only read operations on a specific database:

```azurecli
az cosmosdb sql role definition create \
    --resource-group "myResourceGroup" \
    --account-name "myCosmosAccount" \
    --body '{
      "RoleName": "ReadOnly-OrdersDB",
      "Type": "CustomRole",
      "AssignableScopes": [
        "/dbs/orders"
      ],
      "Permissions": [{
        "DataActions": [
          "Microsoft.DocumentDB/databaseAccounts/readMetadata",
          "Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/read",
          "Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/executeQuery"
        ]
      }]
    }'
```

The `AssignableScopes` array lets you restrict the role to the account level (`/`), a specific database (`/dbs/orders`), or a specific container (`/dbs/orders/colls/line-items`).

### Assigning Roles to Managed Identities and Service Principals

Once you have a role definition, you assign it to an identity. Here's how to assign the built-in Data Contributor role to a managed identity:

```azurecli
az cosmosdb sql role assignment create \
    --resource-group "myResourceGroup" \
    --account-name "myCosmosAccount" \
    --role-definition-id "00000000-0000-0000-0000-000000000002" \
    --principal-id "aaaaaaaa-bbbb-cccc-1111-222222222222" \
    --scope "/"
```

Replace the `--principal-id` with the object ID of your managed identity, service principal, or Entra ID user. The `--scope "/"` grants access to the entire account; narrow it to `/dbs/<database>` or `/dbs/<database>/colls/<container>` for least-privilege access.

> **Best practice:** In production, assign roles to managed identities rather than user accounts or service principals with client secrets. Managed identities eliminate credential management entirely—Azure handles the token lifecycle for you.

## Network Security

Authentication and authorization control *who* can access your data. Network security controls *where* requests can come from, adding another critical layer of defense.

### IP Firewall Rules

The simplest form of network restriction is an IP firewall. You define a list of allowed IPv4 addresses or CIDR ranges, and Cosmos DB rejects any request originating from an IP not on the list.

You can configure the firewall through the Azure portal, CLI, or ARM/Bicep templates. Here's an example using the Azure CLI:

```azurecli
az cosmosdb update \
    --name "myCosmosAccount" \
    --resource-group "myResourceGroup" \
    --ip-range-filter "203.0.113.0/24,198.51.100.42"
```

A few important details:

- To allow access from the Azure portal, you must add the portal's IP addresses (`13.91.105.215`, `4.210.172.107`, `13.88.56.148`, `40.91.218.243`) or enable the **Accept connections from within Azure datacenters** option. Note that MongoDB and Cassandra API accounts may require additional API-specific IP addresses.
- The IP firewall applies to public endpoint traffic only. It has no effect on connections through private endpoints.
- You can specify a generous limit of IP rules per account (consult the [service limits page](https://learn.microsoft.com/azure/cosmos-db/concepts-limits) for current maximums).

### Virtual Network Service Endpoints

Service endpoints extend your virtual network's identity to Cosmos DB. When you enable a service endpoint for `Microsoft.AzureCosmosDB` on a subnet, traffic from that subnet travels over the Azure backbone network and carries the subnet's identity. You then configure your Cosmos DB account to accept traffic only from that subnet.

Service endpoints are simpler to set up than private endpoints but have a key limitation: traffic still goes to Cosmos DB's public IP address (it's just restricted to authorized subnets). The data doesn't traverse the public internet, but it's not fully private either.

### Private Endpoints and Private Link

Azure Private Link gives you the strongest network isolation. A private endpoint places a network interface with a private IP address from your VNet directly into your subnet. Your applications connect to Cosmos DB using this private IP, and the traffic never leaves the Azure backbone.

Key benefits:

- **No public exposure.** You can disable public network access entirely, making your Cosmos DB account invisible from the internet.
- **Data exfiltration protection.** A private endpoint maps to a specific Cosmos DB account, not the entire service. Combined with NSG policies, this limits the scope of what a compromised workload can reach.
- **DNS integration.** Azure Private DNS zones resolve your account's hostname (e.g., `myCosmosAccount.documents.azure.com`) to the private IP automatically.

You can create private endpoints for different Cosmos DB resource types—including the SQL (NoSQL) API endpoint, analytical storage, and even the dedicated gateway. In most production architectures, private endpoints combined with disabling public access is the recommended configuration.

### Network Security Perimeter (Preview)

Network Security Perimeter (NSP) is a newer, preview-level feature that lets you define a logical network boundary around multiple Azure PaaS resources. Instead of configuring private endpoints and firewall rules individually on each resource, you create a perimeter and associate your Cosmos DB account, Azure Key Vault, Azure Storage, and other services within it. Resources inside the perimeter can communicate freely, while traffic crossing the boundary is subject to access rules.

NSP is still maturing, but it represents the direction Azure networking is heading—centralized, intent-based network governance. Keep an eye on this as it moves toward general availability.

## Encryption

Cosmos DB encrypts your data at multiple levels, from transparent server-side encryption to client-side protection for the most sensitive properties.

### Encryption at Rest

All data stored in Azure Cosmos DB is encrypted at rest using AES-256 encryption. This is automatic, always on, and requires zero configuration. By default, Microsoft manages the encryption keys—you don't need to do anything to benefit from this protection. The encryption covers all data, indexes, and backups across all regions.

### Customer-Managed Keys (CMK)

For organizations that need full control over the encryption key lifecycle—often to meet regulatory requirements—Cosmos DB supports a second layer of encryption using customer-managed keys stored in Azure Key Vault.

With CMK enabled:

- Data is first encrypted with a service-managed key (the default layer), then wrapped again with your key from Key Vault.
- You have full control over the key: you can rotate it, revoke it, and audit access to it.
- Revoking the key renders your data inaccessible. This gives you a "kill switch" for compliance scenarios.

To enable CMK on a new account:

```azurecli
az cosmosdb create \
    --name "myCosmosAccount" \
    --resource-group "myResourceGroup" \
    --key-uri "https://mykeyvault.vault.azure.net/keys/mykey/version123"
```

For existing accounts, you can enable CMK by updating the account with the `--key-uri` parameter. This kicks off a background process that encrypts existing data asynchronously—your account remains available for reads and writes during the process.

A few CMK considerations to keep in mind:

- **Enable Soft Delete and Purge Protection** on your Key Vault. Accidentally deleting the key without these safeguards means permanent data loss.
- CMK adds a small overhead to the document ID field, reducing the maximum ID size from 1,023 bytes to 990 bytes.
- Key autorotation in Azure Key Vault is supported—when you create a new version of the key, Cosmos DB automatically picks it up (though it can take up to 24 hours).

### Always Encrypted: Client-Side Encryption

Always Encrypted takes encryption a step further by encrypting sensitive properties *on the client* before they ever reach Cosmos DB. The service stores ciphertext and never has access to the plaintext or the encryption keys.

This is designed for the highest-sensitivity data—credit card numbers, government ID numbers, health records—where even the database administrator shouldn't see the values.

Here's how it works:

1. You create **data encryption keys (DEKs)** stored in Cosmos DB, wrapped by a **customer-managed key (CMK)** in Azure Key Vault.
2. You define an **encryption policy** on the container specifying which properties to encrypt and whether to use randomized or deterministic encryption.
3. The SDK handles encryption/decryption transparently during read and write operations.

**Randomized encryption** provides the strongest protection but prevents equality queries on the encrypted property. **Deterministic encryption** allows equality filters (`WHERE ssn = @ssn`) but reveals when two documents have the same value.

Here's a .NET example initializing the encryption client:

```csharp
var tokenCredential = new DefaultAzureCredential();
var keyResolver = new KeyResolver(tokenCredential);
var client = new CosmosClient("<connection-string>")
    .WithEncryption(keyResolver, KeyEncryptionKeyResolverName.AzureKeyVault);
```

The encryption policy is immutable after container creation, so plan your encrypted properties carefully. Always Encrypted is supported in the .NET, Java, and JavaScript SDKs.

### TLS Version Enforcement

All communication between your applications and Cosmos DB is encrypted in transit using TLS. Cosmos DB supports a self-serve minimum TLS version setting via the `minimalTlsVersion` account property.

You can enforce TLS 1.2 as the minimum:

```azurecli
az cosmosdb update \
    --name "myCosmosAccount" \
    --resource-group "myResourceGroup" \
    --minimal-tls-version "Tls12"
```

The accepted values are `Tls` (TLS 1.0), `Tls11` (TLS 1.1), and `Tls12` (TLS 1.2). The default for new accounts is `Tls12`. Setting this ensures that clients using older, less secure TLS versions are rejected. TLS 1.3 support is on Azure's roadmap and will further strengthen transport security when available.

## Dynamic Data Masking

Dynamic Data Masking (DDM), currently in public preview for Cosmos DB NoSQL, lets you obscure sensitive properties in query results without changing your application code. Masking rules are defined at the account level and apply to read operations—the underlying data remains intact.

For example, you could mask an email address so that queries return `jXXXXX@XXXXX.com` instead of the full value, or mask a credit card number to show only the last four digits. DDM is useful when different roles or applications need to see different levels of detail: your billing service sees the full card number, while your analytics pipeline sees only a masked version.

DDM integrates with Cosmos DB's data-plane RBAC. Users assigned a role with the unmasked data read action see plaintext; everyone else sees masked values. This means you can control masking behavior purely through role assignments, without any code changes on the application side.

> **Note:** Because DDM is in preview, it's not yet recommended for production workloads with strict SLA requirements. But it's worth evaluating now—the feature fills a real gap for multi-tenant applications and regulatory compliance.

## Azure Policy Support

Azure Policy lets you enforce organizational standards and assess compliance across your Azure environment. Cosmos DB has a rich set of built-in policy definitions that cover common security and governance scenarios.

Some of the most useful built-in policies for Cosmos DB include:

| Policy | Effect | What It Enforces |
|--------|--------|-----------------|
| **Azure Cosmos DB accounts should use customer-managed keys** | Audit / Deny | Ensures CMK is configured for encryption at rest |
| **Azure Cosmos DB should disable public network access** | Audit / Deny | Requires private endpoints for all connectivity |
| **Azure Cosmos DB throughput should be limited** | Audit / Deny | Caps maximum RU/s to prevent runaway costs |
| **Configure Cosmos DB to disable local authentication** | Modify | Automatically disables key-based auth on non-compliant accounts |
| **Azure Cosmos DB allowed locations** | Deny | Restricts which Azure regions accounts can be deployed to |
| **Key-based metadata write access should be disabled** | Append | Prevents management operations via account keys |

Policies can be assigned at the management group, subscription, or resource group level. The **Modify** effect is particularly powerful—it can automatically remediate non-compliant resources, for example by disabling local auth on any Cosmos DB account that has it enabled.

> **Important:** Azure Policy is enforced at the resource provider level. The Cosmos DB SDKs can perform certain management operations (like creating databases or containers) that bypass the resource provider and therefore bypass policies. Keep this in mind when designing your governance strategy—policies are a strong guardrail, but not a complete lockdown.

## Resource Locks

Resource locks are a simple but effective safeguard against accidental deletion or modification. You can apply locks at the account, resource group, or subscription level.

| Lock Level | Behavior |
|------------|----------|
| **CanNotDelete** | Authorized users can read and modify the resource, but cannot delete it. |
| **ReadOnly** | Authorized users can read the resource, but cannot modify or delete it. Similar to granting all users the Reader role. |

To apply a delete lock to a Cosmos DB account:

```azurecli
az lock create \
    --name "PreventDelete" \
    --resource-group "myResourceGroup" \
    --resource-name "myCosmosAccount" \
    --resource-type "Microsoft.DocumentDB/databaseAccounts" \
    --lock-type CanNotDelete
```

Locks are especially valuable in production environments where multiple teams have access. A `CanNotDelete` lock on your Cosmos DB account ensures that no one—regardless of their Azure RBAC role—can delete the account without first removing the lock. This two-step process provides a speed bump that prevents impulsive mistakes.

Be aware that a `ReadOnly` lock on a Cosmos DB account can have broader effects than you might expect. It prevents modifications to the account properties—which includes scaling throughput, adding regions, and modifying firewall rules. Use it judiciously.

## Microsoft Defender for Azure Cosmos DB

Microsoft Defender for Azure Cosmos DB is a cloud-native security layer that provides threat detection and security alerts for your Cosmos DB accounts. It continuously monitors your account for unusual access patterns and potentially harmful activities.

Defender detects threats such as:

- **SQL injection attacks** embedded in Cosmos DB queries
- **Anomalous access patterns** — requests from unusual locations, suspicious IPs, or Tor exit nodes
- **Potential key extraction** — unusual patterns in key listing or regeneration that could indicate an attacker probing for credentials
- **Unusual data exfiltration** — abnormally high volumes of data extraction

When Defender detects a threat, it generates a security alert that appears in Microsoft Defender for Cloud. Each alert includes:

- A description of the suspicious activity
- The MITRE ATT&CK tactic it maps to
- Recommended investigation and remediation steps
- An option to trigger an automated response via Azure Logic Apps

Enabling Defender is straightforward—you can turn it on per-account or across your entire subscription in Microsoft Defender for Cloud. There's a cost associated (check Azure pricing for current rates), but for accounts holding sensitive data, the visibility it provides is well worth it.

> **Tip:** Defender works best alongside the other security controls in this chapter. It doesn't *prevent* attacks—it *detects* them. Combine Defender with strong authentication (Entra ID), network isolation (private endpoints), and encryption (CMK + Always Encrypted) for a true defense-in-depth posture.

## Data Residency and Compliance Certifications

Azure Cosmos DB is designed for global distribution, but that doesn't mean your data has to leave a specific region. You control exactly where your data lives by choosing which Azure regions to replicate to. If you configure a single-region account, your data stays in that region. Multi-region accounts replicate only to the regions you explicitly select.

For backups, Cosmos DB offers the option to restrict backup storage to the same region as the source data (geo-redundant backup storage can be disabled), ensuring that even backups respect your residency requirements.

Azure Cosmos DB holds a broad set of compliance certifications, including:

- **SOC 1, SOC 2, SOC 3** — auditing and operational controls
- **ISO 27001, ISO 27017, ISO 27018** — information security management
- **HIPAA** — healthcare data protection
- **FedRAMP High** — US government workloads
- **PCI DSS** — payment card industry
- **GDPR** — European data protection
- **CSA STAR** — cloud security

The full list is extensive and regularly updated. You can review current certifications in the [Azure compliance documentation](https://learn.microsoft.com/azure/compliance/) and the Microsoft Trust Center. When undergoing an audit, you can request an Azure SOC report or other attestation documents directly through the Trust Center.

Cosmos DB also supports **Azure Confidential Computing** integration for workloads that require hardware-based trusted execution environments (TEEs), and the Always Encrypted feature discussed earlier provides client-side encryption that satisfies the most stringent data-handling requirements.

## Pulling It All Together

Security in Cosmos DB is most effective when you think of it as concentric rings:

1. **Identity:** Use Microsoft Entra ID with managed identities. Disable local auth.
2. **Authorization:** Apply the principle of least privilege with data-plane RBAC. Use custom roles when built-in roles are too broad.
3. **Network:** Lock down with private endpoints and disable public access. Use IP firewall rules as a secondary control.
4. **Encryption:** Rely on default encryption at rest. Add CMK for regulatory needs. Use Always Encrypted for the most sensitive properties.
5. **Governance:** Enforce standards with Azure Policy. Protect critical resources with locks.
6. **Detection:** Enable Microsoft Defender for threat monitoring and alerting.

No single layer is sufficient on its own, but together they create a security posture that satisfies even the most demanding compliance regimes.

## What's Next

With your Cosmos DB account locked down, you need a way to observe what's happening inside it. In **Chapter 17**, we'll explore monitoring and diagnostics—Azure Monitor metrics, diagnostic logs, query performance insights, and alerting strategies that keep you informed when things go sideways.
