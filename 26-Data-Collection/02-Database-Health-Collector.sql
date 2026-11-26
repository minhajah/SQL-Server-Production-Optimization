/*
============================================================
Project : SQL Server Production Optimization
Module  : 26 - Data Collection
Script  : 02-Database-Health-Collector.sql
Purpose : Collect database health and availability metrics
Type    : Read-Only Monitoring Collector
Impact  : Low
Frequency: 60 Seconds (Proposed)
============================================================
*/

USE master;
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
    @ServerName NVARCHAR(128);

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

------------------------------------------------------------
-- SECTION 3: Database Health Collection
------------------------------------------------------------

BEGIN TRY

    INSERT INTO @Metrics
    SELECT
        M.MetricID,
        M.Category,
        'Database',
        D.name,
        M.MetricName,
        M.MetricValue,
        M.MetricUnit,

        CASE
            WHEN M.MetricValue IS NULL THEN 'UNKNOWN'
            ELSE 'SUCCESS'
        END,

        NULL

    FROM sys.databases AS D

    CROSS APPLY
    (
        VALUES

        (
            'DB-001',
            'Availability',
            'Database State',
            CONVERT(DECIMAL(28,4), D.state),
            'StateCode'
        ),
        (
            'DB-002',
            'Availability',
            'Database Accessibility',
            CONVERT(DECIMAL(28,4),
                HAS_DBACCESS(D.name)),
            'Boolean'
        ),
        (
            'DB-003',
            'Database Configuration',
            'Read Only Status',
            CONVERT(DECIMAL(28,4), D.is_read_only),
            'Boolean'
        ),
        (
            'DB-004',
            'Database Configuration',
            'Recovery Model',
            CONVERT(DECIMAL(28,4), D.recovery_model),
            'StateCode'
        ),
        (
            'DB-005',
            'Availability',
            'User Access Mode',
            CONVERT(DECIMAL(28,4), D.user_access),
            'StateCode'
        ),
        (
            'DB-006',
            'Availability',
            'Standby Status',
            CONVERT(DECIMAL(28,4), D.is_in_standby),
            'Boolean'
        )

    ) AS M
    (
        MetricID,
        Category,
        MetricName,
        MetricValue,
        MetricUnit
    )

    WHERE D.source_database_id IS NULL;

END TRY

BEGIN CATCH

    INSERT INTO @Metrics
    VALUES
    (
        'DB-000',
        'Collection',
        'Instance',
        @ServerName,
        'Database Health Collection',
        NULL,
        'Status',
        'FAILED',
        ERROR_MESSAGE()
    );

END CATCH;

------------------------------------------------------------
-- SECTION 4: Collection Performance
------------------------------------------------------------

INSERT INTO @Metrics
VALUES
(
    'DB-007',
    'Collection',
    'Instance',
    @ServerName,
    'Collector Execution Duration',
    DATEDIFF(
        MILLISECOND,
        @CollectionStart,
        SYSUTCDATETIME()
    ),
    'Milliseconds',
    'SUCCESS',
    NULL
);

------------------------------------------------------------
-- SECTION 5: Standardized Monitoring Output
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
