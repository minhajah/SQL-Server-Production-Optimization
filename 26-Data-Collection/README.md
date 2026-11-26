# Module 26 – Health Data Collection

## Overview

Read-only SQL collectors for centralized monitoring of production SQL Server instances. The 16 scripts are developed drafts; execution, integration and production approval remain pending. The existing inventory application is unchanged.

## Scripts

| Script | Description | Proposed frequency |
|---|---|---|
| [01-Instance-Health-Collector.sql](01-Instance-Health-Collector.sql) | Collect SQL Server instance health metrics | 60 Seconds (Proposed) |
| [02-Database-Health-Collector.sql](02-Database-Health-Collector.sql) | Collect database health and availability metrics | 60 Seconds (Proposed) |
| [03-CPU-Collector.sql](03-CPU-Collector.sql) | Collect CPU utilization and scheduler metrics | 60 Seconds (Proposed) |
| [04-Memory-Collector.sql](04-Memory-Collector.sql) | Collect memory utilization and pressure metrics | 60 Seconds (Proposed) |
| [05-Storage-Collector.sql](05-Storage-Collector.sql) | Collect storage capacity and disk I/O metrics | 300 Seconds (Proposed) |
| [06-Backup-Collector.sql](06-Backup-Collector.sql) | Collect database backup history and compliance metrics | 900 Seconds (Proposed) |
| [07-HA-Health-Collector.sql](07-HA-Health-Collector.sql) | Collect Always On and basic FCI health metrics | 60 Seconds (Proposed) |
| [08-SQL-Agent-Collector.sql](08-SQL-Agent-Collector.sql) | Collect SQL Agent service and job health metrics | 300 Seconds (Proposed) |
| [09-Blocking-Collector.sql](09-Blocking-Collector.sql) | Collect blocking and active transaction metrics | 30-60 Seconds (Proposed) |
| [10-Transaction-Log-Collector.sql](10-Transaction-Log-Collector.sql) | Collect transaction log utilization and health metrics | 300 Seconds (Proposed) |
| [11-Deadlock-Collector.sql](11-Deadlock-Collector.sql) | Collect deadlock events from system_health | 300 Seconds (Proposed) |
| [12-Error-Log-Collector.sql](12-Error-Log-Collector.sql) | Collect SQL Server error log health metrics | 300 Seconds (Proposed) |
| [13-Wait-Statistics-Collector.sql](13-Wait-Statistics-Collector.sql) | Collect cumulative SQL Server wait statistics | 60 Seconds (Proposed) |
| [14-TempDB-Collector.sql](14-TempDB-Collector.sql) | Collect TempDB capacity and contention metrics | 60 Seconds (Proposed) |
| [15-Long-Running-Query-Collector.sql](15-Long-Running-Query-Collector.sql) | Collect active and resource-intensive request metrics | 60 Seconds (Proposed) |
| [16-SQL-Agent-History-Collector.sql](16-SQL-Agent-History-Collector.sql) | Collect incremental SQL Agent execution history | 300 Seconds (Proposed) |

## Collection Output

All collectors expose the same intended 12-column final result set. See [Collector Reference](Collector-Reference.md) for the schema and integration requirements. Raw collection status is not an assessment severity. The central adapter must implement the separate assessment contract in [Framework Design](../Framework-Design.md).

## Execution Instructions

Development only. Do not run on production until the validation checklist and approval gates are satisfied. Test individual scripts using SSMS on an approved test instance. The external runner must handle GO batch separators, database context, timeouts, permissions and collection envelopes. TempDB collector uses tempdb; other scripts use master.

## Production Safety

- No intended persistent objects or configuration changes on monitored instances.
- Temporary table variables are used; overhead must be measured.
- No automatic remediation, session termination or counter resets.
- Limit concurrency and event/history reads; preserve existing monitoring jobs.
- Never treat missing or stale observations as healthy.

## Safety hardening and pilot scope

The prepared 16-file replacement adds LOCK_TIMEOUT 5000 and DEADLOCK_PRIORITY LOW; collector 10 isolates advanced log-statistics errors per database. These settings do not replace command timeouts. Use dedicated or reset connections. COL-11, COL-12 and COL-16 remain disabled until incremental coverage and replay tests pass. All other collectors are test candidates only.

Documentation baseline: uploaded repository snapshot (2), plus subsequently prepared replacement scripts. GitHub commit equivalence must be verified from a fresh snapshot. No new SQL Server execution or compilation evidence was obtained during consolidation.

## Limitations

Initial supported target is SQL Server 2019+; test SQL Server 2022 separately. Earlier versions are outside the current deployment scope. AG, FCI, restricted permissions, PPDM, counter resets and history rollover require dedicated validation. SQL volume collection cannot cover all host volumes. Deadlock and error-log collectors do not guarantee complete event coverage. Wait statistics require specialized storage and aggregation.

## Validation Status

- File inventory and final projection: static review completed.
- SQL compilation and execution: pending.
- [Validation checklist and review findings](Validation-Checklist.md): open.
- Centralized integration and production pilot: pending.

## Module Status

Collector development complete – 16/16 drafts; not production verified.

Part of the SQL Server Production Optimization Framework.
