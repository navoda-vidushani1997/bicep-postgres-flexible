// main.bicepparam — fill this in before you deploy
//
// Run the deployment with:
//   az deployment group create \
//     --resource-group rg-saas-prod \
//     --template-file main.bicep \
//     --parameters main.bicepparam
//
// The admin password is never typed here as plain text. az.getSecret() reaches
// into Key Vault at deploy time, so the value never ends up in deployment
// history or ARM state.

using 'main.bicep'

param environment = 'prod'
param location    = 'eastus2'

// Keep this short — it ends up in the server name, database name, and DNS.
param tenantSlug = 'contoso'

// ---------------------------------------------------------------------------
// Credentials
// ---------------------------------------------------------------------------

param adminUsername = 'pgadminuser'

// Replace the four placeholders below with your real values.
// The secret VALUE never appears here — only the path to it.
param adminPassword = az.getSecret(
  '00000000-0000-0000-0000-000000000000',  // your subscription ID
  'rg-secrets-prod',                        // resource group that owns the Key Vault
  'kv-saas-prod',                           // Key Vault name
  'psql-admin-password'                     // secret name inside the vault
)

// ---------------------------------------------------------------------------
// Compute & storage
// ---------------------------------------------------------------------------

// D2ds_v4 = 2 vCores, 8 GB RAM. Good enough to start.
// Watch CPU metrics for a week after launch and scale up if needed.
param skuName         = 'Standard_D2ds_v4'
param skuTier         = 'GeneralPurpose'
param postgresVersion = '16'
param storageSizeGB   = 32  // auto-grow handles the ceiling

// ---------------------------------------------------------------------------
// Backup
// ---------------------------------------------------------------------------

// 7 days keeps costs down and satisfies most audit requirements. If your
// compliance team wants 30-day point-in-time recovery, change this to 35.
param backupRetentionDays = 7

// ---------------------------------------------------------------------------
// Networking
// ---------------------------------------------------------------------------

// Subnet must be pre-delegated to Microsoft.DBforPostgreSQL/flexibleServers.
// Don't put anything else in that subnet — PostgreSQL is picky about that.
param delegatedSubnetResourceId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-network-prod/providers/Microsoft.Network/virtualNetworks/vnet-saas-prod/subnets/snet-postgres-prod'

// Zone name must be exactly: privatelink.postgres.database.azure.com
// It also needs a VNet link to the VNet above before you deploy.
param privateDnsZoneResourceId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-network-prod/providers/Microsoft.Network/privateDnsZones/privatelink.postgres.database.azure.com'

// ---------------------------------------------------------------------------
// Entra ID admin
// ---------------------------------------------------------------------------

// Using a group here means you can rotate individual DBAs without touching
// the infrastructure. Get the group's object ID with:
//   az ad group show --group "DBA-Admins" --query id -o tsv
param entraAdminObjectId      = '11111111-1111-1111-1111-111111111111'  // replace me
param entraAdminLogin         = 'dba-admins@example.com'
param entraAdminPrincipalType = 'Group'

// Your directory (tenant) ID — not a SaaS tenant, your Azure AD directory.
// Find it with: az account show --query tenantId -o tsv
param entraDirectoryTenantId = '22222222-2222-2222-2222-222222222222'  // replace me

// ---------------------------------------------------------------------------
// PgBouncer
// ---------------------------------------------------------------------------

// 25 pool slots per (db, user) pair is a safe starting point.
// If you see clients queuing for connections, bump this up slowly — don't just
// crank it to 500, or you'll overwhelm max_connections on the server side.
param pgBouncerPoolSize    = 25
param pgBouncerMaxClientConn = 200

// ---------------------------------------------------------------------------
// Observability
// ---------------------------------------------------------------------------

param logAnalyticsWorkspaceResourceId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-observability-prod/providers/Microsoft.OperationalInsights/workspaces/law-saas-prod'

// ---------------------------------------------------------------------------
// Key Vault metadata (for the secret URI output — not the secret itself)
// ---------------------------------------------------------------------------

param keyVaultName            = 'kv-saas-prod'
param adminPasswordSecretName = 'psql-admin-password'
