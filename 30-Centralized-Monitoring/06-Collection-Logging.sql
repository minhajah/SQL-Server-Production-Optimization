/*
============================================================
Project : SQL Server Production Optimization
Module  : 30 - Centralized Monitoring
Script  : 06-Collection-Logging.sql
Purpose : Track collector execution and monitoring health
Type    : Central Repository Deployment
Impact  : Creates stored procedures in DBA_Monitoring only
Version : 1.0
============================================================

IMPORTANT:

1. Execute ONLY on the approved central monitoring instance.
2. Execute after 05-Register-Collectors.sql.
3. Do NOT execute on monitored production instances.
4. Deployment is disabled by default.
5. No remote connections are established by this script.
6. Existing inventory application remains unchanged.

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
BEGIN
    THROW 50001,
        'Deployment disabled. Review deployment parameters.',
        1;
END;

IF @ApprovedMonitoringServer =
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
-- SECTION 3: Repository Validation
------------------------------------------------------------

IF OBJECT_ID('dbo.MonitoredInstances', 'U') IS NULL
OR OBJECT_ID('dbo.Collectors', 'U') IS NULL
OR OBJECT_ID('dbo.InstanceCollectors', 'U') IS NULL
OR OBJECT_ID('dbo.CollectionRuns', 'U') IS NULL
OR OBJECT_ID('dbo.MonitoringSettings', 'U') IS NULL
OR OBJECT_ID('dbo.SchemaVersion', 'U') IS NULL
BEGIN
    THROW 50008,
        'Required monitoring repository tables are missing.',
        1;
END;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.SchemaVersion
    WHERE VersionNumber = '1.0.1'
)
BEGIN
    THROW 50009,
        'Required repository schema version not found.',
        1;
END;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.MonitoringSettings
    WHERE SettingKey = 'MonitoringEnabled'
      AND SettingValue = N'0'
)
BEGIN
    THROW 50010,
        'Monitoring must be disabled before deployment.',
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
        'Active collection runs exist.',
        1;
END;

------------------------------------------------------------
-- SECTION 4: Stored Procedure Deployment
------------------------------------------------------------

BEGIN TRY

    BEGIN TRANSACTION;

    --------------------------------------------------------
    -- PROCEDURE 01: Collection Run Start
    --------------------------------------------------------

    EXEC sys.sp_executesql N'

    CREATE OR ALTER PROCEDURE dbo.usp_CollectionRunStart
    (
        @InstanceID INT,
        @CollectorID INT,
        @RunToken UNIQUEIDENTIFIER,
        @CollectionRunID BIGINT OUTPUT
    )
    AS
    BEGIN

        SET NOCOUNT ON;
        SET XACT_ABORT ON;

        DECLARE
            @CurrentUTC DATETIME2(3),
            @LockResult INT,
            @ExistingInstanceID INT,
            @ExistingCollectorID INT,
            @GlobalLimit INT,
            @InstanceLimit INT,
            @CollectorVersion VARCHAR(20);

        SET @CollectionRunID = NULL;

        IF @RunToken IS NULL
        BEGIN
            THROW 50101,
                ''A unique run token is required.'',
                1;
        END;

        IF @@TRANCOUNT <> 0
        BEGIN
            THROW 50102,
                ''Start procedure requires an independent transaction.'',
                1;
        END;

        BEGIN TRY

            BEGIN TRANSACTION;

            ------------------------------------------------
            -- Serialize collection reservations
            ------------------------------------------------

            EXEC @LockResult = sys.sp_getapplock
                @Resource = N''DBA_Monitoring.CollectionScheduling'',
                @LockMode = ''Exclusive'',
                @LockOwner = ''Transaction'',
                @LockTimeout = 5000;

            IF @LockResult < 0
            BEGIN
                THROW 50103,
                    ''Unable to acquire scheduling lock.'',
                    1;
            END;

            SET @CurrentUTC = SYSUTCDATETIME();

            ------------------------------------------------
            -- Idempotent run token validation
            ------------------------------------------------

            SELECT
                @CollectionRunID = CollectionRunID,
                @ExistingInstanceID = InstanceID,
                @ExistingCollectorID = CollectorID

            FROM dbo.CollectionRuns

            WHERE RunToken = @RunToken;

            IF @CollectionRunID IS NOT NULL
            BEGIN

                IF @ExistingInstanceID <> @InstanceID
                OR @ExistingCollectorID <> @CollectorID
                BEGIN
                    THROW 50104,
                        ''Run token belongs to another assignment.'',
                        1;
                END;

                COMMIT TRANSACTION;

                SELECT
                    @CollectionRunID AS CollectionRunID,
                    @RunToken AS RunToken,
                    ''ALREADY EXISTS'' AS ReservationStatus,
                    CONVERT(BIT, 0) AS ExecuteCollector;

                RETURN;

            END;

            ------------------------------------------------
            -- Global monitoring safety validation
            ------------------------------------------------

            IF NOT EXISTS
            (
                SELECT 1
                FROM dbo.MonitoringSettings
                WHERE SettingKey = ''MonitoringEnabled''
                  AND SettingValue = N''1''
            )
            BEGIN
                THROW 50105,
                    ''Global monitoring is disabled.'',
                    1;
            END;

            ------------------------------------------------
            -- Validate enabled instance and collector
            ------------------------------------------------

            IF NOT EXISTS
            (
                SELECT 1

                FROM dbo.InstanceCollectors AS IC

                INNER JOIN dbo.MonitoredInstances AS I
                    ON IC.InstanceID = I.InstanceID

                INNER JOIN dbo.Collectors AS C
                    ON IC.CollectorID = C.CollectorID

                WHERE IC.InstanceID = @InstanceID
                  AND IC.CollectorID = @CollectorID

                  AND IC.IsEnabled = 1
                  AND I.IsEnabled = 1
                  AND C.IsEnabled = 1

                  AND I.SQLMajorVersion >=
                      C.MinimumSQLMajorVersion
            )
            BEGIN
                THROW 50106,
                    ''Assignment disabled, missing or incompatible.'',
                    1;
            END;

            ------------------------------------------------
            -- Production and DR protection
            ------------------------------------------------

            IF EXISTS
            (
                SELECT 1
                FROM dbo.MonitoredInstances
                WHERE InstanceID = @InstanceID
                  AND Environment IN
                      (''PRODUCTION'', ''DR'')
            )
            AND NOT EXISTS
            (
                SELECT 1
                FROM dbo.MonitoringSettings
                WHERE SettingKey =
                    ''ProductionCollectionEnabled''
                  AND SettingValue = N''1''
            )
            BEGIN
                THROW 50107,
                    ''Production collection is disabled.'',
                    1;
            END;

            ------------------------------------------------
            -- Pilot mode protection
            -- Missing or invalid setting remains restrictive
            ------------------------------------------------

            IF NOT EXISTS
            (
                SELECT 1
                FROM dbo.MonitoringSettings
                WHERE SettingKey = ''PilotModeEnabled''
                  AND SettingValue = N''0''
            )
            AND NOT EXISTS
            (
                SELECT 1
                FROM dbo.MonitoredInstances
                WHERE InstanceID = @InstanceID
                  AND IsPilotInstance = 1
            )
            BEGIN
                THROW 50108,
                    ''Instance is not approved for pilot monitoring.'',
                    1;
            END;

            ------------------------------------------------
            -- Validate collection schedule
            ------------------------------------------------

            IF EXISTS
            (
                SELECT 1
                FROM dbo.InstanceCollectors
                WHERE InstanceID = @InstanceID
                  AND CollectorID = @CollectorID
                  AND NextRunDateUTC > @CurrentUTC
            )
            BEGIN
                THROW 50109,
                    ''Collector is not yet due for execution.'',
                    1;
            END;

            ------------------------------------------------
            -- Prevent duplicate concurrent execution
            ------------------------------------------------

            IF EXISTS
            (
                SELECT 1
                FROM dbo.CollectionRuns
                WHERE InstanceID = @InstanceID
                  AND CollectorID = @CollectorID
                  AND RunStatus = ''RUNNING''
            )
            BEGIN
                THROW 50110,
                    ''Collector already running for this instance.'',
                    1;
            END;

            ------------------------------------------------
            -- Retrieve concurrency limits
            ------------------------------------------------

            SELECT
                @GlobalLimit =
                    TRY_CONVERT(INT, SettingValue)

            FROM dbo.MonitoringSettings

            WHERE SettingKey =
                ''MaximumConcurrentConnections'';

            SELECT
                @InstanceLimit =
                    TRY_CONVERT(INT, SettingValue)

            FROM dbo.MonitoringSettings

            WHERE SettingKey =
                ''MaximumCollectorsPerInstance'';

            IF ISNULL(@GlobalLimit, 0) < 1
            OR ISNULL(@InstanceLimit, 0) < 1
            BEGIN
                THROW 50111,
                    ''Invalid monitoring concurrency configuration.'',
                    1;
            END;

            ------------------------------------------------
            -- Enforce global concurrency
            ------------------------------------------------

            IF
            (
                SELECT COUNT_BIG(*)
                FROM dbo.CollectionRuns
                WHERE RunStatus = ''RUNNING''
            ) >= @GlobalLimit
            BEGIN
                THROW 50112,
                    ''Global collection concurrency limit reached.'',
                    1;
            END;

            ------------------------------------------------
            -- Enforce per-instance concurrency
            ------------------------------------------------

            IF
            (
                SELECT COUNT_BIG(*)
                FROM dbo.CollectionRuns
                WHERE InstanceID = @InstanceID
                  AND RunStatus = ''RUNNING''
            ) >= @InstanceLimit
            BEGIN
                THROW 50113,
                    ''Instance collection concurrency limit reached.'',
                    1;
            END;

            SELECT
                @CollectorVersion = ScriptVersion

            FROM dbo.Collectors

            WHERE CollectorID = @CollectorID;

            ------------------------------------------------
            -- Register collection execution
            ------------------------------------------------

            INSERT INTO dbo.CollectionRuns
            (
                RunToken,
                InstanceID,
                CollectorID,
                StartDateUTC,
                RunStatus,
                CollectorVersion
            )
            VALUES
            (
                @RunToken,
                @InstanceID,
                @CollectorID,
                @CurrentUTC,
                ''RUNNING'',
                @CollectorVersion
            );

            SET @CollectionRunID =
                CONVERT(BIGINT, SCOPE_IDENTITY());

            UPDATE dbo.InstanceCollectors

            SET LastAttemptDateUTC = @CurrentUTC,
                ModifiedDateUTC = @CurrentUTC

            WHERE InstanceID = @InstanceID
              AND CollectorID = @CollectorID;

            COMMIT TRANSACTION;

            SELECT
                @CollectionRunID AS CollectionRunID,
                @RunToken AS RunToken,
                ''RESERVED'' AS ReservationStatus,
                CONVERT(BIT, 1) AS ExecuteCollector;

        END TRY

        BEGIN CATCH

            IF XACT_STATE() <> 0
                ROLLBACK TRANSACTION;

            SET @CollectionRunID = NULL;

            THROW;

        END CATCH;

    END;

    ';

    --------------------------------------------------------
    -- PROCEDURE 02: Collection Run Completion
    --------------------------------------------------------

    EXEC sys.sp_executesql N'

    CREATE OR ALTER PROCEDURE dbo.usp_CollectionRunComplete
    (
        @CollectionRunID BIGINT,
        @RunToken UNIQUEIDENTIFIER,
        @RunStatus VARCHAR(20),
        @RowsReturned BIGINT = 0,
        @RowsStored BIGINT = 0,
        @ErrorNumber INT = NULL,
        @ErrorMessage NVARCHAR(2048) = NULL
    )
    AS
    BEGIN

        SET NOCOUNT ON;
        SET XACT_ABORT ON;

        DECLARE
            @InstanceID INT,
            @CollectorID INT,
            @StartDateUTC DATETIME2(3),
            @EndDateUTC DATETIME2(3),
            @ExistingStatus VARCHAR(20),
            @IntervalSeconds INT,
            @NextDelaySeconds INT,
            @ConsecutiveFailures INT,
            @StartedTransaction BIT = 0;

        ----------------------------------------------------
        -- Input validation
        ----------------------------------------------------

        IF @RunStatus IS NULL
        OR @RunStatus NOT IN
        (
            ''SUCCESS'',
            ''PARTIAL'',
            ''FAILED'',
            ''TIMEOUT'',
            ''SKIPPED'',
            ''CANCELLED''
        )
        BEGIN
            THROW 50201,
                ''Invalid collection completion status.'',
                1;
        END;

        IF @RunToken IS NULL
        OR @RowsReturned IS NULL
        OR @RowsStored IS NULL
        OR @RowsReturned < 0
        OR @RowsStored < 0
        OR @RowsStored > @RowsReturned
        BEGIN
            THROW 50202,
                ''Invalid run token or row counts.'',
                1;
        END;

        IF XACT_STATE() = -1
        BEGIN
            THROW 50203,
                ''Caller transaction is not committable.'',
                1;
        END;

        BEGIN TRY

            ------------------------------------------------
            -- Support atomic ingestion and completion
            ------------------------------------------------

            IF @@TRANCOUNT = 0
            BEGIN
                BEGIN TRANSACTION;
                SET @StartedTransaction = 1;
            END;

            SELECT
                @InstanceID = InstanceID,
                @CollectorID = CollectorID,
                @StartDateUTC = StartDateUTC,
                @ExistingStatus = RunStatus

            FROM dbo.CollectionRuns
                WITH (UPDLOCK, HOLDLOCK)

            WHERE CollectionRunID = @CollectionRunID
              AND RunToken = @RunToken;

            IF @InstanceID IS NULL
            BEGIN
                THROW 50204,
                    ''Collection run or token not found.'',
                    1;
            END;

            IF @ExistingStatus <> ''RUNNING''
            BEGIN

                IF @ExistingStatus <> @RunStatus
                BEGIN
                    THROW 50205,
                        ''Collection already finalized with a different status.'',
                        1;
                END;

                IF @StartedTransaction = 1
                    COMMIT TRANSACTION;

                SELECT
                    @CollectionRunID AS CollectionRunID,
                    @ExistingStatus AS RunStatus,
                    ''ALREADY COMPLETED'' AS CompletionStatus;

                RETURN;

            END;

            SET @EndDateUTC = SYSUTCDATETIME();

            IF @EndDateUTC < @StartDateUTC
            BEGIN
                THROW 50206,
                    ''Central server clock moved backwards.'',
                    1;
            END;

            ------------------------------------------------
            -- Retrieve scheduling configuration
            ------------------------------------------------

            SELECT
                @IntervalSeconds =
                    COALESCE
                    (
                        IC.IntervalOverrideSeconds,
                        C.DefaultIntervalSeconds
                    ),

                @ConsecutiveFailures =
                    IC.ConsecutiveFailures

            FROM dbo.InstanceCollectors AS IC
                WITH (UPDLOCK, HOLDLOCK)

            INNER JOIN dbo.Collectors AS C
                ON IC.CollectorID = C.CollectorID

            WHERE IC.InstanceID = @InstanceID
              AND IC.CollectorID = @CollectorID;

            IF ISNULL(@IntervalSeconds, 0) < 1
            BEGIN
                THROW 50207,
                    ''Invalid collection interval.'',
                    1;
            END;

            ------------------------------------------------
            -- Record execution outcome
            ------------------------------------------------

            UPDATE dbo.CollectionRuns

            SET EndDateUTC = @EndDateUTC,

                DurationMilliseconds =
                    DATEDIFF_BIG
                    (
                        MILLISECOND,
                        @StartDateUTC,
                        @EndDateUTC
                    ),

                RunStatus = @RunStatus,
                RowsReturned = @RowsReturned,
                RowsStored = @RowsStored,
                ErrorNumber = @ErrorNumber,
                ErrorMessage = @ErrorMessage

            WHERE CollectionRunID = @CollectionRunID;

            ------------------------------------------------
            -- Failure tracking and retry backoff
            ------------------------------------------------

            IF @RunStatus = ''SUCCESS''
            BEGIN
                SET @ConsecutiveFailures = 0;
            END;

            IF @RunStatus IN
            (
                ''FAILED'',
                ''TIMEOUT'',
                ''PARTIAL''
            )
            BEGIN

                IF @ConsecutiveFailures < 2147483647
                    SET @ConsecutiveFailures += 1;

            END;

            SET @NextDelaySeconds = @IntervalSeconds;

            IF @RunStatus IN
            (
                ''FAILED'',
                ''TIMEOUT'',
                ''PARTIAL''
            )
            BEGIN

                SET @NextDelaySeconds =

                    CASE

                        WHEN @ConsecutiveFailures >= 5
                            THEN 900

                        WHEN @ConsecutiveFailures = 4
                            THEN 600

                        WHEN @ConsecutiveFailures = 3
                            THEN 300

                        WHEN @ConsecutiveFailures = 2
                            THEN 120

                        ELSE 60

                    END;

                IF @NextDelaySeconds < @IntervalSeconds
                    SET @NextDelaySeconds =
                        @IntervalSeconds;

            END;

            ------------------------------------------------
            -- Update next execution schedule
            ------------------------------------------------

            UPDATE dbo.InstanceCollectors

            SET LastSuccessDateUTC =

                    CASE

                        WHEN @RunStatus = ''SUCCESS''
                            THEN @EndDateUTC

                        ELSE LastSuccessDateUTC

                    END,

                NextRunDateUTC =
                    DATEADD
                    (
                        SECOND,
                        @NextDelaySeconds,
                        @EndDateUTC
                    ),

                ConsecutiveFailures =
                    @ConsecutiveFailures,

                ModifiedDateUTC = @EndDateUTC

            WHERE InstanceID = @InstanceID
              AND CollectorID = @CollectorID;

            IF @StartedTransaction = 1
                COMMIT TRANSACTION;

            SELECT
                @CollectionRunID AS CollectionRunID,

                @RunStatus AS RunStatus,

                @RowsReturned AS RowsReturned,

                @RowsStored AS RowsStored,

                @ConsecutiveFailures AS ConsecutiveFailures,

                @NextDelaySeconds AS NextDelaySeconds,

                DATEADD
                (
                    SECOND,
                    @NextDelaySeconds,
                    @EndDateUTC
                ) AS NextRunDateUTC;

        END TRY

        BEGIN CATCH

            IF @StartedTransaction = 1
               AND XACT_STATE() <> 0

                ROLLBACK TRANSACTION;

            /*
            When called inside an ingestion transaction,
            the caller must roll back on any exception.
            */

            THROW;

        END CATCH;

    END;

    ';

    --------------------------------------------------------
    -- PROCEDURE 03: Recover Abandoned Collection Runs
    --------------------------------------------------------

    EXEC sys.sp_executesql N'

    CREATE OR ALTER PROCEDURE dbo.usp_CollectionRunRecover
    (
        @StaleAfterMinutes INT = 30,
        @ConfirmServiceStopped BIT = 0,
        @AllowRecovery BIT = 0
    )
    AS
    BEGIN

        SET NOCOUNT ON;
        SET XACT_ABORT ON;

        DECLARE
            @CurrentUTC DATETIME2(3) =
                SYSUTCDATETIME(),

            @LockResult INT,

            @RecoveredRuns INT = 0;

        DECLARE @Recovered TABLE
        (
            CollectionRunID BIGINT,
            InstanceID INT,
            CollectorID INT
        );

        IF @StaleAfterMinutes IS NULL
        OR @StaleAfterMinutes NOT BETWEEN 5 AND 1440
        BEGIN
            THROW 50301,
                ''Stale run threshold must be between 5 and 1440 minutes.'',
                1;
        END;

        ----------------------------------------------------
        -- Preview abandoned runs by default
        ----------------------------------------------------

        IF ISNULL(@AllowRecovery, 0) <> 1
        BEGIN

            SELECT
                R.CollectionRunID,
                R.InstanceID,
                I.InstanceName,
                R.CollectorID,
                C.CollectorName,
                R.StartDateUTC,
                R.RunStatus,

                DATEDIFF_BIG
                (
                    SECOND,
                    R.StartDateUTC,
                    @CurrentUTC
                ) AS RunningSeconds

            FROM dbo.CollectionRuns AS R

            INNER JOIN dbo.MonitoredInstances AS I
                ON R.InstanceID = I.InstanceID

            INNER JOIN dbo.Collectors AS C
                ON R.CollectorID = C.CollectorID

            WHERE R.RunStatus = ''RUNNING''

              AND R.StartDateUTC <=
                  DATEADD
                  (
                      MINUTE,
                      -@StaleAfterMinutes,
                      @CurrentUTC
                  )

            ORDER BY R.StartDateUTC;

            RETURN;

        END;

        ----------------------------------------------------
        -- Explicit administrative recovery approval
        ----------------------------------------------------

        IF ISNULL(@ConfirmServiceStopped, 0) <> 1
        BEGIN
            THROW 50302,
                ''Stop all monitoring workers before recovery.'',
                1;
        END;

        IF NOT EXISTS
        (
            SELECT 1
            FROM dbo.MonitoringSettings
            WHERE SettingKey = ''MonitoringEnabled''
              AND SettingValue = N''0''
        )
        BEGIN
            THROW 50303,
                ''Monitoring must be disabled before recovery.'',
                1;
        END;

        IF @@TRANCOUNT <> 0
        BEGIN
            THROW 50304,
                ''Recovery requires an independent transaction.'',
                1;
        END;

        BEGIN TRY

            BEGIN TRANSACTION;

            EXEC @LockResult = sys.sp_getapplock
                @Resource = N''DBA_Monitoring.CollectionScheduling'',
                @LockMode = ''Exclusive'',
                @LockOwner = ''Transaction'',
                @LockTimeout = 5000;

            IF @LockResult < 0
            BEGIN
                THROW 50305,
                    ''Unable to acquire scheduling lock.'',
                    1;
            END;

            ------------------------------------------------
            -- Mark confirmed abandoned executions
            ------------------------------------------------

            UPDATE dbo.CollectionRuns

            SET RunStatus = ''CANCELLED'',

                EndDateUTC = @CurrentUTC,

                DurationMilliseconds =
                    DATEDIFF_BIG
                    (
                        MILLISECOND,
                        StartDateUTC,
                        @CurrentUTC
                    ),

                ErrorMessage =
                    N''Abandoned collection recovered administratively.''

            OUTPUT

                inserted.CollectionRunID,
                inserted.InstanceID,
                inserted.CollectorID

            INTO @Recovered
            (
                CollectionRunID,
                InstanceID,
                CollectorID
            )

            WHERE RunStatus = ''RUNNING''

              AND StartDateUTC <=
                  DATEADD
                  (
                      MINUTE,
                      -@StaleAfterMinutes,
                      @CurrentUTC
                  );

            SET @RecoveredRuns = @@ROWCOUNT;

            ------------------------------------------------
            -- Reschedule affected assignments
            ------------------------------------------------

            UPDATE IC

            SET NextRunDateUTC =

                    DATEADD
                    (
                        SECOND,

                        CASE

                            WHEN COALESCE
                            (
                                IC.IntervalOverrideSeconds,
                                C.DefaultIntervalSeconds
                            ) > 300

                            THEN COALESCE
                            (
                                IC.IntervalOverrideSeconds,
                                C.DefaultIntervalSeconds
                            )

                            ELSE 300

                        END,

                        @CurrentUTC
                    ),

                ModifiedDateUTC = @CurrentUTC

            FROM dbo.InstanceCollectors AS IC

            INNER JOIN dbo.Collectors AS C
                ON IC.CollectorID = C.CollectorID

            WHERE EXISTS
            (
                SELECT 1
                FROM @Recovered AS R
                WHERE R.InstanceID = IC.InstanceID
                  AND R.CollectorID = IC.CollectorID
            );

            COMMIT TRANSACTION;

            SELECT
                @RecoveredRuns AS RecoveredRuns,
                @CurrentUTC AS RecoveryDateUTC;

            SELECT
                CollectionRunID,
                InstanceID,
                CollectorID

            FROM @Recovered

            ORDER BY CollectionRunID;

        END TRY

        BEGIN CATCH

            IF XACT_STATE() <> 0
                ROLLBACK TRANSACTION;

            THROW;

        END CATCH;

    END;

    ';

    --------------------------------------------------------
    -- PROCEDURE 04: Monitoring Collection Health Summary
    --------------------------------------------------------

    EXEC sys.sp_executesql N'

    CREATE OR ALTER PROCEDURE dbo.usp_CollectionHealthSummary
    (
        @LookbackHours INT = 24
    )
    AS
    BEGIN

        SET NOCOUNT ON;

        IF @LookbackHours IS NULL
        OR @LookbackHours NOT BETWEEN 1 AND 720
        BEGIN
            THROW 50401,
                ''Lookback must be between 1 and 720 hours.'',
                1;
        END;

        DECLARE
            @CurrentUTC DATETIME2(3) =
                SYSUTCDATETIME(),

            @FromDateUTC DATETIME2(3);

        SET @FromDateUTC =
            DATEADD
            (
                HOUR,
                -@LookbackHours,
                @CurrentUTC
            );

        ----------------------------------------------------
        -- Result 01: Global collection summary
        ----------------------------------------------------

        SELECT

            @FromDateUTC AS FromDateUTC,

            @CurrentUTC AS ToDateUTC,

            COUNT_BIG(*) AS TotalCollectionRuns,

            COUNT_BIG
            (
                CASE
                    WHEN RunStatus = ''SUCCESS''
                    THEN 1
                END
            ) AS SuccessfulRuns,

            COUNT_BIG
            (
                CASE
                    WHEN RunStatus = ''PARTIAL''
                    THEN 1
                END
            ) AS PartialRuns,

            COUNT_BIG
            (
                CASE
                    WHEN RunStatus = ''FAILED''
                    THEN 1
                END
            ) AS FailedRuns,

            COUNT_BIG
            (
                CASE
                    WHEN RunStatus = ''TIMEOUT''
                    THEN 1
                END
            ) AS TimeoutRuns,

            COUNT_BIG
            (
                CASE
                    WHEN RunStatus = ''RUNNING''
                    THEN 1
                END
            ) AS RunningRuns,

            COUNT_BIG
            (
                CASE
                    WHEN RunStatus = ''SKIPPED''
                    THEN 1
                END
            ) AS SkippedRuns,

            COUNT_BIG
            (
                CASE
                    WHEN RunStatus = ''CANCELLED''
                    THEN 1
                END
            ) AS CancelledRuns,

            CONVERT
            (
                DECIMAL(10,2),

                COUNT_BIG
                (
                    CASE
                        WHEN RunStatus = ''SUCCESS''
                        THEN 1
                    END
                ) * 100.0

                / NULLIF
                (
                    COUNT_BIG
                    (
                        CASE

                            WHEN RunStatus IN
                            (
                                ''SUCCESS'',
                                ''PARTIAL'',
                                ''FAILED'',
                                ''TIMEOUT''
                            )

                            THEN 1

                        END
                    ),

                    0
                )
            ) AS CollectionSuccessPercent,

            AVG
            (
                CONVERT
                (
                    DECIMAL(20,2),
                    DurationMilliseconds
                )
            ) AS AverageDurationMS,

            MAX(DurationMilliseconds)
                AS MaximumDurationMS,

            COALESCE(SUM(RowsReturned), 0)
                AS TotalRowsReturned,

            COALESCE(SUM(RowsStored), 0)
                AS TotalRowsStored

        FROM dbo.CollectionRuns

        WHERE StartDateUTC >= @FromDateUTC;

        ----------------------------------------------------
        -- Result 02: Collector performance summary
        ----------------------------------------------------

        SELECT
            C.CollectorCode,

            C.CollectorName,

            COUNT_BIG(R.CollectionRunID)
                AS TotalRuns,

            COUNT_BIG
            (
                CASE

                    WHEN R.RunStatus = ''SUCCESS''
                        THEN 1

                END
            ) AS SuccessfulRuns,

            COUNT_BIG
            (
                CASE

                    WHEN R.RunStatus IN
                    (
                        ''FAILED'',
                        ''PARTIAL'',
                        ''TIMEOUT''
                    )

                        THEN 1

                END
            ) AS UnsuccessfulRuns,

            AVG
            (
                CONVERT
                (
                    DECIMAL(20,2),
                    R.DurationMilliseconds
                )
            ) AS AverageDurationMS,

            MAX(R.DurationMilliseconds)
                AS MaximumDurationMS,

            COALESCE(SUM(R.RowsReturned), 0)
                AS TotalRowsReturned,

            COALESCE(SUM(R.RowsStored), 0)
                AS TotalRowsStored

        FROM dbo.Collectors AS C

        LEFT JOIN dbo.CollectionRuns AS R

            ON C.CollectorID = R.CollectorID

           AND R.StartDateUTC >= @FromDateUTC

        GROUP BY
            C.CollectorCode,
            C.CollectorName

        ORDER BY C.CollectorCode;

        ----------------------------------------------------
        -- Result 03: Instance assignment health
        ----------------------------------------------------

        SELECT
            I.InstanceName,

            I.Environment,

            C.CollectorCode,

            C.CollectorName,

            IC.LastAttemptDateUTC,

            IC.LastSuccessDateUTC,

            IC.NextRunDateUTC,

            IC.ConsecutiveFailures,

            COALESCE
            (
                IC.IntervalOverrideSeconds,
                C.DefaultIntervalSeconds
            ) AS EffectiveIntervalSeconds,

            DATEDIFF_BIG
            (
                SECOND,
                IC.LastSuccessDateUTC,
                @CurrentUTC
            ) AS SecondsSinceLastSuccess,

            CASE

                WHEN I.IsEnabled = 0
                  OR C.IsEnabled = 0
                  OR IC.IsEnabled = 0

                    THEN ''DISABLED''

                WHEN NOT EXISTS
                (
                    SELECT 1
                    FROM dbo.MonitoringSettings
                    WHERE SettingKey =
                        ''MonitoringEnabled''
                      AND SettingValue = N''1''
                )

                    THEN ''PAUSED''

                WHEN I.Environment IN
                     (''PRODUCTION'', ''DR'')

                 AND NOT EXISTS
                 (
                     SELECT 1
                     FROM dbo.MonitoringSettings
                     WHERE SettingKey =
                         ''ProductionCollectionEnabled''
                       AND SettingValue = N''1''
                 )

                    THEN ''PAUSED''

                WHEN I.IsPilotInstance = 0

                 AND NOT EXISTS
                 (
                     SELECT 1
                     FROM dbo.MonitoringSettings
                     WHERE SettingKey = ''PilotModeEnabled''
                       AND SettingValue = N''0''
                 )

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

                WHEN IC.ConsecutiveFailures > 0

                    THEN ''COLLECTION ISSUES''

                WHEN IC.LastSuccessDateUTC IS NULL

                    THEN ''NOT YET COLLECTED''

                WHEN DATEDIFF_BIG
                (
                    SECOND,
                    IC.LastSuccessDateUTC,
                    @CurrentUTC
                ) >

                CONVERT(BIGINT,
                    COALESCE
                    (
                        IC.IntervalOverrideSeconds,
                        C.DefaultIntervalSeconds
                    )
                ) * 3

                    THEN ''STALE''

                ELSE ''CURRENT''

            END AS CollectionHealthStatus

        FROM dbo.InstanceCollectors AS IC

        INNER JOIN dbo.MonitoredInstances AS I
            ON IC.InstanceID = I.InstanceID

        INNER JOIN dbo.Collectors AS C
            ON IC.CollectorID = C.CollectorID

        ORDER BY
            I.InstanceName,
            C.ExecutionPriority;

        ----------------------------------------------------
        -- Result 04: Recent collection errors
        ----------------------------------------------------

        SELECT TOP (200)
            R.CollectionRunID,

            I.InstanceName,

            C.CollectorCode,

            C.CollectorName,

            R.StartDateUTC,

            R.EndDateUTC,

            R.DurationMilliseconds,

            R.RunStatus,

            R.ErrorNumber,

            R.ErrorMessage

        FROM dbo.CollectionRuns AS R

        INNER JOIN dbo.MonitoredInstances AS I
            ON R.InstanceID = I.InstanceID

        INNER JOIN dbo.Collectors AS C
            ON R.CollectorID = C.CollectorID

        WHERE R.StartDateUTC >= @FromDateUTC

          AND R.RunStatus IN
          (
              ''FAILED'',
              ''PARTIAL'',
              ''TIMEOUT'',
              ''CANCELLED''
          )

        ORDER BY
            R.StartDateUTC DESC,
            R.CollectionRunID DESC;

    END;

    ';

    --------------------------------------------------------
    -- SECTION 5: Register Schema Version
    --------------------------------------------------------

    IF NOT EXISTS
    (
        SELECT 1

        FROM dbo.SchemaVersion

        WHERE VersionNumber = '1.0.2'
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
            '1.0.2',

            N'06-Collection-Logging.sql',

            ORIGINAL_LOGIN(),

            N'Collection logging, scheduling protection,
              failure backoff and monitoring health procedures.'
        );

    END;

    --------------------------------------------------------
    -- SECTION 6: Commit Deployment
    --------------------------------------------------------

    COMMIT TRANSACTION;

    SELECT
        @ActualServer AS MonitoringServer,

        DB_NAME() AS MonitoringDatabase,

        'SUCCESS' AS DeploymentStatus,

        4 AS ProceduresDeployed,

        '1.0.2' AS SchemaVersion,

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
-- SECTION 7: Stored Procedure Verification
------------------------------------------------------------

SELECT
    S.name AS SchemaName,

    P.name AS ProcedureName,

    P.create_date AS CreatedDate,

    P.modify_date AS ModifiedDate

FROM sys.procedures AS P

INNER JOIN sys.schemas AS S
    ON P.schema_id = S.schema_id

WHERE S.name = 'dbo'

AND P.name IN
(
    'usp_CollectionRunStart',
    'usp_CollectionRunComplete',
    'usp_CollectionRunRecover',
    'usp_CollectionHealthSummary'
)

ORDER BY P.name;

GO
