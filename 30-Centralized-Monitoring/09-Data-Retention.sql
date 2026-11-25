/*
============================================================
Project : SQL Server Production Optimization
Module  : 30 - Centralized Monitoring
Script  : 09-Data-Retention.sql
Purpose : Controlled historical monitoring data retention
Type    : Central Repository Deployment
Impact  : Central DBA_Monitoring database only
Version : 1.0
============================================================

IMPORTANT:

1. Execute ONLY on the approved central monitoring instance.
2. Execute after 08-Historical-Metrics.sql.
3. Do NOT execute on monitored production instances.
4. Deployment is disabled by default.
5. Historical deletion requires explicit authorization.
6. Cleanup is performed in controlled batches.
7. Current metrics and checkpoints are preserved.
8. Existing inventory application remains unchanged.
9. No database shrink operations are performed.

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

    @ActualServer NVARCHAR(128);

SET @ActualServer =
    CONVERT(NVARCHAR(128), SERVERPROPERTY('ServerName'));

------------------------------------------------------------
-- SECTION 2: Deployment Safety Validation
------------------------------------------------------------

IF ISNULL(@AllowDeployment, 0) <> 1
    THROW 50001, 'Deployment disabled.', 1;

IF @ApprovedMonitoringServer =
    N'REPLACE_WITH_APPROVED_SERVER_NAME'
    THROW 50002, 'Approved server must be configured.', 1;

IF @ActualServer IS NULL
   OR @ActualServer <> @ApprovedMonitoringServer
    THROW 50003, 'Incorrect monitoring instance.', 1;

IF DB_NAME() <> N'DBA_Monitoring'
    THROW 50004, 'Incorrect database context.', 1;

IF ISNULL
(
    TRY_CONVERT
    (
        INT,
        SERVERPROPERTY('ProductMajorVersion')
    ),
    0
) < 15
    THROW 50005, 'SQL Server 2019 or later required.', 1;

IF DATABASEPROPERTYEX
(
    DB_NAME(),
    'Updateability'
) <> 'READ_WRITE'
    THROW 50006, 'Database must be writable.', 1;

IF @@TRANCOUNT <> 0
    THROW 50007, 'Existing transaction detected.', 1;

------------------------------------------------------------
-- SECTION 3: Repository Validation
------------------------------------------------------------

IF OBJECT_ID('dbo.MetricSamples', 'U') IS NULL
OR OBJECT_ID('dbo.LatestMetrics', 'U') IS NULL
OR OBJECT_ID('dbo.MetricHourlyAggregates', 'U') IS NULL
OR OBJECT_ID('dbo.MetricCounterBaselines', 'U') IS NULL
OR OBJECT_ID('dbo.MetricEventRegistry', 'U') IS NULL
OR OBJECT_ID('dbo.CollectionRuns', 'U') IS NULL
OR OBJECT_ID('dbo.CollectionCheckpoints', 'U') IS NULL
OR OBJECT_ID('dbo.CheckpointAudit', 'U') IS NULL
OR OBJECT_ID('dbo.MetricDefinitions', 'U') IS NULL
OR OBJECT_ID('dbo.MonitoringSettings', 'U') IS NULL
OR OBJECT_ID('dbo.MonitoredResources', 'U') IS NULL
OR OBJECT_ID('dbo.SchemaVersion', 'U') IS NULL
BEGIN
    THROW 50008,
        'Required monitoring repository objects are missing.',
        1;
END;

IF COL_LENGTH('dbo.MetricSamples', 'SampleKind') IS NULL
OR COL_LENGTH('dbo.MetricSamples', 'IntervalStartUTC') IS NULL
BEGIN
    THROW 50009,
        'Required historical sample columns are missing.',
        1;
END;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.SchemaVersion
    WHERE VersionNumber = '1.0.4'
)
    THROW 50010, 'Required schema version not found.', 1;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.MonitoringSettings
    WHERE SettingKey = 'MonitoringEnabled'
      AND SettingValue = N'0'
)
    THROW 50011, 'Monitoring must be disabled.', 1;

IF EXISTS
(
    SELECT 1
    FROM dbo.CollectionRuns
    WHERE RunStatus = 'RUNNING'
)
    THROW 50012, 'Active collection runs exist.', 1;

------------------------------------------------------------
-- SECTION 4: Transactional Deployment
------------------------------------------------------------

BEGIN TRY

    BEGIN TRANSACTION;

    --------------------------------------------------------
    -- TABLE 16: Retention Execution History
    --------------------------------------------------------

    IF OBJECT_ID
    (
        'dbo.RetentionExecutionLog',
        'U'
    ) IS NULL
    BEGIN

        CREATE TABLE dbo.RetentionExecutionLog
        (
            RetentionRunID BIGINT IDENTITY(1,1)
                NOT NULL,

            StartDateUTC DATETIME2(3) NOT NULL,

            EndDateUTC DATETIME2(3) NULL,

            RunStatus VARCHAR(20) NOT NULL,

            BatchSize INT NOT NULL,

            MaximumBatches INT NOT NULL,

            MaximumRuntimeSeconds INT NOT NULL,

            CompletedBatches INT NOT NULL
                DEFAULT (0),

            RawMetricRowsDeleted BIGINT NOT NULL
                DEFAULT (0),

            StateMetricRowsDeleted BIGINT NOT NULL
                DEFAULT (0),

            EventMetricRowsDeleted BIGINT NOT NULL
                DEFAULT (0),

            AggregateRowsDeleted BIGINT NOT NULL
                DEFAULT (0),

            CollectionRunRowsDeleted BIGINT NOT NULL
                DEFAULT (0),

            CheckpointAuditRowsDeleted BIGINT NOT NULL
                DEFAULT (0),

            RetentionLogRowsDeleted BIGINT NOT NULL
                DEFAULT (0),

            ErrorNumber INT NULL,

            ErrorMessage NVARCHAR(2048) NULL,

            ExecutedBy NVARCHAR(128) NOT NULL,

            CONSTRAINT PK_RetentionExecutionLog
                PRIMARY KEY CLUSTERED
                (RetentionRunID),

            CONSTRAINT CK_REL_RunStatus
                CHECK
                (
                    RunStatus IN
                    (
                        'RUNNING',
                        'SUCCESS',
                        'PARTIAL',
                        'FAILED',
                        'CANCELLED'
                    )
                )
        );

        CREATE NONCLUSTERED INDEX
            IX_REL_StartDate

        ON dbo.RetentionExecutionLog
        (
            StartDateUTC DESC,
            RetentionRunID
        )

        INCLUDE
        (
            RunStatus,
            EndDateUTC,
            CompletedBatches
        );

    END;

    --------------------------------------------------------
    -- SECTION 5: Retention Configuration
    --------------------------------------------------------

    DECLARE @RetentionSettings TABLE
    (
        SettingKey VARCHAR(100) PRIMARY KEY,

        SettingValue NVARCHAR(4000),

        SettingDataType VARCHAR(20),

        Description NVARCHAR(1000)
    );

    INSERT INTO @RetentionSettings
    VALUES
    (
        'DataRetentionEnabled',
        N'0',
        'BOOLEAN',
        N'Permit automated historical data retention.'
    ),
    (
        'RawMetricRetentionDays',
        N'7',
        'INTEGER',
        N'Retention period for raw observations and counter deltas.'
    ),
    (
        'StateMetricRetentionDays',
        N'90',
        'INTEGER',
        N'Retention period for historical state changes.'
    ),
    (
        'EventMetricRetentionDays',
        N'90',
        'INTEGER',
        N'Retention period for historical event metrics.'
    ),
    (
        'HourlyAggregateRetentionDays',
        N'365',
        'INTEGER',
        N'Retention period for hourly performance summaries.'
    ),
    (
        'CollectionRunRetentionDays',
        N'30',
        'INTEGER',
        N'Retention period for completed collection runs.'
    ),
    (
        'CheckpointAuditRetentionDays',
        N'365',
        'INTEGER',
        N'Retention period for checkpoint reset audit history.'
    ),
    (
        'RetentionLogRetentionDays',
        N'90',
        'INTEGER',
        N'Retention period for historical cleanup execution logs.'
    ),
    (
        'RetentionBatchSize',
        N'5000',
        'INTEGER',
        N'Maximum rows deleted per cleanup transaction.'
    ),
    (
        'RetentionMaximumBatches',
        N'100',
        'INTEGER',
        N'Maximum cleanup batches per execution.'
    ),
    (
        'RetentionMaximumRuntimeSeconds',
        N'300',
        'INTEGER',
        N'Cooperative runtime limit for cleanup execution.'
    ),
    (
        'RetentionRequireHourlyAggregation',
        N'1',
        'BOOLEAN',
        N'Require verified hourly aggregation before eligible raw metric deletion.'
    );

    INSERT INTO dbo.MonitoringSettings
    (
        SettingKey,
        SettingValue,
        SettingDataType,
        Description
    )
    SELECT
        S.SettingKey,
        S.SettingValue,
        S.SettingDataType,
        S.Description

    FROM @RetentionSettings AS S

    WHERE NOT EXISTS
    (
        SELECT 1

        FROM dbo.MonitoringSettings AS T

        WHERE T.SettingKey = S.SettingKey
    );

    --------------------------------------------------------
    -- SECTION 6: Supporting Cleanup Indexes
    --------------------------------------------------------

    IF NOT EXISTS
    (
        SELECT 1

        FROM sys.indexes

        WHERE object_id =
            OBJECT_ID('dbo.CheckpointAudit')

          AND name =
            'IX_CPA_Retention'
    )
    BEGIN

        CREATE NONCLUSTERED INDEX
            IX_CPA_Retention

        ON dbo.CheckpointAudit
        (
            ActionDateUTC,
            CheckpointAuditID
        )

        WITH (MAXDOP = 1);

    END;

    IF NOT EXISTS
    (
        SELECT 1

        FROM sys.indexes

        WHERE object_id =
            OBJECT_ID('dbo.MetricSamples')

          AND name =
            'IX_MS_SampleKindRetention'
    )
    BEGIN

        CREATE NONCLUSTERED INDEX
            IX_MS_SampleKindRetention

        ON dbo.MetricSamples
        (
            SampleKind,
            CaptureDateUTC,
            SampleID
        )

        INCLUDE
        (
            InstanceID,
            ResourceID,
            MetricDefinitionID,
            CollectionStatus,
            MetricUnit
        )

        WITH (MAXDOP = 1);

    END;

    --------------------------------------------------------
    -- PROCEDURE 01: Data Retention Preview
    --------------------------------------------------------

    EXEC sys.sp_executesql N'

    CREATE OR ALTER PROCEDURE
        dbo.usp_DataRetentionPreview
    AS
    BEGIN

        SET NOCOUNT ON;

        DECLARE
            @CurrentUTC DATETIME2(3) =
                SYSUTCDATETIME(),

            @RawDays INT,
            @StateDays INT,
            @EventDays INT,
            @AggregateDays INT,
            @RunDays INT,
            @AuditDays INT,
            @LogDays INT;

        SELECT
            @RawDays =
                MAX(CASE
                    WHEN SettingKey =
                        ''RawMetricRetentionDays''
                    THEN TRY_CONVERT(INT, SettingValue)
                END),

            @StateDays =
                MAX(CASE
                    WHEN SettingKey =
                        ''StateMetricRetentionDays''
                    THEN TRY_CONVERT(INT, SettingValue)
                END),

            @EventDays =
                MAX(CASE
                    WHEN SettingKey =
                        ''EventMetricRetentionDays''
                    THEN TRY_CONVERT(INT, SettingValue)
                END),

            @AggregateDays =
                MAX(CASE
                    WHEN SettingKey =
                        ''HourlyAggregateRetentionDays''
                    THEN TRY_CONVERT(INT, SettingValue)
                END),

            @RunDays =
                MAX(CASE
                    WHEN SettingKey =
                        ''CollectionRunRetentionDays''
                    THEN TRY_CONVERT(INT, SettingValue)
                END),

            @AuditDays =
                MAX(CASE
                    WHEN SettingKey =
                        ''CheckpointAuditRetentionDays''
                    THEN TRY_CONVERT(INT, SettingValue)
                END),

            @LogDays =
                MAX(CASE
                    WHEN SettingKey =
                        ''RetentionLogRetentionDays''
                    THEN TRY_CONVERT(INT, SettingValue)
                END)

        FROM dbo.MonitoringSettings;

        IF ISNULL(@RawDays, 0)
            NOT BETWEEN 1 AND 3650

        OR ISNULL(@StateDays, 0)
            NOT BETWEEN 1 AND 3650

        OR ISNULL(@EventDays, 0)
            NOT BETWEEN 1 AND 3650

        OR ISNULL(@AggregateDays, 0)
            NOT BETWEEN 1 AND 3650

        OR ISNULL(@RunDays, 0)
            NOT BETWEEN 1 AND 3650

        OR ISNULL(@AuditDays, 0)
            NOT BETWEEN 1 AND 3650

        OR ISNULL(@LogDays, 0)
            NOT BETWEEN 1 AND 3650

        BEGIN
            THROW 51201,
                ''Invalid retention configuration.'',
                1;
        END;

        ----------------------------------------------------
        -- Candidate records by retention category
        ----------------------------------------------------

        SELECT
            ''Raw and Delta Metrics''
                AS DataCategory,

            @RawDays AS RetentionDays,

            DATEADD
            (
                DAY,
                -@RawDays,
                @CurrentUTC
            ) AS CutoffDateUTC,

            COUNT_BIG(*) AS AgeEligibleRows

        FROM dbo.MetricSamples

        WHERE SampleKind IN (''RAW'', ''DELTA'')

          AND CaptureDateUTC <
              DATEADD(DAY, -@RawDays, @CurrentUTC)

        UNION ALL

        SELECT
            ''State Metrics'',
            @StateDays,
            DATEADD(DAY, -@StateDays, @CurrentUTC),
            COUNT_BIG(*)

        FROM dbo.MetricSamples

        WHERE SampleKind = ''STATE''

          AND CaptureDateUTC <
              DATEADD(DAY, -@StateDays, @CurrentUTC)

        UNION ALL

        SELECT
            ''Event Metrics'',
            @EventDays,
            DATEADD(DAY, -@EventDays, @CurrentUTC),
            COUNT_BIG(*)

        FROM dbo.MetricSamples

        WHERE SampleKind = ''EVENT''

          AND CaptureDateUTC <
              DATEADD(DAY, -@EventDays, @CurrentUTC)

        UNION ALL

        SELECT
            ''Hourly Aggregates'',
            @AggregateDays,
            DATEADD(DAY, -@AggregateDays, @CurrentUTC),
            COUNT_BIG(*)

        FROM dbo.MetricHourlyAggregates

        WHERE HourStartUTC <
              DATEADD(DAY, -@AggregateDays, @CurrentUTC)

        UNION ALL

        SELECT
            ''Collection Runs'',
            @RunDays,
            DATEADD(DAY, -@RunDays, @CurrentUTC),
            COUNT_BIG(*)

        FROM dbo.CollectionRuns

        WHERE EndDateUTC <
              DATEADD(DAY, -@RunDays, @CurrentUTC)

          AND RunStatus <> ''RUNNING''

        UNION ALL

        SELECT
            ''Checkpoint Audit'',
            @AuditDays,
            DATEADD(DAY, -@AuditDays, @CurrentUTC),
            COUNT_BIG(*)

        FROM dbo.CheckpointAudit

        WHERE ActionDateUTC <
              DATEADD(DAY, -@AuditDays, @CurrentUTC)

        UNION ALL

        SELECT
            ''Retention Execution Logs'',
            @LogDays,
            DATEADD(DAY, -@LogDays, @CurrentUTC),
            COUNT_BIG(*)

        FROM dbo.RetentionExecutionLog

        WHERE EndDateUTC <
              DATEADD(DAY, -@LogDays, @CurrentUTC)

          AND RunStatus <> ''RUNNING''

        OPTION (MAXDOP 1);

        ----------------------------------------------------
        -- Retention settings
        ----------------------------------------------------

        SELECT
            SettingKey,
            SettingValue,
            Description

        FROM dbo.MonitoringSettings

        WHERE SettingKey LIKE ''%Retention%''

        ORDER BY SettingKey;

        /*
        AgeEligibleRows is a candidate count only.

        Aggregation verification, active run protection,
        historical dependencies and other safeguards
        may reduce the actual deletion count.
        */

    END;

    ';

    --------------------------------------------------------
    -- PROCEDURE 02: Controlled Data Retention
    --------------------------------------------------------

    EXEC sys.sp_executesql N'

    CREATE OR ALTER PROCEDURE
        dbo.usp_ExecuteDataRetention
    (
        @AllowDeletion BIT = 0,

        @ConfirmServiceStopped BIT = 0
    )
    AS
    BEGIN

        SET NOCOUNT ON;
        SET XACT_ABORT ON;

        DECLARE
            @CurrentUTC DATETIME2(3) =
                SYSUTCDATETIME(),

            @RawDays INT,
            @StateDays INT,
            @EventDays INT,
            @AggregateDays INT,
            @RunDays INT,
            @AuditDays INT,
            @LogDays INT,

            @BatchSize INT,
            @MaximumBatches INT,
            @MaximumRuntimeSeconds INT,

            @RequireAggregation BIT,

            @RawCutoff DATETIME2(3),
            @StateCutoff DATETIME2(3),
            @EventCutoff DATETIME2(3),
            @AggregateCutoff DATETIME2(3),
            @RunCutoff DATETIME2(3),
            @AuditCutoff DATETIME2(3),
            @LogCutoff DATETIME2(3),

            @RetentionRunID BIGINT,

            @LockResult INT,

            @RowsDeleted INT = 0,

            @CompletedBatches INT = 0,

            @Phase INT = 1,

            @FinalStatus VARCHAR(20),

            @RawDeleted BIGINT = 0,
            @StateDeleted BIGINT = 0,
            @EventDeleted BIGINT = 0,
            @AggregateDeleted BIGINT = 0,
            @RunDeleted BIGINT = 0,
            @AuditDeleted BIGINT = 0,
            @LogDeleted BIGINT = 0,

            @LockAcquired BIT = 0,

            @SchedulingLockAcquired BIT = 0,

            @ErrorNumber INT,

            @ErrorMessage NVARCHAR(2048);

        ----------------------------------------------------
        -- Preview mode by default
        ----------------------------------------------------

        IF ISNULL(@AllowDeletion, 0) <> 1
        BEGIN

            EXEC dbo.usp_DataRetentionPreview;

            RETURN;

        END;

        ----------------------------------------------------
        -- Explicit maintenance authorization
        ----------------------------------------------------

        IF ISNULL(@ConfirmServiceStopped, 0) <> 1
            THROW 51301,
                ''Stop monitoring workers before retention cleanup.'',
                1;

        IF @@TRANCOUNT <> 0
            THROW 51302,
                ''Retention requires an independent transaction.'',
                1;

        IF NOT EXISTS
        (
            SELECT 1

            FROM dbo.MonitoringSettings

            WHERE SettingKey =
                ''DataRetentionEnabled''

              AND SettingValue = N''1''
        )
            THROW 51303,
                ''Automated data retention is disabled.'',
                1;

        ----------------------------------------------------
        -- Retrieve retention configuration
        ----------------------------------------------------

        SELECT
            @RawDays =
                MAX(CASE
                    WHEN SettingKey =
                        ''RawMetricRetentionDays''
                    THEN TRY_CONVERT(INT, SettingValue)
                END),

            @StateDays =
                MAX(CASE
                    WHEN SettingKey =
                        ''StateMetricRetentionDays''
                    THEN TRY_CONVERT(INT, SettingValue)
                END),

            @EventDays =
                MAX(CASE
                    WHEN SettingKey =
                        ''EventMetricRetentionDays''
                    THEN TRY_CONVERT(INT, SettingValue)
                END),

            @AggregateDays =
                MAX(CASE
                    WHEN SettingKey =
                        ''HourlyAggregateRetentionDays''
                    THEN TRY_CONVERT(INT, SettingValue)
                END),

            @RunDays =
                MAX(CASE
                    WHEN SettingKey =
                        ''CollectionRunRetentionDays''
                    THEN TRY_CONVERT(INT, SettingValue)
                END),

            @AuditDays =
                MAX(CASE
                    WHEN SettingKey =
                        ''CheckpointAuditRetentionDays''
                    THEN TRY_CONVERT(INT, SettingValue)
                END),

            @LogDays =
                MAX(CASE
                    WHEN SettingKey =
                        ''RetentionLogRetentionDays''
                    THEN TRY_CONVERT(INT, SettingValue)
                END),

            @BatchSize =
                MAX(CASE
                    WHEN SettingKey =
                        ''RetentionBatchSize''
                    THEN TRY_CONVERT(INT, SettingValue)
                END),

            @MaximumBatches =
                MAX(CASE
                    WHEN SettingKey =
                        ''RetentionMaximumBatches''
                    THEN TRY_CONVERT(INT, SettingValue)
                END),

            @MaximumRuntimeSeconds =
                MAX(CASE
                    WHEN SettingKey =
                        ''RetentionMaximumRuntimeSeconds''
                    THEN TRY_CONVERT(INT, SettingValue)
                END),

            @RequireAggregation =
                MAX(CASE
                    WHEN SettingKey =
                        ''RetentionRequireHourlyAggregation''
                    THEN
                        CASE
                            WHEN SettingValue = N''1''
                                THEN 1
                            WHEN SettingValue = N''0''
                                THEN 0
                        END
                END)

        FROM dbo.MonitoringSettings;

        ----------------------------------------------------
        -- Validate retention parameters
        ----------------------------------------------------

        IF ISNULL(@RawDays, 0)
            NOT BETWEEN 1 AND 3650

        OR ISNULL(@StateDays, 0)
            NOT BETWEEN 1 AND 3650

        OR ISNULL(@EventDays, 0)
            NOT BETWEEN 1 AND 3650

        OR ISNULL(@AggregateDays, 0)
            NOT BETWEEN 1 AND 3650

        OR ISNULL(@RunDays, 0)
            NOT BETWEEN 1 AND 3650

        OR ISNULL(@AuditDays, 0)
            NOT BETWEEN 1 AND 3650

        OR ISNULL(@LogDays, 0)
            NOT BETWEEN 1 AND 3650

        OR ISNULL(@BatchSize, 0)
            NOT BETWEEN 100 AND 10000

        OR ISNULL(@MaximumBatches, 0)
            NOT BETWEEN 1 AND 1000

        OR ISNULL(@MaximumRuntimeSeconds, 0)
            NOT BETWEEN 10 AND 3600

        OR @RequireAggregation IS NULL

        BEGIN
            THROW 51304,
                ''Invalid retention configuration.'',
                1;
        END;

        IF @AggregateDays <= @RawDays
        BEGIN
            THROW 51305,
                ''Aggregate retention must exceed raw metric retention.'',
                1;
        END;

        SET @RawCutoff =
            DATEADD(DAY, -@RawDays, @CurrentUTC);

        SET @StateCutoff =
            DATEADD(DAY, -@StateDays, @CurrentUTC);

        SET @EventCutoff =
            DATEADD(DAY, -@EventDays, @CurrentUTC);

        SET @AggregateCutoff =
            DATEADD(DAY, -@AggregateDays, @CurrentUTC);

        SET @RunCutoff =
            DATEADD(DAY, -@RunDays, @CurrentUTC);

        SET @AuditCutoff =
            DATEADD(DAY, -@AuditDays, @CurrentUTC);

        SET @LogCutoff =
            DATEADD(DAY, -@LogDays, @CurrentUTC);

        ----------------------------------------------------
        -- Begin controlled retention processing
        ----------------------------------------------------

        BEGIN TRY

            ------------------------------------------------
            -- Prevent new collection reservations
            ------------------------------------------------

            EXEC @LockResult = sys.sp_getapplock

                @Resource =
                    N''DBA_Monitoring.CollectionScheduling'',

                @LockMode = ''Exclusive'',

                @LockOwner = ''Session'',

                @LockTimeout = 5000;

            IF @LockResult < 0
                THROW 51306,
                    ''Unable to acquire scheduling lock.'',
                    1;

            SET @SchedulingLockAcquired = 1;

            IF NOT EXISTS
            (
                SELECT 1

                FROM dbo.MonitoringSettings

                WHERE SettingKey =
                    ''MonitoringEnabled''

                  AND SettingValue = N''0''
            )
                THROW 51307,
                    ''Monitoring must be disabled before cleanup.'',
                    1;

            IF EXISTS
            (
                SELECT 1

                FROM dbo.CollectionRuns

                WHERE RunStatus = ''RUNNING''
            )
                THROW 51308,
                    ''Active collection runs exist.'',
                    1;

            ------------------------------------------------
            -- Prevent concurrent historical maintenance
            ------------------------------------------------

            EXEC @LockResult = sys.sp_getapplock

                @Resource =
                    N''DBA_Monitoring.HistoricalMaintenance'',

                @LockMode = ''Exclusive'',

                @LockOwner = ''Session'',

                @LockTimeout = 5000;

            IF @LockResult < 0
                THROW 51309,
                    ''Unable to acquire historical maintenance lock.'',
                    1;

            SET @LockAcquired = 1;

            ------------------------------------------------
            -- Register retention execution
            ------------------------------------------------

            INSERT INTO dbo.RetentionExecutionLog
            (
                StartDateUTC,
                RunStatus,
                BatchSize,
                MaximumBatches,
                MaximumRuntimeSeconds,
                ExecutedBy
            )
            VALUES
            (
                @CurrentUTC,
                ''RUNNING'',
                @BatchSize,
                @MaximumBatches,
                @MaximumRuntimeSeconds,
                ORIGINAL_LOGIN()
            );

            SET @RetentionRunID =
                CONVERT(BIGINT, SCOPE_IDENTITY());

            ------------------------------------------------
            -- Stage verified aggregate coverage
            ------------------------------------------------

            CREATE TABLE #VerifiedHours
            (
                HourStartUTC DATETIME2(0) NOT NULL,
                InstanceID INT NOT NULL,
                ResourceID BIGINT NOT NULL,
                MetricDefinitionID INT NOT NULL,
                MetricUnit VARCHAR(30) NOT NULL,
                AggregationType VARCHAR(20) NOT NULL,

                PRIMARY KEY
                (
                    HourStartUTC,
                    InstanceID,
                    ResourceID,
                    MetricDefinitionID,
                    MetricUnit,
                    AggregationType
                )
            );

            /*
            Only verify complete metric-hour groups.

            Compare retained raw sample counts, first and
            last capture timestamps, and aggregated values.

            Do not trust aggregate existence alone.
            */

            IF @RequireAggregation = 1
            BEGIN

                ;WITH HistoricalGroups AS
                (
                    SELECT
                        DATEADD
                        (
                            HOUR,
                            DATEDIFF
                            (
                                HOUR,
                                CONVERT(DATETIME2, ''20000101''),
                                S.CaptureDateUTC
                            ),
                            CONVERT(DATETIME2, ''20000101'')
                        ) AS HourStartUTC,

                        S.InstanceID,

                        S.ResourceID,

                        S.MetricDefinitionID,

                        S.MetricUnit,

                        CASE
                            WHEN S.SampleKind = ''DELTA''
                                THEN ''DELTA''
                            ELSE ''GAUGE''
                        END AS AggregationType,

                        COUNT_BIG(*) AS SampleCount,

                        MIN(S.MetricValue) AS MinimumValue,

                        MAX(S.MetricValue) AS MaximumValue,

                        SUM
                        (
                            CONVERT
                            (
                                DECIMAL(38,4),
                                S.MetricValue
                            )
                        ) AS SumValue,

                        MIN(S.CaptureDateUTC)
                            AS FirstCaptureDateUTC,

                        MAX(S.CaptureDateUTC)
                            AS LastCaptureDateUTC

                    FROM dbo.MetricSamples AS S

                    INNER JOIN dbo.MetricDefinitions AS D

                        ON S.MetricDefinitionID =
                           D.MetricDefinitionID

                    WHERE S.CaptureDateUTC <
                    (
                        DATEADD
                        (
                            HOUR,
                            DATEDIFF
                            (
                                HOUR,
                                CONVERT(DATETIME2, ''20000101''),
                                @RawCutoff
                            ),
                            CONVERT(DATETIME2, ''20000101'')
                        )
                    )

                    AND S.CollectionStatus = ''SUCCESS''

                    AND S.MetricValue IS NOT NULL

                    AND
                    (
                        S.SampleKind = ''DELTA''

                        OR
                        (
                            S.SampleKind = ''RAW''
                            AND D.MetricBehavior = ''GAUGE''
                        )
                    )

                    GROUP BY
                        DATEADD
                        (
                            HOUR,
                            DATEDIFF
                            (
                                HOUR,
                                CONVERT(DATETIME2, ''20000101''),
                                S.CaptureDateUTC
                            ),
                            CONVERT(DATETIME2, ''20000101'')
                        ),

                        S.InstanceID,
                        S.ResourceID,
                        S.MetricDefinitionID,
                        S.MetricUnit,

                        CASE
                            WHEN S.SampleKind = ''DELTA''
                                THEN ''DELTA''
                            ELSE ''GAUGE''
                        END
                )

                INSERT INTO #VerifiedHours
                SELECT
                    H.HourStartUTC,
                    H.InstanceID,
                    H.ResourceID,
                    H.MetricDefinitionID,
                    H.MetricUnit,
                    H.AggregationType

                FROM HistoricalGroups AS H

                INNER JOIN dbo.MetricHourlyAggregates AS A

                    ON H.HourStartUTC = A.HourStartUTC

                   AND H.InstanceID = A.InstanceID

                   AND H.ResourceID = A.ResourceID

                   AND H.MetricDefinitionID =
                       A.MetricDefinitionID

                   AND H.MetricUnit = A.MetricUnit

                   AND H.AggregationType =
                       A.AggregationType

                WHERE H.SampleCount = A.SampleCount

                  AND H.MinimumValue = A.MinimumValue

                  AND H.MaximumValue = A.MaximumValue

                  AND H.SumValue = A.SumValue

                  AND H.FirstCaptureDateUTC =
                      A.FirstCaptureDateUTC

                  AND H.LastCaptureDateUTC =
                      A.LastCaptureDateUTC

                OPTION (MAXDOP 1);

            END;

            ------------------------------------------------
            -- SECTION A: Batch-based deletion
            ------------------------------------------------

            WHILE @Phase <= 7

              AND @CompletedBatches < @MaximumBatches

              AND DATEDIFF_BIG
              (
                  SECOND,
                  @CurrentUTC,
                  SYSUTCDATETIME()
              ) < @MaximumRuntimeSeconds

            BEGIN

                ------------------------------------------------
                -- Check stop switches between batches
                ------------------------------------------------

                IF NOT EXISTS
                (
                    SELECT 1

                    FROM dbo.MonitoringSettings

                    WHERE SettingKey =
                        ''DataRetentionEnabled''

                      AND SettingValue = N''1''
                )
                    BREAK;

                IF NOT EXISTS
                (
                    SELECT 1

                    FROM dbo.MonitoringSettings

                    WHERE SettingKey =
                        ''MonitoringEnabled''

                      AND SettingValue = N''0''
                )
                    BREAK;

                SET @RowsDeleted = 0;

                BEGIN TRANSACTION;

                ------------------------------------------------
                -- PHASE 01: Raw and Delta Metrics
                ------------------------------------------------

                IF @Phase = 1
                BEGIN

                    ;WITH DeleteBatch AS
                    (
                        SELECT TOP (@BatchSize)
                            S.SampleID

                        FROM dbo.MetricSamples AS S

                        INNER JOIN dbo.MetricDefinitions AS D

                            ON S.MetricDefinitionID =
                               D.MetricDefinitionID

                        WHERE S.SampleKind IN
                            (''RAW'', ''DELTA'')

                          AND S.CaptureDateUTC <
                              @RawCutoff

                          AND NOT EXISTS
                          (
                              SELECT 1

                              FROM dbo.CollectionRuns AS R

                              WHERE R.CollectionRunID =
                                    S.CollectionRunID

                                AND R.RunStatus =
                                    ''RUNNING''
                          )

                          AND
                          (
                              @RequireAggregation = 0

                              OR S.CollectionStatus <>
                                 ''SUCCESS''

                              OR
                              (
                                  S.SampleKind = ''RAW''

                                  AND D.MetricBehavior <>
                                      ''GAUGE''
                              )

                              OR EXISTS
                              (
                                  SELECT 1

                                  FROM #VerifiedHours AS V

                                  WHERE V.InstanceID =
                                        S.InstanceID

                                    AND V.ResourceID =
                                        S.ResourceID

                                    AND V.MetricDefinitionID =
                                        S.MetricDefinitionID

                                    AND V.MetricUnit =
                                        S.MetricUnit

                                    AND V.AggregationType =
                                        CASE
                                            WHEN S.SampleKind =
                                                ''DELTA''
                                                THEN ''DELTA''
                                            ELSE ''GAUGE''
                                        END

                                    AND S.CaptureDateUTC >=
                                        V.HourStartUTC

                                    AND S.CaptureDateUTC <
                                        DATEADD
                                        (
                                            HOUR,
                                            1,
                                            V.HourStartUTC
                                        )
                              )
                          )

                        ORDER BY
                            S.CaptureDateUTC,
                            S.SampleID
                    )

                    DELETE S

                    FROM dbo.MetricSamples AS S

                    INNER JOIN DeleteBatch AS B

                        ON S.SampleID = B.SampleID

                    OPTION (MAXDOP 1);

                    SET @RowsDeleted = @@ROWCOUNT;

                    SET @RawDeleted += @RowsDeleted;

                END;

                ------------------------------------------------
                -- PHASE 02: Historical State Changes
                ------------------------------------------------

                ELSE IF @Phase = 2
                BEGIN

                    ;WITH DeleteBatch AS
                    (
                        SELECT TOP (@BatchSize)
                            S.SampleID

                        FROM dbo.MetricSamples AS S

                        WHERE S.SampleKind = ''STATE''

                          AND S.CaptureDateUTC <
                              @StateCutoff

                          AND NOT EXISTS
                          (
                              SELECT 1

                              FROM dbo.CollectionRuns AS R

                              WHERE R.CollectionRunID =
                                    S.CollectionRunID

                                AND R.RunStatus =
                                    ''RUNNING''
                          )

                          -- Preserve the latest state record.

                          AND EXISTS
                          (
                              SELECT 1

                              FROM dbo.MetricSamples AS N

                              WHERE N.InstanceID =
                                    S.InstanceID

                                AND N.ResourceID =
                                    S.ResourceID

                                AND N.MetricDefinitionID =
                                    S.MetricDefinitionID

                                AND N.SampleKind =
                                    ''STATE''

                                AND
                                (
                                    N.CaptureDateUTC >
                                        S.CaptureDateUTC

                                    OR
                                    (
                                        N.CaptureDateUTC =
                                            S.CaptureDateUTC

                                        AND N.SampleID >
                                            S.SampleID
                                    )
                                )
                          )

                        ORDER BY
                            S.CaptureDateUTC,
                            S.SampleID
                    )

                    DELETE S

                    FROM dbo.MetricSamples AS S

                    INNER JOIN DeleteBatch AS B

                        ON S.SampleID = B.SampleID

                    OPTION (MAXDOP 1);

                    SET @RowsDeleted = @@ROWCOUNT;

                    SET @StateDeleted += @RowsDeleted;

                END;

                ------------------------------------------------
                -- PHASE 03: Historical Event Metrics
                ------------------------------------------------

                ELSE IF @Phase = 3
                BEGIN

                    ;WITH DeleteBatch AS
                    (
                        SELECT TOP (@BatchSize)
                            S.SampleID

                        FROM dbo.MetricSamples AS S

                        WHERE S.SampleKind = ''EVENT''

                          AND S.CaptureDateUTC <
                              @EventCutoff

                          AND NOT EXISTS
                          (
                              SELECT 1

                              FROM dbo.CollectionRuns AS R

                              WHERE R.CollectionRunID =
                                    S.CollectionRunID

                                AND R.RunStatus =
                                    ''RUNNING''
                          )

                        ORDER BY
                            S.CaptureDateUTC,
                            S.SampleID
                    )

                    DELETE S

                    FROM dbo.MetricSamples AS S

                    INNER JOIN DeleteBatch AS B

                        ON S.SampleID = B.SampleID

                    OPTION (MAXDOP 1);

                    SET @RowsDeleted = @@ROWCOUNT;

                    SET @EventDeleted += @RowsDeleted;

                END;

                ------------------------------------------------
                -- PHASE 04: Expired Hourly Aggregates
                ------------------------------------------------

                ELSE IF @Phase = 4
                BEGIN

                    ;WITH DeleteBatch AS
                    (
                        SELECT TOP (@BatchSize)
                            A.*

                        FROM dbo.MetricHourlyAggregates AS A

                        WHERE DATEADD
                        (
                            HOUR,
                            1,
                            A.HourStartUTC
                        ) <= @AggregateCutoff

                        -- Keep summaries while matching
                        -- historical samples still exist.

                        AND NOT EXISTS
                        (
                            SELECT 1

                            FROM dbo.MetricSamples AS S

                            WHERE S.InstanceID =
                                  A.InstanceID

                              AND S.ResourceID =
                                  A.ResourceID

                              AND S.MetricDefinitionID =
                                  A.MetricDefinitionID

                              AND S.MetricUnit =
                                  A.MetricUnit

                              AND S.CaptureDateUTC >=
                                  A.HourStartUTC

                              AND S.CaptureDateUTC <
                                  DATEADD
                                  (
                                      HOUR,
                                      1,
                                      A.HourStartUTC
                                  )

                              AND S.SampleKind IN
                                  (''RAW'', ''DELTA'')
                        )

                        ORDER BY A.HourStartUTC
                    )

                    DELETE FROM DeleteBatch

                    OPTION (MAXDOP 1);

                    SET @RowsDeleted = @@ROWCOUNT;

                    SET @AggregateDeleted += @RowsDeleted;

                END;

                ------------------------------------------------
                -- PHASE 05: Completed Collection Runs
                ------------------------------------------------

                ELSE IF @Phase = 5
                BEGIN

                    ;WITH DeleteBatch AS
                    (
                        SELECT TOP (@BatchSize)
                            R.CollectionRunID

                        FROM dbo.CollectionRuns AS R

                        WHERE R.EndDateUTC <
                              @RunCutoff

                          AND R.RunStatus <>
                              ''RUNNING''

                          AND NOT EXISTS
                          (
                              SELECT 1

                              FROM dbo.MetricSamples AS S

                              WHERE S.CollectionRunID =
                                    R.CollectionRunID
                          )

                          AND NOT EXISTS
                          (
                              SELECT 1

                              FROM dbo.LatestMetrics AS L

                              WHERE L.CollectionRunID =
                                    R.CollectionRunID
                          )

                          AND NOT EXISTS
                          (
                              SELECT 1

                              FROM dbo.CollectionCheckpoints AS CP

                              WHERE CP.LastCollectionRunID =
                                    R.CollectionRunID
                          )

                          AND NOT EXISTS
                          (
                              SELECT 1

                              FROM dbo.MetricCounterBaselines AS B

                              WHERE B.CollectionRunID =
                                    R.CollectionRunID
                          )

                          AND NOT EXISTS
                          (
                              SELECT 1

                              FROM dbo.MetricEventRegistry AS E

                              WHERE E.FirstCollectionRunID =
                                    R.CollectionRunID
                          )

                        ORDER BY
                            R.EndDateUTC,
                            R.CollectionRunID
                    )

                    DELETE R

                    FROM dbo.CollectionRuns AS R

                    INNER JOIN DeleteBatch AS B

                        ON R.CollectionRunID =
                           B.CollectionRunID

                    OPTION (MAXDOP 1);

                    SET @RowsDeleted = @@ROWCOUNT;

                    SET @RunDeleted += @RowsDeleted;

                END;

                ------------------------------------------------
                -- PHASE 06: Checkpoint Administrative Audit
                ------------------------------------------------

                ELSE IF @Phase = 6
                BEGIN

                    ;WITH DeleteBatch AS
                    (
                        SELECT TOP (@BatchSize)
                            *

                        FROM dbo.CheckpointAudit

                        WHERE ActionDateUTC <
                              @AuditCutoff

                        ORDER BY
                            ActionDateUTC,
                            CheckpointAuditID
                    )

                    DELETE FROM DeleteBatch;

                    SET @RowsDeleted = @@ROWCOUNT;

                    SET @AuditDeleted += @RowsDeleted;

                END;

                ------------------------------------------------
                -- PHASE 07: Retention Execution History
                ------------------------------------------------

                ELSE IF @Phase = 7
                BEGIN

                    ;WITH DeleteBatch AS
                    (
                        SELECT TOP (@BatchSize)
                            *

                        FROM dbo.RetentionExecutionLog

                        WHERE EndDateUTC <
                              @LogCutoff

                          AND RunStatus <>
                              ''RUNNING''

                          AND RetentionRunID <>
                              @RetentionRunID

                        ORDER BY
                            EndDateUTC,
                            RetentionRunID
                    )

                    DELETE FROM DeleteBatch;

                    SET @RowsDeleted = @@ROWCOUNT;

                    SET @LogDeleted += @RowsDeleted;

                END;

                ------------------------------------------------
                -- Update audit within the same transaction
                ------------------------------------------------

                IF @RowsDeleted > 0
                    SET @CompletedBatches += 1;

                UPDATE dbo.RetentionExecutionLog

                SET CompletedBatches =
                        @CompletedBatches,

                    RawMetricRowsDeleted =
                        @RawDeleted,

                    StateMetricRowsDeleted =
                        @StateDeleted,

                    EventMetricRowsDeleted =
                        @EventDeleted,

                    AggregateRowsDeleted =
                        @AggregateDeleted,

                    CollectionRunRowsDeleted =
                        @RunDeleted,

                    CheckpointAuditRowsDeleted =
                        @AuditDeleted,

                    RetentionLogRowsDeleted =
                        @LogDeleted

                WHERE RetentionRunID =
                      @RetentionRunID;

                COMMIT TRANSACTION;

                ------------------------------------------------
                -- Continue to next category when exhausted
                ------------------------------------------------

                IF @RowsDeleted < @BatchSize
                    SET @Phase += 1;

                IF @RowsDeleted > 0
                BEGIN

                    WAITFOR DELAY ''00:00:00.200'';

                END;

            END;

            ------------------------------------------------
            -- Finalize retention execution
            ------------------------------------------------

            SET @FinalStatus =
                CASE
                    WHEN @Phase > 7
                        THEN ''SUCCESS''
                    ELSE ''PARTIAL''
                END;

            UPDATE dbo.RetentionExecutionLog

            SET EndDateUTC = SYSUTCDATETIME(),

                RunStatus = @FinalStatus

            WHERE RetentionRunID =
                  @RetentionRunID;

            ------------------------------------------------
            -- Release maintenance locks
            ------------------------------------------------

            EXEC sys.sp_releaseapplock

                @Resource =
                    N''DBA_Monitoring.HistoricalMaintenance'',

                @LockOwner = ''Session'';

            SET @LockAcquired = 0;

            EXEC sys.sp_releaseapplock

                @Resource =
                    N''DBA_Monitoring.CollectionScheduling'',

                @LockOwner = ''Session'';

            SET @SchedulingLockAcquired = 0;

            ------------------------------------------------
            -- Return retention execution summary
            ------------------------------------------------

            SELECT
                RetentionRunID,

                StartDateUTC,

                EndDateUTC,

                RunStatus,

                CompletedBatches,

                RawMetricRowsDeleted,

                StateMetricRowsDeleted,

                EventMetricRowsDeleted,

                AggregateRowsDeleted,

                CollectionRunRowsDeleted,

                CheckpointAuditRowsDeleted,

                RetentionLogRowsDeleted,

                RawMetricRowsDeleted

                    + StateMetricRowsDeleted

                    + EventMetricRowsDeleted

                    + AggregateRowsDeleted

                    + CollectionRunRowsDeleted

                    + CheckpointAuditRowsDeleted

                    + RetentionLogRowsDeleted

                    AS TotalRowsDeleted,

                DATEDIFF_BIG
                (
                    MILLISECOND,
                    StartDateUTC,
                    EndDateUTC
                ) AS DurationMilliseconds

            FROM dbo.RetentionExecutionLog

            WHERE RetentionRunID =
                  @RetentionRunID;

        END TRY

        BEGIN CATCH

            SET @ErrorNumber = ERROR_NUMBER();

            SET @ErrorMessage = ERROR_MESSAGE();

            IF XACT_STATE() <> 0
                ROLLBACK TRANSACTION;

            ------------------------------------------------
            -- Retain previously committed batch counts
            ------------------------------------------------

            IF @RetentionRunID IS NOT NULL
            BEGIN

                UPDATE dbo.RetentionExecutionLog

                SET EndDateUTC = SYSUTCDATETIME(),

                    RunStatus = ''FAILED'',

                    ErrorNumber = @ErrorNumber,

                    ErrorMessage = @ErrorMessage

                WHERE RetentionRunID =
                      @RetentionRunID;

            END;

            IF @LockAcquired = 1
            BEGIN

                EXEC sys.sp_releaseapplock

                    @Resource =
                        N''DBA_Monitoring.HistoricalMaintenance'',

                    @LockOwner = ''Session'';

            END;

            IF @SchedulingLockAcquired = 1
            BEGIN

                EXEC sys.sp_releaseapplock

                    @Resource =
                        N''DBA_Monitoring.CollectionScheduling'',

                    @LockOwner = ''Session'';

            END;

            THROW;

        END CATCH;

    END;

    ';

    --------------------------------------------------------
    -- PROCEDURE 03: Retention Execution Summary
    --------------------------------------------------------

    EXEC sys.sp_executesql N'

    CREATE OR ALTER PROCEDURE
        dbo.usp_DataRetentionSummary
    (
        @LookbackDays INT = 30
    )
    AS
    BEGIN

        SET NOCOUNT ON;

        IF @LookbackDays IS NULL

        OR @LookbackDays NOT BETWEEN 1 AND 365

        BEGIN

            THROW 51401,
                ''Lookback must be between 1 and 365 days.'',
                1;

        END;

        DECLARE
            @FromDateUTC DATETIME2(3) =
                DATEADD
                (
                    DAY,
                    -@LookbackDays,
                    SYSUTCDATETIME()
                );

        ----------------------------------------------------
        -- Result 01: Retention execution history
        ----------------------------------------------------

        SELECT
            RetentionRunID,

            StartDateUTC,

            EndDateUTC,

            RunStatus,

            BatchSize,

            CompletedBatches,

            RawMetricRowsDeleted,

            StateMetricRowsDeleted,

            EventMetricRowsDeleted,

            AggregateRowsDeleted,

            CollectionRunRowsDeleted,

            CheckpointAuditRowsDeleted,

            RetentionLogRowsDeleted,

            RawMetricRowsDeleted

                + StateMetricRowsDeleted

                + EventMetricRowsDeleted

                + AggregateRowsDeleted

                + CollectionRunRowsDeleted

                + CheckpointAuditRowsDeleted

                + RetentionLogRowsDeleted

                AS TotalRowsDeleted,

            DATEDIFF_BIG
            (
                MILLISECOND,
                StartDateUTC,
                EndDateUTC
            ) AS DurationMilliseconds,

            ErrorNumber,

            ErrorMessage,

            ExecutedBy

        FROM dbo.RetentionExecutionLog

        WHERE StartDateUTC >= @FromDateUTC

        ORDER BY RetentionRunID DESC;

        ----------------------------------------------------
        -- Result 02: Historical retention summary
        ----------------------------------------------------

        SELECT
            COUNT_BIG(*) AS RetentionExecutions,

            COUNT_BIG
            (
                CASE
                    WHEN RunStatus = ''SUCCESS''
                    THEN 1
                END
            ) AS SuccessfulExecutions,

            COUNT_BIG
            (
                CASE
                    WHEN RunStatus = ''PARTIAL''
                    THEN 1
                END
            ) AS PartialExecutions,

            COUNT_BIG
            (
                CASE
                    WHEN RunStatus = ''FAILED''
                    THEN 1
                END
            ) AS FailedExecutions,

            COALESCE
            (
                SUM(RawMetricRowsDeleted),
                0
            ) AS RawMetricRowsDeleted,

            COALESCE
            (
                SUM(StateMetricRowsDeleted),
                0
            ) AS StateMetricRowsDeleted,

            COALESCE
            (
                SUM(EventMetricRowsDeleted),
                0
            ) AS EventMetricRowsDeleted,

            COALESCE
            (
                SUM(AggregateRowsDeleted),
                0
            ) AS AggregateRowsDeleted,

            COALESCE
            (
                SUM(CollectionRunRowsDeleted),
                0
            ) AS CollectionRunRowsDeleted

        FROM dbo.RetentionExecutionLog

        WHERE StartDateUTC >= @FromDateUTC;

        ----------------------------------------------------
        -- Result 03: Protected monitoring objects
        ----------------------------------------------------

        SELECT
            ''LatestMetrics'' AS ProtectedObject,
            COUNT_BIG(*) AS ProtectedRows

        FROM dbo.LatestMetrics

        UNION ALL

        SELECT
            ''MetricCounterBaselines'',
            COUNT_BIG(*)

        FROM dbo.MetricCounterBaselines

        UNION ALL

        SELECT
            ''CollectionCheckpoints'',
            COUNT_BIG(*)

        FROM dbo.CollectionCheckpoints

        UNION ALL

        SELECT
            ''MetricEventRegistry'',
            COUNT_BIG(*)

        FROM dbo.MetricEventRegistry

        UNION ALL

        SELECT
            ''MonitoredResources'',
            COUNT_BIG(*)

        FROM dbo.MonitoredResources

        OPTION (MAXDOP 1);

    END;

    ';

    --------------------------------------------------------
    -- SECTION 7: Register Schema Version
    --------------------------------------------------------

    IF NOT EXISTS
    (
        SELECT 1

        FROM dbo.SchemaVersion

        WHERE VersionNumber = '1.0.5'
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
            '1.0.5',

            N'09-Data-Retention.sql',

            ORIGINAL_LOGIN(),

            N'Controlled data retention, batch cleanup,
              aggregate verification and retention auditing.'
        );

    END;

    --------------------------------------------------------
    -- SECTION 8: Commit Deployment
    --------------------------------------------------------

    COMMIT TRANSACTION;

    SELECT
        @ActualServer AS MonitoringServer,

        DB_NAME() AS MonitoringDatabase,

        'SUCCESS' AS DeploymentStatus,

        '1.0.5' AS SchemaVersion,

        SYSUTCDATETIME() AS DeploymentDateUTC;

END TRY

BEGIN CATCH

    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    SELECT
        @ActualServer AS MonitoringServer,

        DB_NAME() AS MonitoringDatabase,

        'FAILED' AS DeploymentStatus,

        ERROR_NUMBER() AS ErrorNumber,

        ERROR_LINE() AS ErrorLine,

        ERROR_MESSAGE() AS ErrorMessage,

        SYSUTCDATETIME() AS ErrorDateUTC;

    THROW;

END CATCH;

------------------------------------------------------------
-- SECTION 9: Retention Object Verification
------------------------------------------------------------

SELECT
    S.name AS SchemaName,

    O.name AS ObjectName,

    O.type_desc AS ObjectType,

    O.create_date AS CreatedDate,

    O.modify_date AS ModifiedDate

FROM sys.objects AS O

INNER JOIN sys.schemas AS S

    ON O.schema_id = S.schema_id

WHERE S.name = 'dbo'

AND O.name IN
(
    'RetentionExecutionLog',

    'usp_DataRetentionPreview',

    'usp_ExecuteDataRetention',

    'usp_DataRetentionSummary'
)

ORDER BY
    O.type_desc,
    O.name;

------------------------------------------------------------
-- SECTION 10: Retention Configuration Verification
------------------------------------------------------------

SELECT
    SettingKey,

    SettingValue,

    SettingDataType,

    Description

FROM dbo.MonitoringSettings

WHERE SettingKey LIKE '%Retention%'

ORDER BY SettingKey;

GO
