/*
============================================================
Project : SQL Server Production Optimization
Module  : 26 - Data Collection
Script  : 05-Storage-Collector.sql
Purpose : Collect storage capacity and disk I/O metrics
Type    : Read-Only Monitoring Collector
Impact  : Low - dependent on database file count
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
    @ServerName NVARCHAR(128),
    @UnknownVolumeFiles BIGINT;

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

DECLARE @VolumeFiles TABLE
(
    DatabaseID INT,
    FileID INT,
    VolumeMountPoint NVARCHAR(512),
    TotalBytes BIGINT,
    AvailableBytes BIGINT,
    AllocatedBytes BIGINT
);

------------------------------------------------------------
-- SECTION 3: Storage Capacity Collection
------------------------------------------------------------

BEGIN TRY

    INSERT INTO @VolumeFiles
    SELECT
        F.database_id,
        F.file_id,
        V.volume_mount_point,
        V.total_bytes,
        V.available_bytes,

        CONVERT(BIGINT, F.size) * 8192

    FROM sys.master_files AS F

    INNER JOIN sys.databases AS D
        ON F.database_id = D.database_id

    OUTER APPLY sys.dm_os_volume_stats
    (
        F.database_id,
        F.file_id
    ) AS V

    WHERE F.type IN (0, 1)
      AND D.state = 0
      AND D.source_database_id IS NULL;

    --------------------------------------------------------
    -- Aggregate volume information
    --------------------------------------------------------

    ;WITH VolumeSummary AS
    (
        SELECT
            VolumeMountPoint,

            MAX(TotalBytes) AS TotalBytes,

            MIN(AvailableBytes) AS AvailableBytes,

            SUM(AllocatedBytes) AS AllocatedBytes,

            COUNT_BIG(*) AS FileCount

        FROM @VolumeFiles

        WHERE NULLIF(VolumeMountPoint, '') IS NOT NULL

        GROUP BY VolumeMountPoint
    )
    INSERT INTO @Metrics
    SELECT
        M.MetricID,
        'Storage',
        'Volume',
        V.VolumeMountPoint,
        M.MetricName,
        M.MetricValue,
        M.MetricUnit,

        CASE
            WHEN M.MetricValue IS NULL
                THEN 'UNKNOWN'
            WHEN LEN(V.VolumeMountPoint) > 256
                THEN 'UNKNOWN'
            ELSE 'SUCCESS'
        END,

        CASE
            WHEN LEN(V.VolumeMountPoint) > 256
                THEN 'Volume identifier exceeds contract length.'
            WHEN M.MetricValue IS NULL
                THEN 'Volume information unavailable or invalid.'
            ELSE NULL
        END

    FROM VolumeSummary AS V

    CROSS APPLY
    (
        VALUES

        (
            'STG-001',
            'Total Volume Capacity',
            CONVERT(DECIMAL(28,4),
                CASE WHEN V.TotalBytes > 0
                    THEN V.TotalBytes / 1073741824.0
                END),
            'GB'
        ),
        (
            'STG-002',
            'Available Volume Space',
            CONVERT(DECIMAL(28,4),
                CASE WHEN V.AvailableBytes >= 0
                    THEN V.AvailableBytes / 1073741824.0
                END),
            'GB'
        ),
        (
            'STG-003',
            'Used Volume Space',
            CONVERT(DECIMAL(28,4),
                CASE
                    WHEN V.TotalBytes > 0
                     AND V.AvailableBytes
                         BETWEEN 0 AND V.TotalBytes
                    THEN
                        (V.TotalBytes - V.AvailableBytes)
                        / 1073741824.0
                END),
            'GB'
        ),
        (
            'STG-004',
            'Free Space Percentage',
            CONVERT(DECIMAL(28,4),
                CASE
                    WHEN V.TotalBytes > 0
                     AND V.AvailableBytes
                         BETWEEN 0 AND V.TotalBytes
                    THEN V.AvailableBytes * 100.0
                        / NULLIF(V.TotalBytes, 0)
                END),
            'Percent'
        ),
        (
            'STG-005',
            'Used Space Percentage',
            CONVERT(DECIMAL(28,4),
                CASE
                    WHEN V.TotalBytes > 0
                     AND V.AvailableBytes
                         BETWEEN 0 AND V.TotalBytes
                    THEN
                        (V.TotalBytes - V.AvailableBytes)
                        * 100.0 / NULLIF(V.TotalBytes, 0)
                END),
            'Percent'
        ),
        (
            'STG-006',
            'Allocated SQL Database File Size',
            CONVERT(DECIMAL(28,4),
                V.AllocatedBytes / 1073741824.0),
            'GB'
        ),
        (
            'STG-007',
            'SQL Database File Count',
            CONVERT(DECIMAL(28,4), V.FileCount),
            'Count'
        )

    ) AS M
    (
        MetricID,
        MetricName,
        MetricValue,
        MetricUnit
    )

    WHERE LEN(V.VolumeMountPoint) <= 256;

    --------------------------------------------------------
    -- Volume collection completeness
    --------------------------------------------------------

    SELECT
        @UnknownVolumeFiles = COUNT_BIG(*)

    FROM @VolumeFiles

    WHERE NULLIF(VolumeMountPoint, '') IS NULL
       OR LEN(VolumeMountPoint) > 256
       OR TotalBytes IS NULL
       OR TotalBytes <= 0
       OR AvailableBytes IS NULL
       OR AvailableBytes < 0
       OR AvailableBytes > TotalBytes;

    INSERT INTO @Metrics
    VALUES
    (
        'STG-015',
        'Collection',
        'Instance',
        @ServerName,
        'Files With Unavailable Volume Information',
        @UnknownVolumeFiles,
        'Count',
        'SUCCESS',
        NULL
    );

    IF NOT EXISTS
    (
        SELECT 1
        FROM @Metrics
        WHERE MetricID = 'STG-001'
          AND CollectionStatus = 'SUCCESS'
    )
    BEGIN

        INSERT INTO @Metrics
        VALUES
        (
            'STG-000',
            'Collection',
            'Instance',
            @ServerName,
            'Volume Capacity Collection',
            NULL,
            'Status',
            'UNKNOWN',
            'No valid SQL database volume capacity returned.'
        );

    END;

END TRY

BEGIN CATCH

    INSERT INTO @Metrics
    VALUES
    (
        'STG-000',
        'Collection',
        'Instance',
        @ServerName,
        'Volume Capacity Collection',
        NULL,
        'Status',
        'FAILED',
        ERROR_MESSAGE()
    );

END CATCH;

------------------------------------------------------------
-- SECTION 4: Database File I/O Collection
------------------------------------------------------------

BEGIN TRY

    INSERT INTO @Metrics
    SELECT
        M.MetricID,
        'Storage IO',
        'DatabaseFile',

        CONCAT(
            CONVERT(VARCHAR(20), F.database_id),
            ':',
            CONVERT(VARCHAR(20), F.file_id)
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
                THEN 'File I/O information unavailable.'
            ELSE NULL
        END

    FROM sys.dm_io_virtual_file_stats(NULL, NULL) AS I

    INNER JOIN sys.master_files AS F
        ON I.database_id = F.database_id
       AND I.file_id = F.file_id

    INNER JOIN sys.databases AS D
        ON F.database_id = D.database_id

    CROSS APPLY
    (
        VALUES

        (
            'STG-008',
            'Cumulative Read Operations',
            CONVERT(DECIMAL(28,4), I.num_of_reads),
            'CumulativeCount'
        ),
        (
            'STG-009',
            'Cumulative Write Operations',
            CONVERT(DECIMAL(28,4), I.num_of_writes),
            'CumulativeCount'
        ),
        (
            'STG-010',
            'Cumulative Read Stall',
            CONVERT(DECIMAL(28,4), I.io_stall_read_ms),
            'CumulativeMilliseconds'
        ),
        (
            'STG-011',
            'Cumulative Write Stall',
            CONVERT(DECIMAL(28,4), I.io_stall_write_ms),
            'CumulativeMilliseconds'
        ),
        (
            'STG-012',
            'Cumulative Bytes Read',
            CONVERT(DECIMAL(28,4), I.num_of_bytes_read),
            'CumulativeBytes'
        ),
        (
            'STG-013',
            'Cumulative Bytes Written',
            CONVERT(DECIMAL(28,4), I.num_of_bytes_written),
            'CumulativeBytes'
        ),
        (
            'STG-016',
            'IO Statistics Sample Time',
            CONVERT(DECIMAL(28,4), I.sample_ms),
            'Milliseconds'
        ),
        (
            'STG-017',
            'Database File Type',
            CONVERT(DECIMAL(28,4), F.type),
            'StateCode'
        )

    ) AS M
    (
        MetricID,
        MetricName,
        MetricValue,
        MetricUnit
    )

    WHERE F.type IN (0, 1)
      AND D.state = 0
      AND D.source_database_id IS NULL;

    IF NOT EXISTS
    (
        SELECT 1
        FROM @Metrics
        WHERE MetricID = 'STG-008'
          AND CollectionStatus = 'SUCCESS'
    )
    BEGIN

        INSERT INTO @Metrics
        VALUES
        (
            'STG-099',
            'Collection',
            'Instance',
            @ServerName,
            'Database File IO Collection',
            NULL,
            'Status',
            'UNKNOWN',
            'No valid database file IO statistics returned.'
        );

    END;

END TRY

BEGIN CATCH

    INSERT INTO @Metrics
    VALUES
    (
        'STG-099',
        'Collection',
        'Instance',
        @ServerName,
        'Database File IO Collection',
        NULL,
        'Status',
        'FAILED',
        ERROR_MESSAGE()
    );

END CATCH;

------------------------------------------------------------
-- SECTION 5: Collection Performance
------------------------------------------------------------

INSERT INTO @Metrics
VALUES
(
    'STG-014',
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

ORDER BY
    ResourceType,
    ResourceName,
    MetricID;

GO
