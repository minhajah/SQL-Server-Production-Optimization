/*
============================================================
Project : SQL Server Production Optimization
Module  : 30 - Centralized Monitoring
Script  : 12-Repository-Security.sql
Purpose : Least-privilege central repository access
Type    : Central Repository Deployment
Impact  : Central DBA_Monitoring database only
Version : 1.0
============================================================
Run after Script 11. No remote connections or login creation.
Roles only: no user membership is assigned automatically.
Keep credentials outside GitHub and outside repository tables.
Configuration changes, registrations and user provisioning remain
with an approved DBA. Administrator role handles recovery/reset.
Existing role grants outside this manifest cause deployment failure.
Review effective permissions of actual identities before use.
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
        @MajorVersion INT = TRY_CONVERT(INT, SERVERPROPERTY('ProductMajorVersion')),
        @LockResult INT;

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
IF ISNULL(@MajorVersion, 0) < 15
    THROW 50005, 'SQL Server 2019 or later required.', 1;
IF ISNULL(CONVERT(NVARCHAR(60), DATABASEPROPERTYEX(DB_NAME(), 'Updateability')), N'') <> N'READ_WRITE'
    THROW 50006, 'Database must be writable.', 1;
IF @@TRANCOUNT <> 0 OR (@@OPTIONS & 2) = 2
    THROW 50007, 'Execute outside a transaction with implicit transactions disabled.', 1;
IF OBJECT_ID(N'dbo.SchemaVersion', N'U') IS NULL
OR OBJECT_ID(N'dbo.MonitoringSettings', N'U') IS NULL
OR OBJECT_ID(N'dbo.CollectionRuns', N'U') IS NULL
    THROW 50008, 'Repository dependencies missing.', 1;
IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE VersionNumber = '1.0.7')
    THROW 50009, 'Deploy Script 11 first.', 1;

-- SECTION 3: Explicit Permission Manifest
DECLARE @Roles TABLE (RoleName SYSNAME PRIMARY KEY);
INSERT @Roles VALUES
    (N'MonitoringCollectorRole'),
    (N'MonitoringReportingRole'),
    (N'MonitoringMaintenanceRole'),
    (N'MonitoringAdministratorRole');
DECLARE @Grants TABLE
(
    RoleName SYSNAME NOT NULL,
    PermissionName SYSNAME NOT NULL,
    SecurableClass VARCHAR(20) NOT NULL,
    ObjectName SYSNAME NOT NULL,
    PRIMARY KEY (RoleName, PermissionName, SecurableClass, ObjectName)
);
INSERT @Grants VALUES
    (N'MonitoringCollectorRole', N'EXECUTE', 'OBJECT', N'usp_CollectionRunStart'),
    (N'MonitoringCollectorRole', N'EXECUTE', 'OBJECT', N'usp_CollectionRunComplete'),
    (N'MonitoringCollectorRole', N'EXECUTE', 'OBJECT', N'usp_CollectionCheckpointGet'),
    (N'MonitoringCollectorRole', N'EXECUTE', 'OBJECT', N'usp_CollectionCheckpointSave'),
    (N'MonitoringCollectorRole', N'EXECUTE', 'OBJECT', N'usp_IngestMetricSamples'),
    (N'MonitoringCollectorRole', N'SELECT', 'OBJECT', N'vw_CollectionSchedule'),
    (N'MonitoringCollectorRole', N'SELECT', 'OBJECT', N'vw_CollectionHealth'),
    (N'MonitoringCollectorRole', N'SELECT', 'OBJECT', N'vw_InstanceOverview'),
    (N'MonitoringCollectorRole', N'EXECUTE', 'TYPE', N'MetricSampleInput'),
    (N'MonitoringCollectorRole', N'REFERENCES', 'TYPE', N'MetricSampleInput'),
    (N'MonitoringReportingRole', N'SELECT', 'OBJECT', N'vw_BackupHealth'),
    (N'MonitoringReportingRole', N'SELECT', 'OBJECT', N'vw_BlockingHealth'),
    (N'MonitoringReportingRole', N'SELECT', 'OBJECT', N'vw_CPUHealth'),
    (N'MonitoringReportingRole', N'SELECT', 'OBJECT', N'vw_CollectionHealth'),
    (N'MonitoringReportingRole', N'SELECT', 'OBJECT', N'vw_CollectionSchedule'),
    (N'MonitoringReportingRole', N'SELECT', 'OBJECT', N'vw_DatabaseHealth'),
    (N'MonitoringReportingRole', N'SELECT', 'OBJECT', N'vw_DeadlockHistory'),
    (N'MonitoringReportingRole', N'SELECT', 'OBJECT', N'vw_ErrorLogHealth'),
    (N'MonitoringReportingRole', N'SELECT', 'OBJECT', N'vw_HAHealth'),
    (N'MonitoringReportingRole', N'SELECT', 'OBJECT', N'vw_HistoricalMetricSamples'),
    (N'MonitoringReportingRole', N'SELECT', 'OBJECT', N'vw_HourlyPerformance'),
    (N'MonitoringReportingRole', N'SELECT', 'OBJECT', N'vw_InstanceHealth'),
    (N'MonitoringReportingRole', N'SELECT', 'OBJECT', N'vw_InstanceOverview'),
    (N'MonitoringReportingRole', N'SELECT', 'OBJECT', N'vw_LatestMetrics'),
    (N'MonitoringReportingRole', N'SELECT', 'OBJECT', N'vw_MemoryHealth'),
    (N'MonitoringReportingRole', N'SELECT', 'OBJECT', N'vw_QueryPerformance'),
    (N'MonitoringReportingRole', N'SELECT', 'OBJECT', N'vw_SQLAgentHealth'),
    (N'MonitoringReportingRole', N'SELECT', 'OBJECT', N'vw_SQLAgentHistory'),
    (N'MonitoringReportingRole', N'SELECT', 'OBJECT', N'vw_StorageHealth'),
    (N'MonitoringReportingRole', N'SELECT', 'OBJECT', N'vw_TempDBHealth'),
    (N'MonitoringReportingRole', N'SELECT', 'OBJECT', N'vw_TransactionLogHealth'),
    (N'MonitoringReportingRole', N'SELECT', 'OBJECT', N'vw_WaitStatistics'),
    (N'MonitoringReportingRole', N'EXECUTE', 'OBJECT', N'usp_CollectionHealthSummary'),
    (N'MonitoringReportingRole', N'EXECUTE', 'OBJECT', N'usp_CollectionCheckpointSummary'),
    (N'MonitoringReportingRole', N'EXECUTE', 'OBJECT', N'usp_DataRetentionSummary'),
    (N'MonitoringMaintenanceRole', N'EXECUTE', 'OBJECT', N'usp_AggregateHourlyMetrics'),
    (N'MonitoringMaintenanceRole', N'EXECUTE', 'OBJECT', N'usp_DataRetentionPreview'),
    (N'MonitoringMaintenanceRole', N'EXECUTE', 'OBJECT', N'usp_ExecuteDataRetention'),
    (N'MonitoringMaintenanceRole', N'EXECUTE', 'OBJECT', N'usp_DataRetentionSummary'),
    (N'MonitoringMaintenanceRole', N'EXECUTE', 'OBJECT', N'usp_MetricStorageSummary'),
    (N'MonitoringMaintenanceRole', N'SELECT', 'OBJECT', N'vw_RepositoryHealth'),
    (N'MonitoringAdministratorRole', N'EXECUTE', 'OBJECT', N'usp_CollectionRunRecover'),
    (N'MonitoringAdministratorRole', N'EXECUTE', 'OBJECT', N'usp_CollectionCheckpointReset'),
    (N'MonitoringAdministratorRole', N'EXECUTE', 'OBJECT', N'usp_CollectionHealthSummary'),
    (N'MonitoringAdministratorRole', N'EXECUTE', 'OBJECT', N'usp_CollectionCheckpointSummary'),
    (N'MonitoringAdministratorRole', N'SELECT', 'OBJECT', N'MonitoringSettings'),
    (N'MonitoringAdministratorRole', N'SELECT', 'OBJECT', N'MonitoredInstances'),
    (N'MonitoringAdministratorRole', N'SELECT', 'OBJECT', N'Collectors'),
    (N'MonitoringAdministratorRole', N'SELECT', 'OBJECT', N'InstanceCollectors'),
    (N'MonitoringAdministratorRole', N'SELECT', 'OBJECT', N'MetricDefinitions'),
    (N'MonitoringAdministratorRole', N'SELECT', 'OBJECT', N'SchemaVersion');

-- Database-level DMV permissions are confined to maintenance.
-- SQL Server 2019: VIEW DATABASE STATE + VIEW DEFINITION.
-- SQL Server 2022+: VIEW DATABASE PERFORMANCE STATE + VIEW SECURITY DEFINITION.
IF @MajorVersion = 15
    INSERT @Grants VALUES
    (N'MonitoringMaintenanceRole', N'VIEW DATABASE STATE', 'DATABASE', N''),
    (N'MonitoringMaintenanceRole', N'VIEW DEFINITION', 'DATABASE', N'');
ELSE
    INSERT @Grants VALUES
    (N'MonitoringMaintenanceRole', N'VIEW DATABASE PERFORMANCE STATE', 'DATABASE', N''),
    (N'MonitoringMaintenanceRole', N'VIEW SECURITY DEFINITION', 'DATABASE', N'');

-- SECTION 4: Resolve and Validate Dependencies
IF EXISTS
(
    SELECT 1 FROM @Grants
    WHERE (SecurableClass = 'OBJECT' AND OBJECT_ID(N'dbo.' + QUOTENAME(ObjectName)) IS NULL)
       OR (SecurableClass = 'TYPE' AND TYPE_ID(N'dbo.' + QUOTENAME(ObjectName)) IS NULL)
)
    THROW 50010, 'A required permission target is missing.', 1;

DECLARE @Expected TABLE
(
    RoleName SYSNAME NOT NULL,
    PermissionName SYSNAME NOT NULL,
    ClassID TINYINT NOT NULL,
    MajorID INT NOT NULL,
    MinorID INT NOT NULL,
    PRIMARY KEY (RoleName, PermissionName, ClassID, MajorID, MinorID)
);
INSERT @Expected
SELECT RoleName, PermissionName,
       CASE SecurableClass WHEN 'OBJECT' THEN 1 WHEN 'TYPE' THEN 6 ELSE 0 END,
       CASE SecurableClass WHEN 'OBJECT' THEN OBJECT_ID(N'dbo.' + QUOTENAME(ObjectName))
            WHEN 'TYPE' THEN TYPE_ID(N'dbo.' + QUOTENAME(ObjectName)) ELSE 0 END,
       0
FROM @Grants;

-- Collector reads only the connection metadata required for approved endpoints.
-- CredentialReference is a lookup key, never a password or connection string.
DECLARE @ConnectionColumns TABLE (ColumnName SYSNAME PRIMARY KEY);
INSERT @ConnectionColumns VALUES
    (N'InstanceID'), (N'ConnectionTarget'), (N'ServerName'),
    (N'AuthenticationType'), (N'CredentialReference'),
    (N'ConnectionTimeoutSeconds'), (N'TimeZoneName');
IF EXISTS (SELECT 1 FROM @ConnectionColumns AS C
           WHERE COL_LENGTH(N'dbo.MonitoredInstances', C.ColumnName) IS NULL)
    THROW 50011, 'Connection metadata columns missing.', 1;
INSERT @Expected
SELECT N'MonitoringCollectorRole', N'SELECT', 1,
       OBJECT_ID(N'dbo.MonitoredInstances'), C.column_id
FROM sys.columns AS C
JOIN @ConnectionColumns AS X ON X.ColumnName = C.name
WHERE C.object_id = OBJECT_ID(N'dbo.MonitoredInstances');

-- SECTION 5: Transactional Role Deployment
BEGIN TRY
    BEGIN TRANSACTION;
    EXEC @LockResult = sys.sp_getapplock
        @Resource = N'DBA_Monitoring.CollectionScheduling',
        @LockMode = 'Exclusive', @LockOwner = 'Transaction', @LockTimeout = 10000;
    IF @LockResult < 0 THROW 50012, 'Unable to acquire scheduling lock.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.MonitoringSettings WITH (UPDLOCK, HOLDLOCK)
                   WHERE SettingKey = 'MonitoringEnabled' AND SettingValue = N'0')
        THROW 50013, 'Monitoring must be disabled.', 1;
    IF EXISTS (SELECT 1 FROM dbo.CollectionRuns WHERE RunStatus = 'RUNNING')
        THROW 50014, 'Active collection runs exist.', 1;

    IF EXISTS (SELECT 1 FROM @Roles AS R JOIN sys.database_principals AS P ON P.name = R.RoleName
               WHERE P.type <> 'R' OR P.is_fixed_role = 1 OR P.owning_principal_id <> DATABASE_PRINCIPAL_ID(N'dbo'))
        THROW 50015, 'Existing role name or ownership conflict.', 1;
    IF EXISTS (SELECT 1 FROM sys.database_role_members AS M
               JOIN sys.database_principals AS P ON P.principal_id = M.member_principal_id
               JOIN @Roles AS R ON R.RoleName = P.name)
        THROW 50016, 'Monitoring roles must not inherit other database roles.', 1;
    IF EXISTS (SELECT 1 FROM sys.database_permissions AS P
               JOIN sys.database_principals AS D ON D.principal_id = P.grantee_principal_id
               JOIN @Roles AS R ON R.RoleName = D.name
               WHERE P.state <> 'G' OR NOT EXISTS
               (SELECT 1 FROM @Expected AS E WHERE E.RoleName = D.name
                AND E.PermissionName = P.permission_name AND E.ClassID = P.class
                AND E.MajorID = P.major_id AND E.MinorID = P.minor_id))
        THROW 50017, 'Unexpected existing role permissions; review manually.', 1;
    IF EXISTS (SELECT 1 FROM sys.schemas AS S JOIN sys.database_principals AS P ON P.principal_id = S.principal_id
               JOIN @Roles AS R ON R.RoleName = P.name)
       OR EXISTS (SELECT 1 FROM sys.objects AS O JOIN sys.database_principals AS P ON P.principal_id = O.principal_id
               JOIN @Roles AS R ON R.RoleName = P.name)
        THROW 50018, 'Monitoring roles must not own schemas or objects.', 1;

    DECLARE @RoleName SYSNAME, @PermissionName SYSNAME, @Class VARCHAR(20), @ObjectName SYSNAME,
            @SQL NVARCHAR(MAX), @ColumnName SYSNAME;
    DECLARE RoleCursor CURSOR LOCAL FAST_FORWARD FOR SELECT RoleName FROM @Roles ORDER BY RoleName;
    OPEN RoleCursor;
    FETCH NEXT FROM RoleCursor INTO @RoleName;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF DATABASE_PRINCIPAL_ID(@RoleName) IS NULL
        BEGIN
            SET @SQL = N'CREATE ROLE ' + QUOTENAME(@RoleName) + N' AUTHORIZATION dbo;';
            EXEC sys.sp_executesql @SQL;
        END;
        FETCH NEXT FROM RoleCursor INTO @RoleName;
    END;
    CLOSE RoleCursor;
    DEALLOCATE RoleCursor;

    DECLARE GrantCursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT RoleName, PermissionName, SecurableClass, ObjectName FROM @Grants;
    OPEN GrantCursor;
    FETCH NEXT FROM GrantCursor INTO @RoleName, @PermissionName, @Class, @ObjectName;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @SQL = N'GRANT ' + @PermissionName +
            CASE @Class WHEN 'OBJECT' THEN N' ON OBJECT::dbo.' + QUOTENAME(@ObjectName)
                        WHEN 'TYPE' THEN N' ON TYPE::dbo.' + QUOTENAME(@ObjectName)
                        ELSE N'' END + N' TO ' + QUOTENAME(@RoleName) + N';';
        EXEC sys.sp_executesql @SQL;
        FETCH NEXT FROM GrantCursor INTO @RoleName, @PermissionName, @Class, @ObjectName;
    END;
    CLOSE GrantCursor;
    DEALLOCATE GrantCursor;

    DECLARE ColumnCursor CURSOR LOCAL FAST_FORWARD FOR SELECT ColumnName FROM @ConnectionColumns;
    OPEN ColumnCursor;
    FETCH NEXT FROM ColumnCursor INTO @ColumnName;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @SQL = N'GRANT SELECT ON OBJECT::dbo.MonitoredInstances (' + QUOTENAME(@ColumnName)
                 + N') TO [MonitoringCollectorRole];';
        EXEC sys.sp_executesql @SQL;
        FETCH NEXT FROM ColumnCursor INTO @ColumnName;
    END;
    CLOSE ColumnCursor;
    DEALLOCATE ColumnCursor;

    IF EXISTS (SELECT 1 FROM @Expected AS E WHERE NOT EXISTS
       (SELECT 1 FROM sys.database_permissions AS P JOIN sys.database_principals AS D
        ON D.principal_id = P.grantee_principal_id WHERE D.name = E.RoleName
        AND P.permission_name = E.PermissionName AND P.class = E.ClassID
        AND P.major_id = E.MajorID AND P.minor_id = E.MinorID AND P.state = 'G'))
        THROW 50019, 'Permission manifest verification failed.', 1;

    IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE VersionNumber = '1.0.8')
        INSERT dbo.SchemaVersion (VersionNumber, ScriptName, AppliedBy, Description)
        VALUES ('1.0.8', N'12-Repository-Security.sql', ORIGINAL_LOGIN(),
                N'Explicit central repository roles and least-privilege permission manifest.');
    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;

-- SECTION 6: Deployment Verification (direct grants, not effective access)
SELECT R.RoleName, P.permission_name, P.state_desc, P.class_desc,
       CASE P.class WHEN 1 THEN OBJECT_NAME(P.major_id) WHEN 6 THEN TYPE_NAME(P.major_id)
            ELSE DB_NAME() END AS SecurableName,
       CASE WHEN P.class = 1 AND P.minor_id > 0 THEN COL_NAME(P.major_id, P.minor_id) END AS ColumnName
FROM @Roles AS R
JOIN sys.database_principals AS D ON D.name = R.RoleName
JOIN sys.database_permissions AS P ON P.grantee_principal_id = D.principal_id
ORDER BY R.RoleName, SecurableName, P.permission_name, ColumnName;

SELECT R.RoleName, M.name AS MemberName, M.type_desc AS MemberType
FROM @Roles AS R JOIN sys.database_principals AS D ON D.name = R.RoleName
LEFT JOIN sys.database_role_members AS RM ON RM.role_principal_id = D.principal_id
LEFT JOIN sys.database_principals AS M ON M.principal_id = RM.member_principal_id
ORDER BY R.RoleName, MemberName;

SELECT VersionNumber, ScriptName, AppliedDateUTC, AppliedBy
FROM dbo.SchemaVersion WHERE VersionNumber = '1.0.8';

/* SECTION 7: Manual provisioning and validation (not executed)
   DBA creates/maps approved database users separately; assigns one intended role.
   Do not assign collector identities to maintenance/admin roles or broad fixed roles.
   Review public grants, inherited Windows groups, server roles, ownership and direct
   permissions. Explicit role grants do not revoke privileges acquired elsewhere.
   Test with actual service identity: permitted procedure calls / TVP binding / endpoint
   metadata reads work; direct table writes, checkpoint reset, retention and configuration
   modifications fail. Test maintenance DMV access on the target SQL Server version.
   Stop service and keep monitoring/retention disabled until validation is complete.
   Remote collector permissions are a separate deployment activity.
*/
GO
