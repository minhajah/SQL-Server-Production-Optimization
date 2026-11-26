/*
============================================================
Project : SQL Server Production Optimization
Module  : 01 - Server Inventory
Script  : 05-SQL-Agent-Inventory.sql
Purpose : Collect SQL Server Agent job inventory
Type    : Read-Only Assessment
============================================================
*/

USE msdb;
GO

SET NOCOUNT ON;

------------------------------------------------------------
-- SECTION 1: SQL Agent Job Inventory
------------------------------------------------------------

SELECT
    SYSDATETIME() AS CaptureDate,
    @@SERVERNAME AS ServerName,
    J.name AS JobName,
    C.name AS JobCategory,
    SUSER_SNAME(J.owner_sid) AS JobOwner,

    CASE J.enabled
        WHEN 1 THEN 'Enabled'
        ELSE 'Disabled'
    END AS JobStatus,

    J.description AS JobDescription,
    J.date_created AS CreatedDate,
    J.date_modified AS ModifiedDate,

    CASE H.run_status
        WHEN 0 THEN 'Failed'
        WHEN 1 THEN 'Succeeded'
        WHEN 2 THEN 'Retry'
        WHEN 3 THEN 'Canceled'
        WHEN 4 THEN 'In Progress'
        ELSE 'No History Available'
    END AS LastRunStatus,

    CASE
        WHEN H.run_date > 0
        THEN msdb.dbo.agent_datetime(
            H.run_date, H.run_time)
    END AS LastRunDateTime,

    (H.run_duration / 10000) * 3600
    + ((H.run_duration % 10000) / 100) * 60
    + (H.run_duration % 100)
        AS LastRunDuration_SEC

FROM msdb.dbo.sysjobs AS J

LEFT JOIN msdb.dbo.syscategories AS C
    ON J.category_id = C.category_id

OUTER APPLY
(
    SELECT TOP (1)
        H.run_status,
        H.run_date,
        H.run_time,
        H.run_duration

    FROM msdb.dbo.sysjobhistory AS H

    WHERE H.job_id = J.job_id
      AND H.step_id = 0

    ORDER BY H.instance_id DESC
) AS H

ORDER BY J.name;

------------------------------------------------------------
-- SECTION 2: SQL Agent Job Schedules
------------------------------------------------------------

SELECT
    @@SERVERNAME AS ServerName,
    J.name AS JobName,
    S.name AS ScheduleName,

    CASE J.enabled
        WHEN 1 THEN 'Enabled'
        ELSE 'Disabled'
    END AS JobStatus,

    CASE
        WHEN S.schedule_id IS NULL THEN 'No Schedule'
        WHEN S.enabled = 1 THEN 'Enabled'
        ELSE 'Disabled'
    END AS ScheduleStatus,

    CASE S.freq_type
        WHEN 1 THEN 'One Time'
        WHEN 4 THEN 'Daily'
        WHEN 8 THEN 'Weekly'
        WHEN 16 THEN 'Monthly'
        WHEN 32 THEN 'Monthly Relative'
        WHEN 64 THEN 'SQL Agent Startup'
        WHEN 128 THEN 'When CPU Idle'
        ELSE 'Not Scheduled / Unknown'
    END AS ScheduleFrequency,

    CASE
        WHEN JS.next_run_date > 0
        THEN msdb.dbo.agent_datetime(
            JS.next_run_date, JS.next_run_time)
    END AS NextRunDateTime

FROM msdb.dbo.sysjobs AS J

LEFT JOIN msdb.dbo.sysjobschedules AS JS
    ON J.job_id = JS.job_id

LEFT JOIN msdb.dbo.sysschedules AS S
    ON JS.schedule_id = S.schedule_id

ORDER BY J.name, S.name;

------------------------------------------------------------
-- SECTION 3: Currently Running Jobs
------------------------------------------------------------

SELECT
    @@SERVERNAME AS ServerName,
    J.name AS JobName,
    A.start_execution_date AS StartTime,

    DATEDIFF(SECOND,
        A.start_execution_date, GETDATE())
        AS RunningDuration_SEC,

    CAST(DATEDIFF(SECOND,
        A.start_execution_date, GETDATE()) / 60.0
        AS DECIMAL(18,2))
        AS RunningDuration_MIN,

    A.last_executed_step_id AS LastExecutedStepID,
    'Running' AS CurrentStatus

FROM msdb.dbo.sysjobactivity AS A

INNER JOIN msdb.dbo.sysjobs AS J
    ON A.job_id = J.job_id

WHERE A.session_id =
(
    SELECT MAX(session_id)
    FROM msdb.dbo.syssessions
)
AND A.start_execution_date IS NOT NULL
AND A.stop_execution_date IS NULL

ORDER BY RunningDuration_SEC DESC;

------------------------------------------------------------
-- SECTION 4: Failed Jobs in Last 24 Hours
------------------------------------------------------------

-- SQL Agent history timestamps are in server-local time.
DECLARE @Cutoff DATETIME = DATEADD(HOUR, -24, GETDATE());
DECLARE @CutoffDate INT = CONVERT(INT, CONVERT(CHAR(8), @Cutoff, 112));
DECLARE @CutoffTime INT = DATEPART(HOUR, @Cutoff) * 10000
                       + DATEPART(MINUTE, @Cutoff) * 100
                       + DATEPART(SECOND, @Cutoff);

SELECT
    @@SERVERNAME AS ServerName,
    J.name AS JobName,

    msdb.dbo.agent_datetime(
        H.run_date, H.run_time)
        AS ExecutionDateTime,

    COALESCE(F.step_id, H.step_id) AS StepID,
    COALESCE(F.step_name, H.step_name) AS StepName,
    COALESCE(F.sql_message_id, H.sql_message_id) AS SQLMessageID,
    COALESCE(F.sql_severity, H.sql_severity) AS SQLSeverity,
    COALESCE(F.message, H.message) AS ErrorMessage,

    (H.run_duration / 10000) * 3600
    + ((H.run_duration % 10000) / 100) * 60
    + (H.run_duration % 100)
        AS RunDuration_SEC,

    'Failed' AS ExecutionStatus,
    H.message AS JobOutcomeMessage,
    CASE WHEN F.instance_id IS NOT NULL
         THEN 'Latest recorded failed step'
         ELSE 'Job outcome only - no bounded failed step available'
    END AS ErrorDetailSource

FROM msdb.dbo.sysjobhistory AS H

INNER JOIN msdb.dbo.sysjobs AS J
    ON H.job_id = J.job_id

-- Locate the preceding job outcome to avoid mixing executions.
OUTER APPLY
(
    SELECT TOP (1) P.instance_id
    FROM msdb.dbo.sysjobhistory AS P
    WHERE P.job_id = H.job_id
      AND P.step_id = 0
      AND P.instance_id < H.instance_id
    ORDER BY P.instance_id DESC
) AS P

-- Do not attribute a step if the preceding outcome is missing:
-- history may have been purged or this may be the first execution.
OUTER APPLY
(
    SELECT TOP (1)
        S.instance_id, S.step_id, S.step_name,
        S.sql_message_id, S.sql_severity, S.message
    FROM msdb.dbo.sysjobhistory AS S
    WHERE S.job_id = H.job_id
      AND S.step_id > 0
      AND S.run_status = 0
      AND S.instance_id > P.instance_id
      AND S.instance_id < H.instance_id
    ORDER BY S.instance_id DESC
) AS F

WHERE H.run_status = 0
AND H.step_id = 0
AND H.run_date >= @CutoffDate
AND (H.run_date > @CutoffDate OR H.run_time >= @CutoffTime)

ORDER BY ExecutionDateTime DESC;

GO
