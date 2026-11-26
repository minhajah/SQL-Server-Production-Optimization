/*
============================================================
Project : SQL Server Production Optimization
Module  : 30 - Centralized Monitoring
Script  : 01-Create-Monitoring-Database.sql
Purpose : Create centralized monitoring database
Type    : Central Repository Deployment
Impact  : Creates a new database on monitoring server only
Version : 1.1
============================================================

IMPORTANT:

1. Execute ONLY on the approved central monitoring instance.
2. Do NOT execute on monitored production instances.
3. Existing databases are not modified by default. Explicit recovery
   is restricted to an empty, standalone monitoring database.
   Stop deployment/monitoring and independently confirm database ownership
   before enabling recovery. The lock only serializes cooperating scripts.
4. Existing inventory application will remain unchanged.
5. Replace the approved server name before deployment.

============================================================
*/

USE master;
GO

SET NOCOUNT ON;

------------------------------------------------------------
-- SECTION 1: Deployment Configuration
------------------------------------------------------------

DECLARE
    @DatabaseName SYSNAME = N'DBA_Monitoring',

    @ApprovedMonitoringServer NVARCHAR(128) =
        N'REPLACE_WITH_APPROVED_SERVER_NAME',

    @ActualServer NVARCHAR(128),

    @AllowDeployment BIT = 0,

    @AllowResumeIncompleteDeployment BIT = 0,

    @ExistingDatabase BIT = 0,

    @ConfigurationMatches BIT = 0,

    @HasUserObjects BIT = 0,

    @LockResult INT,

    @ProductMajorVersion INT,

    @DataPath NVARCHAR(4000),

    @LogPath NVARCHAR(4000),

    @DataFile NVARCHAR(4000),

    @LogFile NVARCHAR(4000),

    @SQL NVARCHAR(MAX);

SET @ActualServer =
    CONVERT(NVARCHAR(128), SERVERPROPERTY('ServerName'));

SET @ProductMajorVersion =
    TRY_CONVERT(INT, SERVERPROPERTY('ProductMajorVersion'));

------------------------------------------------------------
-- SECTION 2: Production Safety Validation
------------------------------------------------------------

IF ISNULL(@AllowDeployment, 0) <> 1
    BEGIN

    THROW 50001,
        'Deployment disabled. Review and approve deployment parameters.',
        1;

END;

IF NULLIF
(
    LTRIM(RTRIM(@ApprovedMonitoringServer)),
    N''
) IS NULL
OR @ApprovedMonitoringServer =
    N'REPLACE_WITH_APPROVED_SERVER_NAME'
BEGIN

    THROW 50002,
        'Approved monitoring server name must be configured.',
        1;

END;

IF @ActualServer IS NULL
   OR @ActualServer <> @ApprovedMonitoringServer
BEGIN

    THROW 50003,
        'Deployment blocked. Connected instance is not the approved monitoring server.',
        1;

END;

IF ISNULL(@ProductMajorVersion, 0) < 15
BEGIN

    THROW 50004,
        'SQL Server 2019 or later is required.',
        1;

END;
IF ISNULL(@DatabaseName, N'') <> N'DBA_Monitoring'
BEGIN
    THROW 50006,
        'Invalid monitoring database name.',
        1;
END;

IF DB_NAME() <> N'master'
BEGIN
    THROW 50007,
        'Database creation must execute in master.',
        1;
END;

IF @@TRANCOUNT <> 0
BEGIN
    THROW 50008,
        'Execute outside an existing transaction.',
        1;
END;

IF (@@OPTIONS & 2) = 2
BEGIN
    THROW 50009,
        'Implicit transactions must be disabled.',
        1;
END;

------------------------------------------------------------
-- SECTION 3: Existing Database Validation
------------------------------------------------------------

-- Serialize cooperating deployment sessions on the central instance.
EXEC @LockResult = sys.sp_getapplock
    @Resource = N'DBA_Monitoring.DatabaseDeployment',
    @LockMode = 'Exclusive',
    @LockOwner = 'Session',
    @LockTimeout = 5000,
    @DbPrincipal = 'public';

IF @LockResult < 0 OR @LockResult IS NULL
    THROW 50010, 'Unable to acquire database deployment lock.', 1;

BEGIN TRY

IF DB_ID(@DatabaseName) IS NOT NULL
BEGIN
    SET @ExistingDatabase = 1;

    IF EXISTS
    (
        SELECT 1 FROM sys.databases
        WHERE name = @DatabaseName
          AND recovery_model_desc = 'SIMPLE'
          AND compatibility_level = 150
          AND is_auto_close_on = 0
          AND is_auto_shrink_on = 0
          AND is_auto_create_stats_on = 1
          AND is_auto_update_stats_on = 1
          AND page_verify_option_desc = 'CHECKSUM'
          AND is_trustworthy_on = 0
          AND is_db_chaining_on = 0
    )
        SET @ConfigurationMatches = 1;

    IF @ConfigurationMatches = 0
    BEGIN
        IF ISNULL(@AllowResumeIncompleteDeployment, 0) <> 1
            THROW 50011, 'Existing database settings differ. Review manually before authorizing recovery.', 1;

        IF NOT EXISTS
        (
            SELECT 1 FROM sys.databases
            WHERE name = @DatabaseName
              AND state = 0 AND is_read_only = 0
              AND user_access = 0 AND source_database_id IS NULL
              AND replica_id IS NULL AND group_database_id IS NULL
              AND is_published = 0 AND is_subscribed = 0
              AND is_merge_published = 0 AND is_distributor = 0
        ) OR EXISTS
        (
            SELECT 1 FROM sys.database_mirroring
            WHERE database_id = DB_ID(@DatabaseName)
              AND mirroring_guid IS NOT NULL
        )
            THROW 50012, 'Recovery requires an online, writable, standalone database.', 1;

        -- Require the original logical file layout and full metadata visibility.
        IF ISNULL(IS_SRVROLEMEMBER('sysadmin'), 0) <> 1
            THROW 50013, 'Explicit recovery requires an authorized sysadmin session.', 1;

        IF (SELECT COUNT(*) FROM sys.master_files WHERE database_id = DB_ID(@DatabaseName)) <> 2
           OR NOT EXISTS (SELECT 1 FROM sys.master_files WHERE database_id = DB_ID(@DatabaseName) AND name = N'DBA_Monitoring_Data' AND type = 0)
           OR NOT EXISTS (SELECT 1 FROM sys.master_files WHERE database_id = DB_ID(@DatabaseName) AND name = N'DBA_Monitoring_Log' AND type = 1)
            THROW 50014, 'Existing database file layout does not match the deployment script.', 1;

        EXEC sys.sp_executesql
            N'USE [DBA_Monitoring];
              SELECT @HasObjects = CASE WHEN EXISTS
              (SELECT 1 FROM sys.objects WHERE is_ms_shipped = 0)
              OR EXISTS (SELECT 1 FROM sys.types WHERE is_user_defined = 1)
              THEN 1 ELSE 0 END;',
            N'@HasObjects BIT OUTPUT', @HasObjects = @HasUserObjects OUTPUT;

        IF ISNULL(@HasUserObjects, 1) = 1
            THROW 50015, 'Repository objects already exist. Configuration changes require separate DBA review.', 1;
    END;
END;

------------------------------------------------------------
-- SECTION 4: Database File Location
------------------------------------------------------------

IF @ExistingDatabase = 0
BEGIN

SET @DataPath =
    CONVERT
    (
        NVARCHAR(4000),
        SERVERPROPERTY('InstanceDefaultDataPath')
    );

SET @LogPath =
    CONVERT
    (
        NVARCHAR(4000),
        SERVERPROPERTY('InstanceDefaultLogPath')
    );

IF NULLIF(@DataPath, '') IS NULL
   OR NULLIF(@LogPath, '') IS NULL
BEGIN

    THROW 50005,
        'Default database file locations unavailable.',
        1;

END;

------------------------------------------------------------
-- Normalize Windows directory paths
------------------------------------------------------------

IF RIGHT(@DataPath, 1) <> N'\'
    SET @DataPath = @DataPath + N'\';

IF RIGHT(@LogPath, 1) <> N'\'
    SET @LogPath = @LogPath + N'\';

SET @DataFile =
    @DataPath + N'DBA_Monitoring.mdf';

SET @LogFile =
    @LogPath + N'DBA_Monitoring_log.ldf';

------------------------------------------------------------
-- SECTION 5: Create Monitoring Database
------------------------------------------------------------

    SET @SQL =

        N'CREATE DATABASE ' + QUOTENAME(@DatabaseName) +

        N' ON PRIMARY
        (
            NAME = N''DBA_Monitoring_Data'',

            FILENAME = N''' +
            REPLACE(@DataFile, '''', '''''') + N''',

            SIZE = 512MB,

            FILEGROWTH = 256MB
        )

        LOG ON
        (
            NAME = N''DBA_Monitoring_Log'',

            FILENAME = N''' +
            REPLACE(@LogFile, '''', '''''') + N''',

            SIZE = 256MB,

            FILEGROWTH = 128MB
        );';

    EXEC sys.sp_executesql @SQL;
END;

    --------------------------------------------------------
    -- SECTION 6: Database Configuration
    --------------------------------------------------------

    IF @ConfigurationMatches = 0
    BEGIN
    ALTER DATABASE [DBA_Monitoring]
        SET RECOVERY SIMPLE;

    ALTER DATABASE [DBA_Monitoring]
        SET COMPATIBILITY_LEVEL = 150;

    ALTER DATABASE [DBA_Monitoring]
        SET AUTO_CLOSE OFF;

    ALTER DATABASE [DBA_Monitoring]
        SET AUTO_SHRINK OFF;

    ALTER DATABASE [DBA_Monitoring]
        SET AUTO_CREATE_STATISTICS ON;

    ALTER DATABASE [DBA_Monitoring]
        SET AUTO_UPDATE_STATISTICS ON;

    ALTER DATABASE [DBA_Monitoring]
        SET PAGE_VERIFY CHECKSUM;

    ALTER DATABASE [DBA_Monitoring]
        SET TRUSTWORTHY OFF;

    ALTER DATABASE [DBA_Monitoring]
        SET DB_CHAINING OFF;
    END;

    --------------------------------------------------------
    -- SECTION 7: Deployment Confirmation
    --------------------------------------------------------

    SELECT
        @ActualServer AS ServerName,
        @DatabaseName AS DatabaseName,
        CASE WHEN @ExistingDatabase = 0 THEN 'SUCCESS'
             WHEN @ConfigurationMatches = 1 THEN 'ALREADY CONFIGURED'
             ELSE 'RECOVERY COMPLETED' END AS DeploymentStatus,
        (SELECT physical_name FROM sys.master_files WHERE database_id = DB_ID(@DatabaseName) AND file_id = 1) AS DataFilePath,
        (SELECT physical_name FROM sys.master_files WHERE database_id = DB_ID(@DatabaseName) AND name = N'DBA_Monitoring_Log') AS LogFilePath,
        SYSUTCDATETIME() AS DeploymentDateUTC;

    EXEC sys.sp_releaseapplock @Resource = N'DBA_Monitoring.DatabaseDeployment', @LockOwner = 'Session', @DbPrincipal = 'public';

END TRY

BEGIN CATCH

    EXEC sys.sp_releaseapplock @Resource = N'DBA_Monitoring.DatabaseDeployment', @LockOwner = 'Session', @DbPrincipal = 'public';

    SELECT
        @ActualServer AS ServerName,
        @DatabaseName AS DatabaseName,
        'FAILED' AS DeploymentStatus,
        ERROR_NUMBER() AS ErrorNumber,
        ERROR_MESSAGE() AS ErrorMessage,
        DB_ID(@DatabaseName) AS ExistingDatabaseID,
        SYSUTCDATETIME() AS ErrorDateUTC;

    THROW;

END CATCH;

------------------------------------------------------------
-- SECTION 8: Database Configuration Verification
------------------------------------------------------------

SELECT
    name AS DatabaseName,
    state_desc AS DatabaseState,
    recovery_model_desc AS RecoveryModel,
    compatibility_level AS CompatibilityLevel,
    page_verify_option_desc AS PageVerification,
    is_auto_close_on AS AutoClose,
    is_auto_shrink_on AS AutoShrink,
    is_auto_create_stats_on AS AutoCreateStatistics,
    is_auto_update_stats_on AS AutoUpdateStatistics,
    is_trustworthy_on AS Trustworthy,
    is_db_chaining_on AS DatabaseChaining

FROM sys.databases

WHERE name = @DatabaseName;

------------------------------------------------------------
-- SECTION 9: Database File Verification
------------------------------------------------------------

SELECT
    name AS LogicalFileName,
    type_desc AS FileType,
    physical_name AS PhysicalFileName,

    CONVERT
    (
        DECIMAL(18,2),
        CONVERT(BIGINT, size) / 128.0
    ) AS FileSizeMB,

    CASE

        WHEN is_percent_growth = 1
            THEN CONCAT(growth, '%')

        ELSE CONCAT
        (
            CONVERT
            (
                DECIMAL(18,2),
                growth / 128.0
            ),
            ' MB'
        )

    END AS GrowthSetting

FROM sys.master_files

WHERE database_id = DB_ID(@DatabaseName);

GO
