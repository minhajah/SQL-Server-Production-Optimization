/*
============================================================
Project : SQL Server Production Optimization
Module  : 26 - Data Collection
Script  : 12-Error-Log-Collector.sql
Purpose : Collect SQL Server error log health metrics
Type    : Read-Only Monitoring Collector
Impact  : Controlled - dependent on error log size
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
    @LocalCaptureDate DATETIME = GETDATE(),
    @ServerName NVARCHAR(128),

    @LookbackMinutes INT = 15,
    @MaximumLogSizeMB INT = 50,
    @WindowStart DATETIME,

    @CurrentLogSizeBytes BIGINT,
    @CurrentLogSizeMB DECIMAL(28,4),
    @CollectionSucceeded BIT = 0,
    @CollectionSkipped BIT = 0,
    @LogSizeCheckSucceeded BIT = 0,
    @LogEntryCount BIGINT,
    @CollectionMessage NVARCHAR(2048);

SET @ServerName =
    CONVERT(NVARCHAR(128), SERVERPROPERTY('ServerName'));

SET @WindowStart =
    DATEADD(MINUTE, -@LookbackMinutes, @LocalCaptureDate);

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

DECLARE @ErrorLogInventory TABLE
(
    ArchiveNumber INT,
    LogDate DATETIME,
    LogSizeBytes BIGINT
);

DECLARE @ErrorLog TABLE
(
    LogDate DATETIME,
    ProcessInfo NVARCHAR(128),
    LogText NVARCHAR(MAX)
);

DECLARE @ParsedErrors TABLE
(
    LogDate DATETIME,
    ErrorNumber INT,
    ErrorSeverity INT
);

------------------------------------------------------------
-- SECTION 3: Error Log Inventory and Size Validation
------------------------------------------------------------

BEGIN TRY

    INSERT INTO @ErrorLogInventory

    EXEC master.sys.sp_enumerrorlogs
        @p1 = 1;

    SELECT
        @CurrentLogSizeBytes = LogSizeBytes

    FROM @ErrorLogInventory

    WHERE ArchiveNumber = 0;

    IF @CurrentLogSizeBytes IS NOT NULL
       AND @CurrentLogSizeBytes >= 0
    BEGIN

        SET @CurrentLogSizeMB =
            @CurrentLogSizeBytes / 1048576.0;

        SET @LogSizeCheckSucceeded = 1;

    END
    ELSE
    BEGIN

        SET @CollectionMessage =
            'Current SQL Server error log size unavailable.';

    END;

END TRY

BEGIN CATCH

    SET @CollectionMessage = ERROR_MESSAGE();

    INSERT INTO @Metrics
    VALUES
    (
        'ERR-000',
        'Collection',
        'Instance',
        @ServerName,
        'Error Log Inventory Collection',
        NULL,
        'Status',
        'FAILED',
        ERROR_MESSAGE()
    );

END CATCH;

------------------------------------------------------------
-- SECTION 4: Error Log Safety Validation
------------------------------------------------------------

IF @LogSizeCheckSucceeded = 0
BEGIN

    SET @CollectionSkipped = 1;

    SET @CollectionMessage =
        COALESCE(
            @CollectionMessage,
            'Error log size could not be validated.'
        );

END

ELSE IF @CurrentLogSizeBytes >
        CONVERT(BIGINT, @MaximumLogSizeMB) * 1048576

BEGIN

    SET @CollectionSkipped = 1;

    SET @CollectionMessage = CONCAT
    (
        'Error log collection skipped. Current size: ',
        @CurrentLogSizeMB,
        ' MB. Maximum permitted size: ',
        @MaximumLogSizeMB,
        ' MB.'
    );

END;

------------------------------------------------------------
-- SECTION 5: Controlled Error Log Collection
------------------------------------------------------------

/*
Read current SQL Server error log only.

Date filtering limits returned rows but does not guarantee
that SQL Server avoids scanning the complete log file.

The size check is a preliminary safety control, not a
guaranteed limit on execution time or memory consumption.
*/

IF @CollectionSkipped = 0
AND @LogSizeCheckSucceeded = 1

BEGIN

    BEGIN TRY

        INSERT INTO @ErrorLog

        EXEC master.dbo.xp_readerrorlog
            0,
            1,
            NULL,
            NULL,
            @WindowStart,
            @LocalCaptureDate,
            N'asc';

        DELETE FROM @ErrorLog

        WHERE LogDate < @WindowStart
           OR LogDate > @LocalCaptureDate
           OR LogDate IS NULL;

        SET @CollectionSucceeded = 1;

        SELECT
            @LogEntryCount = COUNT_BIG(*)
        FROM @ErrorLog;

    END TRY

    BEGIN CATCH

        SET @CollectionSucceeded = 0;
        SET @CollectionMessage = ERROR_MESSAGE();

        INSERT INTO @Metrics
        VALUES
        (
            'ERR-099',
            'Collection',
            'Instance',
            @ServerName,
            'Error Log Content Collection',
            NULL,
            'Status',
            'FAILED',
            ERROR_MESSAGE()
        );

    END CATCH;

END;

------------------------------------------------------------
-- SECTION 6: Structured Error Number and Severity Parsing
------------------------------------------------------------

IF @CollectionSucceeded = 1

BEGIN

    BEGIN TRY

        INSERT INTO @ParsedErrors

        SELECT
            E.LogDate,

            TRY_CONVERT
            (
                INT,

                LTRIM(RTRIM
                (
                    SUBSTRING
                    (
                        E.LogText,
                        8,

                        CASE
                            WHEN P.ErrorComma > 8
                                THEN P.ErrorComma - 8
                            ELSE 0
                        END
                    )
                ))
            ),

            TRY_CONVERT
            (
                INT,

                LTRIM(RTRIM
                (
                    SUBSTRING
                    (
                        E.LogText,
                        P.SeverityStart + 9,

                        CASE

                            WHEN P.SeverityStart > 0
                             AND Q.SeverityComma >
                                 P.SeverityStart + 9

                            THEN Q.SeverityComma -
                                 (P.SeverityStart + 9)

                            ELSE 0

                        END
                    )
                ))
            )

        FROM @ErrorLog AS E

        CROSS APPLY
        (
            SELECT
                CHARINDEX(',', E.LogText, 8)
                    AS ErrorComma,

                CHARINDEX('Severity:', E.LogText)
                    AS SeverityStart

        ) AS P

        CROSS APPLY
        (
            SELECT
                CHARINDEX
                (
                    ',',
                    E.LogText,
                    P.SeverityStart + 9
                ) AS SeverityComma

        ) AS Q

        WHERE E.LogText LIKE N'Error: %'
          AND P.ErrorComma > 8;

    END TRY

    BEGIN CATCH

        SET @CollectionSucceeded = 0;
        SET @CollectionMessage = ERROR_MESSAGE();

        INSERT INTO @Metrics
        VALUES
        (
            'ERR-098',
            'Collection',
            'Instance',
            @ServerName,
            'Error Log Parsing',
            NULL,
            'Status',
            'FAILED',
            ERROR_MESSAGE()
        );

    END CATCH;

END;

------------------------------------------------------------
-- SECTION 7: Operational Error Metrics
------------------------------------------------------------

IF @CollectionSucceeded = 1

BEGIN

    INSERT INTO @Metrics
    SELECT
        M.MetricID,
        'Error Log',
        'Instance',
        @ServerName,
        M.MetricName,
        CONVERT(DECIMAL(28,4), M.MetricValue),
        'Count',
        'SUCCESS',
        NULL

    FROM
    (
        SELECT

            COUNT_BIG(CASE
                WHEN ErrorSeverity BETWEEN 17 AND 19
                    THEN 1 END)
                AS Severity17To19,

            COUNT_BIG(CASE
                WHEN ErrorSeverity BETWEEN 20 AND 25
                    THEN 1 END)
                AS Severity20To25,

            COUNT_BIG(CASE
                WHEN ErrorNumber = 18456
                    THEN 1 END)
                AS FailedLogins,

            COUNT_BIG(CASE
                WHEN ErrorNumber = 823
                    THEN 1 END)
                AS Error823,

            COUNT_BIG(CASE
                WHEN ErrorNumber = 824
                    THEN 1 END)
                AS Error824,

            COUNT_BIG(CASE
                WHEN ErrorNumber = 825
                    THEN 1 END)
                AS Error825,

            COUNT_BIG(CASE
                WHEN ErrorNumber = 9002
                    THEN 1 END)
                AS Error9002,

            COUNT_BIG(CASE
                WHEN ErrorNumber = 3414
                    THEN 1 END)
                AS Error3414,

            COUNT_BIG(CASE
                WHEN ErrorNumber = 35273
                    THEN 1 END)
                AS Error35273,

            COUNT_BIG(CASE
                WHEN ErrorNumber = 3041
                    THEN 1 END)
                AS Error3041,

            COUNT_BIG(CASE
                WHEN ErrorNumber = 1105
                    THEN 1 END)
                AS Error1105,

            COUNT_BIG(CASE
                WHEN ErrorNumber = 701
                    THEN 1 END)
                AS Error701,

            COUNT_BIG(CASE
                WHEN ErrorNumber = 5144
                    THEN 1 END)
                AS Error5144,

            COUNT_BIG(CASE
                WHEN ErrorNumber = 833
                    THEN 1 END)
                AS Error833

        FROM @ParsedErrors

    ) AS E

    CROSS APPLY
    (
        VALUES

        (
            'ERR-003',
            'Severity 17 To 19 Errors',
            E.Severity17To19
        ),
        (
            'ERR-004',
            'Severity 20 To 25 Errors',
            E.Severity20To25
        ),
        (
            'ERR-005',
            'Failed Login Errors 18456',
            E.FailedLogins
        ),
        (
            'ERR-006',
            'IO Error 823',
            E.Error823
        ),
        (
            'ERR-007',
            'IO Error 824',
            E.Error824
        ),
        (
            'ERR-008',
            'IO Retry Error 825',
            E.Error825
        ),
        (
            'ERR-009',
            'Transaction Log Full Error 9002',
            E.Error9002
        ),
        (
            'ERR-010',
            'Database Recovery Error 3414',
            E.Error3414
        ),
        (
            'ERR-011',
            'Always On Error 35273',
            E.Error35273
        ),
        (
            'ERR-012',
            'Backup Failure Error 3041',
            E.Error3041
        ),
        (
            'ERR-013',
            'Filegroup Allocation Error 1105',
            E.Error1105
        ),
        (
            'ERR-014',
            'Insufficient Memory Error 701',
            E.Error701
        ),
        (
            'ERR-020',
            'File Autogrowth Cancellation Error 5144',
            E.Error5144
        ),
        (
            'ERR-021',
            'Long IO Warning Error 833',
            E.Error833
        )

    ) AS M
    (
        MetricID,
        MetricName,
        MetricValue
    );

END

ELSE

BEGIN

    INSERT INTO @Metrics
    SELECT
        M.MetricID,
        'Error Log',
        'Instance',
        @ServerName,
        M.MetricName,
        NULL,
        'Count',

        CASE
            WHEN @CollectionSkipped = 1
                THEN 'UNKNOWN'
            ELSE 'FAILED'
        END,

        @CollectionMessage

    FROM
    (
        VALUES

        ('ERR-003', 'Severity 17 To 19 Errors'),
        ('ERR-004', 'Severity 20 To 25 Errors'),
        ('ERR-005', 'Failed Login Errors 18456'),
        ('ERR-006', 'IO Error 823'),
        ('ERR-007', 'IO Error 824'),
        ('ERR-008', 'IO Retry Error 825'),
        ('ERR-009', 'Transaction Log Full Error 9002'),
        ('ERR-010', 'Database Recovery Error 3414'),
        ('ERR-011', 'Always On Error 35273'),
        ('ERR-012', 'Backup Failure Error 3041'),
        ('ERR-013', 'Filegroup Allocation Error 1105'),
        ('ERR-014', 'Insufficient Memory Error 701'),
        ('ERR-020', 'File Autogrowth Cancellation Error 5144'),
        ('ERR-021', 'Long IO Warning Error 833')

    ) AS M
    (
        MetricID,
        MetricName
    );

END;

------------------------------------------------------------
-- SECTION 8: Collection Status and Coverage
------------------------------------------------------------

INSERT INTO @Metrics
VALUES
(
    'ERR-001',
    'Collection',
    'Instance',
    @ServerName,
    'Error Log Collection Successful',
    @CollectionSucceeded,
    'Boolean',
    'SUCCESS',
    @CollectionMessage
),
(
    'ERR-002',
    'Error Log',
    'Instance',
    @ServerName,
    'Error Log Entries Observed',
    CASE WHEN @CollectionSucceeded = 1
        THEN @LogEntryCount ELSE NULL END,
    'Count',
    CASE WHEN @CollectionSucceeded = 1
        THEN 'SUCCESS' ELSE 'UNKNOWN' END,
    @CollectionMessage
),
(
    'ERR-016',
    'Collection',
    'Instance',
    @ServerName,
    'Error Log Collection Lookback Period',
    @LookbackMinutes,
    'Minutes',
    'SUCCESS',
    NULL
),
(
    'ERR-017',
    'Error Log',
    'Instance',
    @ServerName,
    'Current Error Log Size',
    @CurrentLogSizeMB,
    'MB',
    CASE WHEN @LogSizeCheckSucceeded = 1
        THEN 'SUCCESS' ELSE 'UNKNOWN' END,
    NULL
),
(
    'ERR-018',
    'Collection',
    'Instance',
    @ServerName,
    'Error Log Content Collection Skipped',
    @CollectionSkipped,
    'Boolean',
    'SUCCESS',
    CASE WHEN @CollectionSkipped = 1
        THEN @CollectionMessage ELSE NULL END
),
(
    'ERR-019',
    'Collection',
    'Instance',
    @ServerName,
    'Full Error Log Window Coverage Verified',
    0,
    'Boolean',
    'SUCCESS',
    'Current error log only. Archive coverage not verified.'
),
(
    'ERR-022',
    'Collection',
    'Instance',
    @ServerName,
    'Maximum Permitted Error Log Scan Size',
    @MaximumLogSizeMB,
    'MB',
    'SUCCESS',
    NULL
),
(
    'ERR-023',
    'Collection',
    'Instance',
    @ServerName,
    'Error Log Size Validation Successful',
    @LogSizeCheckSucceeded,
    'Boolean',
    'SUCCESS',
    NULL
);

------------------------------------------------------------
-- SECTION 9: Collection Performance
------------------------------------------------------------

INSERT INTO @Metrics
VALUES
(
    'ERR-015',
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
-- SECTION 10: Standardized Monitoring Output
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
