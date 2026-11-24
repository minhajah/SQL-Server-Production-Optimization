/*
============================================================
Project : SQL Server Production Optimization
Module  : 02 - Server Configuration
Script  : 08-HTML-Configuration-Report.sql
Purpose : Generate HTML configuration assessment report
Type    : Read-Only Assessment
Impact  : Low - dependent on plan cache size
============================================================
*/
------------------------------------------------------------
-- SECTION 12: HTML Report Variables
------------------------------------------------------------

DECLARE
    @HTML NVARCHAR(MAX),
    @CategoryRows NVARCHAR(MAX),
    @FindingRows NVARCHAR(MAX),
    @AllAssessmentRows NVARCHAR(MAX),
    @TotalChecks INT,
    @PassedChecks INT,
    @ReviewChecks INT,
    @ObserveChecks INT,
    @UnavailableChecks INT,
    @HighPriority INT,
    @MediumPriority INT,
    @OverallStatus NVARCHAR(100),
    @StatusColor NVARCHAR(20),
    @ReportServer NVARCHAR(256),
    @ReportVersion NVARCHAR(100),
    @ReportEdition NVARCHAR(256),
    @ReportCU NVARCHAR(100);

------------------------------------------------------------
-- SECTION 13: Server Information
------------------------------------------------------------

SELECT
    @ReportServer = ISNULL(
        CONVERT(NVARCHAR(256), @@SERVERNAME),
        'Unknown'),

    @ReportVersion = ISNULL(
        CONVERT(NVARCHAR(100),
        SERVERPROPERTY('ProductVersion')),
        'Unknown'),

    @ReportEdition = ISNULL(
        CONVERT(NVARCHAR(256),
        SERVERPROPERTY('Edition')),
        'Unknown'),

    @ReportCU = ISNULL(
        CONVERT(NVARCHAR(100),
        SERVERPROPERTY('ProductUpdateLevel')),
        'N/A');

-- Encode server information for HTML safety

SET @ReportServer = (
    SELECT @ReportServer AS [text()]
    FOR XML PATH('')
);

SET @ReportVersion = (
    SELECT @ReportVersion AS [text()]
    FOR XML PATH('')
);

SET @ReportEdition = (
    SELECT @ReportEdition AS [text()]
    FOR XML PATH('')
);

SET @ReportCU = (
    SELECT @ReportCU AS [text()]
    FOR XML PATH('')
);

------------------------------------------------------------
-- SECTION 14: Assessment Summary
------------------------------------------------------------

SELECT
    @TotalChecks = COUNT(*),

    @PassedChecks = COUNT(CASE
        WHEN AssessmentStatus = 'PASS'
        THEN 1 END),

    @ReviewChecks = COUNT(CASE
        WHEN AssessmentStatus = 'REVIEW'
        THEN 1 END),

    @ObserveChecks = COUNT(CASE
        WHEN AssessmentStatus = 'OBSERVE'
        THEN 1 END),

    @UnavailableChecks = COUNT(CASE
        WHEN AssessmentStatus IN
        ('UNKNOWN', 'NOT AVAILABLE')
        THEN 1 END),

    @HighPriority = COUNT(CASE
        WHEN Priority = 'HIGH'
        AND AssessmentStatus = 'REVIEW'
        THEN 1 END),

    @MediumPriority = COUNT(CASE
        WHEN Priority = 'MEDIUM'
        AND AssessmentStatus = 'REVIEW'
        THEN 1 END)

FROM @Findings;

------------------------------------------------------------
-- SECTION 15: Overall Configuration Status
------------------------------------------------------------

SET @OverallStatus =
    CASE
        WHEN @TotalChecks = 0
            THEN 'NO ASSESSMENT DATA'

        WHEN @HighPriority > 0
            THEN 'HIGH PRIORITY REVIEW REQUIRED'

        WHEN @ReviewChecks > 0
            THEN 'CONFIGURATION REVIEW REQUIRED'

        WHEN @UnavailableChecks > 0
            THEN 'ASSESSMENT PARTIALLY INCOMPLETE'

        ELSE 'NO BASIC CONFIGURATION EXCEPTIONS DETECTED'
    END;

SET @StatusColor =
    CASE
        WHEN @HighPriority > 0 THEN '#C00000'
        WHEN @ReviewChecks > 0 THEN '#D97706'
        WHEN @UnavailableChecks > 0 THEN '#64748B'
        WHEN @TotalChecks = 0 THEN '#64748B'
        ELSE '#15803D'
    END;

------------------------------------------------------------
-- SECTION 16: Category-Level HTML Summary
------------------------------------------------------------

SET @CategoryRows = CAST(
(
    SELECT
        Category AS 'td', '',

        COUNT(*) AS 'td', '',

        COUNT(CASE
            WHEN AssessmentStatus = 'PASS'
            THEN 1 END) AS 'td', '',

        COUNT(CASE
            WHEN AssessmentStatus = 'REVIEW'
            THEN 1 END) AS 'td', '',

        COUNT(CASE
            WHEN AssessmentStatus = 'OBSERVE'
            THEN 1 END) AS 'td', '',

        COUNT(CASE
            WHEN AssessmentStatus IN
                ('UNKNOWN', 'NOT AVAILABLE')
            THEN 1 END) AS 'td', '',

        COUNT(CASE
            WHEN Priority = 'HIGH'
            AND AssessmentStatus = 'REVIEW'
            THEN 1 END) AS 'td'

    FROM @Findings

    GROUP BY Category
    ORDER BY Category

    FOR XML PATH('tr'), TYPE

) AS NVARCHAR(MAX));

------------------------------------------------------------
-- SECTION 17: Actionable Findings HTML
------------------------------------------------------------

SET @FindingRows = CAST(
(
    SELECT

        AssessmentID AS 'td', '',

        Category AS 'td', '',

        AssessmentName AS 'td', '',

        ISNULL(CurrentValue, 'Unknown') AS 'td', '',

        PreferredBaseline AS 'td', '',

        CASE Priority
            WHEN 'HIGH'
                THEN 'color:#C00000;font-weight:bold;'
            WHEN 'MEDIUM'
                THEN 'color:#D97706;font-weight:bold;'
            ELSE 'color:#64748B;'
        END AS 'td/@style',

        Priority AS 'td', '',

        RecommendedAction AS 'td'

    FROM @Findings

    WHERE AssessmentStatus = 'REVIEW'

    ORDER BY
        CASE Priority
            WHEN 'HIGH' THEN 1
            WHEN 'MEDIUM' THEN 2
            WHEN 'LOW' THEN 3
            ELSE 4
        END,
        AssessmentID

    FOR XML PATH('tr'), TYPE

) AS NVARCHAR(MAX));

IF @ReviewChecks = 0
BEGIN
    SET @FindingRows = N'
    <tr>
        <td colspan="7"
            style="color:#15803D;font-weight:bold;">
            No actionable configuration exceptions detected.
        </td>
    </tr>';
END;

------------------------------------------------------------
-- SECTION 18: Complete Assessment HTML
------------------------------------------------------------

SET @AllAssessmentRows = CAST(
(
    SELECT

        AssessmentID AS 'td', '',

        Category AS 'td', '',

        AssessmentName AS 'td', '',

        ISNULL(CurrentValue, 'Unknown') AS 'td', '',

        PreferredBaseline AS 'td', '',

        Priority AS 'td', '',

        CASE AssessmentStatus

            WHEN 'PASS'
                THEN 'color:#15803D;font-weight:bold;'

            WHEN 'REVIEW'
                THEN 'color:#D97706;font-weight:bold;'

            WHEN 'OBSERVE'
                THEN 'color:#2563EB;'

            ELSE 'color:#64748B;'

        END AS 'td/@style',

        AssessmentStatus AS 'td'

    FROM @Findings

    ORDER BY
        Category,
        AssessmentID

    FOR XML PATH('tr'), TYPE

) AS NVARCHAR(MAX));

------------------------------------------------------------
-- SECTION 19: Generate Complete HTML Report
------------------------------------------------------------

SET @HTML = CAST(N'
<!DOCTYPE html>
<html>

<head>
<meta charset="UTF-8">
<title>SQL Server Configuration Assessment</title>

<style>

body {
    font-family: Arial, sans-serif;
    font-size: 13px;
    color: #333333;
    margin: 25px;
    background-color: #FFFFFF;
}

.header {
    background-color: #17365D;
    color: #FFFFFF;
    padding: 20px;
}

h1 {
    font-size: 24px;
}

h2 {
    background-color: #E8EEF5;
    color: #17365D;
    padding: 10px;
    font-size: 16px;
    margin-top: 25px;
}

table {
    width: 100%;
    border-collapse: collapse;
    margin-bottom: 20px;
}

th {
    background-color: #305496;
    color: #FFFFFF;
    padding: 9px;
    text-align: left;
    border: 1px solid #DDDDDD;
}

td {
    padding: 8px;
    border: 1px solid #DDDDDD;
    vertical-align: top;
}

tr:nth-child(even) {
    background-color: #F5F7FA;
}

.summary {
    background-color: #F5F7FA;
    text-align: center;
    font-size: 14px;
}

.summary-value {
    font-size: 26px;
    font-weight: bold;
}

.note {
    background-color: #FFF7E6;
    border: 1px solid #E5C07B;
    padding: 12px;
    margin-bottom: 15px;
}

.footer {
    color: #777777;
    font-size: 11px;
    border-top: 1px solid #DDDDDD;
    padding-top: 12px;
    margin-top: 25px;
}

</style>

</head>

<body>

<div class="header">

<h1>SQL Server Configuration Assessment</h1>

<p>Server: ' AS NVARCHAR(MAX))

+ @ReportServer + N'</p>

<p>Generated: '
+ CONVERT(NVARCHAR(30), @CaptureDate, 120)
+ N'</p>

</div>

<h2>Overall Configuration Status</h2>

<p style="font-size:18px;font-weight:bold;color:'
+ @StatusColor + N';">'

+ @OverallStatus + N'</p>

<h2>01. Server Information</h2>

<table>

<tr>
<th>Parameter</th>
<th>Value</th>
</tr>

<tr>
<td>SQL Server Name</td>
<td>' + @ReportServer + N'</td>
</tr>

<tr>
<td>SQL Server Edition</td>
<td>' + @ReportEdition + N'</td>
</tr>

<tr>
<td>SQL Server Version</td>
<td>' + @ReportVersion + N'</td>
</tr>

<tr>
<td>CU Level</td>
<td>' + @ReportCU + N'</td>
</tr>

<tr>
<td>Physical RAM (MB)</td>
<td>'
+ ISNULL(CONVERT(NVARCHAR(30), @TotalRAM_MB),
    'Unknown') + N'</td>
</tr>

<tr>
<td>Online Logical CPUs</td>
<td>'
+ ISNULL(CONVERT(NVARCHAR(30), @CPUCount),
    'Unknown') + N'</td>
</tr>

</table>

<h2>02. Assessment Summary</h2>

<table class="summary">

<tr>

<td>
Total Checks<br>
<span class="summary-value">'
+ CONVERT(NVARCHAR(20), @TotalChecks) + N'
</span>
</td>

<td>
Passed<br>
<span class="summary-value"
style="color:#15803D;">'
+ CONVERT(NVARCHAR(20), @PassedChecks) + N'
</span>
</td>

<td>
Review Required<br>
<span class="summary-value"
style="color:#D97706;">'
+ CONVERT(NVARCHAR(20), @ReviewChecks) + N'
</span>
</td>

</tr>

<tr>

<td>
High Priority<br>
<span class="summary-value"
style="color:#C00000;">'
+ CONVERT(NVARCHAR(20), @HighPriority) + N'
</span>
</td>

<td>
Medium Priority<br>
<span class="summary-value"
style="color:#D97706;">'
+ CONVERT(NVARCHAR(20), @MediumPriority) + N'
</span>
</td>

<td>
Observations<br>
<span class="summary-value"
style="color:#2563EB;">'
+ CONVERT(NVARCHAR(20), @ObserveChecks) + N'
</span>
</td>

</tr>

<tr>

<td colspan="3">
Unavailable / Unknown Checks:
<strong>'
+ CONVERT(NVARCHAR(20), @UnavailableChecks) + N'
</strong>
</td>

</tr>

</table>

<h2>03. Assessment by Category</h2>

<table>

<tr>
<th>Category</th>
<th>Total</th>
<th>Passed</th>
<th>Review</th>
<th>Observe</th>
<th>Unavailable</th>
<th>High Priority</th>
</tr>'

+ ISNULL(@CategoryRows, N'') + N'

</table>

<h2>04. Actionable Findings &amp; Recommendations</h2>

<div class="note">

Configuration findings are investigation candidates.
Validate workload, application dependencies and
business requirements before implementing changes.

</div>

<table>

<tr>
<th>ID</th>
<th>Category</th>
<th>Assessment</th>
<th>Current Value</th>
<th>Preferred Baseline</th>
<th>Priority</th>
<th>Recommended Action</th>
</tr>'

+ ISNULL(@FindingRows, N'') + N'

</table>

<h2>05. Complete Configuration Assessment</h2>

<table>

<tr>
<th>ID</th>
<th>Category</th>
<th>Assessment</th>
<th>Current Value</th>
<th>Preferred Baseline</th>
<th>Priority</th>
<th>Status</th>
</tr>'

+ ISNULL(@AllAssessmentRows, N'') + N'

</table>

<h2>06. Assessment Status Definitions</h2>

<table>

<tr>
<th>Status</th>
<th>Description</th>
</tr>

<tr>
<td style="color:#15803D;">PASS</td>
<td>Meets the particular assessment baseline.</td>
</tr>

<tr>
<td style="color:#D97706;">REVIEW</td>
<td>Requires DBA investigation.</td>
</tr>

<tr>
<td style="color:#2563EB;">OBSERVE</td>
<td>Requires workload-specific validation.</td>
</tr>

<tr>
<td>UNKNOWN</td>
<td>Insufficient information for assessment.</td>
</tr>

<tr>
<td>NOT AVAILABLE</td>
<td>Setting unavailable or unsupported.</td>
</tr>

</table>

<h2>07. Production Safety &amp; Limitations</h2>

<p>
This report is generated using read-only assessment
queries and temporary session-level data.
</p>

<ul>

<li>No permanent database objects created.</li>

<li>No server configuration changes performed.</li>

<li>No application data modified.</li>

<li>No services restarted.</li>

<li>Assessment results represent selected configuration
checks and point-in-time observations.</li>

<li>Metadata permissions may affect completeness.</li>

<li>Recommendations require workload validation
and change approval.</li>

<li>This is not a complete SQL Server health
or security assessment.</li>

</ul>

<div class="footer">

SQL Server Production Optimization Framework<br>

Module 02 - SQL Server Configuration Assessment<br>

Generated automatically using T-SQL.

</div>

</body>
</html>';

------------------------------------------------------------
-- SECTION 20: Return HTML Report
------------------------------------------------------------

SELECT @HTML AS HTMLReport;

GO
