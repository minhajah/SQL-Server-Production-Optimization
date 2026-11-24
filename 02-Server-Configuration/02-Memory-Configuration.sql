/*
============================================================
Project : SQL Server Production Optimization
Module  : 02 - Server Configuration
Script  : 02-Memory-Configuration.sql
Purpose : Assess SQL Server memory configuration and pressure
Type    : Read-Only Assessment
Impact  : Low
============================================================
*/

USE master;
GO

SET NOCOUNT ON;
SET LOCK_TIMEOUT 5000;
SET DEADLOCK_PRIORITY LOW;

------------------------------------------------------------
-- SECTION 1: Operating System Memory
------------------------------------------------------------

SELECT
    SYSDATETIME() AS CaptureDate,
    @@SERVERNAME AS ServerName,

    CAST(total_physical_memory_kb / 1024.0
        AS DECIMAL(18,2)) AS TotalRAM_MB,

    CAST(available_physical_memory_kb / 1024.0
        AS DECIMAL(18,2)) AS AvailableRAM_MB,

    CAST(total_physical_memory_kb / 1048576.0
        AS DECIMAL(18,2)) AS TotalRAM_GB,

    CAST(available_physical_memory_kb / 1048576.0
        AS DECIMAL(18,2)) AS AvailableRAM_GB,

    CAST(available_physical_memory_kb * 100.0 /
        NULLIF(total_physical_memory_kb, 0)
        AS DECIMAL(10,2)) AS AvailableRAM_Percent,

    system_high_memory_signal_state AS HighMemorySignal,
    system_low_memory_signal_state AS LowMemorySignal,
    system_memory_state_desc AS OSMemoryState,

    CASE
        WHEN system_low_memory_signal_state = 1
            THEN 'WARNING - OS Memory Pressure Signal'
        ELSE 'No OS Low Memory Signal Detected'
    END AS MemoryStatus

FROM sys.dm_os_sys_memory;

------------------------------------------------------------
-- SECTION 2: SQL Server Memory Configuration
------------------------------------------------------------

DECLARE
    @TotalRAM_MB BIGINT,
    @MaxMemory_MB BIGINT,
    @MinMemory_MB BIGINT,
    @InitialEstimate_MB BIGINT;

SELECT
    @TotalRAM_MB = total_physical_memory_kb / 1024
FROM sys.dm_os_sys_memory;

SELECT
    @MaxMemory_MB = CONVERT(BIGINT, value_in_use)
FROM sys.configurations
WHERE name = 'max server memory (MB)';

SELECT
    @MinMemory_MB = CONVERT(BIGINT, value_in_use)
FROM sys.configurations
WHERE name = 'min server memory (MB)';

-- Preliminary estimate for a dedicated single-instance host.
-- This is not an approved configuration recommendation.

SET @InitialEstimate_MB = FLOOR(@TotalRAM_MB * 0.75);

SELECT
    SYSDATETIME() AS CaptureDate,
    @@SERVERNAME AS ServerName,
    @TotalRAM_MB AS TotalRAM_MB,
    @MinMemory_MB AS MinServerMemory_MB,
    @MaxMemory_MB AS MaxServerMemory_MB,

    CASE
        WHEN @MaxMemory_MB = 2147483647 THEN NULL
        ELSE CAST(@MaxMemory_MB / 1024.0
            AS DECIMAL(18,2))
    END AS MaxServerMemory_GB,

    CASE
        WHEN @MaxMemory_MB = 2147483647 THEN NULL
        ELSE CAST(@MaxMemory_MB * 100.0 /
            NULLIF(@TotalRAM_MB, 0)
            AS DECIMAL(10,2))
    END AS MaxMemory_PercentOfRAM,

    @InitialEstimate_MB AS Preliminary75Percent_MB,

    CASE
        WHEN @MaxMemory_MB = 2147483647
            THEN 'REVIEW - Default Unlimited Setting'

        WHEN @MaxMemory_MB >= @TotalRAM_MB
            THEN 'REVIEW - Insufficient Configured Headroom'

        WHEN @MinMemory_MB > @MaxMemory_MB
            THEN 'REVIEW - Memory Configuration Conflict'

        ELSE 'Configured - Validate Against Workload'
    END AS ConfigurationAssessment;

------------------------------------------------------------
-- SECTION 3: SQL Server Process Memory
------------------------------------------------------------

SELECT
    SYSDATETIME() AS CaptureDate,
    @@SERVERNAME AS ServerName,

    CAST(physical_memory_in_use_kb / 1024.0
        AS DECIMAL(18,2)) AS SQLProcessMemory_MB,

    CAST(physical_memory_in_use_kb / 1048576.0
        AS DECIMAL(18,2)) AS SQLProcessMemory_GB,

    CAST(locked_page_allocations_kb / 1024.0
        AS DECIMAL(18,2)) AS LockedPages_MB,

    CAST(large_page_allocations_kb / 1024.0
        AS DECIMAL(18,2)) AS LargePages_MB,

    memory_utilization_percentage
        AS ProcessMemoryUtilization_Percent,

    process_physical_memory_low
        AS PhysicalMemoryLow,

    process_virtual_memory_low
        AS VirtualMemoryLow,

    CASE
        WHEN process_physical_memory_low = 1
            THEN 'WARNING - Physical Memory Pressure'

        WHEN process_virtual_memory_low = 1
            THEN 'WARNING - Virtual Memory Pressure'

        ELSE 'No Process Low Memory Signal Detected'
    END AS MemoryPressureStatus

FROM sys.dm_os_process_memory;

------------------------------------------------------------
-- SECTION 4: SQL Server Memory Performance Counters
------------------------------------------------------------

SELECT
    SYSDATETIME() AS CaptureDate,
    @@SERVERNAME AS ServerName,
    RTRIM(counter_name) AS CounterName,
    cntr_value AS CounterValue,

    CASE RTRIM(counter_name)
        WHEN 'Total Server Memory (KB)' THEN 'KB'
        WHEN 'Target Server Memory (KB)' THEN 'KB'
        WHEN 'Granted Workspace Memory (KB)' THEN 'KB'
        WHEN 'Maximum Workspace Memory (KB)' THEN 'KB'
        WHEN 'Memory Grants Pending' THEN 'Count'
        WHEN 'Memory Grants Outstanding' THEN 'Count'
        ELSE 'Unknown'
    END AS Unit

FROM sys.dm_os_performance_counters

WHERE object_name LIKE '%:Memory Manager%'
AND counter_name IN
(
    'Total Server Memory (KB)',
    'Target Server Memory (KB)',
    'Granted Workspace Memory (KB)',
    'Maximum Workspace Memory (KB)',
    'Memory Grants Pending',
    'Memory Grants Outstanding'
)

ORDER BY counter_name;

------------------------------------------------------------
-- SECTION 5: Queries Waiting for Memory Grants
------------------------------------------------------------

SELECT
    SYSDATETIME() AS CaptureDate,
    @@SERVERNAME AS ServerName,
    MG.session_id AS SessionID,
    MG.request_id AS RequestID,
    DB_NAME(R.database_id) AS DatabaseName,
    MG.request_time AS RequestTime,
    MG.wait_time_ms AS WaitTime_MS,
    MG.dop AS DOP,

    CAST(MG.requested_memory_kb / 1024.0
        AS DECIMAL(18,2)) AS RequestedMemory_MB,

    CAST(MG.required_memory_kb / 1024.0
        AS DECIMAL(18,2)) AS RequiredMemory_MB,

    MG.timeout_sec AS Timeout_SEC,
    R.wait_type AS WaitType,
    R.blocking_session_id AS BlockingSessionID

FROM sys.dm_exec_query_memory_grants AS MG

LEFT JOIN sys.dm_exec_requests AS R
    ON MG.session_id = R.session_id
    AND MG.request_id = R.request_id

WHERE MG.grant_time IS NULL

ORDER BY MG.wait_time_ms DESC;

------------------------------------------------------------
-- SECTION 6: Memory Configuration Summary
------------------------------------------------------------

SELECT
    SYSDATETIME() AS CaptureDate,
    @@SERVERNAME AS ServerName,

    @TotalRAM_MB AS TotalRAM_MB,
    @MaxMemory_MB AS MaxServerMemory_MB,
    @MinMemory_MB AS MinServerMemory_MB,

    CAST(SM.available_physical_memory_kb / 1024.0
        AS DECIMAL(18,2)) AS AvailableOSMemory_MB,

    CAST(PM.physical_memory_in_use_kb / 1024.0
        AS DECIMAL(18,2)) AS SQLProcessMemory_MB,

    MG.PendingGrants AS PendingMemoryGrants,

    CASE
        WHEN SM.system_low_memory_signal_state = 1
          OR PM.process_physical_memory_low = 1
          OR PM.process_virtual_memory_low = 1
            THEN 'WARNING - Memory Pressure Signal'

        WHEN MG.PendingGrants > 0
            THEN 'WARNING - Pending Memory Grants'

        WHEN @MaxMemory_MB = 2147483647
            THEN 'REVIEW - Default Max Memory'

        WHEN @MaxMemory_MB >= @TotalRAM_MB
            THEN 'REVIEW - Max Memory Headroom'

        ELSE 'NO IMMEDIATE MEMORY EXCEPTIONS DETECTED'
    END AS OverallMemoryAssessment

FROM sys.dm_os_sys_memory AS SM

CROSS JOIN sys.dm_os_process_memory AS PM

CROSS JOIN
(
    SELECT COUNT(*) AS PendingGrants
    FROM sys.dm_exec_query_memory_grants
    WHERE grant_time IS NULL
) AS MG;

------------------------------------------------------------
-- Restore default session settings
------------------------------------------------------------

SET LOCK_TIMEOUT -1;
SET DEADLOCK_PRIORITY NORMAL;

GO
