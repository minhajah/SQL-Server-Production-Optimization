/*
============================================================
Project : SQL Server Production Optimization
Module  : 02 - Server Configuration
Script  : 07-Configuration-Assessment.sql
Purpose : Generate consolidated configuration findings
Type    : Read-Only Assessment
Impact  : Low - dependent on plan cache size
============================================================
*/

USE master;
GO

SET NOCOUNT ON;

------------------------------------------------------------
-- SECTION 1: Assessment Variables
------------------------------------------------------------

DECLARE
    @CaptureDate DATETIME2 = SYSDATETIME(),
    @TotalRAM_MB BIGINT,
    @AvailableRAM_MB BIGINT,
    @MaxMemory_MB BIGINT,
    @MinMemory_MB BIGINT,
    @OSMemoryLow INT,
    @ProcessMemoryLow INT,
    @PendingGrants INT,
    @CPUCount INT,
    @NUMANodes INT,
    @MinSchedulers INT,
    @MaxSchedulers INT,
    @CurrentMAXDOP INT,
    @SuggestedMAXDOP INT,
    @TempDBFiles INT,
    @ExpectedTempDBFiles INT,
    @TempDBDistinctSizes INT,
    @TempDBDistinctGrowth INT,
    @TempDBPercentGrowth INT,
    @TempDBGrowthDisabled INT,
    @TempDBLogFiles INT,
    @TrustworthyDBs INT,
    @ChainingDBs INT,
    @SAEnabled INT,
    @ConfigMismatch INT,
    @IFI NVARCHAR(1),
    @OptimizeAdHoc INT,
    @TotalCacheBytes BIGINT,
    @SingleUseAdHocBytes BIGINT,
    @SingleUsePercent DECIMAL(10,2);

------------------------------------------------------------
-- SECTION 2: Temporary Assessment Results
------------------------------------------------------------

DECLARE @Findings TABLE
(
    AssessmentID VARCHAR(20),
    Category VARCHAR(50),
    AssessmentName NVARCHAR(150),
    CurrentValue NVARCHAR(200),
    PreferredBaseline NVARCHAR(250),
    Priority VARCHAR(20),
    AssessmentStatus VARCHAR(30),
    RecommendedAction NVARCHAR(1000)
);

------------------------------------------------------------
-- SECTION 3: Server Configuration
------------------------------------------------------------

SELECT
    @ConfigMismatch = COUNT(*)
FROM sys.configurations
WHERE value <> value_in_use;

INSERT INTO @Findings
VALUES
(
    'CFG-001',
    'Server Configuration',
    'Configured vs Running Values',
    CONVERT(NVARCHAR(30), @ConfigMismatch),
    'No unexplained mismatches',
    CASE WHEN @ConfigMismatch > 0
        THEN 'MEDIUM' ELSE 'INFO' END,
    CASE WHEN @ConfigMismatch > 0
        THEN 'REVIEW' ELSE 'PASS' END,
    'Investigate mismatches before applying RECONFIGURE
     or scheduling a restart.'
);

------------------------------------------------------------
-- SECTION 4: Memory Configuration
------------------------------------------------------------

SELECT
    @TotalRAM_MB = total_physical_memory_kb / 1024,
    @AvailableRAM_MB = available_physical_memory_kb / 1024,
    @OSMemoryLow = system_low_memory_signal_state
FROM sys.dm_os_sys_memory;

SELECT
    @ProcessMemoryLow =
        CASE
            WHEN process_physical_memory_low = 1
              OR process_virtual_memory_low = 1
                THEN 1
            ELSE 0
        END
FROM sys.dm_os_process_memory;

SELECT
    @MaxMemory_MB = MAX(CASE
        WHEN name = 'max server memory (MB)'
        THEN CONVERT(BIGINT, value_in_use) END),

    @MinMemory_MB = MAX(CASE
        WHEN name = 'min server memory (MB)'
        THEN CONVERT(BIGINT, value_in_use) END)
FROM sys.configurations;

SELECT
    @PendingGrants = COUNT(*)
FROM sys.dm_exec_query_memory_grants
WHERE grant_time IS NULL;

INSERT INTO @Findings
VALUES
(
    'MEM-001',
    'Memory',
    'Maximum Server Memory',
    CONCAT(@MaxMemory_MB, ' MB / ',
           @TotalRAM_MB, ' MB RAM'),
    'Workload-based memory limit with OS headroom',

    CASE
        WHEN @MaxMemory_MB IS NULL THEN 'MEDIUM'
        WHEN @MaxMemory_MB >= @TotalRAM_MB THEN 'HIGH'
        ELSE 'INFO'
    END,

    CASE
        WHEN @MaxMemory_MB IS NULL THEN 'UNKNOWN'
        WHEN @MaxMemory_MB = 2147483647 THEN 'REVIEW'
        WHEN @MaxMemory_MB >= @TotalRAM_MB THEN 'REVIEW'
        ELSE 'OBSERVE'
    END,

    'Review OS requirements, other SQL instances,
     agents and allocations outside the memory cap.'
),
(
    'MEM-002',
    'Memory',
    'Minimum Server Memory',
    CONCAT(@MinMemory_MB, ' MB'),
    'Based on workload and instance requirements',
    CASE WHEN @MinMemory_MB > 0
        THEN 'MEDIUM' ELSE 'INFO' END,
    CASE
        WHEN @MinMemory_MB IS NULL THEN 'UNKNOWN'
        WHEN @MinMemory_MB > 0 THEN 'REVIEW'
        ELSE 'PASS'
    END,
    'Validate minimum memory requirements.'
),
(
    'MEM-003',
    'Memory',
    'Operating System Memory Pressure',
    CONCAT('Available RAM: ', @AvailableRAM_MB, ' MB'),
    'No active low memory signal',
    CASE WHEN @OSMemoryLow = 1
        THEN 'HIGH' ELSE 'INFO' END,
    CASE
        WHEN @OSMemoryLow IS NULL THEN 'UNKNOWN'
        WHEN @OSMemoryLow = 1 THEN 'REVIEW'
        ELSE 'PASS'
    END,
    'Investigate sustained OS memory pressure.'
),
(
    'MEM-004',
    'Memory',
    'SQL Server Process Memory Pressure',
    CONVERT(NVARCHAR(30), @ProcessMemoryLow),
    'No active process low memory signal',
    CASE WHEN @ProcessMemoryLow = 1
        THEN 'HIGH' ELSE 'INFO' END,
    CASE
        WHEN @ProcessMemoryLow IS NULL THEN 'UNKNOWN'
        WHEN @ProcessMemoryLow = 1 THEN 'REVIEW'
        ELSE 'PASS'
    END,
    'Investigate SQL Server process memory pressure.'
),
(
    'MEM-005',
    'Memory',
    'Pending Memory Grants',
    CONVERT(NVARCHAR(30), @PendingGrants),
    'No persistent pending grants',
    CASE WHEN @PendingGrants > 0
        THEN 'HIGH' ELSE 'INFO' END,
    CASE
        WHEN @PendingGrants > 0 THEN 'REVIEW'
        ELSE 'PASS'
    END,
    'Investigate memory-intensive queries if
     pending grants persist.'
);

------------------------------------------------------------
-- SECTION 5: CPU and MAXDOP Configuration
------------------------------------------------------------

;WITH NodeDistribution AS
(
    SELECT
        parent_node_id,
        COUNT(*) AS SchedulerCount
    FROM sys.dm_os_schedulers
    WHERE status = 'VISIBLE ONLINE'
    GROUP BY parent_node_id
)
SELECT
    @NUMANodes = COUNT(*),
    @CPUCount = SUM(SchedulerCount),
    @MinSchedulers = MIN(SchedulerCount),
    @MaxSchedulers = MAX(SchedulerCount)
FROM NodeDistribution;

SET @SuggestedMAXDOP =
    CASE
        WHEN @NUMANodes = 0 THEN NULL
        WHEN @NUMANodes = 1
         AND @MinSchedulers <= 8 THEN @MinSchedulers
        WHEN @NUMANodes = 1 THEN 8
        WHEN @MinSchedulers <= 16 THEN @MinSchedulers
        WHEN @MinSchedulers / 2 > 16 THEN 16
        ELSE @MinSchedulers / 2
    END;

SELECT
    @CurrentMAXDOP = CONVERT(INT, value_in_use)
FROM sys.configurations
WHERE name = 'max degree of parallelism';

INSERT INTO @Findings
VALUES
(
    'CPU-001',
    'Parallelism',
    'Maximum Degree of Parallelism',
    CONVERT(NVARCHAR(30), @CurrentMAXDOP),
    CONCAT('Topology guideline: ', @SuggestedMAXDOP),

    CASE
        WHEN @CurrentMAXDOP = 0
          OR @CurrentMAXDOP > @SuggestedMAXDOP
            THEN 'MEDIUM'
        ELSE 'INFO'
    END,

    CASE
        WHEN @SuggestedMAXDOP IS NULL
          OR @CurrentMAXDOP IS NULL THEN 'UNKNOWN'
        WHEN @MinSchedulers <> @MaxSchedulers
            THEN 'REVIEW'
        WHEN @CurrentMAXDOP = 0
          OR @CurrentMAXDOP > @SuggestedMAXDOP
            THEN 'REVIEW'
        ELSE 'OBSERVE'
    END,

    'Validate MAXDOP against workload, NUMA topology,
     database overrides and query performance.'
);

------------------------------------------------------------
-- SECTION 6: TempDB Configuration
------------------------------------------------------------

SELECT
    @TempDBFiles = COUNT(*),
    @TempDBDistinctSizes = COUNT(DISTINCT size),
    @TempDBDistinctGrowth = COUNT(DISTINCT growth),
    @TempDBPercentGrowth = COUNT(CASE
        WHEN is_percent_growth = 1 THEN 1 END),
    @TempDBGrowthDisabled = COUNT(CASE
        WHEN growth = 0 THEN 1 END)
FROM tempdb.sys.database_files
WHERE type = 0;

SELECT
    @TempDBLogFiles = COUNT(*)
FROM tempdb.sys.database_files
WHERE type = 1;

SET @ExpectedTempDBFiles =
    CASE
        WHEN @CPUCount IS NULL OR @CPUCount = 0
            THEN NULL
        WHEN @CPUCount <= 8 THEN @CPUCount
        ELSE 8
    END;

INSERT INTO @Findings
VALUES
(
    'TMP-001',
    'TempDB',
    'Data File Count',
    CONVERT(NVARCHAR(30), @TempDBFiles),
    CONCAT('Initial guideline: ', @ExpectedTempDBFiles),
    CASE WHEN @TempDBFiles <> @ExpectedTempDBFiles
        THEN 'MEDIUM' ELSE 'INFO' END,
    CASE
        WHEN @ExpectedTempDBFiles IS NULL THEN 'UNKNOWN'
        WHEN @TempDBFiles <> @ExpectedTempDBFiles
            THEN 'REVIEW'
        ELSE 'PASS'
    END,
    'Assess allocation contention before adding
     or removing data files.'
),
(
    'TMP-002',
    'TempDB',
    'Data File Size Consistency',
    CONCAT(@TempDBDistinctSizes, ' distinct sizes'),
    'Equally sized data files',
    CASE WHEN @TempDBDistinctSizes > 1
        THEN 'MEDIUM' ELSE 'INFO' END,
    CASE
        WHEN @TempDBFiles = 0 THEN 'UNKNOWN'
        WHEN @TempDBDistinctSizes > 1 THEN 'REVIEW'
        ELSE 'PASS'
    END,
    'Review startup and current data file sizes.'
),
(
    'TMP-003',
    'TempDB',
    'Data File Growth Configuration',
    CONCAT(
        @TempDBDistinctGrowth, ' growth values; ',
        @TempDBPercentGrowth, ' percentage-based; ',
        @TempDBGrowthDisabled, ' disabled'),
    'Consistent fixed growth, where appropriate',

    CASE
        WHEN @TempDBDistinctGrowth > 1
          OR @TempDBPercentGrowth > 0
          OR @TempDBGrowthDisabled > 0
            THEN 'MEDIUM'
        ELSE 'INFO'
    END,

    CASE
        WHEN @TempDBFiles = 0 THEN 'UNKNOWN'
        WHEN @TempDBDistinctGrowth > 1
          OR @TempDBPercentGrowth > 0
          OR @TempDBGrowthDisabled > 0
            THEN 'REVIEW'
        ELSE 'PASS'
    END,

    'Review growth increments, workload and
     available disk capacity.'
),
(
    'TMP-004',
    'TempDB',
    'Transaction Log File Count',
    CONVERT(NVARCHAR(30), @TempDBLogFiles),
    'One log file under normal circumstances',
    CASE WHEN @TempDBLogFiles > 1
        THEN 'MEDIUM' ELSE 'INFO' END,
    CASE
        WHEN @TempDBLogFiles = 0 THEN 'UNKNOWN'
        WHEN @TempDBLogFiles > 1 THEN 'REVIEW'
        ELSE 'PASS'
    END,
    'Review the reason for multiple log files.'
);

------------------------------------------------------------
-- SECTION 7: Security Configuration
------------------------------------------------------------

SELECT
    @SAEnabled = CONVERT(INT, 1 - is_disabled)
FROM sys.sql_logins
WHERE sid = 0x01;

SELECT
    @TrustworthyDBs = COUNT(CASE
        WHEN is_trustworthy_on = 1 THEN 1 END),
    @ChainingDBs = COUNT(CASE
        WHEN is_db_chaining_on = 1 THEN 1 END)
FROM sys.databases
WHERE database_id > 4
AND source_database_id IS NULL;

INSERT INTO @Findings
VALUES
(
    'SEC-001',
    'Security',
    'Built-in SA Account',
    CASE @SAEnabled
        WHEN 1 THEN 'Enabled'
        WHEN 0 THEN 'Disabled'
        ELSE 'Unknown'
    END,
    'Disabled where operationally feasible',
    CASE WHEN @SAEnabled = 1
        THEN 'HIGH' ELSE 'INFO' END,
    CASE
        WHEN @SAEnabled IS NULL THEN 'UNKNOWN'
        WHEN @SAEnabled = 1 THEN 'REVIEW'
        ELSE 'PASS'
    END,
    'Verify dependencies before disabling
     the built-in administrator login.'
),
(
    'SEC-002',
    'Security',
    'TRUSTWORTHY Databases',
    CONVERT(NVARCHAR(30), @TrustworthyDBs),
    'Disabled unless explicitly justified',
    CASE WHEN @TrustworthyDBs > 0
        THEN 'HIGH' ELSE 'INFO' END,
    CASE WHEN @TrustworthyDBs > 0
        THEN 'REVIEW' ELSE 'PASS' END,
    'Review databases using TRUSTWORTHY.'
),
(
    'SEC-003',
    'Security',
    'Database Ownership Chaining',
    CONVERT(NVARCHAR(30), @ChainingDBs),
    'Disabled unless explicitly justified',
    CASE WHEN @ChainingDBs > 0
        THEN 'HIGH' ELSE 'INFO' END,
    CASE WHEN @ChainingDBs > 0
        THEN 'REVIEW' ELSE 'PASS' END,
    'Validate cross-database security dependencies.'
),
(
    'SEC-004',
    'Security',
    'Authentication Mode',
    CASE SERVERPROPERTY('IsIntegratedSecurityOnly')
        WHEN 1 THEN 'Windows Authentication'
        WHEN 0 THEN 'Mixed Mode'
        ELSE 'Unknown'
    END,
    'Windows Authentication where feasible',
    'INFO',
    CASE SERVERPROPERTY('IsIntegratedSecurityOnly')
        WHEN 1 THEN 'PASS'
        WHEN 0 THEN 'OBSERVE'
        ELSE 'UNKNOWN'
    END,
    'Validate authentication against
     application and security requirements.'
);

------------------------------------------------------------
-- SECTION 8: Instance-Level Configuration Rules
------------------------------------------------------------

INSERT INTO @Findings
SELECT
    R.AssessmentID,
    R.Category,
    R.ConfigurationName,

    CASE
        WHEN C.name IS NULL THEN 'Unavailable'
        ELSE CONVERT(NVARCHAR(30), C.value_in_use)
    END,

    R.PreferredBaseline,

    CASE
        WHEN C.name IS NULL THEN 'INFO'
        WHEN CONVERT(INT, C.value_in_use) = R.ReviewValue
            THEN R.ReviewPriority
        ELSE 'INFO'
    END,

    CASE
        WHEN C.name IS NULL THEN 'NOT AVAILABLE'
        WHEN CONVERT(INT, C.value_in_use) = R.ReviewValue
            THEN 'REVIEW'
        ELSE 'OBSERVE'
    END,

    R.RecommendedAction

FROM
(
    VALUES
    (
        'CPU-002', 'Parallelism',
        'cost threshold for parallelism',
        5, 'MEDIUM',
        'Workload-based threshold',
        'Evaluate query cost and parallelism patterns.'
    ),
    (
        'SEC-005', 'Security',
        'xp_cmdshell',
        1, 'HIGH',
        'Disabled unless approved',
        'Verify business and security requirements.'
    ),
    (
        'SEC-006', 'Security',
        'Ole Automation Procedures',
        1, 'HIGH',
        'Disabled unless approved',
        'Review application dependencies.'
    ),
    (
        'SEC-007', 'Security',
        'Ad Hoc Distributed Queries',
        1, 'HIGH',
        'Disabled unless approved',
        'Review external data access requirements.'
    ),
    (
        'SEC-008', 'Security',
        'cross db ownership chaining',
        1, 'HIGH',
        'Disabled unless approved',
        'Review instance-wide ownership chaining.'
    ),
    (
        'SEC-009', 'Security',
        'clr strict security',
        0, 'HIGH',
        'Enabled where supported',
        'Review CLR security and application dependencies.'
    ),
    (
        'SEC-010', 'Security',
        'clr enabled',
        1, 'MEDIUM',
        'Based on application requirements',
        'Validate CLR usage before considering changes.'
    ),
    (
        'ADV-001', 'Advanced Configuration',
        'priority boost',
        1, 'HIGH',
        'Disabled',
        'Review unsupported or unnecessary tuning.'
    ),
    (
        'ADV-002', 'Advanced Configuration',
        'lightweight pooling',
        1, 'HIGH',
        'Disabled',
        'Review fiber-mode configuration.'
    ),
    (
        'ADV-003', 'Advanced Configuration',
        'backup compression default',
        0, 'MEDIUM',
        'Based on backup strategy',
        'Verify actual backup compression behavior.'
    ),
    (
        'ADV-004', 'Advanced Configuration',
        'backup checksum default',
        0, 'MEDIUM',
        'Enabled where supported by backup strategy',
        'Verify checksum usage in actual backups.'
    ),
    (
        'ADV-005', 'Advanced Configuration',
        'blocked process threshold (s)',
        0, 'MEDIUM',
        'Based on monitoring requirements',
        'Verify existing blocking monitoring coverage.'
    )
) AS R
(
    AssessmentID,
    Category,
    ConfigurationName,
    ReviewValue,
    ReviewPriority,
    PreferredBaseline,
    RecommendedAction
)

LEFT JOIN sys.configurations AS C
    ON R.ConfigurationName = C.name;

------------------------------------------------------------
-- SECTION 9: Additional Advanced Configuration
------------------------------------------------------------

INSERT INTO @Findings
SELECT
    CASE name
        WHEN 'max worker threads' THEN 'ADV-006'
        WHEN 'query governor cost limit' THEN 'ADV-007'
        WHEN 'recovery interval (min)' THEN 'ADV-008'
        WHEN 'user connections' THEN 'ADV-009'
    END,

    'Advanced Configuration',
    name,
    CONVERT(NVARCHAR(30), value_in_use),
    'Default automatic or unrestricted setting',

    CASE WHEN CONVERT(INT, value_in_use) <> 0
        THEN 'MEDIUM' ELSE 'INFO' END,

    CASE WHEN CONVERT(INT, value_in_use) <> 0
        THEN 'REVIEW' ELSE 'PASS' END,

    'Validate non-default settings against
     documented production requirements.'

FROM sys.configurations
WHERE name IN
(
    'max worker threads',
    'query governor cost limit',
    'recovery interval (min)',
    'user connections'
);

------------------------------------------------------------
-- SECTION 10: Instant File Initialization
------------------------------------------------------------

SELECT
    @IFI = instant_file_initialization_enabled
FROM sys.dm_server_services
WHERE process_id =
    CONVERT(INT, SERVERPROPERTY('ProcessID'));

INSERT INTO @Findings
VALUES
(
    'ADV-010',
    'Advanced Configuration',
    'Instant File Initialization',
    CASE @IFI
        WHEN 'Y' THEN 'Enabled'
        WHEN 'N' THEN 'Disabled'
        ELSE 'Unknown'
    END,
    'Enabled where security requirements permit',
    CASE WHEN @IFI = 'N'
        THEN 'MEDIUM' ELSE 'INFO' END,
    CASE
        WHEN @IFI = 'Y' THEN 'PASS'
        WHEN @IFI = 'N' THEN 'REVIEW'
        ELSE 'UNKNOWN'
    END,
    'Review database file allocation performance
     and security requirements.'
);

------------------------------------------------------------
-- SECTION 11: Plan Cache Assessment
------------------------------------------------------------

SELECT
    @OptimizeAdHoc = CONVERT(INT, value_in_use)
FROM sys.configurations
WHERE name = 'optimize for ad hoc workloads';

SELECT
    @TotalCacheBytes =
        COALESCE(SUM(CAST(size_in_bytes AS BIGINT)), 0),

    @SingleUseAdHocBytes = COALESCE(SUM(
        CASE
            WHEN objtype = 'Adhoc'
             AND cacheobjtype = 'Compiled Plan'
             AND usecounts = 1
            THEN CAST(size_in_bytes AS BIGINT)
            ELSE 0
        END), 0)

FROM sys.dm_exec_cached_plans;

SET @SingleUsePercent =
    @SingleUseAdHocBytes * 100.0 /
    NULLIF(@TotalCacheBytes, 0);

INSERT INTO @Findings
VALUES
(
    'ADV-011',
    'Advanced Configuration',
    'Optimize for Ad Hoc Workloads',

    CONCAT(
        'Setting: ', @OptimizeAdHoc,
        '; Single-use cache: ',
        @SingleUsePercent, '%'),

    'Based on plan cache efficiency',

    CASE
        WHEN @OptimizeAdHoc = 0
         AND @SingleUsePercent >= 25
            THEN 'MEDIUM'
        ELSE 'INFO'
    END,

    CASE
        WHEN @OptimizeAdHoc IS NULL
          OR @SingleUsePercent IS NULL THEN 'UNKNOWN'
        WHEN @OptimizeAdHoc = 0
         AND @SingleUsePercent >= 25 THEN 'REVIEW'
        ELSE 'OBSERVE'
    END,

    'Review single-use ad hoc plan memory consumption
     before recommending configuration changes.'
);

------------------------------------------------------------
-- RESULT 1: All Configuration Assessments
------------------------------------------------------------

SELECT
    @CaptureDate AS CaptureDate,
    @@SERVERNAME AS ServerName,
    AssessmentID,
    Category,
    AssessmentName,
    CurrentValue,
    PreferredBaseline,
    Priority,
    AssessmentStatus,
    RecommendedAction

FROM @Findings

ORDER BY
    CASE Priority
        WHEN 'HIGH' THEN 1
        WHEN 'MEDIUM' THEN 2
        WHEN 'LOW' THEN 3
        ELSE 4
    END,
    AssessmentID;

------------------------------------------------------------
-- RESULT 2: Actionable Findings Only
------------------------------------------------------------

SELECT
    AssessmentID,
    Category,
    AssessmentName,
    CurrentValue,
    PreferredBaseline,
    Priority,
    RecommendedAction

FROM @Findings
WHERE AssessmentStatus = 'REVIEW'

ORDER BY
    CASE Priority
        WHEN 'HIGH' THEN 1
        WHEN 'MEDIUM' THEN 2
        WHEN 'LOW' THEN 3
        ELSE 4
    END,
    AssessmentID;

------------------------------------------------------------
-- RESULT 3: Category-Level Summary
------------------------------------------------------------

SELECT
    Category,
    COUNT(*) AS TotalChecks,

    COUNT(CASE WHEN AssessmentStatus = 'PASS'
        THEN 1 END) AS PassedChecks,

    COUNT(CASE WHEN AssessmentStatus = 'REVIEW'
        THEN 1 END) AS ReviewRequired,

    COUNT(CASE WHEN AssessmentStatus = 'OBSERVE'
        THEN 1 END) AS ObservationChecks,

    COUNT(CASE WHEN AssessmentStatus IN
        ('UNKNOWN', 'NOT AVAILABLE')
        THEN 1 END) AS UnavailableChecks,

    COUNT(CASE WHEN Priority = 'HIGH'
        AND AssessmentStatus = 'REVIEW'
        THEN 1 END) AS HighPriorityFindings,

    COUNT(CASE WHEN Priority = 'MEDIUM'
        AND AssessmentStatus = 'REVIEW'
        THEN 1 END) AS MediumPriorityFindings

FROM @Findings

GROUP BY Category
ORDER BY Category;

------------------------------------------------------------
-- RESULT 4: Overall Configuration Summary
------------------------------------------------------------

SELECT
    @CaptureDate AS CaptureDate,
    @@SERVERNAME AS ServerName,

    COUNT(*) AS TotalAssessments,

    COUNT(CASE WHEN AssessmentStatus = 'PASS'
        THEN 1 END) AS PassedChecks,

    COUNT(CASE WHEN AssessmentStatus = 'REVIEW'
        THEN 1 END) AS ReviewRequired,

    COUNT(CASE WHEN AssessmentStatus = 'OBSERVE'
        THEN 1 END) AS ObservationChecks,

    COUNT(CASE WHEN AssessmentStatus IN
        ('UNKNOWN', 'NOT AVAILABLE')
        THEN 1 END) AS UnavailableChecks,

    COUNT(CASE WHEN Priority = 'HIGH'
        AND AssessmentStatus = 'REVIEW'
        THEN 1 END) AS HighPriorityFindings,

    COUNT(CASE WHEN Priority = 'MEDIUM'
        AND AssessmentStatus = 'REVIEW'
        THEN 1 END) AS MediumPriorityFindings,

    CASE

        WHEN COUNT(CASE
            WHEN Priority = 'HIGH'
             AND AssessmentStatus = 'REVIEW'
            THEN 1 END) > 0
            THEN 'HIGH PRIORITY REVIEW REQUIRED'

        WHEN COUNT(CASE
            WHEN AssessmentStatus = 'REVIEW'
            THEN 1 END) > 0
            THEN 'CONFIGURATION REVIEW REQUIRED'

        WHEN COUNT(CASE
            WHEN AssessmentStatus IN
                ('UNKNOWN', 'NOT AVAILABLE')
            THEN 1 END) > 0
            THEN 'ASSESSMENT PARTIALLY INCOMPLETE'

        ELSE 'NO BASIC CONFIGURATION EXCEPTIONS DETECTED'

    END AS OverallConfigurationAssessment

FROM @Findings;

GO
