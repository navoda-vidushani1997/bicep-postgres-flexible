// modules/pgbouncer.bicep
//
// Configures PgBouncer on an existing PostgreSQL Flexible Server.
//
// PgBouncer is built into every Flexible Server — you don't need a sidecar VM
// or a separate deployment. These server-configuration resources just flip the
// switches that are already there.
//
// You must deploy modules/postgres.bicep first. Pass its `serverName` output
// directly to this module; that reference is what tells Bicep to wait.

targetScope = 'resourceGroup'

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------

param serverName   string

@minValue(1)
@maxValue(500)
param poolSize     int

@minValue(10)
@maxValue(10000)
param maxClientConn int

// ---------------------------------------------------------------------------
// Existing server anchor
// ---------------------------------------------------------------------------

// `existing` tells Bicep: "this resource is already there, don't create it."
// We need it so the configuration resources below can use `parent:` to build
// the correct ARM resource paths under this server.
resource postgresServer 'Microsoft.DBforPostgreSQL/flexibleServers@2023-12-01-preview' existing = {
  name: serverName
}

// ---------------------------------------------------------------------------
// PgBouncer configuration
// ---------------------------------------------------------------------------

resource pgBouncerEnabled 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2023-12-01-preview' = {
  parent: postgresServer
  name: 'pgbouncer.enabled'
  properties: {
    value: 'true'
    source: 'user-override'
  }
}

// The other settings depend on pgbouncer.enabled being applied first, so we
// use dependsOn to make that ordering explicit.

resource pgBouncerPoolMode 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2023-12-01-preview' = {
  parent: postgresServer
  name: 'pgbouncer.pool_mode'
  dependsOn: [pgBouncerEnabled]
  properties: {
    // Transaction mode: the server-side connection goes back to the pool after
    // each transaction, not when the client disconnects. This is what you want
    // for typical OLTP — far fewer idle server connections.
    //
    // If your app uses SET LOCAL, advisory locks, or LISTEN/NOTIFY across
    // multiple transactions, switch this to 'session'. Those features rely on
    // connection state that transaction mode deliberately throws away.
    value: 'transaction'
    source: 'user-override'
  }
}

resource pgBouncerDefaultPoolSize 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2023-12-01-preview' = {
  parent: postgresServer
  name: 'pgbouncer.default_pool_size'
  dependsOn: [pgBouncerEnabled]
  properties: {
    // All server-configuration values are strings, even numeric ones.
    value: string(poolSize)
    source: 'user-override'
  }
}

resource pgBouncerMaxClientConnConfig 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2023-12-01-preview' = {
  parent: postgresServer
  name: 'pgbouncer.max_client_conn'
  dependsOn: [pgBouncerEnabled]
  properties: {
    value: string(maxClientConn)
    source: 'user-override'
  }
}
