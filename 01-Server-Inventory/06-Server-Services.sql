/*
============================================================
Project : SQL Server Production Optimization
Module  : 01 - Server Inventory
Script  : 06-Server-Services.sql
Purpose : Collect SQL Server service configuration
Type    : Read-Only Assessment
============================================================
*/

USE master;
GO

SET NOCOUNT ON;

------------------------------------------------------------
-- SECTION 1: SQL Server Services Inventory
------------------------------------------------------------

SELECT
    SYSDATETIME() AS CaptureDate,
    @@SERVERNAME AS ServerName,
    S.servicename AS ServiceName,
    S.status_desc AS ServiceStatus,
    S.startup_type_desc AS StartupType,
    S.service_account AS ServiceAccount,
    S.process_id AS ProcessID,
    S.last_startup_time AS LastStartupTime,
    S.filename AS ExecutablePath,
    S.is_clustered AS IsClustered,
    S.cluster_nodename AS ClusterNodeName,

    CASE
        WHEN S.instant_file_initialization_enabled = 'Y'
            THEN 'Enabled'
        WHEN S.instant_file_initialization_enabled = 'N'
            THEN 'Disabled'
        ELSE 'Not Applicable'
    END AS InstantFileInitialization,

    CASE
        WHEN S.status_desc = 'Running'
            THEN 'RUNNING'

        WHEN S.status_desc = 'Stopped'
         AND S.startup_type_desc = 'Automatic'
            THEN 'WARNING - Review Stopped Service'

        WHEN S.status_desc = 'Stopped'
         AND S.startup_type_desc = 'Disabled'
            THEN 'REVIEW - Disabled Service'

        WHEN S.status_desc = 'Stopped'
            THEN 'REVIEW - Stopped Service'

        ELSE 'REVIEW'
    END AS HealthStatus

FROM sys.dm_server_services AS S

ORDER BY S.servicename;

------------------------------------------------------------
-- SECTION 2: SQL Server Service Summary
------------------------------------------------------------

SELECT
    SYSDATETIME() AS CaptureDate,
    @@SERVERNAME AS ServerName,

    COUNT(*) AS TotalServices,

    COUNT(CASE
        WHEN status_desc = 'Running'
        THEN 1 END) AS RunningServices,

    COUNT(CASE
        WHEN status_desc = 'Stopped'
        THEN 1 END) AS StoppedServices,

    COUNT(CASE
        WHEN startup_type_desc = 'Automatic'
        THEN 1 END) AS AutomaticServices,

    COUNT(CASE
        WHEN startup_type_desc = 'Manual'
        THEN 1 END) AS ManualServices,

    COUNT(CASE
        WHEN startup_type_desc = 'Disabled'
        THEN 1 END) AS DisabledServices,

    COUNT(CASE
        WHEN status_desc = 'Stopped'
        AND startup_type_desc = 'Automatic'
        THEN 1 END) AS ServicesRequiringAttention

FROM sys.dm_server_services;

GO
