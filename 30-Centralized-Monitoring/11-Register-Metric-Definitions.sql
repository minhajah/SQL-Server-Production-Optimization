/*
============================================================
Project : SQL Server Production Optimization
Module  : 30 - Centralized Monitoring
Script  : 11-Register-Metric-Definitions.sql
Purpose : Register all Module 26 metric definitions
Type    : Central Repository Deployment
Impact  : Central DBA_Monitoring database only
Version : 1.0
============================================================
Source: Module 26 collector scripts in uploaded repository snapshot.
Run after scripts 01 through 10; no remote connections.
Deployment disabled by default. Existing definitions are not overwritten.
Catalog registration does not enable monitoring or collectors.
TMP-012 accepts MB or Percent in the collector; ingestion must handle both.
============================================================
*/
USE [DBA_Monitoring];
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON;
SET NUMERIC_ROUNDABORT OFF;

-- SECTION 1: Deployment Configuration
DECLARE @ApprovedMonitoringServer NVARCHAR(128) = N'REPLACE_WITH_APPROVED_SERVER_NAME',
        @AllowDeployment BIT = 0,
        @ActualServer NVARCHAR(128) = CONVERT(NVARCHAR(128), SERVERPROPERTY('ServerName')),
        @LockResult INT,
        @Inserted INT = 0;

-- SECTION 2: Deployment Safety Validation
IF ISNULL(@AllowDeployment, 0) <> 1
    THROW 50001, 'Deployment disabled.', 1;
IF NULLIF(LTRIM(RTRIM(@ApprovedMonitoringServer)), N'') IS NULL
   OR @ApprovedMonitoringServer = N'REPLACE_WITH_APPROVED_SERVER_NAME'
    THROW 50002, 'Approved server must be configured.', 1;
IF @ActualServer IS NULL OR @ActualServer <> @ApprovedMonitoringServer
    THROW 50003, 'Incorrect monitoring instance.', 1;
IF DB_NAME() <> N'DBA_Monitoring'
    THROW 50004, 'Incorrect database context.', 1;
IF ISNULL(TRY_CONVERT(INT, SERVERPROPERTY('ProductMajorVersion')), 0) < 15
    THROW 50005, 'SQL Server 2019 or later required.', 1;
IF ISNULL(CONVERT(NVARCHAR(60), DATABASEPROPERTYEX(DB_NAME(), 'Updateability')), N'') <> N'READ_WRITE'
    THROW 50006, 'Database must be writable.', 1;
IF @@TRANCOUNT <> 0 OR (@@OPTIONS & 2) = 2
    THROW 50007, 'Execute outside a transaction with implicit transactions disabled.', 1;
IF OBJECT_ID('dbo.Collectors', 'U') IS NULL
OR OBJECT_ID('dbo.MetricDefinitions', 'U') IS NULL
OR OBJECT_ID('dbo.MonitoringSettings', 'U') IS NULL
OR OBJECT_ID('dbo.CollectionRuns', 'U') IS NULL
OR OBJECT_ID('dbo.SchemaVersion', 'U') IS NULL
    THROW 50008, 'Repository dependencies missing.', 1;
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE VersionNumber = '1.0.6')
    THROW 50009, 'Deploy Script 10 before registering metrics.', 1;

-- SECTION 3: Source Metric Catalog
DECLARE @Catalog TABLE
(
    CollectorCode VARCHAR(30) NOT NULL,
    MetricID VARCHAR(30) NOT NULL,
    MetricName NVARCHAR(100) NOT NULL,
    Category VARCHAR(50) NOT NULL,
    ResourceType VARCHAR(30) NOT NULL,
    DefaultMetricUnit VARCHAR(30) NOT NULL,
    MetricBehavior VARCHAR(20) NOT NULL,
    StoragePolicy VARCHAR(30) NOT NULL,
    Description NVARCHAR(1000) NULL,
    PRIMARY KEY (CollectorCode, MetricID)
);
INSERT INTO @Catalog
(CollectorCode, MetricID, MetricName, Category, ResourceType,
 DefaultMetricUnit, MetricBehavior, StoragePolicy, Description)
VALUES
    (N'COL-01', N'INST-001', N'Instance Availability', N'Availability', N'Instance', N'Boolean', N'STATE', N'ON_CHANGE', N''),
    (N'COL-01', N'INST-002', N'Instance Uptime', N'Availability', N'Instance', N'Seconds', N'GAUGE', N'RAW', N''),
    (N'COL-01', N'INST-003', N'Logical CPU Count', N'CPU', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-01', N'INST-004', N'Total Physical Memory', N'Memory', N'Instance', N'MB', N'GAUGE', N'RAW', N''),
    (N'COL-01', N'INST-005', N'Collector Execution Duration', N'Collection', N'Instance', N'Milliseconds', N'GAUGE', N'RAW', N''),
    (N'COL-02', N'DB-000', N'Database Health Collection', N'Collection', N'Instance', N'Status', N'STATE', N'ON_CHANGE', N''),
    (N'COL-02', N'DB-001', N'Database State', N'Availability', N'Database', N'StateCode', N'STATE', N'ON_CHANGE', N''),
    (N'COL-02', N'DB-002', N'Database Accessibility', N'Availability', N'Database', N'Boolean', N'STATE', N'ON_CHANGE', N''),
    (N'COL-02', N'DB-003', N'Read Only Status', N'Database Configuration', N'Database', N'Boolean', N'STATE', N'ON_CHANGE', N''),
    (N'COL-02', N'DB-004', N'Recovery Model', N'Database Configuration', N'Database', N'StateCode', N'STATE', N'ON_CHANGE', N''),
    (N'COL-02', N'DB-005', N'User Access Mode', N'Availability', N'Database', N'StateCode', N'STATE', N'ON_CHANGE', N''),
    (N'COL-02', N'DB-006', N'Standby Status', N'Availability', N'Database', N'Boolean', N'STATE', N'ON_CHANGE', N''),
    (N'COL-02', N'DB-007', N'Collector Execution Duration', N'Collection', N'Instance', N'Milliseconds', N'GAUGE', N'RAW', N''),
    (N'COL-03', N'CPU-001', N'SQL Server CPU Utilization', N'CPU', N'Instance', N'Percent', N'GAUGE', N'RAW', N''),
    (N'COL-03', N'CPU-002', N'Other Processes CPU Utilization', N'CPU', N'Instance', N'Percent', N'GAUGE', N'RAW', N''),
    (N'COL-03', N'CPU-003', N'Total System CPU Utilization', N'CPU', N'Instance', N'Percent', N'GAUGE', N'RAW', N''),
    (N'COL-03', N'CPU-004', N'System Idle Percentage', N'CPU', N'Instance', N'Percent', N'GAUGE', N'RAW', N''),
    (N'COL-03', N'CPU-005', N'CPU Sample Age', N'CPU', N'Instance', N'Seconds', N'GAUGE', N'RAW', N''),
    (N'COL-03', N'CPU-006', N'Online Visible Schedulers', N'CPU', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-03', N'CPU-007', N'Runnable Tasks', N'CPU', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-03', N'CPU-008', N'Average Runnable Tasks Per Scheduler', N'CPU', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-03', N'CPU-009', N'Maximum Runnable Tasks On Scheduler', N'CPU', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-03', N'CPU-010', N'Current Workers', N'CPU', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-03', N'CPU-011', N'Active Workers', N'CPU', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-03', N'CPU-012', N'Work Queue Count', N'CPU', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-03', N'CPU-013', N'Collector Execution Duration', N'Collection', N'Instance', N'Milliseconds', N'GAUGE', N'RAW', N''),
    (N'COL-04', N'MEM-001', N'Total Physical Memory', N'Memory', N'Instance', N'MB', N'GAUGE', N'RAW', N''),
    (N'COL-04', N'MEM-002', N'Available Physical Memory', N'Memory', N'Instance', N'MB', N'GAUGE', N'RAW', N''),
    (N'COL-04', N'MEM-003', N'OS Memory Utilization', N'Memory', N'Instance', N'Percent', N'GAUGE', N'RAW', N''),
    (N'COL-04', N'MEM-004', N'SQL Server Physical Memory Usage', N'Memory', N'Instance', N'MB', N'GAUGE', N'RAW', N''),
    (N'COL-04', N'MEM-005', N'Configured Maximum Server Memory', N'Memory', N'Instance', N'MB', N'GAUGE', N'RAW', N''),
    (N'COL-04', N'MEM-006', N'Configured Minimum Server Memory', N'Memory', N'Instance', N'MB', N'GAUGE', N'RAW', N''),
    (N'COL-04', N'MEM-007', N'OS Low Memory Signal', N'Memory', N'Instance', N'Boolean', N'STATE', N'ON_CHANGE', N''),
    (N'COL-04', N'MEM-008', N'SQL Process Physical Memory Pressure', N'Memory', N'Instance', N'Boolean', N'STATE', N'ON_CHANGE', N''),
    (N'COL-04', N'MEM-009', N'SQL Process Virtual Memory Pressure', N'Memory', N'Instance', N'Boolean', N'STATE', N'ON_CHANGE', N''),
    (N'COL-04', N'MEM-010', N'Locked Page Allocations', N'Memory', N'Instance', N'MB', N'GAUGE', N'RAW', N''),
    (N'COL-04', N'MEM-011', N'Total Server Memory', N'Memory', N'Instance', N'MB', N'GAUGE', N'RAW', N''),
    (N'COL-04', N'MEM-012', N'Target Server Memory', N'Memory', N'Instance', N'MB', N'GAUGE', N'RAW', N''),
    (N'COL-04', N'MEM-013', N'Memory Grants Pending', N'Memory', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-04', N'MEM-014', N'Memory Grants Outstanding', N'Memory', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-04', N'MEM-015', N'Granted Workspace Memory', N'Memory', N'Instance', N'MB', N'GAUGE', N'RAW', N''),
    (N'COL-04', N'MEM-016', N'Page Life Expectancy', N'Memory', N'Instance', N'Seconds', N'GAUGE', N'RAW', N''),
    (N'COL-04', N'MEM-017', N'Buffer Cache Hit Ratio', N'Memory', N'Instance', N'Percent', N'GAUGE', N'RAW', N''),
    (N'COL-04', N'MEM-018', N'Free List Stalls Cumulative', N'Memory', N'Instance', N'CumulativeCount', N'COUNTER', N'DELTA', N'Source cumulative unit retained for delta storage; reporting must label delta values correctly.'),
    (N'COL-04', N'MEM-019', N'Lazy Writes Cumulative', N'Memory', N'Instance', N'CumulativeCount', N'COUNTER', N'DELTA', N'Source cumulative unit retained for delta storage; reporting must label delta values correctly.'),
    (N'COL-04', N'MEM-020', N'Collector Execution Duration', N'Collection', N'Instance', N'Milliseconds', N'GAUGE', N'RAW', N''),
    (N'COL-05', N'STG-000', N'Volume Capacity Collection', N'Collection', N'Instance', N'Status', N'STATE', N'ON_CHANGE', N''),
    (N'COL-05', N'STG-001', N'Total Volume Capacity', N'Storage', N'Volume', N'GB', N'GAUGE', N'RAW', N''),
    (N'COL-05', N'STG-002', N'Available Volume Space', N'Storage', N'Volume', N'GB', N'GAUGE', N'RAW', N''),
    (N'COL-05', N'STG-003', N'Used Volume Space', N'Storage', N'Volume', N'GB', N'GAUGE', N'RAW', N''),
    (N'COL-05', N'STG-004', N'Free Space Percentage', N'Storage', N'Volume', N'Percent', N'GAUGE', N'RAW', N''),
    (N'COL-05', N'STG-005', N'Used Space Percentage', N'Storage', N'Volume', N'Percent', N'GAUGE', N'RAW', N''),
    (N'COL-05', N'STG-006', N'Allocated SQL Database File Size', N'Storage', N'Volume', N'GB', N'GAUGE', N'RAW', N''),
    (N'COL-05', N'STG-007', N'SQL Database File Count', N'Storage', N'Volume', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-05', N'STG-008', N'Cumulative Read Operations', N'Storage IO', N'DatabaseFile', N'CumulativeCount', N'COUNTER', N'DELTA', N'Source cumulative unit retained for delta storage; reporting must label delta values correctly.'),
    (N'COL-05', N'STG-009', N'Cumulative Write Operations', N'Storage IO', N'DatabaseFile', N'CumulativeCount', N'COUNTER', N'DELTA', N'Source cumulative unit retained for delta storage; reporting must label delta values correctly.'),
    (N'COL-05', N'STG-010', N'Cumulative Read Stall', N'Storage IO', N'DatabaseFile', N'CumulativeMilliseconds', N'COUNTER', N'DELTA', N'Source cumulative unit retained for delta storage; reporting must label delta values correctly.'),
    (N'COL-05', N'STG-011', N'Cumulative Write Stall', N'Storage IO', N'DatabaseFile', N'CumulativeMilliseconds', N'COUNTER', N'DELTA', N'Source cumulative unit retained for delta storage; reporting must label delta values correctly.'),
    (N'COL-05', N'STG-012', N'Cumulative Bytes Read', N'Storage IO', N'DatabaseFile', N'CumulativeBytes', N'COUNTER', N'DELTA', N'Source cumulative unit retained for delta storage; reporting must label delta values correctly.'),
    (N'COL-05', N'STG-013', N'Cumulative Bytes Written', N'Storage IO', N'DatabaseFile', N'CumulativeBytes', N'COUNTER', N'DELTA', N'Source cumulative unit retained for delta storage; reporting must label delta values correctly.'),
    (N'COL-05', N'STG-014', N'Collector Execution Duration', N'Collection', N'Instance', N'Milliseconds', N'GAUGE', N'RAW', N''),
    (N'COL-05', N'STG-015', N'Files With Unavailable Volume Information', N'Collection', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-05', N'STG-016', N'IO Statistics Sample Time', N'Storage IO', N'DatabaseFile', N'Milliseconds', N'IDENTIFIER', N'LATEST_ONLY', N''),
    (N'COL-05', N'STG-017', N'Database File Type', N'Storage IO', N'DatabaseFile', N'StateCode', N'STATE', N'ON_CHANGE', N''),
    (N'COL-05', N'STG-099', N'Database File IO Collection', N'Collection', N'Instance', N'Status', N'STATE', N'ON_CHANGE', N''),
    (N'COL-06', N'BAK-000', N'Backup Database Inventory Collection', N'Collection', N'Instance', N'Status', N'STATE', N'ON_CHANGE', N''),
    (N'COL-06', N'BAK-001', N'Last Full Backup Age', N'Backup', N'Database', N'Hours', N'GAUGE', N'RAW', N''),
    (N'COL-06', N'BAK-002', N'Last Differential Backup Age', N'Backup', N'Database', N'Hours', N'GAUGE', N'RAW', N''),
    (N'COL-06', N'BAK-003', N'Last Transaction Log Backup Age', N'Backup', N'Database', N'Minutes', N'GAUGE', N'RAW', N''),
    (N'COL-06', N'BAK-004', N'Last Conventional Full Backup Age', N'Backup', N'Database', N'Hours', N'GAUGE', N'RAW', N''),
    (N'COL-06', N'BAK-005', N'Database Recovery Model', N'Backup Configuration', N'Database', N'StateCode', N'STATE', N'ON_CHANGE', N''),
    (N'COL-06', N'BAK-006', N'Availability Group Membership', N'Backup Configuration', N'Database', N'Boolean', N'STATE', N'ON_CHANGE', N''),
    (N'COL-06', N'BAK-007', N'Preferred Backup Replica', N'Backup Configuration', N'Database', N'Boolean', N'STATE', N'ON_CHANGE', N''),
    (N'COL-06', N'BAK-008', N'Last Full Backup Duration', N'Backup', N'Database', N'Seconds', N'GAUGE', N'RAW', N''),
    (N'COL-06', N'BAK-009', N'Last Differential Backup Duration', N'Backup', N'Database', N'Seconds', N'GAUGE', N'RAW', N''),
    (N'COL-06', N'BAK-010', N'Last Log Backup Duration', N'Backup', N'Database', N'Seconds', N'GAUGE', N'RAW', N''),
    (N'COL-06', N'BAK-011', N'Last Full Backup Size', N'Backup', N'Database', N'MB', N'GAUGE', N'RAW', N''),
    (N'COL-06', N'BAK-012', N'Last Differential Backup Size', N'Backup', N'Database', N'MB', N'GAUGE', N'RAW', N''),
    (N'COL-06', N'BAK-013', N'Last Log Backup Size', N'Backup', N'Database', N'MB', N'GAUGE', N'RAW', N''),
    (N'COL-06', N'BAK-014', N'Last Full Backup Checksums', N'Backup', N'Database', N'Boolean', N'STATE', N'ON_CHANGE', N''),
    (N'COL-06', N'BAK-015', N'Last Differential Backup Checksums', N'Backup', N'Database', N'Boolean', N'STATE', N'ON_CHANGE', N''),
    (N'COL-06', N'BAK-016', N'Last Log Backup Checksums', N'Backup', N'Database', N'Boolean', N'STATE', N'ON_CHANGE', N''),
    (N'COL-06', N'BAK-017', N'Collector Execution Duration', N'Collection', N'Instance', N'Milliseconds', N'GAUGE', N'RAW', N''),
    (N'COL-06', N'BAK-018', N'Last Full Backup Copy Only', N'Backup', N'Database', N'Boolean', N'STATE', N'ON_CHANGE', N''),
    (N'COL-06', N'BAK-019', N'Last Full Backup Snapshot', N'Backup', N'Database', N'Boolean', N'STATE', N'ON_CHANGE', N''),
    (N'COL-06', N'BAK-020', N'Last Full Backup Damaged', N'Backup', N'Database', N'Boolean', N'STATE', N'ON_CHANGE', N''),
    (N'COL-06', N'BAK-021', N'Last Differential Backup Damaged', N'Backup', N'Database', N'Boolean', N'STATE', N'ON_CHANGE', N''),
    (N'COL-06', N'BAK-022', N'Last Log Backup Damaged', N'Backup', N'Database', N'Boolean', N'STATE', N'ON_CHANGE', N''),
    (N'COL-06', N'BAK-023', N'Backup History Lookback Period', N'Collection', N'Instance', N'Days', N'GAUGE', N'RAW', N''),
    (N'COL-06', N'BAK-096', N'Backup Database Inventory Availability', N'Collection', N'Instance', N'Status', N'STATE', N'ON_CHANGE', N''),
    (N'COL-06', N'BAK-097', N'Backup Configuration Collection', N'Collection', N'Instance', N'Status', N'STATE', N'ON_CHANGE', N''),
    (N'COL-06', N'BAK-098', N'AG Backup Preference Collection', N'Collection', N'Instance', N'Status', N'STATE', N'ON_CHANGE', N''),
    (N'COL-06', N'BAK-099', N'Backup History Collection', N'Collection', N'Instance', N'Status', N'STATE', N'ON_CHANGE', N''),
    (N'COL-07', N'HA-001', N'Always On Enabled', N'High Availability', N'Instance', N'Boolean', N'STATE', N'ON_CHANGE', N''),
    (N'COL-07', N'HA-002', N'Failover Cluster Instance Enabled', N'High Availability', N'Instance', N'Boolean', N'STATE', N'ON_CHANGE', N''),
    (N'COL-07', N'HA-003', N'Local Availability Group Count', N'High Availability', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-07', N'HA-004', N'Replica Role', N'High Availability', N'AGReplica', N'StateCode', N'STATE', N'ON_CHANGE', N''),
    (N'COL-07', N'HA-005', N'Replica Operational State', N'High Availability', N'AGReplica', N'StateCode', N'STATE', N'ON_CHANGE', N''),
    (N'COL-07', N'HA-006', N'Replica Connected State', N'High Availability', N'AGReplica', N'StateCode', N'STATE', N'ON_CHANGE', N''),
    (N'COL-07', N'HA-007', N'Replica Synchronization Health', N'High Availability', N'AGReplica', N'StateCode', N'STATE', N'ON_CHANGE', N''),
    (N'COL-07', N'HA-008', N'Replica Availability Mode', N'High Availability', N'AGReplica', N'StateCode', N'STATE', N'ON_CHANGE', N''),
    (N'COL-07', N'HA-009', N'Replica Failover Mode', N'High Availability', N'AGReplica', N'StateCode', N'STATE', N'ON_CHANGE', N''),
    (N'COL-07', N'HA-010', N'Database Synchronization State', N'High Availability', N'AGDatabase', N'StateCode', N'STATE', N'ON_CHANGE', N''),
    (N'COL-07', N'HA-011', N'Database Synchronization Health', N'High Availability', N'AGDatabase', N'StateCode', N'STATE', N'ON_CHANGE', N''),
    (N'COL-07', N'HA-012', N'Availability Database State', N'High Availability', N'AGDatabase', N'StateCode', N'STATE', N'ON_CHANGE', N''),
    (N'COL-07', N'HA-013', N'Data Movement Suspended', N'High Availability', N'AGDatabase', N'Boolean', N'STATE', N'ON_CHANGE', N''),
    (N'COL-07', N'HA-014', N'Data Movement Suspend Reason', N'High Availability', N'AGDatabase', N'StateCode', N'STATE', N'ON_CHANGE', N''),
    (N'COL-07', N'HA-015', N'Log Send Queue Size', N'High Availability', N'AGDatabase', N'KB', N'GAUGE', N'RAW', N''),
    (N'COL-07', N'HA-016', N'Log Send Rate', N'High Availability', N'AGDatabase', N'KBPerSecond', N'GAUGE', N'RAW', N''),
    (N'COL-07', N'HA-017', N'Redo Queue Size', N'High Availability', N'AGDatabase', N'KB', N'GAUGE', N'RAW', N''),
    (N'COL-07', N'HA-018', N'Redo Rate', N'High Availability', N'AGDatabase', N'KBPerSecond', N'GAUGE', N'RAW', N''),
    (N'COL-07', N'HA-019', N'Estimated Redo Queue Drain Time', N'High Availability', N'AGDatabase', N'Seconds', N'GAUGE', N'RAW', N''),
    (N'COL-07', N'HA-020', N'Secondary Synchronization Lag', N'High Availability', N'AGDatabase', N'Seconds', N'GAUGE', N'RAW', N''),
    (N'COL-07', N'HA-021', N'Database Is Local Replica', N'High Availability', N'AGDatabase', N'Boolean', N'STATE', N'ON_CHANGE', N''),
    (N'COL-07', N'HA-022', N'Database Is Primary Replica', N'High Availability', N'AGDatabase', N'Boolean', N'STATE', N'ON_CHANGE', N''),
    (N'COL-07', N'HA-023', N'Database Failover Readiness', N'High Availability', N'AGDatabase', N'Boolean', N'STATE', N'ON_CHANGE', N''),
    (N'COL-07', N'HA-024', N'Collector Execution Duration', N'Collection', N'Instance', N'Milliseconds', N'GAUGE', N'RAW', N''),
    (N'COL-07', N'HA-025', N'Database Rows Visible To Collector', N'Collection', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-07', N'HA-026', N'Replica Rows Visible To Collector', N'Collection', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-07', N'HA-027', N'Replica Recovery Health', N'High Availability', N'AGReplica', N'StateCode', N'STATE', N'ON_CHANGE', N''),
    (N'COL-07', N'HA-028', N'Replica Is Local', N'High Availability', N'AGReplica', N'Boolean', N'STATE', N'ON_CHANGE', N''),
    (N'COL-07', N'HA-029', N'Database Joined To Availability Group', N'High Availability', N'AGDatabase', N'Boolean', N'STATE', N'ON_CHANGE', N''),
    (N'COL-07', N'HA-030', N'Database Synchronization Commit Participant', N'High Availability', N'AGDatabase', N'Boolean', N'STATE', N'ON_CHANGE', N''),
    (N'COL-07', N'HA-096', N'Availability Database Visibility', N'Collection', N'Instance', N'Status', N'STATE', N'ON_CHANGE', N''),
    (N'COL-07', N'HA-097', N'Availability Replica Visibility', N'Collection', N'Instance', N'Status', N'STATE', N'ON_CHANGE', N''),
    (N'COL-07', N'HA-098', N'Availability Replica Collection', N'Collection', N'Instance', N'Status', N'STATE', N'ON_CHANGE', N''),
    (N'COL-07', N'HA-099', N'Availability Database Collection', N'Collection', N'Instance', N'Status', N'STATE', N'ON_CHANGE', N''),
    (N'COL-08', N'JOB-001', N'SQL Agent Service Status', N'SQL Agent', N'Instance', N'StateCode', N'STATE', N'ON_CHANGE', N''),
    (N'COL-08', N'JOB-002', N'SQL Agent Startup Type', N'SQL Agent', N'Instance', N'StateCode', N'STATE', N'ON_CHANGE', N''),
    (N'COL-08', N'JOB-003', N'Total SQL Agent Jobs', N'SQL Agent', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-08', N'JOB-004', N'Enabled SQL Agent Jobs', N'SQL Agent', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-08', N'JOB-005', N'Disabled SQL Agent Jobs', N'SQL Agent', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-08', N'JOB-006', N'Currently Running Jobs', N'SQL Agent', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-08', N'JOB-007', N'Jobs With Last Execution Failed', N'SQL Agent', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-08', N'JOB-008', N'Job Enabled Status', N'SQL Agent', N'SQLAgentJob', N'Boolean', N'STATE', N'ON_CHANGE', N''),
    (N'COL-08', N'JOB-009', N'Last Execution Outcome', N'SQL Agent', N'SQLAgentJob', N'StateCode', N'STATE', N'ON_CHANGE', N''),
    (N'COL-08', N'JOB-010', N'Last Execution Start Age', N'SQL Agent', N'SQLAgentJob', N'Minutes', N'GAUGE', N'RAW', N''),
    (N'COL-08', N'JOB-011', N'Last Execution Duration', N'SQL Agent', N'SQLAgentJob', N'Seconds', N'GAUGE', N'RAW', N''),
    (N'COL-08', N'JOB-012', N'Currently Running Status', N'SQL Agent', N'SQLAgentJob', N'Boolean', N'STATE', N'ON_CHANGE', N''),
    (N'COL-08', N'JOB-013', N'Current Execution Duration', N'SQL Agent', N'SQLAgentJob', N'Seconds', N'GAUGE', N'RAW', N''),
    (N'COL-08', N'JOB-014', N'Enabled Schedule Count', N'SQL Agent', N'SQLAgentJob', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-08', N'JOB-015', N'Time Until Next Scheduled Execution', N'SQL Agent', N'SQLAgentJob', N'Minutes', N'GAUGE', N'RAW', N''),
    (N'COL-08', N'JOB-016', N'Collector Execution Duration', N'Collection', N'Instance', N'Milliseconds', N'GAUGE', N'RAW', N''),
    (N'COL-08', N'JOB-017', N'SQL Agent Session ID', N'SQL Agent', N'Instance', N'Identifier', N'IDENTIFIER', N'LATEST_ONLY', N''),
    (N'COL-08', N'JOB-018', N'Job Execution History Available', N'SQL Agent', N'SQLAgentJob', N'Boolean', N'STATE', N'ON_CHANGE', N''),
    (N'COL-08', N'JOB-019', N'Job Requested But Not Started', N'SQL Agent', N'SQLAgentJob', N'Boolean', N'STATE', N'ON_CHANGE', N''),
    (N'COL-08', N'JOB-020', N'Job Execution Queue Duration', N'SQL Agent', N'SQLAgentJob', N'Seconds', N'GAUGE', N'RAW', N''),
    (N'COL-08', N'JOB-099', N'SQL Agent Job Collection', N'Collection', N'Instance', N'Status', N'STATE', N'ON_CHANGE', N''),
    (N'COL-09', N'BLK-000', N'Blocking Collection', N'Collection', N'Instance', N'Status', N'STATE', N'ON_CHANGE', N''),
    (N'COL-09', N'BLK-001', N'Total Blocked Requests', N'Blocking', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-09', N'BLK-002', N'Total Blocked Sessions', N'Blocking', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-09', N'BLK-003', N'Distinct Blocking Sessions', N'Blocking', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-09', N'BLK-004', N'Identified Head Blockers', N'Blocking', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-09', N'BLK-005', N'Maximum Current Blocking Wait', N'Blocking', N'Instance', N'Seconds', N'GAUGE', N'RAW', N''),
    (N'COL-09', N'BLK-006', N'Requests Blocked Over 30 Seconds', N'Blocking', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-09', N'BLK-007', N'Requests Blocked Over 60 Seconds', N'Blocking', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-09', N'BLK-008', N'Requests Blocked Over 300 Seconds', N'Blocking', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-09', N'BLK-009', N'Suspended User Requests', N'Blocking', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-09', N'BLK-010', N'Current Blocking Wait Duration', N'Blocking', N'SessionRequest', N'Seconds', N'GAUGE', N'RAW', N''),
    (N'COL-09', N'BLK-011', N'Blocking Session ID', N'Blocking', N'SessionRequest', N'Identifier', N'IDENTIFIER', N'LATEST_ONLY', N''),
    (N'COL-09', N'BLK-012', N'Blocked Request Database ID', N'Blocking', N'SessionRequest', N'Identifier', N'IDENTIFIER', N'LATEST_ONLY', N''),
    (N'COL-09', N'BLK-013', N'Directly Blocked Sessions', N'Blocking', N'BlockingSession', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-09', N'BLK-014', N'Head Blocker Indicator', N'Blocking', N'BlockingSession', N'Boolean', N'STATE', N'ON_CHANGE', N''),
    (N'COL-09', N'BLK-015', N'Sleeping Blocker Indicator', N'Blocking', N'BlockingSession', N'Boolean', N'STATE', N'ON_CHANGE', N''),
    (N'COL-09', N'BLK-016', N'Blocker Open Transaction Count', N'Blocking', N'BlockingSession', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-09', N'BLK-017', N'Active User Transactions', N'Transactions', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-09', N'BLK-018', N'Oldest Active User Transaction Age', N'Transactions', N'Instance', N'Seconds', N'GAUGE', N'RAW', N''),
    (N'COL-09', N'BLK-019', N'Transactions Older Than 5 Minutes', N'Transactions', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-09', N'BLK-020', N'Transactions Older Than 30 Minutes', N'Transactions', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-09', N'BLK-021', N'Collector Execution Duration', N'Collection', N'Instance', N'Milliseconds', N'GAUGE', N'RAW', N''),
    (N'COL-09', N'BLK-022', N'Requests With Negative Blocker IDs', N'Blocking', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-09', N'BLK-023', N'Oldest Transaction Age Per Session', N'Transactions', N'Session', N'Seconds', N'GAUGE', N'RAW', N''),
    (N'COL-09', N'BLK-099', N'Active Transaction Collection', N'Collection', N'Instance', N'Status', N'STATE', N'ON_CHANGE', N''),
    (N'COL-10', N'LOG-000', N'Transaction Log Database Inventory', N'Collection', N'Instance', N'Status', N'STATE', N'ON_CHANGE', N''),
    (N'COL-10', N'LOG-001', N'Total Allocated Transaction Log Size', N'Transaction Log', N'Database', N'MB', N'GAUGE', N'RAW', N''),
    (N'COL-10', N'LOG-002', N'Used Transaction Log Space', N'Transaction Log', N'Database', N'MB', N'GAUGE', N'RAW', N''),
    (N'COL-10', N'LOG-003', N'Available Transaction Log Space', N'Transaction Log', N'Database', N'MB', N'GAUGE', N'RAW', N''),
    (N'COL-10', N'LOG-004', N'Transaction Log Utilization', N'Transaction Log', N'Database', N'Percent', N'GAUGE', N'RAW', N''),
    (N'COL-10', N'LOG-005', N'Log Reuse Wait Reason', N'Transaction Log Configuration', N'Database', N'StateCode', N'STATE', N'ON_CHANGE', N''),
    (N'COL-10', N'LOG-006', N'Database Recovery Model', N'Transaction Log Configuration', N'Database', N'StateCode', N'STATE', N'ON_CHANGE', N''),
    (N'COL-10', N'LOG-007', N'Transaction Log File Count', N'Transaction Log Configuration', N'Database', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-10', N'LOG-008', N'Log Files With Autogrowth Disabled', N'Transaction Log Configuration', N'Database', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-10', N'LOG-009', N'Log Files With Percentage Growth', N'Transaction Log Configuration', N'Database', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-10', N'LOG-010', N'Log Files With Configured Maximum Size', N'Transaction Log Configuration', N'Database', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-10', N'LOG-011', N'Total Virtual Log File Count', N'Transaction Log', N'Database', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-10', N'LOG-012', N'Active Virtual Log File Count', N'Transaction Log', N'Database', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-10', N'LOG-013', N'Active Transaction Log Size', N'Transaction Log', N'Database', N'MB', N'GAUGE', N'RAW', N''),
    (N'COL-10', N'LOG-014', N'Log Generated Since Last Log Backup', N'Transaction Log', N'Database', N'MB', N'GAUGE', N'RAW', N''),
    (N'COL-10', N'LOG-015', N'Log Generated Since Last Checkpoint', N'Transaction Log', N'Database', N'MB', N'GAUGE', N'RAW', N''),
    (N'COL-10', N'LOG-016', N'Collector Execution Duration', N'Collection', N'Instance', N'Milliseconds', N'GAUGE', N'RAW', N''),
    (N'COL-10', N'LOG-017', N'Log Truncation Holdup Reason', N'Transaction Log', N'Database', N'StateCode', N'STATE', N'ON_CHANGE', N''),
    (N'COL-10', N'LOG-018', N'Log Files At Configured Maximum Size', N'Transaction Log Configuration', N'Database', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-10', N'LOG-019', N'Databases With Advanced Log Statistics', N'Collection', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-10', N'LOG-020', N'Configured Allocated Log File Size', N'Transaction Log Configuration', N'Database', N'MB', N'GAUGE', N'RAW', N''),
    (N'COL-10', N'LOG-021', N'Databases Visible To Log Collector', N'Collection', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-10', N'LOG-097', N'Advanced Transaction Log Statistics Collection', N'Collection', N'Instance', N'Status', N'STATE', N'ON_CHANGE', N''),
    (N'COL-10', N'LOG-098', N'Transaction Log Configuration Collection', N'Collection', N'Instance', N'Status', N'STATE', N'ON_CHANGE', N''),
    (N'COL-10', N'LOG-099', N'Transaction Log Space Collection', N'Collection', N'Instance', N'Status', N'STATE', N'ON_CHANGE', N''),
    (N'COL-11', N'DLK-000', N'System Health Session Validation', N'Collection', N'Instance', N'Status', N'STATE', N'ON_CHANGE', N''),
    (N'COL-11', N'DLK-001', N'System Health Session Running', N'Deadlocks', N'Instance', N'Boolean', N'STATE', N'ON_CHANGE', N''),
    (N'COL-11', N'DLK-002', N'Event File Target Available', N'Deadlocks', N'Instance', N'Boolean', N'STATE', N'ON_CHANGE', N''),
    (N'COL-11', N'DLK-003', N'Deadlocks Observed In Collection Window', N'Deadlocks', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-11', N'DLK-004', N'Most Recent Observed Deadlock Age', N'Deadlocks', N'Instance', N'Seconds', N'GAUGE', N'RAW', N''),
    (N'COL-11', N'DLK-005', N'Deadlock Victim Count', N'Deadlocks', N'DeadlockEvent', N'Count', N'EVENT', N'EVENT_ONLY', N'Requires stable event generation and replay-safe ingestion.'),
    (N'COL-11', N'DLK-006', N'Deadlock Participating Process Count', N'Deadlocks', N'DeadlockEvent', N'Count', N'EVENT', N'EVENT_ONLY', N'Requires stable event generation and replay-safe ingestion.'),
    (N'COL-11', N'DLK-007', N'Deadlock Resource Count', N'Deadlocks', N'DeadlockEvent', N'Count', N'EVENT', N'EVENT_ONLY', N'Requires stable event generation and replay-safe ingestion.'),
    (N'COL-11', N'DLK-008', N'Collector Execution Duration', N'Collection', N'Instance', N'Milliseconds', N'GAUGE', N'RAW', N''),
    (N'COL-11', N'DLK-009', N'Deadlock Collection Lookback Period', N'Collection', N'Instance', N'Minutes', N'GAUGE', N'RAW', N''),
    (N'COL-11', N'DLK-010', N'Deadlock Event Timestamp UTC', N'Deadlocks', N'DeadlockEvent', N'UnixSeconds', N'EVENT', N'EVENT_ONLY', N'Requires stable event generation and replay-safe ingestion.'),
    (N'COL-11', N'DLK-011', N'Full Deadlock Window Coverage Verified', N'Collection', N'Instance', N'Boolean', N'STATE', N'ON_CHANGE', N''),
    (N'COL-11', N'DLK-012', N'Deadlock Event File Collection Successful', N'Collection', N'Instance', N'Boolean', N'STATE', N'ON_CHANGE', N''),
    (N'COL-11', N'DLK-098', N'Deadlock Event Detail Collection', N'Collection', N'Instance', N'Status', N'STATE', N'ON_CHANGE', N''),
    (N'COL-11', N'DLK-099', N'Deadlock Event File Collection', N'Collection', N'Instance', N'Status', N'STATE', N'ON_CHANGE', N''),
    (N'COL-12', N'ERR-000', N'Error Log Inventory Collection', N'Collection', N'Instance', N'Status', N'STATE', N'ON_CHANGE', N''),
    (N'COL-12', N'ERR-001', N'Error Log Collection Successful', N'Collection', N'Instance', N'Boolean', N'STATE', N'ON_CHANGE', N''),
    (N'COL-12', N'ERR-002', N'Error Log Entries Observed', N'Error Log', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-12', N'ERR-003', N'Severity 17 To 19 Errors', N'Error Log', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-12', N'ERR-004', N'Severity 20 To 25 Errors', N'Error Log', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-12', N'ERR-005', N'Failed Login Errors 18456', N'Error Log', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-12', N'ERR-006', N'IO Error 823', N'Error Log', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-12', N'ERR-007', N'IO Error 824', N'Error Log', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-12', N'ERR-008', N'IO Retry Error 825', N'Error Log', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-12', N'ERR-009', N'Transaction Log Full Error 9002', N'Error Log', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-12', N'ERR-010', N'Database Recovery Error 3414', N'Error Log', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-12', N'ERR-011', N'Always On Error 35273', N'Error Log', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-12', N'ERR-012', N'Backup Failure Error 3041', N'Error Log', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-12', N'ERR-013', N'Filegroup Allocation Error 1105', N'Error Log', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-12', N'ERR-014', N'Insufficient Memory Error 701', N'Error Log', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-12', N'ERR-015', N'Collector Execution Duration', N'Collection', N'Instance', N'Milliseconds', N'GAUGE', N'RAW', N''),
    (N'COL-12', N'ERR-016', N'Error Log Collection Lookback Period', N'Collection', N'Instance', N'Minutes', N'GAUGE', N'RAW', N''),
    (N'COL-12', N'ERR-017', N'Current Error Log Size', N'Error Log', N'Instance', N'MB', N'GAUGE', N'RAW', N''),
    (N'COL-12', N'ERR-018', N'Error Log Content Collection Skipped', N'Collection', N'Instance', N'Boolean', N'STATE', N'ON_CHANGE', N''),
    (N'COL-12', N'ERR-019', N'Full Error Log Window Coverage Verified', N'Collection', N'Instance', N'Boolean', N'STATE', N'ON_CHANGE', N''),
    (N'COL-12', N'ERR-020', N'File Autogrowth Cancellation Error 5144', N'Error Log', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-12', N'ERR-021', N'Long IO Warning Error 833', N'Error Log', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-12', N'ERR-022', N'Maximum Permitted Error Log Scan Size', N'Collection', N'Instance', N'MB', N'GAUGE', N'RAW', N''),
    (N'COL-12', N'ERR-023', N'Error Log Size Validation Successful', N'Collection', N'Instance', N'Boolean', N'STATE', N'ON_CHANGE', N''),
    (N'COL-12', N'ERR-098', N'Error Log Parsing', N'Collection', N'Instance', N'Status', N'STATE', N'ON_CHANGE', N''),
    (N'COL-12', N'ERR-099', N'Error Log Content Collection', N'Collection', N'Instance', N'Status', N'STATE', N'ON_CHANGE', N''),
    (N'COL-13', N'WAI-001', N'Cumulative Waiting Tasks Count', N'Wait Statistics', N'WaitType', N'CumulativeCount', N'COUNTER', N'DELTA', N'Source cumulative unit retained for delta storage; reporting must label delta values correctly.'),
    (N'COL-13', N'WAI-002', N'Cumulative Total Wait Time', N'Wait Statistics', N'WaitType', N'CumulativeMilliseconds', N'COUNTER', N'DELTA', N'Source cumulative unit retained for delta storage; reporting must label delta values correctly.'),
    (N'COL-13', N'WAI-003', N'Cumulative Signal Wait Time', N'Wait Statistics', N'WaitType', N'CumulativeMilliseconds', N'COUNTER', N'DELTA', N'Source cumulative unit retained for delta storage; reporting must label delta values correctly.'),
    (N'COL-13', N'WAI-004', N'Cumulative Resource Wait Time', N'Wait Statistics', N'WaitType', N'CumulativeMilliseconds', N'COUNTER', N'DELTA', N'Source cumulative unit retained for delta storage; reporting must label delta values correctly.'),
    (N'COL-13', N'WAI-005', N'Maximum Recorded Wait Time', N'Wait Statistics', N'WaitType', N'Milliseconds', N'GAUGE', N'RAW', N''),
    (N'COL-13', N'WAI-006', N'Total Observed Wait Types', N'Collection', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-13', N'WAI-007', N'Wait Types With Recorded Activity', N'Wait Statistics', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-13', N'WAI-008', N'SQL Server Uptime', N'Collection', N'Instance', N'Seconds', N'GAUGE', N'RAW', N''),
    (N'COL-13', N'WAI-009', N'Collector Execution Duration', N'Collection', N'Instance', N'Milliseconds', N'GAUGE', N'RAW', N''),
    (N'COL-13', N'WAI-010', N'SQL Server Startup Tick', N'Collection', N'Instance', N'Milliseconds', N'IDENTIFIER', N'LATEST_ONLY', N''),
    (N'COL-13', N'WAI-099', N'Wait Statistics Collection', N'Collection', N'Instance', N'Status', N'STATE', N'ON_CHANGE', N''),
    (N'COL-14', N'TMP-000', N'TempDB File Configuration Collection', N'Collection', N'Instance', N'Status', N'STATE', N'ON_CHANGE', N''),
    (N'COL-14', N'TMP-001', N'Total TempDB Data File Size', N'TempDB Space', N'Database', N'MB', N'GAUGE', N'RAW', N''),
    (N'COL-14', N'TMP-002', N'TempDB Unallocated Extent Space', N'TempDB Space', N'Database', N'MB', N'GAUGE', N'RAW', N''),
    (N'COL-14', N'TMP-003', N'TempDB Allocated Extent Space', N'TempDB Space', N'Database', N'MB', N'GAUGE', N'RAW', N''),
    (N'COL-14', N'TMP-004', N'TempDB Data Space Utilization', N'TempDB Space', N'Database', N'Percent', N'GAUGE', N'RAW', N''),
    (N'COL-14', N'TMP-005', N'TempDB User Object Reserved Space', N'TempDB Space', N'Database', N'MB', N'GAUGE', N'RAW', N''),
    (N'COL-14', N'TMP-006', N'TempDB Internal Object Reserved Space', N'TempDB Space', N'Database', N'MB', N'GAUGE', N'RAW', N''),
    (N'COL-14', N'TMP-007', N'TempDB Version Store Reserved Space', N'TempDB Space', N'Database', N'MB', N'GAUGE', N'RAW', N''),
    (N'COL-14', N'TMP-008', N'TempDB Mixed Extent Allocated Space', N'TempDB Space', N'Database', N'MB', N'GAUGE', N'RAW', N''),
    (N'COL-14', N'TMP-009', N'TempDB Data File Count', N'TempDB Configuration', N'Database', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-14', N'TMP-010', N'TempDB Log File Count', N'TempDB Configuration', N'Database', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-14', N'TMP-011', N'TempDB File Size', N'TempDB Configuration', N'DatabaseFile', N'MB', N'GAUGE', N'RAW', N''),
    (N'COL-14', N'TMP-012', N'TempDB File Autogrowth Increment', N'TempDB Configuration', N'DatabaseFile', N'MB', N'GAUGE', N'LATEST_ONLY', N'Unit is MB for fixed growth or Percent for percentage growth; both must be accepted by ingestion.'),
    (N'COL-14', N'TMP-013', N'TempDB File Percentage Growth', N'TempDB Configuration', N'DatabaseFile', N'Boolean', N'STATE', N'ON_CHANGE', N''),
    (N'COL-14', N'TMP-014', N'TempDB File Maximum Size Setting', N'TempDB Configuration', N'DatabaseFile', N'MB', N'GAUGE', N'RAW', N''),
    (N'COL-14', N'TMP-015', N'TempDB File Autogrowth Disabled', N'TempDB Configuration', N'DatabaseFile', N'Boolean', N'STATE', N'ON_CHANGE', N''),
    (N'COL-14', N'TMP-016', N'Current TempDB Page Latch Waiting Tasks', N'TempDB Contention', N'Database', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-14', N'TMP-017', N'Maximum Current TempDB Page Latch Wait', N'TempDB Contention', N'Database', N'Milliseconds', N'GAUGE', N'RAW', N''),
    (N'COL-14', N'TMP-018', N'Suspected Allocation Page Latch Waiting Tasks', N'TempDB Contention', N'Database', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-14', N'TMP-019', N'Collector Execution Duration', N'Collection', N'Instance', N'Milliseconds', N'GAUGE', N'RAW', N''),
    (N'COL-14', N'TMP-020', N'TempDB Data File Size Uniformity', N'TempDB Configuration', N'Database', N'Boolean', N'STATE', N'ON_CHANGE', N''),
    (N'COL-14', N'TMP-021', N'TempDB Data File Growth Uniformity', N'TempDB Configuration', N'Database', N'Boolean', N'STATE', N'ON_CHANGE', N''),
    (N'COL-14', N'TMP-022', N'TempDB File Unallocated Extent Space', N'TempDB Space', N'DatabaseFile', N'MB', N'GAUGE', N'RAW', N''),
    (N'COL-14', N'TMP-023', N'TempDB Data File Utilization', N'TempDB Space', N'DatabaseFile', N'Percent', N'GAUGE', N'RAW', N''),
    (N'COL-14', N'TMP-024', N'TempDB File Type', N'TempDB Configuration', N'DatabaseFile', N'StateCode', N'STATE', N'ON_CHANGE', N''),
    (N'COL-14', N'TMP-025', N'TempDB Data Files With Space Statistics', N'Collection', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-14', N'TMP-098', N'TempDB Page Latch Collection', N'Collection', N'Instance', N'Status', N'STATE', N'ON_CHANGE', N''),
    (N'COL-14', N'TMP-099', N'TempDB Space Utilization Collection', N'Collection', N'Instance', N'Status', N'STATE', N'ON_CHANGE', N''),
    (N'COL-15', N'QRY-001', N'Active User Requests', N'Query Performance', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-15', N'QRY-002', N'Long Running Requests', N'Query Performance', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-15', N'QRY-003', N'Requests Running Over 5 Minutes', N'Query Performance', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-15', N'QRY-004', N'Requests Running Over 15 Minutes', N'Query Performance', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-15', N'QRY-005', N'Maximum Request Elapsed Time', N'Query Performance', N'Instance', N'Seconds', N'GAUGE', N'RAW', N''),
    (N'COL-15', N'QRY-006', N'Requests Above CPU Time Threshold', N'Query Performance', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-15', N'QRY-007', N'Requests Above Logical Read Threshold', N'Query Performance', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-15', N'QRY-008', N'Request Elapsed Time', N'Query Performance', N'SessionRequest', N'Seconds', N'GAUGE', N'RAW', N''),
    (N'COL-15', N'QRY-009', N'Request CPU Time', N'Query Performance', N'SessionRequest', N'Seconds', N'GAUGE', N'RAW', N''),
    (N'COL-15', N'QRY-010', N'Request Logical Reads', N'Query Performance', N'SessionRequest', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-15', N'QRY-011', N'Request Physical Reads', N'Query Performance', N'SessionRequest', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-15', N'QRY-012', N'Request Writes', N'Query Performance', N'SessionRequest', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-15', N'QRY-013', N'Request Granted Query Memory', N'Query Performance', N'SessionRequest', N'MB', N'GAUGE', N'RAW', N''),
    (N'COL-15', N'QRY-014', N'Request Database ID', N'Query Performance', N'SessionRequest', N'Identifier', N'IDENTIFIER', N'LATEST_ONLY', N''),
    (N'COL-15', N'QRY-015', N'Request Session ID', N'Query Performance', N'SessionRequest', N'Identifier', N'IDENTIFIER', N'LATEST_ONLY', N''),
    (N'COL-15', N'QRY-016', N'Request Blocking Session ID', N'Query Performance', N'SessionRequest', N'Identifier', N'IDENTIFIER', N'LATEST_ONLY', N''),
    (N'COL-15', N'QRY-017', N'Request Current Wait Duration', N'Query Performance', N'SessionRequest', N'Seconds', N'GAUGE', N'RAW', N''),
    (N'COL-15', N'QRY-018', N'Request Open Transaction Count', N'Query Performance', N'SessionRequest', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-15', N'QRY-019', N'Request Degree Of Parallelism', N'Query Performance', N'SessionRequest', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-15', N'QRY-020', N'Request Reported Completion Percentage', N'Query Performance', N'SessionRequest', N'Percent', N'GAUGE', N'RAW', N''),
    (N'COL-15', N'QRY-021', N'Collector Execution Duration', N'Collection', N'Instance', N'Milliseconds', N'GAUGE', N'RAW', N''),
    (N'COL-15', N'QRY-022', N'Requests Qualifying For Detailed Collection', N'Query Performance', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-15', N'QRY-023', N'Requests Returned In Detailed Collection', N'Collection', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-15', N'QRY-024', N'Detailed Request Collection Truncated', N'Collection', N'Instance', N'Boolean', N'STATE', N'ON_CHANGE', N''),
    (N'COL-15', N'QRY-025', N'Long Running Request Collection Threshold', N'Collection', N'Instance', N'Seconds', N'GAUGE', N'RAW', N''),
    (N'COL-15', N'QRY-026', N'Request CPU Time Collection Threshold', N'Collection', N'Instance', N'Seconds', N'GAUGE', N'RAW', N''),
    (N'COL-15', N'QRY-027', N'Request Logical Reads Collection Threshold', N'Collection', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-15', N'QRY-028', N'Maximum Detailed Requests Per Collection', N'Collection', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-15', N'QRY-099', N'Active Request Collection', N'Collection', N'Instance', N'Status', N'STATE', N'ON_CHANGE', N''),
    (N'COL-16', N'JH-001', N'Completed Job Executions Collected', N'SQL Agent History', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-16', N'JH-002', N'Successful Job Executions', N'SQL Agent History', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-16', N'JH-003', N'Failed Job Executions', N'SQL Agent History', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-16', N'JH-004', N'Canceled Job Executions', N'SQL Agent History', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-16', N'JH-005', N'Job Execution Outcome', N'SQL Agent History', N'SQLAgentExecution', N'StateCode', N'EVENT', N'EVENT_ONLY', N'Requires stable event generation and replay-safe ingestion.'),
    (N'COL-16', N'JH-006', N'Job Execution Duration', N'SQL Agent History', N'SQLAgentExecution', N'Seconds', N'EVENT', N'EVENT_ONLY', N'Requires stable event generation and replay-safe ingestion.'),
    (N'COL-16', N'JH-007', N'Job Execution Start Local Timestamp', N'SQL Agent History', N'SQLAgentExecution', N'LocalEpochSeconds', N'EVENT', N'EVENT_ONLY', N'Requires stable event generation and replay-safe ingestion.'),
    (N'COL-16', N'JH-008', N'Job Execution Finish Local Timestamp', N'SQL Agent History', N'SQLAgentExecution', N'LocalEpochSeconds', N'EVENT', N'EVENT_ONLY', N'Requires stable event generation and replay-safe ingestion.'),
    (N'COL-16', N'JH-009', N'SQL Agent History Instance ID', N'SQL Agent History', N'SQLAgentExecution', N'Identifier', N'EVENT', N'EVENT_ONLY', N'Requires stable event generation and replay-safe ingestion.'),
    (N'COL-16', N'JH-010', N'Highest Available History ID', N'SQL Agent History', N'Instance', N'Identifier', N'IDENTIFIER', N'LATEST_ONLY', N''),
    (N'COL-16', N'JH-011', N'Lowest Available History ID', N'SQL Agent History', N'Instance', N'Identifier', N'IDENTIFIER', N'LATEST_ONLY', N''),
    (N'COL-16', N'JH-012', N'Collector Execution Duration', N'Collection', N'Instance', N'Milliseconds', N'GAUGE', N'RAW', N''),
    (N'COL-16', N'JH-013', N'Last Processed History ID', N'Collection', N'Instance', N'Identifier', N'IDENTIFIER', N'LATEST_ONLY', N''),
    (N'COL-16', N'JH-014', N'Proposed Next Collection Checkpoint', N'SQL Agent History', N'Instance', N'Identifier', N'IDENTIFIER', N'LATEST_ONLY', N''),
    (N'COL-16', N'JH-015', N'Additional History Records Remain', N'SQL Agent History', N'Instance', N'Boolean', N'STATE', N'ON_CHANGE', N''),
    (N'COL-16', N'JH-016', N'Initial History Lookback Period', N'Collection', N'Instance', N'Days', N'GAUGE', N'RAW', N''),
    (N'COL-16', N'JH-017', N'SQL Agent History Collection Successful', N'Collection', N'Instance', N'Boolean', N'STATE', N'ON_CHANGE', N''),
    (N'COL-16', N'JH-018', N'Possible Job History Discontinuity', N'Collection', N'Instance', N'Boolean', N'STATE', N'ON_CHANGE', N''),
    (N'COL-16', N'JH-019', N'Maximum History Executions Per Batch', N'Collection', N'Instance', N'Count', N'GAUGE', N'RAW', N''),
    (N'COL-16', N'JH-099', N'SQL Agent History Collection', N'Collection', N'Instance', N'Status', N'STATE', N'ON_CHANGE', N'');

-- SECTION 4: Validate and Register (atomic, insert-only)
IF (SELECT COUNT(*) FROM @Catalog) <> 327
OR (SELECT COUNT(DISTINCT CollectorCode) FROM @Catalog) <> 16
    THROW 50010, 'Unexpected metric catalog count.', 1;
BEGIN TRY
    BEGIN TRANSACTION;
    EXEC @LockResult = sys.sp_getapplock
        @Resource = N'DBA_Monitoring.CollectionScheduling',
        @LockMode = 'Exclusive', @LockOwner = 'Transaction', @LockTimeout = 10000;
    IF @LockResult < 0
        THROW 50011, 'Unable to acquire collection scheduling lock.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.MonitoringSettings WITH (UPDLOCK, HOLDLOCK)
                   WHERE SettingKey = 'MonitoringEnabled' AND SettingValue = N'0')
        THROW 50012, 'Disable monitoring before registration.', 1;
    IF EXISTS (SELECT 1 FROM dbo.CollectionRuns WITH (UPDLOCK, HOLDLOCK) WHERE RunStatus = 'RUNNING')
        THROW 50013, 'Active collection runs exist.', 1;
    IF EXISTS (SELECT 1 FROM @Catalog S LEFT JOIN dbo.Collectors C WITH (UPDLOCK, HOLDLOCK)
                   ON C.CollectorCode = S.CollectorCode AND C.ModuleID = '26'
               WHERE C.CollectorID IS NULL)
        THROW 50014, 'Required Module 26 collectors are missing.', 1;
    IF EXISTS
    (
        SELECT 1 FROM @Catalog S
        JOIN dbo.Collectors C ON C.CollectorCode = S.CollectorCode
        JOIN dbo.MetricDefinitions D WITH (UPDLOCK, HOLDLOCK)
          ON D.CollectorID = C.CollectorID AND D.MetricID = S.MetricID
        WHERE D.MetricName <> S.MetricName OR D.Category <> S.Category
           OR D.ResourceType <> S.ResourceType OR D.DefaultMetricUnit <> S.DefaultMetricUnit
           OR D.MetricBehavior <> S.MetricBehavior OR D.StoragePolicy <> S.StoragePolicy
    )
        THROW 50015, 'Existing metric definition conflicts with source catalog; review before proceeding.', 1;
    INSERT INTO dbo.MetricDefinitions
    (CollectorID, MetricID, MetricName, Category, ResourceType, DefaultMetricUnit,
     MetricBehavior, StoragePolicy, IsEnabled, Description)
    SELECT C.CollectorID, S.MetricID, S.MetricName, S.Category, S.ResourceType,
           S.DefaultMetricUnit, S.MetricBehavior, S.StoragePolicy, 1, NULLIF(S.Description, N'')
    FROM @Catalog S JOIN dbo.Collectors C ON C.CollectorCode = S.CollectorCode
    WHERE NOT EXISTS (SELECT 1 FROM dbo.MetricDefinitions D WITH (UPDLOCK, HOLDLOCK)
                      WHERE D.CollectorID = C.CollectorID AND D.MetricID = S.MetricID);
    SET @Inserted = @@ROWCOUNT;
    IF (SELECT COUNT(*) FROM @Catalog S JOIN dbo.Collectors C ON C.CollectorCode = S.CollectorCode
        JOIN dbo.MetricDefinitions D ON D.CollectorID = C.CollectorID AND D.MetricID = S.MetricID) <> 327
        THROW 50016, 'Metric registration verification failed.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WITH (UPDLOCK, HOLDLOCK) WHERE VersionNumber = '1.0.7')
        INSERT INTO dbo.SchemaVersion (VersionNumber, ScriptName, AppliedBy, Description)
        VALUES ('1.0.7', N'11-Register-Metric-Definitions.sql', ORIGINAL_LOGIN(), N'Module 26 metric catalog registration.');
    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;

-- SECTION 5: Registration Verification
SELECT 327 AS ExpectedMetricCount, @Inserted AS NewlyRegistered, 327 - @Inserted AS ExistingDefinitions;
SELECT S.CollectorCode, COUNT(*) AS RegisteredMetrics,
       SUM(CASE WHEN D.IsEnabled = 1 THEN 1 ELSE 0 END) AS EnabledMetricDefinitions
FROM @Catalog S JOIN dbo.Collectors C ON C.CollectorCode = S.CollectorCode
JOIN dbo.MetricDefinitions D ON D.CollectorID = C.CollectorID AND D.MetricID = S.MetricID
GROUP BY S.CollectorCode ORDER BY S.CollectorCode;
SELECT S.CollectorCode, D.MetricID, D.MetricName, D.Category, D.ResourceType,
       D.DefaultMetricUnit, D.MetricBehavior, D.StoragePolicy, D.IsEnabled
FROM @Catalog S JOIN dbo.Collectors C ON C.CollectorCode = S.CollectorCode
JOIN dbo.MetricDefinitions D ON D.CollectorID = C.CollectorID AND D.MetricID = S.MetricID
ORDER BY S.CollectorCode, D.MetricID;
GO
