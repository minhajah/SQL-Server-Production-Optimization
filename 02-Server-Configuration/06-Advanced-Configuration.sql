/*
============================================================
Project : SQL Server Production Optimization
Module  : 02 - Server Configuration
Script  : 06-Advanced-Configuration.sql
Purpose : Assess advanced SQL Server configuration
Type    : Read-Only Assessment
Impact  : Low - dependent on plan cache size
============================================================
*/

USE master;
GO

SET NOCOUNT ON;

------------------------------------------------------------
-- SECTION 1: Advanced Configuration Assessment
------------------------------------------------------------

SELECT
    SYSDATETIME() AS CaptureDate,
    @@SERVERNAME AS ServerName,
    name AS ConfigurationName,
    value AS ConfiguredValue,
    value_in_use AS RunningValue,

    CASE

        WHEN name = 'priority boost'
         AND CONVERT(INT, value_in_use) = 1
            THEN 'HIGH - Priority Boost Enabled'

        WHEN name = 'lightweight pooling'
         AND CONVERT(INT, value_in_use) = 1
            THEN 'HIGH - Lightweight Pooling Enabled'

        WHEN name = 'max worker threads'
         AND CONVERT(INT, value_in_use) <> 0
            THEN 'REVIEW - Manual Worker Thread Setting'

        WHEN name = 'optimize for ad hoc workloads'
         AND CONVERT(INT, value_in_use) = 0
            THEN 'REVIEW - Evaluate Plan Cache Usage'

        WHEN name = 'backup compression default'
         AND CONVERT(INT, value_in_use) = 0
            THEN 'REVIEW - Backup Compression Default'

        WHEN name = 'backup checksum default'
         AND CONVERT(INT, value_in_use) = 0
            THEN 'REVIEW - Backup Checksum Default'

        WHEN name = 'blocked process threshold (s)'
         AND CONVERT(INT, value_in_use) = 0
            THEN 'REVIEW - Blocked Process Reporting Disabled'

        WHEN name = 'blocked process threshold (s)'
         AND CONVERT(INT, value_in_use) BETWEEN 1 AND 4
            THEN 'REVIEW - Threshold Below 5 Seconds'

        WHEN name = 'query governor cost limit'
         AND CONVERT(INT, value_in_use) <> 0
            THEN 'REVIEW - Query Cost Restriction'

        WHEN name = 'recovery interval (min)'
         AND CONVERT(INT, value_in_use) <> 0
            THEN 'REVIEW - Manual Recovery Interval'

        WHEN name = 'user connections'
         AND CONVERT(INT, value_in_use) <> 0
            THEN 'REVIEW - Manual Connection Limit'

        WHEN name = 'fill factor (%)'
         AND CONVERT(INT, value_in_use) NOT IN (0, 100)
            THEN 'REVIEW - Instance-Level Fill Factor'

        ELSE 'No Basic Configuration Exception'

    END AS ConfigurationAssessment,

    description AS ConfigurationDescription

FROM sys.configurations

WHERE name IN
(
    'optimize for ad hoc workloads',
    'backup compression default',
    'backup checksum default',
    'blocked process threshold (s)',
    'max worker threads',
    'lightweight pooling',
    'priority boost',
    'query governor cost limit',
    'recovery interval (min)',
    'user connections',
    'fill factor (%)',
    'remote query timeout (s)',
    'remote login timeout (s)',
    'default trace enabled',
    'nested triggers',
    'cost threshold for parallelism',
    'network packet size (B)',
    'locks'
)

ORDER BY name;

------------------------------------------------------------
-- SECTION 2: Execution Plan Cache Distribution
------------------------------------------------------------

SELECT
    SYSDATETIME() AS CaptureDate,
    @@SERVERNAME AS ServerName,
    objtype AS ObjectType,
    cacheobjtype AS CacheObjectType,
    COUNT_BIG(*) AS CachedEntries,

    CAST(SUM(CAST(size_in_bytes AS BIGINT))
        / 1048576.0 AS DECIMAL(18,2))
        AS TotalCacheSize_MB,

    COUNT_BIG(CASE
        WHEN usecounts = 1 THEN 1 END)
        AS SingleUseEntries,

    CAST(SUM(CASE
        WHEN usecounts = 1
        THEN CAST(size_in_bytes AS BIGINT)
        ELSE 0
    END) / 1048576.0 AS DECIMAL(18,2))
        AS SingleUseCache_MB

FROM sys.dm_exec_cached_plans

GROUP BY
    objtype,
    cacheobjtype

ORDER BY TotalCacheSize_MB DESC;

------------------------------------------------------------
-- SECTION 3: Single-Use Ad Hoc Plan Assessment
------------------------------------------------------------

DECLARE
    @TotalPlanCacheBytes BIGINT,
    @AdHocPlanCount BIGINT,
    @AdHocPlanBytes BIGINT,
    @SingleUseAdHocCount BIGINT,
    @SingleUseAdHocBytes BIGINT,
    @OptimizeAdHoc INT;

SELECT
    @TotalPlanCacheBytes =
        COALESCE(SUM(CAST(size_in_bytes AS BIGINT)), 0),

    @AdHocPlanCount = COUNT_BIG(CASE
        WHEN objtype = 'Adhoc'
         AND cacheobjtype = 'Compiled Plan'
        THEN 1 END),

    @AdHocPlanBytes = COALESCE(SUM(CASE
        WHEN objtype = 'Adhoc'
         AND cacheobjtype = 'Compiled Plan'
        THEN CAST(size_in_bytes AS BIGINT)
        ELSE 0 END), 0),

    @SingleUseAdHocCount = COUNT_BIG(CASE
        WHEN objtype = 'Adhoc'
         AND cacheobjtype = 'Compiled Plan'
         AND usecounts = 1
        THEN 1 END),

    @SingleUseAdHocBytes = COALESCE(SUM(CASE
        WHEN objtype = 'Adhoc'
         AND cacheobjtype = 'Compiled Plan'
         AND usecounts = 1
        THEN CAST(size_in_bytes AS BIGINT)
        ELSE 0 END), 0)

FROM sys.dm_exec_cached_plans;

SELECT
    @OptimizeAdHoc = CONVERT(INT, value_in_use)
FROM sys.configurations
WHERE name = 'optimize for ad hoc workloads';

SELECT
    SYSDATETIME() AS CaptureDate,
    @@SERVERNAME AS ServerName,
    @OptimizeAdHoc AS OptimizeForAdHocWorkloads,

    CAST(@TotalPlanCacheBytes / 1048576.0
        AS DECIMAL(18,2)) AS TotalPlanCache_MB,

    @AdHocPlanCount AS AdHocCompiledPlans,

    CAST(@AdHocPlanBytes / 1048576.0
        AS DECIMAL(18,2)) AS AdHocCompiledCache_MB,

    @SingleUseAdHocCount AS SingleUseAdHocPlans,

    CAST(@SingleUseAdHocBytes / 1048576.0
        AS DECIMAL(18,2)) AS SingleUseAdHocCache_MB,

    CAST(@SingleUseAdHocCount * 100.0 /
        NULLIF(@AdHocPlanCount, 0)
        AS DECIMAL(10,2))
        AS SingleUseAdHocPlan_Percent,

    CAST(@SingleUseAdHocBytes * 100.0 /
        NULLIF(@TotalPlanCacheBytes, 0)
        AS DECIMAL(10,2))
        AS SingleUseAdHoc_TotalCache_Percent,

    CASE
        WHEN @OptimizeAdHoc IS NULL
            THEN 'UNKNOWN - Setting Unavailable'

        WHEN @TotalPlanCacheBytes = 0
            THEN 'INSUFFICIENT CACHE DATA'

        WHEN @OptimizeAdHoc = 1
            THEN 'Enabled - Validate Cache Efficiency'

        WHEN @SingleUseAdHocBytes * 100.0 /
             NULLIF(@TotalPlanCacheBytes, 0) >= 25
            THEN 'REVIEW - High Single-Use Ad Hoc Cache'

        ELSE 'No Threshold Exception Detected'

    END AS PlanCacheAssessment;

------------------------------------------------------------
-- SECTION 4: Instant File Initialization Assessment
------------------------------------------------------------

SELECT
    SYSDATETIME() AS CaptureDate,
    @@SERVERNAME AS ServerName,
    servicename AS ServiceName,
    service_account AS ServiceAccount,

    CASE instant_file_initialization_enabled
        WHEN 'Y' THEN 'Enabled'
        WHEN 'N' THEN 'Disabled'
        ELSE 'Unknown / Not Applicable'
    END AS InstantFileInitialization,

    CASE
        WHEN instant_file_initialization_enabled = 'N'
            THEN 'REVIEW - IFI Disabled'

        WHEN instant_file_initialization_enabled = 'Y'
            THEN 'IFI Enabled'

        ELSE 'UNKNOWN / NOT APPLICABLE'

    END AS IFIAssessment

FROM sys.dm_server_services

WHERE process_id = CONVERT(
    INT, SERVERPROPERTY('ProcessID'));

------------------------------------------------------------
-- SECTION 5: Backup and Monitoring Configuration
------------------------------------------------------------

SELECT
    SYSDATETIME() AS CaptureDate,
    @@SERVERNAME AS ServerName,
    name AS ConfigurationName,
    value_in_use AS RunningValue,

    CASE

        WHEN name = 'backup compression default'
         AND CONVERT(INT, value_in_use) = 1
            THEN 'Default Compression Enabled'

        WHEN name = 'backup checksum default'
         AND CONVERT(INT, value_in_use) = 1
            THEN 'Default Checksum Enabled'

        WHEN name = 'blocked process threshold (s)'
         AND CONVERT(INT, value_in_use) >= 5
            THEN 'Blocked Process Threshold Configured'

        WHEN name = 'default trace enabled'
         AND CONVERT(INT, value_in_use) = 1
            THEN 'Default Trace Enabled'

        ELSE 'Review Against Operational Requirements'

    END AS OperationalAssessment

FROM sys.configurations

WHERE name IN
(
    'backup compression default',
    'backup checksum default',
    'blocked process threshold (s)',
    'default trace enabled'
)

ORDER BY name;

------------------------------------------------------------
-- SECTION 6: Consolidated Advanced Configuration
------------------------------------------------------------

DECLARE
    @PriorityBoost INT,
    @LightweightPooling INT,
    @MaxWorkerThreads INT,
    @BackupCompression INT,
    @BackupChecksum INT,
    @BlockedProcessThreshold INT,
    @IFI NVARCHAR(1);

SELECT
    @PriorityBoost = MAX(CASE
        WHEN name = 'priority boost'
        THEN CONVERT(INT, value_in_use) END),

    @LightweightPooling = MAX(CASE
        WHEN name = 'lightweight pooling'
        THEN CONVERT(INT, value_in_use) END),

    @MaxWorkerThreads = MAX(CASE
        WHEN name = 'max worker threads'
        THEN CONVERT(INT, value_in_use) END),

    @BackupCompression = MAX(CASE
        WHEN name = 'backup compression default'
        THEN CONVERT(INT, value_in_use) END),

    @BackupChecksum = MAX(CASE
        WHEN name = 'backup checksum default'
        THEN CONVERT(INT, value_in_use) END),

    @BlockedProcessThreshold = MAX(CASE
        WHEN name = 'blocked process threshold (s)'
        THEN CONVERT(INT, value_in_use) END)

FROM sys.configurations;

SELECT
    @IFI = instant_file_initialization_enabled
FROM sys.dm_server_services
WHERE process_id = CONVERT(
    INT, SERVERPROPERTY('ProcessID'));

SELECT
    SYSDATETIME() AS CaptureDate,
    @@SERVERNAME AS ServerName,
    @PriorityBoost AS PriorityBoost,
    @LightweightPooling AS LightweightPooling,
    @MaxWorkerThreads AS MaxWorkerThreads,
    @OptimizeAdHoc AS OptimizeForAdHocWorkloads,
    @BackupCompression AS BackupCompressionDefault,
    @BackupChecksum AS BackupChecksumDefault,
    @BlockedProcessThreshold AS BlockedProcessThreshold_SEC,

    CAST(@SingleUseAdHocBytes / 1048576.0
        AS DECIMAL(18,2)) AS SingleUseAdHocCache_MB,

    CAST(@SingleUseAdHocBytes * 100.0 /
        NULLIF(@TotalPlanCacheBytes, 0)
        AS DECIMAL(10,2))
        AS SingleUseAdHoc_TotalCache_Percent,

    CASE @IFI
        WHEN 'Y' THEN 'Enabled'
        WHEN 'N' THEN 'Disabled'
        ELSE 'Unknown'
    END AS InstantFileInitialization,

    CASE

        WHEN @PriorityBoost = 1
          OR @LightweightPooling = 1
            THEN 'HIGH - ADVANCED CONFIGURATION REVIEW'

        WHEN @MaxWorkerThreads <> 0
          OR @BackupCompression = 0
          OR @BackupChecksum = 0
          OR @BlockedProcessThreshold < 5
          OR @IFI = 'N'
            THEN 'REVIEW REQUIRED'

        WHEN @OptimizeAdHoc = 0
         AND @SingleUseAdHocBytes * 100.0 /
             NULLIF(@TotalPlanCacheBytes, 0) >= 25
            THEN 'REVIEW - PLAN CACHE EFFICIENCY'

        WHEN @IFI IS NULL
          OR @PriorityBoost IS NULL
          OR @LightweightPooling IS NULL
          OR @MaxWorkerThreads IS NULL
          OR @OptimizeAdHoc IS NULL
          OR @BackupCompression IS NULL
          OR @BackupChecksum IS NULL
          OR @BlockedProcessThreshold IS NULL
          OR @TotalPlanCacheBytes = 0
            THEN 'INCOMPLETE ASSESSMENT'

        ELSE 'NO BASIC SUMMARY EXCEPTIONS DETECTED'

    END AS OverallAdvancedConfigurationAssessment;

GO
