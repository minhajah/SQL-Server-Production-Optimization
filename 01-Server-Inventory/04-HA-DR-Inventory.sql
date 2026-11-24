/*
============================================================
Project : SQL Server Production Optimization
Module  : 01 - Server Inventory
Script  : 04-HA-DR-Inventory.sql
Purpose : Collect HA/DR and Availability Group details
Type    : Read-Only Assessment
============================================================
*/

USE master;
GO

SET NOCOUNT ON;

------------------------------------------------------------
-- SECTION 1: HA/DR Configuration
------------------------------------------------------------

SELECT
    SYSDATETIME() AS CaptureDate,
    @@SERVERNAME AS ServerName,

    CASE SERVERPROPERTY('IsClustered')
        WHEN 1 THEN 'Yes'
        ELSE 'No'
    END AS IsClustered,

    CASE SERVERPROPERTY('IsHadrEnabled')
        WHEN 1 THEN 'Enabled'
        ELSE 'Disabled'
    END AS AlwaysOnStatus,

    CASE
        WHEN SERVERPROPERTY('IsClustered') = 1
         AND SERVERPROPERTY('IsHadrEnabled') = 1
            THEN 'FCI with AG Enabled'

        WHEN SERVERPROPERTY('IsHadrEnabled') = 1
            THEN 'AG Feature Enabled'

        WHEN SERVERPROPERTY('IsClustered') = 1
            THEN 'Failover Cluster Instance'

        ELSE 'No FCI or AG Enabled'
    END AS HAConfiguration;

------------------------------------------------------------
-- Check if Always On is enabled
------------------------------------------------------------

IF ISNULL(SERVERPROPERTY('IsHadrEnabled'), 0) <> 1
BEGIN
    PRINT 'Always On Availability Groups are not enabled.';
    RETURN;
END;

------------------------------------------------------------
-- SECTION 2: Availability Group Inventory
------------------------------------------------------------

SELECT
    SYSDATETIME() AS CaptureDate,
    @@SERVERNAME AS ServerName,
    AG.name AS AvailabilityGroupName,
    AGS.primary_replica AS PrimaryReplica,
    AGS.primary_recovery_health_desc AS RecoveryHealth,
    AGS.synchronization_health_desc AS SynchronizationHealth,
    AG.automated_backup_preference_desc AS BackupPreference,
    AG.failure_condition_level AS FailureConditionLevel,
    AG.health_check_timeout AS HealthCheckTimeout_MS

FROM sys.availability_groups AS AG

LEFT JOIN sys.dm_hadr_availability_group_states AS AGS
    ON AG.group_id = AGS.group_id

ORDER BY AG.name;

------------------------------------------------------------
-- SECTION 3: Availability Replica Inventory
------------------------------------------------------------

SELECT
    SYSDATETIME() AS CaptureDate,
    @@SERVERNAME AS ServerName,
    AG.name AS AvailabilityGroupName,
    AR.replica_server_name AS ReplicaServer,
    ARS.role_desc AS ReplicaRole,
    AR.availability_mode_desc AS AvailabilityMode,
    AR.failover_mode_desc AS FailoverMode,
    ARS.connected_state_desc AS ConnectionStatus,
    ARS.operational_state_desc AS OperationalState,
    ARS.synchronization_health_desc AS SyncHealth,
    AR.secondary_role_allow_connections_desc
        AS SecondaryConnections,
    AR.backup_priority AS BackupPriority,
    AR.session_timeout AS SessionTimeout_SEC,
    ARS.is_local AS IsLocalReplica

FROM sys.availability_groups AS AG

INNER JOIN sys.availability_replicas AS AR
    ON AG.group_id = AR.group_id

LEFT JOIN sys.dm_hadr_availability_replica_states AS ARS
    ON AR.replica_id = ARS.replica_id
    AND AR.group_id = ARS.group_id

ORDER BY
    AG.name,
    AR.replica_server_name;

------------------------------------------------------------
-- SECTION 4: AG Database Synchronization Health
------------------------------------------------------------

SELECT
    SYSDATETIME() AS CaptureDate,
    @@SERVERNAME AS ServerName,
    AG.name AS AvailabilityGroupName,
    ADC.database_name AS DatabaseName,
    AR.replica_server_name AS ReplicaServer,
    ARS.role_desc AS ReplicaRole,
    AR.availability_mode_desc AS AvailabilityMode,
    DRS.database_state_desc AS DatabaseState,
    DRS.synchronization_state_desc AS SyncState,
    DRS.synchronization_health_desc AS SyncHealth,
    DRS.is_suspended AS IsSuspended,
    DRS.suspend_reason_desc AS SuspendReason,

    CAST(DRS.log_send_queue_size / 1024.0
        AS DECIMAL(18,2)) AS LogSendQueue_MB,

    CAST(DRS.redo_queue_size / 1024.0
        AS DECIMAL(18,2)) AS RedoQueue_MB,

    DRS.log_send_rate AS LogSendRate_KB_Sec,
    DRS.redo_rate AS RedoRate_KB_Sec,
    DRS.last_commit_time AS LastCommitTime,
    DRS.last_hardened_time AS LastHardenedTime,
    DRS.last_redone_time AS LastRedoneTime,
    DRS.is_local AS IsLocalReplica,

    CASE
        WHEN DRS.is_suspended = 1
            THEN 'CRITICAL'

        WHEN DRS.database_state_desc IN
            ('SUSPECT', 'RECOVERY_PENDING', 'OFFLINE')
            THEN 'CRITICAL'

        WHEN DRS.synchronization_health_desc = 'NOT_HEALTHY'
            THEN 'CRITICAL'

        WHEN DRS.synchronization_state_desc = 'NOT SYNCHRONIZING'
            THEN 'CRITICAL'

        WHEN DRS.synchronization_health_desc = 'PARTIALLY_HEALTHY'
            THEN 'WARNING'

        WHEN DRS.synchronization_health_desc = 'HEALTHY'
            THEN 'HEALTHY'

        ELSE 'UNKNOWN'
    END AS HealthStatus

FROM sys.dm_hadr_database_replica_states AS DRS

INNER JOIN sys.availability_groups AS AG
    ON DRS.group_id = AG.group_id

INNER JOIN sys.availability_replicas AS AR
    ON DRS.replica_id = AR.replica_id
    AND DRS.group_id = AR.group_id

INNER JOIN sys.availability_databases_cluster AS ADC
    ON DRS.group_database_id = ADC.group_database_id

LEFT JOIN sys.dm_hadr_availability_replica_states AS ARS
    ON DRS.replica_id = ARS.replica_id
    AND DRS.group_id = ARS.group_id

ORDER BY
    AG.name,
    ADC.database_name,
    AR.replica_server_name;

------------------------------------------------------------
-- SECTION 5: Availability Group Listener Inventory
------------------------------------------------------------

SELECT
    SYSDATETIME() AS CaptureDate,
    @@SERVERNAME AS ServerName,
    AG.name AS AvailabilityGroupName,
    AGL.dns_name AS ListenerName,
    AGL.port AS ListenerPort,
    AGLIP.ip_address AS ListenerIPAddress,
    AGLIP.ip_subnet_mask AS SubnetMask,
    AGLIP.network_subnet_ip AS NetworkSubnet,
    AGLIP.state_desc AS IPAddressState,
    AGLIP.is_dhcp AS IsDHCP

FROM sys.availability_groups AS AG

INNER JOIN sys.availability_group_listeners AS AGL
    ON AG.group_id = AGL.group_id

LEFT JOIN sys.availability_group_listener_ip_addresses AS AGLIP
    ON AGL.listener_id = AGLIP.listener_id

ORDER BY
    AG.name,
    AGL.dns_name,
    AGLIP.ip_address;

GO
