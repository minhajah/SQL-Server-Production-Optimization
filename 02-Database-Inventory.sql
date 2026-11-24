/*
============================================================
Project : SQL Server Production Optimization
Module  : 01 - Server Inventory
Script  : 02-Database-Inventory.sql
Purpose : Collect database inventory and size information
Type    : Read-Only Assessment
============================================================
*/

USE master;
GO

SET NOCOUNT ON;

WITH DatabaseSize AS
(
    SELECT
        database_id,

        SUM(CASE WHEN type = 0
            THEN CAST(size AS BIGINT)
            ELSE 0 END) * 8.0 / 1024 AS DataSizeMB,

        SUM(CASE WHEN type = 1
            THEN CAST(size AS BIGINT)
            ELSE 0 END) * 8.0 / 1024 AS LogSizeMB,

        SUM(CAST(size AS BIGINT))
            * 8.0 / 1024 AS TotalSizeMB

    FROM sys.master_files
    GROUP BY database_id
)
SELECT
    SYSDATETIME() AS CaptureDate,
    @@SERVERNAME AS ServerName,
    D.name AS DatabaseName,
    D.database_id AS DatabaseID,

    CASE
        WHEN D.database_id <= 4 THEN 'System'
        ELSE 'User'
    END AS DatabaseType,

    D.state_desc AS DatabaseStatus,
    D.recovery_model_desc AS RecoveryModel,
    D.compatibility_level AS CompatibilityLevel,
    D.create_date AS CreatedDate,
    D.collation_name AS Collation,

    CAST(S.DataSizeMB / 1024
        AS DECIMAL(18,2)) AS DataSizeGB,

    CAST(S.LogSizeMB / 1024
        AS DECIMAL(18,2)) AS LogSizeGB,

    CAST(S.TotalSizeMB / 1024
        AS DECIMAL(18,2)) AS TotalSizeGB,

    D.is_read_only AS IsReadOnly,
    D.is_auto_close_on AS AutoClose,
    D.is_auto_shrink_on AS AutoShrink,
    D.is_auto_create_stats_on AS AutoCreateStats,
    D.is_auto_update_stats_on AS AutoUpdateStats,
    D.is_auto_update_stats_async_on AS AutoUpdateStatsAsync,
    D.is_encrypted AS IsEncrypted,
    D.page_verify_option_desc AS PageVerify,
    D.log_reuse_wait_desc AS LogReuseWait,
    D.is_query_store_on AS QueryStoreEnabled,

    CASE
        WHEN D.group_database_id IS NOT NULL THEN 'Yes'
        ELSE 'No'
    END AS AvailabilityGroupMember

FROM sys.databases AS D
LEFT JOIN DatabaseSize AS S
    ON D.database_id = S.database_id

ORDER BY
    S.TotalSizeMB DESC;
GO
