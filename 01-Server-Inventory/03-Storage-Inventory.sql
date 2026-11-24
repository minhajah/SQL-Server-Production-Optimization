/*
============================================================
Project : SQL Server Production Optimization
Module  : 01 - Server Inventory
Script  : 03-Storage-Inventory.sql
Purpose : Collect disk and database file inventory
Type    : Read-Only Assessment
============================================================
*/

USE master;
GO

SET NOCOUNT ON;

------------------------------------------------------------
-- SECTION 1: Disk Space Inventory
------------------------------------------------------------

SELECT DISTINCT
    SYSDATETIME() AS CaptureDate,
    @@SERVERNAME AS ServerName,
    VS.volume_mount_point AS Drive,
    VS.logical_volume_name AS VolumeName,
    VS.file_system_type AS FileSystem,

    CAST(VS.total_bytes / 1073741824.0
        AS DECIMAL(18,2)) AS TotalSizeGB,

    CAST((VS.total_bytes - VS.available_bytes)
        / 1073741824.0
        AS DECIMAL(18,2)) AS UsedSpaceGB,

    CAST(VS.available_bytes / 1073741824.0
        AS DECIMAL(18,2)) AS FreeSpaceGB,

    CAST(VS.available_bytes * 100.0 /
        NULLIF(VS.total_bytes, 0)
        AS DECIMAL(10,2)) AS FreeSpacePercent,

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
    END AS HealthStatus

FROM sys.master_files AS MF
CROSS APPLY sys.dm_os_volume_stats
(
    MF.database_id,
    MF.file_id
) AS VS

ORDER BY Drive;

------------------------------------------------------------
-- SECTION 2: Database File Inventory
------------------------------------------------------------

SELECT
    SYSDATETIME() AS CaptureDate,
    @@SERVERNAME AS ServerName,
    DB_NAME(MF.database_id) AS DatabaseName,
    MF.file_id AS FileID,
    MF.name AS LogicalFileName,
    MF.type_desc AS FileType,
    MF.physical_name AS PhysicalFilePath,
    MF.state_desc AS FileStatus,

    CAST(MF.size / 128.0 / 1024
        AS DECIMAL(18,2)) AS FileSizeGB,

    CASE
        WHEN MF.max_size = -1 THEN 'Unlimited'
        WHEN MF.max_size = 0 THEN 'No Growth Allowed'
        ELSE CAST(
            CAST(MF.max_size / 128.0
                AS DECIMAL(18,2))
            AS VARCHAR(30)) + ' MB'
    END AS MaxFileSize,

    CASE
        WHEN MF.growth = 0 THEN 'Disabled'
        WHEN MF.is_percent_growth = 1
            THEN CAST(MF.growth AS VARCHAR(20)) + '%'
        ELSE CAST(
            CAST(MF.growth / 128.0
                AS DECIMAL(18,2))
            AS VARCHAR(30)) + ' MB'
    END AS AutoGrowth,

    CASE
        WHEN MF.growth = 0 THEN 'REVIEW - Disabled'
        WHEN MF.is_percent_growth = 1
            THEN 'REVIEW - Percentage Growth'
        ELSE 'Fixed Growth'
    END AS GrowthAssessment

FROM sys.master_files AS MF

ORDER BY
    DB_NAME(MF.database_id),
    MF.type,
    MF.file_id;

GO
