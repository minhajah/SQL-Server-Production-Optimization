/*
============================================================
Project : SQL Server Production Optimization
Module  : 26 - Data Collection
Script  : 07-HA-Health-Collector.sql
Purpose : Collect Always On and basic FCI health metrics
Type    : Read-Only Monitoring Collector
Impact  : Low - dependent on AG and replica count
Frequency: 60 Seconds (Proposed)
============================================================
*/

USE master;
GO

SET NOCOUNT ON;

------------------------------------------------------------
-- SECTION 1: Collection Variables
------------------------------------------------------------

DECLARE
    @CaptureDate DATETIME2(3) = SYSUTCDATETIME(),
    @CollectionStart DATETIME2(3) = SYSUTCDATETIME(),
    @ServerName NVARCHAR(128),
    @HADREnabled INT,
    @IsClustered INT,
    @AGCount BIGINT,
    @ReplicaCount BIGINT,
    @DatabaseCount BIGINT;

SET @ServerName =
    CONVERT(NVARCHAR(128), SERVERPROPERTY('ServerName'));

SET @HADREnabled =
    CONVERT(INT, SERVERPROPERTY('IsHadrEnabled'));

SET @IsClustered =
    CONVERT(INT, SERVERPROPERTY('IsClustered'));

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
-- SECTION 3: Instance HA Configuration
------------------------------------------------------------

INSERT INTO @Metrics
VALUES
(
    'HA-001',
    'High Availability',
    'Instance',
    @ServerName,
    'Always On Enabled',
    @HADREnabled,
    'Boolean',
    CASE WHEN @HADREnabled IS NULL
        THEN 'UNKNOWN' ELSE 'SUCCESS' END,
    NULL
),
(
    'HA-002',
    'High Availability',
    'Instance',
    @ServerName,
    'Failover Cluster Instance Enabled',
    @IsClustered,
    'Boolean',
    CASE WHEN @IsClustered IS NULL
        THEN 'UNKNOWN' ELSE 'SUCCESS' END,
    NULL
);

------------------------------------------------------------
-- SECTION 4: Availability Group Count
------------------------------------------------------------

IF @HADREnabled = 1
BEGIN

    BEGIN TRY

        SELECT
            @AGCount = COUNT_BIG(*)
        FROM sys.availability_groups;

        INSERT INTO @Metrics
        VALUES
        (
            'HA-003',
            'High Availability',
            'Instance',
            @ServerName,
            'Local Availability Group Count',
            @AGCount,
            'Count',
            'SUCCESS',
            NULL
        );

    END TRY

    BEGIN CATCH

        INSERT INTO @Metrics
        VALUES
        (
            'HA-003',
            'High Availability',
            'Instance',
            @ServerName,
            'Local Availability Group Count',
            NULL,
            'Count',
            'FAILED',
            ERROR_MESSAGE()
        );

    END CATCH;

END

ELSE
BEGIN

    INSERT INTO @Metrics
    VALUES
    (
        'HA-003',
        'High Availability',
        'Instance',
        @ServerName,
        'Local Availability Group Count',

        CASE WHEN @HADREnabled = 0
            THEN 0 ELSE NULL END,

        'Count',

        CASE WHEN @HADREnabled = 0
            THEN 'NOT APPLICABLE'
            ELSE 'UNKNOWN' END,

        'Always On is disabled or unavailable.'
    );

END;

------------------------------------------------------------
-- SECTION 5: Availability Replica Health
------------------------------------------------------------

IF @HADREnabled = 1
BEGIN

    BEGIN TRY

        INSERT INTO @Metrics
        SELECT
            M.MetricID,
            'High Availability',
            'AGReplica',

            CONCAT(
                CONVERT(VARCHAR(36), AR.group_id),
                ':',
                CONVERT(VARCHAR(36), AR.replica_id)
            ),

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
                    THEN 'Replica metric unavailable.'
                ELSE NULL
            END

        FROM sys.dm_hadr_availability_replica_states
            AS RS

        INNER JOIN sys.availability_replicas AS AR
            ON RS.replica_id = AR.replica_id
           AND RS.group_id = AR.group_id

        CROSS APPLY
        (
            VALUES

            (
                'HA-004',
                'Replica Role',
                CONVERT(DECIMAL(28,4), RS.role),
                'StateCode'
            ),
            (
                'HA-005',
                'Replica Operational State',
                CONVERT(DECIMAL(28,4),
                    RS.operational_state),
                'StateCode'
            ),
            (
                'HA-006',
                'Replica Connected State',
                CONVERT(DECIMAL(28,4),
                    RS.connected_state),
                'StateCode'
            ),
            (
                'HA-007',
                'Replica Synchronization Health',
                CONVERT(DECIMAL(28,4),
                    RS.synchronization_health),
                'StateCode'
            ),
            (
                'HA-008',
                'Replica Availability Mode',
                CONVERT(DECIMAL(28,4),
                    AR.availability_mode),
                'StateCode'
            ),
            (
                'HA-009',
                'Replica Failover Mode',
                CONVERT(DECIMAL(28,4),
                    AR.failover_mode),
                'StateCode'
            ),
            (
                'HA-027',
                'Replica Recovery Health',
                CONVERT(DECIMAL(28,4),
                    RS.recovery_health),
                'StateCode'
            ),
            (
                'HA-028',
                'Replica Is Local',
                CONVERT(DECIMAL(28,4),
                    RS.is_local),
                'Boolean'
            )

        ) AS M
        (
            MetricID,
            MetricName,
            MetricValue,
            MetricUnit
        );

        SELECT
            @ReplicaCount = COUNT_BIG(*)
        FROM @Metrics
        WHERE MetricID = 'HA-004';

        INSERT INTO @Metrics
        VALUES
        (
            'HA-026',
            'Collection',
            'Instance',
            @ServerName,
            'Replica Rows Visible To Collector',
            @ReplicaCount,
            'Count',
            'SUCCESS',
            NULL
        );

    END TRY

    BEGIN CATCH

        INSERT INTO @Metrics
        VALUES
        (
            'HA-098',
            'Collection',
            'Instance',
            @ServerName,
            'Availability Replica Collection',
            NULL,
            'Status',
            'FAILED',
            ERROR_MESSAGE()
        );

    END CATCH;

END;

------------------------------------------------------------
-- SECTION 6: Availability Database Health
------------------------------------------------------------

IF @HADREnabled = 1
BEGIN

    BEGIN TRY

        INSERT INTO @Metrics
        SELECT
            M.MetricID,
            'High Availability',
            'AGDatabase',

            CONCAT(
                CONVERT(VARCHAR(36), DS.group_id),
                ':',
                CONVERT(VARCHAR(36),
                    DS.group_database_id),
                ':',
                CONVERT(VARCHAR(36), DS.replica_id)
            ),

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
                    THEN 'Metric unavailable for this replica role or state.'
                ELSE NULL
            END

        FROM sys.dm_hadr_database_replica_states AS DS

        LEFT JOIN
            sys.dm_hadr_database_replica_cluster_states
                AS CS

            ON DS.replica_id = CS.replica_id

           AND DS.group_database_id =
                CS.group_database_id

        CROSS APPLY
        (
            VALUES

            (
                'HA-010',
                'Database Synchronization State',
                CONVERT(DECIMAL(28,4),
                    DS.synchronization_state),
                'StateCode'
            ),
            (
                'HA-011',
                'Database Synchronization Health',
                CONVERT(DECIMAL(28,4),
                    DS.synchronization_health),
                'StateCode'
            ),
            (
                'HA-012',
                'Availability Database State',
                CONVERT(DECIMAL(28,4),
                    DS.database_state),
                'StateCode'
            ),
            (
                'HA-013',
                'Data Movement Suspended',
                CONVERT(DECIMAL(28,4),
                    DS.is_suspended),
                'Boolean'
            ),
            (
                'HA-014',
                'Data Movement Suspend Reason',
                CONVERT(DECIMAL(28,4),
                    DS.suspend_reason),
                'StateCode'
            ),
            (
                'HA-015',
                'Log Send Queue Size',
                CONVERT(DECIMAL(28,4),
                    DS.log_send_queue_size),
                'KB'
            ),
            (
                'HA-016',
                'Log Send Rate',
                CONVERT(DECIMAL(28,4),
                    DS.log_send_rate),
                'KBPerSecond'
            ),
            (
                'HA-017',
                'Redo Queue Size',
                CONVERT(DECIMAL(28,4),
                    DS.redo_queue_size),
                'KB'
            ),
            (
                'HA-018',
                'Redo Rate',
                CONVERT(DECIMAL(28,4),
                    DS.redo_rate),
                'KBPerSecond'
            ),
            (
                'HA-019',
                'Estimated Redo Queue Drain Time',

                CONVERT(DECIMAL(28,4),

                    CASE

                        WHEN DS.redo_queue_size = 0
                            THEN 0

                        WHEN DS.redo_queue_size > 0
                         AND DS.redo_rate > 0

                            THEN
                                CONVERT(DECIMAL(28,4),
                                    DS.redo_queue_size)
                                / NULLIF(DS.redo_rate, 0)

                        ELSE NULL

                    END
                ),

                'Seconds'
            ),
            (
                'HA-020',
                'Secondary Synchronization Lag',
                CONVERT(DECIMAL(28,4),
                    DS.secondary_lag_seconds),
                'Seconds'
            ),
            (
                'HA-021',
                'Database Is Local Replica',
                CONVERT(DECIMAL(28,4),
                    DS.is_local),
                'Boolean'
            ),
            (
                'HA-022',
                'Database Is Primary Replica',
                CONVERT(DECIMAL(28,4),
                    DS.is_primary_replica),
                'Boolean'
            ),
            (
                'HA-023',
                'Database Failover Readiness',
                CONVERT(DECIMAL(28,4),
                    CS.is_failover_ready),
                'Boolean'
            ),
            (
                'HA-029',
                'Database Joined To Availability Group',
                CONVERT(DECIMAL(28,4),
                    CS.is_database_joined),
                'Boolean'
            ),
            (
                'HA-030',
                'Database Synchronization Commit Participant',
                CONVERT(DECIMAL(28,4),
                    DS.is_commit_participant),
                'Boolean'
            )

        ) AS M
        (
            MetricID,
            MetricName,
            MetricValue,
            MetricUnit
        );

        SELECT
            @DatabaseCount = COUNT_BIG(*)
        FROM @Metrics
        WHERE MetricID = 'HA-010';

        INSERT INTO @Metrics
        VALUES
        (
            'HA-025',
            'Collection',
            'Instance',
            @ServerName,
            'Database Rows Visible To Collector',
            @DatabaseCount,
            'Count',
            'SUCCESS',
            NULL
        );

    END TRY

    BEGIN CATCH

        INSERT INTO @Metrics
        VALUES
        (
            'HA-099',
            'Collection',
            'Instance',
            @ServerName,
            'Availability Database Collection',
            NULL,
            'Status',
            'FAILED',
            ERROR_MESSAGE()
        );

    END CATCH;

END;

------------------------------------------------------------
-- SECTION 7: Collection Completeness
------------------------------------------------------------

IF @HADREnabled = 1
AND @AGCount > 0
BEGIN

    IF @ReplicaCount = 0
    BEGIN

        INSERT INTO @Metrics
        VALUES
        (
            'HA-097',
            'Collection',
            'Instance',
            @ServerName,
            'Availability Replica Visibility',
            NULL,
            'Status',
            'UNKNOWN',
            'AG configuration exists but no replica states are visible.'
        );

    END;

    IF @DatabaseCount = 0
    BEGIN

        INSERT INTO @Metrics
        VALUES
        (
            'HA-096',
            'Collection',
            'Instance',
            @ServerName,
            'Availability Database Visibility',
            NULL,
            'Status',
            'UNKNOWN',
            'No availability database states are visible.'
        );

    END;

END;

------------------------------------------------------------
-- SECTION 8: Collection Performance
------------------------------------------------------------

INSERT INTO @Metrics
VALUES
(
    'HA-024',
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
