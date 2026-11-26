/*
============================================================
Project : SQL Server Production Optimization
Module  : 30 - Centralized Monitoring
Script  : 02-Create-Monitoring-Tables.sql
Purpose : Create centralized monitoring repository tables
Type    : Central Repository Deployment
Impact  : Creates tables inside DBA_Monitoring only
Version : 1.0
============================================================

IMPORTANT:

1. Execute ONLY on the approved central monitoring instance.
2. Execute after 01-Create-Monitoring-Database.sql.
3. Do NOT execute on monitored production instances.
4. Existing inventory application will remain unchanged.
5. Deployment is disabled by default.

============================================================
*/

USE [DBA_Monitoring];
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

------------------------------------------------------------
-- SECTION 1: Deployment Configuration
------------------------------------------------------------

DECLARE
    @ApprovedMonitoringServer NVARCHAR(128) =
        N'REPLACE_WITH_APPROVED_SERVER_NAME',

    @AllowDeployment BIT = 0,

    @ActualServer NVARCHAR(128),

    @SchemaVersion VARCHAR(20) = '1.0.0';

SET @ActualServer =
    CONVERT(NVARCHAR(128), SERVERPROPERTY('ServerName'));

------------------------------------------------------------
-- SECTION 2: Deployment Safety Validation
------------------------------------------------------------

IF ISNULL(@AllowDeployment, 0) <> 1
    BEGIN

    THROW 50001,
        'Deployment disabled. Review deployment parameters.',
        1;

END;

IF NULLIF
(
    LTRIM(RTRIM(@ApprovedMonitoringServer)),
    N''
) IS NULL
OR @ApprovedMonitoringServer =
    N'REPLACE_WITH_APPROVED_SERVER_NAME'
BEGIN

    THROW 50002,
        'Approved monitoring server must be configured.',
        1;

END;

IF @ActualServer IS NULL
   OR @ActualServer <> @ApprovedMonitoringServer
BEGIN

    THROW 50003,
        'Connected instance is not the approved monitoring server.',
        1;

END;

IF DB_NAME() <> N'DBA_Monitoring'
BEGIN

    THROW 50004,
        'Incorrect database context.',
        1;

END;

IF ISNULL
(
    TRY_CONVERT
    (
        INT,
        SERVERPROPERTY('ProductMajorVersion')
    ),
    0
) < 15
BEGIN

    THROW 50005,
        'SQL Server 2019 or later is required.',
        1;

END;

IF DATABASEPROPERTYEX
(
    DB_NAME(),
    'Updateability'
) <> 'READ_WRITE'
BEGIN

    THROW 50006,
        'Monitoring database must be writable.',
        1;

END;

IF @@TRANCOUNT <> 0
BEGIN

    THROW 50007,
        'Execute deployment outside an existing transaction.',
        1;

END;

------------------------------------------------------------
-- SECTION 3: Existing Object Protection
------------------------------------------------------------

/*
Do not overwrite an existing or partially deployed schema.
Schema upgrades will be managed through dedicated scripts.
*/

IF EXISTS
(
    SELECT 1

    FROM sys.objects AS O

    INNER JOIN sys.schemas AS S
        ON O.schema_id = S.schema_id

    WHERE S.name = 'dbo'

    AND O.name IN
    (
        'MonitoredInstances',
        'Collectors',
        'InstanceCollectors',
        'MetricDefinitions',
        'MonitoredResources',
        'CollectionRuns',
        'MetricSamples',
        'LatestMetrics',
        'CollectionCheckpoints',
        'MonitoringSettings',
        'SchemaVersion'
    )
)
BEGIN

    THROW 50008,
        'Monitoring objects already exist. Review existing schema before deployment.',
        1;

END;

------------------------------------------------------------
-- SECTION 4: Begin Transactional Schema Deployment
------------------------------------------------------------

BEGIN TRY

    BEGIN TRANSACTION;

    --------------------------------------------------------
    -- TABLE 01: Monitored SQL Server Instances
    --------------------------------------------------------

    CREATE TABLE dbo.MonitoredInstances
    (
        InstanceID INT IDENTITY(1,1) NOT NULL,

        InstanceName NVARCHAR(128) NOT NULL,

        ConnectionTarget NVARCHAR(256) NOT NULL,

        ServerName NVARCHAR(128) NULL,

        Environment VARCHAR(20) NOT NULL,

        SQLVersion NVARCHAR(50) NULL,

        SQLMajorVersion INT NULL,

        SQLEdition NVARCHAR(128) NULL,

        TimeZoneName NVARCHAR(128) NULL,

        AuthenticationType VARCHAR(30) NOT NULL
            CONSTRAINT DF_MI_Authentication
            DEFAULT ('WINDOWS'),

        CredentialReference NVARCHAR(256) NULL,

        ConnectionTimeoutSeconds INT NOT NULL
            CONSTRAINT DF_MI_ConnectionTimeout
            DEFAULT (15),

        IsEnabled BIT NOT NULL
            CONSTRAINT DF_MI_IsEnabled
            DEFAULT (0),

        IsPilotInstance BIT NOT NULL
            CONSTRAINT DF_MI_IsPilot
            DEFAULT (0),

        CreatedDateUTC DATETIME2(3) NOT NULL
            CONSTRAINT DF_MI_CreatedDate
            DEFAULT (SYSUTCDATETIME()),

        ModifiedDateUTC DATETIME2(3) NULL,

        Notes NVARCHAR(1000) NULL,

        CONSTRAINT PK_MonitoredInstances
            PRIMARY KEY CLUSTERED (InstanceID),

        CONSTRAINT UQ_MI_InstanceName
            UNIQUE (InstanceName),

        CONSTRAINT UQ_MI_ConnectionTarget
            UNIQUE (ConnectionTarget),

        CONSTRAINT CK_MI_Environment
            CHECK
            (
                Environment IN
                (
                    'PRODUCTION',
                    'DR',
                    'UAT',
                    'TEST',
                    'DEVELOPMENT'
                )
            ),

        CONSTRAINT CK_MI_Authentication
            CHECK
            (
                AuthenticationType IN
                (
                    'WINDOWS',
                    'SQL'
                )
            ),

        CONSTRAINT CK_MI_ConnectionTimeout
            CHECK
            (
                ConnectionTimeoutSeconds
                    BETWEEN 1 AND 300
            )
    );

    --------------------------------------------------------
    -- TABLE 02: Collector Configuration
    --------------------------------------------------------

    CREATE TABLE dbo.Collectors
    (
        CollectorID INT IDENTITY(1,1) NOT NULL,

        CollectorCode VARCHAR(30) NOT NULL,

        ModuleID VARCHAR(10) NOT NULL
            CONSTRAINT DF_COL_ModuleID
            DEFAULT ('26'),

        CollectorName NVARCHAR(128) NOT NULL,

        ScriptFileName NVARCHAR(256) NOT NULL,

        ScriptVersion VARCHAR(20) NOT NULL
            CONSTRAINT DF_COL_ScriptVersion
            DEFAULT ('1.0.0'),

        CollectionType VARCHAR(20) NOT NULL
            CONSTRAINT DF_COL_CollectionType
            DEFAULT ('SNAPSHOT'),

        DefaultIntervalSeconds INT NOT NULL,

        DefaultTimeoutSeconds INT NOT NULL,

        MinimumSQLMajorVersion INT NOT NULL
            CONSTRAINT DF_COL_MinimumVersion
            DEFAULT (15),

        MaximumOutputRows INT NOT NULL
            CONSTRAINT DF_COL_MaximumRows
            DEFAULT (10000),

        ExecutionPriority INT NOT NULL
            CONSTRAINT DF_COL_Priority
            DEFAULT (50),

        IsEnabled BIT NOT NULL
            CONSTRAINT DF_COL_IsEnabled
            DEFAULT (0),

        CreatedDateUTC DATETIME2(3) NOT NULL
            CONSTRAINT DF_COL_CreatedDate
            DEFAULT (SYSUTCDATETIME()),

        ModifiedDateUTC DATETIME2(3) NULL,

        Description NVARCHAR(1000) NULL,

        CONSTRAINT PK_Collectors
            PRIMARY KEY CLUSTERED (CollectorID),

        CONSTRAINT UQ_COL_CollectorCode
            UNIQUE (CollectorCode),

        CONSTRAINT UQ_COL_ScriptFileName
            UNIQUE (ScriptFileName),

        CONSTRAINT CK_COL_CollectionType
            CHECK
            (
                CollectionType IN
                (
                    'SNAPSHOT',
                    'CUMULATIVE',
                    'INCREMENTAL'
                )
            ),

        CONSTRAINT CK_COL_Interval
            CHECK (DefaultIntervalSeconds > 0),

        CONSTRAINT CK_COL_Timeout
            CHECK (DefaultTimeoutSeconds > 0),

        CONSTRAINT CK_COL_MaximumRows
            CHECK (MaximumOutputRows > 0),

        CONSTRAINT CK_COL_Priority
            CHECK (ExecutionPriority BETWEEN 1 AND 100)
    );

    --------------------------------------------------------
    -- TABLE 03: Instance-Specific Collector Configuration
    --------------------------------------------------------

    CREATE TABLE dbo.InstanceCollectors
    (
        InstanceID INT NOT NULL,

        CollectorID INT NOT NULL,

        IntervalOverrideSeconds INT NULL,

        TimeoutOverrideSeconds INT NULL,

        IsEnabled BIT NOT NULL
            CONSTRAINT DF_IC_IsEnabled
            DEFAULT (0),

        NextRunDateUTC DATETIME2(3) NULL,

        LastAttemptDateUTC DATETIME2(3) NULL,

        LastSuccessDateUTC DATETIME2(3) NULL,

        ConsecutiveFailures INT NOT NULL
            CONSTRAINT DF_IC_Failures
            DEFAULT (0),

        CreatedDateUTC DATETIME2(3) NOT NULL
            CONSTRAINT DF_IC_CreatedDate
            DEFAULT (SYSUTCDATETIME()),

        ModifiedDateUTC DATETIME2(3) NULL,

        CONSTRAINT PK_InstanceCollectors
            PRIMARY KEY CLUSTERED
            (
                InstanceID,
                CollectorID
            ),

        CONSTRAINT FK_IC_Instance
            FOREIGN KEY (InstanceID)
            REFERENCES dbo.MonitoredInstances
            (InstanceID),

        CONSTRAINT FK_IC_Collector
            FOREIGN KEY (CollectorID)
            REFERENCES dbo.Collectors
            (CollectorID),

        CONSTRAINT CK_IC_Interval
            CHECK (IntervalOverrideSeconds > 0),

        CONSTRAINT CK_IC_Timeout
            CHECK (TimeoutOverrideSeconds > 0),

        CONSTRAINT CK_IC_Failures
            CHECK (ConsecutiveFailures >= 0)
    );

    --------------------------------------------------------
    -- TABLE 04: Metric Definitions
    --------------------------------------------------------

    CREATE TABLE dbo.MetricDefinitions
    (
        MetricDefinitionID INT IDENTITY(1,1) NOT NULL,

        CollectorID INT NOT NULL,

        MetricID VARCHAR(30) NOT NULL,

        MetricName NVARCHAR(100) NOT NULL,

        Category VARCHAR(50) NOT NULL,

        ResourceType VARCHAR(30) NOT NULL,

        DefaultMetricUnit VARCHAR(30) NOT NULL,

        MetricBehavior VARCHAR(20) NOT NULL,

        StoragePolicy VARCHAR(30) NOT NULL
            CONSTRAINT DF_MD_StoragePolicy
            DEFAULT ('RAW'),

        IsEnabled BIT NOT NULL
            CONSTRAINT DF_MD_IsEnabled
            DEFAULT (1),

        CreatedDateUTC DATETIME2(3) NOT NULL
            CONSTRAINT DF_MD_CreatedDate
            DEFAULT (SYSUTCDATETIME()),

        Description NVARCHAR(1000) NULL,

        CONSTRAINT PK_MetricDefinitions
            PRIMARY KEY CLUSTERED
            (MetricDefinitionID),

        CONSTRAINT UQ_MD_CollectorMetric
            UNIQUE (CollectorID, MetricID),

        CONSTRAINT FK_MD_Collector
            FOREIGN KEY (CollectorID)
            REFERENCES dbo.Collectors (CollectorID),

        CONSTRAINT CK_MD_MetricBehavior
            CHECK
            (
                MetricBehavior IN
                (
                    'GAUGE',
                    'COUNTER',
                    'STATE',
                    'IDENTIFIER',
                    'EVENT',
                    'TIMESTAMP'
                )
            ),

        CONSTRAINT CK_MD_StoragePolicy
            CHECK
            (
                StoragePolicy IN
                (
                    'RAW',
                    'ON_CHANGE',
                    'DELTA',
                    'LATEST_ONLY',
                    'EVENT_ONLY'
                )
            )
    );

    --------------------------------------------------------
    -- TABLE 05: Monitored Resources
    --------------------------------------------------------

    CREATE TABLE dbo.MonitoredResources
    (
        ResourceID BIGINT IDENTITY(1,1) NOT NULL,

        InstanceID INT NOT NULL,

        ResourceType VARCHAR(30) NOT NULL,

        ResourceName NVARCHAR(256)
            COLLATE Latin1_General_100_BIN2 NOT NULL,

        DisplayName NVARCHAR(256) NULL,

        FirstSeenDateUTC DATETIME2(3) NOT NULL
            CONSTRAINT DF_MR_FirstSeen
            DEFAULT (SYSUTCDATETIME()),

        LastSeenDateUTC DATETIME2(3) NOT NULL
            CONSTRAINT DF_MR_LastSeen
            DEFAULT (SYSUTCDATETIME()),

        IsActive BIT NOT NULL
            CONSTRAINT DF_MR_IsActive
            DEFAULT (1),

        CONSTRAINT PK_MonitoredResources
            PRIMARY KEY CLUSTERED (ResourceID),

        CONSTRAINT UQ_MR_InstanceResource
            UNIQUE
            (
                InstanceID,
                ResourceType,
                ResourceName
            ),

        CONSTRAINT UQ_MR_InstanceResourceID
            UNIQUE (InstanceID, ResourceID),

        CONSTRAINT FK_MR_Instance
            FOREIGN KEY (InstanceID)
            REFERENCES dbo.MonitoredInstances
            (InstanceID)
    );

    --------------------------------------------------------
    -- TABLE 06: Collection Execution History
    --------------------------------------------------------

    CREATE TABLE dbo.CollectionRuns
    (
        CollectionRunID BIGINT IDENTITY(1,1) NOT NULL,

        RunToken UNIQUEIDENTIFIER NOT NULL
            CONSTRAINT DF_CR_RunToken
            DEFAULT (NEWID()),

        InstanceID INT NOT NULL,

        CollectorID INT NOT NULL,

        StartDateUTC DATETIME2(3) NOT NULL
            CONSTRAINT DF_CR_StartDate
            DEFAULT (SYSUTCDATETIME()),

        EndDateUTC DATETIME2(3) NULL,

        DurationMilliseconds BIGINT NULL,

        RunStatus VARCHAR(20) NOT NULL
            CONSTRAINT DF_CR_RunStatus
            DEFAULT ('RUNNING'),

        RowsReturned BIGINT NOT NULL
            CONSTRAINT DF_CR_RowsReturned
            DEFAULT (0),

        RowsStored BIGINT NOT NULL
            CONSTRAINT DF_CR_RowsStored
            DEFAULT (0),

        ErrorNumber INT NULL,

        ErrorMessage NVARCHAR(2048) NULL,

        CollectorVersion VARCHAR(20) NULL,

        CONSTRAINT PK_CollectionRuns
            PRIMARY KEY CLUSTERED
            (CollectionRunID),

        CONSTRAINT UQ_CR_RunToken
            UNIQUE (RunToken),

        CONSTRAINT UQ_CR_RunInstance
            UNIQUE (CollectionRunID, InstanceID),

        CONSTRAINT FK_CR_InstanceCollector
            FOREIGN KEY
            (
                InstanceID,
                CollectorID
            )
            REFERENCES dbo.InstanceCollectors
            (
                InstanceID,
                CollectorID
            ),

        CONSTRAINT CK_CR_RunStatus
            CHECK
            (
                RunStatus IN
                (
                    'RUNNING',
                    'SUCCESS',
                    'PARTIAL',
                    'FAILED',
                    'TIMEOUT',
                    'SKIPPED',
                    'CANCELLED'
                )
            ),

        CONSTRAINT CK_CR_Duration
            CHECK (DurationMilliseconds >= 0),

        CONSTRAINT CK_CR_RowCounts
            CHECK
            (
                RowsReturned >= 0
                AND RowsStored >= 0
            ),

        CONSTRAINT CK_CR_EndDate
            CHECK
            (
                EndDateUTC IS NULL
                OR EndDateUTC >= StartDateUTC
            )
    );

    --------------------------------------------------------
    -- TABLE 07: Historical Metric Samples
    --------------------------------------------------------

    CREATE TABLE dbo.MetricSamples
    (
        SampleID BIGINT IDENTITY(1,1) NOT NULL,

        CollectionRunID BIGINT NOT NULL,

        InstanceID INT NOT NULL,

        ResourceID BIGINT NOT NULL,

        MetricDefinitionID INT NOT NULL,

        CaptureDateUTC DATETIME2(3) NOT NULL,

        MetricValue DECIMAL(28,4) NULL,

        MetricUnit VARCHAR(30) NOT NULL,

        CollectionStatus VARCHAR(20) NOT NULL,

        ErrorMessage NVARCHAR(2048) NULL,

        InsertedDateUTC DATETIME2(3) NOT NULL
            CONSTRAINT DF_MS_InsertedDate
            DEFAULT (SYSUTCDATETIME()),

        CONSTRAINT PK_MetricSamples
            PRIMARY KEY CLUSTERED (SampleID),

        CONSTRAINT UQ_MS_RunResourceMetric
            UNIQUE
            (
                CollectionRunID,
                ResourceID,
                MetricDefinitionID
            ),

        CONSTRAINT FK_MS_CollectionRun
            FOREIGN KEY
            (
                CollectionRunID,
                InstanceID
            )
            REFERENCES dbo.CollectionRuns
            (
                CollectionRunID,
                InstanceID
            ),

        CONSTRAINT FK_MS_Resource
            FOREIGN KEY
            (
                InstanceID,
                ResourceID
            )
            REFERENCES dbo.MonitoredResources
            (
                InstanceID,
                ResourceID
            ),

        CONSTRAINT FK_MS_MetricDefinition
            FOREIGN KEY (MetricDefinitionID)
            REFERENCES dbo.MetricDefinitions
            (MetricDefinitionID),

        CONSTRAINT CK_MS_CollectionStatus
            CHECK
            (
                CollectionStatus IN
                (
                    'SUCCESS',
                    'UNKNOWN',
                    'FAILED',
                    'STALE',
                    'NOT APPLICABLE'
                )
            )
    );

    --------------------------------------------------------
    -- TABLE 08: Latest Metric Values
    --------------------------------------------------------

    CREATE TABLE dbo.LatestMetrics
    (
        InstanceID INT NOT NULL,

        ResourceID BIGINT NOT NULL,

        MetricDefinitionID INT NOT NULL,

        CollectionRunID BIGINT NOT NULL,

        CaptureDateUTC DATETIME2(3) NOT NULL,

        MetricValue DECIMAL(28,4) NULL,

        MetricUnit VARCHAR(30) NOT NULL,

        CollectionStatus VARCHAR(20) NOT NULL,

        ErrorMessage NVARCHAR(2048) NULL,

        LastSuccessfulCaptureUTC DATETIME2(3) NULL,

        LastSuccessfulValue DECIMAL(28,4) NULL,

        LastSuccessfulUnit VARCHAR(30) NULL,

        UpdatedDateUTC DATETIME2(3) NOT NULL
            CONSTRAINT DF_LM_UpdatedDate
            DEFAULT (SYSUTCDATETIME()),

        CONSTRAINT PK_LatestMetrics
            PRIMARY KEY CLUSTERED
            (
                InstanceID,
                ResourceID,
                MetricDefinitionID
            ),

        CONSTRAINT FK_LM_Resource
            FOREIGN KEY
            (
                InstanceID,
                ResourceID
            )
            REFERENCES dbo.MonitoredResources
            (
                InstanceID,
                ResourceID
            ),

        CONSTRAINT FK_LM_MetricDefinition
            FOREIGN KEY (MetricDefinitionID)
            REFERENCES dbo.MetricDefinitions
            (MetricDefinitionID),

        CONSTRAINT CK_LM_CollectionStatus
            CHECK
            (
                CollectionStatus IN
                (
                    'SUCCESS',
                    'UNKNOWN',
                    'FAILED',
                    'STALE',
                    'NOT APPLICABLE'
                )
            )
    );

    --------------------------------------------------------
    -- TABLE 09: Incremental Collection Checkpoints
    --------------------------------------------------------

    CREATE TABLE dbo.CollectionCheckpoints
    (
        CheckpointID BIGINT IDENTITY(1,1) NOT NULL,

        InstanceID INT NOT NULL,

        CollectorID INT NOT NULL,

        CheckpointKey VARCHAR(100) NOT NULL,

        NumericCheckpoint BIGINT NULL,

        TextCheckpoint NVARCHAR(4000) NULL,

        DateCheckpointUTC DATETIME2(7) NULL,

        LastSuccessDateUTC DATETIME2(3) NULL,

        LastCollectionRunID BIGINT NULL,

        UpdatedDateUTC DATETIME2(3) NOT NULL
            CONSTRAINT DF_CP_UpdatedDate
            DEFAULT (SYSUTCDATETIME()),

        RowVersion ROWVERSION NOT NULL,

        CONSTRAINT PK_CollectionCheckpoints
            PRIMARY KEY CLUSTERED (CheckpointID),

        CONSTRAINT UQ_CP_InstanceCollectorKey
            UNIQUE
            (
                InstanceID,
                CollectorID,
                CheckpointKey
            ),

        CONSTRAINT FK_CP_InstanceCollector
            FOREIGN KEY
            (
                InstanceID,
                CollectorID
            )
            REFERENCES dbo.InstanceCollectors
            (
                InstanceID,
                CollectorID
            )
    );

    --------------------------------------------------------
    -- TABLE 10: Global Monitoring Configuration
    --------------------------------------------------------

    CREATE TABLE dbo.MonitoringSettings
    (
        SettingKey VARCHAR(100) NOT NULL,

        SettingValue NVARCHAR(4000) NOT NULL,

        SettingDataType VARCHAR(20) NOT NULL,

        Description NVARCHAR(1000) NULL,

        ModifiedDateUTC DATETIME2(3) NOT NULL
            CONSTRAINT DF_MSET_ModifiedDate
            DEFAULT (SYSUTCDATETIME()),

        CONSTRAINT PK_MonitoringSettings
            PRIMARY KEY CLUSTERED (SettingKey),

        CONSTRAINT CK_MSET_DataType
            CHECK
            (
                SettingDataType IN
                (
                    'STRING',
                    'INTEGER',
                    'DECIMAL',
                    'BOOLEAN',
                    'JSON'
                )
            )
    );

    --------------------------------------------------------
    -- TABLE 11: Repository Schema Version
    --------------------------------------------------------

    CREATE TABLE dbo.SchemaVersion
    (
        SchemaVersionID INT IDENTITY(1,1) NOT NULL,

        VersionNumber VARCHAR(20) NOT NULL,

        ScriptName NVARCHAR(256) NOT NULL,

        AppliedDateUTC DATETIME2(3) NOT NULL
            CONSTRAINT DF_SV_AppliedDate
            DEFAULT (SYSUTCDATETIME()),

        AppliedBy NVARCHAR(128) NOT NULL,

        Description NVARCHAR(1000) NULL,

        CONSTRAINT PK_SchemaVersion
            PRIMARY KEY CLUSTERED
            (SchemaVersionID),

        CONSTRAINT UQ_SV_VersionNumber
            UNIQUE (VersionNumber)
    );

    --------------------------------------------------------
    -- SECTION 5: Register Repository Schema Version
    --------------------------------------------------------

    INSERT INTO dbo.SchemaVersion
    (
        VersionNumber,
        ScriptName,
        AppliedBy,
        Description
    )
    VALUES
    (
        @SchemaVersion,
        N'02-Create-Monitoring-Tables.sql',
        ORIGINAL_LOGIN(),
        N'Initial centralized monitoring repository schema.'
    );

    --------------------------------------------------------
    -- SECTION 6: Initial Safety Configuration
    --------------------------------------------------------

    INSERT INTO dbo.MonitoringSettings
    (
        SettingKey,
        SettingValue,
        SettingDataType,
        Description
    )
    VALUES
    (
        'MonitoringEnabled',
        N'0',
        'BOOLEAN',
        N'Global monitoring service execution switch.'
    ),
    (
        'ProductionCollectionEnabled',
        N'0',
        'BOOLEAN',
        N'Permit collection from production instances.'
    ),
    (
        'AlertingEnabled',
        N'0',
        'BOOLEAN',
        N'Permit monitoring alert notifications.'
    ),
    (
        'EmailReportingEnabled',
        N'0',
        'BOOLEAN',
        N'Permit automated email reporting.'
    ),
    (
        'PilotModeEnabled',
        N'1',
        'BOOLEAN',
        N'Restrict collection to approved pilot instances.'
    ),
    (
        'MaximumConcurrentConnections',
        N'2',
        'INTEGER',
        N'Initial proposed global collection concurrency.'
    ),
    (
        'MaximumCollectorsPerInstance',
        N'1',
        'INTEGER',
        N'Maximum simultaneous collectors per instance.'
    ),
    (
        'DataRetentionEnabled',
        N'0',
        'BOOLEAN',
        N'Permit automated historical data cleanup.'
    ),
    (
        'RawMetricRetentionDays',
        N'7',
        'INTEGER',
        N'Proposed raw metric retention period.'
    ),
    (
        'CollectionRunRetentionDays',
        N'30',
        'INTEGER',
        N'Proposed collection execution history retention.'
    );

    --------------------------------------------------------
    -- SECTION 7: Commit Schema Deployment
    --------------------------------------------------------

    COMMIT TRANSACTION;

    SELECT
        @ActualServer AS ServerName,
        DB_NAME() AS DatabaseName,
        @SchemaVersion AS SchemaVersion,
        'SUCCESS' AS DeploymentStatus,
        11 AS MonitoringTablesCreated,
        SYSUTCDATETIME() AS DeploymentDateUTC;

END TRY

BEGIN CATCH

    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    SELECT
        @ActualServer AS ServerName,
        DB_NAME() AS DatabaseName,
        'FAILED' AS DeploymentStatus,
        ERROR_NUMBER() AS ErrorNumber,
        ERROR_LINE() AS ErrorLine,
        ERROR_MESSAGE() AS ErrorMessage,
        SYSUTCDATETIME() AS ErrorDateUTC;

    THROW;

END CATCH;

------------------------------------------------------------
-- SECTION 8: Monitoring Table Verification
------------------------------------------------------------

SELECT
    S.name AS SchemaName,
    T.name AS TableName,
    T.create_date AS CreatedDate,
    T.modify_date AS ModifiedDate

FROM sys.tables AS T

INNER JOIN sys.schemas AS S
    ON T.schema_id = S.schema_id

WHERE S.name = 'dbo'

AND T.name IN
(
    'MonitoredInstances',
    'Collectors',
    'InstanceCollectors',
    'MetricDefinitions',
    'MonitoredResources',
    'CollectionRuns',
    'MetricSamples',
    'LatestMetrics',
    'CollectionCheckpoints',
    'MonitoringSettings',
    'SchemaVersion'
)

ORDER BY T.name;

------------------------------------------------------------
-- SECTION 9: Monitoring Configuration Verification
------------------------------------------------------------

SELECT
    SettingKey,
    SettingValue,
    SettingDataType,
    Description

FROM dbo.MonitoringSettings

ORDER BY SettingKey;

GO
