# Centralized Monitoring – Repository Schema

## 1. Document Information

| Property | Details |
|---|---|
| Project | SQL Server Production Optimization |
| Module | 30 – Centralized Monitoring |
| Database | DBA_Monitoring |
| Schema Version | 1.0.8 |
| Document Version | 1.0 |
| Compatibility Target | SQL Server 2019 and later |
| Development Status | Development Completed – Validation Pending |
| Initial Deployment Scope | 25 SQL Server instances |
| Architecture | Centralized monitoring repository |

---

## 2. Database Object Inventory

| Object Type | Count |
|---|---:|
| Database | 1 |
| Tables | 16 |
| Stored Procedures | 14 |
| Views | 23 |
| User-Defined Table Types | 1 |
| Registered Collector Definitions | 16 planned |

Object counts describe the intended deployed schema. Actual deployment results must be verified during testing.

---

## 3. Repository Design Principles

- Separate production metric collection from centralized storage.
- Normalize instance, resource and metric identifiers.
- Minimize unnecessary historical data storage.
- Maintain current and historical observations separately.
- Support configurable monitoring frequencies.
- Preserve incremental collection continuity.
- Prevent duplicate event ingestion.
- Support cumulative counter processing.
- Maintain configurable retention policies.
- Provide a consistent reporting interface.
- Preserve administrative and operational accountability.
- Support future instance and collector expansion.
- Avoid dependencies on existing inventory application tables.

---

## 4. Logical Database Relationships

```text
MonitoredInstances
    |
    +-- InstanceCollectors
    |       |
    |       +-- CollectionRuns
    |       |       |
    |       |       +-- MetricSamples
    |       |
    |       +-- CollectionCheckpoints
    |
    +-- MonitoredResources
            |
            +-- MetricSamples
            +-- LatestMetrics
            +-- MetricCounterBaselines
            +-- MetricEventRegistry
            +-- MetricHourlyAggregates

Collectors
    |
    +-- InstanceCollectors
    |
    +-- MetricDefinitions
            |
            +-- MetricSamples
            +-- LatestMetrics
            +-- MetricCounterBaselines
            +-- MetricEventRegistry
            +-- MetricHourlyAggregates

Administrative Objects
    |
    +-- MonitoringSettings
    +-- SchemaVersion
    +-- CheckpointAudit
    +-- RetentionExecutionLog
```

The diagram represents logical relationships. Some historical collection-run references are maintained by application logic rather than enforced foreign key constraints.

---

## 5. Configuration Tables

### 5.1 dbo.MonitoredInstances

Stores registered SQL Server instances and their connection configuration.

| Column | Data Type | Description |
|---|---|---|
| InstanceID | INT | Primary key |
| InstanceName | NVARCHAR(128) | Unique monitoring instance name |
| ConnectionTarget | NVARCHAR(256) | SQL Server connection endpoint |
| ServerName | NVARCHAR(128) | Validated SQL Server identity |
| Environment | VARCHAR(20) | Environment classification |
| SQLVersion | NVARCHAR(50) | SQL Server product version |
| SQLMajorVersion | INT | SQL Server major version |
| SQLEdition | NVARCHAR(128) | SQL Server edition |
| TimeZoneName | NVARCHAR(128) | Source server time zone |
| AuthenticationType | VARCHAR(30) | Authentication method |
| CredentialReference | NVARCHAR(256) | External credential reference |
| ConnectionTimeoutSeconds | INT | Connection timeout |
| IsEnabled | BIT | Monitoring activation status |
| IsPilotInstance | BIT | Pilot instance designation |
| CreatedDateUTC | DATETIME2(3) | Registration timestamp |
| ModifiedDateUTC | DATETIME2(3) | Last configuration modification |
| Notes | NVARCHAR(1000) | Administrative notes |

Primary Key: InstanceID

Unique Constraints:

- InstanceName
- ConnectionTarget

Supported Environments:

- PRODUCTION
- DR
- UAT
- TEST
- DEVELOPMENT

New instances are disabled by default.

Passwords must not be stored in this table.

### 5.2 dbo.Collectors

Stores collector definitions and execution configuration.

| Column | Data Type | Description |
|---|---|---|
| CollectorID | INT | Primary key |
| CollectorCode | VARCHAR(30) | Unique collector identifier |
| ModuleID | VARCHAR(10) | Source module |
| CollectorName | NVARCHAR(128) | Collector display name |
| ScriptFileName | NVARCHAR(256) | Collector SQL filename |
| ScriptVersion | VARCHAR(20) | Collector version |
| CollectionType | VARCHAR(20) | Collection processing type |
| DefaultIntervalSeconds | INT | Default execution interval |
| DefaultTimeoutSeconds | INT | Default execution timeout |
| MinimumSQLMajorVersion | INT | Minimum supported SQL version |
| MaximumOutputRows | INT | Configured output limit |
| ExecutionPriority | INT | Scheduling priority |
| IsEnabled | BIT | Collector activation status |
| CreatedDateUTC | DATETIME2(3) | Registration timestamp |
| ModifiedDateUTC | DATETIME2(3) | Last modification timestamp |
| Description | NVARCHAR(1000) | Collector description |

Primary Key: CollectorID

Unique Constraints:

- CollectorCode
- ScriptFileName

Collection Types:

- SNAPSHOT
- CUMULATIVE
- INCREMENTAL

Execution priority ranges from 1 to 100, with 1 representing the highest scheduling priority.

### 5.3 dbo.InstanceCollectors

Maintains collector assignments for individual SQL Server instances.

| Column | Data Type | Description |
|---|---|---|
| InstanceID | INT | Registered instance |
| CollectorID | INT | Registered collector |
| IntervalOverrideSeconds | INT | Instance-specific collection interval |
| TimeoutOverrideSeconds | INT | Instance-specific execution timeout |
| IsEnabled | BIT | Assignment activation status |
| NextRunDateUTC | DATETIME2(3) | Next scheduled execution |
| LastAttemptDateUTC | DATETIME2(3) | Latest collection attempt |
| LastSuccessDateUTC | DATETIME2(3) | Latest successful collection |
| ConsecutiveFailures | INT | Consecutive unsuccessful collections |
| CreatedDateUTC | DATETIME2(3) | Assignment creation timestamp |
| ModifiedDateUTC | DATETIME2(3) | Assignment modification timestamp |

Composite Primary Key:

- InstanceID
- CollectorID

Foreign Keys:

- InstanceID → MonitoredInstances
- CollectorID → Collectors

Effective configuration uses instance-specific overrides when provided; otherwise, collector defaults are applied.

---

## 6. Metric and Resource Definitions

### 6.1 dbo.MetricDefinitions

Defines the meaning, behavior and storage policy of each monitoring metric.

| Column | Data Type | Description |
|---|---|---|
| MetricDefinitionID | INT | Internal primary key |
| CollectorID | INT | Owning collector |
| MetricID | VARCHAR(30) | Collector metric identifier |
| MetricName | NVARCHAR(100) | Metric description |
| Category | VARCHAR(50) | Monitoring category |
| ResourceType | VARCHAR(30) | Expected resource classification |
| DefaultMetricUnit | VARCHAR(30) | Default measurement unit |
| MetricBehavior | VARCHAR(20) | Metric semantic behavior |
| StoragePolicy | VARCHAR(30) | Historical storage policy |
| IsEnabled | BIT | Metric ingestion activation |
| CreatedDateUTC | DATETIME2(3) | Definition creation timestamp |
| Description | NVARCHAR(1000) | Additional metric documentation |

Primary Key: MetricDefinitionID

Unique Constraint:

- CollectorID + MetricID

Foreign Key:

- CollectorID → Collectors

Supported Metric Behaviors:

| Behavior | Description |
|---|---|
| GAUGE | Point-in-time measurement |
| COUNTER | Cumulative numeric observation |
| STATE | Numeric state classification |
| IDENTIFIER | Numeric resource or configuration identifier |
| EVENT | Historical event observation |
| TIMESTAMP | Numeric timestamp representation |

Supported Storage Policies:

| Policy | Description |
|---|---|
| RAW | Store periodic observations |
| ON_CHANGE | Store changes in values or collection status |
| DELTA | Store cumulative counter differences |
| LATEST_ONLY | Maintain latest observations without raw history |
| EVENT_ONLY | Store deduplicated historical events |

All metric definitions must be registered before ingestion.

### 6.2 dbo.MonitoredResources

Stores normalized resource identities discovered during collection.

| Column | Data Type | Description |
|---|---|---|
| ResourceID | BIGINT | Primary key |
| InstanceID | INT | Owning SQL Server instance |
| ResourceType | VARCHAR(30) | Resource classification |
| ResourceName | NVARCHAR(256) | Resource identity |
| DisplayName | NVARCHAR(256) | Optional display name |
| FirstSeenDateUTC | DATETIME2(3) | First repository observation |
| LastSeenDateUTC | DATETIME2(3) | Latest repository observation |
| IsActive | BIT | Resource activation status |

Primary Key: ResourceID

Unique Constraints:

- InstanceID + ResourceType + ResourceName
- InstanceID + ResourceID

Foreign Key:

- InstanceID → MonitoredInstances

ResourceName uses a binary collation to preserve case-sensitive resource identities.

Resources may represent instances, databases, volumes, database files, availability groups, replicas, SQL Agent jobs, sessions, requests, wait types and historical events.

Transient resource lifecycle management remains pending.

---

## 7. Collection Execution Tables

### 7.1 dbo.CollectionRuns

Tracks individual collector executions.

| Column | Data Type | Description |
|---|---|---|
| CollectionRunID | BIGINT | Primary key |
| RunToken | UNIQUEIDENTIFIER | Unique execution token |
| InstanceID | INT | Source instance |
| CollectorID | INT | Executed collector |
| StartDateUTC | DATETIME2(3) | Execution start |
| EndDateUTC | DATETIME2(3) | Execution completion |
| DurationMilliseconds | BIGINT | Execution duration |
| RunStatus | VARCHAR(20) | Execution outcome |
| RowsReturned | BIGINT | Number of collected output rows |
| RowsStored | BIGINT | Number of historical rows stored |
| ErrorNumber | INT | Collection error code |
| ErrorMessage | NVARCHAR(2048) | Sanitized diagnostic information |
| CollectorVersion | VARCHAR(20) | Executed collector version |

Primary Key: CollectionRunID

Unique Constraints:

- RunToken
- CollectionRunID + InstanceID

Foreign Key:

- InstanceID + CollectorID → InstanceCollectors

Supported Execution Statuses:

| Status | Description |
|---|---|
| RUNNING | Reserved or active execution |
| SUCCESS | Successfully completed collection |
| PARTIAL | Incomplete collection |
| FAILED | Unsuccessful collection |
| TIMEOUT | Execution timeout |
| SKIPPED | Intentionally skipped execution |
| CANCELLED | Cancelled or abandoned execution |

Successful collection does not imply that the monitored resource is healthy.

### 7.2 dbo.CollectionCheckpoints

Maintains persistent incremental collector positions.

| Column | Data Type | Description |
|---|---|---|
| CheckpointID | BIGINT | Primary key |
| InstanceID | INT | Source instance |
| CollectorID | INT | Incremental collector |
| CheckpointKey | VARCHAR(100) | Checkpoint identifier |
| NumericCheckpoint | BIGINT | Numeric source position |
| TextCheckpoint | NVARCHAR(4000) | Source identity or file position |
| DateCheckpointUTC | DATETIME2(7) | Source timestamp |
| LastSuccessDateUTC | DATETIME2(3) | Last successful checkpoint update |
| LastCollectionRunID | BIGINT | Associated collection run |
| UpdatedDateUTC | DATETIME2(3) | Last modification timestamp |
| RowVersion | ROWVERSION | Optimistic concurrency token |

Primary key: CheckpointID. Unique: InstanceID + CollectorID + CheckpointKey. Foreign key: InstanceID + CollectorID → InstanceCollectors. Advance only in the successful ingestion transaction.

---

## 8. Historical and Current Metric Tables

### 8.1 dbo.MetricSamples

| Column | Data Type |
| --- | --- |
| SampleID | BIGINT |
| CollectionRunID | BIGINT |
| InstanceID | INT |
| ResourceID | BIGINT |
| MetricDefinitionID | INT |
| CaptureDateUTC | DATETIME2(3) |
| MetricValue | DECIMAL(28,4) |
| MetricUnit | VARCHAR(30) |
| CollectionStatus | VARCHAR(20) |
| ErrorMessage | NVARCHAR(2048) |
| InsertedDateUTC | DATETIME2(3) |
| SampleKind | VARCHAR(20) |
| IntervalStartUTC | DATETIME2(3) |

PK SampleID; unique CollectionRunID + ResourceID + MetricDefinitionID. Foreign keys to run/instance, resource/instance and metric definition. SampleKind and IntervalStartUTC are added by script 08.

### 8.2 dbo.LatestMetrics

| Column | Data Type |
| --- | --- |
| InstanceID | INT |
| ResourceID | BIGINT |
| MetricDefinitionID | INT |
| CollectionRunID | BIGINT |
| CaptureDateUTC | DATETIME2(3) |
| MetricValue | DECIMAL(28,4) |
| MetricUnit | VARCHAR(30) |
| CollectionStatus | VARCHAR(20) |
| ErrorMessage | NVARCHAR(2048) |
| LastSuccessfulCaptureUTC | DATETIME2(3) |
| LastSuccessfulValue | DECIMAL(28,4) |
| LastSuccessfulUnit | VARCHAR(30) |
| UpdatedDateUTC | DATETIME2(3) |

Composite PK InstanceID + ResourceID + MetricDefinitionID. Preserve last successful observation separately. Foreign keys to resource/instance and metric definition.

### 8.3 dbo.MetricCounterBaselines

| Column | Data Type |
| --- | --- |
| InstanceID | INT |
| ResourceID | BIGINT |
| MetricDefinitionID | INT |
| CaptureDateUTC | DATETIME2(3) |
| CounterValue | DECIMAL(28,4) |
| CounterUnit | VARCHAR(30) |
| CounterEpoch | NVARCHAR(128) |
| CollectionRunID | BIGINT |
| UpdatedDateUTC | DATETIME2(3) |

Composite PK InstanceID + ResourceID + MetricDefinitionID. Stable counter epoch and units required.

### 8.4 dbo.MetricEventRegistry

| Column | Data Type |
| --- | --- |
| InstanceID | INT |
| ResourceID | BIGINT |
| MetricDefinitionID | INT |
| EventGeneration | NVARCHAR(128) |
| FirstCollectionRunID | BIGINT |
| FirstSeenDateUTC | DATETIME2(3) |

Composite PK InstanceID + ResourceID + MetricDefinitionID + EventGeneration. Deduplication is at event metric level.

### 8.5 dbo.MetricHourlyAggregates

| Column | Data Type |
| --- | --- |
| InstanceID | INT |
| ResourceID | BIGINT |
| MetricDefinitionID | INT |
| HourStartUTC | DATETIME2(0) |
| MetricUnit | VARCHAR(30) |
| AggregationType | VARCHAR(20) |
| SampleCount | BIGINT |
| MinimumValue | DECIMAL(28,4) |
| MaximumValue | DECIMAL(28,4) |
| AverageValue | DECIMAL(38,6) |
| SumValue | DECIMAL(38,4) |
| FirstCaptureDateUTC | DATETIME2(3) |
| LastCaptureDateUTC | DATETIME2(3) |
| AggregatedDateUTC | DATETIME2(3) |

Composite PK HourStartUTC + InstanceID + ResourceID + MetricDefinitionID + MetricUnit + AggregationType. Averages are sample-based; deltas attributed to capture hour.



---

## 9. Administrative Tables

### 9.1 dbo.MonitoringSettings

| Column | Data Type |
| --- | --- |
| SettingKey | VARCHAR(100) |
| SettingValue | NVARCHAR(4000) |
| SettingDataType | VARCHAR(20) |
| Description | NVARCHAR(1000) |
| ModifiedDateUTC | DATETIME2(3) |

PK SettingKey; validate logical data type before use.

### 9.2 dbo.SchemaVersion

| Column | Data Type |
| --- | --- |
| SchemaVersionID | INT |
| VersionNumber | VARCHAR(20) |
| ScriptName | NVARCHAR(256) |
| AppliedDateUTC | DATETIME2(3) |
| AppliedBy | NVARCHAR(128) |
| Description | NVARCHAR(1000) |

PK SchemaVersionID; unique VersionNumber.

### 9.3 dbo.CheckpointAudit

| Column | Data Type |
| --- | --- |
| CheckpointAuditID | BIGINT |
| CheckpointID | BIGINT |
| InstanceID | INT |
| CollectorID | INT |
| CheckpointKey | VARCHAR(100) |
| ActionType | VARCHAR(20) |
| PreviousNumericCheckpoint | BIGINT |
| PreviousTextCheckpoint | NVARCHAR(4000) |
| PreviousDateCheckpointUTC | DATETIME2(7) |
| PreviousCollectionRunID | BIGINT |
| Reason | NVARCHAR(1000) |
| ActionBy | NVARCHAR(128) |
| ActionDateUTC | DATETIME2(3) |

PK CheckpointAuditID; records previous checkpoint and reset reason.

### 9.4 dbo.RetentionExecutionLog

| Column | Data Type |
| --- | --- |
| RetentionRunID | BIGINT |
| StartDateUTC | DATETIME2(3) |
| EndDateUTC | DATETIME2(3) |
| RunStatus | VARCHAR(20) |
| BatchSize | INT |
| MaximumBatches | INT |
| MaximumRuntimeSeconds | INT |
| CompletedBatches | INT |
| RawMetricRowsDeleted | BIGINT |
| StateMetricRowsDeleted | BIGINT |
| EventMetricRowsDeleted | BIGINT |
| AggregateRowsDeleted | BIGINT |
| CollectionRunRowsDeleted | BIGINT |
| CheckpointAuditRowsDeleted | BIGINT |
| RetentionLogRowsDeleted | BIGINT |
| ErrorNumber | INT |
| ErrorMessage | NVARCHAR(2048) |
| ExecutedBy | NVARCHAR(128) |

PK RetentionRunID; records committed batch counts and outcomes.



---

## 10. Table-Valued Input Type

### dbo.MetricSampleInput

| Column | Data Type | Description |
| --- | --- | --- |
| CaptureDateUTC | DATETIME2(3) | UTC observation timestamp |
| ServerName | NVARCHAR(128) | Source SQL Server identity |
| ModuleID | VARCHAR(10) | Source monitoring module |
| MetricID | VARCHAR(30) | Collector metric identifier |
| Category | VARCHAR(50) | Monitoring category |
| ResourceType | VARCHAR(30) | Resource classification |
| ResourceName | NVARCHAR(256) | Resource identity |
| MetricName | VARCHAR(100) | Metric description |
| MetricValue | DECIMAL(28,4) | Numeric observation |
| MetricUnit | VARCHAR(30) | Measurement unit |
| CollectionStatus | VARCHAR(20) | Collection result status |
| ErrorMessage | NVARCHAR(2048) | Sanitized diagnostic information |
MetricValue and ErrorMessage permit NULL. All other columns are required.

---

## 11. Supporting Index Inventory

| Index | Table |
| --- | --- |
| IX_MI_EnabledInstances | MonitoredInstances |
| IX_IC_NextScheduledRun | InstanceCollectors |
| IX_CR_InstanceCollectorHistory | CollectionRuns |
| IX_CR_UnsuccessfulCollections | CollectionRuns |
| IX_CR_Retention | CollectionRuns |
| IX_MS_ResourceMetricHistory | MetricSamples |
| IX_MS_MetricTimeAnalysis | MetricSamples |
| IX_MS_Retention | MetricSamples |
| IX_LM_MetricDashboard | LatestMetrics |
| IX_MR_ActiveResources | MonitoredResources |
| IX_CPA_InstanceCollectorHistory | CheckpointAudit |
| IX_MER_FirstSeenDate | MetricEventRegistry |
| IX_MHA_ResourceMetricHistory | MetricHourlyAggregates |
| IX_REL_StartDate | RetentionExecutionLog |
| IX_CPA_Retention | CheckpointAudit |
| IX_MS_SampleKindRetention | MetricSamples |
Primary and unique constraint indexes excluded. Benchmark write overhead and query plans.

---

## 12. Collection Integration Workflow

1. Discover eligible assignment
2. Validate configuration and reserve execution
3. Retrieve applicable checkpoint
4. Validate remote identity
5. Execute approved read-only collector
6. Validate output and sanitize diagnostics
7. Begin central ingestion transaction
8. Ingest validated metrics
9. Save applicable checkpoint
10. Finalize collection run
11. Commit transaction
12. Schedule next execution

On failure roll back ingestion, preserve committed checkpoints, record failure and backoff, and dispose of remote connections. Reconcile unknown commit outcomes before retry.

---

## 13. Stored Procedure Integration Reference

- `dbo.usp_CollectionRunStart`
- `dbo.usp_CollectionRunComplete`
- `dbo.usp_CollectionRunRecover`
- `dbo.usp_CollectionHealthSummary`
- `dbo.usp_CollectionCheckpointGet`
- `dbo.usp_CollectionCheckpointSave`
- `dbo.usp_CollectionCheckpointReset`
- `dbo.usp_CollectionCheckpointSummary`
- `dbo.usp_IngestMetricSamples`
- `dbo.usp_AggregateHourlyMetrics`
- `dbo.usp_MetricStorageSummary`
- `dbo.usp_DataRetentionPreview`
- `dbo.usp_ExecuteDataRetention`
- `dbo.usp_DataRetentionSummary`

Administrative resets, recovery and retention require separate authorization.

---

## 14. Monitoring Configuration Inventory

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


---

## 15. Timestamp Standards

All repository timestamps use UTC. CaptureDateUTC is source observation time; InsertedDateUTC and UpdatedDateUTC are central timestamps; IntervalStartUTC is prior counter observation; HourStartUTC is aggregation boundary. Normalize SQL Agent local timestamps using validated source time zone and handle DST ambiguity. Validate clock synchronization.

---

## 16. Proposed Permission Model

| Role | Intended access |
|---|---|
| MonitoringCollectorRole | Approved collection procedures, TVP and limited scheduling/connection metadata |
| MonitoringReportingRole | Approved reporting views |
| MonitoringMaintenanceRole | Approved aggregation and retention procedures and required DMV access |
| MonitoringAdministratorRole | Approved recovery and checkpoint reset |

Script 12 defines grants, not users or memberships. Validate effective permissions and inherited grants; remote collector rights are separate.

---

## 17. Repository Schema Version History

| Version | Script |
| --- | --- |
| 1.0.0 | 02-Create-Monitoring-Tables.sql |
| 1.0.1 | 03-Create-Monitoring-Indexes.sql |
| 1.0.2 | 06-Collection-Logging.sql |
| 1.0.3 | 07-Collection-Checkpoints.sql |
| 1.0.4 | 08-Historical-Metrics.sql |
| 1.0.5 | 09-Data-Retention.sql |
| 1.0.6 | 10-Monitoring-Views.sql |
| 1.0.7 | 11-Register-Metric-Definitions.sql |
| 1.0.8 | 12-Repository-Security.sql |


---

## 18. Repository Capacity Considerations

Measure instance and resource counts, metric frequency, retention, event volume, index overhead, temporary processing and transaction log usage. Benchmark steady-state and maintenance loads on the central host before expansion.

---

## 19. Pending Technical Validation

The canonical issue IDs, status and acceptance criteria are maintained in [Technical-Review.md](Technical-Review.md). All applicable runtime tests and deployment gates remain pending; no issue is closed solely by a prepared patch.

---

## 20. Production Restrictions

No repository DDL on monitored production instances; no automatic session termination, configuration changes, index changes, failover or shrink; no unapproved monitoring or deletion; no public production secrets or evidence. Preserve existing applications.

---

## 21. Related Documentation

- [Module 30](README.md)
- [Validation Checklist](Validation-Checklist.md)
- [Module 26](../26-Data-Collection/)
- [Main Repository](../README.md)

---

## 22. Conclusion

The schema documents the intended development baseline, not an inspected deployed database. Consolidated testing, integration, security and performance validation remain mandatory.

## Integration revision notes

Documentation baseline: uploaded repository snapshot (2), plus subsequently prepared replacement scripts. GitHub commit equivalence must be verified from a fresh snapshot. No new SQL Server execution or compilation evidence was obtained during consolidation.

MetricDefinitions references Collectors through FK_MD_Collector. Historical and hourly reporting add ReportingMetricUnit without replacing MetricUnit. The late-arrival policy rejects aggregate-eligible batches after hour end plus 15 minutes; shared/exclusive maintenance locks coordinate ingestion and maintenance. Atomic verified-hour cleanup replaces partial group deletion. These are prepared code changes, not proven runtime guarantees.
