/*
============================================================
Project : SQL Server Production Optimization
Module  : 26 - Data Collection
Script  : 13-Wait-Statistics-Collector.sql
Purpose : Collect cumulative SQL Server wait statistics
Type    : Read-Only Monitoring Collector
Impact  : Low
Frequency: 60 Seconds (Proposed)
============================================================
*/

USE master;
GO

SET NOCOUNT ON;

-- Limit lock waits and favor application transactions in deadlocks.
SET LOCK_TIMEOUT 5000;
SET DEADLOCK_PRIORITY LOW;

------------------------------------------------------------
-- SECTION 1: Collection Variables
------------------------------------------------------------

DECLARE
    @CaptureDate DATETIME2(3) = SYSUTCDATETIME(),
    @CollectionStart DATETIME2(3) = SYSUTCDATETIME(),
    @ServerName NVARCHAR(128),

    @WaitTypeCount BIGINT,
    @ActiveWaitTypeCount BIGINT,
    @SQLUptimeSeconds BIGINT,
    @SQLStartTime DATETIME,
    @SQLStartTimeTicks BIGINT;

SET @ServerName =
    CONVERT(NVARCHAR(128), SERVERPROPERTY('ServerName'));

------------------------------------------------------------
-- SECTION 2: Monitoring Data Structure
------------------------------------------------------------

DECLARE @Metrics TABLE
(
    MetricID VARCHAR(30),
    Category VARCHAR(50),
    ResourceType VARCHAR(30),
    ResourceName NVARCHAR(256),
    MetricName VARCHAR(100),
    MetricValue DECIMAL(28,4),
    MetricUnit VARCHAR(30),
    CollectionStatus VARCHAR(20),
    ErrorMessage NVARCHAR(2048)
);

DECLARE @WaitStats TABLE
(
    WaitType NVARCHAR(120) PRIMARY KEY,
    WaitingTasksCount BIGINT,
    TotalWaitTimeMS BIGINT,
    SignalWaitTimeMS BIGINT,
    ResourceWaitTimeMS BIGINT,
    MaxWaitTimeMS BIGINT
);

------------------------------------------------------------
-- SECTION 3: SQL Server Startup Information
------------------------------------------------------------

BEGIN TRY

    SELECT

        @SQLUptimeSeconds =
            CASE
                WHEN ms_ticks >= sqlserver_start_time_ms_ticks
                THEN
                    (ms_ticks - sqlserver_start_time_ms_ticks)
                    / 1000
                ELSE NULL
            END,

        @SQLStartTime = sqlserver_start_time,

        @SQLStartTimeTicks =
            sqlserver_start_time_ms_ticks

    FROM sys.dm_os_sys_info;

    INSERT INTO @Metrics
    SELECT
        M.MetricID,
        'Collection',
        'Instance',
        @ServerName,
        M.MetricName,
        M.MetricValue,
        M.MetricUnit,

        CASE
            WHEN M.MetricValue IS NULL
                THEN 'UNKNOWN'
            ELSE 'SUCCESS'
        END,

        CASE
            WHEN M.MetricValue IS NULL
                THEN 'SQL Server startup information unavailable.'
            ELSE NULL
        END

    FROM
    (
        VALUES

        (
            'WAI-008',
            'SQL Server Uptime',
            CONVERT(DECIMAL(28,4), @SQLUptimeSeconds),
            'Seconds'
        ),
        (
            'WAI-010',
            'SQL Server Startup Tick',
            CONVERT(DECIMAL(28,4), @SQLStartTimeTicks),
            'Milliseconds'
        )

    ) AS M
    (
        MetricID,
        MetricName,
        MetricValue,
        MetricUnit
    );

END TRY

BEGIN CATCH

    INSERT INTO @Metrics
    SELECT
        M.MetricID,
        'Collection',
        'Instance',
        @ServerName,
        M.MetricName,
        NULL,
        M.MetricUnit,
        'FAILED',
        ERROR_MESSAGE()

    FROM
    (
        VALUES

        (
            'WAI-008',
            'SQL Server Uptime',
            'Seconds'
        ),
        (
            'WAI-010',
            'SQL Server Startup Tick',
            'Milliseconds'
        )

    ) AS M
    (
        MetricID,
        MetricName,
        MetricUnit
    );

END CATCH;

------------------------------------------------------------
-- SECTION 4: Cumulative Wait Statistics Collection
------------------------------------------------------------

BEGIN TRY

    INSERT INTO @WaitStats
    SELECT
        wait_type,
        waiting_tasks_count,
        wait_time_ms,
        signal_wait_time_ms,

        CASE

            WHEN wait_time_ms >= signal_wait_time_ms

                THEN wait_time_ms - signal_wait_time_ms

            ELSE NULL

        END,

        max_wait_time_ms

    FROM sys.dm_os_wait_stats;

    --------------------------------------------------------
    -- Wait statistics summary
    --------------------------------------------------------

    SELECT

        @WaitTypeCount = COUNT_BIG(*),

        @ActiveWaitTypeCount = COUNT_BIG
        (
            CASE

                WHEN WaitingTasksCount > 0
                  OR TotalWaitTimeMS > 0

                    THEN 1

            END
        )

    FROM @WaitStats;

    INSERT INTO @Metrics
    VALUES
    (
        'WAI-006',
        'Collection',
        'Instance',
        @ServerName,
        'Total Observed Wait Types',
        @WaitTypeCount,
        'Count',

        CASE
            WHEN @WaitTypeCount = 0
                THEN 'UNKNOWN'
            ELSE 'SUCCESS'
        END,

        CASE
            WHEN @WaitTypeCount = 0
                THEN 'No wait statistics returned.'
            ELSE NULL
        END
    ),
    (
        'WAI-007',
        'Wait Statistics',
        'Instance',
        @ServerName,
        'Wait Types With Recorded Activity',
        CASE
            WHEN @WaitTypeCount > 0
                THEN @ActiveWaitTypeCount
            ELSE NULL
        END,
        'Count',

        CASE
            WHEN @WaitTypeCount = 0
                THEN 'UNKNOWN'
            ELSE 'SUCCESS'
        END,

        NULL
    );

    --------------------------------------------------------
    -- SECTION 5: Individual Wait Type Metrics
    --------------------------------------------------------

    INSERT INTO @Metrics
    SELECT
        M.MetricID,
        'Wait Statistics',
        'WaitType',
        W.WaitType,
        M.MetricName,
        M.MetricValue,
        M.MetricUnit,

        CASE

            WHEN M.MetricValue IS NULL
                THEN 'UNKNOWN'

            WHEN M.MetricValue < 0
                THEN 'UNKNOWN'

            ELSE 'SUCCESS'

        END,

        CASE

            WHEN M.MetricValue IS NULL
                THEN 'Wait counter unavailable or inconsistent.'

            WHEN M.MetricValue < 0
                THEN 'Invalid negative wait counter.'

            ELSE NULL

        END

    FROM @WaitStats AS W

    CROSS APPLY
    (
        VALUES

        (
            'WAI-001',
            'Cumulative Waiting Tasks Count',

            CONVERT(DECIMAL(28,4),
                W.WaitingTasksCount),

            'CumulativeCount'
        ),
        (
            'WAI-002',
            'Cumulative Total Wait Time',

            CONVERT(DECIMAL(28,4),
                W.TotalWaitTimeMS),

            'CumulativeMilliseconds'
        ),
        (
            'WAI-003',
            'Cumulative Signal Wait Time',

            CONVERT(DECIMAL(28,4),
                W.SignalWaitTimeMS),

            'CumulativeMilliseconds'
        ),
        (
            'WAI-004',
            'Cumulative Resource Wait Time',

            CONVERT(DECIMAL(28,4),
                W.ResourceWaitTimeMS),

            'CumulativeMilliseconds'
        ),
        (
            'WAI-005',
            'Maximum Recorded Wait Time',

            CONVERT(DECIMAL(28,4),
                W.MaxWaitTimeMS),

            'Milliseconds'
        )

    ) AS M
    (
        MetricID,
        MetricName,
        MetricValue,
        MetricUnit
    );

END TRY

BEGIN CATCH

    INSERT INTO @Metrics
    VALUES
    (
        'WAI-099',
        'Collection',
        'Instance',
        @ServerName,
        'Wait Statistics Collection',
        NULL,
        'Status',
        'FAILED',
        ERROR_MESSAGE()
    );

END CATCH;

------------------------------------------------------------
-- SECTION 6: Collection Performance
------------------------------------------------------------

INSERT INTO @Metrics
VALUES
(
    'WAI-009',
    'Collection',
    'Instance',
    @ServerName,
    'Collector Execution Duration',

    DATEDIFF
    (
        MILLISECOND,
        @CollectionStart,
        SYSUTCDATETIME()
    ),

    'Milliseconds',
    'SUCCESS',
    NULL
);

------------------------------------------------------------
-- SECTION 7: Standardized Monitoring Output
------------------------------------------------------------

SELECT
    @CaptureDate AS CaptureDateUTC,
    @ServerName AS ServerName,
    '26' AS ModuleID,
    MetricID,
    Category,
    ResourceType,
    ResourceName,
    MetricName,
    MetricValue,
    MetricUnit,
    CollectionStatus,
    ErrorMessage

FROM @Metrics

ORDER BY
    ResourceType,
    ResourceName,
    MetricID;

GO
