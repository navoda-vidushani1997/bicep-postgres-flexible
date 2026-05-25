// main.bicep — the orchestrator
//
// This file is intentionally thin. All it does is declare parameters and wire
// three modules together. No resource blocks live here.
//
// Deploy order (Bicep works this out from the output references, but here's
// the mental model):
//
//   postgres  ──▶  pgbouncer
//             ──▶  diagnostics

targetScope = 'resourceGroup'

// ---------------------------------------------------------------------------
// Naming & placement
// ---------------------------------------------------------------------------

@description('Short environment label (dev | staging | prod).')
@allowed(['dev', 'staging', 'prod'])
param environment string

@description('Azure region for all resources. Defaults to the resource group location.')
param location string = resourceGroup().location

// This slug ends up in every resource name and the database name, so keep it
// short and URL-safe — no uppercase, no underscores, max 12 chars.
@description('Opaque SaaS tenant identifier used in resource and database names.')
@maxLength(12)
param tenantSlug string

// ---------------------------------------------------------------------------
// PostgreSQL credentials
// ---------------------------------------------------------------------------

@description('Administrator login username. Avoid reserved names like admin, root, postgres.')
param adminUsername string

// The password never appears as a plain string anywhere — az.getSecret() in
// the .bicepparam file pulls it straight from Key Vault at deploy time.
@description('Administrator password, sourced from Key Vault via az.getSecret().')
@secure()
param adminPassword string

// ---------------------------------------------------------------------------
// PostgreSQL compute & storage
// ---------------------------------------------------------------------------

// D2ds_v4 (2 vCores / 8 GB) is a reasonable starting point for multi-tenant
// workloads. If p95 CPU is consistently above 60%, move to D4ds_v4.
@description('Compute SKU name.')
param skuName string = 'Standard_D2ds_v4'

@description('SKU tier.')
@allowed(['Burstable', 'GeneralPurpose', 'MemoryOptimized'])
param skuTier string = 'GeneralPurpose'

@description('PostgreSQL major version.')
@allowed(['14', '15', '16'])
param postgresVersion string = '16'

// 32 GB is just the floor — auto-grow handles the rest.
@description('Initial storage in GB.')
@minValue(32)
@maxValue(16384)
param storageSizeGB int = 32

// ---------------------------------------------------------------------------
// Backup
// ---------------------------------------------------------------------------

// 7 days is the cheapest option and satisfies most compliance baselines.
// Bump to 14 or 35 if you need a longer recovery window.
@description('Automated backup retention in days (7–35).')
@minValue(7)
@maxValue(35)
param backupRetentionDays int = 7

// ---------------------------------------------------------------------------
// Networking
// ---------------------------------------------------------------------------

// The subnet must already be delegated to Microsoft.DBforPostgreSQL/flexibleServers
// before you run this deployment.
@description('Resource ID of the delegated subnet for VNet injection.')
param delegatedSubnetResourceId string

// The DNS zone must exist AND be linked to the VNet. The zone name must be
// exactly: privatelink.postgres.database.azure.com
@description('Resource ID of the private DNS zone for the server FQDN.')
param privateDnsZoneResourceId string

// ---------------------------------------------------------------------------
// Entra ID (Azure AD) auth
// ---------------------------------------------------------------------------

// Get the object ID from: az ad group show --group "YourGroup" --query id -o tsv
@description('Object ID of the Entra ID user, group, or SP that becomes the AAD admin.')
param entraAdminObjectId string

@description('UPN or display name of the Entra ID admin (portal display only).')
param entraAdminLogin string

// Groups are strongly preferred here — individual user accounts as DB admins
// are a pain to rotate when people leave.
@description('Principal type of the Entra ID admin.')
@allowed(['User', 'Group', 'ServicePrincipal'])
param entraAdminPrincipalType string = 'Group'

// Get this from: az account show --query tenantId -o tsv
@description('Your Entra ID directory tenant GUID.')
param entraDirectoryTenantId string

// ---------------------------------------------------------------------------
// PgBouncer
// ---------------------------------------------------------------------------

// Start at 25 and tune from there. A rough formula: don't exceed
// max_connections / number_of_distinct_users on the server side.
@description('Server-side pool size per (database, user) pair.')
@minValue(1)
@maxValue(500)
param pgBouncerPoolSize int = 25

@description('Maximum client connections PgBouncer will accept in total.')
@minValue(10)
@maxValue(10000)
param pgBouncerMaxClientConn int = 200

// ---------------------------------------------------------------------------
// Observability
// ---------------------------------------------------------------------------

@description('Full resource ID of the Log Analytics Workspace.')
param logAnalyticsWorkspaceResourceId string

// ---------------------------------------------------------------------------
// Key Vault metadata — used only to build the secret URI output
// ---------------------------------------------------------------------------

// We don't need the actual password value here, just the vault name and
// secret name so we can hand a stable URI to downstream modules.
@description('Name of the Key Vault that holds the admin password secret.')
param keyVaultName string

@description('Name of the Key Vault secret for the admin password.')
param adminPasswordSecretName string

// ===========================================================================
// Modules
// ===========================================================================

// 1. Stand up the server, create the database, wire up the Entra admin.
module postgres 'modules/postgres.bicep' = {
  name: 'deploy-postgres'
  params: {
    location: location
    tenantSlug: tenantSlug
    environment: environment
    adminUsername: adminUsername
    adminPassword: adminPassword
    skuName: skuName
    skuTier: skuTier
    postgresVersion: postgresVersion
    storageSizeGB: storageSizeGB
    backupRetentionDays: backupRetentionDays
    delegatedSubnetResourceId: delegatedSubnetResourceId
    privateDnsZoneResourceId: privateDnsZoneResourceId
    entraAdminObjectId: entraAdminObjectId
    entraAdminLogin: entraAdminLogin
    entraAdminPrincipalType: entraAdminPrincipalType
    entraDirectoryTenantId: entraDirectoryTenantId
  }
}

// 2. Enable PgBouncer and set pool sizes. Referencing postgres.outputs.serverName
//    is what tells Bicep to wait for the server before touching configurations.
module pgbouncer 'modules/pgbouncer.bicep' = {
  name: 'deploy-pgbouncer'
  params: {
    serverName: postgres.outputs.serverName
    poolSize: pgBouncerPoolSize
    maxClientConn: pgBouncerMaxClientConn
  }
}

// 3. Hook up diagnostic settings. Same implicit ordering via the output reference.
module diagnostics 'modules/diagnostics.bicep' = {
  name: 'deploy-diagnostics'
  params: {
    serverName: postgres.outputs.serverName
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceResourceId
  }
}

// ===========================================================================
// Outputs
// ===========================================================================

@description('Server FQDN — use this as the hostname in connection strings.')
output serverFqdn string = postgres.outputs.serverFqdn

@description('Tenant database name.')
output databaseName string = postgres.outputs.databaseName

// This is just a URI path string, not the secret itself — the linter flags the
// name but there's nothing sensitive in the value.
#disable-next-line outputs-should-not-contain-secrets
@description('Key Vault URI for the admin password — hand this to downstream modules so they can pull the secret themselves.')
output adminPasswordSecretUri string = 'https://${keyVaultName}.${az.environment().suffixes.keyvaultDns}/secrets/${adminPasswordSecretName}'
