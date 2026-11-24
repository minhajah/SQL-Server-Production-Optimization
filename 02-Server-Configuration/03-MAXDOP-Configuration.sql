/*
============================================================
Project : SQL Server Production Optimization
Module  : 02 - Server Configuration
Script  : 03-MAXDOP-Configuration.sql
Purpose : Assess MAXDOP and parallelism configuration
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
-- SECTION 1: CPU and NUMA Configuration
------------------------------------------------------------

SELECT
    SYSDATETIME() AS CaptureDate,
    @@SERVERNAME AS ServerName,
    cpu_count AS LogicalCPUCount,
    scheduler_count AS SchedulerCount,
    hyperthread_ratio AS HyperthreadRatio,
    max_workers_count AS MaxWorkers,
    softnuma_configuration_desc AS SoftNUMAConfiguration,
    affinity_type_desc AS CPUAffinity,
    virtual_machine_type_desc AS VirtualMachineType,
    sqlserver_start_time AS SQLServerStartTime
FROM sys.dm_os_sys_info;

------------------------------------------------------------
-- SECTION 2: NUMA Node Distribution
------------------------------------------------------------

SELECT
    SYSDATETIME() AS CaptureDate,
    @@SERVERNAME AS ServerName,
    N.node_id AS NUMANodeID,
    N.memory_node_id AS MemoryNodeID,
    N.node_state_desc AS NodeStatus,
    N.online_scheduler_count AS OnlineSchedulers,
    N.active_worker_count AS ActiveWorkers,
    N.avg_load_balance AS AverageLoadBalance
FROM sys.dm_os_nodes AS N
WHERE EXISTS
(
    SELECT 1
    FROM sys.dm_os_schedulers AS S
    WHERE S.parent_node_id = N.node_id
    AND S.status = 'VISIBLE ONLINE'
)
ORDER BY N.node_id;

------------------------------------------------------------
-- SECTION 3: MAXDOP and Parallelism Configuration
------------------------------------------------------------

SELECT
    SYSDATETIME() AS CaptureDate,
    @@SERVERNAME AS ServerName,
    name AS ConfigurationName,
    value AS ConfiguredValue,
    value_in_use AS RunningValue,
    description AS ConfigurationDescription,

    CASE
        WHEN name = 'max degree of parallelism'
         AND CONVERT(INT, value_in_use) = 0
            THEN 'REVIEW - No Explicit MAXDOP Limit'

        WHEN name = 'max degree of parallelism'
         AND CONVERT(INT, value_in_use) = 1
            THEN 'REVIEW - Serial Execution Setting'

        WHEN name = 'cost threshold for parallelism'
         AND CONVERT(INT, value_in_use) = 5
            THEN 'REVIEW - Default Cost Threshold'

        ELSE 'Configured - Validate Against Workload'
    END AS ConfigurationAssessment

FROM sys.configurations
WHERE name IN
(
    'max degree of parallelism',
    'cost threshold for parallelism',
    'max worker threads'
)
ORDER BY name;

------------------------------------------------------------
-- SECTION 4: SQL Server Scheduler Pressure
------------------------------------------------------------

SELECT
    SYSDATETIME() AS CaptureDate,
    @@SERVERNAME AS ServerName,
    scheduler_id AS SchedulerID,
    cpu_id AS CPUID,
    parent_node_id AS NUMANodeID,
    status AS SchedulerStatus,
    current_tasks_count AS CurrentTasks,
    runnable_tasks_count AS RunnableTasks,
    current_workers_count AS CurrentWorkers,
    active_workers_count AS ActiveWorkers,
    work_queue_count AS WorkQueueCount,
    pending_disk_io_count AS PendingDiskIO,

    CASE
        WHEN work_queue_count > 0
            THEN 'REVIEW - Workers Queued'

        WHEN runnable_tasks_count > 0
            THEN 'OBSERVE - Runnable Tasks Present'

        ELSE 'No Immediate Queue Detected'
    END AS SchedulerAssessment

FROM sys.dm_os_schedulers
WHERE status = 'VISIBLE ONLINE'
ORDER BY scheduler_id;

------------------------------------------------------------
-- SECTION 5: Parallelism and CPU Related Wait Statistics
------------------------------------------------------------

SELECT
    SYSDATETIME() AS CaptureDate,
    @@SERVERNAME AS ServerName,
    wait_type AS WaitType,
    waiting_tasks_count AS WaitingTasks,

    CAST(wait_time_ms / 1000.0
        AS DECIMAL(18,2)) AS TotalWait_SEC,

    CAST(signal_wait_time_ms / 1000.0
        AS DECIMAL(18,2)) AS SignalWait_SEC,

    CAST((wait_time_ms - signal_wait_time_ms) / 1000.0
        AS DECIMAL(18,2)) AS ResourceWait_SEC,

    CAST(wait_time_ms * 1.0 /
        NULLIF(waiting_tasks_count, 0)
        AS DECIMAL(18,2)) AS AverageWait_MS

FROM sys.dm_os_wait_stats
WHERE wait_type IN
(
    'CXPACKET',
    'CXCONSUMER',
    'CXSYNC_PORT',
    'CXSYNC_CONSUMER',
    'SOS_SCHEDULER_YIELD',
    'THREADPOOL'
)
ORDER BY wait_time_ms DESC;

------------------------------------------------------------
-- SECTION 6: Database-Level MAXDOP Configuration
------------------------------------------------------------

CREATE TABLE #DatabaseMAXDOP
(
    DatabaseName SYSNAME,
    MAXDOP INT NULL,
    CollectionStatus NVARCHAR(4000)
);

DECLARE
    @DatabaseName SYSNAME,
    @SQL NVARCHAR(MAX);

DECLARE DatabaseCursor CURSOR LOCAL FAST_FORWARD FOR

SELECT name
FROM sys.databases
WHERE database_id > 4
AND state_desc = 'ONLINE'
AND HAS_DBACCESS(name) = 1
AND source_database_id IS NULL;

OPEN DatabaseCursor;

FETCH NEXT FROM DatabaseCursor INTO @DatabaseName;

WHILE @@FETCH_STATUS = 0
BEGIN

    BEGIN TRY

        SET @SQL = N'
        INSERT INTO #DatabaseMAXDOP
        SELECT
            @DBName,
            CONVERT(INT, value),
            N''Collected''
        FROM ' + QUOTENAME(@DatabaseName) +
        N'.sys.database_scoped_configurations
        WHERE name = N''MAXDOP'';

        IF @@ROWCOUNT = 0
        BEGIN
            INSERT INTO #DatabaseMAXDOP
            VALUES (@DBName, NULL, N''MAXDOP not found'');
        END;';

        EXEC sys.sp_executesql
            @SQL,
            N'@DBName SYSNAME',
            @DBName = @DatabaseName;

    END TRY

    BEGIN CATCH

        INSERT INTO #DatabaseMAXDOP
        VALUES
        (
            @DatabaseName,
            NULL,
            ERROR_MESSAGE()
        );

    END CATCH;

    FETCH NEXT FROM DatabaseCursor INTO @DatabaseName;

END;

CLOSE DatabaseCursor;
DEALLOCATE DatabaseCursor;

SELECT
    SYSDATETIME() AS CaptureDate,
    @@SERVERNAME AS ServerName,
    D.name AS DatabaseName,
    M.MAXDOP AS DatabaseMAXDOP,

    CASE
        WHEN M.MAXDOP IS NULL
            THEN 'UNKNOWN - Not Collected'

        WHEN M.MAXDOP = 0
            THEN 'Inherits Server MAXDOP'

        ELSE 'Database-Level Override'
    END AS MAXDOPAssessment,

    COALESCE(M.CollectionStatus,
        'Skipped - Offline or Inaccessible')
        AS CollectionStatus

FROM sys.databases AS D

LEFT JOIN #DatabaseMAXDOP AS M
    ON D.name = M.DatabaseName

WHERE D.database_id > 4
AND D.source_database_id IS NULL
ORDER BY D.name;

DROP TABLE #DatabaseMAXDOP;

------------------------------------------------------------
-- SECTION 7: Consolidated MAXDOP Assessment
------------------------------------------------------------

DECLARE
    @CurrentMAXDOP INT,
    @CostThreshold INT,
    @OnlineSchedulers INT,
    @NUMANodes INT,
    @MinSchedulersPerNode INT,
    @MaxSchedulersPerNode INT,
    @SuggestedMAXDOP INT,
    @RunnableTasks INT,
    @QueuedWork INT;

SELECT
    @CurrentMAXDOP = CONVERT(INT, value_in_use)
FROM sys.configurations
WHERE name = 'max degree of parallelism';

SELECT
    @CostThreshold = CONVERT(INT, value_in_use)
FROM sys.configurations
WHERE name = 'cost threshold for parallelism';

SELECT
    @OnlineSchedulers = COUNT(*),
    @RunnableTasks = SUM(runnable_tasks_count),
    @QueuedWork = SUM(work_queue_count)
FROM sys.dm_os_schedulers
WHERE status = 'VISIBLE ONLINE';

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
    @MinSchedulersPerNode = MIN(SchedulerCount),
    @MaxSchedulersPerNode = MAX(SchedulerCount)
FROM NodeDistribution;

------------------------------------------------------------
-- Preliminary topology-based MAXDOP guideline
------------------------------------------------------------

SET @SuggestedMAXDOP =
    CASE

        WHEN @NUMANodes IS NULL
          OR @NUMANodes = 0
            THEN NULL

        WHEN @NUMANodes = 1
         AND @MinSchedulersPerNode <= 8
            THEN @MinSchedulersPerNode

        WHEN @NUMANodes = 1
            THEN 8

        WHEN @MinSchedulersPerNode <= 16
            THEN @MinSchedulersPerNode

        WHEN @MinSchedulersPerNode / 2 > 16
            THEN 16

        ELSE @MinSchedulersPerNode / 2

    END;

SELECT
    SYSDATETIME() AS CaptureDate,
    @@SERVERNAME AS ServerName,
    @OnlineSchedulers AS OnlineSchedulers,
    @NUMANodes AS SQLNUMANodes,
    @MinSchedulersPerNode AS MinSchedulersPerNode,
    @MaxSchedulersPerNode AS MaxSchedulersPerNode,
    @CurrentMAXDOP AS CurrentMAXDOP,
    @SuggestedMAXDOP AS TopologyMAXDOPGuideline,
    @CostThreshold AS CurrentCostThreshold,
    @RunnableTasks AS TotalRunnableTasks,
    @QueuedWork AS TotalQueuedWork,

    CASE

        WHEN @SuggestedMAXDOP IS NULL
            THEN 'UNKNOWN - CPU Topology Unavailable'

        WHEN @MinSchedulersPerNode <>
             @MaxSchedulersPerNode
            THEN 'REVIEW - Uneven NUMA Distribution'

        WHEN @CurrentMAXDOP = 0
            THEN 'REVIEW - Default MAXDOP'

        WHEN @CurrentMAXDOP > @SuggestedMAXDOP
            THEN 'REVIEW - Above Topology Guideline'

        WHEN @CostThreshold = 5
            THEN 'REVIEW - Default Cost Threshold'

        WHEN @QueuedWork > 0
            THEN 'REVIEW - Worker Queue Detected'

        ELSE 'VALIDATE CONFIGURATION AGAINST WORKLOAD'

    END AS OverallParallelismAssessment;

------------------------------------------------------------
-- Restore default session settings
------------------------------------------------------------

SET LOCK_TIMEOUT -1;
SET DEADLOCK_PRIORITY NORMAL;

GO
