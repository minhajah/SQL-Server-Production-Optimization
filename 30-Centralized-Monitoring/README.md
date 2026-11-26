# Module 30 – Centralized Monitoring

## 1. Overview

The Centralized Monitoring module provides the database infrastructure required to collect, store, process and report SQL Server health and performance information across multiple SQL Server instances.

This module integrates with Module 26 – Data Collection and provides the foundation for an automated, scalable and production-conscious SQL Server monitoring solution.

The framework is designed to operate independently of existing inventory applications and production databases.

**Development Status:** Development Completed – Validation Pending  
**Repository Database:** DBA_Monitoring  
**Schema Version:** 1.0.8  
**Initial Compatibility Target:** SQL Server 2019 and later

---

## 2. Objectives

- Centralize SQL Server health and performance monitoring.
- Support multiple SQL Server instances through configurable registration.
- Maintain historical performance and availability information.
- Identify collection failures and outdated monitoring data.
- Support incremental event collection and persistent checkpoints.
- Minimize monitoring overhead on production systems.
- Implement configurable data retention and historical aggregation.
- Provide a reporting interface for dashboards and automated notifications.
- Support future monitoring expansion without architectural redesign.
- Maintain separation from existing database inventory applications.

---

## 3. Monitoring Architecture

```text
SQL Server Instances
        |
        | Read-Only SQL Collectors
        |
        v
Python Collection Service
        |
        | Validation and Processing
        |
        v
DBA_Monitoring Database
        |
        +-- Instance Registration
        +-- Collector Configuration
        +-- Collection Execution History
        +-- Latest Metrics
        +-- Historical Metrics
        +-- Counter Baselines
        +-- Incremental Checkpoints
        +-- Historical Aggregation
        +-- Data Retention
        |
        v
Monitoring and Reporting Layer
        |
        +-- Centralized Dashboard
        +-- Daily Health Reports
        +-- Weekly Performance Reports
        +-- Monthly Capacity Reports
        +-- Alerts and Notifications
```

The Python collection service, reporting application and alerting engine are planned integration components and are not deployed by this module.

---

## 4. Script Inventory

| Script | Description |
|---|---|
| [01-Create-Monitoring-Database.sql](01-Create-Monitoring-Database.sql) | Creates the centralized monitoring database with initial configuration and deployment safeguards. |
| [02-Create-Monitoring-Tables.sql](02-Create-Monitoring-Tables.sql) | Creates the core monitoring tables, constraints and default safety settings. |
| [03-Create-Monitoring-Indexes.sql](03-Create-Monitoring-Indexes.sql) | Creates supporting indexes for collection scheduling, ingestion, reporting and retention. |
| [04-Register-SQL-Instances.sql](04-Register-SQL-Instances.sql) | Registers SQL Server instances using configurable connection and authentication references. |
| [05-Register-Collectors.sql](05-Register-Collectors.sql) | Registers Module 26 collectors, execution frequencies, timeouts and instance assignments. |
| [06-Collection-Logging.sql](06-Collection-Logging.sql) | Implements collection execution logging, concurrency protection, failure backoff and recovery. |
| [07-Collection-Checkpoints.sql](07-Collection-Checkpoints.sql) | Implements persistent incremental checkpoints and administrative reset auditing. |
| [08-Historical-Metrics.sql](08-Historical-Metrics.sql) | Implements metric ingestion, cumulative counter processing, event deduplication and hourly aggregation. |
| [09-Data-Retention.sql](09-Data-Retention.sql) | Implements configurable historical cleanup, aggregation verification and retention auditing. |
| [10-Monitoring-Views.sql](10-Monitoring-Views.sql) | Creates centralized reporting views for monitoring, scheduling, data freshness and historical analysis. |
| [11-Register-Metric-Definitions.sql](11-Register-Metric-Definitions.sql) | Registers metric catalog; runtime metadata verification pending. |
| [12-Repository-Security.sql](12-Repository-Security.sql) | Defines four repository security roles; effective permissions pending. |

---

## 5. Repository Database

| Configuration | Initial Value |
|---|---|
| Database Name | DBA_Monitoring |
| Recovery Model | SIMPLE |
| Compatibility Level | 150 |
| Initial Data File Size | 512 MB |
| Initial Log File Size | 256 MB |
| Data File Growth | 256 MB |
| Log File Growth | 128 MB |
| Page Verification | CHECKSUM |
| Auto Close | OFF |
| Auto Shrink | OFF |
| Auto Create Statistics | ON |
| Auto Update Statistics | ON |
| Trustworthy | OFF |
| Cross-Database Ownership Chaining | OFF |

These are proposed initial configurations. Final sizing, recovery requirements, file locations and backup policies must be validated before deployment.

---

## 6. Repository Tables

| Table | Purpose |
|---|---|
| MonitoredInstances | Registered SQL Server instances |
| Collectors | Collector definitions and execution configuration |
| InstanceCollectors | Instance-specific collector assignments |
| MetricDefinitions | Metric definitions and storage policies |
| MonitoredResources | Discovered monitoring resources |
| CollectionRuns | Collection execution history |
| MetricSamples | Historical monitoring measurements |
| LatestMetrics | Latest available metric observations |
| CollectionCheckpoints | Incremental collection checkpoints |
| MonitoringSettings | Central monitoring configuration |
| SchemaVersion | Repository schema deployment history |
| CheckpointAudit | Administrative checkpoint reset history |
| MetricCounterBaselines | Previous cumulative counter observations |
| MetricEventRegistry | Historical event deduplication |
| MetricHourlyAggregates | Hourly historical performance summaries |
| RetentionExecutionLog | Historical cleanup execution auditing |

---

## 7. Stored Procedures

### Collection Execution Management

| Stored Procedure | Purpose |
|---|---|
| usp_CollectionRunStart | Reserve and register collection execution |
| usp_CollectionRunComplete | Finalize collection execution and update scheduling |
| usp_CollectionRunRecover | Recover abandoned collection records |
| usp_CollectionHealthSummary | Review collection service health |

### Checkpoint Management

| Stored Procedure | Purpose |
|---|---|
| usp_CollectionCheckpointGet | Retrieve existing checkpoint |
| usp_CollectionCheckpointSave | Save incremental checkpoint |
| usp_CollectionCheckpointReset | Perform approved administrative reset |
| usp_CollectionCheckpointSummary | Review checkpoint health |

### Historical Metrics Management

| Stored Procedure | Purpose |
|---|---|
| usp_IngestMetricSamples | Validate and ingest collected monitoring metrics |
| usp_AggregateHourlyMetrics | Generate hourly metric summaries |
| usp_MetricStorageSummary | Review repository storage consumption |

### Data Retention Management

| Stored Procedure | Purpose |
|---|---|
| usp_DataRetentionPreview | Preview historical cleanup candidates |
| usp_ExecuteDataRetention | Execute controlled historical cleanup |
| usp_DataRetentionSummary | Review retention execution history |

---

## 8. Monitoring Views

| View | Monitoring Area |
|---|---|
| vw_InstanceOverview | Central instance monitoring coverage |
| vw_CollectionSchedule | Collector scheduling |
| vw_CollectionHealth | Collection execution health |
| vw_LatestMetrics | Latest metric observations |
| vw_HistoricalMetricSamples | Historical metric observations |
| vw_InstanceHealth | Instance availability |
| vw_DatabaseHealth | Database health |
| vw_CPUHealth | CPU performance |
| vw_MemoryHealth | Memory performance |
| vw_StorageHealth | Storage capacity and performance |
| vw_BackupHealth | Backup health |
| vw_HAHealth | High availability health |
| vw_SQLAgentHealth | SQL Agent health |
| vw_BlockingHealth | Blocking and transactions |
| vw_TransactionLogHealth | Transaction log health |
| vw_DeadlockHistory | Historical deadlock events |
| vw_ErrorLogHealth | SQL Server error logs |
| vw_WaitStatistics | Historical wait statistics |
| vw_TempDBHealth | TempDB performance |
| vw_QueryPerformance | Active query performance observations |
| vw_SQLAgentHistory | Historical job executions |
| vw_HourlyPerformance | Hourly performance trends |
| vw_RepositoryHealth | Monitoring repository storage |

---

## 9. Collector Integration

The centralized monitoring framework integrates with all 16 collectors developed in [Module 26 – Data Collection](../26-Data-Collection/).

| Collector | Proposed Interval |
|---|---|
| Instance Health | 60 seconds |
| Database Health | 60 seconds |
| CPU | 60 seconds |
| Memory | 60 seconds |
| Storage | 300 seconds |
| Backup | 900 seconds |
| High Availability | 60 seconds |
| SQL Agent | 300 seconds |
| Blocking | 60 seconds |
| Transaction Log | 300 seconds |
| Deadlock | 300 seconds |
| Error Log | 300 seconds |
| Wait Statistics | 300 seconds |
| TempDB | 60 seconds |
| Long-Running Query | 60 seconds |
| SQL Agent History | 300 seconds |

Collection frequencies, execution timeouts, output limits and scheduling priorities are configurable.

All collectors and instance-specific collector assignments remain disabled by default.

---

## 10. Standardized Metric Collection

The monitoring repository accepts the standardized 12-column output generated by Module 26 collectors.

| Column | Description |
|---|---|
| CaptureDateUTC | UTC observation timestamp |
| ServerName | Source SQL Server identity |
| ModuleID | Source monitoring module |
| MetricID | Collector metric identifier |
| Category | Monitoring category |
| ResourceType | Resource classification |
| ResourceName | Resource identity |
| MetricName | Metric description |
| MetricValue | Numeric observation |
| MetricUnit | Measurement unit |
| CollectionStatus | Collection result status |
| ErrorMessage | Sanitized diagnostic information |

All metric definitions must be registered before ingestion.

---

## 11. Historical Storage Policies

| Policy | Description |
| --- | --- |
| RAW | Store periodic observations |
| ON_CHANGE | Store changes in values or status |
| DELTA | Store cumulative counter differences |
| LATEST_ONLY | Maintain latest observations only |
| EVENT_ONLY | Store deduplicated event metrics |
Counter deltas require a stable epoch, increasing timestamp and nondecreasing counter. Event deduplication depends on stable event identities. Ingestion, checkpoint and successful completion must commit atomically.

---

## 12. Data Retention

| Data category | Proposed retention |
| --- | --- |
| Raw metrics | 7 days |
| Counter deltas | 7 days |
| State changes | 90 days |
| Historical events | 90 days |
| Hourly aggregates | 365 days |
| Collection execution history | 30 days |
| Checkpoint audit | 365 days |
| Retention execution history | 90 days |
| Latest metrics | Preserved |
| Counter baselines | Preserved |
| Collection checkpoints | Preserved |
| Event registry | Preserved initially |
Retention is disabled until tested. Dependencies may extend actual retention; verified-hour cleanup progress and late arrivals require reconciliation.

---

## 13. Monitoring Safety Controls

| Setting | Default |
| --- | --- |
| MonitoringEnabled | 0 |
| ProductionCollectionEnabled | 0 |
| AlertingEnabled | 0 |
| EmailReportingEnabled | 0 |
| PilotModeEnabled | 1 |
| MaximumConcurrentConnections | 2 |
| MaximumCollectorsPerInstance | 1 |
| DataRetentionEnabled | 0 |
| RawMetricRetentionDays | 7 |
| CollectionRunRetentionDays | 30 |
| StateMetricRetentionDays | 90 |
| EventMetricRetentionDays | 90 |
| HourlyAggregateRetentionDays | 365 |
| CheckpointAuditRetentionDays | 365 |
| RetentionLogRetentionDays | 90 |
| RetentionBatchSize | 5000 |
| RetentionMaximumBatches | 100 |
| RetentionMaximumRuntimeSeconds | 300 |
| RetentionRequireHourlyAggregation | 1 |
The Python service must enforce applicable switches, timeouts and concurrency limits. Configuration alone does not cancel remote commands.

---

## 14. Scalability and Instance Management

Register additional instances using scripts 04 and 05 without changing schema. New registrations and assignments remain disabled. Validate direct AG replica identities, FCI virtual endpoints, credentials and compatibility. Actual capacity must be benchmarked.

---

## 15. Security Considerations

Use approved dedicated identities, encrypted connections with certificate validation, least privilege and external secret storage. Never publish production endpoints, credentials or diagnostic evidence. Separate administrative, maintenance and reporting access. No automatic remediation.

---

## 16. Production Deployment Safety

Deploy repository scripts only on the approved central instance. Stop monitoring workers before schema or offline maintenance changes. Keep deployment flags disabled until approved. Read-only collectors still consume resources. Preserve existing inventory and monitoring applications.

---

## 17. Deployment Sequence

1. Complete technical review
2. Resolve critical defects
3. Compile and execute in non-production
4. Deploy repository and register test instances
5. Register metric catalog (11) and deploy repository roles (12); assign approved accounts separately
6. Integrate Python service
7. Validate ingestion, recovery, retention and permissions
8. Benchmark workload
9. Approved production pilot
10. Gradual expansion
11. Enable separately approved reports and alerts

---

## 18. Known Limitations and Pending Validation

The canonical issue IDs, status and acceptance criteria are maintained in [Technical-Review.md](Technical-Review.md). All applicable runtime tests and deployment gates remain pending; no issue is closed solely by a prepared patch.

---

## 19. Module Dependencies

| Module | Role |
| --- | --- |
| 01 – Server Inventory | Discovery reference |
| 02 – Server Configuration | Configuration assessment |
| 26 – Data Collection | Standardized output |
| 27 – Daily Health Report | Downstream reporting |
| 28 – Weekly Performance Report | Historical analysis |
| 29 – Monthly Capacity Report | Capacity analysis |
| 31 – Automated Email Reporting | Delivery |
| 32 – Health Check Thresholds | Classification |


---

## 20. Development Summary

| Component | Expected count |
| --- | --- |
| Database | 1 |
| Tables | 16 |
| Stored procedures | 14 |
| Views | 23 |
| Table-valued input types | 1 |
| Additional named nonclustered indexes | 16 |
| Initial settings | 19 |
| Schema version records | 9 |
| Collector definitions | 16 |
12 SQL scripts prepared. Schema target 1.0.8. Compilation, Python integration, performance testing and deployment pending.

---

## 21. Conclusion

The central repository is an initial development baseline. Complete the technical review, catalog metadata validation and integration before production use.

[Return to Main Repository](../README.md)

## Baseline integration decisions

Documentation baseline: uploaded repository snapshot (2), plus subsequently prepared replacement scripts. GitHub commit equivalence must be verified from a fresh snapshot. No new SQL Server execution or compilation evidence was obtained during consolidation.

- Ingestion validates metric units (TMP-012 exception), uses shared maintenance locking and rejects aggregate-eligible late batches after the 15-minute hour-closing cutoff.
- Aggregation and retention use exclusive maintenance locks; verified hourly groups are deleted atomically and may exceed normal batch size. Retention stays disabled.
- ReportingMetricUnit provides delta reporting units; freshness is separate from health severity.
- Successful or partial ingestion, optional checkpoint and completion use one caller transaction. Partial runs must not advance checkpoints. Reconcile uncertain commits using the original run token.
- Pilot excludes incremental collectors 11, 12 and 16 until coverage and replay are validated. The Python service is independent of the existing inventory application and must run offline.
