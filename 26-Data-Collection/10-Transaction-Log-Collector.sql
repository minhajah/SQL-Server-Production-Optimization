/*
============================================================
Project : SQL Server Production Optimization
Module  : 26 - Data Collection
Script  : 10-Transaction-Log-Collector.sql
Purpose : Collect transaction log utilization and health metrics
Type    : Read-Only Monitoring Collector
Impact  : Low to Moderate - dependent on database and VLF count
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
    @DatabaseCount BIGINT,
    @LogStatsCount BIGINT;

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

DECLARE @Databases TABLE
(
    DatabaseID INT PRIMARY KEY,
    DatabaseName NVARCHAR(128),
    DatabaseState INT,
    RecoveryModel INT,
    LogReuseWait INT
);

DECLARE @LogSpace TABLE
(
    DatabaseName NVARCHAR(128),
    LogSizeMB FLOAT,
    LogUsedPercent FLOAT,
    LogStatus INT
);

DECLARE @LogFiles TABLE
(
    DatabaseID INT PRIMARY KEY,
    AllocatedLogMB DECIMAL(28,4),
    LogFileCount INT,
    GrowthDisabledCount INT,
    PercentGrowthCount INT,
    MaximumSizeConfiguredCount INT,
    MaximumSizeReachedCount INT
);

DECLARE @LogStatsErrors TABLE
(
    DatabaseID INT PRIMARY KEY,
    ErrorMessage NVARCHAR(2048)
);

DECLARE @LogStats TABLE
(
    DatabaseID INT PRIMARY KEY,
    TotalVLFCount BIGINT,
    ActiveVLFCount BIGINT,
    ActiveLogSizeMB DECIMAL(28,4),
    LogSinceLastBackupMB DECIMAL(28,4),
    LogSinceLastCheckpointMB DECIMAL(28,4),
    TruncationHoldupReason NVARCHAR(60)
);

------------------------------------------------------------
-- SECTION 3: Database Inventory
------------------------------------------------------------

BEGIN TRY

    INSERT INTO @Databases
    SELECT
        database_id,
        name,
        state,
        recovery_model,
        log_reuse_wait

    FROM sys.databases

    WHERE source_database_id IS NULL;

    SELECT
        @DatabaseCount = COUNT_BIG(*)
    FROM @Databases;

END TRY

BEGIN CATCH

    INSERT INTO @Metrics
    VALUES
    (
        'LOG-000',
        'Collection',
        'Instance',
        @ServerName,
        'Transaction Log Database Inventory',
        NULL,
        'Status',
        'FAILED',
        ERROR_MESSAGE()
    );

END CATCH;

------------------------------------------------------------
-- SECTION 4: Transaction Log Space Collection
------------------------------------------------------------

BEGIN TRY

    INSERT INTO @LogSpace

    EXEC
    (
        'DBCC SQLPERF(LOGSPACE) WITH NO_INFOMSGS;'
    );

    --------------------------------------------------------
    -- Transaction log utilization metrics
    --------------------------------------------------------

    INSERT INTO @Metrics
    SELECT
        M.MetricID,
        'Transaction Log',
        'Database',
        D.DatabaseName,
        M.MetricName,
        M.MetricValue,
        M.MetricUnit,

        CASE

            WHEN D.DatabaseState <> 0
                THEN 'UNKNOWN'

            WHEN M.MetricValue IS NULL
                THEN 'UNKNOWN'

            ELSE 'SUCCESS'

        END,

        CASE

            WHEN D.DatabaseState <> 0
                THEN 'Database is not ONLINE.'

            WHEN M.MetricValue IS NULL
                THEN 'Log space information unavailable or invalid.'

            ELSE NULL

        END

    FROM @Databases AS D

    LEFT JOIN @LogSpace AS L
        ON D.DatabaseName = L.DatabaseName

    CROSS APPLY
    (
        VALUES

        (
            'LOG-001',
            'Total Allocated Transaction Log Size',

            CONVERT(DECIMAL(28,4),
                CASE
                    WHEN D.DatabaseState = 0
                     AND L.LogSizeMB > 0
                        THEN L.LogSizeMB
                END
            ),

            'MB'
        ),
        (
            'LOG-002',
            'Used Transaction Log Space',

            CONVERT(DECIMAL(28,4),
                CASE
                    WHEN D.DatabaseState = 0
                     AND L.LogSizeMB > 0
                     AND L.LogUsedPercent BETWEEN 0 AND 100

                        THEN L.LogSizeMB
                            * L.LogUsedPercent / 100.0
                END
            ),

            'MB'
        ),
        (
            'LOG-003',
            'Available Transaction Log Space',

            CONVERT(DECIMAL(28,4),
                CASE
                    WHEN D.DatabaseState = 0
                     AND L.LogSizeMB > 0
                     AND L.LogUsedPercent BETWEEN 0 AND 100

                        THEN L.LogSizeMB
                            * (100.0 - L.LogUsedPercent)
                            / 100.0
                END
            ),

            'MB'
        ),
        (
            'LOG-004',
            'Transaction Log Utilization',

            CONVERT(DECIMAL(28,4),
                CASE
                    WHEN D.DatabaseState = 0
                     AND L.LogSizeMB > 0
                     AND L.LogUsedPercent BETWEEN 0 AND 100

                        THEN L.LogUsedPercent
                END
            ),

            'Percent'
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
        'LOG-099',
        'Collection',
        'Instance',
        @ServerName,
        'Transaction Log Space Collection',
        NULL,
        'Status',
        'FAILED',
        ERROR_MESSAGE()
    );

END CATCH;

------------------------------------------------------------
-- SECTION 5: Transaction Log Configuration
------------------------------------------------------------

BEGIN TRY

    INSERT INTO @LogFiles
    SELECT
        F.database_id,

        SUM(CONVERT(BIGINT, F.size)) / 128.0,

        COUNT(*),

        COUNT(CASE
            WHEN F.growth = 0
                THEN 1 END),

        COUNT(CASE
            WHEN F.is_percent_growth = 1
             AND F.growth > 0
                THEN 1 END),

        COUNT(CASE
            WHEN F.max_size > 0
                THEN 1 END),

        COUNT(CASE
            WHEN F.max_size > 0
             AND F.size >= F.max_size
                THEN 1 END)

    FROM sys.master_files AS F

    INNER JOIN @Databases AS D
        ON F.database_id = D.DatabaseID

    WHERE F.type = 1

    GROUP BY F.database_id;

    --------------------------------------------------------
    -- Configuration metrics
    --------------------------------------------------------

    INSERT INTO @Metrics
    SELECT
        M.MetricID,
        'Transaction Log Configuration',
        'Database',
        D.DatabaseName,
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
                THEN 'Transaction log configuration unavailable.'
            ELSE NULL
        END

    FROM @Databases AS D

    LEFT JOIN @LogFiles AS F
        ON D.DatabaseID = F.DatabaseID

    CROSS APPLY
    (
        VALUES

        (
            'LOG-005',
            'Log Reuse Wait Reason',
            CONVERT(DECIMAL(28,4), D.LogReuseWait),
            'StateCode'
        ),
        (
            'LOG-006',
            'Database Recovery Model',
            CONVERT(DECIMAL(28,4), D.RecoveryModel),
            'StateCode'
        ),
        (
            'LOG-007',
            'Transaction Log File Count',
            CONVERT(DECIMAL(28,4), F.LogFileCount),
            'Count'
        ),
        (
            'LOG-008',
            'Log Files With Autogrowth Disabled',
            CONVERT(DECIMAL(28,4),
                F.GrowthDisabledCount),
            'Count'
        ),
        (
            'LOG-009',
            'Log Files With Percentage Growth',
            CONVERT(DECIMAL(28,4),
                F.PercentGrowthCount),
            'Count'
        ),
        (
            'LOG-010',
            'Log Files With Configured Maximum Size',
            CONVERT(DECIMAL(28,4),
                F.MaximumSizeConfiguredCount),
            'Count'
        ),
        (
            'LOG-018',
            'Log Files At Configured Maximum Size',
            CONVERT(DECIMAL(28,4),
                F.MaximumSizeReachedCount),
            'Count'
        ),
        (
            'LOG-020',
            'Configured Allocated Log File Size',
            F.AllocatedLogMB,
            'MB'
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
        'LOG-098',
        'Collection',
        'Instance',
        @ServerName,
        'Transaction Log Configuration Collection',
        NULL,
        'Status',
        'FAILED',
        ERROR_MESSAGE()
    );

END CATCH;

------------------------------------------------------------
-- SECTION 6: Advanced Transaction Log Statistics
------------------------------------------------------------

BEGIN TRY

    DECLARE @LogStatsDatabaseID INT;

    SELECT @LogStatsDatabaseID = MIN(DatabaseID)
    FROM @Databases WHERE DatabaseState = 0;

    WHILE @LogStatsDatabaseID IS NOT NULL
    BEGIN
        BEGIN TRY
            INSERT INTO @LogStats
            SELECT
                @LogStatsDatabaseID,
                L.total_vlf_count,
                L.active_vlf_count,
                CONVERT(DECIMAL(28,4), L.active_log_size_mb),
                CONVERT(DECIMAL(28,4), L.log_since_last_log_backup_mb),
                CONVERT(DECIMAL(28,4), L.log_since_last_checkpoint_mb),
                L.log_truncation_holdup_reason
            FROM sys.dm_db_log_stats(@LogStatsDatabaseID) AS L;
        END TRY
        BEGIN CATCH
            INSERT INTO @LogStatsErrors (DatabaseID, ErrorMessage)
            VALUES (@LogStatsDatabaseID, ERROR_MESSAGE());
        END CATCH;

        SELECT @LogStatsDatabaseID = MIN(DatabaseID)
        FROM @Databases
        WHERE DatabaseState = 0
          AND DatabaseID > @LogStatsDatabaseID;
    END;

    --------------------------------------------------------
    -- Transaction log statistics metrics
    --------------------------------------------------------

    INSERT INTO @Metrics
    SELECT
        M.MetricID,
        'Transaction Log',
        'Database',
        D.DatabaseName,
        M.MetricName,
        M.MetricValue,
        M.MetricUnit,

        CASE

            WHEN M.MetricID = 'LOG-014'
             AND D.RecoveryModel = 3
                THEN 'NOT APPLICABLE'

            WHEN E.DatabaseID IS NOT NULL
                THEN 'FAILED'

            WHEN M.MetricValue IS NULL
                THEN 'UNKNOWN'

            ELSE 'SUCCESS'

        END,

        CASE

            WHEN M.MetricID = 'LOG-014'
             AND D.RecoveryModel = 3
                THEN 'Database uses SIMPLE recovery model.'

            WHEN D.DatabaseState <> 0
                THEN 'Database is not ONLINE.'

            WHEN E.DatabaseID IS NOT NULL
                THEN E.ErrorMessage

            WHEN M.MetricValue IS NULL
                THEN 'Log statistic unavailable for database or replica.'

            ELSE NULL

        END

    FROM @Databases AS D

    LEFT JOIN @LogStats AS L
        ON D.DatabaseID = L.DatabaseID

    LEFT JOIN @LogStatsErrors AS E
        ON D.DatabaseID = E.DatabaseID

    CROSS APPLY
    (
        VALUES

        (
            'LOG-011',
            'Total Virtual Log File Count',
            CONVERT(DECIMAL(28,4),
                L.TotalVLFCount),
            'Count'
        ),
        (
            'LOG-012',
            'Active Virtual Log File Count',
            CONVERT(DECIMAL(28,4),
                L.ActiveVLFCount),
            'Count'
        ),
        (
            'LOG-013',
            'Active Transaction Log Size',
            L.ActiveLogSizeMB,
            'MB'
        ),
        (
            'LOG-014',
            'Log Generated Since Last Log Backup',

            CASE
                WHEN D.RecoveryModel <> 3
                    THEN L.LogSinceLastBackupMB
                ELSE NULL
            END,

            'MB'
        ),
        (
            'LOG-015',
            'Log Generated Since Last Checkpoint',
            L.LogSinceLastCheckpointMB,
            'MB'
        ),
        (
            'LOG-017',
            'Log Truncation Holdup Reason',

            CONVERT(DECIMAL(28,4),

                CASE L.TruncationHoldupReason

                    WHEN 'NOTHING' THEN 0
                    WHEN 'CHECKPOINT' THEN 1
                    WHEN 'LOG_BACKUP' THEN 2
                    WHEN 'ACTIVE_BACKUP_OR_RESTORE' THEN 3
                    WHEN 'ACTIVE_TRANSACTION' THEN 4
                    WHEN 'DATABASE_MIRRORING' THEN 5
                    WHEN 'REPLICATION' THEN 6
                    WHEN 'DATABASE_SNAPSHOT_CREATION' THEN 7
                    WHEN 'LOG_SCAN' THEN 8
                    WHEN 'AVAILABILITY_REPLICA' THEN 9
                    WHEN 'OTHER_TRANSIENT' THEN 10
                    WHEN 'OLDEST_PAGE' THEN 13
                    WHEN 'XTP_CHECKPOINT' THEN 16
                    WHEN 'SLOG_SCAN' THEN 17

                    ELSE NULL

                END
            ),

            'StateCode'
        )

    ) AS M
    (
        MetricID,
        MetricName,
        MetricValue,
        MetricUnit
    );

    --------------------------------------------------------
    -- Log statistics collection coverage
    --------------------------------------------------------

    SELECT
        @LogStatsCount = COUNT_BIG(*)
    FROM @LogStats
    WHERE TotalVLFCount IS NOT NULL;

    INSERT INTO @Metrics
    VALUES
    (
        'LOG-019',
        'Collection',
        'Instance',
        @ServerName,
        'Databases With Advanced Log Statistics',
        @LogStatsCount,
        'Count',
        'SUCCESS',
        NULL
    );

END TRY

BEGIN CATCH

    INSERT INTO @Metrics
    VALUES
    (
        'LOG-097',
        'Collection',
        'Instance',
        @ServerName,
        'Advanced Transaction Log Statistics Collection',
        NULL,
        'Status',
        'FAILED',
        ERROR_MESSAGE()
    );

END CATCH;

------------------------------------------------------------
-- SECTION 7: Collection Completeness
------------------------------------------------------------

INSERT INTO @Metrics
VALUES
(
    'LOG-021',
    'Collection',
    'Instance',
    @ServerName,
    'Databases Visible To Log Collector',
    @DatabaseCount,
    'Count',

    CASE
        WHEN @DatabaseCount IS NULL
          OR @DatabaseCount = 0
            THEN 'UNKNOWN'
        ELSE 'SUCCESS'
    END,

    CASE
        WHEN @DatabaseCount IS NULL
          OR @DatabaseCount = 0
            THEN 'No database inventory available.'
        ELSE NULL
    END
);

------------------------------------------------------------
-- SECTION 8: Collection Performance
------------------------------------------------------------

INSERT INTO @Metrics
VALUES
(
    'LOG-016',
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
