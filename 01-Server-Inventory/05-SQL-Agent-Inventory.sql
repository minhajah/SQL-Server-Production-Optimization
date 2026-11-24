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

SELECT
    @@SERVERNAME AS ServerName,
    J.name AS JobName,

    msdb.dbo.agent_datetime(
        H.run_date, H.run_time)
        AS ExecutionDateTime,

    H.step_id AS StepID,
    H.step_name AS StepName,
    H.sql_message_id AS SQLMessageID,
    H.sql_severity AS SQLSeverity,
    H.message AS ErrorMessage,

    (H.run_duration / 10000) * 3600
    + ((H.run_duration % 10000) / 100) * 60
    + (H.run_duration % 100)
        AS RunDuration_SEC,

    'Failed' AS ExecutionStatus

FROM msdb.dbo.sysjobhistory AS H

INNER JOIN msdb.dbo.sysjobs AS J
    ON H.job_id = J.job_id

WHERE H.run_status = 0
AND H.run_date > 0
AND H.step_id = 0
AND msdb.dbo.agent_datetime(
        H.run_date, H.run_time)
    >= DATEADD(HOUR, -24, GETDATE())

ORDER BY ExecutionDateTime DESC;

GO
