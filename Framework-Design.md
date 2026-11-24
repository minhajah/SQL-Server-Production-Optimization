# SQL Server Production Optimization Framework

**Design baseline:** v1.0 | **Date:** 2026-11-24 | **Status:** Proposed for owner approval; implementation and production validation pending

## 1. Scope and architecture

Retain the existing 33-module roadmap and folder names. The number of supporting scripts is not a target. Each module must solve a distinct operational or assessment problem. The existing Python inventory application remains unchanged. Integration is a later design decision.

Architecture: SQL Server instances → scheduled read-only collectors → central DBA repository → assessment and incident lifecycle → exception-based dashboard, alerts and reports. Detailed module reports and SSMS investigation scripts are on-demand tools, not daily email attachments. Central storage, scheduler, credentials and notification infrastructure require separate approved deployment; no permanent objects are created on monitored production instances by assessment scripts.

| Phase | Modules | Deliverable |
|---|---|---|
| Baseline | 01–05 | Inventory, configuration, backup and integrity |
| Performance | 06–16 | CPU, memory, I/O, waits, TempDB, indexes, statistics, queries, blocking, capacity and transaction log |
| Reliability and security | 17–25 | Security, auditing, AG, clustering, maintenance, monitoring, patching, baseline and final assessment |
| Reporting | 26–31 | Collection, daily, weekly, monthly, centralized reporting and email |
| Continuous improvement | 32–33 | Thresholds and improvement tracking |

The roadmap describes development scope, not the number of daily reports. Build a small end-to-end pilot early; do not wait until module 26 to test collection and reporting compatibility.

## 2. Module template

Keep existing names for modules 01 and 02. For subsequent modules use the established numbered SQL filenames and README.md and Assessment-Report.md. Include only necessary scripts. A typical module contains detailed diagnostic scripts, one consolidated assessment returning a machine-readable result set, and an optional independently executable HTML report for on-demand review. Existing HTML reports remain supported. Avoid duplicating a check across modules unless diagnostic detail is needed; assign one owning module and stable check ID.

Every SQL file uses the existing header: Project, Module, Script, Purpose, Type, Impact. Document supported versions, permissions, expected output, collection interval, scope and limitations. No SQLCMD mode or external dependency for standalone SSMS diagnostics. The collector may use separate approved orchestration.

## 3. Standard assessment contract

Version the interface (ContractVersion = 1.0). Consolidated scripts expose one designated, stable assessment result set for automation; additional diagnostic result sets are allowed and documented. Existing modules may use an adapter or a minimal compatibility change after review; no wholesale rewrite. Use UTC capture times. The collector supplies stable TargetId and RunId and maps instance/database identity to inventory. Database names are display labels, not durable identifiers. ScopeId identifies the specific database, file, job, replica or instance within a target; rename/recreation reconciliation is explicit.

| Field | Type / meaning |
|---|---|
| ContractVersion | varchar(10), schema version |
| RunId | uniqueidentifier, collection attempt |
| CapturedAtUtc | datetime2(3) |
| TargetId | stable collector-assigned identifier |
| ServerName | nvarchar(256), display name |
| ModuleId | char(2) |
| AssessmentId | varchar(30), stable within module |
| ScopeType | varchar(20), INSTANCE/DATABASE/FILE/JOB/REPLICA/etc. |
| ScopeId | nvarchar(256), stable within scope where feasible |
| ScopeName | nvarchar(256), human-readable object name |
| DatabaseName | sysname, nullable when not applicable |
| Category | nvarchar(100) |
| AssessmentName | nvarchar(200) |
| CurrentValue | nvarchar(1000), display value |
| MetricValue | decimal(28,8), nullable numeric evidence |
| MetricUnit | varchar(30), nullable |
| PreferredBaseline | nvarchar(1000), rule or policy reference |
| ThresholdVersion | varchar(30), rule version |
| FindingType | varchar(20), OPERATIONAL/CONFIGURATION/ADVISORY |
| Priority | varchar(10), CRITICAL/HIGH/MEDIUM/LOW/INFO |
| AssessmentStatus | varchar(20), PASS/REVIEW/OBSERVE/UNKNOWN/NOT AVAILABLE |
| RecommendedAction | nvarchar(2000), safe next step |
| Evidence | nvarchar(max), optional sanitized diagnostic context |

Use NULL for unavailable values, never zero to represent missing data. Operational alerts are derived from rules and confirmed observations; configuration HIGH is not an outage. Maintain compatibility with existing statuses. Collector envelope is separate and always recorded, even when the SQL connection fails: RunId, TargetId, ModuleId, StartedAtUtc, CompletedAtUtc, CollectionStatus (SUCCESS/PARTIAL/FAILED/TIMEOUT/SKIPPED), error category/message, row count and rule/collector version. A successful empty result is not proof of health unless the check explicitly defines that meaning. Unknown results cannot resolve existing findings.

## 4. Severity and lifecycle

| Priority | Meaning | Delivery |
|---|---|---|
| CRITICAL | Confirmed urgent operational or security condition under approved policy | Immediate alert; recovery notification |
| HIGH | Important risk or sustained degradation | Daily exception summary; escalate per policy |
| MEDIUM | Investigation or improvement opportunity | Weekly optimization report |
| LOW | Minor opportunity | Weekly/monthly backlog |
| INFO | Baseline or contextual observation | Dashboard/on demand |

Finding identity: TargetId + ModuleId + AssessmentId + ScopeType + ScopeId. Track first/last seen UTC, latest evidence, severity, owner, state, exception approval/expiry, remediation ticket and resolution date. Lifecycle: Open → Under investigation → Remediation planned → Resolved; approved exception is a documented alternate state with review date. Reopen recurring issues; distinguish new, ongoing, worsening, recovered and suppressed notifications. Suppression never hides the issue from the dashboard. Do not close findings on timeout or missing data. Use consecutive samples, hysteresis and cooldown for noisy metrics; allow immediate alerts for confirmed hard failures. An enabled built-in sa login is a HIGH configuration review, not an automatic critical incident.

## 5. Collection and production safeguards

Use version/feature and permission checks. SQL Server 2017–2022 is the initial proposed validation matrix (later versions tested separately); unsupported features return NOT AVAILABLE. Standalone, AG primary/secondary, FCI, named instances and restricted permissions need test cases. Use existing authorized DBA access for pilots; design least-privilege collector credentials separately. Never grant sysadmin solely for monitoring. No changes to configuration, agent jobs, user data, cache or services in assessment scripts. Temporary structures are allowed and documented. No blanket NOLOCK, unbounded scans of application tables, routine CHECKDB, physical index scans, full plan XML capture or expensive diagnostics in frequent collectors. Diagnostic scripts with higher impact must be explicitly labeled and run on demand or in approved windows. Bound concurrency and connection/query timeouts in the collector. Measure duration, CPU and I/O before rollout. Avoid simultaneous polling spikes and duplicate AG backup alerts; correlate replicas with database and backup policy. Use existing monitoring/backup sources including PPDM where appropriate. Do not collect secrets, full query text or sensitive data by default.

Proposed cadence (validate against SLA, RPO and overhead): availability/AG/CPU/memory 1–5 min; blocking 30–60 s using existing monitoring if suitable; disk/jobs 5–15 min; backups based on per-database policy (e.g. 15–30 min where appropriate); configuration daily or weekly; expensive index analysis weekly/on demand; capacity monthly. Use deltas for cumulative counters with reset detection. A stale or failed collector is UNKNOWN, not healthy. Do not duplicate existing monitoring jobs without approval.

## 6. Central repository and dashboard

Logical entities: Targets, CollectionRuns, AssessmentResults, MetricSamples, Findings, FindingHistory, ThresholdPolicies, ApprovedExceptions, NotificationHistory. Physical schema, indexes, retention and deployment are separate implementation deliverables. Proposed retention: raw high-frequency metrics 30 days, hourly aggregates 90 days, daily summaries 13 months; finding history according to organizational audit policy. Confirm storage sizing and access controls before deployment.

Default dashboard: last successful collection, target coverage, critical incidents, warning targets, unknown/unreachable targets, new/worsening findings, resolved findings and overdue actions. Filters: server, environment, module, severity, scope, status, date. Drill-down: fleet → target → issue → evidence → relevant SSMS diagnostic script → remediation record. Separate operational health from configuration risk. Health status precedence: confirmed critical incident, operational warning, incomplete/stale coverage, healthy only when required operational checks are current and passing. Preserve coverage indicators even when an incident exists. Do not derive a health percentage from arbitrary counts of unlike checks.

## 7. Final reporting templates

### Critical alert (event-driven)
Subject: [SQL][CRITICAL] Target – issue. Body: first detected UTC/local time, affected scope, current evidence, threshold, operational impact (if known), last successful collection, immediate investigation steps and incident reference. Deduplicate and send escalation/recovery according to approved policy.

### Daily health report (one fleet email)
Subject: [SQL] Daily Health – YYYY-MM-DD. Include coverage (expected/collected/failed/stale targets), operational health counts, current critical incidents, new/worsening warnings, backup/AG/job/storage/availability exceptions, recovered incidents and outstanding high-risk count. Show at most 10 rows per exception section by severity and age; show remaining count and dashboard reference. No full inventories, all-pass rows or complete module HTML attachments. If no issues, show an explicit healthy summary only when coverage is complete.

### Weekly optimization report
Subject: [SQL] Weekly Optimization – date range. Include new and outstanding configuration/security/performance findings, workload trends, evidence, top actionable opportunities, approved exceptions due for review, owners and target dates. Link to detailed module reports on demand. Distinguish observations from approved changes.

### Monthly management report
Subject: [SQL] Monthly Reliability & Capacity – YYYY-MM. Include coverage, availability and backup compliance against defined SLAs, incident trends, capacity projections with assumptions, risk backlog, closed improvements and measured outcomes. Avoid unsupported compliance claims or forecasts with insufficient history.

### HTML presentation standard
Use compact blue/white report style consistent with modules 01–02. Use text severity labels as well as color; email-compatible tables and inline styles. Escape all dynamic HTML content. Provide single HTML result for standalone module reports; no embedded scripts or external resources. Centralized reports are rendered from collected data, not concatenated module HTML. Limit email length and provide internal drill-down only when deployed and authorized.

## 8. Definition of done

A module is complete for its stated validation scope when: purpose and ownership are defined; scripts execute in SSMS with documented outputs; standardized assessment mapping is verified; normal, exception, NULL/empty and permission/error cases are tested; overhead is measured on representative systems; output counts and priorities reconcile; no sensitive data is committed; README and assessment template are updated. HTML and structured findings must agree for the same snapshot/rules. Record test environment, version, date and unresolved limitations. Standalone verified is not HA or cross-version certification. Test central ingestion and alert deduplication on the early pilot before scaling.

## 9. Immediate closeout and change control

1. Approve this design baseline and commit Framework-Design.md at repository root; reference it from the main README.
2. Review modules 01–02 against the contract, safety checks and output consistency. Preserve existing validated files unless a defect or necessary compatibility gap is identified. Module 01 inventory is inventory data, not a fabricated health assessment; map it to Targets and collection coverage.
3. Prototype collection of modules 01–02 on one approved test target using a separate central/test environment; verify ingestion, new/existing/resolved/unknown states and a compact daily report. Add synthetic operational incidents to test alert logic without changing production.
4. Record pilot results and any necessary contract revisions before developing module 03. No production deployment without approval.

Changes to stable IDs, result schemas, severity rules, frequency or deployment require a documented rationale, version update and regression test. Maintain backwards compatibility where practical. This is the design baseline, not a claim that centralized monitoring is implemented or production-approved.
