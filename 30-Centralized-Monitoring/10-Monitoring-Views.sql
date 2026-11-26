/*
============================================================
Project : SQL Server Production Optimization
Module  : 30 - Centralized Monitoring
Script  : 10-Monitoring-Views.sql
Purpose : Centralized monitoring and reporting views
Type    : Central Repository Deployment
Impact  : Central DBA_Monitoring database only
Version : 1.0
============================================================

IMPORTANT:

1. Execute ONLY on the approved central monitoring instance.
2. Execute after 09-Data-Retention.sql.
3. Do NOT execute on monitored production instances.
4. Deployment is disabled by default.
5. Views retrieve data from the central repository only.
6. Existing inventory application remains unchanged.
7. Collection success does not mean resource health.

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

    @DeploymentStart DATETIME2(3) =
        SYSUTCDATETIME(),

    @ViewName SYSNAME,

    @CollectorCode VARCHAR(30),

    @SourceView SYSNAME,

    @SQL NVARCHAR(MAX),

    @ViewsDeployed INT = 0;

SET @ActualServer =
    CONVERT(NVARCHAR(128), SERVERPROPERTY('ServerName'));

------------------------------------------------------------
-- SECTION 2: Deployment Safety Validation
------------------------------------------------------------

IF ISNULL(@AllowDeployment, 0) <> 1
    THROW 50001, 'Deployment disabled.', 1;

IF NULLIF
(
    LTRIM(RTRIM(@ApprovedMonitoringServer)),
    N''
) IS NULL
OR @ApprovedMonitoringServer =
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
IF (@@OPTIONS & 2) = 2
    THROW 50013,
        'Implicit transactions must be disabled.',
        1;

------------------------------------------------------------
-- SECTION 3: Repository Validation
------------------------------------------------------------

IF OBJECT_ID('dbo.MonitoredInstances', 'U') IS NULL
OR OBJECT_ID('dbo.Collectors', 'U') IS NULL
OR OBJECT_ID('dbo.InstanceCollectors', 'U') IS NULL
OR OBJECT_ID('dbo.MetricDefinitions', 'U') IS NULL
OR OBJECT_ID('dbo.MonitoredResources', 'U') IS NULL
OR OBJECT_ID('dbo.CollectionRuns', 'U') IS NULL
OR OBJECT_ID('dbo.LatestMetrics', 'U') IS NULL
OR OBJECT_ID('dbo.MetricSamples', 'U') IS NULL
OR OBJECT_ID('dbo.MetricHourlyAggregates', 'U') IS NULL
OR OBJECT_ID('dbo.MetricCounterBaselines', 'U') IS NULL
OR OBJECT_ID('dbo.MetricEventRegistry', 'U') IS NULL
OR OBJECT_ID('dbo.CollectionCheckpoints', 'U') IS NULL
OR OBJECT_ID('dbo.MonitoringSettings', 'U') IS NULL
OR OBJECT_ID('dbo.RetentionExecutionLog', 'U') IS NULL
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
        'Required historical metric columns are missing.',
        1;
END;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.SchemaVersion
    WHERE VersionNumber = '1.0.5'
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
-- SECTION 4: View Deployment Tracking
------------------------------------------------------------

DECLARE @DeploymentResults TABLE
(
    ViewName SYSNAME PRIMARY KEY,
    DeploymentStatus VARCHAR(30)
);

DECLARE @CollectorViews TABLE
(
    ViewName SYSNAME PRIMARY KEY,
    CollectorCode VARCHAR(30) NOT NULL,
    SourceView SYSNAME NOT NULL
);

------------------------------------------------------------
-- SECTION 5: Begin Transactional Deployment
------------------------------------------------------------

BEGIN TRY

    BEGIN TRANSACTION;

    --------------------------------------------------------
    -- VIEW 01: Collector Scheduling and Eligibility
    --------------------------------------------------------

    EXEC sys.sp_executesql N'

    CREATE OR ALTER VIEW dbo.vw_CollectionSchedule
    AS

    WITH Settings AS
    (
        SELECT

            MAX
            (
                CASE
                    WHEN SettingKey = ''MonitoringEnabled''
                    THEN SettingValue
                END
            ) AS MonitoringEnabled,

            MAX
            (
                CASE
                    WHEN SettingKey =
                        ''ProductionCollectionEnabled''
                    THEN SettingValue
                END
            ) AS ProductionEnabled,

            MAX
            (
                CASE
                    WHEN SettingKey = ''PilotModeEnabled''
                    THEN SettingValue
                END
            ) AS PilotModeEnabled

        FROM dbo.MonitoringSettings
    ),
    Schedule AS
    (
        SELECT

            I.InstanceID,

            I.InstanceName,

            I.Environment,

            I.SQLMajorVersion,

            I.IsEnabled AS InstanceEnabled,

            I.IsPilotInstance,

            C.CollectorID,

            C.CollectorCode,

            C.CollectorName,

            C.ScriptFileName,

            C.ScriptVersion,

            C.CollectionType,

            C.IsEnabled AS CollectorEnabled,

            IC.IsEnabled AS AssignmentEnabled,

            C.ExecutionPriority,

            C.MaximumOutputRows,

            COALESCE
            (
                IC.IntervalOverrideSeconds,
                C.DefaultIntervalSeconds
            ) AS EffectiveIntervalSeconds,

            COALESCE
            (
                IC.TimeoutOverrideSeconds,
                C.DefaultTimeoutSeconds
            ) AS EffectiveTimeoutSeconds,

            IC.NextRunDateUTC,

            IC.LastAttemptDateUTC,

            IC.LastSuccessDateUTC,

            IC.ConsecutiveFailures,

            CASE

                WHEN I.IsEnabled = 0
                  OR C.IsEnabled = 0
                  OR IC.IsEnabled = 0

                    THEN ''DISABLED''

                WHEN ISNULL(S.MonitoringEnabled, N''0'')
                    <> N''1''

                    THEN ''PAUSED''

                WHEN I.Environment IN
                    (''PRODUCTION'', ''DR'')

                 AND ISNULL(S.ProductionEnabled, N''0'')
                     <> N''1''

                    THEN ''PRODUCTION PAUSED''

                WHEN ISNULL(S.PilotModeEnabled, N''1'')
                     <> N''0''

                 AND I.IsPilotInstance = 0

                    THEN ''PILOT EXCLUDED''

                WHEN I.SQLMajorVersion IS NULL

                    THEN ''VALIDATION REQUIRED''

                WHEN I.SQLMajorVersion <
                     C.MinimumSQLMajorVersion

                    THEN ''INCOMPATIBLE''

                WHEN EXISTS
                (
                    SELECT 1

                    FROM dbo.CollectionRuns AS R

                    WHERE R.InstanceID = IC.InstanceID

                      AND R.CollectorID = IC.CollectorID

                      AND R.RunStatus = ''RUNNING''
                )

                    THEN ''RUNNING''

                WHEN IC.NextRunDateUTC IS NULL

                    THEN ''DUE''

                WHEN IC.NextRunDateUTC <=
                     SYSUTCDATETIME()

                    THEN ''DUE''

                ELSE ''SCHEDULED''

            END AS ScheduleStatus

        FROM dbo.InstanceCollectors AS IC

        INNER JOIN dbo.MonitoredInstances AS I
            ON IC.InstanceID = I.InstanceID

        INNER JOIN dbo.Collectors AS C
            ON IC.CollectorID = C.CollectorID

        CROSS JOIN Settings AS S
    )

    SELECT

        Schedule.*,

        CONVERT
        (
            BIT,

            CASE
                WHEN ScheduleStatus = ''DUE''
                THEN 1
                ELSE 0
            END

        ) AS IsDueCandidate

    FROM Schedule;

    ';

    INSERT INTO @DeploymentResults
    VALUES ('vw_CollectionSchedule', 'DEPLOYED');

    --------------------------------------------------------
    -- VIEW 02: Collection Health
    --------------------------------------------------------

    EXEC sys.sp_executesql N'

    CREATE OR ALTER VIEW dbo.vw_CollectionHealth
    AS

    SELECT

        S.InstanceID,

        S.InstanceName,

        S.Environment,

        S.CollectorID,

        S.CollectorCode,

        S.CollectorName,

        S.EffectiveIntervalSeconds,

        S.EffectiveTimeoutSeconds,

        S.LastAttemptDateUTC,

        S.LastSuccessDateUTC,

        S.NextRunDateUTC,

        S.ConsecutiveFailures,

        S.ScheduleStatus,

        R.CollectionRunID AS LastCollectionRunID,

        R.RunStatus AS LastRunStatus,

        R.StartDateUTC AS LastRunStartUTC,

        R.EndDateUTC AS LastRunEndUTC,

        R.DurationMilliseconds,

        R.RowsReturned,

        R.RowsStored,

        R.ErrorNumber,

        DATEDIFF_BIG
        (
            SECOND,
            S.LastSuccessDateUTC,
            SYSUTCDATETIME()
        ) AS SecondsSinceLastSuccess,

        CASE

            WHEN S.ScheduleStatus NOT IN
            (
                ''DUE'',
                ''SCHEDULED'',
                ''RUNNING''
            )

                THEN S.ScheduleStatus

            WHEN R.RunStatus = ''RUNNING''

             AND DATEDIFF_BIG
                 (
                     SECOND,
                     R.StartDateUTC,
                     SYSUTCDATETIME()
                 ) >
                 CONVERT
                 (
                     BIGINT,
                     S.EffectiveTimeoutSeconds
                 ) + 60

                THEN ''RUN OVERDUE''

            WHEN R.RunStatus = ''RUNNING''

                THEN ''RUNNING''

            WHEN R.RunStatus IN
            (
                ''FAILED'',
                ''TIMEOUT'',
                ''PARTIAL''
            )

                THEN ''COLLECTION ISSUES''

            WHEN S.LastSuccessDateUTC IS NULL

                THEN ''NOT YET COLLECTED''

            WHEN DATEDIFF_BIG
            (
                SECOND,
                S.LastSuccessDateUTC,
                SYSUTCDATETIME()
            ) >
            CONVERT
            (
                BIGINT,
                S.EffectiveIntervalSeconds
            ) * 3

                THEN ''STALE''

            WHEN R.RunStatus IN
            (
                ''CANCELLED'',
                ''SKIPPED''
            )

                THEN ''REVIEW REQUIRED''

            ELSE ''CURRENT''

        END AS CollectionHealthStatus

    FROM dbo.vw_CollectionSchedule AS S

    OUTER APPLY
    (
        SELECT TOP (1)

            CR.CollectionRunID,

            CR.RunStatus,

            CR.StartDateUTC,

            CR.EndDateUTC,

            CR.DurationMilliseconds,

            CR.RowsReturned,

            CR.RowsStored,

            CR.ErrorNumber

        FROM dbo.CollectionRuns AS CR

        WHERE CR.InstanceID = S.InstanceID

          AND CR.CollectorID = S.CollectorID

        ORDER BY
            CR.StartDateUTC DESC,
            CR.CollectionRunID DESC

    ) AS R;

    ';

    INSERT INTO @DeploymentResults
    VALUES ('vw_CollectionHealth', 'DEPLOYED');

    --------------------------------------------------------
    -- VIEW 03: Instance Monitoring Overview
    --------------------------------------------------------

    EXEC sys.sp_executesql N'

    CREATE OR ALTER VIEW dbo.vw_InstanceOverview
    AS

    SELECT

        I.InstanceID,

        I.InstanceName,

        I.ServerName,

        I.Environment,

        I.SQLVersion,

        I.SQLMajorVersion,

        I.SQLEdition,

        I.TimeZoneName,

        I.IsEnabled,

        I.IsPilotInstance,

        COALESCE(A.AssignedCollectors, 0)
            AS AssignedCollectors,

        COALESCE(A.CurrentCollectors, 0)
            AS CurrentCollectors,

        COALESCE(A.IssueCollectors, 0)
            AS IssueCollectors,

        COALESCE(A.StaleCollectors, 0)
            AS StaleCollectors,

        COALESCE(A.DisabledCollectors, 0)
            AS DisabledCollectors,

        A.LastSuccessfulCollectionUTC,

        CASE

            WHEN I.IsEnabled = 0

                THEN ''DISABLED''

            WHEN COALESCE(A.AssignedCollectors, 0) = 0

                THEN ''NOT CONFIGURED''

            WHEN COALESCE(A.IssueCollectors, 0) > 0

                THEN ''COLLECTION ISSUES''

            WHEN COALESCE(A.StaleCollectors, 0) > 0

                THEN ''STALE DATA''

            WHEN COALESCE(A.CurrentCollectors, 0) = 0

                THEN ''NO CURRENT COVERAGE''

            WHEN A.CurrentCollectors <
                 A.AssignedCollectors

                THEN ''PARTIAL COVERAGE''

            ELSE ''CURRENT COVERAGE''

        END AS MonitoringCoverageStatus

    FROM dbo.MonitoredInstances AS I

    LEFT JOIN
    (
        SELECT

            InstanceID,

            COUNT_BIG(*) AS AssignedCollectors,

            COUNT_BIG
            (
                CASE
                    WHEN CollectionHealthStatus =
                         ''CURRENT''
                    THEN 1
                END
            ) AS CurrentCollectors,

            COUNT_BIG
            (
                CASE
                    WHEN CollectionHealthStatus IN
                    (
                        ''COLLECTION ISSUES'',
                        ''RUN OVERDUE'',
                        ''REVIEW REQUIRED''
                    )
                    THEN 1
                END
            ) AS IssueCollectors,

            COUNT_BIG
            (
                CASE
                    WHEN CollectionHealthStatus =
                         ''STALE''
                    THEN 1
                END
            ) AS StaleCollectors,

            COUNT_BIG
            (
                CASE
                    WHEN CollectionHealthStatus =
                         ''DISABLED''
                    THEN 1
                END
            ) AS DisabledCollectors,

            MAX(LastSuccessDateUTC)
                AS LastSuccessfulCollectionUTC

        FROM dbo.vw_CollectionHealth

        GROUP BY InstanceID

    ) AS A

        ON I.InstanceID = A.InstanceID;

    ';

    INSERT INTO @DeploymentResults
    VALUES ('vw_InstanceOverview', 'DEPLOYED');

    --------------------------------------------------------
    -- VIEW 04: Latest Centralized Metrics
    --------------------------------------------------------

    EXEC sys.sp_executesql N'

    CREATE OR ALTER VIEW dbo.vw_LatestMetrics
    AS

    SELECT

        L.InstanceID,

        I.InstanceName,

        I.Environment,

        C.CollectorID,

        C.CollectorCode,

        C.CollectorName,

        D.MetricDefinitionID,

        D.MetricID,

        D.MetricName,

        D.Category,

        D.MetricBehavior,

        D.StoragePolicy,

        R.ResourceID,

        R.ResourceType,

        R.ResourceName,

        R.DisplayName,

        R.IsActive AS ResourceActive,

        R.LastSeenDateUTC AS ResourceLastSeenUTC,

        L.CollectionRunID,

        L.CaptureDateUTC,

        L.MetricValue,

        L.MetricUnit,

        L.CollectionStatus,

        L.LastSuccessfulCaptureUTC,

        L.LastSuccessfulValue,

        L.LastSuccessfulUnit,

        L.UpdatedDateUTC,

        H.EffectiveIntervalSeconds,

        H.CollectionHealthStatus,

        H.LastRunStatus,

        H.LastCollectionRunID,

        DATEDIFF_BIG
        (
            SECOND,
            L.CaptureDateUTC,
            SYSUTCDATETIME()
        ) AS MetricAgeSeconds,

        CASE

            WHEN D.IsEnabled = 0
                THEN ''DISABLED''

            WHEN R.IsActive = 0
                THEN ''INACTIVE RESOURCE''

            WHEN H.InstanceID IS NULL
                THEN ''UNASSIGNED''

            WHEN H.ScheduleStatus NOT IN
            (
                ''DUE'',
                ''SCHEDULED'',
                ''RUNNING''
            )

                THEN H.ScheduleStatus

            WHEN H.CollectionHealthStatus IN
            (
                ''COLLECTION ISSUES'',
                ''RUN OVERDUE'',
                ''REVIEW REQUIRED''
            )

                THEN ''COLLECTION ISSUES''
----------------------------------------------------
-- Prevent previous collection observations
-- from appearing as current transient resources
----------------------------------------------------

WHEN C.CollectorCode IN (''COL-09'', ''COL-15'')

 AND H.LastRunStatus = ''SUCCESS''

 AND L.CollectionRunID <> H.LastCollectionRunID

    THEN ''NOT IN LATEST SNAPSHOT''
            WHEN L.CollectionStatus <> ''SUCCESS''

                THEN L.CollectionStatus
        WHEN H.CollectionHealthStatus = ''STALE''

    THEN ''STALE''

            WHEN L.CaptureDateUTC >
                 DATEADD
                 (
                     MINUTE,
                     5,
                     SYSUTCDATETIME()
                 )

                THEN ''CLOCK SKEW''

            WHEN DATEDIFF_BIG
            (
                SECOND,
                L.CaptureDateUTC,
                SYSUTCDATETIME()
            ) >
            CONVERT
            (
                BIGINT,
                H.EffectiveIntervalSeconds
            ) * 3

                THEN ''STALE''

            ELSE ''CURRENT''

        END AS DataFreshnessStatus

    FROM dbo.LatestMetrics AS L

    INNER JOIN dbo.MonitoredInstances AS I
        ON L.InstanceID = I.InstanceID

    INNER JOIN dbo.MonitoredResources AS R
        ON L.InstanceID = R.InstanceID
       AND L.ResourceID = R.ResourceID

    INNER JOIN dbo.MetricDefinitions AS D
        ON L.MetricDefinitionID =
           D.MetricDefinitionID

    INNER JOIN dbo.Collectors AS C
        ON D.CollectorID = C.CollectorID

    LEFT JOIN dbo.vw_CollectionHealth AS H
        ON L.InstanceID = H.InstanceID
       AND C.CollectorID = H.CollectorID;

    ';

    INSERT INTO @DeploymentResults
    VALUES ('vw_LatestMetrics', 'DEPLOYED');

    --------------------------------------------------------
    -- VIEW 05: Internal Historical Reporting View
    --------------------------------------------------------

    /*
    Shared historical reporting source.

    This supporting view is used by event and cumulative
    collector views to avoid duplicating large joins.

    Historical queries must always use bounded date ranges.
    */

    EXEC sys.sp_executesql N'

    CREATE OR ALTER VIEW dbo.vw_HistoricalMetricSamples
    AS

    SELECT

        S.SampleID,

        S.CollectionRunID,

        S.InstanceID,

        I.InstanceName,

        I.Environment,

        C.CollectorCode,

        C.CollectorName,

        D.MetricDefinitionID,

        D.MetricID,

        D.MetricName,

        D.Category,

        D.MetricBehavior,

        R.ResourceID,

        R.ResourceType,

        R.ResourceName,

        R.DisplayName,

        S.CaptureDateUTC,

        S.IntervalStartUTC,

        CASE

            WHEN S.IntervalStartUTC IS NOT NULL

            THEN DATEDIFF_BIG
            (
                MILLISECOND,
                S.IntervalStartUTC,
                S.CaptureDateUTC
            )

        END AS SampleIntervalMilliseconds,

        S.MetricValue,

        S.MetricUnit,

        S.CollectionStatus,

        S.SampleKind,

        S.InsertedDateUTC

    FROM dbo.MetricSamples AS S

    INNER JOIN dbo.MonitoredInstances AS I
        ON S.InstanceID = I.InstanceID

    INNER JOIN dbo.MonitoredResources AS R
        ON S.InstanceID = R.InstanceID
       AND S.ResourceID = R.ResourceID

    INNER JOIN dbo.MetricDefinitions AS D
        ON S.MetricDefinitionID =
           D.MetricDefinitionID

    INNER JOIN dbo.Collectors AS C
        ON D.CollectorID = C.CollectorID;

    ';

    INSERT INTO @DeploymentResults
    VALUES ('vw_HistoricalMetricSamples', 'DEPLOYED');

    --------------------------------------------------------
    -- SECTION 6: Collector-Specific View Definitions
    --------------------------------------------------------

    INSERT INTO @CollectorViews
    (
        ViewName,
        CollectorCode,
        SourceView
    )
    VALUES

    (
        'vw_InstanceHealth',
        'COL-01',
        'vw_LatestMetrics'
    ),
    (
        'vw_DatabaseHealth',
        'COL-02',
        'vw_LatestMetrics'
    ),
    (
        'vw_CPUHealth',
        'COL-03',
        'vw_LatestMetrics'
    ),
    (
        'vw_MemoryHealth',
        'COL-04',
        'vw_LatestMetrics'
    ),
    (
        'vw_StorageHealth',
        'COL-05',
        'vw_LatestMetrics'
    ),
    (
        'vw_BackupHealth',
        'COL-06',
        'vw_LatestMetrics'
    ),
    (
        'vw_HAHealth',
        'COL-07',
        'vw_LatestMetrics'
    ),
    (
        'vw_SQLAgentHealth',
        'COL-08',
        'vw_LatestMetrics'
    ),
    (
        'vw_BlockingHealth',
        'COL-09',
        'vw_LatestMetrics'
    ),
    (
        'vw_TransactionLogHealth',
        'COL-10',
        'vw_LatestMetrics'
    ),
    (
        'vw_DeadlockHistory',
        'COL-11',
        'vw_HistoricalMetricSamples'
    ),
    (
        'vw_ErrorLogHealth',
        'COL-12',
        'vw_LatestMetrics'
    ),
    (
        'vw_WaitStatistics',
        'COL-13',
        'vw_HistoricalMetricSamples'
    ),
    (
        'vw_TempDBHealth',
        'COL-14',
        'vw_LatestMetrics'
    ),
    (
        'vw_QueryPerformance',
        'COL-15',
        'vw_LatestMetrics'
    ),
    (
        'vw_SQLAgentHistory',
        'COL-16',
        'vw_HistoricalMetricSamples'
    );

    --------------------------------------------------------
    -- SECTION 7: Deploy All Collector-Specific Views
    --------------------------------------------------------

    /*
    All object names originate from the fixed internal
    configuration above.

    No external user input is accepted for dynamic SQL.
    */

    WHILE EXISTS
    (
        SELECT 1
        FROM @CollectorViews
    )
    BEGIN

        SELECT TOP (1)

            @ViewName = ViewName,

            @CollectorCode = CollectorCode,

            @SourceView = SourceView

        FROM @CollectorViews

        ORDER BY CollectorCode;

        SET @SQL =

            N'CREATE OR ALTER VIEW dbo.' +

            QUOTENAME(@ViewName) +

            N' AS
            SELECT V.*
            FROM dbo.' +

            QUOTENAME(@SourceView) +

            N' AS V
            WHERE V.CollectorCode = ' +

            QUOTENAME(@CollectorCode, '''');

        ----------------------------------------------------
        -- Only return deduplicated event observations
        ----------------------------------------------------

        IF @CollectorCode IN ('COL-11', 'COL-16')
        BEGIN

            SET @SQL +=

                N' AND V.SampleKind = ''EVENT''
                   AND V.CollectionStatus = ''SUCCESS''';

        END;

        ----------------------------------------------------
        -- Only return valid cumulative wait deltas
        ----------------------------------------------------

        IF @CollectorCode = 'COL-13'
        BEGIN

            SET @SQL +=

                N' AND V.SampleKind = ''DELTA''
                   AND V.CollectionStatus = ''SUCCESS''
                   AND V.IntervalStartUTC IS NOT NULL
                   AND V.SampleIntervalMilliseconds > 0';

        END;

        SET @SQL += N';';

        EXEC sys.sp_executesql @SQL;

        INSERT INTO @DeploymentResults
        VALUES (@ViewName, 'DEPLOYED');

        DELETE FROM @CollectorViews
        WHERE ViewName = @ViewName;

    END;

    --------------------------------------------------------
    -- VIEW 22: Hourly Performance Trends
    --------------------------------------------------------

    EXEC sys.sp_executesql N'

    CREATE OR ALTER VIEW dbo.vw_HourlyPerformance
    AS

    SELECT

        A.HourStartUTC,

        DATEADD
        (
            HOUR,
            1,
            A.HourStartUTC
        ) AS HourEndUTC,

        A.InstanceID,

        I.InstanceName,

        I.Environment,

        C.CollectorCode,

        C.CollectorName,

        D.MetricID,

        D.MetricName,

        D.MetricBehavior,

        R.ResourceID,

        R.ResourceType,

        R.ResourceName,

        A.MetricUnit,

        A.AggregationType,

        A.SampleCount,

        A.MinimumValue,

        A.MaximumValue,

        A.AverageValue,

        CASE

            WHEN A.AggregationType = ''DELTA''

                THEN A.SumValue

        END AS TotalIntervalDelta,

        A.FirstCaptureDateUTC,

        A.LastCaptureDateUTC,

        A.AggregatedDateUTC

    FROM dbo.MetricHourlyAggregates AS A

    INNER JOIN dbo.MonitoredInstances AS I
        ON A.InstanceID = I.InstanceID

    INNER JOIN dbo.MonitoredResources AS R
        ON A.InstanceID = R.InstanceID
       AND A.ResourceID = R.ResourceID

    INNER JOIN dbo.MetricDefinitions AS D
        ON A.MetricDefinitionID =
           D.MetricDefinitionID

    INNER JOIN dbo.Collectors AS C
        ON D.CollectorID = C.CollectorID;

    ';

    INSERT INTO @DeploymentResults
    VALUES ('vw_HourlyPerformance', 'DEPLOYED');

    --------------------------------------------------------
    -- VIEW 23: Central Repository Health
    --------------------------------------------------------

    EXEC sys.sp_executesql N'

    CREATE OR ALTER VIEW dbo.vw_RepositoryHealth
    AS

    SELECT

        CONVERT
        (
            NVARCHAR(128),
            SERVERPROPERTY(''ServerName'')
        ) AS RepositoryServer,

        DB_NAME() AS RepositoryDatabase,

        S.name AS SchemaName,

        T.name AS TableName,

        SUM
        (
            CASE

                WHEN P.index_id IN (0,1)

                THEN P.row_count

                ELSE 0

            END
        ) AS TableRows,

        CONVERT
        (
            DECIMAL(18,2),

            SUM(P.reserved_page_count) / 128.0

        ) AS ReservedSpaceMB,

        CONVERT
        (
            DECIMAL(18,2),

            SUM(P.used_page_count) / 128.0

        ) AS UsedSpaceMB,

        SYSUTCDATETIME() AS CaptureDateUTC

    FROM sys.dm_db_partition_stats AS P

    INNER JOIN sys.tables AS T
        ON P.object_id = T.object_id

    INNER JOIN sys.schemas AS S
        ON T.schema_id = S.schema_id

    WHERE S.name = ''dbo''

      AND T.name IN
      (
          ''MonitoredInstances'',
          ''Collectors'',
          ''InstanceCollectors'',
          ''MetricDefinitions'',
          ''MonitoredResources'',
          ''CollectionRuns'',
          ''MetricSamples'',
          ''LatestMetrics'',
          ''CollectionCheckpoints'',
          ''MonitoringSettings'',
          ''SchemaVersion'',
          ''CheckpointAudit'',
          ''MetricCounterBaselines'',
          ''MetricEventRegistry'',
          ''MetricHourlyAggregates'',
          ''RetentionExecutionLog''
      )

    GROUP BY
        S.name,
        T.name;

    ';

    INSERT INTO @DeploymentResults
    VALUES ('vw_RepositoryHealth', 'DEPLOYED');

    --------------------------------------------------------
    -- SECTION 8: Deployment Count Validation
    --------------------------------------------------------

    SELECT
        @ViewsDeployed = COUNT(*)

    FROM @DeploymentResults;

    IF @ViewsDeployed <> 23
    BEGIN

        THROW 50013,
            'Unexpected number of deployed monitoring views.',
            1;

    END;

    --------------------------------------------------------
    -- SECTION 9: Register Schema Version
    --------------------------------------------------------

    IF NOT EXISTS
    (
        SELECT 1

        FROM dbo.SchemaVersion

        WHERE VersionNumber = '1.0.6'
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
            '1.0.6',

            N'10-Monitoring-Views.sql',

            ORIGINAL_LOGIN(),

            N'Central monitoring reporting views,
              collection health, scheduling, metric
              freshness and historical analysis.'
        );

    END;

    --------------------------------------------------------
    -- SECTION 10: Commit Deployment
    --------------------------------------------------------

    COMMIT TRANSACTION;

    SELECT

        @ActualServer AS MonitoringServer,

        DB_NAME() AS MonitoringDatabase,

        'SUCCESS' AS DeploymentStatus,

        @ViewsDeployed AS ViewsDeployed,

        '1.0.6' AS SchemaVersion,

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
-- SECTION 11: View Deployment Verification
------------------------------------------------------------

SELECT

    D.ViewName,

    D.DeploymentStatus,

    V.create_date AS CreatedDate,

    V.modify_date AS ModifiedDate

FROM @DeploymentResults AS D

LEFT JOIN sys.views AS V
    ON V.name = D.ViewName
   AND V.schema_id = SCHEMA_ID('dbo')

ORDER BY D.ViewName;

------------------------------------------------------------
-- SECTION 12: Repository Version Verification
------------------------------------------------------------

SELECT

    VersionNumber,

    ScriptName,

    AppliedDateUTC,

    AppliedBy,

    Description

FROM dbo.SchemaVersion

ORDER BY SchemaVersionID;

GO
