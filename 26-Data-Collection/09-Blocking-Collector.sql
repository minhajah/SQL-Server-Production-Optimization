/*
============================================================
Project : SQL Server Production Optimization
Module  : 26 - Data Collection
Script  : 09-Blocking-Collector.sql
Purpose : Collect blocking and active transaction metrics
Type    : Read-Only Monitoring Collector
Impact  : Low - dependent on active session count
Frequency: 30-60 Seconds (Proposed)
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

    @BlockedRequests BIGINT,
    @BlockedSessions BIGINT,
    @BlockingSessions BIGINT,
    @HeadBlockers BIGINT,
    @MaxBlockingWait BIGINT,

    @BlockedOver30 BIGINT,
    @BlockedOver60 BIGINT,
    @BlockedOver300 BIGINT,

    @SuspendedRequests BIGINT,
    @NegativeBlockers BIGINT,

    @ActiveTransactions BIGINT,
    @OldestTransactionAge BIGINT,
    @TransactionsOver5Min BIGINT,
    @TransactionsOver30Min BIGINT;

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

DECLARE @Requests TABLE
(
    SessionID INT,
    RequestID INT,
    BlockingSessionID INT,
    DatabaseID INT,
    WaitTimeMS BIGINT,
    RequestStatus NVARCHAR(30),
    IsUserProcess BIT,

    PRIMARY KEY (SessionID, RequestID)
);

DECLARE @Blockers TABLE
(
    SessionID INT PRIMARY KEY,
    BlockedSessionCount BIGINT,
    IsHeadBlocker INT,
    IsSleeping INT,
    OpenTransactionCount INT,
    LoginTime DATETIME
);

DECLARE @Transactions TABLE
(
    TransactionID BIGINT PRIMARY KEY,
    TransactionBeginTime DATETIME,
    TransactionAgeSeconds BIGINT
);

DECLARE @SessionTransactions TABLE
(
    SessionID INT,
    TransactionID BIGINT,

    PRIMARY KEY (SessionID, TransactionID)
);

------------------------------------------------------------
-- SECTION 3: Active Request Collection
------------------------------------------------------------

BEGIN TRY

    INSERT INTO @Requests
    SELECT
        R.session_id,
        R.request_id,
        R.blocking_session_id,
        R.database_id,
        CONVERT(BIGINT, R.wait_time),
        R.status,
        S.is_user_process

    FROM sys.dm_exec_requests AS R

    INNER JOIN sys.dm_exec_sessions AS S
        ON R.session_id = S.session_id

    WHERE R.session_id <> @@SPID;

    --------------------------------------------------------
    -- Blocking summary
    --------------------------------------------------------

    SELECT

        @BlockedRequests = COUNT_BIG(CASE
            WHEN IsUserProcess = 1
             AND BlockingSessionID > 0
             AND BlockingSessionID <> SessionID
                THEN 1 END),

        @BlockedSessions = COUNT(DISTINCT CASE
            WHEN IsUserProcess = 1
             AND BlockingSessionID > 0
             AND BlockingSessionID <> SessionID
                THEN SessionID END),

        @BlockingSessions = COUNT(DISTINCT CASE
            WHEN IsUserProcess = 1
             AND BlockingSessionID > 0
             AND BlockingSessionID <> SessionID
                THEN BlockingSessionID END),

        @MaxBlockingWait = MAX(CASE
            WHEN IsUserProcess = 1
             AND BlockingSessionID > 0
             AND BlockingSessionID <> SessionID
                THEN WaitTimeMS END),

        @BlockedOver30 = COUNT_BIG(CASE
            WHEN IsUserProcess = 1
             AND BlockingSessionID > 0
             AND BlockingSessionID <> SessionID
             AND WaitTimeMS >= 30000
                THEN 1 END),

        @BlockedOver60 = COUNT_BIG(CASE
            WHEN IsUserProcess = 1
             AND BlockingSessionID > 0
             AND BlockingSessionID <> SessionID
             AND WaitTimeMS >= 60000
                THEN 1 END),

        @BlockedOver300 = COUNT_BIG(CASE
            WHEN IsUserProcess = 1
             AND BlockingSessionID > 0
             AND BlockingSessionID <> SessionID
             AND WaitTimeMS >= 300000
                THEN 1 END),

        @SuspendedRequests = COUNT_BIG(CASE
            WHEN IsUserProcess = 1
             AND RequestStatus = 'suspended'
                THEN 1 END),

        @NegativeBlockers = COUNT_BIG(CASE
            WHEN IsUserProcess = 1
             AND BlockingSessionID < 0
                THEN 1 END)

    FROM @Requests;

    IF @BlockedRequests = 0
        SET @MaxBlockingWait = 0;

    --------------------------------------------------------
    -- SECTION 4: Blocking Session Identification
    --------------------------------------------------------

    ;WITH BlockingSummary AS
    (
        SELECT
            BlockingSessionID,
            COUNT(DISTINCT SessionID)
                AS BlockedSessionCount

        FROM @Requests

        WHERE IsUserProcess = 1
          AND BlockingSessionID > 0
          AND BlockingSessionID <> SessionID

        GROUP BY BlockingSessionID
    )

    INSERT INTO @Blockers
    SELECT
        B.BlockingSessionID,
        B.BlockedSessionCount,

        CASE

            WHEN S.session_id IS NULL
                THEN NULL

            WHEN EXISTS
            (
                SELECT 1
                FROM @Requests AS R

                WHERE R.SessionID =
                    B.BlockingSessionID

                AND R.BlockingSessionID <> 0
                AND R.BlockingSessionID <> R.SessionID
            )
                THEN 0

            ELSE 1

        END,

        CASE
            WHEN S.session_id IS NULL THEN NULL
            WHEN S.status = 'sleeping' THEN 1
            ELSE 0
        END,

        S.open_transaction_count,
        S.login_time

    FROM BlockingSummary AS B

    LEFT JOIN sys.dm_exec_sessions AS S
        ON B.BlockingSessionID = S.session_id;

    SELECT

        @HeadBlockers =

            CASE

                WHEN COUNT_BIG(CASE
                    WHEN IsHeadBlocker IS NULL
                        THEN 1 END) > 0

                    THEN NULL

                ELSE COUNT_BIG(CASE
                    WHEN IsHeadBlocker = 1
                        THEN 1 END)

            END

    FROM @Blockers;

    --------------------------------------------------------
    -- SECTION 5: Instance-Level Blocking Metrics
    --------------------------------------------------------

    INSERT INTO @Metrics
    SELECT
        M.MetricID,
        'Blocking',
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
                THEN 'Blocking information incomplete.'
            ELSE NULL
        END

    FROM
    (
        VALUES

        (
            'BLK-001',
            'Total Blocked Requests',
            CONVERT(DECIMAL(28,4), @BlockedRequests),
            'Count'
        ),
        (
            'BLK-002',
            'Total Blocked Sessions',
            CONVERT(DECIMAL(28,4), @BlockedSessions),
            'Count'
        ),
        (
            'BLK-003',
            'Distinct Blocking Sessions',
            CONVERT(DECIMAL(28,4), @BlockingSessions),
            'Count'
        ),
        (
            'BLK-004',
            'Identified Head Blockers',
            CONVERT(DECIMAL(28,4), @HeadBlockers),
            'Count'
        ),
        (
            'BLK-005',
            'Maximum Current Blocking Wait',
            CONVERT(DECIMAL(28,4), @MaxBlockingWait)
                / 1000.0,
            'Seconds'
        ),
        (
            'BLK-006',
            'Requests Blocked Over 30 Seconds',
            CONVERT(DECIMAL(28,4), @BlockedOver30),
            'Count'
        ),
        (
            'BLK-007',
            'Requests Blocked Over 60 Seconds',
            CONVERT(DECIMAL(28,4), @BlockedOver60),
            'Count'
        ),
        (
            'BLK-008',
            'Requests Blocked Over 300 Seconds',
            CONVERT(DECIMAL(28,4), @BlockedOver300),
            'Count'
        ),
        (
            'BLK-009',
            'Suspended User Requests',
            CONVERT(DECIMAL(28,4), @SuspendedRequests),
            'Count'
        ),
        (
            'BLK-022',
            'Requests With Negative Blocker IDs',
            CONVERT(DECIMAL(28,4), @NegativeBlockers),
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
    -- SECTION 6: Blocked Request Metrics
    --------------------------------------------------------

    INSERT INTO @Metrics
    SELECT
        M.MetricID,
        'Blocking',
        'SessionRequest',

        CONCAT(
            R.SessionID,
            ':',
            R.RequestID
        ),

        M.MetricName,
        M.MetricValue,
        M.MetricUnit,

        CASE
            WHEN M.MetricValue IS NULL
                THEN 'UNKNOWN'
            ELSE 'SUCCESS'
        END,

        NULL

    FROM @Requests AS R

    CROSS APPLY
    (
        VALUES

        (
            'BLK-010',
            'Current Blocking Wait Duration',

            CONVERT(DECIMAL(28,4), R.WaitTimeMS)
                / 1000.0,

            'Seconds'
        ),
        (
            'BLK-011',
            'Blocking Session ID',
            CONVERT(DECIMAL(28,4), R.BlockingSessionID),
            'Identifier'
        ),
        (
            'BLK-012',
            'Blocked Request Database ID',
            CONVERT(DECIMAL(28,4), R.DatabaseID),
            'Identifier'
        )

    ) AS M
    (
        MetricID,
        MetricName,
        MetricValue,
        MetricUnit
    )

    WHERE R.IsUserProcess = 1
      AND R.BlockingSessionID <> 0
      AND R.BlockingSessionID <> R.SessionID;

    --------------------------------------------------------
    -- SECTION 7: Blocking Session Metrics
    --------------------------------------------------------

    INSERT INTO @Metrics
    SELECT
        M.MetricID,
        'Blocking',
        'BlockingSession',

        CONCAT(
            B.SessionID,
            ':',
            COALESCE(
                CONVERT(VARCHAR(30),
                    B.LoginTime, 126),
                'Unknown'
            )
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
                THEN 'Blocking session information unavailable.'
            ELSE NULL
        END

    FROM @Blockers AS B

    CROSS APPLY
    (
        VALUES

        (
            'BLK-013',
            'Directly Blocked Sessions',
            CONVERT(DECIMAL(28,4),
                B.BlockedSessionCount),
            'Count'
        ),
        (
            'BLK-014',
            'Head Blocker Indicator',
            CONVERT(DECIMAL(28,4),
                B.IsHeadBlocker),
            'Boolean'
        ),
        (
            'BLK-015',
            'Sleeping Blocker Indicator',
            CONVERT(DECIMAL(28,4),
                B.IsSleeping),
            'Boolean'
        ),
        (
            'BLK-016',
            'Blocker Open Transaction Count',
            CONVERT(DECIMAL(28,4),
                B.OpenTransactionCount),
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
    VALUES
    (
        'BLK-000',
        'Collection',
        'Instance',
        @ServerName,
        'Blocking Collection',
        NULL,
        'Status',
        'FAILED',
        ERROR_MESSAGE()
    );

END CATCH;

------------------------------------------------------------
-- SECTION 8: Active Transaction Collection
------------------------------------------------------------

BEGIN TRY

    INSERT INTO @SessionTransactions
    SELECT DISTINCT
        ST.session_id,
        ST.transaction_id

    FROM sys.dm_tran_session_transactions AS ST

    INNER JOIN sys.dm_exec_sessions AS S
        ON ST.session_id = S.session_id

    WHERE ST.is_user_transaction = 1
      AND S.is_user_process = 1
      AND ST.session_id <> @@SPID;

    INSERT INTO @Transactions
    SELECT
        T.transaction_id,
        T.transaction_begin_time,

        CASE
            WHEN T.transaction_begin_time
                <= @LocalCaptureDate

            THEN DATEDIFF_BIG
            (
                SECOND,
                T.transaction_begin_time,
                @LocalCaptureDate
            )

            ELSE NULL
        END

    FROM sys.dm_tran_active_transactions AS T

    WHERE EXISTS
    (
        SELECT 1

        FROM @SessionTransactions AS ST

        WHERE ST.TransactionID =
            T.transaction_id
    )

    AND T.transaction_type IN (1, 2, 4)
    AND T.transaction_state IN (2, 4, 5, 7);

    --------------------------------------------------------
    -- Transaction summary
    --------------------------------------------------------

    SELECT

        @ActiveTransactions = COUNT_BIG(*),

        @OldestTransactionAge =
            MAX(TransactionAgeSeconds),

        @TransactionsOver5Min = COUNT_BIG(CASE
            WHEN TransactionAgeSeconds >= 300
                THEN 1 END),

        @TransactionsOver30Min = COUNT_BIG(CASE
            WHEN TransactionAgeSeconds >= 1800
                THEN 1 END)

    FROM @Transactions;

    IF @ActiveTransactions = 0
        SET @OldestTransactionAge = 0;

    --------------------------------------------------------
    -- Transaction monitoring metrics
    --------------------------------------------------------

    INSERT INTO @Metrics
    SELECT
        M.MetricID,
        'Transactions',
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

        NULL

    FROM
    (
        VALUES

        (
            'BLK-017',
            'Active User Transactions',
            CONVERT(DECIMAL(28,4), @ActiveTransactions),
            'Count'
        ),
        (
            'BLK-018',
            'Oldest Active User Transaction Age',
            CONVERT(DECIMAL(28,4),
                @OldestTransactionAge),
            'Seconds'
        ),
        (
            'BLK-019',
            'Transactions Older Than 5 Minutes',
            CONVERT(DECIMAL(28,4),
                @TransactionsOver5Min),
            'Count'
        ),
        (
            'BLK-020',
            'Transactions Older Than 30 Minutes',
            CONVERT(DECIMAL(28,4),
                @TransactionsOver30Min),
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
    -- SECTION 9: Session Transaction Age
    --------------------------------------------------------

    INSERT INTO @Metrics
    SELECT
        'BLK-023',
        'Transactions',
        'Session',

        CONCAT(
            ST.SessionID,
            ':',
            COALESCE(
                CONVERT(VARCHAR(30),
                    S.login_time, 126),
                'Unknown'
            )
        ),

        'Oldest Transaction Age Per Session',

        CONVERT(DECIMAL(28,4),
            MAX(T.TransactionAgeSeconds)),

        'Seconds',

        CASE
            WHEN MAX(T.TransactionAgeSeconds) IS NULL
                THEN 'UNKNOWN'
            ELSE 'SUCCESS'
        END,

        NULL

    FROM @SessionTransactions AS ST

    INNER JOIN @Transactions AS T
        ON ST.TransactionID = T.TransactionID

    LEFT JOIN sys.dm_exec_sessions AS S
        ON ST.SessionID = S.session_id

    GROUP BY
        ST.SessionID,
        S.login_time

    HAVING MAX(T.TransactionAgeSeconds) >= 300;

END TRY

BEGIN CATCH

    INSERT INTO @Metrics
    VALUES
    (
        'BLK-099',
        'Collection',
        'Instance',
        @ServerName,
        'Active Transaction Collection',
        NULL,
        'Status',
        'FAILED',
        ERROR_MESSAGE()
    );

END CATCH;

------------------------------------------------------------
-- SECTION 10: Collection Performance
------------------------------------------------------------

INSERT INTO @Metrics
VALUES
(
    'BLK-021',
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
-- SECTION 11: Standardized Monitoring Output
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
