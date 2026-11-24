/*
============================================================
Project : SQL Server Production Optimization
Module  : 02 - Server Configuration
Script  : 05-Security-Configuration.sql
Purpose : Assess instance-level security configuration
Type    : Read-Only Assessment
Impact  : Low
============================================================
*/

USE master;
GO

SET NOCOUNT ON;

------------------------------------------------------------
-- SECTION 1: Server Authentication Configuration
------------------------------------------------------------

SELECT
    SYSDATETIME() AS CaptureDate,
    @@SERVERNAME AS ServerName,

    CASE SERVERPROPERTY('IsIntegratedSecurityOnly')
        WHEN 1 THEN 'Windows Authentication'
        WHEN 0 THEN 'Mixed Mode'
        ELSE 'Unknown'
    END AS AuthenticationMode,

    CASE
        WHEN SERVERPROPERTY('IsIntegratedSecurityOnly') = 1
            THEN 'Windows Authentication Configured'

        WHEN SERVERPROPERTY('IsIntegratedSecurityOnly') = 0
            THEN 'REVIEW - Mixed Mode Authentication'

        ELSE 'UNKNOWN'
    END AS AuthenticationAssessment;

------------------------------------------------------------
-- SECTION 2: Security Configuration Assessment
------------------------------------------------------------

SELECT
    SYSDATETIME() AS CaptureDate,
    @@SERVERNAME AS ServerName,
    name AS ConfigurationName,
    value AS ConfiguredValue,
    value_in_use AS RunningValue,

    CASE

        WHEN name IN
        (
            'xp_cmdshell',
            'Ole Automation Procedures',
            'Ad Hoc Distributed Queries',
            'cross db ownership chaining'
        )
        AND CONVERT(INT, value_in_use) = 1
            THEN 'HIGH - Review Business Requirement'

        WHEN name = 'clr strict security'
        AND CONVERT(INT, value_in_use) = 0
            THEN 'HIGH - CLR Strict Security Disabled'

        WHEN name IN
        (
            'clr enabled',
            'contained database authentication',
            'external scripts enabled'
        )
        AND CONVERT(INT, value_in_use) = 1
            THEN 'REVIEW - Validate Requirement'

        WHEN name = 'Database Mail XPs'
        AND CONVERT(INT, value_in_use) = 1
            THEN 'INFORMATIONAL - Database Mail Enabled'

        WHEN name = 'remote admin connections'
        AND CONVERT(INT, value_in_use) = 1
            THEN 'INFORMATIONAL - Remote DAC Enabled'

        WHEN name = 'remote access'
            THEN 'INFORMATIONAL - Review Legacy Dependency'

        WHEN name = 'clr strict security'
        AND CONVERT(INT, value_in_use) = 1
            THEN 'Enabled'

        ELSE 'No Basic Configuration Exception'

    END AS SecurityAssessment,

    description AS ConfigurationDescription

FROM sys.configurations

WHERE name IN
(
    'xp_cmdshell',
    'Ole Automation Procedures',
    'Ad Hoc Distributed Queries',
    'clr enabled',
    'clr strict security',
    'Database Mail XPs',
    'remote admin connections',
    'remote access',
    'cross db ownership chaining',
    'contained database authentication',
    'external scripts enabled'
)

ORDER BY name;

------------------------------------------------------------
-- SECTION 3: Built-in SA Account Assessment
------------------------------------------------------------

SELECT
    SYSDATETIME() AS CaptureDate,
    @@SERVERNAME AS ServerName,
    name AS LoginName,
    create_date AS CreatedDate,
    modify_date AS ModifiedDate,

    CASE is_disabled
        WHEN 1 THEN 'Disabled'
        ELSE 'Enabled'
    END AS LoginStatus,

    CASE is_policy_checked
        WHEN 1 THEN 'Enabled'
        ELSE 'Disabled'
    END AS PasswordPolicy,

    CASE is_expiration_checked
        WHEN 1 THEN 'Enabled'
        ELSE 'Disabled'
    END AS PasswordExpiration,

    CASE
        WHEN is_disabled = 1
            THEN 'Built-in SA Account Disabled'
        ELSE 'REVIEW - Built-in SA Account Enabled'
    END AS SecurityAssessment

FROM sys.sql_logins
WHERE sid = 0x01;

------------------------------------------------------------
-- SECTION 4: Database Security Configuration
------------------------------------------------------------

SELECT
    SYSDATETIME() AS CaptureDate,
    @@SERVERNAME AS ServerName,
    name AS DatabaseName,
    state_desc AS DatabaseState,

    CASE is_trustworthy_on
        WHEN 1 THEN 'Enabled'
        ELSE 'Disabled'
    END AS TrustworthyStatus,

    CASE is_db_chaining_on
        WHEN 1 THEN 'Enabled'
        ELSE 'Disabled'
    END AS OwnershipChaining,

    containment_desc AS ContainmentType,

    CASE is_encrypted
        WHEN 1 THEN 'Enabled'
        ELSE 'Disabled'
    END AS EncryptionStatus,

    CASE
        WHEN is_trustworthy_on = 1
            THEN 'HIGH - Review TRUSTWORTHY Setting'

        WHEN is_db_chaining_on = 1
            THEN 'REVIEW - Ownership Chaining Enabled'

        WHEN containment <> 0
            THEN 'REVIEW - Contained Database'

        ELSE 'No Basic Configuration Exception'

    END AS SecurityAssessment

FROM sys.databases

WHERE database_id > 4
AND source_database_id IS NULL

ORDER BY name;

------------------------------------------------------------
-- SECTION 5: Consolidated Security Assessment
------------------------------------------------------------

DECLARE
    @RiskyFeatures INT,
    @TrustworthyDBs INT,
    @ChainingDBs INT,
    @SAEnabled INT,
    @CLRStrictDisabled INT,
    @SettingsMismatch INT;

SELECT
    @RiskyFeatures = COUNT(*)
FROM sys.configurations
WHERE name IN
(
    'xp_cmdshell',
    'Ole Automation Procedures',
    'Ad Hoc Distributed Queries',
    'cross db ownership chaining'
)
AND CONVERT(INT, value_in_use) = 1;

SELECT
    @TrustworthyDBs = COUNT(CASE
        WHEN is_trustworthy_on = 1 THEN 1 END),

    @ChainingDBs = COUNT(CASE
        WHEN is_db_chaining_on = 1 THEN 1 END)

FROM sys.databases
WHERE database_id > 4
AND source_database_id IS NULL;

SELECT
    @SAEnabled = CONVERT(INT, 1 - is_disabled)
FROM sys.sql_logins
WHERE sid = 0x01;

SELECT
    @CLRStrictDisabled = COUNT(*)
FROM sys.configurations
WHERE name = 'clr strict security'
AND CONVERT(INT, value_in_use) = 0;

SELECT
    @SettingsMismatch = COUNT(*)
FROM sys.configurations
WHERE name IN
(
    'xp_cmdshell',
    'Ole Automation Procedures',
    'Ad Hoc Distributed Queries',
    'clr enabled',
    'clr strict security',
    'Database Mail XPs',
    'remote admin connections',
    'remote access',
    'cross db ownership chaining',
    'contained database authentication',
    'external scripts enabled'
)
AND value <> value_in_use;

SELECT
    SYSDATETIME() AS CaptureDate,
    @@SERVERNAME AS ServerName,

    CASE SERVERPROPERTY('IsIntegratedSecurityOnly')
        WHEN 1 THEN 'Windows Authentication'
        WHEN 0 THEN 'Mixed Mode'
        ELSE 'Unknown'
    END AS AuthenticationMode,

    @RiskyFeatures AS RiskyFeaturesEnabled,
    @TrustworthyDBs AS TrustworthyDatabases,
    @ChainingDBs AS OwnershipChainingDatabases,
    @SettingsMismatch AS SecuritySettingMismatches,

    CASE
        WHEN @SAEnabled = 1 THEN 'Enabled'
        WHEN @SAEnabled = 0 THEN 'Disabled'
        ELSE 'Unknown'
    END AS SALoginStatus,

    CASE
        WHEN NOT EXISTS
        (
            SELECT 1
            FROM sys.configurations
            WHERE name = 'clr strict security'
        )
            THEN 'Not Applicable'

        WHEN @CLRStrictDisabled > 0
            THEN 'Disabled'

        ELSE 'Enabled'
    END AS CLRStrictSecurity,

    CASE

        WHEN @RiskyFeatures > 0
          OR @TrustworthyDBs > 0
          OR @CLRStrictDisabled > 0
            THEN 'HIGH - SECURITY CONFIGURATION REVIEW'

        WHEN @SAEnabled = 1
          OR @ChainingDBs > 0
          OR @SettingsMismatch > 0
          OR SERVERPROPERTY('IsIntegratedSecurityOnly') = 0
            THEN 'REVIEW REQUIRED'

        WHEN @SAEnabled IS NULL
            THEN 'INCOMPLETE SECURITY ASSESSMENT'

        ELSE 'NO BASIC SECURITY EXCEPTIONS DETECTED'

    END AS OverallSecurityAssessment;

GO
