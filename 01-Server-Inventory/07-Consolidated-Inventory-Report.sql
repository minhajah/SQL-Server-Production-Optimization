/*
============================================================
Project : SQL Server Production Optimization
Module  : 01 - Server Inventory
Script  : 07-Consolidated-Inventory-Report.sql
Purpose : Generate consolidated inventory summary
Type    : Read-Only Assessment
============================================================
*/

USE master;
GO

SET NOCOUNT ON;

DECLARE @ReportDate DATETIME = GETDATE();

------------------------------------------------------------
-- SECTION 1: Collect Inventory Metrics
------------------------------------------------------------

DECLARE
    @CPUCount INT,
    @RAM_GB DECIMAL(18,2),
    @UptimeDays DECIMAL(18,2),
    @TotalDBs INT,
    @OnlineDBs INT,
    @NonOnlineDBs INT,
    @TotalDBSizeGB DECIMAL(18,2),
    @TotalJobs INT,
    @EnabledJobs INT,
    @DisabledJobs INT,
    @FailedJobs INT,
    @TotalServices INT,
    @RunningServices INT,
    @StoppedAutoServices INT,
    @TotalVolumes INT,
    @WarningVolumes INT,
    @CriticalVolumes INT,
    @UnknownVolumes INT;

------------------------------------------------------------
-- Server Information
------------------------------------------------------------

SELECT
    @CPUCount = cpu_count,
    @RAM_GB = physical_memory_kb / 1048576.0,
    @UptimeDays =
        DATEDIFF_BIG(SECOND, sqlserver_start_time,
            @ReportDate) / 86400.0
FROM sys.dm_os_sys_info;

------------------------------------------------------------
-- Database Information
------------------------------------------------------------

SELECT
    @TotalDBs = COUNT(*),
    @OnlineDBs = COUNT(CASE
        WHEN state_desc = 'ONLINE' THEN 1 END),
    @NonOnlineDBs = COUNT(CASE
        WHEN state_desc <> 'ONLINE' THEN 1 END)
FROM sys.databases
WHERE database_id > 4;

SELECT
    @TotalDBSizeGB =
        COALESCE(SUM(CAST(size AS BIGINT)), 0)
        / 131072.0
FROM sys.master_files
WHERE database_id > 4
AND type IN (0, 1);

------------------------------------------------------------
-- Storage Information
------------------------------------------------------------

;WITH Volumes AS
(
    SELECT
        VS.volume_mount_point,
        MIN(VS.available_bytes * 100.0 /
            NULLIF(VS.total_bytes, 0))
            AS FreePercent
    FROM sys.master_files AS MF
    CROSS APPLY sys.dm_os_volume_stats
    (
        MF.database_id,
        MF.file_id
    ) AS VS
    GROUP BY VS.volume_mount_point
)
SELECT
    @TotalVolumes = COUNT(*),
    @WarningVolumes = COUNT(CASE
        WHEN FreePercent >= 10
         AND FreePercent < 20 THEN 1 END),
    @CriticalVolumes = COUNT(CASE
        WHEN FreePercent < 10 THEN 1 END),
    @UnknownVolumes = COUNT(CASE
        WHEN FreePercent IS NULL THEN 1 END)
FROM Volumes;

------------------------------------------------------------
-- SQL Agent Information
------------------------------------------------------------

SELECT
    @TotalJobs = COUNT(*),
    @EnabledJobs = COUNT(CASE
        WHEN enabled = 1 THEN 1 END),
    @DisabledJobs = COUNT(CASE
        WHEN enabled = 0 THEN 1 END)
FROM msdb.dbo.sysjobs;

SELECT
    @FailedJobs = COUNT(*)
FROM msdb.dbo.sysjobhistory
WHERE step_id = 0
AND run_status = 0
AND run_date > 0
AND msdb.dbo.agent_datetime(run_date, run_time)
    >= DATEADD(HOUR, -24, @ReportDate);

------------------------------------------------------------
-- SQL Server Services
------------------------------------------------------------

SELECT
    @TotalServices = COUNT(*),
    @RunningServices = COUNT(CASE
        WHEN status_desc = 'Running' THEN 1 END),
    @StoppedAutoServices = COUNT(CASE
        WHEN status_desc = 'Stopped'
         AND startup_type_desc = 'Automatic'
        THEN 1 END)
FROM sys.dm_server_services;

------------------------------------------------------------
-- SECTION 2: Consolidated Inventory Report
------------------------------------------------------------

SELECT
    @ReportDate AS ReportDate,
    @@SERVERNAME AS ServerName,
    SERVERPROPERTY('Edition') AS SQLEdition,
    SERVERPROPERTY('ProductVersion') AS SQLVersion,
    SERVERPROPERTY('ProductUpdateLevel') AS CULevel,

    @CPUCount AS LogicalCPUCount,
    @RAM_GB AS TotalRAM_GB,
    @UptimeDays AS UptimeDays,

    @TotalDBs AS TotalUserDatabases,
    @OnlineDBs AS OnlineUserDatabases,
    @NonOnlineDBs AS NonOnlineUserDatabases,
    @TotalDBSizeGB AS AllocatedDatabaseSize_GB,

    @TotalVolumes AS SQLStorageVolumes,
    @WarningVolumes AS WarningVolumes,
    @CriticalVolumes AS CriticalVolumes,
    @UnknownVolumes AS UnknownVolumes,

    CASE
        WHEN SERVERPROPERTY('IsHadrEnabled') = 1
            THEN 'AG Enabled - Review AG Health'
        WHEN SERVERPROPERTY('IsClustered') = 1
            THEN 'Failover Cluster Instance'
        ELSE 'Standalone'
    END AS HAConfiguration,

    @TotalJobs AS TotalAgentJobs,
    @EnabledJobs AS EnabledJobs,
    @DisabledJobs AS DisabledJobs,
    @FailedJobs AS FailedExecutions_Last24Hrs,

    @TotalServices AS TotalServices,
    @RunningServices AS RunningServices,
    @StoppedAutoServices AS StoppedAutomaticServices,

    CASE
        WHEN @CriticalVolumes > 0
            THEN 'CRITICAL - STORAGE'
        WHEN @NonOnlineDBs > 0
          OR @WarningVolumes > 0
          OR @FailedJobs > 0
          OR @StoppedAutoServices > 0
            THEN 'REVIEW REQUIRED'
        WHEN @UnknownVolumes > 0
          OR @TotalVolumes = 0
            THEN 'INCOMPLETE DATA'
        ELSE 'NO INVENTORY EXCEPTIONS DETECTED'
    END AS InventoryStatus;

GO
