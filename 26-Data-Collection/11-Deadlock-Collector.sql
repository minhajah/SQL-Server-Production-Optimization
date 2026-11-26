/*
============================================================
Project : SQL Server Production Optimization
Module  : 26 - Data Collection
Script  : 11-Deadlock-Collector.sql
Purpose : Collect deadlock events from system_health
Type    : Read-Only Monitoring Collector
Impact  : Low to Moderate - dependent on XE file size
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
    @ServerName NVARCHAR(128),

    @LookbackMinutes INT = 15,
    @WindowStart DATETIME2(3),

    @SessionRunning INT,
    @EventFileAvailable INT,
    @TargetData XML,
    @EventFilePath NVARCHAR(260),

    @DeadlockCount BIGINT,
    @LatestDeadlockUTC DATETIME2(7),
    @LatestDeadlockAge BIGINT,
    @CollectionSucceeded BIT = 0;

SET @ServerName =
    CONVERT(NVARCHAR(128), SERVERPROPERTY('ServerName'));

SET @WindowStart =
    DATEADD(MINUTE, -@LookbackMinutes, @CaptureDate);

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

DECLARE @Deadlocks TABLE
(
    EventID VARCHAR(64) PRIMARY KEY,
    EventTimeUTC DATETIME2(7),
    EventXML XML
);

------------------------------------------------------------
-- SECTION 3: System Health Session Validation
------------------------------------------------------------

BEGIN TRY

    SELECT
        @SessionRunning =
            CASE WHEN EXISTS
            (
                SELECT 1
                FROM sys.dm_xe_sessions
                WHERE name = 'system_health'
            )
            THEN 1 ELSE 0 END;

    IF @SessionRunning = 1
    BEGIN

        SELECT TOP (1)
            @TargetData = TRY_CAST(T.target_data AS XML)

        FROM sys.dm_xe_sessions AS S

        INNER JOIN sys.dm_xe_session_targets AS T
            ON S.address = T.event_session_address

        WHERE S.name = 'system_health'
          AND T.target_name = 'event_file';

        IF @TargetData IS NOT NULL
        BEGIN

            SET @EventFilePath = @TargetData.value
            (
                '(/EventFileTarget/File/@name)[1]',
                'NVARCHAR(260)'
            );

        END;

        SET @EventFileAvailable =
            CASE
                WHEN NULLIF(@EventFilePath, '') IS NOT NULL
                    THEN 1
                ELSE 0
            END;

    END
    ELSE
    BEGIN

        SET @EventFileAvailable = NULL;

    END;

    INSERT INTO @Metrics
    VALUES
    (
        'DLK-001',
        'Deadlocks',
        'Instance',
        @ServerName,
        'System Health Session Running',
        @SessionRunning,
        'Boolean',
        'SUCCESS',
        NULL
    ),
    (
        'DLK-002',
        'Deadlocks',
        'Instance',
        @ServerName,
        'Event File Target Available',
        @EventFileAvailable,
        'Boolean',

        CASE
            WHEN @EventFileAvailable IS NULL
                THEN 'UNKNOWN'
            ELSE 'SUCCESS'
        END,

        CASE
            WHEN ISNULL(@EventFileAvailable, 0) = 0
                THEN 'System health event file unavailable.'
            ELSE NULL
        END
    );

END TRY

BEGIN CATCH

    INSERT INTO @Metrics
    VALUES
    (
        'DLK-000',
        'Collection',
        'Instance',
        @ServerName,
        'System Health Session Validation',
        NULL,
        'Status',
        'FAILED',
        ERROR_MESSAGE()
    );

END CATCH;

------------------------------------------------------------
-- SECTION 4: Deadlock Event Collection
------------------------------------------------------------

/*
Initial implementation reads only the current XE file.

The production collection service will implement persistent
file and offset checkpoints, rollover handling and event
deduplication across collection cycles.

Do not use an unrestricted wildcard scan of all XE files
during frequent monitoring.
*/

IF @SessionRunning = 1
AND @EventFileAvailable = 1

BEGIN

    BEGIN TRY

        ;WITH RawEvents AS
        (
            SELECT

                CONVERT
                (
                    VARCHAR(64),

                    HASHBYTES
                    (
                        'SHA2_256',

                        CONCAT
                        (
                            CONVERT(NVARCHAR(MAX), X.file_name),
                            '|',
                            X.file_offset,
                            '|',
                            CONVERT(VARCHAR(33),
                                X.timestamp_utc, 126),
                            '|',
                            X.event_data
                        )
                    ),

                    2

                ) AS EventID,

                X.timestamp_utc AS EventTimeUTC,

                TRY_CAST(X.event_data AS XML)
                    AS EventXML

            FROM sys.fn_xe_file_target_read_file
            (
                @EventFilePath,
                NULL,
                NULL,
                NULL
            ) AS X

            WHERE X.object_name = 'xml_deadlock_report'

              AND X.timestamp_utc >= @WindowStart

              AND X.timestamp_utc <= @CaptureDate
        ),

        UniqueEvents AS
        (
            SELECT
                EventID,
                EventTimeUTC,
                EventXML,

                ROW_NUMBER() OVER
                (
                    PARTITION BY EventID
                    ORDER BY EventTimeUTC

                ) AS RowNumber

            FROM RawEvents
        )

        INSERT INTO @Deadlocks
        SELECT
            EventID,
            EventTimeUTC,
            EventXML

        FROM UniqueEvents

        WHERE RowNumber = 1;

        SET @CollectionSucceeded = 1;

    END TRY

    BEGIN CATCH

        INSERT INTO @Metrics
        VALUES
        (
            'DLK-099',
            'Collection',
            'Instance',
            @ServerName,
            'Deadlock Event File Collection',
            NULL,
            'Status',
            'FAILED',
            ERROR_MESSAGE()
        );

    END CATCH;

END;

------------------------------------------------------------
-- SECTION 5: Deadlock Summary Metrics
------------------------------------------------------------

IF @CollectionSucceeded = 1

BEGIN

    SELECT
        @DeadlockCount = COUNT_BIG(*),

        @LatestDeadlockUTC = MAX(EventTimeUTC)

    FROM @Deadlocks;

    SET @LatestDeadlockAge =
        CASE

            WHEN @LatestDeadlockUTC IS NOT NULL

            THEN DATEDIFF_BIG
            (
                SECOND,
                @LatestDeadlockUTC,
                @CaptureDate
            )

            ELSE NULL

        END;

END;

INSERT INTO @Metrics
VALUES
(
    'DLK-003',
    'Deadlocks',
    'Instance',
    @ServerName,
    'Deadlocks Observed In Collection Window',
    @DeadlockCount,
    'Count',

    CASE
        WHEN @CollectionSucceeded = 1
            THEN 'SUCCESS'
        ELSE 'UNKNOWN'
    END,

    CASE
        WHEN @CollectionSucceeded = 0
            THEN 'Deadlock event collection unavailable.'
        ELSE NULL
    END
),
(
    'DLK-004',
    'Deadlocks',
    'Instance',
    @ServerName,
    'Most Recent Observed Deadlock Age',
    @LatestDeadlockAge,
    'Seconds',

    CASE

        WHEN @CollectionSucceeded = 0
            THEN 'UNKNOWN'

        WHEN @DeadlockCount = 0
            THEN 'NOT APPLICABLE'

        WHEN @LatestDeadlockAge IS NULL
            THEN 'UNKNOWN'

        ELSE 'SUCCESS'

    END,

    CASE

        WHEN @CollectionSucceeded = 0
            THEN 'Deadlock collection unsuccessful.'

        WHEN @DeadlockCount = 0
            THEN 'No deadlocks found in the inspected file and window.'

        ELSE NULL

    END
);

------------------------------------------------------------
-- SECTION 6: Individual Deadlock Event Metrics
------------------------------------------------------------

IF @CollectionSucceeded = 1

BEGIN

    BEGIN TRY

        INSERT INTO @Metrics
        SELECT
            M.MetricID,
            'Deadlocks',
            'DeadlockEvent',
            D.EventID,
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
                    THEN 'Deadlock event details unavailable.'
                ELSE NULL
            END

        FROM @Deadlocks AS D

        CROSS APPLY
        (
            VALUES

            (
                'DLK-005',
                'Deadlock Victim Count',

                CONVERT(DECIMAL(28,4),

                    CASE

                        WHEN D.EventXML.exist
                        (
                            '/event/data/value/deadlock'
                        ) = 1

                        THEN D.EventXML.value
                        (
                            'count(
                                /event/data/value/deadlock/
                                victim-list/victimProcess
                            )',
                            'INT'
                        )

                        ELSE NULL

                    END
                ),

                'Count'
            ),
            (
                'DLK-006',
                'Deadlock Participating Process Count',

                CONVERT(DECIMAL(28,4),

                    CASE

                        WHEN D.EventXML.exist
                        (
                            '/event/data/value/deadlock'
                        ) = 1

                        THEN D.EventXML.value
                        (
                            'count(
                                /event/data/value/deadlock/
                                process-list/process
                            )',
                            'INT'
                        )

                        ELSE NULL

                    END
                ),

                'Count'
            ),
            (
                'DLK-007',
                'Deadlock Resource Count',

                CONVERT(DECIMAL(28,4),

                    CASE

                        WHEN D.EventXML.exist
                        (
                            '/event/data/value/deadlock'
                        ) = 1

                        THEN D.EventXML.value
                        (
                            'count(
                                /event/data/value/deadlock/
                                resource-list/*
                            )',
                            'INT'
                        )

                        ELSE NULL

                    END
                ),

                'Count'
            ),
            (
                'DLK-010',
                'Deadlock Event Timestamp UTC',

                CONVERT(DECIMAL(28,4),

                    DATEDIFF_BIG
                    (
                        MILLISECOND,
                        CONVERT(DATETIME2, '19700101'),
                        D.EventTimeUTC
                    ) / 1000.0

                ),

                'UnixSeconds'
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
            'DLK-098',
            'Collection',
            'Instance',
            @ServerName,
            'Deadlock Event Detail Collection',
            NULL,
            'Status',
            'FAILED',
            ERROR_MESSAGE()
        );

    END CATCH;

END;

------------------------------------------------------------
-- SECTION 7: Collection Coverage
------------------------------------------------------------

INSERT INTO @Metrics
VALUES
(
    'DLK-009',
    'Collection',
    'Instance',
    @ServerName,
    'Deadlock Collection Lookback Period',
    @LookbackMinutes,
    'Minutes',
    'SUCCESS',
    NULL
),
(
    'DLK-011',
    'Collection',
    'Instance',
    @ServerName,
    'Full Deadlock Window Coverage Verified',
    0,
    'Boolean',
    'SUCCESS',
    'Current event file only. Rollover coverage not verified.'
),
(
    'DLK-012',
    'Collection',
    'Instance',
    @ServerName,
    'Deadlock Event File Collection Successful',
    @CollectionSucceeded,
    'Boolean',
    'SUCCESS',
    NULL
);

------------------------------------------------------------
-- SECTION 8: Collection Performance
------------------------------------------------------------

INSERT INTO @Metrics
VALUES
(
    'DLK-008',
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
