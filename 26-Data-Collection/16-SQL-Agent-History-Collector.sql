/*
============================================================
Project : SQL Server Production Optimization
Module  : 26 - Data Collection
Script  : 16-SQL-Agent-History-Collector.sql
Purpose : Collect incremental SQL Agent execution history
Type    : Read-Only Monitoring Collector
Impact  : Low to Moderate - dependent on history volume
Frequency: 300 Seconds (Proposed)
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
    @LocalCaptureDate DATETIME2(3) = SYSDATETIME(),
    @ServerName NVARCHAR(128),

    @LastProcessedHistoryID BIGINT = 0,
    @InitialLookbackDays INT = 7,
    @MaximumBatchSize INT = 500,

    @InitialHistoryDate INT,
    @HighestHistoryID BIGINT,
    @LowestHistoryID BIGINT,
    @NextCheckpoint BIGINT,

    @ExecutionCount BIGINT,
    @SuccessfulExecutions BIGINT,
    @FailedExecutions BIGINT,
    @CanceledExecutions BIGINT,

    @BatchLimitReached BIT = 0,
    @CollectionSucceeded BIT = 0,
    @HistoryDiscontinuity BIT = 0,

    @CollectionMessage NVARCHAR(2048);

SET @ServerName =
    CONVERT(NVARCHAR(128), SERVERPROPERTY('ServerName'));

SET @InitialHistoryDate =
    CONVERT
    (
        INT,
        CONVERT
        (
            CHAR(8),
            DATEADD
            (
                DAY,
                -@InitialLookbackDays,
                @LocalCaptureDate
            ),
            112
        )
    );

SET @NextCheckpoint = @LastProcessedHistoryID;

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

DECLARE @JobHistory TABLE
(
    HistoryID BIGINT PRIMARY KEY,
    JobID UNIQUEIDENTIFIER,
    RunStatus INT,
    RunDate INT,
    RunTime INT,
    RunDuration INT,
    StartDateTime DATETIME2(0),
    FinishDateTime DATETIME2(0),
    DurationSeconds BIGINT
);

------------------------------------------------------------
-- SECTION 3: Collection Parameter Validation
------------------------------------------------------------

BEGIN TRY

    IF @MaximumBatchSize < 1
       OR @MaximumBatchSize > 10000

    BEGIN

        THROW 50001,
            'Maximum batch size must be between 1 and 10000.',
            1;

    END;

    IF @LastProcessedHistoryID < 0

    BEGIN

        THROW 50002,
            'Last processed history ID cannot be negative.',
            1;

    END;

    IF @InitialLookbackDays < 1
       OR @InitialLookbackDays > 365

    BEGIN

        THROW 50003,
            'Initial lookback must be between 1 and 365 days.',
            1;

    END;

    --------------------------------------------------------
    -- Validate direct history table visibility
    --------------------------------------------------------

    IF ISNULL
    (
        HAS_DBACCESS('msdb'),
        0
    ) <> 1

    BEGIN

        THROW 50004,
            'Monitoring account cannot access msdb.',
            1;

    END;

    --------------------------------------------------------
    -- SECTION 4: History Boundary Collection
    --------------------------------------------------------

    SELECT

        @HighestHistoryID =
            MAX(CONVERT(BIGINT, instance_id)),

        @LowestHistoryID =
            MIN(CONVERT(BIGINT, instance_id))

    FROM msdb.dbo.sysjobhistory;

    --------------------------------------------------------
    -- Detect possible history reset or retention gap
    --------------------------------------------------------

    IF @LastProcessedHistoryID > 0

    BEGIN

        IF @HighestHistoryID IS NULL

           OR @LastProcessedHistoryID >
                @HighestHistoryID

           OR @LastProcessedHistoryID <
                @LowestHistoryID

        BEGIN

            SET @HistoryDiscontinuity = 1;

        END;

    END;

    --------------------------------------------------------
    -- Do not automatically reset an invalid checkpoint
    --------------------------------------------------------

    IF @HistoryDiscontinuity = 1

    BEGIN

        THROW 50005,
            'Possible SQL Agent history discontinuity. Checkpoint review required.',
            1;

    END;

    --------------------------------------------------------
    -- SECTION 5: Incremental Job History Collection
    --------------------------------------------------------

    /*
    step_id = 0 represents the job-level execution outcome.

    Status codes collected:

        0 = Failed
        1 = Succeeded
        3 = Canceled

    Job step records and in-progress records are excluded.
    */

    IF @LastProcessedHistoryID = 0

    BEGIN

        ----------------------------------------------------
        -- Initial collection
        ----------------------------------------------------

        INSERT INTO @JobHistory
        (
            HistoryID,
            JobID,
            RunStatus,
            RunDate,
            RunTime,
            RunDuration
        )

        SELECT TOP (@MaximumBatchSize + 1)

            H.instance_id,
            H.job_id,
            H.run_status,
            H.run_date,
            H.run_time,
            H.run_duration

        FROM msdb.dbo.sysjobhistory AS H

        WHERE H.step_id = 0

          AND H.run_status IN (0, 1, 3)

          AND H.run_date >= @InitialHistoryDate

          AND H.instance_id <= @HighestHistoryID

        ORDER BY H.instance_id ASC;

    END

    ELSE

    BEGIN

        ----------------------------------------------------
        -- Subsequent incremental collection
        ----------------------------------------------------

        INSERT INTO @JobHistory
        (
            HistoryID,
            JobID,
            RunStatus,
            RunDate,
            RunTime,
            RunDuration
        )

        SELECT TOP (@MaximumBatchSize + 1)

            H.instance_id,
            H.job_id,
            H.run_status,
            H.run_date,
            H.run_time,
            H.run_duration

        FROM msdb.dbo.sysjobhistory AS H

        WHERE H.step_id = 0

          AND H.run_status IN (0, 1, 3)

          AND H.instance_id >
                @LastProcessedHistoryID

          AND H.instance_id <=
                @HighestHistoryID

        ORDER BY H.instance_id ASC;

    END;

    --------------------------------------------------------
    -- Determine whether additional records remain
    --------------------------------------------------------

    IF
    (
        SELECT COUNT_BIG(*)
        FROM @JobHistory
    ) > @MaximumBatchSize

    BEGIN

        SET @BatchLimitReached = 1;

        DELETE FROM @JobHistory

        WHERE HistoryID =
        (
            SELECT MAX(HistoryID)
            FROM @JobHistory
        );

    END;

    --------------------------------------------------------
    -- SECTION 6: Job Execution Timestamp Conversion
    --------------------------------------------------------

    UPDATE @JobHistory

    SET StartDateTime =

        TRY_CONVERT
        (
            DATETIME2(0),

            CONCAT
            (
                STUFF
                (
                    STUFF
                    (
                        RIGHT
                        (
                            '00000000' +
                            CONVERT(VARCHAR(8), RunDate),
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
                        RIGHT
                        (
                            '000000' +
                            CONVERT(VARCHAR(6), RunTime),
                            6
                        ),
                        3, 0, ':'
                    ),
                    6, 0, ':'
                )
            ),

            126
        ),

        DurationSeconds =

            CASE

                WHEN RunDuration >= 0

                 AND (RunDuration % 10000) / 100 < 60

                 AND RunDuration % 100 < 60

                THEN

                    CONVERT(BIGINT,
                        RunDuration / 10000) * 3600

                    + CONVERT(BIGINT,
                        (RunDuration % 10000) / 100) * 60

                    + CONVERT(BIGINT,
                        RunDuration % 100)

                ELSE NULL

            END;

    --------------------------------------------------------
    -- Calculate estimated local completion timestamp
    --------------------------------------------------------

    UPDATE @JobHistory

    SET FinishDateTime =

        CASE

            WHEN StartDateTime IS NOT NULL

             AND DurationSeconds
                 BETWEEN 0 AND 2147483647

             AND DurationSeconds <=
                DATEDIFF_BIG
                (
                    SECOND,
                    StartDateTime,
                    CONVERT
                    (
                        DATETIME2(0),
                        '9999-12-31T23:59:59',
                        126
                    )
                )

            THEN DATEADD
            (
                SECOND,
                CONVERT(INT, DurationSeconds),
                StartDateTime
            )

            ELSE NULL

        END;

    --------------------------------------------------------
    -- SECTION 7: Job Execution Summary
    --------------------------------------------------------

    SELECT

        @ExecutionCount = COUNT_BIG(*),

        @SuccessfulExecutions = COUNT_BIG
        (
            CASE
                WHEN RunStatus = 1
                    THEN 1
            END
        ),

        @FailedExecutions = COUNT_BIG
        (
            CASE
                WHEN RunStatus = 0
                    THEN 1
            END
        ),

        @CanceledExecutions = COUNT_BIG
        (
            CASE
                WHEN RunStatus = 3
                    THEN 1
            END
        ),

        @NextCheckpoint =
            COALESCE
            (
                MAX(HistoryID),
                @LastProcessedHistoryID
            )

    FROM @JobHistory;

    --------------------------------------------------------
    -- Advance across inspected history when no batch
    -- backlog remains.
    --------------------------------------------------------

    IF @BatchLimitReached = 0

       AND @HighestHistoryID IS NOT NULL

       AND @HighestHistoryID > @NextCheckpoint

    BEGIN

        SET @NextCheckpoint = @HighestHistoryID;

    END;

    --------------------------------------------------------
    -- SECTION 8: Individual Job Execution Metrics
    --------------------------------------------------------

    INSERT INTO @Metrics
    SELECT
        M.MetricID,
        'SQL Agent History',
        'SQLAgentExecution',

        CONCAT
        (
            CONVERT(VARCHAR(36), H.JobID),
            ':',
            H.HistoryID,
            ':',
            H.RunDate,
            ':',
            H.RunTime
        ),

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
                THEN 'Job history metric unavailable or invalid.'
            ELSE NULL
        END

    FROM @JobHistory AS H

    CROSS APPLY
    (
        VALUES

        (
            'JH-005',
            'Job Execution Outcome',

            CONVERT(DECIMAL(28,4),
                H.RunStatus),

            'StateCode'
        ),
        (
            'JH-006',
            'Job Execution Duration',

            CONVERT(DECIMAL(28,4),
                H.DurationSeconds),

            'Seconds'
        ),
        (
            'JH-007',
            'Job Execution Start Local Timestamp',

            CONVERT
            (
                DECIMAL(28,4),

                DATEDIFF_BIG
                (
                    SECOND,
                    CONVERT(DATETIME2, '19700101'),
                    H.StartDateTime
                )
            ),

            'LocalEpochSeconds'
        ),
        (
            'JH-008',
            'Job Execution Finish Local Timestamp',

            CONVERT
            (
                DECIMAL(28,4),

                DATEDIFF_BIG
                (
                    SECOND,
                    CONVERT(DATETIME2, '19700101'),
                    H.FinishDateTime
                )
            ),

            'LocalEpochSeconds'
        ),
        (
            'JH-009',
            'SQL Agent History Instance ID',

            CONVERT(DECIMAL(28,4),
                H.HistoryID),

            'Identifier'
        )

    ) AS M
    (
        MetricID,
        MetricName,
        MetricValue,
        MetricUnit
    );

    SET @CollectionSucceeded = 1;

END TRY

BEGIN CATCH

    SET @CollectionSucceeded = 0;

    SET @CollectionMessage = ERROR_MESSAGE();

    SET @NextCheckpoint = @LastProcessedHistoryID;

    SET @ExecutionCount = NULL;
    SET @SuccessfulExecutions = NULL;
    SET @FailedExecutions = NULL;
    SET @CanceledExecutions = NULL;

    DELETE FROM @Metrics

    WHERE ResourceType = 'SQLAgentExecution';

    INSERT INTO @Metrics
    VALUES
    (
        'JH-099',
        'Collection',
        'Instance',
        @ServerName,
        'SQL Agent History Collection',
        NULL,
        'Status',
        'FAILED',
        ERROR_MESSAGE()
    );

END CATCH;

------------------------------------------------------------
-- SECTION 9: Instance-Level History Metrics
------------------------------------------------------------

INSERT INTO @Metrics
SELECT
    M.MetricID,
    'SQL Agent History',
    'Instance',
    @ServerName,
    M.MetricName,
    M.MetricValue,
    M.MetricUnit,

    CASE

        WHEN @CollectionSucceeded = 0
            THEN 'FAILED'

        WHEN M.MetricValue IS NULL
            THEN 'UNKNOWN'

        ELSE 'SUCCESS'

    END,

    CASE

        WHEN @CollectionSucceeded = 0
            THEN @CollectionMessage

        WHEN M.MetricValue IS NULL
            THEN 'History information unavailable.'

        ELSE NULL

    END

FROM
(
    VALUES

    (
        'JH-001',
        'Completed Job Executions Collected',
        CONVERT(DECIMAL(28,4), @ExecutionCount),
        'Count'
    ),
    (
        'JH-002',
        'Successful Job Executions',
        CONVERT(DECIMAL(28,4), @SuccessfulExecutions),
        'Count'
    ),
    (
        'JH-003',
        'Failed Job Executions',
        CONVERT(DECIMAL(28,4), @FailedExecutions),
        'Count'
    ),
    (
        'JH-004',
        'Canceled Job Executions',
        CONVERT(DECIMAL(28,4), @CanceledExecutions),
        'Count'
    ),
    (
        'JH-010',
        'Highest Available History ID',
        CONVERT(DECIMAL(28,4), @HighestHistoryID),
        'Identifier'
    ),
    (
        'JH-011',
        'Lowest Available History ID',
        CONVERT(DECIMAL(28,4), @LowestHistoryID),
        'Identifier'
    ),
    (
        'JH-014',
        'Proposed Next Collection Checkpoint',
        CONVERT(DECIMAL(28,4), @NextCheckpoint),
        'Identifier'
    ),
    (
        'JH-015',
        'Additional History Records Remain',
        CONVERT(DECIMAL(28,4), @BatchLimitReached),
        'Boolean'
    )

) AS M
(
    MetricID,
    MetricName,
    MetricValue,
    MetricUnit
);

------------------------------------------------------------
-- SECTION 10: Collection Configuration and Status
------------------------------------------------------------

INSERT INTO @Metrics
VALUES
(
    'JH-013',
    'Collection',
    'Instance',
    @ServerName,
    'Last Processed History ID',
    @LastProcessedHistoryID,
    'Identifier',
    'SUCCESS',
    NULL
),
(
    'JH-016',
    'Collection',
    'Instance',
    @ServerName,
    'Initial History Lookback Period',
    @InitialLookbackDays,
    'Days',
    'SUCCESS',
    NULL
),
(
    'JH-017',
    'Collection',
    'Instance',
    @ServerName,
    'SQL Agent History Collection Successful',
    @CollectionSucceeded,
    'Boolean',
    'SUCCESS',
    @CollectionMessage
),
(
    'JH-018',
    'Collection',
    'Instance',
    @ServerName,
    'Possible Job History Discontinuity',
    @HistoryDiscontinuity,
    'Boolean',
    'SUCCESS',

    CASE

        WHEN @HistoryDiscontinuity = 1

        THEN 'History retention, reset or restore requires review.'

        ELSE NULL

    END
),
(
    'JH-019',
    'Collection',
    'Instance',
    @ServerName,
    'Maximum History Executions Per Batch',
    @MaximumBatchSize,
    'Count',
    'SUCCESS',
    NULL
);

------------------------------------------------------------
-- SECTION 11: Collection Performance
------------------------------------------------------------

INSERT INTO @Metrics
VALUES
(
    'JH-012',
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
-- SECTION 12: Standardized Monitoring Output
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
