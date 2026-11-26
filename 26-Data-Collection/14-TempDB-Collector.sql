/*
============================================================
Project : SQL Server Production Optimization
Module  : 26 - Data Collection
Script  : 14-TempDB-Collector.sql
Purpose : Collect TempDB capacity and contention metrics
Type    : Read-Only Monitoring Collector
Impact  : Low - dependent on file and waiting task count
Frequency: 60 Seconds (Proposed)
============================================================
*/

USE tempdb;
GO

SET NOCOUNT ON;

-- Limit lock waits and favor application transactions in deadlocks.
SET LOCK_TIMEOUT 5000;
SET DEADLOCK_PRIORITY LOW;

------------------------------------------------------------
-- SECTION 1: Collection Variables
------------------------------------------------------------

DECLARE
    @CaptureDate DATETIME2(3) = SYSUTCDATETIME(),
    @CollectionStart DATETIME2(3) = SYSUTCDATETIME(),
    @ServerName NVARCHAR(128),

    @TotalPages BIGINT,
    @UnallocatedPages BIGINT,
    @AllocatedPages BIGINT,
    @UserObjectPages BIGINT,
    @InternalObjectPages BIGINT,
    @VersionStorePages BIGINT,
    @MixedExtentPages BIGINT,

    @DataFileCount INT,
    @LogFileCount INT,
    @UniformFileSize INT,
    @UniformFileGrowth INT,

    @PageLatchWaits BIGINT,
    @MaxPageLatchWaitMS BIGINT,
    @AllocationPageWaits BIGINT;

SET @ServerName =
    CONVERT(NVARCHAR(128), SERVERPROPERTY('ServerName'));

------------------------------------------------------------
-- SECTION 2: Monitoring Data Structure
------------------------------------------------------------

DECLARE @Metrics TABLE
(
    MetricID VARCHAR(30),
    Category VARCHAR(50),
    ResourceType VARCHAR(30),
    ResourceName NVARCHAR(256),
    MetricName VARCHAR(100),
    MetricValue DECIMAL(28,4),
    MetricUnit VARCHAR(30),
    CollectionStatus VARCHAR(20),
    ErrorMessage NVARCHAR(2048)
);

DECLARE @Files TABLE
(
    FileID INT PRIMARY KEY,
    FileType INT,
    SizePages BIGINT,
    GrowthValue BIGINT,
    IsPercentGrowth BIT,
    MaxSizePages BIGINT
);

DECLARE @FileSpace TABLE
(
    FileID INT PRIMARY KEY,
    TotalPages BIGINT,
    UnallocatedPages BIGINT,
    AllocatedPages BIGINT,
    UserObjectPages BIGINT,
    InternalObjectPages BIGINT,
    VersionStorePages BIGINT,
    MixedExtentPages BIGINT
);

DECLARE @LatchWaits TABLE
(
    SessionID INT,
    WaitDurationMS BIGINT,
    FileID INT,
    PageID BIGINT
);

------------------------------------------------------------
-- SECTION 3: TempDB File Inventory
------------------------------------------------------------

BEGIN TRY

    INSERT INTO @Files
    SELECT
        file_id,
        type,
        CONVERT(BIGINT, size),
        CONVERT(BIGINT, growth),
        is_percent_growth,
        CONVERT(BIGINT, max_size)

    FROM sys.database_files

    WHERE type IN (0, 1);

    SELECT

        @DataFileCount = COUNT(CASE
            WHEN FileType = 0 THEN 1 END),

        @LogFileCount = COUNT(CASE
            WHEN FileType = 1 THEN 1 END)

    FROM @Files;

    --------------------------------------------------------
    -- Data file size and growth uniformity
    --------------------------------------------------------

    SELECT

        @UniformFileSize =

            CASE

                WHEN COUNT(*) = 0 THEN NULL

                WHEN MIN(SizePages) = MAX(SizePages)
                    THEN 1

                ELSE 0

            END,

        @UniformFileGrowth =

            CASE

                WHEN COUNT(*) = 0 THEN NULL

                WHEN MIN(GrowthValue) = MAX(GrowthValue)

                 AND MIN(CONVERT(INT, IsPercentGrowth))
                     = MAX(CONVERT(INT, IsPercentGrowth))

                    THEN 1

                ELSE 0

            END

    FROM @Files

    WHERE FileType = 0;

    --------------------------------------------------------
    -- Database-level file configuration metrics
    --------------------------------------------------------

    INSERT INTO @Metrics
    SELECT
        M.MetricID,
        'TempDB Configuration',
        'Database',
        'tempdb',
        M.MetricName,
        M.MetricValue,
        M.MetricUnit,

        CASE
            WHEN M.MetricValue IS NULL
                THEN 'UNKNOWN'
            ELSE 'SUCCESS'
        END,

        CASE
            WHEN M.MetricValue IS NULL
                THEN 'TempDB file configuration unavailable.'
            ELSE NULL
        END

    FROM
    (
        VALUES

        (
            'TMP-009',
            'TempDB Data File Count',
            CONVERT(DECIMAL(28,4), @DataFileCount),
            'Count'
        ),
        (
            'TMP-010',
            'TempDB Log File Count',
            CONVERT(DECIMAL(28,4), @LogFileCount),
            'Count'
        ),
        (
            'TMP-020',
            'TempDB Data File Size Uniformity',
            CONVERT(DECIMAL(28,4), @UniformFileSize),
            'Boolean'
        ),
        (
            'TMP-021',
            'TempDB Data File Growth Uniformity',
            CONVERT(DECIMAL(28,4), @UniformFileGrowth),
            'Boolean'
        )

    ) AS M
    (
        MetricID,
        MetricName,
        MetricValue,
        MetricUnit
    );

    --------------------------------------------------------
    -- Individual file configuration metrics
    --------------------------------------------------------

    INSERT INTO @Metrics
    SELECT
        M.MetricID,
        'TempDB Configuration',
        'DatabaseFile',

        CONCAT('2:', F.FileID),

        M.MetricName,
        M.MetricValue,
        M.MetricUnit,

        CASE
            WHEN M.MetricValue IS NULL
                THEN 'UNKNOWN'
            ELSE 'SUCCESS'
        END,

        NULL

    FROM @Files AS F

    CROSS APPLY
    (
        VALUES

        (
            'TMP-011',
            'TempDB File Size',

            CONVERT(DECIMAL(28,4),
                F.SizePages / 128.0),

            'MB'
        ),
        (
            'TMP-012',
            'TempDB File Autogrowth Increment',

            CONVERT(DECIMAL(28,4),

                CASE

                    WHEN F.IsPercentGrowth = 1
                        THEN F.GrowthValue

                    ELSE F.GrowthValue / 128.0

                END
            ),

            CASE

                WHEN F.IsPercentGrowth = 1
                    THEN 'Percent'

                ELSE 'MB'

            END
        ),
        (
            'TMP-013',
            'TempDB File Percentage Growth',

            CONVERT(DECIMAL(28,4),
                F.IsPercentGrowth),

            'Boolean'
        ),
        (
            'TMP-014',
            'TempDB File Maximum Size Setting',

            CONVERT(DECIMAL(28,4),

                CASE

                    WHEN F.MaxSizePages = -1
                        THEN -1

                    ELSE F.MaxSizePages / 128.0

                END
            ),

            'MB'
        ),
        (
            'TMP-015',
            'TempDB File Autogrowth Disabled',

            CONVERT(DECIMAL(28,4),

                CASE
                    WHEN F.GrowthValue = 0 THEN 1
                    ELSE 0
                END
            ),

            'Boolean'
        ),
        (
            'TMP-024',
            'TempDB File Type',

            CONVERT(DECIMAL(28,4), F.FileType),

            'StateCode'
        )

    ) AS M
    (
        MetricID,
        MetricName,
        MetricValue,
        MetricUnit
    );

END TRY

BEGIN CATCH

    INSERT INTO @Metrics
    VALUES
    (
        'TMP-000',
        'Collection',
        'Instance',
        @ServerName,
        'TempDB File Configuration Collection',
        NULL,
        'Status',
        'FAILED',
        ERROR_MESSAGE()
    );

END CATCH;

------------------------------------------------------------
-- SECTION 4: TempDB Space Utilization
------------------------------------------------------------

BEGIN TRY

    INSERT INTO @FileSpace
    SELECT
        file_id,
        total_page_count,
        unallocated_extent_page_count,
        allocated_extent_page_count,
        user_object_reserved_page_count,
        internal_object_reserved_page_count,
        version_store_reserved_page_count,
        mixed_extent_page_count

    FROM sys.dm_db_file_space_usage;

    SELECT

        @TotalPages = SUM(TotalPages),

        @UnallocatedPages = SUM(UnallocatedPages),

        @AllocatedPages = SUM(AllocatedPages),

        @UserObjectPages = SUM(UserObjectPages),

        @InternalObjectPages = SUM(InternalObjectPages),

        @VersionStorePages = SUM(VersionStorePages),

        @MixedExtentPages = SUM(MixedExtentPages)

    FROM @FileSpace;

    --------------------------------------------------------
    -- Database-level space utilization
    --------------------------------------------------------

    INSERT INTO @Metrics
    SELECT
        M.MetricID,
        'TempDB Space',
        'Database',
        'tempdb',
        M.MetricName,
        M.MetricValue,
        M.MetricUnit,

        CASE
            WHEN M.MetricValue IS NULL
                THEN 'UNKNOWN'
            ELSE 'SUCCESS'
        END,

        CASE
            WHEN M.MetricValue IS NULL
                THEN 'TempDB space information unavailable.'
            ELSE NULL
        END

    FROM
    (
        VALUES

        (
            'TMP-001',
            'Total TempDB Data File Size',

            CONVERT(DECIMAL(28,4),
                @TotalPages / 128.0),

            'MB'
        ),
        (
            'TMP-002',
            'TempDB Unallocated Extent Space',

            CONVERT(DECIMAL(28,4),
                @UnallocatedPages / 128.0),

            'MB'
        ),
        (
            'TMP-003',
            'TempDB Allocated Extent Space',

            CONVERT(DECIMAL(28,4),
                @AllocatedPages / 128.0),

            'MB'
        ),
        (
            'TMP-004',
            'TempDB Data Space Utilization',

            CONVERT(DECIMAL(28,4),

                CASE
                    WHEN @AllocatedPages
                        BETWEEN 0 AND @TotalPages

                    THEN @AllocatedPages * 100.0
                        / NULLIF(@TotalPages, 0)
                END
            ),

            'Percent'
        ),
        (
            'TMP-005',
            'TempDB User Object Reserved Space',

            CONVERT(DECIMAL(28,4),
                @UserObjectPages / 128.0),

            'MB'
        ),
        (
            'TMP-006',
            'TempDB Internal Object Reserved Space',

            CONVERT(DECIMAL(28,4),
                @InternalObjectPages / 128.0),

            'MB'
        ),
        (
            'TMP-007',
            'TempDB Version Store Reserved Space',

            CONVERT(DECIMAL(28,4),
                @VersionStorePages / 128.0),

            'MB'
        ),
        (
            'TMP-008',
            'TempDB Mixed Extent Allocated Space',

            CONVERT(DECIMAL(28,4),
                @MixedExtentPages / 128.0),

            'MB'
        )

    ) AS M
    (
        MetricID,
        MetricName,
        MetricValue,
        MetricUnit
    );

    --------------------------------------------------------
    -- SECTION 5: Individual Data File Utilization
    --------------------------------------------------------

    INSERT INTO @Metrics
    SELECT
        M.MetricID,
        'TempDB Space',
        'DatabaseFile',

        CONCAT('2:', F.FileID),

        M.MetricName,
        M.MetricValue,
        M.MetricUnit,

        CASE
            WHEN M.MetricValue IS NULL
                THEN 'UNKNOWN'
            ELSE 'SUCCESS'
        END,

        CASE
            WHEN M.MetricValue IS NULL
                THEN 'TempDB file space information unavailable.'
            ELSE NULL
        END

    FROM @FileSpace AS F

    CROSS APPLY
    (
        VALUES

        (
            'TMP-022',
            'TempDB File Unallocated Extent Space',

            CONVERT(DECIMAL(28,4),
                F.UnallocatedPages / 128.0),

            'MB'
        ),
        (
            'TMP-023',
            'TempDB Data File Utilization',

            CONVERT(DECIMAL(28,4),

                CASE
                    WHEN F.AllocatedPages
                        BETWEEN 0 AND F.TotalPages

                    THEN F.AllocatedPages * 100.0
                        / NULLIF(F.TotalPages, 0)
                END
            ),

            'Percent'
        )

    ) AS M
    (
        MetricID,
        MetricName,
        MetricValue,
        MetricUnit
    );

END TRY

BEGIN CATCH

    INSERT INTO @Metrics
    VALUES
    (
        'TMP-099',
        'Collection',
        'Instance',
        @ServerName,
        'TempDB Space Utilization Collection',
        NULL,
        'Status',
        'FAILED',
        ERROR_MESSAGE()
    );

END CATCH;

------------------------------------------------------------
-- SECTION 6: TempDB Page Latch Contention
------------------------------------------------------------

/*
PAGELATCH waits represent in-memory page contention.

PAGEIOLATCH waits represent page I/O-related waits
and are intentionally excluded from this section.

Only waiting tasks with identifiable TempDB page
resources are included.
*/

BEGIN TRY

    INSERT INTO @LatchWaits
    SELECT

        W.session_id,

        W.wait_duration_ms,

        TRY_CONVERT
        (
            INT,
            PARSENAME(R.PageResource, 2)
        ),

        TRY_CONVERT
        (
            BIGINT,
            PARSENAME(R.PageResource, 1)
        )

    FROM sys.dm_os_waiting_tasks AS W

    CROSS APPLY
    (
        SELECT REPLACE
        (
            LTRIM(RTRIM(W.resource_description)),
            ':',
            '.'
        ) AS PageResource

    ) AS R

    WHERE W.wait_type LIKE 'PAGELATCH[_]%'

      AND W.session_id <> @@SPID

      AND TRY_CONVERT
      (
          INT,
          PARSENAME(R.PageResource, 3)
      ) = DB_ID('tempdb')

      AND PARSENAME(R.PageResource, 4) IS NULL

      AND TRY_CONVERT
      (
          INT,
          PARSENAME(R.PageResource, 2)
      ) > 0

      AND TRY_CONVERT
      (
          BIGINT,
          PARSENAME(R.PageResource, 1)
      ) >= 0;

    --------------------------------------------------------
    -- Current page latch waits
    --------------------------------------------------------

    SELECT

        @PageLatchWaits = COUNT_BIG(*),

        @MaxPageLatchWaitMS =
            MAX(WaitDurationMS),

        @AllocationPageWaits = COUNT_BIG
        (
            CASE

                WHEN PageID IN (1, 2, 3)

                  OR
                  (
                      PageID > 0
                      AND PageID % 8088 = 0
                  )

                  OR
                  (
                      PageID > 0
                      AND PageID % 511232 = 0
                  )

                  OR
                  (
                      PageID > 1
                      AND (PageID - 1) % 511232 = 0
                  )

                    THEN 1

            END
        )

    FROM @LatchWaits;

    IF @PageLatchWaits = 0
        SET @MaxPageLatchWaitMS = 0;

    INSERT INTO @Metrics
    SELECT
        M.MetricID,
        'TempDB Contention',
        'Database',
        'tempdb',
        M.MetricName,
        M.MetricValue,
        M.MetricUnit,
        'SUCCESS',
        NULL

    FROM
    (
        VALUES

        (
            'TMP-016',
            'Current TempDB Page Latch Waiting Tasks',

            CONVERT(DECIMAL(28,4),
                @PageLatchWaits),

            'Count'
        ),
        (
            'TMP-017',
            'Maximum Current TempDB Page Latch Wait',

            CONVERT(DECIMAL(28,4),
                @MaxPageLatchWaitMS),

            'Milliseconds'
        ),
        (
            'TMP-018',
            'Suspected Allocation Page Latch Waiting Tasks',

            CONVERT(DECIMAL(28,4),
                @AllocationPageWaits),

            'Count'
        )

    ) AS M
    (
        MetricID,
        MetricName,
        MetricValue,
        MetricUnit
    );

END TRY

BEGIN CATCH

    INSERT INTO @Metrics
    VALUES
    (
        'TMP-098',
        'Collection',
        'Instance',
        @ServerName,
        'TempDB Page Latch Collection',
        NULL,
        'Status',
        'FAILED',
        ERROR_MESSAGE()
    );

END CATCH;

------------------------------------------------------------
-- SECTION 7: Collection Coverage
------------------------------------------------------------

INSERT INTO @Metrics
VALUES
(
    'TMP-025',
    'Collection',
    'Instance',
    @ServerName,
    'TempDB Data Files With Space Statistics',

    (
        SELECT COUNT_BIG(*)
        FROM @FileSpace
    ),

    'Count',

    CASE
        WHEN NOT EXISTS
        (
            SELECT 1
            FROM @FileSpace
        )
            THEN 'UNKNOWN'

        ELSE 'SUCCESS'
    END,

    NULL
);

------------------------------------------------------------
-- SECTION 8: Collection Performance
------------------------------------------------------------

INSERT INTO @Metrics
VALUES
(
    'TMP-019',
    'Collection',
    'Instance',
    @ServerName,
    'Collector Execution Duration',

    DATEDIFF
    (
        MILLISECOND,
        @CollectionStart,
        SYSUTCDATETIME()
    ),

    'Milliseconds',
    'SUCCESS',
    NULL
);

------------------------------------------------------------
-- SECTION 9: Standardized Monitoring Output
------------------------------------------------------------

SELECT
    @CaptureDate AS CaptureDateUTC,
    @ServerName AS ServerName,
    '26' AS ModuleID,
    MetricID,
    Category,
    ResourceType,
    ResourceName,
    MetricName,
    MetricValue,
    MetricUnit,
    CollectionStatus,
    ErrorMessage

FROM @Metrics

ORDER BY
    ResourceType,
    ResourceName,
    MetricID;

GO
