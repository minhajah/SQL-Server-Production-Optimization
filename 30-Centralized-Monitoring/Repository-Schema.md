# Centralized Monitoring – Repository Schema

## 1. Document Information

| Property | Details |
|---|---|
| Project | SQL Server Production Optimization |
| Module | 30 – Centralized Monitoring |
| Database | DBA_Monitoring |
| Schema Version | 1.0.6 |
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
| LastSuccess
