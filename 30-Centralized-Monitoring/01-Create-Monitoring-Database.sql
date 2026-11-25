/*
============================================================
Project : SQL Server Production Optimization
Module  : 30 - Centralized Monitoring
Script  : 01-Create-Monitoring-Database.sql
Purpose : Create centralized monitoring database
Type    : Central Repository Deployment
Impact  : Creates a new database on monitoring server only
Version : 1.0
============================================================

IMPORTANT:

1. Execute ONLY on the approved central monitoring instance.
2. Do NOT execute on monitored production instances.
3. Existing databases will not be modified.
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

IF @AllowDeployment <> 1
BEGIN

    THROW 50001,
        'Deployment disabled. Review and approve deployment parameters.',
        1;

END;

IF @ApprovedMonitoringServer =
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

------------------------------------------------------------
-- SECTION 3: Existing Database Validation
------------------------------------------------------------

IF DB_ID(@DatabaseName) IS NOT NULL
BEGIN

    SELECT
        @ActualServer AS ServerName,
        @DatabaseName AS DatabaseName,
        'ALREADY EXISTS' AS DeploymentStatus,
        'No database changes performed.' AS Details;

    RETURN;

END;

------------------------------------------------------------
-- SECTION 4: Database File Location
------------------------------------------------------------

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

BEGIN TRY

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

    --------------------------------------------------------
    -- SECTION 6: Database Configuration
    --------------------------------------------------------

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

    --------------------------------------------------------
    -- SECTION 7: Deployment Confirmation
    --------------------------------------------------------

    SELECT
        @ActualServer AS ServerName,
        @DatabaseName AS DatabaseName,
        'SUCCESS' AS DeploymentStatus,
        @DataFile AS DataFilePath,
        @LogFile AS LogFilePath,
        SYSUTCDATETIME() AS DeploymentDateUTC;

END TRY

BEGIN CATCH

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
