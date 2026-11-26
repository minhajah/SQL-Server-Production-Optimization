/*
============================================================
Project : SQL Server Production Optimization
Module  : 30 - Centralized Monitoring
Script  : 03-Create-Monitoring-Indexes.sql
Purpose : Create supporting monitoring repository indexes
Type    : Central Repository Deployment
Impact  : Index creation inside DBA_Monitoring only
Version : 1.0
============================================================

IMPORTANT:

1. Execute ONLY on the approved central monitoring instance.
2. Execute after 02-Create-Monitoring-Tables.sql.
3. Do NOT execute on monitored production instances.
4. Existing inventory application will remain unchanged.
5. Deployment is disabled by default.
6. Existing indexes will not be dropped or rebuilt.

============================================================
*/

USE [DBA_Monitoring];
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

-- Required SET options for filtered indexes
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON;
SET NUMERIC_ROUNDABORT OFF;

------------------------------------------------------------
-- SECTION 1: Deployment Configuration
------------------------------------------------------------

DECLARE
    @ApprovedMonitoringServer NVARCHAR(128) =
        N'REPLACE_WITH_APPROVED_SERVER_NAME',

    @AllowDeployment BIT = 0,

    @ActualServer NVARCHAR(128),

    @DeploymentStart DATETIME2(3) =
        SYSUTCDATETIME(),

    @IndexesCreated INT = 0,

    @IndexesSkipped INT = 0;

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
-- SECTION 3: Required Table Validation
------------------------------------------------------------

IF OBJECT_ID('dbo.MonitoredInstances', 'U') IS NULL
OR OBJECT_ID('dbo.InstanceCollectors', 'U') IS NULL
OR OBJECT_ID('dbo.CollectionRuns', 'U') IS NULL
OR OBJECT_ID('dbo.MetricSamples', 'U') IS NULL
OR OBJECT_ID('dbo.LatestMetrics', 'U') IS NULL
OR OBJECT_ID('dbo.MonitoredResources', 'U') IS NULL
OR OBJECT_ID('dbo.MonitoringSettings', 'U') IS NULL
OR OBJECT_ID('dbo.SchemaVersion', 'U') IS NULL
BEGIN

    THROW 50008,
        'Required monitoring tables are missing.',
        1;

END;

IF NOT EXISTS
(
    SELECT 1

    FROM dbo.SchemaVersion

    WHERE VersionNumber = '1.0.0'

      AND ScriptName =
          N'02-Create-Monitoring-Tables.sql'
)
BEGIN

    THROW 50009,
        'Required repository schema version not found.',
        1;

END;

------------------------------------------------------------
-- SECTION 4: Monitoring Service Safety Validation
------------------------------------------------------------

IF NOT EXISTS
(
    SELECT 1

    FROM dbo.MonitoringSettings

    WHERE SettingKey = 'MonitoringEnabled'
      AND SettingValue = N'0'
)
BEGIN

    THROW 50010,
        'Monitoring must be disabled before index deployment.',
        1;

END;

IF EXISTS
(
    SELECT 1

    FROM dbo.CollectionRuns

    WHERE RunStatus = 'RUNNING'
)
BEGIN

    THROW 50011,
        'Active collection runs exist. Review before index deployment.',
        1;

END;

------------------------------------------------------------
-- SECTION 5: Index Deployment Tracking
------------------------------------------------------------

DECLARE @DeploymentResults TABLE
(
    TableName SYSNAME,
    IndexName SYSNAME,
    DeploymentStatus VARCHAR(30),
    Details NVARCHAR(2048)
);

------------------------------------------------------------
-- SECTION 6: Index Creation
------------------------------------------------------------

BEGIN TRY

    BEGIN TRANSACTION;

    --------------------------------------------------------
    -- INDEX 01: Enabled Monitoring Instances
    --------------------------------------------------------

    IF NOT EXISTS
    (
        SELECT 1

        FROM sys.indexes

        WHERE object_id =
            OBJECT_ID('dbo.MonitoredInstances')

          AND name =
            'IX_MI_EnabledInstances'
    )
    BEGIN

        CREATE NONCLUSTERED INDEX
            IX_MI_EnabledInstances

        ON dbo.MonitoredInstances
        (
            IsPilotInstance,
            Environment,
            InstanceID
        )

        INCLUDE
        (
            ConnectionTarget,
            AuthenticationType,
            CredentialReference,
            ConnectionTimeoutSeconds,
            SQLMajorVersion
        )

        WHERE IsEnabled = 1

        WITH (MAXDOP = 1);

        SET @IndexesCreated += 1;

        INSERT INTO @DeploymentResults
        VALUES
        (
            'MonitoredInstances',
            'IX_MI_EnabledInstances',
            'CREATED',
            NULL
        );

    END

    ELSE
    BEGIN

        SET @IndexesSkipped += 1;

        INSERT INTO @DeploymentResults
        VALUES
        (
            'MonitoredInstances',
            'IX_MI_EnabledInstances',
            'ALREADY EXISTS',
            'Existing index preserved.'
        );

    END;

    --------------------------------------------------------
    -- INDEX 02: Collector Scheduling
    --------------------------------------------------------

    IF NOT EXISTS
    (
        SELECT 1

        FROM sys.indexes

        WHERE object_id =
            OBJECT_ID('dbo.InstanceCollectors')

          AND name =
            'IX_IC_NextScheduledRun'
    )
    BEGIN

        CREATE NONCLUSTERED INDEX
            IX_IC_NextScheduledRun

        ON dbo.InstanceCollectors
        (
            NextRunDateUTC,
            InstanceID,
            CollectorID
        )

        INCLUDE
        (
            IntervalOverrideSeconds,
            TimeoutOverrideSeconds,
            LastAttemptDateUTC,
            LastSuccessDateUTC,
            ConsecutiveFailures
        )

        WHERE IsEnabled = 1

        WITH (MAXDOP = 1);

        SET @IndexesCreated += 1;

        INSERT INTO @DeploymentResults
        VALUES
        (
            'InstanceCollectors',
            'IX_IC_NextScheduledRun',
            'CREATED',
            NULL
        );

    END

    ELSE
    BEGIN

        SET @IndexesSkipped += 1;

        INSERT INTO @DeploymentResults
        VALUES
        (
            'InstanceCollectors',
            'IX_IC_NextScheduledRun',
            'ALREADY EXISTS',
            'Existing index preserved.'
        );

    END;

    --------------------------------------------------------
    -- INDEX 03: Instance Collection History
    --------------------------------------------------------

    IF NOT EXISTS
    (
        SELECT 1

        FROM sys.indexes

        WHERE object_id =
            OBJECT_ID('dbo.CollectionRuns')

          AND name =
            'IX_CR_InstanceCollectorHistory'
    )
    BEGIN

        CREATE NONCLUSTERED INDEX
            IX_CR_InstanceCollectorHistory

        ON dbo.CollectionRuns
        (
            InstanceID,
            CollectorID,
            StartDateUTC DESC
        )

        INCLUDE
        (
            EndDateUTC,
            RunStatus,
            DurationMilliseconds,
            RowsReturned,
            RowsStored,
            ErrorNumber
        )

        WITH (MAXDOP = 1);

        SET @IndexesCreated += 1;

        INSERT INTO @DeploymentResults
        VALUES
        (
            'CollectionRuns',
            'IX_CR_InstanceCollectorHistory',
            'CREATED',
            NULL
        );

    END

    ELSE
    BEGIN

        SET @IndexesSkipped += 1;

        INSERT INTO @DeploymentResults
        VALUES
        (
            'CollectionRuns',
            'IX_CR_InstanceCollectorHistory',
            'ALREADY EXISTS',
            'Existing index preserved.'
        );

    END;

    --------------------------------------------------------
    -- INDEX 04: Unsuccessful Collection Investigation
    --------------------------------------------------------

    IF NOT EXISTS
    (
        SELECT 1

        FROM sys.indexes

        WHERE object_id =
            OBJECT_ID('dbo.CollectionRuns')

          AND name =
            'IX_CR_UnsuccessfulCollections'
    )
    BEGIN

        CREATE NONCLUSTERED INDEX
            IX_CR_UnsuccessfulCollections

        ON dbo.CollectionRuns
        (
            StartDateUTC DESC,
            InstanceID,
            CollectorID
        )

        INCLUDE
        (
            RunStatus,
            DurationMilliseconds,
            ErrorNumber
        )

        WHERE RunStatus IN
        (
            'FAILED',
            'TIMEOUT',
            'PARTIAL',
            'CANCELLED'
        )

        WITH (MAXDOP = 1);

        SET @IndexesCreated += 1;

        INSERT INTO @DeploymentResults
        VALUES
        (
            'CollectionRuns',
            'IX_CR_UnsuccessfulCollections',
            'CREATED',
            NULL
        );

    END

    ELSE
    BEGIN

        SET @IndexesSkipped += 1;

        INSERT INTO @DeploymentResults
        VALUES
        (
            'CollectionRuns',
            'IX_CR_UnsuccessfulCollections',
            'ALREADY EXISTS',
            'Existing index preserved.'
        );

    END;

    --------------------------------------------------------
    -- INDEX 05: Collection History Retention
    --------------------------------------------------------

    IF NOT EXISTS
    (
        SELECT 1

        FROM sys.indexes

        WHERE object_id =
            OBJECT_ID('dbo.CollectionRuns')

          AND name =
            'IX_CR_Retention'
    )
    BEGIN

        CREATE NONCLUSTERED INDEX
            IX_CR_Retention

        ON dbo.CollectionRuns
        (
            EndDateUTC,
            CollectionRunID
        )

        INCLUDE
        (
            RunStatus
        )

        WHERE EndDateUTC IS NOT NULL

        WITH (MAXDOP = 1);

        SET @IndexesCreated += 1;

        INSERT INTO @DeploymentResults
        VALUES
        (
            'CollectionRuns',
            'IX_CR_Retention',
            'CREATED',
            NULL
        );

    END

    ELSE
    BEGIN

        SET @IndexesSkipped += 1;

        INSERT INTO @DeploymentResults
        VALUES
        (
            'CollectionRuns',
            'IX_CR_Retention',
            'ALREADY EXISTS',
            'Existing index preserved.'
        );

    END;

    --------------------------------------------------------
    -- INDEX 06: Historical Resource Metric Retrieval
    --------------------------------------------------------

    IF NOT EXISTS
    (
        SELECT 1

        FROM sys.indexes

        WHERE object_id =
            OBJECT_ID('dbo.MetricSamples')

          AND name =
            'IX_MS_ResourceMetricHistory'
    )
    BEGIN

        CREATE NONCLUSTERED INDEX
            IX_MS_ResourceMetricHistory

        ON dbo.MetricSamples
        (
            InstanceID,
            ResourceID,
            MetricDefinitionID,
            CaptureDateUTC DESC
        )

        INCLUDE
        (
            MetricValue,
            MetricUnit,
            CollectionStatus
        )

        WITH (MAXDOP = 1);

        SET @IndexesCreated += 1;

        INSERT INTO @DeploymentResults
        VALUES
        (
            'MetricSamples',
            'IX_MS_ResourceMetricHistory',
            'CREATED',
            NULL
        );

    END

    ELSE
    BEGIN

        SET @IndexesSkipped += 1;

        INSERT INTO @DeploymentResults
        VALUES
        (
            'MetricSamples',
            'IX_MS_ResourceMetricHistory',
            'ALREADY EXISTS',
            'Existing index preserved.'
        );

    END;

    --------------------------------------------------------
    -- INDEX 07: Cross-Instance Metric Analysis
    --------------------------------------------------------

    IF NOT EXISTS
    (
        SELECT 1

        FROM sys.indexes

        WHERE object_id =
            OBJECT_ID('dbo.MetricSamples')

          AND name =
            'IX_MS_MetricTimeAnalysis'
    )
    BEGIN

        CREATE NONCLUSTERED INDEX
            IX_MS_MetricTimeAnalysis

        ON dbo.MetricSamples
        (
            MetricDefinitionID,
            CaptureDateUTC DESC,
            InstanceID,
            ResourceID
        )

        INCLUDE
        (
            MetricValue,
            MetricUnit
        )

        WHERE CollectionStatus = 'SUCCESS'

        WITH (MAXDOP = 1);

        SET @IndexesCreated += 1;

        INSERT INTO @DeploymentResults
        VALUES
        (
            'MetricSamples',
            'IX_MS_MetricTimeAnalysis',
            'CREATED',
            NULL
        );

    END

    ELSE
    BEGIN

        SET @IndexesSkipped += 1;

        INSERT INTO @DeploymentResults
        VALUES
        (
            'MetricSamples',
            'IX_MS_MetricTimeAnalysis',
            'ALREADY EXISTS',
            'Existing index preserved.'
        );

    END;

    --------------------------------------------------------
    -- INDEX 08: Historical Metric Retention
    --------------------------------------------------------

    IF NOT EXISTS
    (
        SELECT 1

        FROM sys.indexes

        WHERE object_id =
            OBJECT_ID('dbo.MetricSamples')

          AND name =
            'IX_MS_Retention'
    )
    BEGIN

        CREATE NONCLUSTERED INDEX
            IX_MS_Retention

        ON dbo.MetricSamples
        (
            CaptureDateUTC,
            SampleID
        )

        WITH (MAXDOP = 1);

        SET @IndexesCreated += 1;

        INSERT INTO @DeploymentResults
        VALUES
        (
            'MetricSamples',
            'IX_MS_Retention',
            'CREATED',
            NULL
        );

    END

    ELSE
    BEGIN

        SET @IndexesSkipped += 1;

        INSERT INTO @DeploymentResults
        VALUES
        (
            'MetricSamples',
            'IX_MS_Retention',
            'ALREADY EXISTS',
            'Existing index preserved.'
        );

    END;

    --------------------------------------------------------
    -- INDEX 09: Current Metric Dashboard
    --------------------------------------------------------

    IF NOT EXISTS
    (
        SELECT 1

        FROM sys.indexes

        WHERE object_id =
            OBJECT_ID('dbo.LatestMetrics')

          AND name =
            'IX_LM_MetricDashboard'
    )
    BEGIN

        CREATE NONCLUSTERED INDEX
            IX_LM_MetricDashboard

        ON dbo.LatestMetrics
        (
            MetricDefinitionID,
            InstanceID,
            ResourceID
        )

        INCLUDE
        (
            CaptureDateUTC,
            MetricValue,
            MetricUnit,
            CollectionStatus,
            LastSuccessfulCaptureUTC,
            LastSuccessfulValue,
            LastSuccessfulUnit
        )

        WITH (MAXDOP = 1);

        SET @IndexesCreated += 1;

        INSERT INTO @DeploymentResults
        VALUES
        (
            'LatestMetrics',
            'IX_LM_MetricDashboard',
            'CREATED',
            NULL
        );

    END

    ELSE
    BEGIN

        SET @IndexesSkipped += 1;

        INSERT INTO @DeploymentResults
        VALUES
        (
            'LatestMetrics',
            'IX_LM_MetricDashboard',
            'ALREADY EXISTS',
            'Existing index preserved.'
        );

    END;

    --------------------------------------------------------
    -- INDEX 10: Active Resource Inventory
    --------------------------------------------------------

    IF NOT EXISTS
    (
        SELECT 1

        FROM sys.indexes

        WHERE object_id =
            OBJECT_ID('dbo.MonitoredResources')

          AND name =
            'IX_MR_ActiveResources'
    )
    BEGIN

        CREATE NONCLUSTERED INDEX
            IX_MR_ActiveResources

        ON dbo.MonitoredResources
        (
            InstanceID,
            ResourceType,
            LastSeenDateUTC
        )

        INCLUDE
        (
            ResourceName,
            DisplayName,
            FirstSeenDateUTC
        )

        WHERE IsActive = 1

        WITH (MAXDOP = 1);

        SET @IndexesCreated += 1;

        INSERT INTO @DeploymentResults
        VALUES
        (
            'MonitoredResources',
            'IX_MR_ActiveResources',
            'CREATED',
            NULL
        );

    END

    ELSE
    BEGIN

        SET @IndexesSkipped += 1;

        INSERT INTO @DeploymentResults
        VALUES
        (
            'MonitoredResources',
            'IX_MR_ActiveResources',
            'ALREADY EXISTS',
            'Existing index preserved.'
        );

    END;

    --------------------------------------------------------
    -- SECTION 7: Register Schema Version
    --------------------------------------------------------

    IF NOT EXISTS
    (
        SELECT 1

        FROM dbo.SchemaVersion

        WHERE VersionNumber = '1.0.1'
    )
    BEGIN

        INSERT INTO dbo.SchemaVersion
        (
            VersionNumber,
            ScriptName,
            AppliedBy,
            Description
        )
        VALUES
        (
            '1.0.1',
            N'03-Create-Monitoring-Indexes.sql',
            ORIGINAL_LOGIN(),
            N'Initial supporting monitoring repository indexes.'
        );

    END;

    --------------------------------------------------------
    -- SECTION 8: Commit Index Deployment
    --------------------------------------------------------

    COMMIT TRANSACTION;

    SELECT
        @ActualServer AS ServerName,
        DB_NAME() AS DatabaseName,
        'SUCCESS' AS DeploymentStatus,
        @IndexesCreated AS IndexesCreated,
        @IndexesSkipped AS ExistingIndexesSkipped,

        DATEDIFF_BIG
        (
            MILLISECOND,
            @DeploymentStart,
            SYSUTCDATETIME()
        ) AS DeploymentDurationMS,

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
-- SECTION 9: Index Deployment Results
------------------------------------------------------------

SELECT
    TableName,
    IndexName,
    DeploymentStatus,
    Details

FROM @DeploymentResults

ORDER BY
    TableName,
    IndexName;

------------------------------------------------------------
-- SECTION 10: Monitoring Index Verification
------------------------------------------------------------

SELECT
    S.name AS SchemaName,
    T.name AS TableName,
    I.name AS IndexName,
    I.type_desc AS IndexType,
    I.is_unique AS IsUnique,
    I.is_primary_key AS IsPrimaryKey,
    I.is_disabled AS IsDisabled,
    I.has_filter AS HasFilter,
    I.filter_definition AS FilterDefinition

FROM sys.indexes AS I

INNER JOIN sys.tables AS T
    ON I.object_id = T.object_id

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

  AND I.index_id > 0

ORDER BY
    T.name,
    I.index_id;

------------------------------------------------------------
-- SECTION 11: Index Storage Verification
------------------------------------------------------------

SELECT
    T.name AS TableName,
    I.name AS IndexName,

    SUM(P.row_count) AS RowCount,

    CONVERT
    (
        DECIMAL(18,2),
        SUM(P.reserved_page_count) / 128.0
    ) AS ReservedSpaceMB,

    CONVERT
    (
        DECIMAL(18,2),
        SUM(P.used_page_count) / 128.0
    ) AS UsedSpaceMB

FROM sys.dm_db_partition_stats AS P

INNER JOIN sys.indexes AS I
    ON P.object_id = I.object_id
   AND P.index_id = I.index_id

INNER JOIN sys.tables AS T
    ON I.object_id = T.object_id

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

  AND I.index_id > 0

GROUP BY
    T.name,
    I.name

ORDER BY
    ReservedSpaceMB DESC,
    T.name,
    I.name;

GO
