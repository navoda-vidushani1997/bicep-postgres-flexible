// modules/postgres.bicep
//
// Creates the PostgreSQL Flexible Server, the tenant database, and the Entra
// ID administrator record. That's it — PgBouncer config and diagnostic settings
// live in their own modules so this one stays focused.
//
// Before you call this module, make sure:
//   • The target subnet is already delegated to Microsoft.DBforPostgreSQL/flexibleServers
//   • The private DNS zone exists and has a VNet link to that subnet's VNet

targetScope = 'resourceGroup'

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------

param location    string
param tenantSlug  string
param environment string

@maxLength(12)
// tenantSlug is already validated by the caller, but @maxLength is cheap
// insurance if this module is ever called directly.
param adminUsername string

@secure()
param adminPassword string

param skuName        string
@allowed(['Burstable', 'GeneralPurpose', 'MemoryOptimized'])
param skuTier        string
@allowed(['14', '15', '16'])
param postgresVersion string

@minValue(32)
@maxValue(16384)
param storageSizeGB int

@minValue(7)
@maxValue(35)
param backupRetentionDays int

param delegatedSubnetResourceId string
param privateDnsZoneResourceId  string

param entraAdminObjectId     string
param entraAdminLogin        string
@allowed(['User', 'Group', 'ServicePrincipal'])
param entraAdminPrincipalType string
param entraDirectoryTenantId  string

// ---------------------------------------------------------------------------
// Naming
// ---------------------------------------------------------------------------

// Consistent naming keeps the portal readable. tenantSlug + env makes each
// server globally unique within a subscription.
var serverName   = 'psql-${tenantSlug}-${environment}'
var databaseName = 'db-${tenantSlug}'

// ---------------------------------------------------------------------------
// PostgreSQL Flexible Server
// ---------------------------------------------------------------------------

resource postgresServer 'Microsoft.DBforPostgreSQL/flexibleServers@2023-12-01-preview' = {
  name: serverName
  location: location
  sku: {
    name: skuName
    tier: skuTier
  }
  properties: {
    administratorLogin: adminUsername
    administratorLoginPassword: adminPassword

    version: postgresVersion

    authConfig: {
      activeDirectoryAuth: 'Enabled'
      passwordAuth: 'Enabled'
      // This is the Entra *directory* tenant ID — not the SaaS tenant slug.
      // Easy to mix up, so the comment stays.
      tenantId: entraDirectoryTenantId

      // We leave password auth on during the migration window. Once every
      // application is connecting with Entra tokens or managed identities,
      // flip this to 'Disabled' and redeploy.
    }

    network: {
      delegatedSubnetResourceId: delegatedSubnetResourceId
      privateDnsZoneArmResourceId: privateDnsZoneResourceId
      // No public endpoint, full stop. All traffic must go through the VNet.
      publicNetworkAccess: 'Disabled'
    }

    storage: {
      storageSizeGB: storageSizeGB
      // auto-grow kicks in before you hit the limit, so you don't get woken
      // up at 2am by a disk-full alert.
      autoGrow: 'Enabled'
    }

    backup: {
      backupRetentionDays: backupRetentionDays
      // Geo-redundant backup roughly doubles the backup cost. Leave it off for
      // dev/staging. Turn it on for prod if cross-region DR is a hard requirement.
      geoRedundantBackup: 'Disabled'
    }

    highAvailability: {
      // Disabled to keep costs down. Flip to 'ZoneRedundant' if you need
      // automatic failover and a tighter RTO SLA.
      mode: 'Disabled'
    }
  }
}

// ---------------------------------------------------------------------------
// Entra ID administrator
// ---------------------------------------------------------------------------

// This is a separate ARM resource type — it's managed by the Entra control
// plane, not the PostgreSQL engine. The resource name must be the object ID
// of the principal (not the display name), which is why entraAdminObjectId
// appears as `name:` here.
resource entraAdmin 'Microsoft.DBforPostgreSQL/flexibleServers/administrators@2023-12-01-preview' = {
  parent: postgresServer
  name: entraAdminObjectId
  properties: {
    principalType: entraAdminPrincipalType
    principalName: entraAdminLogin
    tenantId: entraDirectoryTenantId
  }
}

// ---------------------------------------------------------------------------
// Tenant database
// ---------------------------------------------------------------------------

// One database per tenant, named from the slug so there's no ambiguity.
// UTF8 + en_US.utf8 is the safest default for multilingual SaaS content.
resource tenantDatabase 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2023-12-01-preview' = {
  parent: postgresServer
  name: databaseName
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

// serverName is passed to sibling modules (pgbouncer, diagnostics) so they
// can reference this server with the `existing` keyword.
output serverName string = postgresServer.name
output serverFqdn string = postgresServer.properties.fullyQualifiedDomainName
output databaseName string = tenantDatabase.name
