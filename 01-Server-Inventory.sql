/*
============================================================
Project : SQL Server Production Optimization
Module  : 01 - Server Inventory
Script  : 01-Server-Inventory.sql
Purpose : Collect SQL Server instance and hardware details
Type    : Read-Only Assessment
============================================================
*/

USE master;
GO

SET NOCOUNT ON;

SELECT
    SYSDATETIME() AS CaptureDate,
    @@SERVERNAME AS ServerName,
    SERVERPROPERTY('MachineName') AS MachineName,
    ISNULL(SERVERPROPERTY('InstanceName'),
           'MSSQLSERVER') AS InstanceName,
    SERVERPROPERTY('Edition') AS SQLServerEdition,
    SERVERPROPERTY('ProductVersion') AS ProductVersion,
    SERVERPROPERTY('ProductLevel') AS ProductLevel,
    SERVERPROPERTY('ProductUpdateLevel') AS CULevel,
    SERVERPROPERTY('ProductUpdateReference') AS KBReference,
    SERVERPROPERTY('Collation') AS ServerCollation,

    CASE SERVERPROPERTY('IsClustered')
        WHEN 1 THEN 'Yes'
        ELSE 'No'
    END AS IsClustered,

    CASE SERVERPROPERTY('IsHadrEnabled')
        WHEN 1 THEN 'Enabled'
        ELSE 'Disabled'
    END AS AlwaysOnStatus,

    CASE SERVERPROPERTY('IsIntegratedSecurityOnly')
        WHEN 1 THEN 'Windows Authentication'
        ELSE 'Mixed Mode'
    END AS AuthenticationMode,

    SI.cpu_count AS LogicalCPUCount,
    SI.scheduler_count AS SchedulerCount,
    SI.hyperthread_ratio AS HyperthreadRatio,

    CAST(SI.physical_memory_kb / 1024.0 / 1024
        AS DECIMAL(10,2)) AS TotalRAM_GB,

    SI.virtual_machine_type_desc AS VirtualMachineType,
    SI.sqlserver_start_time AS SQLServerStartTime,

    CAST(DATEDIFF_BIG(SECOND,
        SI.sqlserver_start_time, GETDATE()) / 86400.0
        AS DECIMAL(10,2)) AS SQLServerUptime_Days

FROM sys.dm_os_sys_info AS SI;
GO
