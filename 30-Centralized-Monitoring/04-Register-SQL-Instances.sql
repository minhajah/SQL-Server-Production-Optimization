/*
============================================================
Project : SQL Server Production Optimization
Module  : 30 - Centralized Monitoring
Script  : 04-Register-SQL-Instances.sql
Purpose : Register monitored SQL Server instances
Type    : Central Repository Deployment
Impact  : Configuration records in DBA_Monitoring only
Version : 1.0
============================================================

IMPORTANT:

1. Execute ONLY on the approved central monitoring instance.
2. Execute after 03-Create-Monitoring-Indexes.sql.
3. Do NOT execute on monitored production instances.
4. Never upload actual production connection details to GitHub.
5. Never store passwords in this script.
6. New instances remain disabled by default.
7. Registration does not initiate remote connections.

============================================================
*/

USE [DBA_Monitoring];
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;

------------------------------------------------------------
-- SECTION 1: Deployment Configuration
------------------------------------------------------------

DECLARE
    @ApprovedMonitoringServer NVARCHAR(128) =
        N'REPLACE_WITH_APPROVED_SERVER_NAME',

    @AllowDeployment BIT = 0,

    @ActualServer NVARCHAR(128),

    @DeploymentStart DATETIME2(3) =
        SYSUTCDATETIME(),

    @InstancesRegistered INT = 0,

    @InstancesSkipped INT = 0;

SET @ActualServer =
    CONVERT(NVARCHAR(128), SERVERPROPERTY('ServerName'));

------------------------------------------------------------
-- SECTION 2: Deployment Safety Validation
------------------------------------------------------------

IF @AllowDeployment <> 1
BEGIN

    THROW 50001,
        'Deployment disabled. Review deployment parameters.',
        1;

END;

IF @ApprovedMonitoringServer =
    N'REPLACE_WITH_APPROVED_SERVER_NAME'
BEGIN

    THROW 50002,
        'Approved monitoring server must be configured.',
        1;

END;

IF @ActualServer IS NULL
   OR @ActualServer <> @ApprovedMonitoringServer
BEGIN

    THROW 50003,
        'Connected instance is not the approved monitoring server.',
        1;

END;

IF DB_NAME() <> N'DBA_Monitoring'
BEGIN

    THROW 50004,
        'Incorrect database context.',
        1;

END;

IF ISNULL
(
    TRY_CONVERT
    (
        INT,
        SERVERPROPERTY('ProductMajorVersion')
    ),
    0
) < 15
BEGIN

    THROW 50005,
        'SQL Server 2019 or later is required.',
        1;

END;

IF DATABASEPROPERTYEX
(
    DB_NAME(),
    'Updateability'
) <> 'READ_WRITE'
BEGIN

    THROW 50006,
        'Monitoring database must be writable.',
        1;

END;

IF @@TRANCOUNT <> 0
BEGIN

    THROW 50007,
        'Execute registration outside an existing transaction.',
        1;

END;

------------------------------------------------------------
-- SECTION 3: Repository Validation
------------------------------------------------------------

IF OBJECT_ID('dbo.MonitoredInstances', 'U') IS NULL

OR OBJECT_ID('dbo.MonitoringSettings', 'U') IS NULL

OR OBJECT_ID('dbo.SchemaVersion', 'U') IS NULL

OR OBJECT_ID('dbo.CollectionRuns', 'U') IS NULL

BEGIN

    THROW 50008,
        'Required monitoring repository tables are missing.',
        1;

END;

IF NOT EXISTS
(
    SELECT 1

    FROM dbo.SchemaVersion

    WHERE VersionNumber = '1.0.1'
)
BEGIN

    THROW 50009,
        'Required monitoring repository version not found.',
        1;

END;

------------------------------------------------------------
-- SECTION 4: Monitoring Safety Validation
------------------------------------------------------------

IF NOT EXISTS
(
    SELECT 1

    FROM dbo.MonitoringSettings

    WHERE SettingKey = 'MonitoringEnabled'
      AND SettingValue = N'0'
)
BEGIN

    THROW 50010,
        'Monitoring must be disabled before instance registration.',
        1;

END;

IF EXISTS
(
    SELECT 1

    FROM dbo.CollectionRuns

    WHERE RunStatus = 'RUNNING'
)
BEGIN

    THROW 50011,
        'Active collection runs exist. Review before registration.',
        1;

END;

------------------------------------------------------------
-- SECTION 5: Instance Registration Structure
------------------------------------------------------------

DECLARE @Instances TABLE
(
    InstanceName NVARCHAR(128) NOT NULL,

    ConnectionTarget NVARCHAR(256) NOT NULL,

    ServerName NVARCHAR(128) NULL,

    Environment VARCHAR(20) NOT NULL,

    SQLVersion NVARCHAR(50) NULL,

    SQLMajorVersion INT NULL,

    SQLEdition NVARCHAR(128) NULL,

    TimeZoneName NVARCHAR(128) NULL,

    AuthenticationType VARCHAR(30) NOT NULL,

    CredentialReference NVARCHAR(256) NULL,

    ConnectionTimeoutSeconds INT NOT NULL,

    IsPilotInstance BIT NOT NULL,

    Notes NVARCHAR(1000) NULL
);

------------------------------------------------------------
-- SECTION 6: Instance Registration Input
------------------------------------------------------------

/*
The following entries are EXAMPLES ONLY.

Replace them in a private deployment copy with
approved SQL Server instance details.

Do not commit actual production information to GitHub.

SQL version, edition and actual server identity may
remain NULL until connectivity validation is performed.

The script does not establish remote connections.
*/

INSERT INTO @Instances
(
    InstanceName,
    ConnectionTarget,
    ServerName,
    Environment,
    SQLVersion,
    SQLMajorVersion,
    SQLEdition,
    TimeZoneName,
    AuthenticationType,
    CredentialReference,
    ConnectionTimeoutSeconds,
    IsPilotInstance,
    Notes
)
VALUES
(
    N'EXAMPLE-TEST-SQL-01',
    N'REPLACE_WITH_TEST_SQL_HOST',
    NULL,
    'TEST',
    NULL,
    NULL,
    NULL,
    N'Arab Standard Time',
    'WINDOWS',
    NULL,
    15,
    1,
    N'Initial non-production validation instance.'
),
(
    N'EXAMPLE-PROD-SQL-01',
    N'REPLACE_WITH_PRODUCTION_SQL_HOST',
    NULL,
    'PRODUCTION',
    NULL,
    NULL,
    NULL,
    N'Arab Standard Time',
    'WINDOWS',
    NULL,
    15,
    0,
    N'Production instance. Monitoring disabled.'
),
(
    N'EXAMPLE-DR-SQL-01',
    N'REPLACE_WITH_DR_SQL_HOST',
    NULL,
    'DR',
    NULL,
    NULL,
    NULL,
    N'Arab Standard Time',
    'WINDOWS',
    NULL,
    15,
    0,
    N'Disaster recovery instance. Monitoring disabled.'
);

------------------------------------------------------------
-- SECTION 7: Registration Input Validation
------------------------------------------------------------

IF NOT EXISTS
(
    SELECT 1
    FROM @Instances
)
BEGIN

    THROW 50012,
        'No instances supplied for registration.',
        1;

END;

------------------------------------------------------------
-- Prevent example records from being deployed
------------------------------------------------------------

IF EXISTS
(
    SELECT 1

    FROM @Instances

    WHERE InstanceName LIKE N'EXAMPLE-%'

       OR ConnectionTarget LIKE N'REPLACE[_]WITH%'

       OR NULLIF(
            LTRIM(RTRIM(InstanceName)), N''
          ) IS NULL

       OR NULLIF(
            LTRIM(RTRIM(ConnectionTarget)), N''
          ) IS NULL
)
BEGIN

    THROW 50013,
        'Placeholder or invalid instance registration values detected.',
        1;

END;

------------------------------------------------------------
-- Duplicate instance name validation
------------------------------------------------------------

IF EXISTS
(
    SELECT InstanceName

    FROM @Instances

    GROUP BY InstanceName

    HAVING COUNT(*) > 1
)
BEGIN

    THROW 50014,
        'Duplicate instance names detected in registration input.',
        1;

END;

------------------------------------------------------------
-- Duplicate connection target validation
------------------------------------------------------------

IF EXISTS
(
    SELECT ConnectionTarget

    FROM @Instances

    GROUP BY ConnectionTarget

    HAVING COUNT(*) > 1
)
BEGIN

    THROW 50015,
        'Duplicate connection targets detected.',
        1;

END;

------------------------------------------------------------
-- Environment validation
------------------------------------------------------------

IF EXISTS
(
    SELECT 1

    FROM @Instances

    WHERE Environment NOT IN
    (
        'PRODUCTION',
        'DR',
        'UAT',
        'TEST',
        'DEVELOPMENT'
    )
)
BEGIN

    THROW 50016,
        'Invalid environment classification.',
        1;

END;

------------------------------------------------------------
-- Authentication validation
------------------------------------------------------------

IF EXISTS
(
    SELECT 1

    FROM @Instances

    WHERE AuthenticationType NOT IN
    (
        'WINDOWS',
        'SQL'
    )
)
BEGIN

    THROW 50017,
        'Unsupported authentication type.',
        1;

END;

------------------------------------------------------------
-- Credential reference validation
------------------------------------------------------------

IF EXISTS
(
    SELECT 1

    FROM @Instances

    WHERE AuthenticationType = 'SQL'

      AND NULLIF
      (
          LTRIM(RTRIM(CredentialReference)),
          N''
      ) IS NULL
)
BEGIN

    THROW 50018,
        'SQL authentication requires an external credential reference.',
        1;

END;

------------------------------------------------------------
-- Connection timeout validation
------------------------------------------------------------

IF EXISTS
(
    SELECT 1

    FROM @Instances

    WHERE ConnectionTimeoutSeconds
        NOT BETWEEN 1 AND 300
)
BEGIN

    THROW 50019,
        'Connection timeout must be between 1 and 300 seconds.',
        1;

END;

------------------------------------------------------------
-- Prevent self-monitoring by accidental registration
------------------------------------------------------------

IF EXISTS
(
    SELECT 1

    FROM @Instances

    WHERE ConnectionTarget = @ActualServer

       OR ServerName = @ActualServer
)
BEGIN

    THROW 50020,
        'Central monitoring server registration requires separate review.',
        1;

END;

------------------------------------------------------------
-- SECTION 8: Registration Result Structure
------------------------------------------------------------

DECLARE @RegistrationResults TABLE
(
    InstanceName NVARCHAR(128),

    ConnectionTarget NVARCHAR(256),

    RegistrationStatus VARCHAR(30),

    Details NVARCHAR(2048)
);

------------------------------------------------------------
-- SECTION 9: Register SQL Server Instances
------------------------------------------------------------

BEGIN TRY

    BEGIN TRANSACTION;

    --------------------------------------------------------
    -- Protect existing instance configuration
    --------------------------------------------------------

    IF EXISTS
    (
        SELECT 1

        FROM @Instances AS S

        INNER JOIN dbo.MonitoredInstances AS T
            WITH (UPDLOCK, HOLDLOCK)

            ON T.InstanceName = S.InstanceName

        WHERE T.ConnectionTarget <>
              S.ConnectionTarget
    )
    BEGIN

        THROW 50021,
            'Existing instance name has a different connection target.',
            1;

    END;

    IF EXISTS
    (
        SELECT 1

        FROM @Instances AS S

        INNER JOIN dbo.MonitoredInstances AS T
            WITH (UPDLOCK, HOLDLOCK)

            ON T.ConnectionTarget =
               S.ConnectionTarget

        WHERE T.InstanceName <> S.InstanceName
    )
    BEGIN

        THROW 50022,
            'Connection target already belongs to another registered instance.',
            1;

    END;

    --------------------------------------------------------
    -- Record existing registrations
    --------------------------------------------------------

    INSERT INTO @RegistrationResults
    SELECT
        S.InstanceName,
        S.ConnectionTarget,
        'ALREADY EXISTS',
        N'Existing configuration preserved.'

    FROM @Instances AS S

    INNER JOIN dbo.MonitoredInstances AS T
        WITH (UPDLOCK, HOLDLOCK)

        ON T.InstanceName = S.InstanceName

       AND T.ConnectionTarget =
           S.ConnectionTarget;

    SET @InstancesSkipped = @@ROWCOUNT;

    --------------------------------------------------------
    -- Register new instances
    --------------------------------------------------------

    INSERT INTO dbo.MonitoredInstances
    (
        InstanceName,
        ConnectionTarget,
        ServerName,
        Environment,
        SQLVersion,
        SQLMajorVersion,
        SQLEdition,
        TimeZoneName,
        AuthenticationType,
        CredentialReference,
        ConnectionTimeoutSeconds,
        IsEnabled,
        IsPilotInstance,
        Notes
    )

    OUTPUT

        inserted.InstanceName,

        inserted.ConnectionTarget,

        'REGISTERED',

        N'Instance registered with monitoring disabled.'

    INTO @RegistrationResults
    (
        InstanceName,
        ConnectionTarget,
        RegistrationStatus,
        Details
    )

    SELECT
        S.InstanceName,
        S.ConnectionTarget,
        S.ServerName,
        S.Environment,
        S.SQLVersion,
        S.SQLMajorVersion,
        S.SQLEdition,
        S.TimeZoneName,
        S.AuthenticationType,
        S.CredentialReference,
        S.ConnectionTimeoutSeconds,

        0,

        S.IsPilotInstance,
        S.Notes

    FROM @Instances AS S

    WHERE NOT EXISTS
    (
        SELECT 1

        FROM dbo.MonitoredInstances AS T
            WITH (UPDLOCK, HOLDLOCK)

        WHERE T.InstanceName = S.InstanceName
    );

    SET @InstancesRegistered = @@ROWCOUNT;

    --------------------------------------------------------
    -- SECTION 10: Commit Registration
    --------------------------------------------------------

    COMMIT TRANSACTION;

    SELECT
        @ActualServer AS MonitoringServer,

        DB_NAME() AS MonitoringDatabase,

        'SUCCESS' AS DeploymentStatus,

        @InstancesRegistered AS InstancesRegistered,

        @InstancesSkipped AS ExistingInstancesSkipped,

        DATEDIFF_BIG
        (
            MILLISECOND,
            @DeploymentStart,
            SYSUTCDATETIME()
        ) AS ExecutionDurationMS,

        SYSUTCDATETIME() AS ExecutionDateUTC;

END TRY

BEGIN CATCH

    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    SELECT
        @ActualServer AS MonitoringServer,

        DB_NAME() AS MonitoringDatabase,

        'FAILED' AS DeploymentStatus,

        ERROR_NUMBER() AS ErrorNumber,

        ERROR_LINE() AS ErrorLine,

        ERROR_MESSAGE() AS ErrorMessage,

        SYSUTCDATETIME() AS ErrorDateUTC;

    THROW;

END CATCH;

------------------------------------------------------------
-- SECTION 11: Instance Registration Results
------------------------------------------------------------

SELECT
    InstanceName,
    ConnectionTarget,
    RegistrationStatus,
    Details

FROM @RegistrationResults

ORDER BY InstanceName;

------------------------------------------------------------
-- SECTION 12: Registered Instance Verification
------------------------------------------------------------

SELECT
    InstanceID,

    InstanceName,

    ConnectionTarget,

    ServerName,

    Environment,

    SQLVersion,

    SQLMajorVersion,

    SQLEdition,

    TimeZoneName,

    AuthenticationType,

    CASE

        WHEN CredentialReference IS NULL
            THEN 'NOT CONFIGURED'

        ELSE 'CONFIGURED'

    END AS CredentialReferenceStatus,

    ConnectionTimeoutSeconds,

    IsEnabled,

    IsPilotInstance,

    CreatedDateUTC,

    ModifiedDateUTC,

    Notes

FROM dbo.MonitoredInstances

ORDER BY
    Environment,
    InstanceName;

------------------------------------------------------------
-- SECTION 13: Registration Summary
------------------------------------------------------------

SELECT
    Environment,

    COUNT_BIG(*) AS TotalInstances,

    COUNT_BIG
    (
        CASE
            WHEN IsEnabled = 1 THEN 1
        END
    ) AS EnabledInstances,

    COUNT_BIG
    (
        CASE
            WHEN IsEnabled = 0 THEN 1
        END
    ) AS DisabledInstances,

    COUNT_BIG
    (
        CASE
            WHEN IsPilotInstance = 1 THEN 1
        END
    ) AS PilotInstances

FROM dbo.MonitoredInstances

GROUP BY Environment

ORDER BY Environment;

GO
