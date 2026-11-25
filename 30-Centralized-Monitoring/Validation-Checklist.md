# Centralized Monitoring – Validation Checklist

## 1. Document Information

| Property | Details |
|---|---|
| Project | SQL Server Production Optimization |
| Module | 30 – Centralized Monitoring |
| Database | DBA_Monitoring |
| Schema Version | 1.0.6 |
| Document Version | 1.0 |
| Initial Compatibility Target | SQL Server 2019 and later |
| Initial Monitoring Scope | 25 SQL Server instances |
| Development Status | Development Completed |
| Validation Status | Pending |
| Production Deployment Status | Not Started |

---

## 2. Validation Objectives

- Validate repository deployment and configuration.
- Verify database schema and referential integrity.
- Validate integration with all Module 26 collectors.
- Verify collection scheduling and concurrency protection.
- Validate metric ingestion and historical processing.
- Prevent duplicate historical event storage.
- Ensure reliable checkpoint management.
- Validate historical aggregation and retention.
- Measure production monitoring overhead.
- Verify monitoring security and access controls.
- Ensure existing applications remain unaffected.
- Establish controlled production deployment procedures.
- Validate scalability for future SQL Server instances.

---

## 3. Validation Status Definitions

| Status | Description |
|---|---|
| PENDING | Validation not performed |
| PASS | Validation completed successfully |
| FAIL | Validation completed with errors |
| BLOCKED | Validation requires another dependency |
| NOT APPLICABLE | Validation does not apply to the environment |

A validation item must not be marked as passed without supporting evidence.

---

## 4. Pre-Deployment Infrastructure Validation

- [ ] Confirm approved central monitoring server.
- [ ] Confirm Windows Server version.
- [ ] Confirm SQL Server version and edition.
- [ ] Confirm available CPU resources.
- [ ] Confirm available physical memory.
- [ ] Confirm SQL Server memory configuration.
- [ ] Confirm available data drive capacity.
- [ ] Confirm available transaction log drive capacity.
- [ ] Confirm TempDB capacity.
- [ ] Confirm database backup destination.
- [ ] Confirm Python installation and supported version.
- [ ] Confirm supported SQL Server ODBC driver.
- [ ] Confirm network connectivity requirements.
- [ ] Confirm firewall requirements.
- [ ] Confirm DNS resolution.
- [ ] Confirm time synchronization.
- [ ] Confirm source server time zones.
- [ ] Confirm existing inventory application resource consumption.
- [ ] Establish monitoring repository resource limits.
- [ ] Confirm database recovery objectives.
- [ ] Confirm infrastructure deployment approval.

---

## 5. Script-Level Validation

| Script | Compilation | Execution | Functional Validation | Status |
|---|---|---|---|---|
| 01-Create-Monitoring-Database.sql | Pending | Pending | Pending | PENDING |
| 02-Create-Monitoring-Tables.sql | Pending | Pending | Pending | PENDING |
| 03-Create-Monitoring-Indexes.sql | Pending | Pending | Pending | PENDING |
| 04-Register-SQL-Instances.sql | Pending | Pending | Pending | PENDING |
| 05-Register-Collectors.sql | Pending | Pending | Pending | PENDING |
| 06-Collection-Logging.sql | Pending | Pending | Pending | PENDING |
| 07-Collection-Checkpoints.sql | Pending | Pending | Pending | PENDING |
| 08-Historical-Metrics.sql | Pending | Pending | Pending | PENDING |
| 09-Data-Retention.sql | Pending | Pending | Pending | PENDING |
| 10-Monitoring-Views.sql | Pending | Pending | Pending | PENDING |

All scripts must be tested on an approved non-production SQL Server instance before production repository deployment.

---

## 6. Deployment Safety Validation

- [ ] Verify deployment is disabled by default.
- [ ] Verify NULL deployment flags are rejected.
- [ ] Verify placeholder server names are rejected.
- [ ] Verify incorrect monitoring server identity is rejected.
- [ ] Verify incorrect database context is rejected.
- [ ] Verify database-context safety across SSMS batch boundaries.
- [ ] Verify unsupported SQL Server versions are rejected.
- [ ] Verify read-only repository deployment is rejected.
- [ ] Verify deployment inside an existing transaction is rejected.
- [ ] Verify required schema dependencies are validated.
- [ ] Verify deployment cannot bypass monitoring safety checks.
- [ ] Verify active collection runs prevent incompatible deployment operations.
- [ ] Verify failed schema deployment rolls back correctly.
- [ ] Verify existing repository objects are protected.
- [ ] Verify existing object definitions are compatible before reuse.
- [ ] Verify deployment scripts establish no remote connections.
- [ ] Verify no permanent objects are created on monitored production instances.
- [ ] Verify existing inventory application objects remain unchanged.

---

## 7. Database Creation Validation

Script: 01-Create-Monitoring-Database.sql

- [ ] Confirm DBA_Monitoring database creation.
- [ ] Confirm approved database file locations.
- [ ] Confirm sufficient disk capacity before creation.
- [ ] Confirm initial data file size.
- [ ] Confirm initial transaction log file size.
- [ ] Confirm fixed-size file growth settings.
- [ ] Confirm approved maximum database growth policy.
- [ ] Confirm SIMPLE recovery model is appropriate.
- [ ] Confirm compatibility level 150.
- [ ] Confirm PAGE_VERIFY CHECKSUM.
- [ ] Confirm AUTO_CLOSE is disabled.
- [ ] Confirm AUTO_SHRINK is disabled.
- [ ] Confirm automatic statistics creation.
- [ ] Confirm automatic statistics updates.
- [ ] Confirm TRUSTWORTHY is disabled.
- [ ] Confirm cross-database ownership chaining is disabled.
- [ ] Confirm existing database protection.
- [ ] Validate recovery from partially completed database creation.
- [ ] Validate repository backup and restore.

---

## 8. Repository Schema Validation

Script: 02-Create-Monitoring-Tables.sql

- [ ] Verify all 11 initial repository tables.
- [ ] Verify primary key definitions.
- [ ] Verify unique constraints.
- [ ] Verify foreign key relationships.
- [ ] Verify check constraints.
- [ ] Verify default constraints.
- [ ] Verify identity columns.
- [ ] Verify numeric precision and scale.
- [ ] Verify required column nullability.
- [ ] Verify UTC timestamp defaults.
- [ ] Verify resource name collation behavior.
- [ ] Verify duplicate instance names are rejected.
- [ ] Verify duplicate connection targets are rejected.
- [ ] Verify duplicate collector definitions are rejected.
- [ ] Verify invalid environment values are rejected.
- [ ] Verify invalid execution statuses are rejected.
- [ ] Verify invalid metric collection statuses are rejected.
- [ ] Verify cross-instance resource references are rejected.
- [ ] Verify collector ownership of metric definitions.
- [ ] Verify all initial monitoring safety settings.
- [ ] Verify transactional schema deployment.
- [ ] Verify initial schema version registration.

---

## 9. Index Validation

Script: 03-Create-Monitoring-Indexes.sql

- [ ] Verify all 10 initial supporting indexes.
- [ ] Verify index key columns.
- [ ] Verify included columns.
- [ ] Verify filtered index definitions.
- [ ] Verify required session SET options for filtered indexes.
- [ ] Verify existing index definitions before skipping creation.
- [ ] Verify existing indexes are not dropped.
- [ ] Verify existing indexes are not rebuilt unnecessarily.
- [ ] Verify collector scheduling query performance.
- [ ] Verify collection history query performance.
- [ ] Verify latest metric query performance.
- [ ] Verify historical metric query performance.
- [ ] Verify retention query performance.
- [ ] Measure index storage overhead.
- [ ] Measure index write overhead.
- [ ] Identify redundant or unused indexes after representative testing.
- [ ] Verify schema version 1.0.1.

---

## 10. SQL Instance Registration Validation

Script: 04-Register-SQL-Instances.sql

- [ ] Verify placeholder registration records are rejected.
- [ ] Verify new SQL Server instance registration.
- [ ] Verify duplicate instance name detection.
- [ ] Verify duplicate connection target detection.
- [ ] Verify conflicting registration records are rejected.
- [ ] Verify existing registrations remain unchanged.
- [ ] Verify new instances remain disabled.
- [ ] Verify environment and authentication classification.
- [ ] Verify external credential references and connection timeout.
- [ ] Validate actual remote identity and duplicate aliases.
- [ ] Verify SQL version, edition and time zone discovery.
- [ ] Verify direct AG replicas and FCI virtual endpoints.
- [ ] Verify pilot designation and future instance registration.
- [ ] Verify no production endpoints or passwords are published.

---

## 11. Collector Registration Validation

- [ ] Verify all 16 codes, filenames, versions and collection types.
- [ ] Verify intervals, timeouts, priorities and row limits.
- [ ] Verify compatibility checks and disabled unknown-version assignments.
- [ ] Verify existing configuration preserved and new assignments disabled.
- [ ] Verify overrides and rerunnable missing assignments.
- [ ] Verify additional server registration; 400 assignments for 25 eligible instances.

---

## 12. Collection Logging Validation

- [ ] Verify unique run tokens and duplicate reservation prevention.
- [ ] Verify global, instance, collector, assignment, production and pilot switches.
- [ ] Verify compatibility, due scheduling and concurrency limits.
- [ ] Test application locks and simultaneous reservations.
- [ ] Test all seven run statuses, durations, counts and token ownership.
- [ ] Test completion retry, failure backoff and next schedule.
- [ ] Verify completion participates in ingestion transaction and rollback.
- [ ] Test clock changes and sanitized errors.
- [ ] Verify recovery preview, authorization, stopped workers and remote command completion.
- [ ] Verify abandoned run cancellation and rescheduling without remote KILL.
- [ ] Verify schema version 1.0.2.

---

## 13. Checkpoint Management Validation

- [ ] Test missing, existing and initialized checkpoints.
- [ ] Test numeric, text and date values.
- [ ] Test rowversion conflicts, run ownership and incremental collector restriction.
- [ ] Test regression and older run protection.
- [ ] Reject missing or uncommittable ingestion transactions.
- [ ] Verify failed or partial ingestion does not incorrectly advance checkpoints.
- [ ] Test rollback, restart and unknown commit reconciliation.
- [ ] Test authorized reset preview, audit and preservation of history.
- [ ] Verify freshness and schema version 1.0.3.

---

## 14. Historical Metric Ingestion Validation

- [ ] Register every metric including diagnostic and failure IDs.
- [ ] Validate catalog names, categories, resource types, units, behaviors, policies and versions.
- [ ] Reject unknown metric IDs; verify disabled metrics.
- [ ] Test all 12 columns and TVP integration.
- [ ] Validate source identity, module and run ownership.
- [ ] Test empty output, row limit, duplicates, precision, NULLs, units, timestamps and statuses.
- [ ] Sanitize error messages and test repeated ingestion.
- [ ] Test resource identity, binary collation, reuse, activation and expiration.
- [ ] Verify latest observations, equal timestamps and out-of-order samples.
- [ ] Preserve last successful values and distinguish failed or missing data.

---

## 15. Historical Storage Policy Validation

- [ ] RAW: test valid and unsuccessful samples and duplicate ingestion.
- [ ] ON_CHANGE: test initial, unchanged, numeric, status, NULL, unit and error transitions.
- [ ] DELTA: test first baseline, interval, restart, epoch, decrease, unit changes and failed observations.
- [ ] DELTA: test missing, delayed, out-of-order and zero-delta observations; quantify wait volume.
- [ ] LATEST_ONLY: verify no history and disabled metric handling.
- [ ] EVENT_ONLY: test stable identity, source generation, repeated ingestion, rollback and reset.
- [ ] Distinguish event timestamp from capture timestamp.

---

## 16. Incremental Collector Validation

- [ ] Deadlocks: validate system_health, file target, identity and timestamp.
- [ ] Implement XE file-position checkpoint; test rollover, missing files, deduplication and coverage.
- [ ] Measure XE read overhead and validate permissions.
- [ ] Error log: test size guard, unknown size, severity parsing and relevant error codes.
- [ ] Implement incremental log processing; test rotation, timestamps, deduplication, incomplete coverage and cancellation.
- [ ] Agent history: test initial collection, checkpoints, outcome, duration and timestamps.
- [ ] Test timezone and DST handling, batch limits, backlog and history gaps.
- [ ] Test purge, reset, msdb restore and concurrent inserts.
- [ ] Verify checkpoint advancement and duplicate prevention.

---

## 17. Historical Aggregation Validation

- [ ] Test UTC hour boundaries, incomplete hour rejection and preview.
- [ ] Verify count, min, max, average, delta sum and units.
- [ ] Exclude failed and event samples.
- [ ] Verify first/last timestamps and duplicate hour handling.
- [ ] Implement late-arrival reconciliation and test crossing-hour deltas.
- [ ] Test maintenance locks, CPU, I/O and temporary storage.
- [ ] Verify schema version 1.0.4.

---

## 18. Data Retention Validation

- [ ] Verify disabled default, read-only preview and explicit authorization.
- [ ] Reject invalid retention, batch and runtime values.
- [ ] Test stopped workers, active runs, locks and configuration changes.
- [ ] Verify expired raw/delta/state/event/aggregate selection and protected dependencies.
- [ ] Verify complete aggregate coverage and preserve incomplete hours.
- [ ] Preserve latest state, latest metrics, baselines, checkpoints and deduplication.
- [ ] Test batch and runtime bounds, delay and stop switches.
- [ ] Test rollback and committed audit counts.
- [ ] Implement persistent verified-hour cleanup tracking; test partial cleanup and late arrivals.
- [ ] Test fairness, interrupted audit recovery and session lock release.
- [ ] Measure log use and blocking; verify no shrink and schema 1.0.5.

---

## 19. Monitoring View Validation

- [ ] Compile all 23 views and verify repository-only access.
- [ ] Test scheduling, coverage, disabled, pilot and production restrictions.
- [ ] Test stale, failed, overdue, missing and clock-skew observations.
- [ ] Ensure completed transient resources are not shown as active.
- [ ] Verify event and wait delta filters, bounded history and storage calculations.
- [ ] Test reporting permissions and performance; verify schema 1.0.6.

---

## 20. Module 26 Collector Integration Validation

- [ ] Test all 16 collectors for compatibility, accuracy, performance and permissions.
- [ ] Validate CPU ring buffer, memory counters and complete volume coverage.
- [ ] Validate enterprise backup history and AG replica reconciliation; restore testing separately.
- [ ] Test AG primary/secondary, multi-subnet, FCI and approved failover.
- [ ] Test blocking identity, VLF visibility, TempDB and expensive request limits.
- [ ] Test restricted, offline and recovery-pending databases and failure isolation.

---

## 21. Python Collection Service Integration

- [ ] Keep application independent of existing inventory.
- [ ] Test repository connectivity, ODBC, encryption and certificate validation.
- [ ] Test secure credentials and approved authentication.
- [ ] Test script loading, GO handling, parameters and result parsing.
- [ ] Test source identity, metric conversion and TVP support.
- [ ] Test connection/command timeouts, cancellation, disposal and row limits.
- [ ] Test concurrency, fairness, staggered scheduling and retry backoff.
- [ ] Implement instance-wide connection failure circuit breaker.
- [ ] Test dynamic registration, configuration, shutdown and restart.
- [ ] Test atomic ingestion, checkpoints and unknown commit reconciliation.
- [ ] Test logging, redaction, disk protection, repository outage and graceful degradation.

---

## 22. Security and Permission Validation

- [ ] Implement separate repository roles and least privilege.
- [ ] Restrict direct table updates; grant approved procedures, types and views.
- [ ] Restrict deployment, configuration, reset, recovery and deletion.
- [ ] Verify admin audit and dedicated production identity.
- [ ] Validate version-specific DMV, msdb, Agent, XE, error log and HA permissions.
- [ ] Verify no unnecessary sysadmin, app database writes or remediation permissions.
- [ ] Test credential rotation.

---

## 23. Performance and Capacity Validation

- [ ] Measure individual collector CPU, reads, duration and cancellation.
- [ ] Compare production CPU, memory, disk latency, blocking and application response before/after.
- [ ] Test peak workload, backup, maintenance and AG synchronization.
- [ ] Measure central throughput, aggregation, retention, reports, log and TempDB.
- [ ] Measure daily storage growth, worker utilization and schedule lag.
- [ ] Confirm inventory application performance; approve limits before pilot.

---

## 24. Failure and Recovery Testing

- [ ] Test unreachable instance, authentication and permissions failures.
- [ ] Test timeout, network interruption and repository outage or disk full.
- [ ] Test Python crash, unknown commit, duplicate run and event.
- [ ] Test SQL restart, counter reset, AG failover and Agent restart.
- [ ] Test msdb restore, XE rollover and error-log rotation.
- [ ] Test retention interruption and monitoring server restart.

---

## 25. Monitoring Repository Recovery Validation

- [ ] Agree RPO, RTO and backup frequency.
- [ ] Verify full/differential backup where applicable and checksum.
- [ ] Restore test copy and verify integrity.
- [ ] Verify restored configuration, definitions, history, checkpoints, baselines and deduplication.
- [ ] Test restart and duplicate protection after restore.
- [ ] Document recovery procedures.

---

## 26. Production Pilot Validation

- [ ] Complete applicable non-production tests and resolve critical defects.
- [ ] Approve one pilot instance, account, permissions and scope.
- [ ] Capture baseline and enable only approved assignments.
- [ ] Verify accuracy, monitoring health, CPU, memory, I/O and response time.
- [ ] Verify backup/maintenance compatibility and repository growth.
- [ ] Confirm inventory unaffected and review failures and intervals.
- [ ] Test safe shutdown and obtain expansion approval.

---

## 27. Controlled Production Expansion

- [ ] Test one non-production instance.
- [ ] Approve one production pilot.
- [ ] Expand to five approved instances.
- [ ] Expand remaining instances in controlled batches.
- [ ] Review capacity, performance, durations, delays, storage, permissions and unresolved failures before each expansion.

---

## 28. Rollback and Emergency Stop Validation

- [ ] Test global, instance and collector disable switches.
- [ ] Prevent new reservations and safely stop remote commands and workers.
- [ ] Rollback uncommitted ingestion while preserving committed history/checkpoints.
- [ ] Disable retention, alerting and reporting independently.
- [ ] Confirm existing applications and monitoring remain operational.
- [ ] Document emergency stop procedures.

---

## 29. Final Repository Object Verification

| Object | Expected | Actual | Status |
| --- | --- | --- | --- |
| Database | 1 | TBD | PENDING |
| Tables | 16 | TBD | PENDING |
| Stored procedures | 14 | TBD | PENDING |
| Views | 23 | TBD | PENDING |
| Table-valued input types | 1 | TBD | PENDING |
| Additional named nonclustered indexes | 16 | TBD | PENDING |
| Initial settings | 19 | TBD | PENDING |
| Schema version records | 7 | TBD | PENDING |
| Collector definitions | 16 | TBD | PENDING |
| Instances | Configurable | TBD | PENDING |
| Metric definitions | Catalog dependent | TBD | PENDING |


---

## 30. Known Technical Issues and Deployment Blockers

| ID | Issue | Priority | Status |
| --- | --- | --- | --- |
| CM-001 | Complete metric definition catalog missing | Critical | OPEN |
| CM-002 | SQL compilation and execution testing pending | Critical | OPEN |
| CM-003 | Python integration pending | Critical | OPEN |
| CM-004 | Atomic ingestion and checkpoint transaction enforcement | Critical | OPEN |
| CM-005 | Persistent verified-hour retention tracking | Critical | OPEN |
| CM-006 | Least-privilege permissions | High | OPEN |
| CM-007 | Incremental XE rollover | High | OPEN |
| CM-008 | Incremental error-log processing | High | OPEN |
| CM-009 | SQL Agent history discontinuity | High | OPEN |
| CM-010 | Counter epoch and reset detection | High | OPEN |
| CM-011 | Event generation and deduplication | High | OPEN |
| CM-012 | Late-arriving sample reconciliation | High | OPEN |
| CM-013 | Transient resource lifecycle | High | OPEN |
| CM-014 | Instance-wide connection failure circuit breaker | High | OPEN |
| CM-015 | Capacity and overhead testing | High | OPEN |
| CM-016 | Scheduling fairness | Medium | OPEN |
| CM-017 | Existing object definition verification | Medium | OPEN |
| CM-018 | Maintenance interruption recovery | High | OPEN |
| CM-019 | Event registry growth policy | Medium | OPEN |
| CM-020 | Threshold and incident classification | High | OPEN |
| CM-021 | Failed database-context and deployment flag safety | High | OPEN |
| CM-022 | High-volume wait statistics storage optimization | High | OPEN |
All critical blockers must be resolved before production pilot. Other issues must be resolved or explicitly excluded from approved scope.

---

## 31. Validation Evidence Register

| Test ID | Description | Environment | Result | Evidence | Tested by | Date |
| --- | --- | --- | --- | --- | --- | --- |
| TBD | TBD | TBD | PENDING | TBD | TBD | TBD |
Keep confidential production evidence internally; do not upload it to public GitHub.

---

## 32. Production Readiness Approval

| Approval area | Status | Approved by | Date |
| --- | --- | --- | --- |
| SQL review | PENDING | TBD | TBD |
| Schema | PENDING | TBD | TBD |
| Collectors | PENDING | TBD | TBD |
| Python integration | PENDING | TBD | TBD |
| Security | PENDING | TBD | TBD |
| Performance | PENDING | TBD | TBD |
| Recovery | PENDING | TBD | TBD |
| Retention | PENDING | TBD | TBD |
| Pilot | PENDING | TBD | TBD |
| Expansion | PENDING | TBD | TBD |


---

## 33. Final Validation Summary

| Area | Status |
| --- | --- |
| SQL development | COMPLETED |
| Documentation | COMPLETED |
| Technical review | PENDING |
| Metric catalog | PENDING |
| Non-production testing | PENDING |
| Python integration | PENDING |
| Security and performance | PENDING |
| Production pilot and deployment | NOT STARTED |
Current module status: Development Completed – Validation Pending. No production-readiness claim.

---

## 34. Related Documentation

- [Module 30](README.md)
- [Repository Schema](Repository-Schema.md)
- [Module 26](../26-Data-Collection/)
- [Main Repository](../README.md)
