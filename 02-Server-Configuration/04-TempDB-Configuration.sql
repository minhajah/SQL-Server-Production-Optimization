/*
============================================================
Project : SQL Server Production Optimization
Module  : 02 - Server Configuration
Script  : 04-TempDB-Configuration.sql
Purpose : Assess TempDB configuration and utilization
Type    : Read-Only Assessment
Impact  : Low
============================================================
*/

USE tempdb;
GO

SET NOCOUNT ON;

------------------------------------------------------------
-- SECTION 1: TempDB File Configuration
------------------------------------------------------------

SELECT
    SYSDATETIME() AS CaptureDate,
    @@SERVERNAME AS ServerName,
    DF.file_id AS FileID,
    DF.name AS LogicalFileName,
    DF.type_desc AS FileType,
    DF.physical_name AS PhysicalFilePath,

    CAST(MF.size / 128.0
        AS DECIMAL(18,2)) AS StartupSize_MB,

    CAST(DF.size / 128.0
        AS DECIMAL(18,2)) AS CurrentSize_MB,

    CASE
        WHEN DF.max_size = -1 THEN 'Unlimited'
        WHEN DF.max_size = 0 THEN 'No Growth Allowed'
        ELSE CAST(
            CAST(DF.max_size / 128.0
                AS DECIMAL(18,2))
            AS VARCHAR(30)) + ' MB'
    END AS MaxFileSize,

    CASE
        WHEN DF.growth = 0 THEN 'Disabled'
        WHEN DF.is_percent_growth = 1
            THEN CAST(DF.growth AS VARCHAR(20)) + '%'
        ELSE CAST(
            CAST(DF.growth / 128.0
                AS DECIMAL(18,2))
            AS VARCHAR(30)) + ' MB'
    END AS AutoGrowth,

    CASE
        WHEN DF.growth = 0
            THEN 'REVIEW - Growth Disabled'
        WHEN DF.is_percent_growth = 1
            THEN 'REVIEW - Percentage Growth'
        ELSE 'Fixed Growth'
    END AS GrowthAssessment

FROM sys.database_files AS DF

LEFT JOIN master.sys.master_files AS MF
    ON MF.database_id = DB_ID('tempdb')
    AND MF.file_id = DF.file_id

ORDER BY DF.type, DF.file_id;

------------------------------------------------------------
-- SECTION 2: TempDB Data File Count Assessment
------------------------------------------------------------

DECLARE
    @CPUCount INT,
    @DataFiles INT,
    @LogFiles INT,
    @BaselineFileCount INT;

SELECT
    @CPUCount = COUNT(*)
FROM sys.dm_os_schedulers
WHERE status = 'VISIBLE ONLINE';

SELECT
    @DataFiles = COUNT(CASE
        WHEN type = 0 THEN 1 END),
    @LogFiles = COUNT(CASE
        WHEN type = 1 THEN 1 END)
FROM sys.database_files;

SET @BaselineFileCount =
    CASE
        WHEN @CPUCount = 0 THEN NULL
        WHEN @CPUCount <= 8 THEN @CPUCount
        ELSE 8
    END;

SELECT
    SYSDATETIME() AS CaptureDate,
    @@SERVERNAME AS ServerName,
    @CPUCount AS OnlineLogicalCPUs,
    @DataFiles AS CurrentDataFiles,
    @LogFiles AS CurrentLogFiles,
    @BaselineFileCount AS BaselineDataFileCount,

    CASE
        WHEN @BaselineFileCount IS NULL
            THEN 'UNKNOWN - CPU Count Unavailable'

        WHEN @DataFiles < @BaselineFileCount
            THEN 'REVIEW - Below Baseline File Count'

        WHEN @DataFiles > @BaselineFileCount
            THEN 'REVIEW - Above Baseline File Count'

        ELSE 'Matches Baseline Guideline'
    END AS FileCountAssessment;

------------------------------------------------------------
-- SECTION 3: TempDB File Size and Growth Consistency
------------------------------------------------------------

SELECT
    SYSDATETIME() AS CaptureDate,
    @@SERVERNAME AS ServerName,
    COUNT(*) AS DataFileCount,

    CAST(MIN(size) / 128.0
        AS DECIMAL(18,2)) AS SmallestFile_MB,

    CAST(MAX(size) / 128.0
        AS DECIMAL(18,2)) AS LargestFile_MB,

    CAST((MAX(size) - MIN(size)) / 128.0
        AS DECIMAL(18,2)) AS SizeDifference_MB,

    COUNT(DISTINCT size) AS DistinctFileSizes,
    COUNT(DISTINCT growth) AS DistinctGrowthValues,

    COUNT(CASE
        WHEN is_percent_growth = 1 THEN 1 END)
        AS PercentageGrowthFiles,

    COUNT(CASE
        WHEN growth = 0 THEN 1 END)
        AS GrowthDisabledFiles,

    CASE
        WHEN MIN(size) <> MAX(size)
            THEN 'REVIEW - Unequal Data File Sizes'
        ELSE 'Equal Current Data File Sizes'
    END AS SizeAssessment,

    CASE
        WHEN MIN(growth) <> MAX(growth)
          OR MIN(CONVERT(INT, is_percent_growth)) <>
             MAX(CONVERT(INT, is_percent_growth))
            THEN 'REVIEW - Inconsistent Growth Settings'

        WHEN MAX(CONVERT(INT, is_percent_growth)) = 1
            THEN 'REVIEW - Percentage Growth'

        WHEN MIN(growth) = 0
            THEN 'REVIEW - Growth Disabled'

        ELSE 'Consistent Fixed Growth'
    END AS GrowthAssessment

FROM sys.database_files
WHERE type = 0;

------------------------------------------------------------
-- SECTION 4: TempDB Data Space Utilization
------------------------------------------------------------

SELECT
    SYSDATETIME() AS CaptureDate,
    @@SERVERNAME AS ServerName,
    DF.name AS LogicalFileName,

    CAST(FS.total_page_count / 128.0
        AS DECIMAL(18,2)) AS TotalSpace_MB,

    CAST(FS.unallocated_extent_page_count / 128.0
        AS DECIMAL(18,2)) AS UnallocatedSpace_MB,

    CAST(FS.user_object_reserved_page_count / 128.0
        AS DECIMAL(18,2)) AS UserObjects_MB,

    CAST(FS.internal_object_reserved_page_count / 128.0
        AS DECIMAL(18,2)) AS InternalObjects_MB,

    CAST(FS.version_store_reserved_page_count / 128.0
        AS DECIMAL(18,2)) AS VersionStore_MB,

    CAST(
        (FS.total_page_count -
         FS.unallocated_extent_page_count) * 100.0 /
        NULLIF(FS.total_page_count, 0)
        AS DECIMAL(10,2)
    ) AS AllocatedSpace_Percent

FROM sys.dm_db_file_space_usage AS FS

INNER JOIN sys.database_files AS DF
    ON FS.file_id = DF.file_id

WHERE DF.type = 0

ORDER BY DF.file_id;

------------------------------------------------------------
-- SECTION 5: TempDB Transaction Log Utilization
------------------------------------------------------------

SELECT
    SYSDATETIME() AS CaptureDate,
    @@SERVERNAME AS ServerName,

    CAST(total_log_size_in_bytes / 1048576.0
        AS DECIMAL(18,2)) AS TotalLogSize_MB,

    CAST(used_log_space_in_bytes / 1048576.0
        AS DECIMAL(18,2)) AS UsedLogSpace_MB,

    CAST(
        (total_log_size_in_bytes -
         used_log_space_in_bytes) / 1048576.0
        AS DECIMAL(18,2)) AS FreeLogSpace_MB,

    CAST(used_log_space_in_percent
        AS DECIMAL(10,2)) AS UsedLogSpace_Percent,

    CASE
        WHEN used_log_space_in_percent >= 90
            THEN 'REVIEW - High Log Utilization'
        WHEN used_log_space_in_percent >= 80
            THEN 'OBSERVE - Elevated Log Utilization'
        ELSE 'Below Utilization Threshold'
    END AS LogAssessment

FROM sys.dm_db_log_space_usage;

------------------------------------------------------------
-- SECTION 6: TempDB Storage Capacity
------------------------------------------------------------

SELECT DISTINCT
    SYSDATETIME() AS CaptureDate,
    @@SERVERNAME AS ServerName,
    VS.volume_mount_point AS Drive,

    CAST(VS.total_bytes / 1073741824.0
        AS DECIMAL(18,2)) AS TotalVolume_GB,

    CAST(VS.available_bytes / 1073741824.0
        AS DECIMAL(18,2)) AS FreeVolume_GB,

    CAST(VS.available_bytes * 100.0 /
        NULLIF(VS.total_bytes, 0)
        AS DECIMAL(10,2)) AS FreeVolume_Percent,

    CASE
        WHEN VS.total_bytes IS NULL
          OR VS.total_bytes = 0
          OR VS.available_bytes IS NULL
            THEN 'UNKNOWN'

        WHEN VS.available_bytes * 100.0 /
             NULLIF(VS.total_bytes, 0) < 10
            THEN 'CRITICAL'

        WHEN VS.available_bytes * 100.0 /
             NULLIF(VS.total_bytes, 0) < 20
            THEN 'WARNING'

        ELSE 'HEALTHY'
    END AS StorageStatus

FROM sys.database_files AS DF

CROSS APPLY sys.dm_os_volume_stats
(
    DB_ID('tempdb'),
    DF.file_id
) AS VS

ORDER BY Drive;

------------------------------------------------------------
-- SECTION 7: TempDB File I/O Statistics
------------------------------------------------------------

SELECT
    SYSDATETIME() AS CaptureDate,
    @@SERVERNAME AS ServerName,
    DF.name AS LogicalFileName,
    DF.type_desc AS FileType,

    VFS.num_of_reads AS TotalReads,
    VFS.num_of_writes AS TotalWrites,

    CAST(VFS.io_stall_read_ms * 1.0 /
        NULLIF(VFS.num_of_reads, 0)
        AS DECIMAL(18,2)) AS AvgReadLatency_MS,

    CAST(VFS.io_stall_write_ms * 1.0 /
        NULLIF(VFS.num_of_writes, 0)
        AS DECIMAL(18,2)) AS AvgWriteLatency_MS,

    CAST(VFS.num_of_bytes_read / 1048576.0
        AS DECIMAL(18,2)) AS TotalRead_MB,

    CAST(VFS.num_of_bytes_written / 1048576.0
        AS DECIMAL(18,2)) AS TotalWritten_MB

FROM sys.dm_io_virtual_file_stats
(
    DB_ID('tempdb'), NULL
) AS VFS

INNER JOIN sys.database_files AS DF
    ON VFS.file_id = DF.file_id

ORDER BY DF.type, DF.file_id;

------------------------------------------------------------
-- SECTION 8: Consolidated TempDB Assessment
------------------------------------------------------------

SELECT
    SYSDATETIME() AS CaptureDate,
    @@SERVERNAME AS ServerName,
    @CPUCount AS OnlineLogicalCPUs,
    @DataFiles AS CurrentDataFiles,
    @BaselineFileCount AS BaselineDataFiles,
    @LogFiles AS CurrentLogFiles,

    CAST(SUM(CAST(size AS BIGINT)) / 128.0
        AS DECIMAL(18,2)) AS TotalDataSize_MB,

    COUNT(DISTINCT size) AS DistinctDataFileSizes,

    COUNT(CASE
        WHEN is_percent_growth = 1 THEN 1 END)
        AS PercentageGrowthFiles,

    COUNT(CASE
        WHEN growth = 0 THEN 1 END)
        AS GrowthDisabledFiles,

    CASE
        WHEN @BaselineFileCount IS NULL
            THEN 'UNKNOWN - CPU Information Unavailable'

        WHEN @DataFiles < @BaselineFileCount
            THEN 'REVIEW - Data File Count'

        WHEN MIN(size) <> MAX(size)
            THEN 'REVIEW - Unequal Data File Sizes'

        WHEN MIN(growth) <> MAX(growth)
          OR MIN(CONVERT(INT, is_percent_growth)) <>
             MAX(CONVERT(INT, is_percent_growth))
            THEN 'REVIEW - Inconsistent Growth Settings'

        WHEN MAX(CONVERT(INT, is_percent_growth)) = 1
            THEN 'REVIEW - Percentage Growth'

        WHEN MIN(growth) = 0
            THEN 'REVIEW - Growth Disabled'

        WHEN @LogFiles > 1
            THEN 'REVIEW - Multiple Log Files'

        WHEN @DataFiles > @BaselineFileCount
            THEN 'VALIDATE - Above Baseline File Count'

        ELSE 'NO BASIC CONFIGURATION EXCEPTIONS DETECTED'
    END AS OverallTempDBConfigurationAssessment

FROM sys.database_files
WHERE type = 0;

GO

USE master;
GO
