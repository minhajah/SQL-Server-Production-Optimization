/*
============================================================
Project : SQL Server Production Optimization
Module  : 26 - Data Collection
Script  : 04-Memory-Collector.sql
Purpose : Collect memory utilization and pressure metrics
Type    : Read-Only Monitoring Collector
Impact  : Low
Frequency: 60 Seconds (Proposed)
============================================================
*/

USE master;
GO

SET NOCOUNT ON;

-- Limit lock waits and favor application transactions in deadlocks.
SET LOCK_TIMEOUT 5000;
SET DEADLOCK_PRIORITY LOW;

------------------------------------------------------------
-- SECTION 1: Collection Variables
------------------------------------------------------------

DECLARE
    @CaptureDate DATETIME2(3) = SYSUTCDATETIME(),
    @CollectionStart DATETIME2(3) = SYSUTCDATETIME(),
    @ServerName NVARCHAR(128),

    @TotalMemoryMB DECIMAL(28,4),
    @AvailableMemoryMB DECIMAL(28,4),
    @MemoryUsedPercent DECIMAL(28,4),

    @SQLMemoryMB DECIMAL(28,4),
    @MaxMemoryMB BIGINT,
    @MinMemoryMB BIGINT,

    @OSMemoryLow INT,
    @ProcessPhysicalLow INT,
    @ProcessVirtualLow INT,
    @LockedPagesMB DECIMAL(28,4),

    @TotalServerMemoryMB DECIMAL(28,4),
    @TargetServerMemoryMB DECIMAL(28,4),
    @MemoryGrantsPending BIGINT,
    @MemoryGrantsOutstanding BIGINT,
    @GrantedWorkspaceMB DECIMAL(28,4),

    @PLE BIGINT,
    @BufferCacheHit BIGINT,
    @BufferCacheBase BIGINT,
    @BufferCacheHitPercent DECIMAL(28,4),

    @FreeListStalls BIGINT,
    @LazyWrites BIGINT;

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
-- SECTION 3: Operating System Memory
------------------------------------------------------------

BEGIN TRY

    SELECT
        @TotalMemoryMB =
            total_physical_memory_kb / 1024.0,

        @AvailableMemoryMB =
            available_physical_memory_kb / 1024.0,

        @OSMemoryLow =
            system_low_memory_signal_state

    FROM sys.dm_os_sys_memory;

    SET @MemoryUsedPercent =
        (@TotalMemoryMB - @AvailableMemoryMB)
        * 100.0 / NULLIF(@TotalMemoryMB, 0);

    INSERT INTO @Metrics
    SELECT
        M.MetricID,
        'Memory',
        'Instance',
        @ServerName,
        M.MetricName,
        M.MetricValue,
        M.MetricUnit,
        CASE
            WHEN M.MetricValue IS NULL THEN 'UNKNOWN'
            ELSE 'SUCCESS'
        END,
        NULL
    FROM
    (
        VALUES

        (
            'MEM-001',
            'Total Physical Memory',
            @TotalMemoryMB,
            'MB'
        ),
        (
            'MEM-002',
            'Available Physical Memory',
            @AvailableMemoryMB,
            'MB'
        ),
        (
            'MEM-003',
            'OS Memory Utilization',
            @MemoryUsedPercent,
            'Percent'
        ),
        (
            'MEM-007',
            'OS Low Memory Signal',
            CONVERT(DECIMAL(28,4), @OSMemoryLow),
            'Boolean'
        )

    ) AS M
    (
        MetricID,
        MetricName,
        MetricValue,
        MetricUnit
    );

END TRY

BEGIN CATCH

    INSERT INTO @Metrics
    SELECT
        M.MetricID,
        'Memory',
        'Instance',
        @ServerName,
        M.MetricName,
        NULL,
        M.MetricUnit,
        'FAILED',
        ERROR_MESSAGE()
    FROM
    (
        VALUES
        ('MEM-001', 'Total Physical Memory', 'MB'),
        ('MEM-002', 'Available Physical Memory', 'MB'),
        ('MEM-003', 'OS Memory Utilization', 'Percent'),
        ('MEM-007', 'OS Low Memory Signal', 'Boolean')

    ) AS M
    (
        MetricID,
        MetricName,
        MetricUnit
    );

END CATCH;

------------------------------------------------------------
-- SECTION 4: SQL Server Process Memory
------------------------------------------------------------

BEGIN TRY

    SELECT
        @SQLMemoryMB =
            physical_memory_in_use_kb / 1024.0,

        @ProcessPhysicalLow =
            process_physical_memory_low,

        @ProcessVirtualLow =
            process_virtual_memory_low,

        @LockedPagesMB =
            locked_page_allocations_kb / 1024.0

    FROM sys.dm_os_process_memory;

    INSERT INTO @Metrics
    SELECT
        M.MetricID,
        'Memory',
        'Instance',
        @ServerName,
        M.MetricName,
        M.MetricValue,
        M.MetricUnit,
        CASE
            WHEN M.MetricValue IS NULL THEN 'UNKNOWN'
            ELSE 'SUCCESS'
        END,
        NULL
    FROM
    (
        VALUES

        (
            'MEM-004',
            'SQL Server Physical Memory Usage',
            @SQLMemoryMB,
            'MB'
        ),
        (
            'MEM-008',
            'SQL Process Physical Memory Pressure',
            CONVERT(DECIMAL(28,4), @ProcessPhysicalLow),
            'Boolean'
        ),
        (
            'MEM-009',
            'SQL Process Virtual Memory Pressure',
            CONVERT(DECIMAL(28,4), @ProcessVirtualLow),
            'Boolean'
        ),
        (
            'MEM-010',
            'Locked Page Allocations',
            @LockedPagesMB,
            'MB'
        )

    ) AS M
    (
        MetricID,
        MetricName,
        MetricValue,
        MetricUnit
    );

END TRY

BEGIN CATCH

    INSERT INTO @Metrics
    SELECT
        M.MetricID,
        'Memory',
        'Instance',
        @ServerName,
        M.MetricName,
        NULL,
        M.MetricUnit,
        'FAILED',
        ERROR_MESSAGE()
    FROM
    (
        VALUES
        ('MEM-004',
         'SQL Server Physical Memory Usage', 'MB'),

        ('MEM-008',
         'SQL Process Physical Memory Pressure', 'Boolean'),

        ('MEM-009',
         'SQL Process Virtual Memory Pressure', 'Boolean'),

        ('MEM-010',
         'Locked Page Allocations', 'MB')

    ) AS M
    (
        MetricID,
        MetricName,
        MetricUnit
    );

END CATCH;

------------------------------------------------------------
-- SECTION 5: Memory Configuration
------------------------------------------------------------

BEGIN TRY

    SELECT
        @MaxMemoryMB = MAX(CASE
            WHEN name = 'max server memory (MB)'
            THEN CONVERT(BIGINT, value_in_use)
        END),

        @MinMemoryMB = MAX(CASE
            WHEN name = 'min server memory (MB)'
            THEN CONVERT(BIGINT, value_in_use)
        END)

    FROM sys.configurations;

    INSERT INTO @Metrics
    SELECT
        M.MetricID,
        'Memory',
        'Instance',
        @ServerName,
        M.MetricName,
        M.MetricValue,
        'MB',
        CASE
            WHEN M.MetricValue IS NULL THEN 'UNKNOWN'
            ELSE 'SUCCESS'
        END,
        NULL
    FROM
    (
        VALUES
        (
            'MEM-005',
            'Configured Maximum Server Memory',
            CONVERT(DECIMAL(28,4), @MaxMemoryMB)
        ),
        (
            'MEM-006',
            'Configured Minimum Server Memory',
            CONVERT(DECIMAL(28,4), @MinMemoryMB)
        )

    ) AS M
    (
        MetricID,
        MetricName,
        MetricValue
    );

END TRY

BEGIN CATCH

    INSERT INTO @Metrics
    SELECT
        M.MetricID,
        'Memory',
        'Instance',
        @ServerName,
        M.MetricName,
        NULL,
        'MB',
        'FAILED',
        ERROR_MESSAGE()
    FROM
    (
        VALUES
        ('MEM-005', 'Configured Maximum Server Memory'),
        ('MEM-006', 'Configured Minimum Server Memory')

    ) AS M
    (
        MetricID,
        MetricName
    );

END CATCH;

------------------------------------------------------------
-- SECTION 6: Memory Performance Counters
------------------------------------------------------------

BEGIN TRY

    SELECT
        @TotalServerMemoryMB = MAX(CASE
            WHEN counter_name = 'Total Server Memory (KB)'
            THEN cntr_value / 1024.0 END),

        @TargetServerMemoryMB = MAX(CASE
            WHEN counter_name = 'Target Server Memory (KB)'
            THEN cntr_value / 1024.0 END),

        @MemoryGrantsPending = MAX(CASE
            WHEN counter_name = 'Memory Grants Pending'
            THEN cntr_value END),

        @MemoryGrantsOutstanding = MAX(CASE
            WHEN counter_name = 'Memory Grants Outstanding'
            THEN cntr_value END),

        @GrantedWorkspaceMB = MAX(CASE
            WHEN counter_name = 'Granted Workspace Memory (KB)'
            THEN cntr_value / 1024.0 END)

    FROM sys.dm_os_performance_counters

    WHERE RTRIM(object_name) LIKE '%:Memory Manager'
    AND RTRIM(instance_name) = '';

    SELECT
        @PLE = MAX(CASE
            WHEN counter_name = 'Page life expectancy'
            THEN cntr_value END),

        @BufferCacheHit = MAX(CASE
            WHEN counter_name = 'Buffer cache hit ratio'
            AND cntr_type = 537003264
            THEN cntr_value END),

        @BufferCacheBase = MAX(CASE
            WHEN counter_name = 'Buffer cache hit ratio base'
            AND cntr_type = 1073939712
            THEN cntr_value END),

        @FreeListStalls = MAX(CASE
            WHEN counter_name = 'Free list stalls/sec'
            AND cntr_type IN (272696320, 272696576)
            THEN cntr_value END),

        @LazyWrites = MAX(CASE
            WHEN counter_name = 'Lazy writes/sec'
            AND cntr_type IN (272696320, 272696576)
            THEN cntr_value END)

    FROM sys.dm_os_performance_counters

    WHERE RTRIM(object_name) LIKE '%:Buffer Manager'
    AND RTRIM(instance_name) = '';

    SET @BufferCacheHitPercent =
        CONVERT(DECIMAL(28,4), @BufferCacheHit)
        * 100.0 / NULLIF(@BufferCacheBase, 0);

    IF @BufferCacheHitPercent NOT BETWEEN 0 AND 100
        SET @BufferCacheHitPercent = NULL;

    INSERT INTO @Metrics
    SELECT
        M.MetricID,
        'Memory',
        'Instance',
        @ServerName,
        M.MetricName,
        M.MetricValue,
        M.MetricUnit,

        CASE
            WHEN M.MetricValue IS NULL THEN 'UNKNOWN'
            ELSE 'SUCCESS'
        END,

        CASE
            WHEN M.MetricValue IS NULL
                THEN 'Performance counter unavailable or invalid.'
            ELSE NULL
        END

    FROM
    (
        VALUES

        (
            'MEM-011',
            'Total Server Memory',
            @TotalServerMemoryMB,
            'MB'
        ),
        (
            'MEM-012',
            'Target Server Memory',
            @TargetServerMemoryMB,
            'MB'
        ),
        (
            'MEM-013',
            'Memory Grants Pending',
            CONVERT(DECIMAL(28,4), @MemoryGrantsPending),
            'Count'
        ),
        (
            'MEM-014',
            'Memory Grants Outstanding',
            CONVERT(DECIMAL(28,4), @MemoryGrantsOutstanding),
            'Count'
        ),
        (
            'MEM-015',
            'Granted Workspace Memory',
            @GrantedWorkspaceMB,
            'MB'
        ),
        (
            'MEM-016',
            'Page Life Expectancy',
            CONVERT(DECIMAL(28,4), @PLE),
            'Seconds'
        ),
        (
            'MEM-017',
            'Buffer Cache Hit Ratio',
            @BufferCacheHitPercent,
            'Percent'
        ),
        (
            'MEM-018',
            'Free List Stalls Cumulative',
            CONVERT(DECIMAL(28,4), @FreeListStalls),
            'CumulativeCount'
        ),
        (
            'MEM-019',
            'Lazy Writes Cumulative',
            CONVERT(DECIMAL(28,4), @LazyWrites),
            'CumulativeCount'
        )

    ) AS M
    (
        MetricID,
        MetricName,
        MetricValue,
        MetricUnit
    );

END TRY

BEGIN CATCH

    INSERT INTO @Metrics
    SELECT
        M.MetricID,
        'Memory',
        'Instance',
        @ServerName,
        M.MetricName,
        NULL,
        M.MetricUnit,
        'FAILED',
        ERROR_MESSAGE()

    FROM
    (
        VALUES

        ('MEM-011', 'Total Server Memory', 'MB'),
        ('MEM-012', 'Target Server Memory', 'MB'),
        ('MEM-013', 'Memory Grants Pending', 'Count'),
        ('MEM-014', 'Memory Grants Outstanding', 'Count'),
        ('MEM-015', 'Granted Workspace Memory', 'MB'),
        ('MEM-016', 'Page Life Expectancy', 'Seconds'),
        ('MEM-017', 'Buffer Cache Hit Ratio', 'Percent'),
        ('MEM-018', 'Free List Stalls Cumulative',
         'CumulativeCount'),
        ('MEM-019', 'Lazy Writes Cumulative',
         'CumulativeCount')

    ) AS M
    (
        MetricID,
        MetricName,
        MetricUnit
    );

END CATCH;

------------------------------------------------------------
-- SECTION 7: Collection Performance
------------------------------------------------------------

INSERT INTO @Metrics
VALUES
(
    'MEM-020',
    'Collection',
    'Instance',
    @ServerName,
    'Collector Execution Duration',

    DATEDIFF(
        MILLISECOND,
        @CollectionStart,
        SYSUTCDATETIME()
    ),

    'Milliseconds',
    'SUCCESS',
    NULL
);

------------------------------------------------------------
-- SECTION 8: Standardized Monitoring Output
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
