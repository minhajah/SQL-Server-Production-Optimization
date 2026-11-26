/*
============================================================
Project : SQL Server Production Optimization
Module  : 30 - Centralized Monitoring
Script  : 07-Collection-Checkpoints.sql
Purpose : Manage persistent incremental collection checkpoints
Type    : Central Repository Deployment
Impact  : Central DBA_Monitoring database only
Version : 1.0
============================================================

IMPORTANT:

1. Execute ONLY on the approved central monitoring instance.
2. Execute after 06-Collection-Logging.sql.
3. Do NOT execute on monitored production instances.
4. Deployment is disabled by default.
5. Checkpoints must be saved within the ingestion transaction.
6. Checkpoints must not advance after failed collection.
7. Existing inventory application remains unchanged.

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

    @ActualServer NVARCHAR(128);

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
        'Execute deployment outside an existing transaction.',
        1;
END;
IF (@@OPTIONS & 2) = 2
BEGIN
    THROW 50012,
        'Implicit transactions must be disabled before deployment.',
        1;
END;

------------------------------------------------------------
-- SECTION 3: Repository Validation
------------------------------------------------------------

IF OBJECT_ID('dbo.CollectionCheckpoints', 'U') IS NULL
OR OBJECT_ID('dbo.CollectionRuns', 'U') IS NULL
OR OBJECT_ID('dbo.InstanceCollectors', 'U') IS NULL
OR OBJECT_ID('dbo.MonitoredInstances', 'U') IS NULL
OR OBJECT_ID('dbo.Collectors', 'U') IS NULL
OR OBJECT_ID('dbo.MonitoringSettings', 'U') IS NULL
OR OBJECT_ID('dbo.SchemaVersion', 'U') IS NULL
OR OBJECT_ID('dbo.usp_CollectionRunComplete', 'P') IS NULL
BEGIN
    THROW 50008,
        'Required monitoring repository objects are missing.',
        1;
END;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.SchemaVersion
    WHERE VersionNumber = '1.0.2'
)
BEGIN
    THROW 50009,
        'Required repository schema version not found.',
        1;
END;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.MonitoringSettings
    WHERE SettingKey = 'MonitoringEnabled'
      AND SettingValue = N'0'
)
BEGIN
    THROW 50010,
        'Monitoring must be disabled before deployment.',
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
        'Active collection runs exist.',
        1;
END;

------------------------------------------------------------
-- SECTION 4: Begin Transactional Deployment
------------------------------------------------------------

BEGIN TRY

    BEGIN TRANSACTION;

    --------------------------------------------------------
    -- TABLE 12: Checkpoint Administrative Audit
    --------------------------------------------------------

    IF OBJECT_ID('dbo.CheckpointAudit', 'U') IS NULL
    BEGIN

        CREATE TABLE dbo.CheckpointAudit
        (
            CheckpointAuditID BIGINT IDENTITY(1,1)
                NOT NULL,

            CheckpointID BIGINT NOT NULL,

            InstanceID INT NOT NULL,

            CollectorID INT NOT NULL,

            CheckpointKey VARCHAR(100) NOT NULL,

            ActionType VARCHAR(20) NOT NULL,

            PreviousNumericCheckpoint BIGINT NULL,

            PreviousTextCheckpoint NVARCHAR(4000) NULL,

            PreviousDateCheckpointUTC DATETIME2(7) NULL,

            PreviousCollectionRunID BIGINT NULL,

            Reason NVARCHAR(1000) NOT NULL,

            ActionBy NVARCHAR(128) NOT NULL,

            ActionDateUTC DATETIME2(3) NOT NULL
                CONSTRAINT DF_CPA_ActionDate
                DEFAULT (SYSUTCDATETIME()),

            CONSTRAINT PK_CheckpointAudit
                PRIMARY KEY CLUSTERED
                (CheckpointAuditID),

            CONSTRAINT CK_CPA_ActionType
                CHECK (ActionType IN ('RESET'))
        );

        CREATE NONCLUSTERED INDEX
            IX_CPA_InstanceCollectorHistory

        ON dbo.CheckpointAudit
        (
            InstanceID,
            CollectorID,
            ActionDateUTC DESC
        );

    END;

    --------------------------------------------------------
    -- PROCEDURE 01: Retrieve Collection Checkpoint
    --------------------------------------------------------

    EXEC sys.sp_executesql N'

    CREATE OR ALTER PROCEDURE dbo.usp_CollectionCheckpointGet
    (
        @InstanceID INT,
        @CollectorID INT,
        @CheckpointKey VARCHAR(100)
    )
    AS
    BEGIN

        SET NOCOUNT ON;

        IF NULLIF
        (
            LTRIM(RTRIM(@CheckpointKey)),
            ''''
        ) IS NULL
        BEGIN
            THROW 50701,
                ''Checkpoint key is required.'',
                1;
        END;

        IF NOT EXISTS
        (
            SELECT 1
            FROM dbo.InstanceCollectors
            WHERE InstanceID = @InstanceID
              AND CollectorID = @CollectorID
        )
        BEGIN
            THROW 50702,
                ''Instance collector assignment not found.'',
                1;
        END;

        ----------------------------------------------------
        -- Return one row even when no checkpoint exists
        ----------------------------------------------------

        SELECT
            @InstanceID AS InstanceID,

            @CollectorID AS CollectorID,

            @CheckpointKey AS CheckpointKey,

            CP.CheckpointID,

            CP.NumericCheckpoint,

            CP.TextCheckpoint,

            CP.DateCheckpointUTC,

            CP.LastSuccessDateUTC,

            CP.LastCollectionRunID,

            CP.UpdatedDateUTC,

            CP.RowVersion AS CheckpointRowVersion,

            CONVERT
            (
                BIT,

                CASE
                    WHEN CP.CheckpointID IS NULL
                        THEN 0
                    ELSE 1
                END
            ) AS CheckpointExists,

            CASE

                WHEN CP.CheckpointID IS NULL
                    THEN ''NOT INITIALIZED''

                WHEN CP.NumericCheckpoint IS NULL
                 AND CP.TextCheckpoint IS NULL
                 AND CP.DateCheckpointUTC IS NULL
                    THEN ''RESET''

                ELSE ''AVAILABLE''

            END AS CheckpointStatus

        FROM
        (
            SELECT 1 AS Anchor
        ) AS A

        LEFT JOIN dbo.CollectionCheckpoints AS CP

            ON CP.InstanceID = @InstanceID

           AND CP.CollectorID = @CollectorID

           AND CP.CheckpointKey = @CheckpointKey;

    END;

    ';

    --------------------------------------------------------
    -- PROCEDURE 02: Save Collection Checkpoint
    --------------------------------------------------------

    EXEC sys.sp_executesql N'

    CREATE OR ALTER PROCEDURE dbo.usp_CollectionCheckpointSave
    (
        @InstanceID INT,

        @CollectorID INT,

        @CheckpointKey VARCHAR(100),

        @CollectionRunID BIGINT,

        @RunToken UNIQUEIDENTIFIER,

        @NumericCheckpoint BIGINT = NULL,

        @TextCheckpoint NVARCHAR(4000) = NULL,

        @DateCheckpointUTC DATETIME2(7) = NULL,

        @ExpectedRowVersion BINARY(8) = NULL,

        @EnforceNumericMonotonicity BIT = 1,

        @EnforceDateMonotonicity BIT = 1
    )
    AS
    BEGIN

        SET NOCOUNT ON;
        SET XACT_ABORT ON;

        DECLARE
            @CheckpointID BIGINT,

            @ExistingRowVersion BINARY(8),

            @ExistingNumericCheckpoint BIGINT,

            @ExistingDateCheckpointUTC DATETIME2(7),

            @ExistingCollectionRunID BIGINT,

            @RunStatus VARCHAR(20),

            @IngestedRowsReturned BIGINT,

            @IngestedRowsStored BIGINT,

            @CurrentUTC DATETIME2(3),

            @SaveStatus VARCHAR(20);

        ----------------------------------------------------
        -- Require the caller ingestion transaction
        ----------------------------------------------------

        IF @@TRANCOUNT = 0
           OR XACT_STATE() <> 1
        BEGIN
            THROW 50801,
                ''Checkpoint save requires a committable ingestion transaction.'',
                1;
        END;

        IF NULLIF
        (
            LTRIM(RTRIM(@CheckpointKey)),
            ''''
        ) IS NULL
        BEGIN
            THROW 50802,
                ''Checkpoint key is required.'',
                1;
        END;

        IF @RunToken IS NULL
        BEGIN
            THROW 50803,
                ''Collection run token is required.'',
                1;
        END;

        IF @NumericCheckpoint IS NULL
           AND @TextCheckpoint IS NULL
           AND @DateCheckpointUTC IS NULL
        BEGIN
            THROW 50804,
                ''At least one checkpoint value is required.'',
                1;
        END;

        IF @NumericCheckpoint < 0
        BEGIN
            THROW 50805,
                ''Numeric checkpoint cannot be negative.'',
                1;
        END;

        IF @EnforceNumericMonotonicity IS NULL
           OR @EnforceDateMonotonicity IS NULL
        BEGIN
            THROW 50806,
                ''Checkpoint validation options cannot be NULL.'',
                1;
        END;

        ----------------------------------------------------
        -- Validate current collection run ownership
        ----------------------------------------------------

        SELECT
        SELECT
    @RunStatus = RunStatus,

    @IngestedRowsReturned = RowsReturned,

    @IngestedRowsStored = RowsStored

FROM dbo.CollectionRuns
    WITH (UPDLOCK, HOLDLOCK)

        WHERE CollectionRunID = @CollectionRunID

          AND RunToken = @RunToken

          AND InstanceID = @InstanceID

          AND CollectorID = @CollectorID;

        IF @RunStatus IS NULL
        BEGIN
            THROW 50807,
                ''Collection run ownership validation failed.'',
                1;
        END;

        IF @RunStatus <> ''RUNNING''
        BEGIN
            THROW 50808,
                ''Checkpoint requires an active collection run.'',
                1;
        END;
----------------------------------------------------
-- Validate ingestion before advancing checkpoint
----------------------------------------------------

IF ISNULL(@IngestedRowsReturned, 0) <= 0
OR @IngestedRowsStored IS NULL
OR @IngestedRowsStored < 0
OR @IngestedRowsStored > @IngestedRowsReturned
BEGIN
    THROW 50816,
        ''Validated metric ingestion is required before saving a checkpoint.'',
        1;
END;

        IF NOT EXISTS
        (
            SELECT 1

            FROM dbo.Collectors

            WHERE CollectorID = @CollectorID

              AND CollectionType = ''INCREMENTAL''
        )
        BEGIN
            THROW 50809,
                ''Collector is not registered for incremental collection.'',
                1;
        END;

        ----------------------------------------------------
        -- Lock the existing checkpoint
        ----------------------------------------------------

        SELECT
            @CheckpointID = CheckpointID,

            @ExistingRowVersion = RowVersion,

            @ExistingNumericCheckpoint =
                NumericCheckpoint,

            @ExistingDateCheckpointUTC =
                DateCheckpointUTC,

            @ExistingCollectionRunID =
                LastCollectionRunID

        FROM dbo.CollectionCheckpoints
            WITH (UPDLOCK, HOLDLOCK)

        WHERE InstanceID = @InstanceID

          AND CollectorID = @CollectorID

          AND CheckpointKey = @CheckpointKey;

        SET @CurrentUTC = SYSUTCDATETIME();

        ----------------------------------------------------
        -- Create a new checkpoint
        ----------------------------------------------------

        IF @CheckpointID IS NULL
        BEGIN

            IF @ExpectedRowVersion IS NOT NULL
            BEGIN
                THROW 50810,
                    ''Expected checkpoint no longer exists.'',
                    1;
            END;

            INSERT INTO dbo.CollectionCheckpoints
            (
                InstanceID,
                CollectorID,
                CheckpointKey,
                NumericCheckpoint,
                TextCheckpoint,
                DateCheckpointUTC,
                LastSuccessDateUTC,
                LastCollectionRunID,
                UpdatedDateUTC
            )
            VALUES
            (
                @InstanceID,
                @CollectorID,
                @CheckpointKey,
                @NumericCheckpoint,
                @TextCheckpoint,
                @DateCheckpointUTC,
                @CurrentUTC,
                @CollectionRunID,
                @CurrentUTC
            );

            SET @CheckpointID =
                CONVERT(BIGINT, SCOPE_IDENTITY());

            SET @SaveStatus = ''CREATED'';

        END

        ELSE
        BEGIN

            ------------------------------------------------
            -- Optimistic concurrency validation
            ------------------------------------------------

            IF @ExpectedRowVersion IS NULL

               OR @ExistingRowVersion <>
                  @ExpectedRowVersion

            BEGIN
                THROW 50811,
                    ''Checkpoint changed since it was retrieved. Reload before retrying.'',
                    1;
            END;

            ------------------------------------------------
            -- Reject older collection runs
            ------------------------------------------------

            IF @ExistingCollectionRunID IS NOT NULL

               AND @CollectionRunID <
                   @ExistingCollectionRunID

            BEGIN
                THROW 50812,
                    ''Older collection run cannot replace a newer checkpoint.'',
                    1;
            END;

            ------------------------------------------------
            -- Prevent numeric checkpoint regression
            ------------------------------------------------

            IF @EnforceNumericMonotonicity = 1

               AND @ExistingNumericCheckpoint IS NOT NULL

               AND
               (
                   @NumericCheckpoint IS NULL

                   OR @NumericCheckpoint <
                       @ExistingNumericCheckpoint
               )

            BEGIN
                THROW 50813,
                    ''Numeric checkpoint regression detected.'',
                    1;
            END;

            ------------------------------------------------
            -- Prevent date checkpoint regression
            ------------------------------------------------

            IF @EnforceDateMonotonicity = 1

               AND @ExistingDateCheckpointUTC IS NOT NULL

               AND
               (
                   @DateCheckpointUTC IS NULL

                   OR @DateCheckpointUTC <
                       @ExistingDateCheckpointUTC
               )

            BEGIN
                THROW 50814,
                    ''Date checkpoint regression detected.'',
                    1;
            END;

            ------------------------------------------------
            -- Update the checkpoint
            ------------------------------------------------

            UPDATE dbo.CollectionCheckpoints

            SET NumericCheckpoint =
                    @NumericCheckpoint,

                TextCheckpoint =
                    @TextCheckpoint,

                DateCheckpointUTC =
                    @DateCheckpointUTC,

                LastSuccessDateUTC =
                    @CurrentUTC,

                LastCollectionRunID =
                    @CollectionRunID,

                UpdatedDateUTC =
                    @CurrentUTC

            WHERE CheckpointID = @CheckpointID

              AND RowVersion = @ExpectedRowVersion;

            IF @@ROWCOUNT <> 1
            BEGIN
                THROW 50815,
                    ''Checkpoint concurrency conflict detected.'',
                    1;
            END;

            SET @SaveStatus = ''UPDATED'';

        END;

        ----------------------------------------------------
        -- Return pending checkpoint state
        ----------------------------------------------------

        SELECT
            CheckpointID,

            InstanceID,

            CollectorID,

            CheckpointKey,

            NumericCheckpoint,

            TextCheckpoint,

            DateCheckpointUTC,

            LastCollectionRunID,

            UpdatedDateUTC,

            RowVersion AS CheckpointRowVersion,

            @SaveStatus AS SaveStatus,

            ''PENDING CALLER COMMIT'' AS TransactionStatus

        FROM dbo.CollectionCheckpoints

        WHERE CheckpointID = @CheckpointID;

        /*
        This procedure deliberately does not commit.

        The Python ingestion transaction must:

        1. Store validated event records.
        2. Save the checkpoint.
        3. Finalize the collection run successfully.
        4. Commit the entire transaction.

        On any failure, roll back the entire transaction.
        */

    END;

    ';

    --------------------------------------------------------
    -- PROCEDURE 03: Administrative Checkpoint Reset
    --------------------------------------------------------

    EXEC sys.sp_executesql N'

    CREATE OR ALTER PROCEDURE dbo.usp_CollectionCheckpointReset
    (
        @InstanceID INT,

        @CollectorID INT,

        @CheckpointKey VARCHAR(100),

        @Reason NVARCHAR(1000) = NULL,

        @ConfirmServiceStopped BIT = 0,

        @AllowReset BIT = 0
    )
    AS
    BEGIN

        SET NOCOUNT ON;
        SET XACT_ABORT ON;

        DECLARE
            @CheckpointID BIGINT,

            @LockResult INT,

            @CurrentUTC DATETIME2(3);

        ----------------------------------------------------
        -- Preview current checkpoint by default
        ----------------------------------------------------

        IF ISNULL(@AllowReset, 0) <> 1
        BEGIN

            EXEC dbo.usp_CollectionCheckpointGet

                @InstanceID = @InstanceID,

                @CollectorID = @CollectorID,

                @CheckpointKey = @CheckpointKey;

            RETURN;

        END;

        ----------------------------------------------------
        -- Validate explicit reset authorization
        ----------------------------------------------------

        IF ISNULL(@ConfirmServiceStopped, 0) <> 1
        BEGIN
            THROW 50901,
                ''Stop all monitoring workers before checkpoint reset.'',
                1;
        END;

        IF NULLIF
        (
            LTRIM(RTRIM(@Reason)),
            N''''
        ) IS NULL
        BEGIN
            THROW 50902,
                ''Checkpoint reset requires an administrative reason.'',
                1;
        END;

        IF @@TRANCOUNT <> 0
        BEGIN
            THROW 50903,
                ''Checkpoint reset requires an independent transaction.'',
                1;
        END;
        IF (@@OPTIONS & 2) = 2
BEGIN
    THROW 50908,
        ''Implicit transactions must be disabled before checkpoint reset.'',
        1;
END;

        BEGIN TRY

            BEGIN TRANSACTION;

            ------------------------------------------------
            -- Prevent new collection reservations
            ------------------------------------------------

            EXEC @LockResult = sys.sp_getapplock

                @Resource =
                    N''DBA_Monitoring.CollectionScheduling'',

                @LockMode = ''Exclusive'',

                @LockOwner = ''Transaction'',

                @LockTimeout = 5000;

            IF @LockResult < 0
            BEGIN
                THROW 50904,
                    ''Unable to acquire scheduling lock.'',
                    1;
            END;

            IF NOT EXISTS
(
    SELECT 1

    FROM dbo.MonitoringSettings
        WITH (UPDLOCK, HOLDLOCK)

    WHERE SettingKey = ''MonitoringEnabled''

      AND SettingValue = N''0''
)
            BEGIN
                THROW 50905,
                    ''Monitoring must be disabled before checkpoint reset.'',
                    1;
            END;

            IF EXISTS
            (
                SELECT 1

                FROM dbo.CollectionRuns

                WHERE RunStatus = ''RUNNING''
            )
            BEGIN
                THROW 50906,
                    ''Active collection runs exist.'',
                    1;
            END;

            SELECT
                @CheckpointID = CheckpointID

            FROM dbo.CollectionCheckpoints
                WITH (UPDLOCK, HOLDLOCK)

            WHERE InstanceID = @InstanceID

              AND CollectorID = @CollectorID

              AND CheckpointKey = @CheckpointKey;

            IF @CheckpointID IS NULL
            BEGIN
                THROW 50907,
                    ''Checkpoint not found.'',
                    1;
            END;

            SET @CurrentUTC = SYSUTCDATETIME();

            ------------------------------------------------
            -- Preserve the previous checkpoint in audit
            ------------------------------------------------

            INSERT INTO dbo.CheckpointAudit
            (
                CheckpointID,

                InstanceID,

                CollectorID,

                CheckpointKey,

                ActionType,

                PreviousNumericCheckpoint,

                PreviousTextCheckpoint,

                PreviousDateCheckpointUTC,

                PreviousCollectionRunID,

                Reason,

                ActionBy,

                ActionDateUTC
            )

            SELECT
                CheckpointID,

                InstanceID,

                CollectorID,

                CheckpointKey,

                ''RESET'',

                NumericCheckpoint,

                TextCheckpoint,

                DateCheckpointUTC,

                LastCollectionRunID,

                @Reason,

                ORIGINAL_LOGIN(),

                @CurrentUTC

            FROM dbo.CollectionCheckpoints

            WHERE CheckpointID = @CheckpointID;

            ------------------------------------------------
            -- Reset without deleting the checkpoint row
            ------------------------------------------------

            UPDATE dbo.CollectionCheckpoints

            SET NumericCheckpoint = NULL,

                TextCheckpoint = NULL,

                DateCheckpointUTC = NULL,

                LastSuccessDateUTC = NULL,

                LastCollectionRunID = NULL,

                UpdatedDateUTC = @CurrentUTC

            WHERE CheckpointID = @CheckpointID;

            COMMIT TRANSACTION;

            SELECT
                @CheckpointID AS CheckpointID,

                @InstanceID AS InstanceID,

                @CollectorID AS CollectorID,

                @CheckpointKey AS CheckpointKey,

                ''RESET COMPLETED'' AS ResetStatus,

                @Reason AS ResetReason,

                @CurrentUTC AS ResetDateUTC;

        END TRY

        BEGIN CATCH

            IF XACT_STATE() <> 0
                ROLLBACK TRANSACTION;

            THROW;

        END CATCH;

    END;

    ';

    --------------------------------------------------------
    -- PROCEDURE 04: Checkpoint Health Summary
    --------------------------------------------------------

    EXEC sys.sp_executesql N'

    CREATE OR ALTER PROCEDURE dbo.usp_CollectionCheckpointSummary
    (
        @InstanceID INT = NULL,

        @CollectorID INT = NULL
    )
    AS
    BEGIN

        SET NOCOUNT ON;

        DECLARE @CurrentUTC DATETIME2(3) =
            SYSUTCDATETIME();

        ----------------------------------------------------
        -- Result 01: Checkpoint inventory and health
        ----------------------------------------------------

        SELECT
            I.InstanceID,

            I.InstanceName,

            I.Environment,

            C.CollectorCode,

            C.CollectorName,

            CP.CheckpointID,

            CP.CheckpointKey,

            CP.NumericCheckpoint,

            CP.TextCheckpoint,

            CP.DateCheckpointUTC,

            CP.LastSuccessDateUTC,

            CP.LastCollectionRunID,

            CP.UpdatedDateUTC,

            DATEDIFF_BIG
            (
                SECOND,
                CP.LastSuccessDateUTC,
                @CurrentUTC
            ) AS SecondsSinceCheckpointSuccess,

            COALESCE
            (
                IC.IntervalOverrideSeconds,
                C.DefaultIntervalSeconds
            ) AS EffectiveIntervalSeconds,

            CASE

                WHEN I.IsEnabled = 0
                  OR C.IsEnabled = 0
                  OR IC.IsEnabled = 0

                    THEN ''DISABLED''

                WHEN NOT EXISTS
                (
                    SELECT 1

                    FROM dbo.MonitoringSettings

                    WHERE SettingKey = ''MonitoringEnabled''

                      AND SettingValue = N''1''
                )

                    THEN ''PAUSED''

                WHEN I.Environment IN
                    (''PRODUCTION'', ''DR'')

                 AND NOT EXISTS
                 (
                     SELECT 1

                     FROM dbo.MonitoringSettings

                     WHERE SettingKey =
                         ''ProductionCollectionEnabled''

                       AND SettingValue = N''1''
                 )

                    THEN ''PAUSED''

                WHEN I.IsPilotInstance = 0

                 AND NOT EXISTS
                 (
                     SELECT 1

                     FROM dbo.MonitoringSettings

                     WHERE SettingKey =
                         ''PilotModeEnabled''

                       AND SettingValue = N''0''
                 )

                    THEN ''PILOT EXCLUDED''

                WHEN I.SQLMajorVersion IS NULL

                    THEN ''VALIDATION REQUIRED''

                WHEN I.SQLMajorVersion <
                    C.MinimumSQLMajorVersion

                    THEN ''INCOMPATIBLE''

                WHEN CP.CheckpointID IS NULL

                    THEN ''NOT INITIALIZED''

                WHEN CP.NumericCheckpoint IS NULL
                 AND CP.TextCheckpoint IS NULL
                 AND CP.DateCheckpointUTC IS NULL

                    THEN ''RESET''

                WHEN CP.LastSuccessDateUTC IS NULL

                    THEN ''UNKNOWN''

                WHEN DATEDIFF_BIG
                (
                    SECOND,
                    CP.LastSuccessDateUTC,
                    @CurrentUTC
                ) >

                CONVERT
                (
                    BIGINT,

                    COALESCE
                    (
                        IC.IntervalOverrideSeconds,

                        C.DefaultIntervalSeconds
                    )
                ) * 3

                    THEN ''STALE''

                ELSE ''CURRENT''

            END AS CheckpointHealthStatus

        FROM dbo.InstanceCollectors AS IC

        INNER JOIN dbo.MonitoredInstances AS I

            ON IC.InstanceID = I.InstanceID

        INNER JOIN dbo.Collectors AS C

            ON IC.CollectorID = C.CollectorID

        LEFT JOIN dbo.CollectionCheckpoints AS CP

            ON IC.InstanceID = CP.InstanceID

           AND IC.CollectorID = CP.CollectorID

        WHERE C.CollectionType = ''INCREMENTAL''

          AND
          (
              @InstanceID IS NULL

              OR I.InstanceID = @InstanceID
          )

          AND
          (
              @CollectorID IS NULL

              OR C.CollectorID = @CollectorID
          )

        ORDER BY
            I.InstanceName,
            C.CollectorCode,
            CP.CheckpointKey;

        ----------------------------------------------------
        -- Result 02: Recent administrative resets
        ----------------------------------------------------

        SELECT TOP (100)

            A.CheckpointAuditID,

            I.InstanceName,

            C.CollectorCode,

            A.CheckpointKey,

            A.ActionType,

            A.PreviousNumericCheckpoint,

            A.PreviousDateCheckpointUTC,

            A.PreviousCollectionRunID,

            A.Reason,

            A.ActionBy,

            A.ActionDateUTC

        FROM dbo.CheckpointAudit AS A

        INNER JOIN dbo.MonitoredInstances AS I

            ON A.InstanceID = I.InstanceID

        INNER JOIN dbo.Collectors AS C

            ON A.CollectorID = C.CollectorID

        WHERE
        (
            @InstanceID IS NULL

            OR A.InstanceID = @InstanceID
        )

        AND
        (
            @CollectorID IS NULL

            OR A.CollectorID = @CollectorID
        )

        ORDER BY
            A.ActionDateUTC DESC,

            A.CheckpointAuditID DESC;

    END;

    ';

    --------------------------------------------------------
    -- SECTION 5: Register Schema Version
    --------------------------------------------------------

    IF NOT EXISTS
    (
        SELECT 1

        FROM dbo.SchemaVersion

        WHERE VersionNumber = '1.0.3'
    )
    BEGIN

        INSERT INTO dbo.SchemaVersion
        (
            VersionNumber,
            ScriptName,
            AppliedBy,
            Description
        )
        VALUES
        (
            '1.0.3',

            N'07-Collection-Checkpoints.sql',

            ORIGINAL_LOGIN(),

            N'Persistent incremental checkpoints,
              concurrency protection and administrative
              checkpoint reset auditing.'
        );

    END;

    --------------------------------------------------------
    -- SECTION 6: Commit Deployment
    --------------------------------------------------------

    COMMIT TRANSACTION;

    SELECT
        @ActualServer AS MonitoringServer,

        DB_NAME() AS MonitoringDatabase,

        'SUCCESS' AS DeploymentStatus,

        4 AS ProceduresDeployed,

        '1.0.3' AS SchemaVersion,

        SYSUTCDATETIME() AS DeploymentDateUTC;

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
-- SECTION 7: Stored Procedure Verification
------------------------------------------------------------

SELECT
    S.name AS SchemaName,

    P.name AS ProcedureName,

    P.create_date AS CreatedDate,

    P.modify_date AS ModifiedDate

FROM sys.procedures AS P

INNER JOIN sys.schemas AS S

    ON P.schema_id = S.schema_id

WHERE S.name = 'dbo'

AND P.name IN
(
    'usp_CollectionCheckpointGet',

    'usp_CollectionCheckpointSave',

    'usp_CollectionCheckpointReset',

    'usp_CollectionCheckpointSummary'
)

ORDER BY P.name;

------------------------------------------------------------
-- SECTION 8: Checkpoint Table Verification
------------------------------------------------------------

SELECT
    S.name AS SchemaName,

    T.name AS TableName,

    T.create_date AS CreatedDate,

    T.modify_date AS ModifiedDate

FROM sys.tables AS T

INNER JOIN sys.schemas AS S

    ON T.schema_id = S.schema_id

WHERE S.name = 'dbo'

AND T.name IN
(
    'CollectionCheckpoints',

    'CheckpointAudit'
)

ORDER BY T.name;

GO
