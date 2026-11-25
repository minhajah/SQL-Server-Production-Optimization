# Module 26 – Collector Reference

## Raw result contract (draft v1.0)

| Field | SQL type |
|---|---|
| CaptureDateUTC | datetime2(3) |
| ServerName | nvarchar(128) |
| ModuleID | varchar(2), literal 26 |
| MetricID | varchar(30) |
| Category | varchar(50) |
| ResourceType | varchar(30) |
| ResourceName | nvarchar(256) |
| MetricName | varchar(100) |
| MetricValue | decimal(28,4), nullable |
| MetricUnit | varchar(30) |
| CollectionStatus | varchar(20) |
| ErrorMessage | nvarchar(2048), nullable |

SUCCESS means an observation was obtained, not that the resource is healthy. UNKNOWN, FAILED, STALE and NOT APPLICABLE must be preserved and mapped explicitly. A successful collection-duration row does not prove the rest succeeded. Use a separate run envelope including TargetId, RunId, version, timestamps, row count and failure reason, as defined in Framework-Design.md. Preserve NULL and units. Do not send GO to an ODBC driver.

## Metric ID inventory

IDs extracted from the uploaded SQL source, including conditional diagnostic IDs. This is a source inventory, not an execution-verified metric dictionary. Metric names and units are defined by each script.

| Collector | Metric IDs |
|---|---|
| [01-Instance-Health-Collector.sql](01-Instance-Health-Collector.sql) | INST-001, INST-002, INST-003, INST-004, INST-005 |
| [02-Database-Health-Collector.sql](02-Database-Health-Collector.sql) | DB-000, DB-001, DB-002, DB-003, DB-004, DB-005, DB-006, DB-007 |
| [03-CPU-Collector.sql](03-CPU-Collector.sql) | CPU-001, CPU-002, CPU-003, CPU-004, CPU-005, CPU-006, CPU-007, CPU-008, CPU-009, CPU-010, CPU-011, CPU-012, CPU-013 |
| [04-Memory-Collector.sql](04-Memory-Collector.sql) | MEM-001, MEM-002, MEM-003, MEM-004, MEM-005, MEM-006, MEM-007, MEM-008, MEM-009, MEM-010, MEM-011, MEM-012, MEM-013, MEM-014, MEM-015, MEM-016, MEM-017, MEM-018, MEM-019, MEM-020 |
| [05-Storage-Collector.sql](05-Storage-Collector.sql) | STG-000, STG-001, STG-002, STG-003, STG-004, STG-005, STG-006, STG-007, STG-008, STG-009, STG-010, STG-011, STG-012, STG-013, STG-014, STG-015, STG-016, STG-017, STG-099 |
| [06-Backup-Collector.sql](06-Backup-Collector.sql) | BAK-000, BAK-001, BAK-002, BAK-003, BAK-004, BAK-005, BAK-006, BAK-007, BAK-008, BAK-009, BAK-010, BAK-011, BAK-012, BAK-013, BAK-014, BAK-015, BAK-016, BAK-017, BAK-018, BAK-019, BAK-020, BAK-021, BAK-022, BAK-023, BAK-096, BAK-097, BAK-098, BAK-099 |
| [07-HA-Health-Collector.sql](07-HA-Health-Collector.sql) | HA-001, HA-002, HA-003, HA-004, HA-005, HA-006, HA-007, HA-008, HA-009, HA-010, HA-011, HA-012, HA-013, HA-014, HA-015, HA-016, HA-017, HA-018, HA-019, HA-020, HA-021, HA-022, HA-023, HA-024, HA-025, HA-026, HA-027, HA-028, HA-029, HA-030, HA-096, HA-097, HA-098, HA-099 |
| [08-SQL-Agent-Collector.sql](08-SQL-Agent-Collector.sql) | JOB-001, JOB-002, JOB-003, JOB-004, JOB-005, JOB-006, JOB-007, JOB-008, JOB-009, JOB-010, JOB-011, JOB-012, JOB-013, JOB-014, JOB-015, JOB-016, JOB-017, JOB-018, JOB-019, JOB-020, JOB-099 |
| [09-Blocking-Collector.sql](09-Blocking-Collector.sql) | BLK-000, BLK-001, BLK-002, BLK-003, BLK-004, BLK-005, BLK-006, BLK-007, BLK-008, BLK-009, BLK-010, BLK-011, BLK-012, BLK-013, BLK-014, BLK-015, BLK-016, BLK-017, BLK-018, BLK-019, BLK-020, BLK-021, BLK-022, BLK-023, BLK-099 |
| [10-Transaction-Log-Collector.sql](10-Transaction-Log-Collector.sql) | LOG-000, LOG-001, LOG-002, LOG-003, LOG-004, LOG-005, LOG-006, LOG-007, LOG-008, LOG-009, LOG-010, LOG-011, LOG-012, LOG-013, LOG-014, LOG-015, LOG-016, LOG-017, LOG-018, LOG-019, LOG-020, LOG-021, LOG-097, LOG-098, LOG-099 |
| [11-Deadlock-Collector.sql](11-Deadlock-Collector.sql) | DLK-000, DLK-001, DLK-002, DLK-003, DLK-004, DLK-005, DLK-006, DLK-007, DLK-008, DLK-009, DLK-010, DLK-011, DLK-012, DLK-098, DLK-099 |
| [12-Error-Log-Collector.sql](12-Error-Log-Collector.sql) | ERR-000, ERR-001, ERR-002, ERR-003, ERR-004, ERR-005, ERR-006, ERR-007, ERR-008, ERR-009, ERR-010, ERR-011, ERR-012, ERR-013, ERR-014, ERR-015, ERR-016, ERR-017, ERR-018, ERR-019, ERR-020, ERR-021, ERR-022, ERR-023, ERR-098, ERR-099 |
| [13-Wait-Statistics-Collector.sql](13-Wait-Statistics-Collector.sql) | WAI-001, WAI-002, WAI-003, WAI-004, WAI-005, WAI-006, WAI-007, WAI-008, WAI-009, WAI-010, WAI-099 |
| [14-TempDB-Collector.sql](14-TempDB-Collector.sql) | TMP-000, TMP-001, TMP-002, TMP-003, TMP-004, TMP-005, TMP-006, TMP-007, TMP-008, TMP-009, TMP-010, TMP-011, TMP-012, TMP-013, TMP-014, TMP-015, TMP-016, TMP-017, TMP-018, TMP-019, TMP-020, TMP-021, TMP-022, TMP-023, TMP-024, TMP-025, TMP-098, TMP-099 |
| [15-Long-Running-Query-Collector.sql](15-Long-Running-Query-Collector.sql) | QRY-001, QRY-002, QRY-003, QRY-004, QRY-005, QRY-006, QRY-007, QRY-008, QRY-009, QRY-010, QRY-011, QRY-012, QRY-013, QRY-014, QRY-015, QRY-016, QRY-017, QRY-018, QRY-019, QRY-020, QRY-021, QRY-022, QRY-023, QRY-024, QRY-025, QRY-026, QRY-027, QRY-028, QRY-099 |
| [16-SQL-Agent-History-Collector.sql](16-SQL-Agent-History-Collector.sql) | JH-001, JH-002, JH-003, JH-004, JH-005, JH-006, JH-007, JH-008, JH-009, JH-010, JH-011, JH-012, JH-013, JH-014, JH-015, JH-016, JH-017, JH-018, JH-019, JH-099 |

## Integration rules

| Collector | Handling |
|---|---|
| 01–02 | External connection failure detection; expected database state and account visibility. |
| 03–04 | Sample age; distinguish gauges and cumulative memory counters. |
| 05 | File identity mapping, I/O deltas, reset detection; host volume coverage separately. |
| 06 | Correlate AG replicas, PPDM and database backup policy; local history is not restore proof. |
| 07 | Map GUIDs to topology; reconcile local and remote observations. |
| 08 | Map job GUID; latest outcome is not complete history. |
| 09 | Session IDs are ephemeral; current wait is not total incident duration. |
| 10 | Separate internal log free space and disk capacity. |
| 11–12 | Partial rolling-window observations; no summation of overlapping counts; incremental event capture required. |
| 13 | Dedicated latest baseline, interval deltas and rollups; do not delta maximum wait. |
| 14 | Space counters and suspected allocation waits; validate page identification. |
| 15 | Bounded active request snapshots; do not sum accumulated counters. |
| 16 | Durable checkpoint, deduplication, reconciliation and atomic central commit; local timestamps need timezone mapping. |

Use stable inventory identities and restart generations. Store event and high-volume time series separately from generic metrics. Approve retention, storage sizing and thresholds before pilot.
