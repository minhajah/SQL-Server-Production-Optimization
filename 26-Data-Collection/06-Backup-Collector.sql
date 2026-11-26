/*
============================================================
Project : SQL Server Production Optimization
Module  : 26 - Data Collection
Script  : 06-Backup-Collector.sql
Purpose : Collect database backup history and compliance metrics
Type    : Read-Only Monitoring Collector
Impact  : Low to Moderate - dependent on backup history size
Frequency: 900 Seconds (Proposed)
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
    @HistoryDays INT = 35,
    @HistoryStart DATETIME2(3),
    @HADREnabled INT;

SET @ServerName =
    CONVERT(NVARCHAR(128), SERVERPROPERTY('ServerName'));

SET @HADREnabled =
    CONVERT(INT, SERVERPROPERTY('IsHadrEnabled'));

SET @HistoryStart =
    DATEADD(DAY, -@HistoryDays, @LocalCaptureDate);

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
    DatabaseGUID UNIQUEIDENTIFIER,
    RecoveryModel INT,
    IsAGDatabase INT,
    PreferredBackupReplica INT
);

DECLARE @LatestBackups TABLE
(
    DatabaseID INT,
    BackupType CHAR(1),
    BackupStartDate DATETIME,
    BackupFinishDate DATETIME,
    BackupSize DECIMAL(28,4),
    HasBackupChecksums BIT,
    IsCopyOnly BIT,
    IsSnapshot BIT,
    IsDamaged BIT,

    PRIMARY KEY (DatabaseID, BackupType)
);

DECLARE @NonCopyOnlyFull TABLE
(
    DatabaseID INT PRIMARY KEY,
    BackupFinishDate DATETIME
);

------------------------------------------------------------
-- SECTION 3: Database Inventory
------------------------------------------------------------

BEGIN TRY

    INSERT INTO @Databases
    SELECT
        D.database_id,
        D.name,
        R.database_guid,
        D.recovery_model,

        CASE
            WHEN D.group_database_id IS NOT NULL
                THEN 1
            ELSE 0
        END,

        NULL

    FROM sys.databases AS D

    LEFT JOIN sys.database_recovery_status AS R
        ON D.database_id = R.database_id

    WHERE D.database_id <> 2
      AND D.source_database_id IS NULL;

END TRY

BEGIN CATCH

    INSERT INTO @Metrics
    VALUES
    (
        'BAK-000',
        'Collection',
        'Instance',
        @ServerName,
        'Backup Database Inventory Collection',
        NULL,
        'Status',
        'FAILED',
        ERROR_MESSAGE()
    );

END CATCH;

------------------------------------------------------------
-- SECTION 4: AG Backup Preference
------------------------------------------------------------

BEGIN TRY

    IF @HADREnabled = 1
    BEGIN

        UPDATE @Databases

        SET PreferredBackupReplica =
            sys.fn_hadr_backup_is_preferred_replica(
                DatabaseName
            )

        WHERE IsAGDatabase = 1;

    END;

END TRY

BEGIN CATCH

    INSERT INTO @Metrics
    VALUES
    (
        'BAK-098',
        'Collection',
        'Instance',
        @ServerName,
        'AG Backup Preference Collection',
        NULL,
        'Status',
        'FAILED',
        ERROR_MESSAGE()
    );

END CATCH;

------------------------------------------------------------
-- SECTION 5: Latest Backup History
------------------------------------------------------------

BEGIN TRY

    ;WITH RankedBackups AS
    (
        SELECT
            D.DatabaseID,
            B.type AS BackupType,
            B.backup_start_date,
            B.backup_finish_date,
            B.backup_size,
            B.has_backup_checksums,
            B.is_copy_only,
            B.is_snapshot,
            B.is_damaged,

            ROW_NUMBER() OVER
            (
                PARTITION BY
                    D.DatabaseID,
                    B.type

                ORDER BY
                    B.backup_finish_date DESC,
                    B.backup_set_id DESC

            ) AS RowNumber

        FROM msdb.dbo.backupset AS B

        INNER JOIN @Databases AS D
            ON B.database_name = D.DatabaseName

        WHERE B.type IN ('D', 'I', 'L')

          AND B.backup_finish_date >= @HistoryStart

          AND B.backup_finish_date <= @LocalCaptureDate

          AND
          (
              D.DatabaseGUID IS NULL

              OR B.database_guid = D.DatabaseGUID
          )
    )

    INSERT INTO @LatestBackups
    SELECT
        DatabaseID,
        BackupType,
        backup_start_date,
        backup_finish_date,
        CONVERT(DECIMAL(28,4), backup_size),
        has_backup_checksums,
        is_copy_only,
        is_snapshot,
        is_damaged

    FROM RankedBackups

    WHERE RowNumber = 1;

    --------------------------------------------------------
    -- Latest conventional full backup
    --------------------------------------------------------

    INSERT INTO @NonCopyOnlyFull
    SELECT
        D.DatabaseID,
        MAX(B.backup_finish_date)

    FROM msdb.dbo.backupset AS B

    INNER JOIN @Databases AS D
        ON B.database_name = D.DatabaseName

    WHERE B.type = 'D'
      AND B.is_copy_only = 0
      AND B.is_damaged = 0
      AND B.is_snapshot = 0

      AND B.backup_finish_date >= @HistoryStart

      AND B.backup_finish_date <= @LocalCaptureDate

      AND
      (
          D.DatabaseGUID IS NULL

          OR B.database_guid = D.DatabaseGUID
      )

    GROUP BY D.DatabaseID;

    --------------------------------------------------------
    -- Backup age, duration, size and checksum metrics
    --------------------------------------------------------

    INSERT INTO @Metrics
    SELECT
        M.MetricID,
        'Backup',
        'Database',
        D.DatabaseName,
        M.MetricName,
        M.MetricValue,
        M.MetricUnit,

        CASE

            WHEN M.MetricID IN
            (
                'BAK-003',
                'BAK-010',
                'BAK-013',
                'BAK-016'
            )
            AND D.RecoveryModel = 3
                THEN 'NOT APPLICABLE'

            WHEN M.MetricValue IS NULL
                THEN 'UNKNOWN'

            ELSE 'SUCCESS'

        END,

        CASE

            WHEN M.MetricID IN
            (
                'BAK-003',
                'BAK-010',
                'BAK-013',
                'BAK-016'
            )
            AND D.RecoveryModel = 3
                THEN 'Database uses SIMPLE recovery model.'

            WHEN M.MetricValue IS NULL
                THEN CONCAT(
                    'Metric unavailable or no matching ',
                    'local backup history within ',
                    @HistoryDays,
                    ' days.'
                )

            ELSE NULL

        END

    FROM @Databases AS D

    LEFT JOIN @LatestBackups AS F
        ON D.DatabaseID = F.DatabaseID
       AND F.BackupType = 'D'

    LEFT JOIN @LatestBackups AS I
        ON D.DatabaseID = I.DatabaseID
       AND I.BackupType = 'I'

    LEFT JOIN @LatestBackups AS L
        ON D.DatabaseID = L.DatabaseID
       AND L.BackupType = 'L'

    LEFT JOIN @NonCopyOnlyFull AS N
        ON D.DatabaseID = N.DatabaseID

    CROSS APPLY
    (
        VALUES

        (
            'BAK-001',
            'Last Full Backup Age',
            CONVERT(DECIMAL(28,4),
                DATEDIFF_BIG(
                    SECOND,
                    F.BackupFinishDate,
                    @LocalCaptureDate
                ) / 3600.0),
            'Hours'
        ),
        (
            'BAK-002',
            'Last Differential Backup Age',
            CONVERT(DECIMAL(28,4),
                DATEDIFF_BIG(
                    SECOND,
                    I.BackupFinishDate,
                    @LocalCaptureDate
                ) / 3600.0),
            'Hours'
        ),
        (
            'BAK-003',
            'Last Transaction Log Backup Age',
            CONVERT(DECIMAL(28,4),
                CASE WHEN D.RecoveryModel <> 3
                    THEN DATEDIFF_BIG(
                        SECOND,
                        L.BackupFinishDate,
                        @LocalCaptureDate
                    ) / 60.0
                END),
            'Minutes'
        ),
        (
            'BAK-004',
            'Last Conventional Full Backup Age',
            CONVERT(DECIMAL(28,4),
                DATEDIFF_BIG(
                    SECOND,
                    N.BackupFinishDate,
                    @LocalCaptureDate
                ) / 3600.0),
            'Hours'
        ),
        (
            'BAK-008',
            'Last Full Backup Duration',
            CONVERT(DECIMAL(28,4),
                DATEDIFF_BIG(
                    SECOND,
                    F.BackupStartDate,
                    F.BackupFinishDate
                )),
            'Seconds'
        ),
        (
            'BAK-009',
            'Last Differential Backup Duration',
            CONVERT(DECIMAL(28,4),
                DATEDIFF_BIG(
                    SECOND,
                    I.BackupStartDate,
                    I.BackupFinishDate
                )),
            'Seconds'
        ),
        (
            'BAK-010',
            'Last Log Backup Duration',
            CONVERT(DECIMAL(28,4),
                CASE WHEN D.RecoveryModel <> 3
                    THEN DATEDIFF_BIG(
                        SECOND,
                        L.BackupStartDate,
                        L.BackupFinishDate
                    )
                END),
            'Seconds'
        ),
        (
            'BAK-011',
            'Last Full Backup Size',
            CONVERT(DECIMAL(28,4),
                F.BackupSize / 1048576.0),
            'MB'
        ),
        (
            'BAK-012',
            'Last Differential Backup Size',
            CONVERT(DECIMAL(28,4),
                I.BackupSize / 1048576.0),
            'MB'
        ),
        (
            'BAK-013',
            'Last Log Backup Size',
            CONVERT(DECIMAL(28,4),
                CASE WHEN D.RecoveryModel <> 3
                    THEN L.BackupSize / 1048576.0
                END),
            'MB'
        ),
        (
            'BAK-014',
            'Last Full Backup Checksums',
            CONVERT(DECIMAL(28,4),
                F.HasBackupChecksums),
            'Boolean'
        ),
        (
            'BAK-015',
            'Last Differential Backup Checksums',
            CONVERT(DECIMAL(28,4),
                I.HasBackupChecksums),
            'Boolean'
        ),
        (
            'BAK-016',
            'Last Log Backup Checksums',
            CONVERT(DECIMAL(28,4),
                CASE WHEN D.RecoveryModel <> 3
                    THEN L.HasBackupChecksums
                END),
            'Boolean'
        ),
        (
            'BAK-018',
            'Last Full Backup Copy Only',
            CONVERT(DECIMAL(28,4),
                F.IsCopyOnly),
            'Boolean'
        ),
        (
            'BAK-019',
            'Last Full Backup Snapshot',
            CONVERT(DECIMAL(28,4),
                F.IsSnapshot),
            'Boolean'
        ),
        (
            'BAK-020',
            'Last Full Backup Damaged',
            CONVERT(DECIMAL(28,4),
                F.IsDamaged),
            'Boolean'
        ),
        (
            'BAK-021',
            'Last Differential Backup Damaged',
            CONVERT(DECIMAL(28,4),
                I.IsDamaged),
            'Boolean'
        ),
        (
            'BAK-022',
            'Last Log Backup Damaged',
            CONVERT(DECIMAL(28,4),
                CASE WHEN D.RecoveryModel <> 3
                    THEN L.IsDamaged
                END),
            'Boolean'
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
        'BAK-099',
        'Collection',
        'Instance',
        @ServerName,
        'Backup History Collection',
        NULL,
        'Status',
        'FAILED',
        ERROR_MESSAGE()
    );

END CATCH;

------------------------------------------------------------
-- SECTION 6: Backup Configuration Metrics
------------------------------------------------------------

BEGIN TRY

    INSERT INTO @Metrics
    SELECT
        M.MetricID,
        'Backup Configuration',
        'Database',
        D.DatabaseName,
        M.MetricName,
        M.MetricValue,
        M.MetricUnit,

        CASE

            WHEN M.MetricID = 'BAK-007'
             AND D.IsAGDatabase = 0
                THEN 'NOT APPLICABLE'

            WHEN M.MetricValue IS NULL
                THEN 'UNKNOWN'

            ELSE 'SUCCESS'

        END,

        CASE

            WHEN M.MetricID = 'BAK-007'
             AND D.IsAGDatabase = 0
                THEN 'Database is not an AG member.'

            WHEN M.MetricValue IS NULL
                THEN 'Backup configuration unavailable.'

            ELSE NULL

        END

    FROM @Databases AS D

    CROSS APPLY
    (
        VALUES
        (
            'BAK-005',
            'Database Recovery Model',
            CONVERT(DECIMAL(28,4),
                D.RecoveryModel),
            'StateCode'
        ),
        (
            'BAK-006',
            'Availability Group Membership',
            CONVERT(DECIMAL(28,4),
                D.IsAGDatabase),
            'Boolean'
        ),
        (
            'BAK-007',
            'Preferred Backup Replica',
            CONVERT(DECIMAL(28,4),
                D.PreferredBackupReplica),
            'Boolean'
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
        'BAK-097',
        'Collection',
        'Instance',
        @ServerName,
        'Backup Configuration Collection',
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
    'BAK-023',
    'Collection',
    'Instance',
    @ServerName,
    'Backup History Lookback Period',
    @HistoryDays,
    'Days',
    'SUCCESS',
    NULL
);

IF NOT EXISTS
(
    SELECT 1
    FROM @Databases
)
BEGIN

    INSERT INTO @Metrics
    VALUES
    (
        'BAK-096',
        'Collection',
        'Instance',
        @ServerName,
        'Backup Database Inventory Availability',
        NULL,
        'Status',
        'UNKNOWN',
        'No eligible databases visible to collector.'
    );

END;

------------------------------------------------------------
-- SECTION 8: Collection Performance
------------------------------------------------------------

INSERT INTO @Metrics
VALUES
(
    'BAK-017',
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
