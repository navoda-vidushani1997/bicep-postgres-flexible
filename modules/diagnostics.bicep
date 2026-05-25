// modules/diagnostics.bicep
//
// Attaches diagnostic settings to an existing PostgreSQL Flexible Server,
// routing all logs and metrics to a Log Analytics Workspace.
//
// Why all five log categories? Between them they cover the evidence an auditor
// will ask for under SOC 2:
//   - PostgreSQLLogs        → privilege changes, failed logins, pgaudit output  (CC6.1)
//   - PostgreSQLFlexSessions → who connected, when, from where                  (CC6.2)
//   - AllMetrics            → CPU/connection baselines for anomaly detection     (CC7.2)
//   - The other two (QueryStore, TableStats) are useful for the ops team and
//     cost almost nothing extra in Log Analytics ingestion.
//
// Note on retention: we set retentionPolicy.enabled = false on every category.
// Retention is controlled at the workspace level — per-category retention
// settings are deprecated and have no effect when workspace retention is set.
//
// Deploy modules/postgres.bicep first. Pass its `serverName` output here.

targetScope = 'resourceGroup'

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------

param serverName                      string
param logAnalyticsWorkspaceResourceId string

// ---------------------------------------------------------------------------
// Existing server anchor
// ---------------------------------------------------------------------------

// We need an `existing` reference so we can use it as the `scope` for the
// diagnostic settings resource below. Without it, Bicep can't build the
// correct resource ID to attach to.
resource postgresServer 'Microsoft.DBforPostgreSQL/flexibleServers@2023-12-01-preview' existing = {
  name: serverName
}

// ---------------------------------------------------------------------------
// Diagnostic settings
// ---------------------------------------------------------------------------

resource diagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-${serverName}'
  scope: postgresServer
  properties: {
    workspaceId: logAnalyticsWorkspaceResourceId

    logs: [
      {
        // This is the big one for compliance. It also carries pgaudit output
        // once you run `CREATE EXTENSION pgaudit;` in the database and set
        // pgaudit.log = 'ddl, role, connection' at the server level.
        category: 'PostgreSQLLogs'
        enabled: true
        retentionPolicy: { enabled: false, days: 0 }
      }
      {
        // One row per session: who connected, when, from which IP, which app.
        // Auditors love this table.
        category: 'PostgreSQLFlexSessions'
        enabled: true
        retentionPolicy: { enabled: false, days: 0 }
      }
      {
        // Query Store captures slow queries and wait stats. Useful when a
        // tenant reports slowness and you need to know what changed.
        category: 'PostgreSQLFlexQueryStore'
        enabled: true
        retentionPolicy: { enabled: false, days: 0 }
      }
      {
        // Per-table I/O and row counts. Good for spotting tables growing faster
        // than expected.
        category: 'PostgreSQLFlexTableStats'
        enabled: true
        retentionPolicy: { enabled: false, days: 0 }
      }
      {
        // Commit and rollback counts per database. A sudden spike in rollbacks
        // usually means something is wrong in the application.
        category: 'PostgreSQLFlexDatabaseXacts'
        enabled: true
        retentionPolicy: { enabled: false, days: 0 }
      }
    ]

    metrics: [
      {
        // CPU, memory, connections, IOPS, storage, replication lag — everything
        // you'd want on a dashboard or alert rule.
        category: 'AllMetrics'
        enabled: true
        retentionPolicy: { enabled: false, days: 0 }
      }
    ]
  }
}
