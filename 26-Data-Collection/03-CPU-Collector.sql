/*
============================================================
Project : SQL Server Production Optimization
Module  : 26 - Data Collection
Script  : 03-CPU-Collector.sql
Purpose : Collect CPU utilization and scheduler metrics
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

    @SQLCPU INT,
    @SystemIdle INT,
    @OtherCPU INT,
    @TotalCPU INT,
    @SampleAgeSeconds BIGINT,

    @CurrentTicks BIGINT,
    @SampleTicks BIGINT,
    @CPURecord XML,

    @OnlineSchedulers INT,
    @RunnableTasks BIGINT,
    @AvgRunnableTasks DECIMAL(28,4),
    @MaxRunnableTasks INT,
    @CurrentWorkers BIGINT,
    @ActiveWorkers BIGINT,
    @WorkQueueCount BIGINT;

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

------------------------------------------------------------
-- SECTION 3: CPU Utilization Collection
------------------------------------------------------------

BEGIN TRY

    SELECT
        @CurrentTicks = ms_ticks
    FROM sys.dm_os_sys_info;

    SELECT TOP (1)
        @CPURecord = TRY_CAST(record AS XML),
        @SampleTicks = [timestamp]

    FROM sys.dm_os_ring_buffers

    WHERE ring_buffer_type =
        'RING_BUFFER_SCHEDULER_MONITOR'

    AND record LIKE '%<SystemHealth>%'

    ORDER BY [timestamp] DESC;

    IF @CPURecord IS NOT NULL
    BEGIN

        SELECT
            @SQLCPU = @CPURecord.value(
                '(/Record/SchedulerMonitorEvent/
                SystemHealth/ProcessUtilization)[1]',
                'INT'),

            @SystemIdle = @CPURecord.value(
                '(/Record/SchedulerMonitorEvent/
                SystemHealth/SystemIdle)[1]',
                'INT');

        SET @SampleAgeSeconds =
            CASE
                WHEN @CurrentTicks >= @SampleTicks
                    THEN (@CurrentTicks - @SampleTicks)
                         / 1000
                ELSE NULL
            END;

        IF @SQLCPU BETWEEN 0 AND 100
        AND @SystemIdle BETWEEN 0 AND 100
        AND (@SQLCPU + @SystemIdle) <= 100
        BEGIN

            SET @OtherCPU =
                100 - @SQLCPU - @SystemIdle;

            SET @TotalCPU =
                100 - @SystemIdle;

        END
        ELSE
        BEGIN

            SET @SQLCPU = NULL;
            SET @SystemIdle = NULL;
            SET @OtherCPU = NULL;
            SET @TotalCPU = NULL;

        END;

    END;

    INSERT INTO @Metrics
    SELECT
        M.MetricID,
        'CPU',
        'Instance',
        @ServerName,
        M.MetricName,
        M.MetricValue,
        M.MetricUnit,

        CASE
            WHEN M.MetricValue IS NULL
                THEN 'UNKNOWN'

            WHEN @SampleAgeSeconds IS NULL
                THEN 'UNKNOWN'

            WHEN @SampleAgeSeconds > 180
                THEN 'STALE'

            ELSE 'SUCCESS'
        END,

        CASE
            WHEN M.MetricValue IS NULL
                THEN 'CPU sample unavailable or invalid.'

            WHEN @SampleAgeSeconds IS NULL
                THEN 'CPU sample age unavailable.'

            WHEN @SampleAgeSeconds > 180
                THEN 'CPU sample is older than 180 seconds.'

            ELSE NULL
        END

    FROM
    (
        VALUES

        (
            'CPU-001',
            'SQL Server CPU Utilization',
            CONVERT(DECIMAL(28,4), @SQLCPU),
            'Percent'
        ),
        (
            'CPU-002',
            'Other Processes CPU Utilization',
            CONVERT(DECIMAL(28,4), @OtherCPU),
            'Percent'
        ),
        (
            'CPU-003',
            'Total System CPU Utilization',
            CONVERT(DECIMAL(28,4), @TotalCPU),
            'Percent'
        ),
        (
            'CPU-004',
            'System Idle Percentage',
            CONVERT(DECIMAL(28,4), @SystemIdle),
            'Percent'
        ),
        (
            'CPU-005',
            'CPU Sample Age',
            CONVERT(DECIMAL(28,4), @SampleAgeSeconds),
            'Seconds'
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
        'CPU',
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
        ('CPU-001',
         'SQL Server CPU Utilization', 'Percent'),

        ('CPU-002',
         'Other Processes CPU Utilization', 'Percent'),

        ('CPU-003',
         'Total System CPU Utilization', 'Percent'),

        ('CPU-004',
         'System Idle Percentage', 'Percent'),

        ('CPU-005',
         'CPU Sample Age', 'Seconds')

    ) AS M
    (
        MetricID,
        MetricName,
        MetricUnit
    );

END CATCH;

------------------------------------------------------------
-- SECTION 4: Scheduler Pressure Collection
------------------------------------------------------------

BEGIN TRY

    SELECT
        @OnlineSchedulers = COUNT(*),

        @RunnableTasks =
            SUM(CONVERT(BIGINT, runnable_tasks_count)),

        @MaxRunnableTasks =
            MAX(runnable_tasks_count),

        @CurrentWorkers =
            SUM(CONVERT(BIGINT, current_workers_count)),

        @ActiveWorkers =
            SUM(CONVERT(BIGINT, active_workers_count)),

        @WorkQueueCount =
            SUM(CONVERT(BIGINT, work_queue_count))

    FROM sys.dm_os_schedulers

    WHERE status = 'VISIBLE ONLINE';

    SET @AvgRunnableTasks =
        CONVERT(DECIMAL(28,4), @RunnableTasks)
        / NULLIF(@OnlineSchedulers, 0);

    INSERT INTO @Metrics
    SELECT
        M.MetricID,
        'CPU',
        'Instance',
        @ServerName,
        M.MetricName,
        M.MetricValue,
        M.MetricUnit,

        CASE
            WHEN M.MetricValue IS NULL
              OR @OnlineSchedulers = 0
                THEN 'UNKNOWN'
            ELSE 'SUCCESS'
        END,

        CASE
            WHEN M.MetricValue IS NULL
              OR @OnlineSchedulers = 0
                THEN 'Scheduler information unavailable.'
            ELSE NULL
        END

    FROM
    (
        VALUES

        (
            'CPU-006',
            'Online Visible Schedulers',
            CONVERT(DECIMAL(28,4), @OnlineSchedulers),
            'Count'
        ),
        (
            'CPU-007',
            'Runnable Tasks',
            CONVERT(DECIMAL(28,4), @RunnableTasks),
            'Count'
        ),
        (
            'CPU-008',
            'Average Runnable Tasks Per Scheduler',
            @AvgRunnableTasks,
            'Count'
        ),
        (
            'CPU-009',
            'Maximum Runnable Tasks On Scheduler',
            CONVERT(DECIMAL(28,4), @MaxRunnableTasks),
            'Count'
        ),
        (
            'CPU-010',
            'Current Workers',
            CONVERT(DECIMAL(28,4), @CurrentWorkers),
            'Count'
        ),
        (
            'CPU-011',
            'Active Workers',
            CONVERT(DECIMAL(28,4), @ActiveWorkers),
            'Count'
        ),
        (
            'CPU-012',
            'Work Queue Count',
            CONVERT(DECIMAL(28,4), @WorkQueueCount),
            'Count'
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
        'CPU',
        'Instance',
        @ServerName,
        M.MetricName,
        NULL,
        'Count',
        'FAILED',
        ERROR_MESSAGE()

    FROM
    (
        VALUES
        ('CPU-006', 'Online Visible Schedulers'),
        ('CPU-007', 'Runnable Tasks'),
        ('CPU-008', 'Average Runnable Tasks Per Scheduler'),
        ('CPU-009', 'Maximum Runnable Tasks On Scheduler'),
        ('CPU-010', 'Current Workers'),
        ('CPU-011', 'Active Workers'),
        ('CPU-012', 'Work Queue Count')

    ) AS M
    (
        MetricID,
        MetricName
    );

END CATCH;

------------------------------------------------------------
-- SECTION 5: Collection Performance
------------------------------------------------------------

INSERT INTO @Metrics
VALUES
(
    'CPU-013',
    'Collection',
    'Instance',
    @ServerName,
    'Collector Execution Duration',

    DATEDIFF(
        MILLISECOND,
        @CollectionStart,
        SYSUTCDATETIME()
    ),

    'Milliseconds',
    'SUCCESS',
    NULL
);

------------------------------------------------------------
-- SECTION 6: Standardized Monitoring Output
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

ORDER BY MetricID;

GO
