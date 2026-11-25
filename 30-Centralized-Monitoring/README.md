# Module 30 – Centralized Monitoring

## 1. Overview

The Centralized Monitoring module provides the database infrastructure required to collect, store, process and report SQL Server health and performance information across multiple SQL Server instances.

This module integrates with Module 26 – Data Collection and provides the foundation for an automated, scalable and production-conscious SQL Server monitoring solution.

The framework is designed to operate independently of existing inventory applications and production databases.

**Development Status:** Development Completed – Validation Pending  
**Repository Database:** DBA_Monitoring  
**Schema Version:** 1.0.6  
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
