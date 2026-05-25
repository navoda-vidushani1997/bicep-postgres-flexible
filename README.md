# PostgreSQL Flexible Server — Bicep Module

Provisions a production-ready PostgreSQL Flexible Server for a multi-tenant SaaS platform. No public endpoint, no hardcoded credentials, PgBouncer included.

## What gets created

| Resource | Notes |
|---|---|
| PostgreSQL Flexible Server | Private VNet injection, Entra ID auth, auto-grow storage |
| Tenant database | One per deployment, named from `tenantSlug` |
| Entra ID administrator | User, group, or service principal |
| PgBouncer (built-in) | Transaction pooling mode, pool size is a parameter |
| Diagnostic settings | All log categories + metrics → Log Analytics Workspace |

## Folder structure

```
.
├── main.bicep           # Orchestrator — parameters and module wiring only
├── main.bicepparam      # Your values go here, deploy from this file
└── modules/
    ├── postgres.bicep   # Server, database, Entra admin
    ├── pgbouncer.bicep  # Connection pooler configuration
    └── diagnostics.bicep # Logs and metrics → Log Analytics
```

`main.bicep` contains no resource blocks. Every resource lives in a module so each piece can be reviewed and reused in isolation.

## Prerequisites

These must exist before you run a deployment. This module does not create them.

**Networking**
- A VNet with a subnet delegated to `Microsoft.DBforPostgreSQL/flexibleServers`
  - The subnet must be empty — PostgreSQL won't share it with anything else
  - A `/28` (16 addresses) is the minimum size Azure accepts
- A private DNS zone named exactly `privatelink.postgres.database.azure.com`, linked to that VNet

**Secrets**
- A Key Vault in the same subscription containing the admin password as a secret
- The principal running the deployment needs `Key Vault Secrets User` on that vault

**Observability**
- A Log Analytics Workspace to receive logs and metrics

**Tip:** get the resource IDs you need with:
```bash
# Subnet
az network vnet subnet show \
  --resource-group rg-network-prod \
  --vnet-name vnet-saas-prod \
  --name snet-postgres-prod \
  --query id -o tsv

# Private DNS zone
az network private-dns zone show \
  --resource-group rg-network-prod \
  --name privatelink.postgres.database.azure.com \
  --query id -o tsv

# Log Analytics workspace
az monitor log-analytics workspace show \
  --resource-group rg-observability-prod \
  --workspace-name law-saas-prod \
  --query id -o tsv
```

## Deploying

**1. Fill in `main.bicepparam`**

Open [main.bicepparam](main.bicepparam) and replace every placeholder (`00000000-...`, `11111111-...`, etc.) with your real values. The file has inline comments explaining each one.

**2. Store the admin password in Key Vault**

```bash
az keyvault secret set \
  --vault-name kv-saas-prod \
  --name psql-admin-password \
  --value "$(openssl rand -base64 32)"
```

The password is pulled from Key Vault by `az.getSecret()` at deploy time and never appears in the parameter file or ARM deployment history.

**3. Run the deployment**

```bash
az deployment group create \
  --resource-group rg-saas-prod \
  --template-file main.bicep \
  --parameters main.bicepparam
```

**4. Check the outputs**

```bash
az deployment group show \
  --resource-group rg-saas-prod \
  --name main \
  --query properties.outputs
```

You'll get back the server FQDN, database name, and the Key Vault URI for the admin password.

## After deploying

A few things to do manually once the server is up:

**Enable pgaudit for SOC 2 evidence**

The diagnostic settings capture `PostgreSQLLogs`, but audit detail (DDL changes, privilege grants, connection events) only shows up once pgaudit is enabled:

```sql
-- Connect as the Entra admin
CREATE EXTENSION pgaudit;
```

Then set `pgaudit.log = 'ddl, role, connection'` as a server parameter in the portal or via `az postgres flexible-server parameter set`.

**Disable password auth once you're ready**

`main.bicep` leaves `passwordAuth: 'Enabled'` so you have a migration window. Once every application connects using Entra tokens or managed identities, set it to `'Disabled'` in [modules/postgres.bicep](modules/postgres.bicep) and redeploy. This removes the password-based attack surface entirely.

**Set up alerts**

The metrics are flowing to Log Analytics — wire up at least these three alert rules:
- CPU > 80% for 5 minutes
- Active connections > 80% of `max_connections`
- Storage used > 85%

## Key parameters

| Parameter | Default | When to change |
|---|---|---|
| `skuName` | `Standard_D2ds_v4` | Scale up when p95 CPU > 60% |
| `backupRetentionDays` | `7` | Increase to 35 for longer PITR window |
| `pgBouncerPoolSize` | `25` | Tune up if clients queue for connections |
| `pgBouncerMaxClientConn` | `200` | Must stay below `poolSize × distinct_user_count` |
| `skuTier` | `GeneralPurpose` | Use `MemoryOptimized` for heavy analytical queries |

## Things intentionally left off

| Feature | Why it's off by default |
|---|---|
| Geo-redundant backup | Roughly doubles backup cost. Enable it in prod if cross-region DR is a hard requirement. |
| Zone-redundant HA | Adds a hot standby in another AZ. Enable with `highAvailability.mode = 'ZoneRedundant'` when your SLA demands sub-minute failover. |
| Read replicas | Not needed until read traffic is measurably impacting write latency. |

## Linter notes

The `adminPasswordSecretUri` output triggers the `outputs-should-not-contain-secrets` linter rule because of the word "secret" in the name. The output value is a URI path string — there's no credential in it. The `#disable-next-line` suppression in `main.bicep` is intentional.
