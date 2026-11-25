/*
============================================================
Project : SQL Server Production Optimization
Module  : 26 - Data Collection
Script  : 08-SQL-Agent-Collector.sql
Purpose : Collect SQL Agent service and job health metrics
Type    : Read-Only Monitoring Collector
Impact  : Low to Moderate - dependent on job history size
Frequency: 300 Seconds (Proposed)
============================================================
*/

USE master;
GO

SET NOCOUNT ON;

------------------------------------------------------------
-- SECTION 1: Collection Variables
------------------------------------------------------------

DECLARE
    @CaptureDate DATETIME2(3) = SYSUTCDATETIME(),
    @CollectionStart DATETIME2(3) = SYSUTCDATETIME(),
    @LocalCaptureDate DATETIME2(3) = SYSDATETIME(),
    @ServerName NVARCHAR(128),

    @AgentStatus INT,
    @AgentStartupType INT,
    @AgentSessionID INT,
    @AgentServiceFound INT,

    @TotalJobs BIGINT,
    @EnabledJobs BIGINT,
    @DisabledJobs BIGINT,
    @RunningJobs BIGINT,
    @FailedJobs BIGINT;

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

DECLARE @JobDetails TABLE
(
    JobID UNIQUEIDENTIFIER PRIMARY KEY,
    JobEnabled BIT,
    LastRunStatus INT,
    LastRunDateTime DATETIME2,
    LastRunDurationSeconds BIGINT,
    HistoryAvailable BIT,
    RunningStatus INT,
    CurrentRunDurationSeconds BIGINT,
    EnabledScheduleCount INT,
    NextRunDateTime DATETIME2,
    QueuedStatus INT,
    QueueDurationSeconds BIGINT
);

------------------------------------------------------------
-- SECTION 3: SQL Agent Service Availability
------------------------------------------------------------

BEGIN TRY

    SELECT TOP (1)
        @AgentStatus = status,
        @AgentStartupType = startup_type,
        @AgentServiceFound = 1

    FROM sys.dm_server_services

    WHERE servicename LIKE 'SQL Server Agent (%';

    INSERT INTO @Metrics
    SELECT
        M.MetricID,
        'SQL Agent',
        'Instance',
        @ServerName,
        M.MetricName,
        M.MetricValue,
        'StateCode',

        CASE
            WHEN M.MetricValue IS NOT NULL
                THEN 'SUCCESS'

            WHEN @AgentServiceFound IS NULL
             AND CONVERT(INT,
                 SERVERPROPERTY('EngineEdition')) = 4
                THEN 'NOT APPLICABLE'

            ELSE 'UNKNOWN'
        END,

        CASE
            WHEN M.MetricValue IS NULL
                THEN 'SQL Agent service information unavailable.'
            ELSE NULL
        END

    FROM
    (
        VALUES
        (
            'JOB-001',
            'SQL Agent Service Status',
            CONVERT(DECIMAL(28,4), @AgentStatus)
        ),
        (
            'JOB-002',
            'SQL Agent Startup Type',
            CONVERT(DECIMAL(28,4), @AgentStartupType)
        )

    ) AS M
    (
        MetricID,
        MetricName,
        MetricValue
    );

END TRY

BEGIN CATCH

    INSERT INTO @Metrics
    SELECT
        M.MetricID,
        'SQL Agent',
        'Instance',
        @ServerName,
        M.MetricName,
        NULL,
        'StateCode',
        'FAILED',
        ERROR_MESSAGE()

    FROM
    (
        VALUES
        ('JOB-001', 'SQL Agent Service Status'),
        ('JOB-002', 'SQL Agent Startup Type')

    ) AS M
    (
        MetricID,
        MetricName
    );

END CATCH;

------------------------------------------------------------
-- SECTION 4: Current SQL Agent Session
------------------------------------------------------------

BEGIN TRY

    SELECT
        @AgentSessionID = MAX(session_id)
    FROM msdb.dbo.syssessions;

    INSERT INTO @Metrics
    VALUES
    (
        'JOB-017',
        'SQL Agent',
        'Instance',
        @ServerName,
        'SQL Agent Session ID',
        @AgentSessionID,
        'Identifier',

        CASE
            WHEN @AgentSessionID IS NULL
                THEN 'UNKNOWN'
            ELSE 'SUCCESS'
        END,

        NULL
    );

END TRY

BEGIN CATCH

    INSERT INTO @Metrics
    VALUES
    (
        'JOB-017',
        'SQL Agent',
        'Instance',
        @ServerName,
        'SQL Agent Session ID',
        NULL,
        'Identifier',
        'FAILED',
        ERROR_MESSAGE()
    );

END CATCH;

------------------------------------------------------------
-- SECTION 5: SQL Agent Job Collection
------------------------------------------------------------

BEGIN TRY

    ;WITH JobSchedules AS
    (
        SELECT
            JS.job_id,
            COUNT(*) AS EnabledScheduleCount,

            MIN
            (
                CASE
                    WHEN JS.next_run_date > 0

                    THEN TRY_CONVERT
                    (
                        DATETIME2,

                        CONCAT
                        (
                            STUFF
                            (
                                STUFF
                                (
                                    RIGHT(
                                        '00000000' +
                                        CONVERT(VARCHAR(8),
                                            JS.next_run_date),
                                        8
                                    ),
                                    5, 0, '-'
                                ),
                                8, 0, '-'
                            ),

                            'T',

                            STUFF
                            (
                                STUFF
                                (
                                    RIGHT(
                                        '000000' +
                                        CONVERT(VARCHAR(6),
                                            JS.next_run_time),
                                        6
                                    ),
                                    3, 0, ':'
                                ),
                                6, 0, ':'
                            )
                        ),

                        126
                    )

                    ELSE NULL
                END

            ) AS NextRunDateTime

        FROM msdb.dbo.sysjobschedules AS JS

        INNER JOIN msdb.dbo.sysschedules AS S
            ON JS.schedule_id = S.schedule_id

        WHERE S.enabled = 1

        GROUP BY JS.job_id
    )

    INSERT INTO @JobDetails
    SELECT
        J.job_id,
        J.enabled,
        H.run_status,

        ----------------------------------------------------
        -- Last completed job execution start time
        ----------------------------------------------------

        TRY_CONVERT
        (
            DATETIME2,

            CONCAT
            (
                STUFF
                (
                    STUFF
                    (
                        RIGHT(
                            '00000000' +
                            CONVERT(VARCHAR(8), H.run_date),
                            8
                        ),
                        5, 0, '-'
                    ),
                    8, 0, '-'
                ),

                'T',

                STUFF
                (
                    STUFF
                    (
                        RIGHT(
                            '000000' +
                            CONVERT(VARCHAR(6), H.run_time),
                            6
                        ),
                        3, 0, ':'
                    ),
                    6, 0, ':'
                )
            ),

            126
        ),

        ----------------------------------------------------
        -- Last execution duration in seconds
        ----------------------------------------------------

        CONVERT(BIGINT, H.run_duration / 10000) * 3600
        + CONVERT(BIGINT,
            (H.run_duration % 10000) / 100) * 60
        + CONVERT(BIGINT, H.run_duration % 100),

        CASE
            WHEN H.instance_id IS NOT NULL THEN 1
            ELSE 0
        END,

        ----------------------------------------------------
        -- Current running status
        ----------------------------------------------------

        CASE

            WHEN @AgentStatus = 1 THEN 0

            WHEN ISNULL(@AgentStatus, -1) <> 4
              OR @AgentSessionID IS NULL
              OR A.job_id IS NULL
                THEN NULL

            WHEN A.start_execution_date IS NOT NULL
             AND A.stop_execution_date IS NULL
                THEN 1

            ELSE 0

        END,

        ----------------------------------------------------
        -- Current execution duration
        ----------------------------------------------------

        CASE

            WHEN @AgentStatus = 4
             AND A.start_execution_date IS NOT NULL
             AND A.stop_execution_date IS NULL
             AND A.start_execution_date <= @LocalCaptureDate

                THEN DATEDIFF_BIG
                (
                    SECOND,
                    A.start_execution_date,
                    @LocalCaptureDate
                )

            ELSE NULL

        END,

        ISNULL(S.EnabledScheduleCount, 0),

        CASE
            WHEN J.enabled = 1
                THEN S.NextRunDateTime
            ELSE NULL
        END,

        ----------------------------------------------------
        -- Requested but not yet started
        ----------------------------------------------------

        CASE

            WHEN @AgentStatus = 1 THEN 0

            WHEN ISNULL(@AgentStatus, -1) <> 4
              OR @AgentSessionID IS NULL
              OR A.job_id IS NULL
                THEN NULL

            WHEN A.run_requested_date IS NOT NULL
             AND A.start_execution_date IS NULL
             AND A.stop_execution_date IS NULL
                THEN 1

            ELSE 0

        END,

        ----------------------------------------------------
        -- Current job queue duration
        ----------------------------------------------------

        CASE

            WHEN @AgentStatus = 4
             AND A.run_requested_date IS NOT NULL
             AND A.start_execution_date IS NULL
             AND A.stop_execution_date IS NULL
             AND A.run_requested_date <= @LocalCaptureDate

                THEN DATEDIFF_BIG
                (
                    SECOND,
                    A.run_requested_date,
                    @LocalCaptureDate
                )

            ELSE NULL

        END

    FROM msdb.dbo.sysjobs AS J

    LEFT JOIN msdb.dbo.sysjobactivity AS A
        ON J.job_id = A.job_id
       AND A.session_id = @AgentSessionID

    LEFT JOIN JobSchedules AS S
        ON J.job_id = S.job_id

    OUTER APPLY
    (
        SELECT TOP (1)
            H.instance_id,
            H.run_status,
            H.run_date,
            H.run_time,
            H.run_duration

        FROM msdb.dbo.sysjobhistory AS H

        WHERE H.job_id = J.job_id
          AND H.step_id = 0
          AND H.run_status IN (0, 1, 3)

        ORDER BY H.instance_id DESC

    ) AS H;

    --------------------------------------------------------
    -- SECTION 6: Instance-Level Job Summary
    --------------------------------------------------------

    SELECT
        @TotalJobs = COUNT_BIG(*),

        @EnabledJobs = COUNT_BIG(CASE
            WHEN JobEnabled = 1 THEN 1 END),

        @DisabledJobs = COUNT_BIG(CASE
            WHEN JobEnabled = 0 THEN 1 END),

        @RunningJobs =
            CASE
                WHEN COUNT_BIG(CASE
                    WHEN RunningStatus IS NULL
                    THEN 1 END) > 0
                    THEN NULL
                ELSE COUNT_BIG(CASE
                    WHEN RunningStatus = 1
                    THEN 1 END)
            END,

        @FailedJobs = COUNT_BIG(CASE
            WHEN LastRunStatus = 0
            THEN 1 END)

    FROM @JobDetails;

    IF ISNULL(@AgentStatus, -1) NOT IN (1, 4)
        SET @RunningJobs = NULL;

    INSERT INTO @Metrics
    SELECT
        M.MetricID,
        'SQL Agent',
        'Instance',
        @ServerName,
        M.MetricName,
        M.MetricValue,
        'Count',

        CASE
            WHEN M.MetricValue IS NULL
                THEN 'UNKNOWN'
            ELSE 'SUCCESS'
        END,

        CASE
            WHEN M.MetricValue IS NULL
                THEN 'Current job activity unavailable.'
            ELSE NULL
        END

    FROM
    (
        VALUES

        (
            'JOB-003',
            'Total SQL Agent Jobs',
            CONVERT(DECIMAL(28,4), @TotalJobs)
        ),
        (
            'JOB-004',
            'Enabled SQL Agent Jobs',
            CONVERT(DECIMAL(28,4), @EnabledJobs)
        ),
        (
            'JOB-005',
            'Disabled SQL Agent Jobs',
            CONVERT(DECIMAL(28,4), @DisabledJobs)
        ),
        (
            'JOB-006',
            'Currently Running Jobs',
            CONVERT(DECIMAL(28,4), @RunningJobs)
        ),
        (
            'JOB-007',
            'Jobs With Last Execution Failed',
            CONVERT(DECIMAL(28,4), @FailedJobs)
        )

    ) AS M
    (
        MetricID,
        MetricName,
        MetricValue
    );

    --------------------------------------------------------
    -- SECTION 7: Individual Job Monitoring Metrics
    --------------------------------------------------------

    INSERT INTO @Metrics
    SELECT
        M.MetricID,
        'SQL Agent',
        'SQLAgentJob',
        CONVERT(VARCHAR(36), J.JobID),
        M.MetricName,
        M.MetricValue,
        M.MetricUnit,

        CASE

            WHEN M.MetricID = 'JOB-013'
             AND J.RunningStatus = 0
                THEN 'NOT APPLICABLE'

            WHEN M.MetricID = 'JOB-020'
             AND J.QueuedStatus = 0
                THEN 'NOT APPLICABLE'

            WHEN M.MetricID = 'JOB-015'
             AND
             (
                 J.JobEnabled = 0
                 OR J.EnabledScheduleCount = 0
             )
                THEN 'NOT APPLICABLE'

            WHEN M.MetricValue IS NULL
                THEN 'UNKNOWN'

            ELSE 'SUCCESS'

        END,

        CASE

            WHEN M.MetricID = 'JOB-013'
             AND J.RunningStatus = 0
                THEN 'Job is not currently running.'

            WHEN M.MetricID = 'JOB-020'
             AND J.QueuedStatus = 0
                THEN 'Job is not currently queued.'

            WHEN M.MetricID = 'JOB-015'
             AND
             (
                 J.JobEnabled = 0
                 OR J.EnabledScheduleCount = 0
             )
                THEN 'No applicable enabled schedule.'

            WHEN M.MetricValue IS NULL
                THEN 'Job information unavailable or not recorded.'

            ELSE NULL

        END

    FROM @JobDetails AS J

    CROSS APPLY
    (
        VALUES

        (
            'JOB-008',
            'Job Enabled Status',
            CONVERT(DECIMAL(28,4), J.JobEnabled),
            'Boolean'
        ),
        (
            'JOB-009',
            'Last Execution Outcome',
            CONVERT(DECIMAL(28,4), J.LastRunStatus),
            'StateCode'
        ),
        (
            'JOB-010',
            'Last Execution Start Age',

            CONVERT(DECIMAL(28,4),

                CASE
                    WHEN J.LastRunDateTime
                        <= @LocalCaptureDate

                    THEN DATEDIFF_BIG
                    (
                        SECOND,
                        J.LastRunDateTime,
                        @LocalCaptureDate
                    ) / 60.0
                END
            ),

            'Minutes'
        ),
        (
            'JOB-011',
            'Last Execution Duration',
            CONVERT(DECIMAL(28,4),
                J.LastRunDurationSeconds),
            'Seconds'
        ),
        (
            'JOB-012',
            'Currently Running Status',
            CONVERT(DECIMAL(28,4),
                J.RunningStatus),
            'Boolean'
        ),
        (
            'JOB-013',
            'Current Execution Duration',
            CONVERT(DECIMAL(28,4),
                J.CurrentRunDurationSeconds),
            'Seconds'
        ),
        (
            'JOB-014',
            'Enabled Schedule Count',
            CONVERT(DECIMAL(28,4),
                J.EnabledScheduleCount),
            'Count'
        ),
        (
            'JOB-015',
            'Time Until Next Scheduled Execution',

            CONVERT(DECIMAL(28,4),

                CASE
                    WHEN J.NextRunDateTime
                        >= @LocalCaptureDate

                    THEN DATEDIFF_BIG
                    (
                        SECOND,
                        @LocalCaptureDate,
                        J.NextRunDateTime
                    ) / 60.0

                    ELSE NULL
                END
            ),

            'Minutes'
        ),
        (
            'JOB-018',
            'Job Execution History Available',
            CONVERT(DECIMAL(28,4),
                J.HistoryAvailable),
            'Boolean'
        ),
        (
            'JOB-019',
            'Job Requested But Not Started',
            CONVERT(DECIMAL(28,4),
                J.QueuedStatus),
            'Boolean'
        ),
        (
            'JOB-020',
            'Job Execution Queue Duration',
            CONVERT(DECIMAL(28,4),
                J.QueueDurationSeconds),
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
    VALUES
    (
        'JOB-099',
        'Collection',
        'Instance',
        @ServerName,
        'SQL Agent Job Collection',
        NULL,
        'Status',
        'FAILED',
        ERROR_MESSAGE()
    );

END CATCH;

------------------------------------------------------------
-- SECTION 8: Collection Performance
------------------------------------------------------------

INSERT INTO @Metrics
VALUES
(
    'JOB-016',
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
-- SECTION 9: Standardized Monitoring Output
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
