/*
============================================================
Project : SQL Server Production Optimization
Module  : 26 - Data Collection
Script  : 01-Instance-Health-Collector.sql
Purpose : Collect SQL Server instance health metrics
Type    : Read-Only Monitoring Collector
Impact  : Low
Frequency: 60 Seconds (Proposed)
============================================================
*/

USE master;
GO

SET NOCOUNT ON;

------------------------------------------------------------
-- SECTION 1: Collection Variables
------------------------------------------------------------

DECLARE
    @CaptureDate DATETIME2(3) = SYSUTCDATETIME(),
    @ServerName NVARCHAR(128),
    @StartTime DATETIME2,
    @UptimeSeconds BIGINT,
    @CPUCount INT,
    @TotalMemoryMB BIGINT,
    @CollectionStart DATETIME2(3) = SYSUTCDATETIME();

SET @ServerName =
    CONVERT(NVARCHAR(128), SERVERPROPERTY('ServerName'));

------------------------------------------------------------
-- SECTION 2: Monitoring Data Structure
------------------------------------------------------------

DECLARE @Metrics TABLE
(
    MetricID VARCHAR(30),
    Category VARCHAR(50),
    ResourceType VARCHAR(30),
    ResourceName NVARCHAR(256),
    MetricName VARCHAR(100),
    MetricValue DECIMAL(28,4),
    MetricUnit VARCHAR(30),
    CollectionStatus VARCHAR(20),
    ErrorMessage NVARCHAR(2048)
);

------------------------------------------------------------
-- SECTION 3: Instance Availability
------------------------------------------------------------

INSERT INTO @Metrics
VALUES
(
    'INST-001',
    'Availability',
    'Instance',
    @ServerName,
    'Instance Availability',
    1,
    'Boolean',
    'SUCCESS',
    NULL
);

------------------------------------------------------------
-- SECTION 4: Instance Health Collection
------------------------------------------------------------

BEGIN TRY

    SELECT
        @StartTime = sqlserver_start_time,
        @UptimeSeconds =
            CONVERT(BIGINT, ms_ticks -
                sqlserver_start_time_ms_ticks) / 1000,
        @CPUCount = cpu_count,
        @TotalMemoryMB = physical_memory_kb / 1024
    FROM sys.dm_os_sys_info;

    INSERT INTO @Metrics
    VALUES
    (
        'INST-002',
        'Availability',
        'Instance',
        @ServerName,
        'Instance Uptime',
        @UptimeSeconds,
        'Seconds',
        CASE WHEN @UptimeSeconds IS NULL
            THEN 'UNKNOWN' ELSE 'SUCCESS' END,
        NULL
    ),
    (
        'INST-003',
        'CPU',
        'Instance',
        @ServerName,
        'Logical CPU Count',
        @CPUCount,
        'Count',
        CASE WHEN @CPUCount IS NULL
            THEN 'UNKNOWN' ELSE 'SUCCESS' END,
        NULL
    ),
    (
        'INST-004',
        'Memory',
        'Instance',
        @ServerName,
        'Total Physical Memory',
        @TotalMemoryMB,
        'MB',
        CASE WHEN @TotalMemoryMB IS NULL
            THEN 'UNKNOWN' ELSE 'SUCCESS' END,
        NULL
    );

END TRY

BEGIN CATCH

    INSERT INTO @Metrics
    SELECT
        MetricID,
        Category,
        'Instance',
        @ServerName,
        MetricName,
        NULL,
        MetricUnit,
        'FAILED',
        ERROR_MESSAGE()
    FROM
    (
        VALUES
        ('INST-002', 'Availability',
         'Instance Uptime', 'Seconds'),

        ('INST-003', 'CPU',
         'Logical CPU Count', 'Count'),

        ('INST-004', 'Memory',
         'Total Physical Memory', 'MB')

    ) AS M
    (
        MetricID,
        Category,
        MetricName,
        MetricUnit
    );

END CATCH;

------------------------------------------------------------
-- SECTION 5: Collection Performance
------------------------------------------------------------

INSERT INTO @Metrics
VALUES
(
    'INST-005',
    'Collection',
    'Instance',
    @ServerName,
    'Collector Execution Duration',
    DATEDIFF(MILLISECOND,
        @CollectionStart, SYSUTCDATETIME()),
    'Milliseconds',
    'SUCCESS',
    NULL
);

------------------------------------------------------------
-- SECTION 6: Standardized Monitoring Output
------------------------------------------------------------

SELECT
    @CaptureDate AS CaptureDateUTC,
    @ServerName AS ServerName,
    '26' AS ModuleID,
    MetricID,
    Category,
    ResourceType,
    ResourceName,
    MetricName,
    MetricValue,
    MetricUnit,
    CollectionStatus,
    ErrorMessage
FROM @Metrics

ORDER BY MetricID;

GO
