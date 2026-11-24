/*
============================================================
Project : SQL Server Production Optimization
Module  : 01 - Server Inventory
Script  : 08-HTML-Inventory-Report.sql
Purpose : Generate HTML server inventory report
Type    : Read-Only Assessment
============================================================
*/

USE master;
GO

SET NOCOUNT ON;

DECLARE
    @HTML NVARCHAR(MAX),
    @ServerName NVARCHAR(256),
    @Edition NVARCHAR(256),
    @Version NVARCHAR(100),
    @CULevel NVARCHAR(100),
    @CPU INT,
    @RAM DECIMAL(18,2),
    @Uptime DECIMAL(18,2),
    @TotalDB INT,
    @OnlineDB INT,
    @OfflineDB INT,
    @DBSize DECIMAL(18,2),
    @TotalJobs INT,
    @EnabledJobs INT,
    @DisabledJobs INT,
    @FailedJobs INT,
    @TotalServices INT,
    @RunningServices INT,
    @StoppedAuto INT,
    @WarningVolumes INT,
    @CriticalVolumes INT,
    @UnknownVolumes INT,
    @HAStatus NVARCHAR(100),
    @OverallStatus NVARCHAR(100),
    @StatusColor NVARCHAR(20),
    @DiskRows NVARCHAR(MAX),
    @ReportDate DATETIME = GETDATE();

------------------------------------------------------------
-- SECTION 1: Server Information
------------------------------------------------------------

SELECT
    @ServerName = @@SERVERNAME,
    @Edition = CONVERT(NVARCHAR(256),
        SERVERPROPERTY('Edition')),
    @Version = CONVERT(NVARCHAR(100),
        SERVERPROPERTY('ProductVersion')),
    @CULevel = ISNULL(CONVERT(NVARCHAR(100),
        SERVERPROPERTY('ProductUpdateLevel')), 'N/A');

SELECT
    @CPU = cpu_count,
    @RAM = physical_memory_kb / 1048576.0,
    @Uptime = DATEDIFF_BIG(
        SECOND, sqlserver_start_time,
        @ReportDate) / 86400.0
FROM sys.dm_os_sys_info;

------------------------------------------------------------
-- SECTION 2: Database Information
------------------------------------------------------------

SELECT
    @TotalDB = COUNT(*),
    @OnlineDB = COUNT(CASE
        WHEN state_desc = 'ONLINE' THEN 1 END),
    @OfflineDB = COUNT(CASE
        WHEN state_desc <> 'ONLINE' THEN 1 END)
FROM sys.databases
WHERE database_id > 4;

SELECT
    @DBSize = COALESCE(SUM(CAST(size AS BIGINT)), 0)
        / 131072.0
FROM sys.master_files
WHERE database_id > 4
AND type IN (0,1);

------------------------------------------------------------
-- SECTION 3: Storage Information
------------------------------------------------------------

DECLARE @Volumes TABLE
(
    Drive NVARCHAR(512),
    TotalGB DECIMAL(18,2),
    FreeGB DECIMAL(18,2),
    FreePercent DECIMAL(10,2),
    HealthStatus NVARCHAR(20)
);

INSERT INTO @Volumes
SELECT
    VS.volume_mount_point,

    MAX(VS.total_bytes) / 1073741824.0,

    MIN(VS.available_bytes) / 1073741824.0,

    MIN(VS.available_bytes * 100.0 /
        NULLIF(VS.total_bytes, 0)),

    CASE
        WHEN MIN(VS.available_bytes * 100.0 /
             NULLIF(VS.total_bytes, 0)) IS NULL
            THEN 'UNKNOWN'
        WHEN MIN(VS.available_bytes * 100.0 /
             NULLIF(VS.total_bytes, 0)) < 10
            THEN 'CRITICAL'
        WHEN MIN(VS.available_bytes * 100.0 /
             NULLIF(VS.total_bytes, 0)) < 20
            THEN 'WARNING'
        ELSE 'HEALTHY'
    END

FROM sys.master_files AS MF
CROSS APPLY sys.dm_os_volume_stats
(
    MF.database_id,
    MF.file_id
) AS VS
GROUP BY VS.volume_mount_point;

SELECT
    @WarningVolumes = COUNT(CASE
        WHEN HealthStatus = 'WARNING' THEN 1 END),
    @CriticalVolumes = COUNT(CASE
        WHEN HealthStatus = 'CRITICAL' THEN 1 END),
    @UnknownVolumes = COUNT(CASE
        WHEN HealthStatus = 'UNKNOWN' THEN 1 END)
FROM @Volumes;

------------------------------------------------------------
-- SECTION 4: HA/DR Information
------------------------------------------------------------

SET @HAStatus =
    CASE
        WHEN SERVERPROPERTY('IsHadrEnabled') = 1
            THEN 'AG Enabled - Health Not Yet Assessed'
        WHEN SERVERPROPERTY('IsClustered') = 1
            THEN 'Failover Cluster Instance'
        ELSE 'Standalone - AG Not Applicable'
    END;

------------------------------------------------------------
-- SECTION 5: SQL Agent Information
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
-- SECTION 6: SQL Server Services
------------------------------------------------------------

SELECT
    @TotalServices = COUNT(*),
    @RunningServices = COUNT(CASE
        WHEN status_desc = 'Running' THEN 1 END),
    @StoppedAuto = COUNT(CASE
        WHEN status_desc = 'Stopped'
         AND startup_type_desc = 'Automatic'
        THEN 1 END)
FROM sys.dm_server_services;

------------------------------------------------------------
-- SECTION 7: Overall Inventory Status
------------------------------------------------------------

SET @OverallStatus =
    CASE
        WHEN @CriticalVolumes > 0
            THEN 'CRITICAL - STORAGE'
        WHEN @OfflineDB > 0
          OR @WarningVolumes > 0
          OR @FailedJobs > 0
          OR @StoppedAuto > 0
            THEN 'REVIEW REQUIRED'
        WHEN @UnknownVolumes > 0
          OR NOT EXISTS (SELECT 1 FROM @Volumes)
            THEN 'INCOMPLETE DATA'
        ELSE 'NO INVENTORY EXCEPTIONS DETECTED'
    END;

SET @StatusColor =
    CASE
        WHEN @OverallStatus = 'CRITICAL - STORAGE'
            THEN '#C00000'
        WHEN @OverallStatus = 'REVIEW REQUIRED'
            THEN '#D97706'
        WHEN @OverallStatus = 'INCOMPLETE DATA'
            THEN '#64748B'
        ELSE '#15803D'
    END;

------------------------------------------------------------
-- SECTION 8: Generate Storage HTML Rows
------------------------------------------------------------

SET @DiskRows = CAST(
(
    SELECT
        ISNULL(Drive, 'Unknown') AS 'td', '',
        ISNULL(CONVERT(NVARCHAR(30), TotalGB), 'N/A')
            AS 'td', '',
        ISNULL(CONVERT(NVARCHAR(30), FreeGB), 'N/A')
            AS 'td', '',
        ISNULL(CONVERT(NVARCHAR(30), FreePercent), 'N/A')
            AS 'td', '',
        HealthStatus AS 'td'
    FROM @Volumes
    ORDER BY Drive
    FOR XML PATH('tr'), TYPE
) AS NVARCHAR(MAX));

------------------------------------------------------------
-- SECTION 9: Generate HTML Report
------------------------------------------------------------

SET @HTML = N'
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<title>SQL Server Inventory Report</title>

<style>
body {
    font-family: Arial, sans-serif;
    font-size: 13px;
    color: #333333;
    margin: 25px;
}
.header {
    background-color: #17365D;
    color: white;
    padding: 20px;
}
h2 {
    background-color: #E8EEF5;
    padding: 10px;
    color: #17365D;
    font-size: 16px;
}
table {
    border-collapse: collapse;
    width: 100%;
    margin-bottom: 20px;
}
th {
    background-color: #305496;
    color: white;
    padding: 9px;
    text-align: left;
}
td {
    border: 1px solid #DDDDDD;
    padding: 8px;
}
tr:nth-child(even) {
    background-color: #F5F7FA;
}
.footer {
    color: #777777;
    font-size: 11px;
    border-top: 1px solid #DDDDDD;
    padding-top: 10px;
}
</style>
</head>

<body>

<div class="header">
<h1>SQL Server Inventory Report</h1>
<p>' + REPLACE(REPLACE(REPLACE(
        ISNULL(@ServerName, 'Unknown'),
        '&', '&amp;'), '<', '&lt;'), '>', '&gt;') + N'</p>
<p>Generated: ' +
CONVERT(NVARCHAR(30), @ReportDate, 120) + N'</p>
</div>

<h2>Overall Inventory Status</h2>

<p style="font-size:18px;font-weight:bold;color:'
+ @StatusColor + N';">'
+ @OverallStatus + N'</p>

<h2>01. Server Information</h2>

<table>
<tr><th>Parameter</th><th>Value</th></tr>
<tr><td>SQL Server Edition</td><td>'
+ REPLACE(REPLACE(REPLACE(
    ISNULL(@Edition, 'Unknown'),
    '&', '&amp;'), '<', '&lt;'), '>', '&gt;') + N'</td></tr>
<tr><td>SQL Version</td><td>'
+ ISNULL(@Version, 'Unknown') + N'</td></tr>
<tr><td>CU Level</td><td>'
+ @CULevel + N'</td></tr>
<tr><td>Logical CPU Count</td><td>'
+ CONVERT(NVARCHAR(20), @CPU) + N'</td></tr>
<tr><td>Total RAM (GB)</td><td>'
+ CONVERT(NVARCHAR(20), @RAM) + N'</td></tr>
<tr><td>SQL Server Uptime (Days)</td><td>'
+ CONVERT(NVARCHAR(20), @Uptime) + N'</td></tr>
</table>

<h2>02. Database Information</h2>

<table>
<tr><th>Parameter</th><th>Value</th></tr>
<tr><td>Total User Databases</td><td>'
+ CONVERT(NVARCHAR(20), @TotalDB) + N'</td></tr>
<tr><td>Online Databases</td><td>'
+ CONVERT(NVARCHAR(20), @OnlineDB) + N'</td></tr>
<tr><td>Non-Online Databases</td><td>'
+ CONVERT(NVARCHAR(20), @OfflineDB) + N'</td></tr>
<tr><td>Allocated Database Size (GB)</td><td>'
+ CONVERT(NVARCHAR(30), @DBSize) + N'</td></tr>
</table>

<h2>03. Storage Information</h2>

<table>
<tr>
<th>Drive</th>
<th>Total GB</th>
<th>Free GB</th>
<th>Free %</th>
<th>Status</th>
</tr>'
+ ISNULL(@DiskRows, '') + N'
</table>

<h2>04. High Availability</h2>

<table>
<tr><th>Parameter</th><th>Value</th></tr>
<tr><td>HA Configuration</td><td>'
+ @HAStatus + N'</td></tr>
</table>

<h2>05. SQL Agent Information</h2>

<table>
<tr><th>Parameter</th><th>Value</th></tr>
<tr><td>Total Jobs</td><td>'
+ CONVERT(NVARCHAR(20), @TotalJobs) + N'</td></tr>
<tr><td>Enabled Jobs</td><td>'
+ CONVERT(NVARCHAR(20), @EnabledJobs) + N'</td></tr>
<tr><td>Disabled Jobs</td><td>'
+ CONVERT(NVARCHAR(20), @DisabledJobs) + N'</td></tr>
<tr><td>Failed Executions - Last 24 Hours</td><td>'
+ CONVERT(NVARCHAR(20), @FailedJobs) + N'</td></tr>
</table>

<h2>06. SQL Server Services</h2>

<table>
<tr><th>Parameter</th><th>Value</th></tr>
<tr><td>Total Services</td><td>'
+ CONVERT(NVARCHAR(20), @TotalServices) + N'</td></tr>
<tr><td>Running Services</td><td>'
+ CONVERT(NVARCHAR(20), @RunningServices) + N'</td></tr>
<tr><td>Stopped Automatic Services</td><td>'
+ CONVERT(NVARCHAR(20), @StoppedAuto) + N'</td></tr>
</table>

<div class="footer">
SQL Server Production Optimization Framework<br>
Module 01 - Server Inventory<br>
Inventory assessment only. Not a complete health report.
</div>

</body>
</html>';

------------------------------------------------------------
-- SECTION 10: Return HTML Report
------------------------------------------------------------

SELECT @HTML AS HTMLReport;

GO
