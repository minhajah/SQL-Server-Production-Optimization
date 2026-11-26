/*
============================================================
Project : SQL Server Production Optimization
Module  : 30 - Centralized Monitoring
Script  : 08-Historical-Metrics.sql
Purpose : Central metric ingestion and historical processing
Type    : Central Repository Deployment
Impact  : Central DBA_Monitoring database only
Version : 1.0
============================================================

IMPORTANT:

1. Execute ONLY on the approved central monitoring instance.
2. Execute after 07-Collection-Checkpoints.sql.
3. Do NOT execute on monitored production instances.
4. Deployment is disabled by default.
5. No automatic historical data deletion is performed.
6. Metric definitions must be registered before ingestion.
7. The Python service must manage ingestion transactions.

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
    THROW 50001, 'Deployment disabled.', 1;

IF NULLIF
(
    LTRIM(RTRIM(@ApprovedMonitoringServer)),
    N''
) IS NULL
OR @ApprovedMonitoringServer =
    N'REPLACE_WITH_APPROVED_SERVER_NAME'
    THROW 50002, 'Approved server must be configured.', 1;

IF @ActualServer IS NULL
   OR @ActualServer <> @ApprovedMonitoringServer
    THROW 50003, 'Incorrect monitoring instance.', 1;

IF DB_NAME() <> N'DBA_Monitoring'
    THROW 50004, 'Incorrect database context.', 1;

IF ISNULL
(
    TRY_CONVERT
    (
        INT,
        SERVERPROPERTY('ProductMajorVersion')
    ),
    0
) < 15
    THROW 50005, 'SQL Server 2019 or later required.', 1;

IF DATABASEPROPERTYEX
(
    DB_NAME(),
    'Updateability'
) <> 'READ_WRITE'
    THROW 50006, 'Database must be writable.', 1;

IF @@TRANCOUNT <> 0
    THROW 50007, 'Existing transaction detected.', 1;
IF (@@OPTIONS & 2) = 2
    THROW 50012,
        'Implicit transactions must be disabled.',
        1;

------------------------------------------------------------
-- SECTION 3: Repository Validation
------------------------------------------------------------

IF OBJECT_ID('dbo.MetricSamples', 'U') IS NULL
OR OBJECT_ID('dbo.LatestMetrics', 'U') IS NULL
OR OBJECT_ID('dbo.MetricDefinitions', 'U') IS NULL
OR OBJECT_ID('dbo.MonitoredResources', 'U') IS NULL
OR OBJECT_ID('dbo.MonitoredInstances', 'U') IS NULL
OR OBJECT_ID('dbo.Collectors', 'U') IS NULL
OR OBJECT_ID('dbo.CollectionRuns', 'U') IS NULL
OR OBJECT_ID('dbo.MonitoringSettings', 'U') IS NULL
OR OBJECT_ID('dbo.SchemaVersion', 'U') IS NULL
OR OBJECT_ID('dbo.usp_CollectionRunComplete', 'P') IS NULL
OR OBJECT_ID('dbo.usp_CollectionCheckpointSave', 'P') IS NULL
BEGIN
    THROW 50008,
        'Required repository objects are missing.',
        1;
END;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.SchemaVersion
    WHERE VersionNumber = '1.0.3'
)
    THROW 50009, 'Required schema version not found.', 1;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.MonitoringSettings
    WHERE SettingKey = 'MonitoringEnabled'
      AND SettingValue = N'0'
)
    THROW 50010, 'Monitoring must be disabled.', 1;

IF EXISTS
(
    SELECT 1
    FROM dbo.CollectionRuns
    WHERE RunStatus = 'RUNNING'
)
    THROW 50011, 'Active collection runs exist.', 1;

------------------------------------------------------------
-- SECTION 4: Transactional Deployment
------------------------------------------------------------

BEGIN TRY

    BEGIN TRANSACTION;

    --------------------------------------------------------
    -- TYPE 01: Bulk Metric Input
    --------------------------------------------------------

    IF TYPE_ID('dbo.MetricSampleInput') IS NULL
    BEGIN

        EXEC sys.sp_executesql N'

        CREATE TYPE dbo.MetricSampleInput AS TABLE
        (
            CaptureDateUTC DATETIME2(3) NOT NULL,

            ServerName NVARCHAR(128) NOT NULL,

            ModuleID VARCHAR(10) NOT NULL,

            MetricID VARCHAR(30) NOT NULL,

            Category VARCHAR(50) NOT NULL,

            ResourceType VARCHAR(30) NOT NULL,

            ResourceName NVARCHAR(256)
                COLLATE Latin1_General_100_BIN2 NOT NULL,

            MetricName VARCHAR(100) NOT NULL,

            MetricValue DECIMAL(28,4) NULL,

            MetricUnit VARCHAR(30) NOT NULL,

            CollectionStatus VARCHAR(20) NOT NULL,

            ErrorMessage NVARCHAR(2048) NULL
        );

        ';

    END;

    --------------------------------------------------------
    -- TABLE 13: Cumulative Counter Baselines
    --------------------------------------------------------

    IF OBJECT_ID
    (
        'dbo.MetricCounterBaselines',
        'U'
    ) IS NULL
    BEGIN

        CREATE TABLE dbo.MetricCounterBaselines
        (
            InstanceID INT NOT NULL,

            ResourceID BIGINT NOT NULL,

            MetricDefinitionID INT NOT NULL,

            CaptureDateUTC DATETIME2(3) NOT NULL,

            CounterValue DECIMAL(28,4) NOT NULL,

            CounterUnit VARCHAR(30) NOT NULL,

            CounterEpoch NVARCHAR(128) NOT NULL,

            CollectionRunID BIGINT NOT NULL,

            UpdatedDateUTC DATETIME2(3) NOT NULL
                DEFAULT (SYSUTCDATETIME()),

            CONSTRAINT PK_MetricCounterBaselines
                PRIMARY KEY CLUSTERED
                (
                    InstanceID,
                    ResourceID,
                    MetricDefinitionID
                ),

            CONSTRAINT FK_MCB_Resource
                FOREIGN KEY
                (
                    InstanceID,
                    ResourceID
                )
                REFERENCES dbo.MonitoredResources
                (
                    InstanceID,
                    ResourceID
                ),

            CONSTRAINT FK_MCB_MetricDefinition
                FOREIGN KEY (MetricDefinitionID)
                REFERENCES dbo.MetricDefinitions
                (MetricDefinitionID)
        );

    END;

    --------------------------------------------------------
    -- TABLE 14: Historical Event Deduplication
    --------------------------------------------------------

    IF OBJECT_ID
    (
        'dbo.MetricEventRegistry',
        'U'
    ) IS NULL
    BEGIN

        CREATE TABLE dbo.MetricEventRegistry
        (
            InstanceID INT NOT NULL,

            ResourceID BIGINT NOT NULL,

            MetricDefinitionID INT NOT NULL,

            EventGeneration NVARCHAR(128)
                COLLATE Latin1_General_100_BIN2 NOT NULL,

            FirstCollectionRunID BIGINT NOT NULL,

            FirstSeenDateUTC DATETIME2(3) NOT NULL
                DEFAULT (SYSUTCDATETIME()),

            CONSTRAINT PK_MetricEventRegistry
                PRIMARY KEY CLUSTERED
                (
                    InstanceID,
                    ResourceID,
                    MetricDefinitionID,
                    EventGeneration
                ),

            CONSTRAINT FK_MER_Resource
                FOREIGN KEY
                (
                    InstanceID,
                    ResourceID
                )
                REFERENCES dbo.MonitoredResources
                (
                    InstanceID,
                    ResourceID
                ),

            CONSTRAINT FK_MER_MetricDefinition
                FOREIGN KEY (MetricDefinitionID)
                REFERENCES dbo.MetricDefinitions
                (MetricDefinitionID)
        );

    END;

    --------------------------------------------------------
    -- TABLE 15: Hourly Metric Aggregates
    --------------------------------------------------------

    IF OBJECT_ID
    (
        'dbo.MetricHourlyAggregates',
        'U'
    ) IS NULL
    BEGIN

        CREATE TABLE dbo.MetricHourlyAggregates
        (
            InstanceID INT NOT NULL,

            ResourceID BIGINT NOT NULL,

            MetricDefinitionID INT NOT NULL,

            HourStartUTC DATETIME2(0) NOT NULL,

            MetricUnit VARCHAR(30) NOT NULL,

            AggregationType VARCHAR(20) NOT NULL,

            SampleCount BIGINT NOT NULL,

            MinimumValue DECIMAL(28,4) NOT NULL,

            MaximumValue DECIMAL(28,4) NOT NULL,

            AverageValue DECIMAL(38,6) NOT NULL,

            SumValue DECIMAL(38,4) NOT NULL,

            FirstCaptureDateUTC DATETIME2(3) NOT NULL,

            LastCaptureDateUTC DATETIME2(3) NOT NULL,

            AggregatedDateUTC DATETIME2(3) NOT NULL
                DEFAULT (SYSUTCDATETIME()),

            CONSTRAINT PK_MetricHourlyAggregates
                PRIMARY KEY CLUSTERED
                (
                    HourStartUTC,
                    InstanceID,
                    ResourceID,
                    MetricDefinitionID,
                    MetricUnit,
                    AggregationType
                ),

            CONSTRAINT FK_MHA_Resource
                FOREIGN KEY
                (
                    InstanceID,
                    ResourceID
                )
                REFERENCES dbo.MonitoredResources
                (
                    InstanceID,
                    ResourceID
                ),

            CONSTRAINT FK_MHA_MetricDefinition
                FOREIGN KEY (MetricDefinitionID)
                REFERENCES dbo.MetricDefinitions
                (MetricDefinitionID),

            CONSTRAINT CK_MHA_AggregationType
                CHECK
                (
                    AggregationType IN
                    (
                        'GAUGE',
                        'DELTA'
                    )
                )
        );

    END;

    --------------------------------------------------------
    -- SECTION 5: Historical Sample Metadata
    --------------------------------------------------------

    /*
    Distinguish raw observations from calculated deltas.

    IntervalStartUTC records the previous observation time
    used to calculate a cumulative counter difference.
    */

    IF COL_LENGTH
    (
        'dbo.MetricSamples',
        'SampleKind'
    ) IS NULL
    BEGIN

        ALTER TABLE dbo.MetricSamples

        ADD SampleKind VARCHAR(20) NOT NULL

            CONSTRAINT DF_MS_SampleKind
            DEFAULT ('RAW'),

            CONSTRAINT CK_MS_SampleKind
            CHECK
            (
                SampleKind IN
                (
                    'RAW',
                    'DELTA',
                    'EVENT',
                    'STATE'
                )
            );

    END;

    IF COL_LENGTH
    (
        'dbo.MetricSamples',
        'IntervalStartUTC'
    ) IS NULL
    BEGIN

        ALTER TABLE dbo.MetricSamples

        ADD IntervalStartUTC DATETIME2(3) NULL;

    END;

    --------------------------------------------------------
    -- SECTION 6: Supporting Indexes
    --------------------------------------------------------

    IF NOT EXISTS
    (
        SELECT 1
        FROM sys.indexes

        WHERE object_id =
            OBJECT_ID('dbo.MetricEventRegistry')

          AND name =
            'IX_MER_FirstSeenDate'
    )
    BEGIN

        CREATE NONCLUSTERED INDEX IX_MER_FirstSeenDate

        ON dbo.MetricEventRegistry
        (
            FirstSeenDateUTC
        )

        WITH (MAXDOP = 1);

    END;

    IF NOT EXISTS
    (
        SELECT 1
        FROM sys.indexes

        WHERE object_id =
            OBJECT_ID('dbo.MetricHourlyAggregates')

          AND name =
            'IX_MHA_ResourceMetricHistory'
    )
    BEGIN

        CREATE NONCLUSTERED INDEX
            IX_MHA_ResourceMetricHistory

        ON dbo.MetricHourlyAggregates
        (
            InstanceID,
            ResourceID,
            MetricDefinitionID,
            HourStartUTC DESC
        )

        WITH (MAXDOP = 1);

    END;

    --------------------------------------------------------
    -- PROCEDURE 01: Central Metric Ingestion
    --------------------------------------------------------

    EXEC sys.sp_executesql N'

    CREATE OR ALTER PROCEDURE dbo.usp_IngestMetricSamples
    (
        @CollectionRunID BIGINT,

        @RunToken UNIQUEIDENTIFIER,

        @Samples dbo.MetricSampleInput READONLY,

        @CounterEpoch NVARCHAR(128) = NULL,

        @EventGeneration NVARCHAR(128) = NULL,

        @RowsStored BIGINT OUTPUT
    )
    AS
    BEGIN

        SET NOCOUNT ON;
        SET XACT_ABORT ON;

        DECLARE
            @InstanceID INT,
            @CollectorID INT,
            @ModuleID VARCHAR(10),
            @ExpectedServerName NVARCHAR(128),
            @MaximumOutputRows INT,
            @RowsReturned BIGINT,
            @CurrentUTC DATETIME2(3),
            @LockResult INT,
            @LockResource NVARCHAR(255);

        SET @RowsStored = 0;

        SET @CurrentUTC = SYSUTCDATETIME();

        ----------------------------------------------------
        -- Require atomic caller transaction
        ----------------------------------------------------

        IF @@TRANCOUNT = 0 OR XACT_STATE() <> 1
            THROW 51001,
                ''Ingestion requires a committable transaction.'',
                1;

        IF @RunToken IS NULL
            THROW 51002,
                ''Run token is required.'',
                1;

        ----------------------------------------------------
        -- Coordinate ingestion with aggregation and retention.
        -- Shared locks permit concurrent ingestion across instances.
        ----------------------------------------------------
        EXEC @LockResult = sys.sp_getapplock
            @Resource = N''DBA_Monitoring.HistoricalMaintenance'',
            @LockMode = ''Shared'',
            @LockOwner = ''Transaction'',
            @LockTimeout = 5000;

        IF @LockResult < 0
            THROW 51013,
                ''Unable to acquire historical ingestion lock.'',
                1;

        ----------------------------------------------------
        -- Validate current collection ownership
        ----------------------------------------------------

        SELECT
            @InstanceID = R.InstanceID,

            @CollectorID = R.CollectorID,

            @ModuleID = C.ModuleID,

            @ExpectedServerName = I.ServerName,

            @MaximumOutputRows = C.MaximumOutputRows

        FROM dbo.CollectionRuns AS R
            WITH (UPDLOCK, HOLDLOCK)

        INNER JOIN dbo.Collectors AS C
            ON R.CollectorID = C.CollectorID

        INNER JOIN dbo.MonitoredInstances AS I
            ON R.InstanceID = I.InstanceID

        WHERE R.CollectionRunID = @CollectionRunID

          AND R.RunToken = @RunToken

          AND R.RunStatus = ''RUNNING''

          AND R.RowsReturned = 0;

        IF @InstanceID IS NULL
            THROW 51003,
                ''Invalid, finalized or already ingested run.'',
                1;

        IF NULLIF(@ExpectedServerName, N'''') IS NULL
            THROW 51004,
                ''Actual instance identity is not validated.'',
                1;

        ----------------------------------------------------
        -- Serialize ingestion for the same instance
        ----------------------------------------------------

        SET @LockResource =
            CONCAT
            (
                N''DBA_Monitoring.Ingestion.'',
                @InstanceID
            );

        EXEC @LockResult = sys.sp_getapplock
            @Resource = @LockResource,
            @LockMode = ''Exclusive'',
            @LockOwner = ''Transaction'',
            @LockTimeout = 5000;

        IF @LockResult < 0
            THROW 51005,
                ''Unable to acquire ingestion lock.'',
                1;

        ----------------------------------------------------
        -- Validate output volume
        ----------------------------------------------------

        SELECT @RowsReturned = COUNT_BIG(*)
        FROM @Samples;

        IF @RowsReturned = 0
            THROW 51006,
                ''Empty collector output.'',
                1;

        IF @RowsReturned > @MaximumOutputRows
            THROW 51007,
                ''Collector output exceeded configured limit.'',
                1;

        ----------------------------------------------------
        -- Validate collector output contract
        ----------------------------------------------------

        IF EXISTS
        (
            SELECT 1

            FROM @Samples

            WHERE ModuleID <> @ModuleID

               OR ServerName <> @ExpectedServerName

               OR CaptureDateUTC >
                  DATEADD(MINUTE, 5, @CurrentUTC)

               OR NULLIF
                  (
                      LTRIM(RTRIM(ResourceName)),
                      N''''
                  ) IS NULL

               OR NULLIF
                  (
                      LTRIM(RTRIM(ResourceType)),
                      ''''
                  ) IS NULL

               OR NULLIF
                  (
                      LTRIM(RTRIM(MetricUnit)),
                      ''''
                  ) IS NULL

               OR CollectionStatus NOT IN
                  (
                      ''SUCCESS'',
                      ''UNKNOWN'',
                      ''FAILED'',
                      ''STALE'',
                      ''NOT APPLICABLE''
                  )

               OR
                  (
                      CollectionStatus = ''SUCCESS''
                      AND MetricValue IS NULL
                  )
        )
        BEGIN

            THROW 51008,
                ''Invalid collector output detected.'',
                1;

        END;

        ----------------------------------------------------
        -- Prevent duplicate metrics within one run
        ----------------------------------------------------

        IF EXISTS
        (
            SELECT
                ResourceType,
                ResourceName,
                MetricID

            FROM @Samples

            GROUP BY
                ResourceType,
                ResourceName,
                MetricID

            HAVING COUNT_BIG(*) > 1
        )
        BEGIN

            THROW 51009,
                ''Duplicate resource metrics detected.'',
                1;

        END;

        ----------------------------------------------------
        -- Validate registered metric definitions
        ----------------------------------------------------

        IF EXISTS
        (
            SELECT 1

            FROM @Samples AS S

            LEFT JOIN dbo.MetricDefinitions AS D

                ON D.CollectorID = @CollectorID

               AND D.MetricID = S.MetricID

           WHERE D.MetricDefinitionID IS NULL

           OR S.Category <> D.Category

           OR S.ResourceType <> D.ResourceType

           OR
           (
               S.MetricUnit <> D.DefaultMetricUnit
               AND NOT
               (
                   S.MetricID = ''TMP-012''
                   AND D.DefaultMetricUnit = ''MB''
                   AND S.MetricUnit = ''Percent''
               )
           )
        )
        BEGIN

            THROW 51010,
                ''Unregistered metric or incompatible category, resource type or unit.'',
                1;

        END;

        ----------------------------------------------------
        -- Close hourly input 15 minutes after the UTC hour ends.
        -- Reject delayed aggregate-eligible observations before
        -- updating resources, baselines, history or checkpoints.
        -- Refresh time after obtaining the maintenance lock.
        ----------------------------------------------------
        SET @CurrentUTC = SYSUTCDATETIME();

        IF EXISTS
        (
            SELECT 1
            FROM @Samples AS S
            INNER JOIN dbo.MetricDefinitions AS D
                ON D.CollectorID = @CollectorID
               AND D.MetricID = S.MetricID
            WHERE D.IsEnabled = 1
              AND S.CollectionStatus = ''SUCCESS''
              AND
              (
                  (D.StoragePolicy = ''RAW''
                   AND D.MetricBehavior = ''GAUGE'')
                  OR D.StoragePolicy = ''DELTA''
              )
              AND
              (
                  DATEADD(HOUR, DATEDIFF(HOUR, CONVERT(DATETIME2(0), ''20000101''), S.CaptureDateUTC) + 1, CONVERT(DATETIME2(0), ''20000101''))
                      <= DATEADD(MINUTE, -15, @CurrentUTC)
                  OR EXISTS
                  (
                      SELECT 1
                      FROM dbo.MetricHourlyAggregates AS A
                      WHERE A.HourStartUTC = DATEADD(HOUR,
                          DATEDIFF(HOUR, CONVERT(DATETIME2(0), ''20000101''), S.CaptureDateUTC), CONVERT(DATETIME2(0), ''20000101''))
                  )
              )
        )
            THROW 51014,
                ''Aggregate-eligible observation belongs to a closed UTC hour; roll back and record failure.'',
                1;

        ----------------------------------------------------
        -- Validate cumulative processing requirements
        ----------------------------------------------------

        IF EXISTS
        (
            SELECT 1

            FROM @Samples AS S

            INNER JOIN dbo.MetricDefinitions AS D

                ON D.CollectorID = @CollectorID

               AND D.MetricID = S.MetricID

            WHERE D.IsEnabled = 1

              AND D.StoragePolicy = ''DELTA''

              AND
              (
                  D.MetricBehavior <> ''COUNTER''

                  OR NULLIF(@CounterEpoch, N'''') IS NULL

                  OR
                  (
                      S.CollectionStatus = ''SUCCESS''
                      AND S.MetricValue < 0
                  )
              )
        )
        BEGIN

            THROW 51011,
                ''Invalid counter definition or missing counter epoch.'',
                1;

        END;

        ----------------------------------------------------
        -- Validate event processing requirements
        ----------------------------------------------------

        IF EXISTS
        (
            SELECT 1

            FROM @Samples AS S

            INNER JOIN dbo.MetricDefinitions AS D

                ON D.CollectorID = @CollectorID

               AND D.MetricID = S.MetricID

            WHERE D.IsEnabled = 1

              AND D.StoragePolicy = ''EVENT_ONLY''

              AND NULLIF(@EventGeneration, N'''') IS NULL
        )
        BEGIN

            THROW 51012,
                ''Stable source event generation is required.'',
                1;

        END;

        ----------------------------------------------------
        -- Register newly discovered resources
        ----------------------------------------------------

        INSERT INTO dbo.MonitoredResources
        (
            InstanceID,
            ResourceType,
            ResourceName,
            FirstSeenDateUTC,
            LastSeenDateUTC,
            IsActive
        )

        SELECT DISTINCT
            @InstanceID,

            S.ResourceType,

            S.ResourceName,

            @CurrentUTC,

            @CurrentUTC,

            1

        FROM @Samples AS S

        INNER JOIN dbo.MetricDefinitions AS D

            ON D.CollectorID = @CollectorID

           AND D.MetricID = S.MetricID

           AND D.IsEnabled = 1

        WHERE NOT EXISTS
        (
            SELECT 1

            FROM dbo.MonitoredResources AS R
                WITH (UPDLOCK, HOLDLOCK)

            WHERE R.InstanceID = @InstanceID

              AND R.ResourceType = S.ResourceType

              AND R.ResourceName = S.ResourceName
        );

        ----------------------------------------------------
        -- Resolve registered resource and metric IDs
        ----------------------------------------------------

        SELECT
            S.CaptureDateUTC,

            S.MetricValue,

            S.MetricUnit,

            S.CollectionStatus,

            S.ErrorMessage,

            R.ResourceID,

            D.MetricDefinitionID,

            D.MetricBehavior,

            D.StoragePolicy

        INTO #ResolvedSamples

        FROM @Samples AS S

        INNER JOIN dbo.MetricDefinitions AS D

            ON D.CollectorID = @CollectorID

           AND D.MetricID = S.MetricID

           AND D.IsEnabled = 1

        INNER JOIN dbo.MonitoredResources AS R

            ON R.InstanceID = @InstanceID

           AND R.ResourceType = S.ResourceType

           AND R.ResourceName = S.ResourceName;

        CREATE UNIQUE CLUSTERED INDEX
            IX_ResolvedSamples

        ON #ResolvedSamples
        (
            ResourceID,
            MetricDefinitionID
        );

        ----------------------------------------------------
        -- Refresh resource observation timestamps
        ----------------------------------------------------

        UPDATE R

        SET LastSeenDateUTC = @CurrentUTC,

            IsActive = 1

        FROM dbo.MonitoredResources AS R

        WHERE R.InstanceID = @InstanceID

          AND EXISTS
          (
              SELECT 1

              FROM #ResolvedSamples AS S

              WHERE S.ResourceID = R.ResourceID
          );

        ----------------------------------------------------
        -- Stage historical records
        ----------------------------------------------------

        CREATE TABLE #HistoryRows
        (
            ResourceID BIGINT NOT NULL,

            MetricDefinitionID INT NOT NULL,

            CaptureDateUTC DATETIME2(3) NOT NULL,

            MetricValue DECIMAL(28,4) NULL,

            MetricUnit VARCHAR(30) NOT NULL,

            CollectionStatus VARCHAR(20) NOT NULL,

            ErrorMessage NVARCHAR(2048) NULL,

            SampleKind VARCHAR(20) NOT NULL,

            IntervalStartUTC DATETIME2(3) NULL,

            PRIMARY KEY
            (
                ResourceID,
                MetricDefinitionID
            )
        );

        ----------------------------------------------------
        -- RAW storage policy
        ----------------------------------------------------

        INSERT INTO #HistoryRows

        SELECT
            S.ResourceID,

            S.MetricDefinitionID,

            S.CaptureDateUTC,

            S.MetricValue,

            S.MetricUnit,

            S.CollectionStatus,

            S.ErrorMessage,

            ''RAW'',

            NULL

        FROM #ResolvedSamples AS S

        WHERE S.StoragePolicy = ''RAW'';

        ----------------------------------------------------
        -- ON_CHANGE storage policy
        ----------------------------------------------------

        INSERT INTO #HistoryRows

        SELECT
            S.ResourceID,

            S.MetricDefinitionID,

            S.CaptureDateUTC,

            S.MetricValue,

            S.MetricUnit,

            S.CollectionStatus,

            S.ErrorMessage,

            ''STATE'',

            NULL

        FROM #ResolvedSamples AS S

        LEFT JOIN dbo.LatestMetrics AS L

            ON L.InstanceID = @InstanceID

           AND L.ResourceID = S.ResourceID

           AND L.MetricDefinitionID =
               S.MetricDefinitionID

        WHERE S.StoragePolicy = ''ON_CHANGE''

          AND
          (
              L.ResourceID IS NULL

              OR S.CaptureDateUTC > L.CaptureDateUTC
          )

          AND
          (
              L.ResourceID IS NULL

              OR S.MetricValue <> L.MetricValue

              OR
              (
                  S.MetricValue IS NULL
                  AND L.MetricValue IS NOT NULL
              )

              OR
              (
                  S.MetricValue IS NOT NULL
                  AND L.MetricValue IS NULL
              )

              OR S.CollectionStatus <>
                 L.CollectionStatus

              OR S.MetricUnit <> L.MetricUnit

              OR ISNULL(S.ErrorMessage, N'''') <>
                 ISNULL(L.ErrorMessage, N'''')
          );

        ----------------------------------------------------
        -- DELTA storage policy
        ----------------------------------------------------

        /*
        Only calculate a difference when:

        1. A previous successful baseline exists.
        2. The source epoch is unchanged.
        3. Units are unchanged.
        4. The new sample is newer.
        5. The cumulative counter has not decreased.
        */

        INSERT INTO #HistoryRows

        SELECT
            S.ResourceID,

            S.MetricDefinitionID,

            S.CaptureDateUTC,

            S.MetricValue - B.CounterValue,

            S.MetricUnit,

            S.CollectionStatus,

            S.ErrorMessage,

            ''DELTA'',

            B.CaptureDateUTC

        FROM #ResolvedSamples AS S

        INNER JOIN dbo.MetricCounterBaselines AS B

            ON B.InstanceID = @InstanceID

           AND B.ResourceID = S.ResourceID

           AND B.MetricDefinitionID =
               S.MetricDefinitionID

        WHERE S.StoragePolicy = ''DELTA''

          AND S.CollectionStatus = ''SUCCESS''

          AND B.CounterEpoch = @CounterEpoch

          AND S.MetricUnit = B.CounterUnit

          AND S.CaptureDateUTC > B.CaptureDateUTC

          AND S.MetricValue >= B.CounterValue;

        ----------------------------------------------------
        -- Refresh existing cumulative baselines
        ----------------------------------------------------

        UPDATE B

        SET CaptureDateUTC = S.CaptureDateUTC,

            CounterValue = S.MetricValue,

            CounterUnit = S.MetricUnit,

            CounterEpoch = @CounterEpoch,

            CollectionRunID = @CollectionRunID,

            UpdatedDateUTC = @CurrentUTC

        FROM dbo.MetricCounterBaselines AS B

        INNER JOIN #ResolvedSamples AS S

            ON B.ResourceID = S.ResourceID

           AND B.MetricDefinitionID =
               S.MetricDefinitionID

        WHERE B.InstanceID = @InstanceID

          AND S.StoragePolicy = ''DELTA''

          AND S.CollectionStatus = ''SUCCESS''

          AND S.CaptureDateUTC > B.CaptureDateUTC;

        ----------------------------------------------------
        -- Initialize missing cumulative baselines
        ----------------------------------------------------

        INSERT INTO dbo.MetricCounterBaselines
        (
            InstanceID,
            ResourceID,
            MetricDefinitionID,
            CaptureDateUTC,
            CounterValue,
            CounterUnit,
            CounterEpoch,
            CollectionRunID,
            UpdatedDateUTC
        )

        SELECT
            @InstanceID,

            S.ResourceID,

            S.MetricDefinitionID,

            S.CaptureDateUTC,

            S.MetricValue,

            S.MetricUnit,

            @CounterEpoch,

            @CollectionRunID,

            @CurrentUTC

        FROM #ResolvedSamples AS S

        WHERE S.StoragePolicy = ''DELTA''

          AND S.CollectionStatus = ''SUCCESS''

          AND NOT EXISTS
          (
              SELECT 1

              FROM dbo.MetricCounterBaselines AS B

              WHERE B.InstanceID = @InstanceID

                AND B.ResourceID = S.ResourceID

                AND B.MetricDefinitionID =
                    S.MetricDefinitionID
          );

        ----------------------------------------------------
        -- EVENT_ONLY storage policy
        ----------------------------------------------------

        INSERT INTO #HistoryRows

        SELECT
            S.ResourceID,

            S.MetricDefinitionID,

            S.CaptureDateUTC,

            S.MetricValue,

            S.MetricUnit,

            S.CollectionStatus,

            S.ErrorMessage,

            ''EVENT'',

            NULL

        FROM #ResolvedSamples AS S

        WHERE S.StoragePolicy = ''EVENT_ONLY''

          AND S.CollectionStatus = ''SUCCESS''

          AND NOT EXISTS
          (
              SELECT 1

              FROM dbo.MetricEventRegistry AS E
                  WITH (UPDLOCK, HOLDLOCK)

              WHERE E.InstanceID = @InstanceID

                AND E.ResourceID = S.ResourceID

                AND E.MetricDefinitionID =
                    S.MetricDefinitionID

                AND E.EventGeneration =
                    @EventGeneration
          );

        ----------------------------------------------------
        -- Register newly accepted events
        ----------------------------------------------------

        INSERT INTO dbo.MetricEventRegistry
        (
            InstanceID,
            ResourceID,
            MetricDefinitionID,
            EventGeneration,
            FirstCollectionRunID,
            FirstSeenDateUTC
        )

        SELECT
            @InstanceID,

            H.ResourceID,

            H.MetricDefinitionID,

            @EventGeneration,

            @CollectionRunID,

            @CurrentUTC

        FROM #HistoryRows AS H

        WHERE H.SampleKind = ''EVENT'';

        ----------------------------------------------------
        -- Store selected historical observations
        ----------------------------------------------------

        INSERT INTO dbo.MetricSamples
        (
            CollectionRunID,
            InstanceID,
            ResourceID,
            MetricDefinitionID,
            CaptureDateUTC,
            MetricValue,
            MetricUnit,
            CollectionStatus,
            ErrorMessage,
            SampleKind,
            IntervalStartUTC
        )

        SELECT
            @CollectionRunID,

            @InstanceID,

            H.ResourceID,

            H.MetricDefinitionID,

            H.CaptureDateUTC,

            H.MetricValue,

            H.MetricUnit,

            H.CollectionStatus,

            H.ErrorMessage,

            H.SampleKind,

            H.IntervalStartUTC

        FROM #HistoryRows AS H;

        SET @RowsStored = @@ROWCOUNT;

        ----------------------------------------------------
        -- Update latest observed values
        ----------------------------------------------------

        UPDATE L

        SET CollectionRunID = @CollectionRunID,

            CaptureDateUTC = S.CaptureDateUTC,

            MetricValue = S.MetricValue,

            MetricUnit = S.MetricUnit,

            CollectionStatus = S.CollectionStatus,

            ErrorMessage = S.ErrorMessage,

            LastSuccessfulCaptureUTC =

                CASE

                    WHEN S.CollectionStatus = ''SUCCESS''

                    THEN S.CaptureDateUTC

                    ELSE L.LastSuccessfulCaptureUTC

                END,

            LastSuccessfulValue =

                CASE

                    WHEN S.CollectionStatus = ''SUCCESS''

                    THEN S.MetricValue

                    ELSE L.LastSuccessfulValue

                END,

            LastSuccessfulUnit =

                CASE

                    WHEN S.CollectionStatus = ''SUCCESS''

                    THEN S.MetricUnit

                    ELSE L.LastSuccessfulUnit

                END,

            UpdatedDateUTC = @CurrentUTC

        FROM dbo.LatestMetrics AS L

        INNER JOIN #ResolvedSamples AS S

            ON L.ResourceID = S.ResourceID

           AND L.MetricDefinitionID =
               S.MetricDefinitionID

        WHERE L.InstanceID = @InstanceID

          AND S.StoragePolicy <> ''EVENT_ONLY''

          AND
          (
              S.CaptureDateUTC > L.CaptureDateUTC

              OR
              (
                  S.CaptureDateUTC = L.CaptureDateUTC

                  AND @CollectionRunID >
                      L.CollectionRunID
              )
          );
----------------------------------------------------
-- Preserve delayed successful observations
----------------------------------------------------

UPDATE L

SET LastSuccessfulCaptureUTC = S.CaptureDateUTC,

    LastSuccessfulValue = S.MetricValue,

    LastSuccessfulUnit = S.MetricUnit,

    UpdatedDateUTC = @CurrentUTC

FROM dbo.LatestMetrics AS L

INNER JOIN #ResolvedSamples AS S

    ON L.ResourceID = S.ResourceID

   AND L.MetricDefinitionID =
       S.MetricDefinitionID

WHERE L.InstanceID = @InstanceID

  AND S.StoragePolicy <> ''EVENT_ONLY''

  AND S.CollectionStatus = ''SUCCESS''

  AND
  (
      L.LastSuccessfulCaptureUTC IS NULL

      OR S.CaptureDateUTC >
         L.LastSuccessfulCaptureUTC
  );
        ----------------------------------------------------
        -- Initialize new latest observations
        ----------------------------------------------------

        INSERT INTO dbo.LatestMetrics
        (
            InstanceID,
            ResourceID,
            MetricDefinitionID,
            CollectionRunID,
            CaptureDateUTC,
            MetricValue,
            MetricUnit,
            CollectionStatus,
            ErrorMessage,
            LastSuccessfulCaptureUTC,
            LastSuccessfulValue,
            LastSuccessfulUnit,
            UpdatedDateUTC
        )

        SELECT
            @InstanceID,

            S.ResourceID,

            S.MetricDefinitionID,

            @CollectionRunID,

            S.CaptureDateUTC,

            S.MetricValue,

            S.MetricUnit,

            S.CollectionStatus,

            S.ErrorMessage,

            CASE

                WHEN S.CollectionStatus = ''SUCCESS''

                THEN S.CaptureDateUTC

            END,

            CASE

                WHEN S.CollectionStatus = ''SUCCESS''

                THEN S.MetricValue

            END,

            CASE

                WHEN S.CollectionStatus = ''SUCCESS''

                THEN S.MetricUnit

            END,

            @CurrentUTC

        FROM #ResolvedSamples AS S

        WHERE S.StoragePolicy <> ''EVENT_ONLY''

          AND NOT EXISTS
          (
              SELECT 1

              FROM dbo.LatestMetrics AS L

              WHERE L.InstanceID = @InstanceID

                AND L.ResourceID = S.ResourceID

                AND L.MetricDefinitionID =
                    S.MetricDefinitionID
          );

        ----------------------------------------------------
        -- Record ingestion counts
        ----------------------------------------------------

        UPDATE dbo.CollectionRuns

        SET RowsReturned = @RowsReturned,

            RowsStored = @RowsStored

        WHERE CollectionRunID = @CollectionRunID

          AND RunToken = @RunToken

          AND RunStatus = ''RUNNING'';

        ----------------------------------------------------
        -- Return ingestion summary
        ----------------------------------------------------

        SELECT
            @CollectionRunID AS CollectionRunID,

            @InstanceID AS InstanceID,

            @CollectorID AS CollectorID,

            @RowsReturned AS RowsReturned,

            @RowsStored AS HistoricalRowsStored,

            @RowsReturned - @RowsStored
                AS RowsNotStoredAsHistory,

            ''PENDING CALLER COMMIT''
                AS TransactionStatus;

        /*
        The caller must now:

        1. Save checkpoints when applicable.
        2. Finalize the collection run.
        3. Commit the entire transaction.

        Any exception requires a complete rollback.
        */

    END;

    ';

    --------------------------------------------------------
    -- PROCEDURE 02: Hourly Historical Aggregation
    --------------------------------------------------------

    EXEC sys.sp_executesql N'

    CREATE OR ALTER PROCEDURE
        dbo.usp_AggregateHourlyMetrics
    (
        @HourStartUTC DATETIME2(0),

        @AllowAggregation BIT = 0
    )
    AS
    BEGIN

        SET NOCOUNT ON;
        SET XACT_ABORT ON;

        DECLARE
            @HourEndUTC DATETIME2(0),

            @CurrentUTC DATETIME2(3) =
                SYSUTCDATETIME(),

            @RowsAggregated BIGINT = 0,

            @LockResult INT;

        IF @HourStartUTC IS NULL
            THROW 51101,
                ''Aggregation hour is required.'',
                1;

        IF DATEPART(MINUTE, @HourStartUTC) <> 0

        OR DATEPART(SECOND, @HourStartUTC) <> 0

            THROW 51102,
                ''Aggregation start must align to a UTC hour.'',
                1;

        SET @HourEndUTC =
            DATEADD(HOUR, 1, @HourStartUTC);

        IF @HourEndUTC > DATEADD
        (
            MINUTE,
            -15,
            @CurrentUTC
        )
        BEGIN

            THROW 51103,
                ''Aggregation hour is not sufficiently complete.'',
                1;

        END;

        ----------------------------------------------------
        -- Preview aggregation scope
        ----------------------------------------------------

        IF ISNULL(@AllowAggregation, 0) <> 1
        BEGIN

            SELECT
                @HourStartUTC AS HourStartUTC,

                @HourEndUTC AS HourEndUTC,

                COUNT_BIG(*) AS EligibleHistoricalRows,

                ''PREVIEW ONLY'' AS ExecutionStatus

            FROM dbo.MetricSamples AS S

            INNER JOIN dbo.MetricDefinitions AS D

                ON S.MetricDefinitionID =
                   D.MetricDefinitionID

            WHERE S.CaptureDateUTC >= @HourStartUTC

              AND S.CaptureDateUTC < @HourEndUTC

              AND S.CollectionStatus = ''SUCCESS''

              AND S.MetricValue IS NOT NULL

              AND
              (
                  (
                      S.SampleKind = ''RAW''

                      AND D.MetricBehavior = ''GAUGE''
                  )

                  OR S.SampleKind = ''DELTA''
              );

            RETURN;

        END;

        IF @@TRANCOUNT <> 0
            THROW 51104,
                ''Aggregation requires an independent transaction.'',
                1;
        IF (@@OPTIONS & 2) = 2
    THROW 51107,
        ''Implicit transactions must be disabled before aggregation.'',
        1;

        BEGIN TRY

            BEGIN TRANSACTION;

            ------------------------------------------------
            -- Coordinate with future retention processing
            ------------------------------------------------

            EXEC @LockResult = sys.sp_getapplock

                @Resource =
                    N''DBA_Monitoring.HistoricalMaintenance'',

                @LockMode = ''Exclusive'',

                @LockOwner = ''Transaction'',

                @LockTimeout = 5000;

            IF @LockResult < 0
                THROW 51105,
                    ''Unable to acquire maintenance lock.'',
                    1;

            ------------------------------------------------
            -- Build one hourly aggregation batch
            ------------------------------------------------

            SELECT
                S.InstanceID,

                S.ResourceID,

                S.MetricDefinitionID,

                S.MetricUnit,

                CASE

                    WHEN S.SampleKind = ''DELTA''

                    THEN ''DELTA''

                    ELSE ''GAUGE''

                END AS AggregationType,

                COUNT_BIG(*) AS SampleCount,

                MIN(S.MetricValue) AS MinimumValue,

                MAX(S.MetricValue) AS MaximumValue,

                AVG
                (
                    CONVERT
                    (
                        DECIMAL(38,6),
                        S.MetricValue
                    )
                ) AS AverageValue,

                SUM
                (
                    CONVERT
                    (
                        DECIMAL(38,4),
                        S.MetricValue
                    )
                ) AS SumValue,

                MIN(S.CaptureDateUTC)
                    AS FirstCaptureDateUTC,

                MAX(S.CaptureDateUTC)
                    AS LastCaptureDateUTC

            INTO #Hourly

            FROM dbo.MetricSamples AS S

            INNER JOIN dbo.MetricDefinitions AS D

                ON S.MetricDefinitionID =
                   D.MetricDefinitionID

            WHERE S.CaptureDateUTC >= @HourStartUTC

              AND S.CaptureDateUTC < @HourEndUTC

              AND S.CollectionStatus = ''SUCCESS''

              AND S.MetricValue IS NOT NULL

              AND
              (
                  (
                      S.SampleKind = ''RAW''

                      AND D.MetricBehavior = ''GAUGE''
                  )

                  OR S.SampleKind = ''DELTA''
              )

            GROUP BY
                S.InstanceID,

                S.ResourceID,

                S.MetricDefinitionID,

                S.MetricUnit,

                CASE

                    WHEN S.SampleKind = ''DELTA''

                    THEN ''DELTA''

                    ELSE ''GAUGE''

                END

            OPTION (MAXDOP 1);

            ------------------------------------------------
            -- Prevent silent overwriting of existing rollups
            ------------------------------------------------

            IF EXISTS
            (
                SELECT 1

                FROM dbo.MetricHourlyAggregates

                WHERE HourStartUTC = @HourStartUTC
            )
            BEGIN

                THROW 51106,
                    ''Hour already aggregated. Reconciliation required.'',
                    1;

            END;

            ------------------------------------------------
            -- Persist hourly historical summaries
            ------------------------------------------------

            INSERT INTO dbo.MetricHourlyAggregates
            (
                InstanceID,
                ResourceID,
                MetricDefinitionID,
                HourStartUTC,
                MetricUnit,
                AggregationType,
                SampleCount,
                MinimumValue,
                MaximumValue,
                AverageValue,
                SumValue,
                FirstCaptureDateUTC,
                LastCaptureDateUTC,
                AggregatedDateUTC
            )

            SELECT
                H.InstanceID,

                H.ResourceID,

                H.MetricDefinitionID,

                @HourStartUTC,

                H.MetricUnit,

                H.AggregationType,

                H.SampleCount,

                H.MinimumValue,

                H.MaximumValue,

                H.AverageValue,

                H.SumValue,

                H.FirstCaptureDateUTC,

                H.LastCaptureDateUTC,

                @CurrentUTC

            FROM #Hourly AS H;

            SET @RowsAggregated = @@ROWCOUNT;

            COMMIT TRANSACTION;

            SELECT
                @HourStartUTC AS HourStartUTC,

                @HourEndUTC AS HourEndUTC,

                @RowsAggregated AS AggregatedRows,

                ''SUCCESS'' AS AggregationStatus;

        END TRY

        BEGIN CATCH

            IF XACT_STATE() <> 0
                ROLLBACK TRANSACTION;

            THROW;

        END CATCH;

    END;

    ';

    --------------------------------------------------------
    -- PROCEDURE 03: Repository Storage Summary
    --------------------------------------------------------

    EXEC sys.sp_executesql N'

    CREATE OR ALTER PROCEDURE dbo.usp_MetricStorageSummary
    AS
    BEGIN

        SET NOCOUNT ON;

        ----------------------------------------------------
        -- Result 01: Monitoring table storage consumption
        ----------------------------------------------------

        SELECT
            T.name AS TableName,

            SUM
            (
                CASE

                    WHEN P.index_id IN (0,1)

                    THEN P.row_count

                    ELSE 0

                END
            ) AS TableRows,

            CONVERT
            (
                DECIMAL(18,2),

                SUM(P.reserved_page_count) / 128.0

            ) AS ReservedSpaceMB,

            CONVERT
            (
                DECIMAL(18,2),

                SUM(P.used_page_count) / 128.0

            ) AS UsedSpaceMB

        FROM sys.dm_db_partition_stats AS P

        INNER JOIN sys.tables AS T

            ON P.object_id = T.object_id

        INNER JOIN sys.schemas AS S

            ON T.schema_id = S.schema_id

        WHERE S.name = ''dbo''

          AND T.name IN
          (
              ''MetricSamples'',

              ''LatestMetrics'',

              ''MetricCounterBaselines'',

              ''MetricEventRegistry'',

              ''MetricHourlyAggregates'',

              ''MonitoredResources'',

              ''CollectionRuns'',

              ''CollectionCheckpoints'',

              ''CheckpointAudit''
          )

        GROUP BY T.name

        ORDER BY ReservedSpaceMB DESC;

        ----------------------------------------------------
        -- Result 02: Recent collector ingestion volume
        ----------------------------------------------------

        SELECT
            C.CollectorCode,

            C.CollectorName,

            COUNT_BIG(R.CollectionRunID)
                AS CollectionRuns,

            COALESCE(SUM(R.RowsReturned), 0)
                AS RowsReturned,

            COALESCE(SUM(R.RowsStored), 0)
                AS HistoricalRowsStored,

            COALESCE(SUM(R.RowsReturned), 0)

                - COALESCE(SUM(R.RowsStored), 0)

                AS RowsNotStoredAsHistory

        FROM dbo.Collectors AS C

        LEFT JOIN dbo.CollectionRuns AS R

            ON C.CollectorID = R.CollectorID

           AND R.StartDateUTC >=
               DATEADD
               (
                   HOUR,
                   -24,
                   SYSUTCDATETIME()
               )

           AND R.RunStatus IN
               (''SUCCESS'', ''PARTIAL'')

        GROUP BY
            C.CollectorCode,
            C.CollectorName

        ORDER BY HistoricalRowsStored DESC;

        ----------------------------------------------------
        -- Result 03: Database file allocation
        ----------------------------------------------------

        SELECT
            name AS LogicalFileName,

            type_desc AS FileType,

            physical_name AS PhysicalFileName,

            CONVERT
            (
                DECIMAL(18,2),
                CONVERT(BIGINT, size) / 128.0
            ) AS AllocatedSizeMB,

            CONVERT
            (
                DECIMAL(18,2),

                CASE

                    WHEN type = 0

                    THEN FILEPROPERTY
                    (
                        name,
                        ''SpaceUsed''
                    ) / 128.0

                END

            ) AS UsedDataSpaceMB

        FROM sys.database_files;

    END;

    ';

    --------------------------------------------------------
    -- SECTION 7: Register Schema Version
    --------------------------------------------------------

    IF NOT EXISTS
    (
        SELECT 1

        FROM dbo.SchemaVersion

        WHERE VersionNumber = '1.0.4'
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
            '1.0.4',

            N'08-Historical-Metrics.sql',

            ORIGINAL_LOGIN(),

            N'Metric ingestion, counter baselines,
              event deduplication and hourly aggregation.'
        );

    END;

    --------------------------------------------------------
    -- SECTION 8: Commit Deployment
    --------------------------------------------------------

    COMMIT TRANSACTION;

    SELECT
        @ActualServer AS MonitoringServer,

        DB_NAME() AS MonitoringDatabase,

        'SUCCESS' AS DeploymentStatus,

        '1.0.4' AS SchemaVersion,

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
-- SECTION 9: Object Verification
------------------------------------------------------------

SELECT
    S.name AS SchemaName,

    O.name AS ObjectName,

    O.type_desc AS ObjectType,

    O.create_date AS CreatedDate,

    O.modify_date AS ModifiedDate

FROM sys.objects AS O

INNER JOIN sys.schemas AS S
    ON O.schema_id = S.schema_id

WHERE S.name = 'dbo'

AND O.name IN
(
    'MetricCounterBaselines',

    'MetricEventRegistry',

    'MetricHourlyAggregates',

    'usp_IngestMetricSamples',

    'usp_AggregateHourlyMetrics',

    'usp_MetricStorageSummary'
)

ORDER BY O.type_desc, O.name;

------------------------------------------------------------
-- SECTION 10: Table Type Verification
------------------------------------------------------------

SELECT
    S.name AS SchemaName,

    T.name AS TableTypeName

FROM sys.table_types AS T

INNER JOIN sys.schemas AS S
    ON T.schema_id = S.schema_id

WHERE T.name = 'MetricSampleInput';

GO
