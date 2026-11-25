/*
============================================================
Project : SQL Server Production Optimization
Module  : 26 - Data Collection
Script  : 15-Long-Running-Query-Collector.sql
Purpose : Collect active and resource-intensive request metrics
Type    : Read-Only Monitoring Collector
Impact  : Low - dependent on active request count
Frequency: 60 Seconds (Proposed)
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
    @ServerName NVARCHAR(128),

    @LongRunningThresholdMS BIGINT = 60000,
    @CPUThresholdMS BIGINT = 30000,
    @LogicalReadThreshold BIGINT = 100000,

    @MaximumDetailedRequests INT = 50,

    @ActiveRequests BIGINT,
    @LongRunningRequests BIGINT,
    @RequestsOver5Min BIGINT,
    @RequestsOver15Min BIGINT,
    @MaximumElapsedTimeMS BIGINT,
    @CPUIntensiveRequests BIGINT,
    @HighLogicalReadRequests BIGINT,

    @QualifiedRequests BIGINT,
    @DetailedRequests BIGINT,

    @RequiredPermission NVARCHAR(128);

SET @ServerName =
    CONVERT(NVARCHAR(128), SERVERPROPERTY('ServerName'));

SET @RequiredPermission =
    CASE
        WHEN TRY_CONVERT(
            INT, SERVERPROPERTY('ProductMajorVersion')
        ) >= 16
            THEN 'VIEW SERVER PERFORMANCE STATE'
        ELSE 'VIEW SERVER STATE'
    END;

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

DECLARE @Requests TABLE
(
    SessionID INT,
    RequestID INT,
    DatabaseID INT,
    LoginTime DATETIME,
    RequestStartTime DATETIME,
    ElapsedTimeMS BIGINT,
    CPUTimeMS BIGINT,
    LogicalReads BIGINT,
    PhysicalReads BIGINT,
    Writes BIGINT,
    GrantedQueryMemoryPages BIGINT,
    BlockingSessionID INT,
    WaitTimeMS BIGINT,
    OpenTransactionCount INT,
    DegreeOfParallelism INT,
    PercentComplete REAL,
    IsQualified BIT DEFAULT 0,

    PRIMARY KEY (SessionID, RequestID)
);

------------------------------------------------------------
-- SECTION 3: Active Request Collection
------------------------------------------------------------

BEGIN TRY

    --------------------------------------------------------
    -- Validate instance-wide monitoring visibility
    --------------------------------------------------------

    IF ISNULL
    (
        HAS_PERMS_BY_NAME
        (
            NULL,
            NULL,
            @RequiredPermission
        ),
        0
    ) <> 1

    BEGIN

        THROW 50001,
            'Required server monitoring permission unavailable.',
            1;

    END;

    --------------------------------------------------------
    -- Capture currently executing user requests
    --------------------------------------------------------

    INSERT INTO @Requests
    (
        SessionID,
        RequestID,
        DatabaseID,
        LoginTime,
        RequestStartTime,
        ElapsedTimeMS,
        CPUTimeMS,
        LogicalReads,
        PhysicalReads,
        Writes,
        GrantedQueryMemoryPages,
        BlockingSessionID,
        WaitTimeMS,
        OpenTransactionCount,
        DegreeOfParallelism,
        PercentComplete
    )

    SELECT
        R.session_id,
        R.request_id,
        R.database_id,
        S.login_time,
        R.start_time,
        CONVERT(BIGINT, R.total_elapsed_time),
        CONVERT(BIGINT, R.cpu_time),
        R.logical_reads,
        R.reads,
        R.writes,
        R.granted_query_memory,
        R.blocking_session_id,
        CONVERT(BIGINT, R.wait_time),
        R.open_transaction_count,
        R.dop,
        R.percent_complete

    FROM sys.dm_exec_requests AS R

    INNER JOIN sys.dm_exec_sessions AS S
        ON R.session_id = S.session_id

    WHERE S.is_user_process = 1
      AND R.session_id <> @@SPID;

    --------------------------------------------------------
    -- Identify requests qualifying for detailed monitoring
    --------------------------------------------------------

    UPDATE @Requests

    SET IsQualified = 1

    WHERE ElapsedTimeMS >= @LongRunningThresholdMS

       OR CPUTimeMS >= @CPUThresholdMS

       OR LogicalReads >= @LogicalReadThreshold;

    --------------------------------------------------------
    -- SECTION 4: Instance-Level Request Summary
    --------------------------------------------------------

    SELECT

        @ActiveRequests = COUNT_BIG(*),

        @LongRunningRequests = COUNT_BIG
        (
            CASE
                WHEN ElapsedTimeMS >=
                    @LongRunningThresholdMS
                THEN 1
            END
        ),

        @RequestsOver5Min = COUNT_BIG
        (
            CASE
                WHEN ElapsedTimeMS >= 300000
                THEN 1
            END
        ),

        @RequestsOver15Min = COUNT_BIG
        (
            CASE
                WHEN ElapsedTimeMS >= 900000
                THEN 1
            END
        ),

        @MaximumElapsedTimeMS =
            MAX(ElapsedTimeMS),

        @CPUIntensiveRequests = COUNT_BIG
        (
            CASE
                WHEN CPUTimeMS >= @CPUThresholdMS
                THEN 1
            END
        ),

        @HighLogicalReadRequests = COUNT_BIG
        (
            CASE
                WHEN LogicalReads >= @LogicalReadThreshold
                THEN 1
            END
        ),

        @QualifiedRequests = COUNT_BIG
        (
            CASE
                WHEN IsQualified = 1
                THEN 1
            END
        )

    FROM @Requests;

    IF @ActiveRequests = 0
        SET @MaximumElapsedTimeMS = 0;

    INSERT INTO @Metrics
    SELECT
        M.MetricID,
        'Query Performance',
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
                THEN 'Request summary unavailable.'
            ELSE NULL
        END

    FROM
    (
        VALUES

        (
            'QRY-001',
            'Active User Requests',
            CONVERT(DECIMAL(28,4), @ActiveRequests),
            'Count'
        ),
        (
            'QRY-002',
            'Long Running Requests',
            CONVERT(DECIMAL(28,4),
                @LongRunningRequests),
            'Count'
        ),
        (
            'QRY-003',
            'Requests Running Over 5 Minutes',
            CONVERT(DECIMAL(28,4),
                @RequestsOver5Min),
            'Count'
        ),
        (
            'QRY-004',
            'Requests Running Over 15 Minutes',
            CONVERT(DECIMAL(28,4),
                @RequestsOver15Min),
            'Count'
        ),
        (
            'QRY-005',
            'Maximum Request Elapsed Time',

            CONVERT(DECIMAL(28,4),
                @MaximumElapsedTimeMS) / 1000.0,

            'Seconds'
        ),
        (
            'QRY-006',
            'Requests Above CPU Time Threshold',
            CONVERT(DECIMAL(28,4),
                @CPUIntensiveRequests),
            'Count'
        ),
        (
            'QRY-007',
            'Requests Above Logical Read Threshold',
            CONVERT(DECIMAL(28,4),
                @HighLogicalReadRequests),
            'Count'
        ),
        (
            'QRY-022',
            'Requests Qualifying For Detailed Collection',
            CONVERT(DECIMAL(28,4),
                @QualifiedRequests),
            'Count'
        )

    ) AS M
    (
        MetricID,
        MetricName,
        MetricValue,
        MetricUnit
    );

    --------------------------------------------------------
    -- SECTION 5: Detailed Active Request Metrics
    --------------------------------------------------------

    ;WITH QualifiedRequests AS
    (
        SELECT TOP (@MaximumDetailedRequests)
            *

        FROM @Requests

        WHERE IsQualified = 1

        ORDER BY
            ElapsedTimeMS DESC,
            CPUTimeMS DESC,
            LogicalReads DESC,
            SessionID,
            RequestID
    )

    INSERT INTO @Metrics
    SELECT
        M.MetricID,
        'Query Performance',
        'SessionRequest',

        CONCAT
        (
            R.SessionID,
            ':',
            R.RequestID,
            ':',
            CONVERT(VARCHAR(30),
                R.LoginTime, 126),
            ':',
            CONVERT(VARCHAR(30),
                R.RequestStartTime, 126)
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
                THEN 'Request metric unavailable or not reported.'
            ELSE NULL
        END

    FROM QualifiedRequests AS R

    CROSS APPLY
    (
        VALUES

        (
            'QRY-008',
            'Request Elapsed Time',

            CONVERT(DECIMAL(28,4),
                R.ElapsedTimeMS) / 1000.0,

            'Seconds'
        ),
        (
            'QRY-009',
            'Request CPU Time',

            CONVERT(DECIMAL(28,4),
                R.CPUTimeMS) / 1000.0,

            'Seconds'
        ),
        (
            'QRY-010',
            'Request Logical Reads',

            CONVERT(DECIMAL(28,4),
                R.LogicalReads),

            'Count'
        ),
        (
            'QRY-011',
            'Request Physical Reads',

            CONVERT(DECIMAL(28,4),
                R.PhysicalReads),

            'Count'
        ),
        (
            'QRY-012',
            'Request Writes',

            CONVERT(DECIMAL(28,4),
                R.Writes),

            'Count'
        ),
        (
            'QRY-013',
            'Request Granted Query Memory',

            CONVERT(DECIMAL(28,4),
                R.GrantedQueryMemoryPages) / 128.0,

            'MB'
        ),
        (
            'QRY-014',
            'Request Database ID',

            CONVERT(DECIMAL(28,4),
                R.DatabaseID),

            'Identifier'
        ),
        (
            'QRY-015',
            'Request Session ID',

            CONVERT(DECIMAL(28,4),
                R.SessionID),

            'Identifier'
        ),
        (
            'QRY-016',
            'Request Blocking Session ID',

            CONVERT(DECIMAL(28,4),
                R.BlockingSessionID),

            'Identifier'
        ),
        (
            'QRY-017',
            'Request Current Wait Duration',

            CONVERT(DECIMAL(28,4),
                R.WaitTimeMS) / 1000.0,

            'Seconds'
        ),
        (
            'QRY-018',
            'Request Open Transaction Count',

            CONVERT(DECIMAL(28,4),
                R.OpenTransactionCount),

            'Count'
        ),
        (
            'QRY-019',
            'Request Degree Of Parallelism',

            CONVERT(DECIMAL(28,4),
                R.DegreeOfParallelism),

            'Count'
        ),
        (
            'QRY-020',
            'Request Reported Completion Percentage',

            CONVERT(DECIMAL(28,4),
                R.PercentComplete),

            'Percent'
        )

    ) AS M
    (
        MetricID,
        MetricName,
        MetricValue,
        MetricUnit
    );

    --------------------------------------------------------
    -- SECTION 6: Collection Completeness
    --------------------------------------------------------

    SELECT
        @DetailedRequests = COUNT_BIG(*)

    FROM @Metrics

    WHERE MetricID = 'QRY-008';

    INSERT INTO @Metrics
    VALUES
    (
        'QRY-023',
        'Collection',
        'Instance',
        @ServerName,
        'Requests Returned In Detailed Collection',
        @DetailedRequests,
        'Count',
        'SUCCESS',
        NULL
    ),
    (
        'QRY-024',
        'Collection',
        'Instance',
        @ServerName,
        'Detailed Request Collection Truncated',

        CASE
            WHEN @QualifiedRequests >
                @DetailedRequests
                THEN 1
            ELSE 0
        END,

        'Boolean',
        'SUCCESS',

        CASE
            WHEN @QualifiedRequests >
                @DetailedRequests

            THEN 'Qualifying requests exceeded detailed collection limit.'

            ELSE NULL
        END
    );

END TRY

BEGIN CATCH

    INSERT INTO @Metrics
    VALUES
    (
        'QRY-099',
        'Collection',
        'Instance',
        @ServerName,
        'Active Request Collection',
        NULL,
        'Status',
        'FAILED',
        ERROR_MESSAGE()
    );

END CATCH;

------------------------------------------------------------
-- SECTION 7: Collection Configuration
------------------------------------------------------------

INSERT INTO @Metrics
VALUES
(
    'QRY-025',
    'Collection',
    'Instance',
    @ServerName,
    'Long Running Request Collection Threshold',
    CONVERT(DECIMAL(28,4),
        @LongRunningThresholdMS) / 1000.0,
    'Seconds',
    'SUCCESS',
    NULL
),
(
    'QRY-026',
    'Collection',
    'Instance',
    @ServerName,
    'Request CPU Time Collection Threshold',
    CONVERT(DECIMAL(28,4),
        @CPUThresholdMS) / 1000.0,
    'Seconds',
    'SUCCESS',
    NULL
),
(
    'QRY-027',
    'Collection',
    'Instance',
    @ServerName,
    'Request Logical Reads Collection Threshold',
    @LogicalReadThreshold,
    'Count',
    'SUCCESS',
    NULL
),
(
    'QRY-028',
    'Collection',
    'Instance',
    @ServerName,
    'Maximum Detailed Requests Per Collection',
    @MaximumDetailedRequests,
    'Count',
    'SUCCESS',
    NULL
);

------------------------------------------------------------
-- SECTION 8: Collection Performance
------------------------------------------------------------

INSERT INTO @Metrics
VALUES
(
    'QRY-021',
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
