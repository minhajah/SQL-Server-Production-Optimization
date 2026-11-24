/*
============================================================
Project : SQL Server Production Optimization
Module  : 02 - Server Configuration
Script  : 08-HTML-Configuration-Report.sql
Purpose : Generate standalone HTML configuration assessment
Type    : Read-Only Assessment (table variable only)
Impact  : Low - dependent on plan cache size
============================================================
*/
USE master;
GO
SET NOCOUNT ON;

------------------------------------------------------------
-- SECTION 1: Pre-execution Validation
------------------------------------------------------------
-- Target: SQL Server 2017 or later, Windows Database Engine.
-- Conservative pilot requirement: an existing sysadmin DBA session.
-- Do not grant additional privileges solely to run this report.
IF ISNULL(TRY_CONVERT(int, SERVERPROPERTY('ProductMajorVersion')), 0) < 14
    THROW 50001, 'This report requires SQL Server 2017 or later.', 1;

IF ISNULL(CONVERT(int, SERVERPROPERTY('EngineEdition')), 0) NOT IN (2, 3, 4)
    THROW 50002, 'This report targets SQL Server Database Engine, not Azure SQL or other engines.', 1;

IF ISNULL(IS_SRVROLEMEMBER('sysadmin'), 0) <> 1
    THROW 50003, 'Pilot report requires an existing sysadmin session for complete metadata visibility.', 1;

BEGIN TRY

------------------------------------------------------------
-- SECTION 2: Assessment Variables and Session Data
------------------------------------------------------------
DECLARE @CaptureDate datetime2 = SYSDATETIME();
DECLARE @Findings TABLE (AssessmentID varchar(20),
    Category varchar(50),
    AssessmentName nvarchar(150),
    CurrentValue nvarchar(300),
    PreferredBaseline nvarchar(300),
    Priority varchar(20),
    AssessmentStatus varchar(30),
    RecommendedAction nvarchar(1000));
DECLARE @RAM bigint,
    @Available bigint,
    @MaxMem bigint,
    @MinMem bigint,
    @OSLow int,
    @ProcLow int,
    @Grants int,
    @CPU int,
    @Nodes int,
    @MinCPU int,
    @MaxCPU int,
    @DOP int,
    @Guide int,
    @Files int,
    @Expected int,
    @Sizes int,
    @Growth int,
    @Percent int,
    @Disabled int,
    @Logs int,
    @SA int,
    @Trust int,
    @Chain int,
    @Mismatch int,
    @IFI nvarchar(1),
    @AdHoc int,
    @Cache bigint,
    @Single bigint,
    @Share decimal(10,
    2);

------------------------------------------------------------
-- SECTION 3: Server Configuration
------------------------------------------------------------

SELECT @Mismatch=COUNT(*) FROM sys.configurations WHERE value<>value_in_use;
INSERT @Findings VALUES ('CFG-001',
    'Server Configuration',
    'Configured vs Running Values',
    CONVERT(nvarchar(30),
    @Mismatch),
    'No unexplained mismatches',
    CASE WHEN @Mismatch>0 THEN 'MEDIUM' ELSE 'INFO' END,
    CASE WHEN @Mismatch>0 THEN 'REVIEW' ELSE 'PASS' END,
    'Investigate mismatches before applying RECONFIGURE or scheduling a restart.');

------------------------------------------------------------
-- SECTION 4: Memory Configuration
------------------------------------------------------------

SELECT @RAM=total_physical_memory_kb/1024,
    @Available=available_physical_memory_kb/1024,
    @OSLow=system_low_memory_signal_state
    FROM sys.dm_os_sys_memory;
SELECT @ProcLow=CASE WHEN process_physical_memory_low=1 OR process_virtual_memory_low=1 THEN 1 ELSE 0 END FROM sys.dm_os_process_memory;
SELECT @MaxMem=MAX(CASE WHEN name='max server memory (MB)' THEN CONVERT(bigint,
    value_in_use) END),
    @MinMem=MAX(CASE WHEN name='min server memory (MB)' THEN CONVERT(bigint,
    value_in_use) END)
    FROM sys.configurations;
SELECT @Grants=COUNT(*) FROM sys.dm_exec_query_memory_grants WHERE grant_time IS NULL;
INSERT @Findings VALUES
('MEM-001',
    'Memory',
    'Maximum Server Memory',
    CONCAT(@MaxMem,
    ' MB / ',
    @RAM,
    ' MB RAM'),
    'Workload-based memory limit with OS headroom',
    CASE WHEN @MaxMem IS NULL OR @RAM IS NULL THEN 'MEDIUM' WHEN @MaxMem>=@RAM THEN 'HIGH' ELSE 'INFO' END,
    CASE WHEN @MaxMem IS NULL OR @RAM IS NULL THEN 'UNKNOWN' WHEN @MaxMem=2147483647 OR @MaxMem>=@RAM THEN 'REVIEW' ELSE 'OBSERVE' END,
    'Review OS requirements, other instances, agents and allocations outside the cap.'),
    
('MEM-002',
    'Memory',
    'Minimum Server Memory',
    CONCAT(@MinMem,
    ' MB'),
    'Based on workload',
    CASE WHEN @MinMem>0 THEN 'MEDIUM' ELSE 'INFO' END,
    CASE WHEN @MinMem IS NULL THEN 'UNKNOWN' WHEN @MinMem>0 THEN 'REVIEW' ELSE 'PASS' END,
    'Validate minimum memory requirements.'),
    
('MEM-003',
    'Memory',
    'Operating System Memory Pressure',
    CONCAT('Available RAM: ',
    @Available,
    ' MB; low signal: ',
    @OSLow),
    'No active low memory signal',
    CASE WHEN @OSLow=1 THEN 'HIGH' ELSE 'INFO' END,
    CASE WHEN @OSLow IS NULL THEN 'UNKNOWN' WHEN @OSLow=1 THEN 'REVIEW' ELSE 'PASS' END,
    'Investigate sustained OS memory pressure.'),
    
('MEM-004',
    'Memory',
    'SQL Server Process Memory Pressure',
    CONVERT(nvarchar(30),
    @ProcLow),
    'No active process low memory signal',
    CASE WHEN @ProcLow=1 THEN 'HIGH' ELSE 'INFO' END,
    CASE WHEN @ProcLow IS NULL THEN 'UNKNOWN' WHEN @ProcLow=1 THEN 'REVIEW' ELSE 'PASS' END,
    'Investigate SQL Server process memory pressure.'),
    
('MEM-005',
    'Memory',
    'Pending Memory Grants',
    CONVERT(nvarchar(30),
    @Grants),
    'No persistent pending grants',
    CASE WHEN @Grants>0 THEN 'HIGH' ELSE 'INFO' END,
    CASE WHEN @Grants IS NULL THEN 'UNKNOWN' WHEN @Grants>0 THEN 'REVIEW' ELSE 'PASS' END,
    'Investigate memory-intensive queries if pending grants persist.');

------------------------------------------------------------
-- SECTION 5: CPU and MAXDOP Configuration
------------------------------------------------------------

;WITH N AS (SELECT parent_node_id,COUNT(*) AS C FROM sys.dm_os_schedulers WHERE status='VISIBLE ONLINE' GROUP BY parent_node_id)
SELECT @Nodes=COUNT(*),@CPU=SUM(C),@MinCPU=MIN(C),@MaxCPU=MAX(C) FROM N;
SET @Guide=CASE WHEN @Nodes=0 THEN NULL WHEN @Nodes=1 AND @MinCPU<=8 THEN @MinCPU WHEN @Nodes=1 THEN 8 WHEN @MinCPU<=16 THEN @MinCPU WHEN @MinCPU/2>16 THEN 16 ELSE @MinCPU/2 END;
SELECT @DOP=CONVERT(int,value_in_use) FROM sys.configurations WHERE name='max degree of parallelism';
INSERT @Findings VALUES ('CPU-001',
    'Parallelism',
    'Maximum Degree of Parallelism',
    CONVERT(nvarchar(30),
    @DOP),
    CONCAT('Topology guideline: ',
    @Guide),
    CASE WHEN @DOP=0 OR @DOP>@Guide OR @MinCPU<>@MaxCPU THEN 'MEDIUM' ELSE 'INFO' END,
    CASE WHEN @Guide IS NULL OR @DOP IS NULL THEN 'UNKNOWN' WHEN @DOP=0 OR @DOP>@Guide OR @MinCPU<>@MaxCPU THEN 'REVIEW' ELSE 'OBSERVE' END,
    'Validate MAXDOP against workload, NUMA topology, database overrides and query performance.');

------------------------------------------------------------
-- SECTION 6: TempDB Configuration
------------------------------------------------------------

SELECT @Files=COUNT(*),
    @Sizes=COUNT(DISTINCT size),
    @Growth=COUNT(DISTINCT growth),
    @Percent=COUNT(CASE WHEN is_percent_growth=1 THEN 1 END),
    @Disabled=COUNT(CASE WHEN growth=0 THEN 1 END)
    FROM tempdb.sys.database_files
    WHERE type=0;
SELECT @Logs=COUNT(*) FROM tempdb.sys.database_files WHERE type=1;
SET @Expected=CASE WHEN @CPU IS NULL OR @CPU=0 THEN NULL WHEN @CPU<=8 THEN @CPU ELSE 8 END;
INSERT @Findings VALUES
('TMP-001',
    'TempDB',
    'Data File Count',
    CONVERT(nvarchar(30),
    @Files),
    CONCAT('Initial guideline: ',
    @Expected),
    CASE WHEN @Files<>@Expected THEN 'MEDIUM' ELSE 'INFO' END,
    CASE WHEN @Expected IS NULL OR @Files=0 THEN 'UNKNOWN' WHEN @Files<>@Expected THEN 'REVIEW' ELSE 'PASS' END,
    'Assess allocation contention before adding or removing files.'),
    
('TMP-002',
    'TempDB',
    'Data File Size Consistency',
    CONCAT(@Sizes,
    ' distinct sizes'),
    'Equally sized data files',
    CASE WHEN @Sizes>1 THEN 'MEDIUM' ELSE 'INFO' END,
    CASE WHEN @Files=0 THEN 'UNKNOWN' WHEN @Sizes>1 THEN 'REVIEW' ELSE 'PASS' END,
    'Review startup and current file sizes.'),
    
('TMP-003',
    'TempDB',
    'Data File Growth Configuration',
    CONCAT(@Growth,
    ' growth values; ',
    @Percent,
    ' percentage-based; ',
    @Disabled,
    ' disabled'),
    'Consistent fixed growth where appropriate',
    CASE WHEN @Growth>1 OR @Percent>0 OR @Disabled>0 THEN 'MEDIUM' ELSE 'INFO' END,
    CASE WHEN @Files=0 THEN 'UNKNOWN' WHEN @Growth>1 OR @Percent>0 OR @Disabled>0 THEN 'REVIEW' ELSE 'PASS' END,
    'Review growth increments, workload and disk capacity.'),
    
('TMP-004',
    'TempDB',
    'Transaction Log File Count',
    CONVERT(nvarchar(30),
    @Logs),
    'One log file under normal circumstances',
    CASE WHEN @Logs>1 THEN 'MEDIUM' ELSE 'INFO' END,
    CASE WHEN @Logs=0 THEN 'UNKNOWN' WHEN @Logs>1 THEN 'REVIEW' ELSE 'PASS' END,
    'Review the reason for multiple log files.');

------------------------------------------------------------
-- SECTION 7: Security Configuration
------------------------------------------------------------

SELECT @SA=1-CONVERT(int,is_disabled) FROM sys.sql_logins WHERE sid=0x01;
SELECT @Trust=COUNT(CASE WHEN is_trustworthy_on=1 THEN 1 END),
    @Chain=COUNT(CASE WHEN is_db_chaining_on=1 THEN 1 END)
    FROM sys.databases
    WHERE database_id>4 AND source_database_id IS NULL;
INSERT @Findings VALUES
('SEC-001',
    'Security',
    'Built-in SA Account',
    CASE @SA WHEN 1 THEN 'Enabled' WHEN 0 THEN 'Disabled' ELSE 'Unknown' END,
    'Disabled where feasible',
    CASE WHEN @SA=1 THEN 'HIGH' ELSE 'INFO' END,
    CASE WHEN @SA IS NULL THEN 'UNKNOWN' WHEN @SA=1 THEN 'REVIEW' ELSE 'PASS' END,
    'Verify dependencies before disabling the built-in administrator login.'),
    
('SEC-002',
    'Security',
    'TRUSTWORTHY Databases',
    CONVERT(nvarchar(30),
    @Trust),
    'Disabled unless justified',
    CASE WHEN @Trust>0 THEN 'HIGH' ELSE 'INFO' END,
    CASE WHEN @Trust>0 THEN 'REVIEW' ELSE 'PASS' END,
    'Review databases using TRUSTWORTHY.'),
    
('SEC-003',
    'Security',
    'Database Ownership Chaining',
    CONVERT(nvarchar(30),
    @Chain),
    'Disabled unless justified',
    CASE WHEN @Chain>0 THEN 'HIGH' ELSE 'INFO' END,
    CASE WHEN @Chain>0 THEN 'REVIEW' ELSE 'PASS' END,
    'Validate cross-database security dependencies.'),
    
('SEC-004',
    'Security',
    'Authentication Mode',
    CASE SERVERPROPERTY('IsIntegratedSecurityOnly') WHEN 1 THEN 'Windows Authentication' WHEN 0 THEN 'Mixed Mode' ELSE 'Unknown' END,
    'Windows Authentication where feasible',
    'INFO',
    CASE SERVERPROPERTY('IsIntegratedSecurityOnly') WHEN 1 THEN 'PASS' WHEN 0 THEN 'OBSERVE' ELSE 'UNKNOWN' END,
    'Validate authentication against application requirements.');

------------------------------------------------------------
-- SECTION 8: Instance-Level Configuration Rules
------------------------------------------------------------

INSERT @Findings
SELECT R.ID,
    R.Category,
    R.Name,
    COALESCE(CONVERT(nvarchar(30),
    C.value_in_use),
    'Unavailable'),
    R.Baseline,
    CASE WHEN CONVERT(int,
    C.value_in_use)=R.ReviewValue THEN R.Priority ELSE 'INFO' END,
    CASE WHEN C.name IS NULL THEN 'NOT AVAILABLE' WHEN CONVERT(int,
    C.value_in_use)=R.ReviewValue THEN 'REVIEW' ELSE 'OBSERVE' END,
    R.Action
FROM (VALUES
('CPU-002','Parallelism','cost threshold for parallelism',5,'MEDIUM','Workload-based threshold','Evaluate query cost and parallelism patterns.'),
('SEC-005','Security','xp_cmdshell',1,'HIGH','Disabled unless approved','Verify business and security requirements.'),
('SEC-006','Security','Ole Automation Procedures',1,'HIGH','Disabled unless approved','Review application dependencies.'),
('SEC-007','Security','Ad Hoc Distributed Queries',1,'HIGH','Disabled unless approved','Review external data access requirements.'),
('SEC-008','Security','cross db ownership chaining',1,'HIGH','Disabled unless approved','Review instance-wide ownership chaining.'),
('SEC-009','Security','clr strict security',0,'HIGH','Enabled where supported','Review CLR security and application dependencies.'),
('SEC-010','Security','clr enabled',1,'MEDIUM','Based on application requirements','Validate CLR usage before changes.'),
('ADV-001','Advanced Configuration','priority boost',1,'HIGH','Disabled','Review unnecessary tuning.'),
('ADV-002','Advanced Configuration','lightweight pooling',1,'HIGH','Disabled','Review fiber-mode configuration.'),
('ADV-003',
    'Advanced Configuration',
    'backup compression default',
    0,
    'MEDIUM',
    'Based on backup strategy',
    'Verify actual backup compression behavior.'),
    
('ADV-004','Advanced Configuration','backup checksum default',0,'MEDIUM','Based on backup strategy','Verify checksum usage in actual backups.'),
('ADV-005',
    'Advanced Configuration',
    'blocked process threshold (s)',
    0,
    'MEDIUM',
    'Based on monitoring requirements',
    'Verify existing blocking monitoring coverage.')
) R(ID,Category,Name,ReviewValue,Priority,Baseline,Action) LEFT JOIN sys.configurations C ON C.name=R.Name;

------------------------------------------------------------
-- SECTION 9: Additional Advanced Configuration
------------------------------------------------------------

INSERT @Findings SELECT CASE name WHEN 'max worker threads' THEN 'ADV-006' WHEN 'query governor cost limit' THEN 'ADV-007' WHEN 'recovery interval (min)' THEN 'ADV-008' WHEN 'user connections' THEN 'ADV-009' END,
    'Advanced Configuration',
    name,
    CONVERT(nvarchar(30),
    value_in_use),
    'Default automatic or unrestricted setting',
    CASE WHEN CONVERT(int,
    value_in_use)<>0 THEN 'MEDIUM' ELSE 'INFO' END,
    CASE WHEN CONVERT(int,
    value_in_use)<>0 THEN 'REVIEW' ELSE 'PASS' END,
    'Validate non-default settings against documented requirements.'
    FROM sys.configurations
    WHERE name IN ('max worker threads',
    'query governor cost limit',
    'recovery interval (min)',
    'user connections');

------------------------------------------------------------
-- SECTION 10: Instant File Initialization
------------------------------------------------------------

SELECT @IFI=instant_file_initialization_enabled FROM sys.dm_server_services WHERE process_id=CONVERT(int,SERVERPROPERTY('ProcessID'));
INSERT @Findings VALUES ('ADV-010',
    'Advanced Configuration',
    'Instant File Initialization',
    CASE @IFI WHEN 'Y' THEN 'Enabled' WHEN 'N' THEN 'Disabled' ELSE 'Unknown' END,
    'Enabled where security requirements permit',
    CASE WHEN @IFI='N' THEN 'MEDIUM' ELSE 'INFO' END,
    CASE @IFI WHEN 'Y' THEN 'PASS' WHEN 'N' THEN 'REVIEW' ELSE 'UNKNOWN' END,
    'Review file allocation performance and security requirements.');

------------------------------------------------------------
-- SECTION 11: Plan Cache Assessment
------------------------------------------------------------

SELECT @AdHoc=CONVERT(int,value_in_use) FROM sys.configurations WHERE name='optimize for ad hoc workloads';
SELECT @Cache=COALESCE(SUM(CONVERT(bigint,
    size_in_bytes)),
    0),
    @Single=COALESCE(SUM(CASE WHEN objtype='Adhoc' AND cacheobjtype='Compiled Plan' AND usecounts=1 THEN CONVERT(bigint,
    size_in_bytes) ELSE 0 END),
    0)
    FROM sys.dm_exec_cached_plans;
SET @Share=@Single*100.0/NULLIF(@Cache,0);
INSERT @Findings VALUES ('ADV-011',
    'Advanced Configuration',
    'Optimize for Ad Hoc Workloads',
    CONCAT('Setting: ',
    @AdHoc,
    '; Single-use cache: ',
    @Share,
    '%'),
    'Based on plan cache efficiency',
    CASE WHEN @AdHoc=0 AND @Share>=25 THEN 'MEDIUM' ELSE 'INFO' END,
    CASE WHEN @AdHoc IS NULL OR @Share IS NULL THEN 'UNKNOWN' WHEN @AdHoc=0 AND @Share>=25 THEN 'REVIEW' ELSE 'OBSERVE' END,
    'Review single-use ad hoc plan memory consumption before changes.');

------------------------------------------------------------
-- SECTION 12: HTML Report Variables and Summary
------------------------------------------------------------


DECLARE @HTML nvarchar(max),
    @CategoryRows nvarchar(max),
    @FindingRows nvarchar(max),
    @AllRows nvarchar(max),
    @Total int,
    @Pass int,
    @Review int,
    @Observe int,
    @Unknown int,
    @High int,
    @Medium int,
    @Status nvarchar(100),
    @Color varchar(20),
    @Server nvarchar(max),
    @Edition nvarchar(max),
    @Version nvarchar(max),
    @CU nvarchar(max);
SELECT @Total=COUNT(*),
    @Pass=COUNT(CASE WHEN AssessmentStatus='PASS' THEN 1 END),
    @Review=COUNT(CASE WHEN AssessmentStatus='REVIEW' THEN 1 END),
    @Observe=COUNT(CASE WHEN AssessmentStatus='OBSERVE' THEN 1 END),
    @Unknown=COUNT(CASE WHEN AssessmentStatus IN ('UNKNOWN',
    'NOT AVAILABLE') THEN 1 END),
    @High=COUNT(CASE WHEN AssessmentStatus='REVIEW' AND Priority='HIGH' THEN 1 END),
    @Medium=COUNT(CASE WHEN AssessmentStatus='REVIEW' AND Priority='MEDIUM' THEN 1 END)
    FROM @Findings;
SET @Status=CASE WHEN @Total=0 THEN 'NO ASSESSMENT DATA' WHEN @High>0 THEN 'HIGH PRIORITY REVIEW REQUIRED' WHEN @Review>0 THEN 'CONFIGURATION REVIEW REQUIRED' WHEN @Unknown>0 THEN 'ASSESSMENT PARTIALLY INCOMPLETE' ELSE 'NO BASIC CONFIGURATION EXCEPTIONS DETECTED' END;
SET @Color=CASE WHEN @High>0 THEN '#C00000' WHEN @Review>0 THEN '#D97706' WHEN @Unknown>0 OR @Total=0 THEN '#64748B' ELSE '#15803D' END;

------------------------------------------------------------
-- SECTION 13: Server Information
------------------------------------------------------------

SET @Server=(SELECT COALESCE(CONVERT(nvarchar(256),@@SERVERNAME),'Unknown') AS [text()] FOR XML PATH(''));
SET @Edition=(SELECT COALESCE(CONVERT(nvarchar(256),SERVERPROPERTY('Edition')),'Unknown') AS [text()] FOR XML PATH(''));
SET @Version=(SELECT COALESCE(CONVERT(nvarchar(100),SERVERPROPERTY('ProductVersion')),'Unknown') AS [text()] FOR XML PATH(''));
SET @CU=(SELECT COALESCE(CONVERT(nvarchar(100),SERVERPROPERTY('ProductUpdateLevel')),'N/A') AS [text()] FOR XML PATH(''));

------------------------------------------------------------
-- SECTION 14: Category Summary
------------------------------------------------------------

SET @CategoryRows=CONVERT(nvarchar(max),
    (SELECT Category AS [td],
    '',
    COUNT(*) AS [td],
    '',
    COUNT(CASE WHEN AssessmentStatus='PASS' THEN 1 END) AS [td],
    '',
    COUNT(CASE WHEN AssessmentStatus='REVIEW' THEN 1 END) AS [td],
    '',
    COUNT(CASE WHEN AssessmentStatus='OBSERVE' THEN 1 END) AS [td],
    '',
    COUNT(CASE WHEN AssessmentStatus IN ('UNKNOWN',
    'NOT AVAILABLE') THEN 1 END) AS [td],
    '',
    COUNT(CASE WHEN AssessmentStatus='REVIEW' AND Priority='HIGH' THEN 1 END) AS [td]
    FROM @Findings
    GROUP BY Category
    ORDER BY Category FOR XML PATH('tr'),
    TYPE));

------------------------------------------------------------
-- SECTION 15: Actionable Findings
------------------------------------------------------------

SET @FindingRows=CONVERT(nvarchar(max),
    (SELECT AssessmentID AS [td],
    '',
    Category AS [td],
    '',
    AssessmentName AS [td],
    '',
    COALESCE(CurrentValue,
    'Unknown') AS [td],
    '',
    PreferredBaseline AS [td],
    '',
    Priority AS [td],
    '',
    RecommendedAction AS [td]
    FROM @Findings
    WHERE AssessmentStatus='REVIEW'
    ORDER BY CASE Priority WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END,
    AssessmentID FOR XML PATH('tr'),
    TYPE));
IF @Review=0 SET @FindingRows=N'<tr>
<td colspan="7">No actionable configuration exceptions detected.</td>
</tr>';

------------------------------------------------------------
-- SECTION 16: Complete Assessment
------------------------------------------------------------

SET @AllRows=CONVERT(nvarchar(max),
    (SELECT AssessmentID AS [td],
    '',
    Category AS [td],
    '',
    AssessmentName AS [td],
    '',
    COALESCE(CurrentValue,
    'Unknown') AS [td],
    '',
    PreferredBaseline AS [td],
    '',
    Priority AS [td],
    '',
    AssessmentStatus AS [td]
    FROM @Findings
    ORDER BY Category,
    AssessmentID FOR XML PATH('tr'),
    TYPE));

------------------------------------------------------------
-- SECTION 17: Generate HTML Report
------------------------------------------------------------

SET @HTML=CONCAT(CAST(N'<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<title>SQL Server Configuration Assessment</title>
<style>body{font-family:Arial,sans-serif;font-size:13px;color:#333;margin:25px;background:#fff}.header{background:#17365D;color:white;padding:20px}h2{background:#E8EEF5;color:#17365D;padding:10px;font-size:16px}table{width:100%;border-collapse:collapse;margin-bottom:20px}th{background:#305496;color:white;padding:9px;text-align:left}td{border:1px solid #ddd;padding:8px;vertical-align:top}tr:nth-child(even){background:#F5F7FA}.summary{text-align:center}.summary b{font-size:26px}.footer{color:#777;font-size:11px;border-top:1px solid #ddd;padding:12px}</style>
</head>
<body>
<div class="header">
<h1>SQL Server Configuration Assessment</h1>
<p>Server: ' AS nvarchar(max)),
    @Server,
    N'</p>
<p>Generated: ',
    CONVERT(nvarchar(30),
    @CaptureDate,
    120),
    N'</p>
</div>
<h2>Overall Configuration Status</h2>
<p style="font-size:18px;font-weight:bold;color:',
    @Color,
    N';">',
    @Status,
    N'</p>
<h2>01. Server Information</h2>
<table>
<tr>
<th>Parameter</th>
<th>Value</th>
</tr>
<tr>
<td>SQL Server Name</td>
<td>',
    @Server,
    N'</td>
</tr>
<tr>
<td>Edition</td>
<td>',
    @Edition,
    N'</td>
</tr>
<tr>
<td>Version</td>
<td>',
    @Version,
    N'</td>
</tr>
<tr>
<td>CU Level</td>
<td>',
    @CU,
    N'</td>
</tr>
<tr>
<td>Physical RAM (MB)</td>
<td>',
    COALESCE(CONVERT(nvarchar(30),
    @RAM),
    'Unknown'),
    N'</td>
</tr>
<tr>
<td>Online Logical CPUs</td>
<td>',
    COALESCE(CONVERT(nvarchar(30),
    @CPU),
    'Unknown'),
    N'</td>
</tr>
</table>
<h2>02. Assessment Summary</h2>
<table class="summary">
<tr>
<td>Total Checks<br>
<b>',
    @Total,
    N'</b>
</td>
<td>Passed<br>
<b style="color:#15803D">',
    @Pass,
    N'</b>
</td>
<td>Review Required<br>
<b style="color:#D97706">',
    @Review,
    N'</b>
</td>
</tr>
<tr>
<td>High Priority<br>
<b style="color:#C00000">',
    @High,
    N'</b>
</td>
<td>Medium Priority<br>
<b style="color:#D97706">',
    @Medium,
    N'</b>
</td>
<td>Observations<br>
<b>',
    @Observe,
    N'</b>
</td>
</tr>
<tr>
<td colspan="3">Unavailable / Unknown Checks: ',
    @Unknown,
    N'</td>
</tr>
</table>
<h2>03. Assessment by Category</h2>
<table>
<tr>
<th>Category</th>
<th>Total</th>
<th>Passed</th>
<th>Review</th>
<th>Observe</th>
<th>Unavailable</th>
<th>High Priority</th>
</tr>',
    @CategoryRows,
    N'</table>
<h2>04. Actionable Findings &amp; Recommendations</h2>
<p>Validate workload, dependencies and business requirements before implementing changes.</p>
<table>
<tr>
<th>ID</th>
<th>Category</th>
<th>Assessment</th>
<th>Current Value</th>
<th>Preferred Baseline</th>
<th>Priority</th>
<th>Recommended Action</th>
</tr>',
    @FindingRows,
    N'</table>
<h2>05. Complete Configuration Assessment</h2>
<table>
<tr>
<th>ID</th>
<th>Category</th>
<th>Assessment</th>
<th>Current Value</th>
<th>Preferred Baseline</th>
<th>Priority</th>
<th>Status</th>
</tr>',
    @AllRows,
    N'</table>
<h2>06. Assessment Status Definitions</h2>
<table>
<tr>
<th>Status</th>
<th>Description</th>
</tr>
<tr>
<td>PASS</td>
<td>Meets the particular baseline.</td>
</tr>
<tr>
<td>REVIEW</td>
<td>Requires investigation.</td>
</tr>
<tr>
<td>OBSERVE</td>
<td>Requires workload validation.</td>
</tr>
<tr>
<td>UNKNOWN</td>
<td>Insufficient information.</td>
</tr>
<tr>
<td>NOT AVAILABLE</td>
<td>Setting unavailable or unsupported.</td>
</tr>
</table>
<h2>07. Production Safety &amp; Limitations</h2>
<p>No permanent objects, configuration changes or email delivery. Selected checks only; point-in-time observations and metadata visibility limitations apply. SQL Server 2017+ Windows pilot; existing sysadmin session required. Compare findings with Script 07; small unknown-data handling improvements may affect counts. The 25% plan cache threshold is an internal review guideline. This is not a complete health or security assessment.</p>
<div class="footer">SQL Server Production Optimization Framework<br>Module 02 - SQL Server Configuration Assessment</div>
</body>
</html>');

------------------------------------------------------------
-- SECTION 18: Return HTML Report
------------------------------------------------------------

IF @HTML IS NULL OR LEN(@HTML) = 0
    THROW 50004, 'HTML report generation returned no data.', 1;

SELECT @HTML AS HTMLReport;

END TRY
BEGIN CATCH
    -- Fail closed: do not return a misleading partial success report.
    THROW;
END CATCH;
GO
