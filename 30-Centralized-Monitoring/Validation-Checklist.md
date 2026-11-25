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
- [ ] Verify new
