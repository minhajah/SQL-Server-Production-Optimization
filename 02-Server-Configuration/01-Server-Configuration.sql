/*
============================================================
Project : SQL Server Production Optimization
Module  : 02 - Server Configuration
Script  : 01-Server-Configuration.sql
Purpose : Collect SQL Server configuration baseline
Type    : Read-Only Assessment
============================================================
*/

USE master;
GO

SET NOCOUNT ON;

------------------------------------------------------------
-- SECTION 1: Complete Server Configuration
------------------------------------------------------------

SELECT
    SYSDATETIME() AS CaptureDate,
    @@SERVERNAME AS ServerName,
    configuration_id AS ConfigurationID,
    name AS ConfigurationName,
    value AS ConfiguredValue,
    value_in_use AS RunningValue,
    minimum AS MinimumValue,
    maximum AS MaximumValue,

    CASE is_dynamic
        WHEN 1 THEN 'Yes'
        ELSE 'No'
    END AS IsDynamic,

    CASE is_advanced
        WHEN 1 THEN 'Yes'
        ELSE 'No'
    END AS IsAdvanced,

    CASE
        WHEN value <> value_in_use
            THEN 'REVIEW - Value Mismatch'
        ELSE 'MATCHED'
    END AS ConfigurationStatus,

    description AS ConfigurationDescription

FROM sys.configurations

ORDER BY name;

------------------------------------------------------------
-- SECTION 2: Configured vs Running Value Mismatch
------------------------------------------------------------

SELECT
    SYSDATETIME() AS CaptureDate,
    @@SERVERNAME AS ServerName,
    name AS ConfigurationName,
    value AS ConfiguredValue,
    value_in_use AS RunningValue,

    CASE
        WHEN is_dynamic = 0
            THEN 'Review Restart Requirement'
        WHEN is_dynamic = 1
            THEN 'Review RECONFIGURE Requirement'
        ELSE 'Investigate'
    END AS RecommendedReview,

    description AS ConfigurationDescription

FROM sys.configurations

WHERE value <> value_in_use

ORDER BY name;

------------------------------------------------------------
-- SECTION 3: Important Production Configuration
------------------------------------------------------------

SELECT
    SYSDATETIME() AS CaptureDate,
    @@SERVERNAME AS ServerName,
    name AS ConfigurationName,
    value AS ConfiguredValue,
    value_in_use AS RunningValue,
    description AS ConfigurationDescription

FROM sys.configurations

WHERE name IN
(
    'max server memory (MB)',
    'min server memory (MB)',
    'max degree of parallelism',
    'cost threshold for parallelism',
    'optimize for ad hoc workloads',
    'backup compression default',
    'backup checksum default',
    'blocked process threshold (s)',
    'remote admin connections',
    'remote query timeout (s)',
    'max worker threads',
    'lightweight pooling',
    'priority boost',
    'clr enabled',
    'clr strict security',
    'xp_cmdshell',
    'Ole Automation Procedures',
    'Ad Hoc Distributed Queries',
    'Database Mail XPs',
    'default trace enabled',
    'fill factor (%)',
    'user connections',
    'contained database authentication',
    'recovery interval (min)',
    'query governor cost limit',
    'show advanced options'
)

ORDER BY name;

------------------------------------------------------------
-- SECTION 4: Configuration Summary
------------------------------------------------------------

SELECT
    SYSDATETIME() AS CaptureDate,
    @@SERVERNAME AS ServerName,

    COUNT(*) AS TotalConfigurations,

    COUNT(CASE
        WHEN is_dynamic = 1 THEN 1
    END) AS DynamicConfigurations,

    COUNT(CASE
        WHEN is_dynamic = 0 THEN 1
    END) AS NonDynamicConfigurations,

    COUNT(CASE
        WHEN is_advanced = 1 THEN 1
    END) AS AdvancedConfigurations,

    COUNT(CASE
        WHEN value <> value_in_use THEN 1
    END) AS ConfigurationMismatches,

    CASE
        WHEN COUNT(CASE
            WHEN value <> value_in_use THEN 1
        END) > 0
            THEN 'REVIEW REQUIRED'
        ELSE 'NO VALUE MISMATCHES DETECTED'
    END AS ConfigurationStatus

FROM sys.configurations;

GO
