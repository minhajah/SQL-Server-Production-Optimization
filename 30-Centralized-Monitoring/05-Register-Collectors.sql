/*
============================================================
Project : SQL Server Production Optimization
Module  : 30 - Centralized Monitoring
Script  : 05-Register-Collectors.sql
Purpose : Register monitoring collectors and instance assignments
Type    : Central Repository Deployment
Impact  : Configuration records in DBA_Monitoring only
Version : 1.0
============================================================

IMPORTANT:

1. Execute ONLY on the approved central monitoring instance.
2. Execute after 04-Register-SQL-Instances.sql.
3. Do NOT execute on monitored production instances.
4. All new collectors remain disabled by default.
5. All new instance-collector assignments remain disabled.
6. Existing collector configuration will be preserved.
7. Registration does not execute any collector scripts.

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

    @CollectorsRegistered INT = 0,

    @CollectorsSkipped INT = 0,

    @AssignmentsCreated INT = 0;

SET @ActualServer =
    CONVERT(NVARCHAR(128), SERVERPROPERTY('ServerName'));

------------------------------------------------------------
-- SECTION 2: Deployment Safety Validation
------------------------------------------------------------

IF ISNULL(@AllowDeployment, 0) <> 1
    BEGIN

    THROW 50001,
        'Deployment disabled. Review deployment parameters.',
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

IF OBJECT_ID('dbo.Collectors', 'U') IS NULL

OR OBJECT_ID('dbo.MonitoredInstances', 'U') IS NULL

OR OBJECT_ID('dbo.InstanceCollectors', 'U') IS NULL

OR OBJECT_ID('dbo.MonitoringSettings', 'U') IS NULL

OR OBJECT_ID('dbo.CollectionRuns', 'U') IS NULL

OR OBJECT_ID('dbo.SchemaVersion', 'U') IS NULL

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
        'Monitoring must be disabled before collector registration.',
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
-- SECTION 5: Collector Registration Structure
------------------------------------------------------------

DECLARE @CollectorInput TABLE
(
    CollectorCode VARCHAR(30) PRIMARY KEY,

    ModuleID VARCHAR(10) NOT NULL,

    CollectorName NVARCHAR(128) NOT NULL,

    ScriptFileName NVARCHAR(256) NOT NULL UNIQUE,

    ScriptVersion VARCHAR(20) NOT NULL,

    CollectionType VARCHAR(20) NOT NULL,

    DefaultIntervalSeconds INT NOT NULL,

    DefaultTimeoutSeconds INT NOT NULL,

    MinimumSQLMajorVersion INT NOT NULL,

    MaximumOutputRows INT NOT NULL,

    ExecutionPriority INT NOT NULL,

    Description NVARCHAR(1000) NULL
);

------------------------------------------------------------
-- SECTION 6: Module 26 Collector Configuration
------------------------------------------------------------

/*
Priority convention:

    1   = Highest scheduling priority
    100 = Lowest scheduling priority

Collection types:

    SNAPSHOT    = Point-in-time observations
    CUMULATIVE  = Includes cumulative counters
    INCREMENTAL = Requires historical event tracking

CollectionType describes the collector's primary
processing requirement. Individual metric definitions
will determine the actual storage behavior.

All collectors initially target SQL Server 2019 or later.
*/

INSERT INTO @CollectorInput
(
    CollectorCode,
    ModuleID,
    CollectorName,
    ScriptFileName,
    ScriptVersion,
    CollectionType,
    DefaultIntervalSeconds,
    DefaultTimeoutSeconds,
    MinimumSQLMajorVersion,
    MaximumOutputRows,
    ExecutionPriority,
    Description
)
VALUES

------------------------------------------------------------
-- COL-01: Instance Health
------------------------------------------------------------

(
    'COL-01',
    '26',
    N'Instance Health',
    N'01-Instance-Health-Collector.sql',
    '1.0.0',
    'SNAPSHOT',
    60,
    10,
    15,
    100,
    1,
    N'Instance availability, uptime, CPU count and memory.'
),

------------------------------------------------------------
-- COL-02: Database Health
------------------------------------------------------------

(
    'COL-02',
    '26',
    N'Database Health',
    N'02-Database-Health-Collector.sql',
    '1.0.0',
    'SNAPSHOT',
    60,
    15,
    15,
    10000,
    5,
    N'Database state, accessibility and recovery configuration.'
),

------------------------------------------------------------
-- COL-03: CPU
------------------------------------------------------------

(
    'COL-03',
    '26',
    N'CPU Performance',
    N'03-CPU-Collector.sql',
    '1.0.0',
    'SNAPSHOT',
    60,
    10,
    15,
    100,
    10,
    N'CPU utilization, runnable tasks and scheduler pressure.'
),

------------------------------------------------------------
-- COL-04: Memory
------------------------------------------------------------

(
    'COL-04',
    '26',
    N'Memory Performance',
    N'04-Memory-Collector.sql',
    '1.0.0',
    'CUMULATIVE',
    60,
    10,
    15,
    100,
    15,
    N'OS memory, SQL memory, memory grants and buffer counters.'
),

------------------------------------------------------------
-- COL-05: Storage
------------------------------------------------------------

(
    'COL-05',
    '26',
    N'Storage Performance',
    N'05-Storage-Collector.sql',
    '1.0.0',
    'CUMULATIVE',
    300,
    30,
    15,
    20000,
    20,
    N'Volume capacity and cumulative database file IO counters.'
),

------------------------------------------------------------
-- COL-06: Backup
------------------------------------------------------------

(
    'COL-06',
    '26',
    N'Backup Health',
    N'06-Backup-Collector.sql',
    '1.0.0',
    'SNAPSHOT',
    900,
    30,
    15,
    20000,
    25,
    N'Backup history, backup age and recovery configuration.'
),

------------------------------------------------------------
-- COL-07: High Availability
------------------------------------------------------------

(
    'COL-07',
    '26',
    N'High Availability Health',
    N'07-HA-Health-Collector.sql',
    '1.0.0',
    'SNAPSHOT',
    60,
    15,
    15,
    20000,
    3,
    N'Always On replica and database synchronization health.'
),

------------------------------------------------------------
-- COL-08: SQL Agent
------------------------------------------------------------

(
    'COL-08',
    '26',
    N'SQL Agent Health',
    N'08-SQL-Agent-Collector.sql',
    '1.0.0',
    'SNAPSHOT',
    300,
    20,
    15,
    20000,
    35,
    N'SQL Agent service, job status and current execution activity.'
),

------------------------------------------------------------
-- COL-09: Blocking
------------------------------------------------------------

(
    'COL-09',
    '26',
    N'Blocking Activity',
    N'09-Blocking-Collector.sql',
    '1.0.0',
    'SNAPSHOT',
    60,
    15,
    15,
    20000,
    8,
    N'Blocked requests, head blockers and active transactions.'
),

------------------------------------------------------------
-- COL-10: Transaction Log
------------------------------------------------------------

(
    'COL-10',
    '26',
    N'Transaction Log Health',
    N'10-Transaction-Log-Collector.sql',
    '1.0.0',
    'SNAPSHOT',
    300,
    30,
    15,
    20000,
    30,
    N'Transaction log utilization, reuse waits and VLF statistics.'
),

------------------------------------------------------------
-- COL-11: Deadlocks
------------------------------------------------------------

(
    'COL-11',
    '26',
    N'Deadlock Events',
    N'11-Deadlock-Collector.sql',
    '1.0.0',
    'INCREMENTAL',
    300,
    30,
    15,
    5000,
    45,
    N'Deadlock events from the existing system_health XE files.'
),

------------------------------------------------------------
-- COL-12: Error Log
------------------------------------------------------------

(
    'COL-12',
    '26',
    N'SQL Server Error Log',
    N'12-Error-Log-Collector.sql',
    '1.0.0',
    'INCREMENTAL',
    300,
    30,
    15,
    100,
    40,
    N'Operational errors with preliminary error log size protection.'
),

------------------------------------------------------------
-- COL-13: Wait Statistics
------------------------------------------------------------

(
    'COL-13',
    '26',
    N'Wait Statistics',
    N'13-Wait-Statistics-Collector.sql',
    '1.0.0',
    'CUMULATIVE',
    300,
    15,
    15,
    15000,
    50,
    N'Cumulative waits for historical interval analysis.'
),

------------------------------------------------------------
-- COL-14: TempDB
------------------------------------------------------------

(
    'COL-14',
    '26',
    N'TempDB Performance',
    N'14-TempDB-Collector.sql',
    '1.0.0',
    'SNAPSHOT',
    60,
    15,
    15,
    5000,
    18,
    N'TempDB space, file configuration and suspected contention.'
),

------------------------------------------------------------
-- COL-15: Long-Running Queries
------------------------------------------------------------

(
    'COL-15',
    '26',
    N'Long Running Queries',
    N'15-Long-Running-Query-Collector.sql',
    '1.0.0',
    'SNAPSHOT',
    60,
    15,
    15,
    1000,
    22,
    N'Active expensive requests and query resource consumption.'
),

------------------------------------------------------------
-- COL-16: SQL Agent History
------------------------------------------------------------

(
    'COL-16',
    '26',
    N'SQL Agent Execution History',
    N'16-SQL-Agent-History-Collector.sql',
    '1.0.0',
    'INCREMENTAL',
    300,
    30,
    15,
    3000,
    55,
    N'Incremental completed SQL Agent job execution history.'
);

------------------------------------------------------------
-- SECTION 7: Collector Configuration Validation
------------------------------------------------------------

IF
(
    SELECT COUNT(*)
    FROM @CollectorInput
) <> 16
BEGIN

    THROW 50012,
        'Expected exactly 16 Module 26 collectors.',
        1;

END;

IF EXISTS
(
    SELECT 1

    FROM @CollectorInput

    WHERE DefaultIntervalSeconds <= 0

       OR DefaultTimeoutSeconds <= 0

       OR DefaultTimeoutSeconds >=
            DefaultIntervalSeconds

       OR MaximumOutputRows <= 0

       OR ExecutionPriority NOT BETWEEN 1 AND 100

       OR MinimumSQLMajorVersion < 15

       OR CollectionType NOT IN
       (
           'SNAPSHOT',
           'CUMULATIVE',
           'INCREMENTAL'
       )
)
BEGIN

    THROW 50013,
        'Invalid collector configuration detected.',
        1;

END;

------------------------------------------------------------
-- SECTION 8: Registration Tracking
------------------------------------------------------------

DECLARE @RegistrationResults TABLE
(
    CollectorCode VARCHAR(30),

    CollectorName NVARCHAR(128),

    ScriptFileName NVARCHAR(256),

    RegistrationStatus VARCHAR(30),

    Details NVARCHAR(2048)
);

------------------------------------------------------------
-- SECTION 9: Register Monitoring Collectors
------------------------------------------------------------

BEGIN TRY

    BEGIN TRANSACTION;

    --------------------------------------------------------
    -- Protect existing collector identity
    --------------------------------------------------------

    IF EXISTS
    (
        SELECT 1

        FROM @CollectorInput AS S

        INNER JOIN dbo.Collectors AS T
            WITH (UPDLOCK, HOLDLOCK)

            ON S.CollectorCode = T.CollectorCode

        WHERE S.ScriptFileName <> T.ScriptFileName

           OR S.ModuleID <> T.ModuleID
    )
    BEGIN

        THROW 50014,
            'Existing collector code has a different script or module.',
            1;

    END;

    IF EXISTS
    (
        SELECT 1

        FROM @CollectorInput AS S

        INNER JOIN dbo.Collectors AS T
            WITH (UPDLOCK, HOLDLOCK)

            ON S.ScriptFileName = T.ScriptFileName

        WHERE S.CollectorCode <> T.CollectorCode
    )
    BEGIN

        THROW 50015,
            'Collector script already belongs to another collector.',
            1;

    END;

    --------------------------------------------------------
    -- Record existing collectors
    --------------------------------------------------------

    INSERT INTO @RegistrationResults
    SELECT
        S.CollectorCode,

        S.CollectorName,

        S.ScriptFileName,

        'ALREADY EXISTS',

        N'Existing collector configuration preserved.'

    FROM @CollectorInput AS S

    INNER JOIN dbo.Collectors AS T
        WITH (UPDLOCK, HOLDLOCK)

        ON S.CollectorCode = T.CollectorCode;

    SET @CollectorsSkipped = @@ROWCOUNT;

    --------------------------------------------------------
    -- Insert new collectors
    --------------------------------------------------------

    INSERT INTO dbo.Collectors
    (
        CollectorCode,
        ModuleID,
        CollectorName,
        ScriptFileName,
        ScriptVersion,
        CollectionType,
        DefaultIntervalSeconds,
        DefaultTimeoutSeconds,
        MinimumSQLMajorVersion,
        MaximumOutputRows,
        ExecutionPriority,
        IsEnabled,
        Description
    )

    OUTPUT

        inserted.CollectorCode,

        inserted.CollectorName,

        inserted.ScriptFileName,

        'REGISTERED',

        N'Collector registered with execution disabled.'

    INTO @RegistrationResults
    (
        CollectorCode,
        CollectorName,
        ScriptFileName,
        RegistrationStatus,
        Details
    )

    SELECT
        S.CollectorCode,

        S.ModuleID,

        S.CollectorName,

        S.ScriptFileName,

        S.ScriptVersion,

        S.CollectionType,

        S.DefaultIntervalSeconds,

        S.DefaultTimeoutSeconds,

        S.MinimumSQLMajorVersion,

        S.MaximumOutputRows,

        S.ExecutionPriority,

        0,

        S.Description

    FROM @CollectorInput AS S

    WHERE NOT EXISTS
    (
        SELECT 1

        FROM dbo.Collectors AS T
            WITH (UPDLOCK, HOLDLOCK)

        WHERE T.CollectorCode = S.CollectorCode
    );

    SET @CollectorsRegistered = @@ROWCOUNT;

    --------------------------------------------------------
    -- SECTION 10: Instance-Collector Assignments
    --------------------------------------------------------

    /*
    Create assignments for registered instances.

    Unknown SQL versions are permitted for registration
    purposes only. The Python service must validate
    compatibility before execution.

    Known incompatible versions are excluded.

    All new assignments remain disabled.
    */

    INSERT INTO dbo.InstanceCollectors
    (
        InstanceID,
        CollectorID,
        IntervalOverrideSeconds,
        TimeoutOverrideSeconds,
        IsEnabled,
        NextRunDateUTC,
        LastAttemptDateUTC,
        LastSuccessDateUTC,
        ConsecutiveFailures
    )

    SELECT
        I.InstanceID,

        C.CollectorID,

        NULL,

        NULL,

        0,

        NULL,

        NULL,

        NULL,

        0

    FROM dbo.MonitoredInstances AS I

    CROSS JOIN dbo.Collectors AS C

    INNER JOIN @CollectorInput AS S
        ON C.CollectorCode = S.CollectorCode

    WHERE
    (
        I.SQLMajorVersion IS NULL

        OR I.SQLMajorVersion >=
            C.MinimumSQLMajorVersion
    )

    AND NOT EXISTS
    (
        SELECT 1

        FROM dbo.InstanceCollectors AS IC
            WITH (UPDLOCK, HOLDLOCK)

        WHERE IC.InstanceID = I.InstanceID

          AND IC.CollectorID = C.CollectorID
    );

    SET @AssignmentsCreated = @@ROWCOUNT;

    --------------------------------------------------------
    -- SECTION 11: Commit Registration
    --------------------------------------------------------

    COMMIT TRANSACTION;

    SELECT
        @ActualServer AS MonitoringServer,

        DB_NAME() AS MonitoringDatabase,

        'SUCCESS' AS DeploymentStatus,

        @CollectorsRegistered AS CollectorsRegistered,

        @CollectorsSkipped AS ExistingCollectorsSkipped,

        @AssignmentsCreated AS InstanceAssignmentsCreated,

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
-- SECTION 12: Collector Registration Results
------------------------------------------------------------

SELECT
    CollectorCode,

    CollectorName,

    ScriptFileName,

    RegistrationStatus,

    Details

FROM @RegistrationResults

ORDER BY CollectorCode;

------------------------------------------------------------
-- SECTION 13: Collector Configuration Verification
------------------------------------------------------------

SELECT
    CollectorID,

    CollectorCode,

    ModuleID,

    CollectorName,

    ScriptFileName,

    ScriptVersion,

    CollectionType,

    DefaultIntervalSeconds,

    DefaultTimeoutSeconds,

    MinimumSQLMajorVersion,

    MaximumOutputRows,

    ExecutionPriority,

    IsEnabled,

    CreatedDateUTC,

    Description

FROM dbo.Collectors

WHERE ModuleID = '26'

ORDER BY CollectorCode;

------------------------------------------------------------
-- SECTION 14: Instance Assignment Verification
------------------------------------------------------------

SELECT
    I.InstanceName,

    I.Environment,

    I.SQLMajorVersion,

    I.IsEnabled AS InstanceEnabled,

    C.CollectorCode,

    C.CollectorName,

    C.IsEnabled AS CollectorEnabled,

    IC.IsEnabled AS AssignmentEnabled,

    COALESCE
    (
        IC.IntervalOverrideSeconds,
        C.DefaultIntervalSeconds
    ) AS EffectiveIntervalSeconds,

    COALESCE
    (
        IC.TimeoutOverrideSeconds,
        C.DefaultTimeoutSeconds
    ) AS EffectiveTimeoutSeconds,

    IC.NextRunDateUTC,

    CASE

        WHEN I.SQLMajorVersion IS NULL

            THEN 'VALIDATION REQUIRED'

        WHEN I.SQLMajorVersion <
             C.MinimumSQLMajorVersion

            THEN 'INCOMPATIBLE'

        ELSE 'VERSION ELIGIBLE'

    END AS CompatibilityStatus

FROM dbo.InstanceCollectors AS IC

INNER JOIN dbo.MonitoredInstances AS I
    ON IC.InstanceID = I.InstanceID

INNER JOIN dbo.Collectors AS C
    ON IC.CollectorID = C.CollectorID

WHERE C.ModuleID = '26'

ORDER BY
    I.InstanceName,
    C.ExecutionPriority,
    C.CollectorCode;

------------------------------------------------------------
-- SECTION 15: Collector Assignment Summary
------------------------------------------------------------

SELECT
    I.InstanceID,

    I.InstanceName,

    I.Environment,

    I.IsEnabled AS InstanceEnabled,

    COUNT(IC.CollectorID)
        AS AssignedCollectors,

    COUNT
    (
        CASE

            WHEN IC.IsEnabled = 1
             AND C.IsEnabled = 1

                THEN 1

        END
    ) AS EnabledCollectorAssignments,

    COUNT
    (
        CASE

            WHEN IC.IsEnabled = 0

                THEN 1

        END
    ) AS DisabledCollectorAssignments,

    COUNT
    (
        CASE

            WHEN I.SQLMajorVersion IS NULL

                THEN IC.CollectorID

        END
    ) AS AssignmentsRequiringVersionValidation

FROM dbo.MonitoredInstances AS I

LEFT JOIN dbo.InstanceCollectors AS IC
    ON I.InstanceID = IC.InstanceID

LEFT JOIN dbo.Collectors AS C
    ON IC.CollectorID = C.CollectorID

GROUP BY
    I.InstanceID,
    I.InstanceName,
    I.Environment,
    I.IsEnabled

ORDER BY
    I.Environment,
    I.InstanceName;

GO
