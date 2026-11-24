# SQL Server Health Check Coverage

Baseline: Framework Design v1.0 | 24 November 2026

## Purpose

Mandatory minimum functional coverage derived from Uday Arumilli's [SQL Server Health Check HTML Report](https://udayarumilli.com/sql-server-health-check-html-report/) (9 May 2020). This is a requirements cross-reference, not a copy of the original SQL code. Retain all 33 existing modules and the approved architecture.

## Coverage and acceptance checklist

| ID | Required capability | Owning module | Supporting modules | Acceptance evidence | Initial status |
|---|---|---|---|---|---|
| HC-01 | Host inventory | 01 | 15 | Host and resource inventory | Standalone verified |
| HC-02 | Instance properties | 01 | 02 | Version, edition and instance settings | Standalone verified |
| HC-03 | Volume utilization | 08 | 01, 15 | Free bytes, percent, mount points, growth trend | Partial |
| HC-04 | TempDB utilization | 10 | 02 | User/internal/version store usage, file/log utilization, contention | Partial |
| HC-05 | Processor utilization | 06 | 22 | SQL and host CPU, sustained pressure, runnable queues | Planned |
| HC-06 | Memory utilization | 07 | 02 | Host and SQL memory, pressure, grants | Partial |
| HC-07 | Performance counters | 22 | 06, 07, 08, 09 | PLE, cache ratio with base, grants, CPU, throughput and I/O; reset-aware rates | Planned |
| HC-08 | Backup compliance | 04 | 19 | Full/differential/log as policy requires, RPO, AG and PPDM reconciliation | Planned |
| HC-09 | Connection analysis | 22 | 13 | Counts by database, active/sleeping sessions, connection trends | Planned |
| HC-10 | Log utilization | 16 | 15 | Used/free log, reuse waits, growth and VLFs where supported | Planned |
| HC-11 | Agent execution health | 21 | 01, 22 | Failed, overdue, long-running jobs and Agent availability | Partial |
| HC-12 | Blocking | 14 | 22 | Head blocker, duration, affected sessions; existing collector reuse | Planned |
| HC-13 | Open transactions | 16 | 14 | Transaction age, database, log usage and blocking evidence | Planned |
| HC-14 | Largest tables | 15 | 11 | Top 20 by reserved/used space using metadata, row estimates and growth | Planned |
| HC-15 | Index assessment | 11 | 12, 21 | Usage, size, candidate missing/duplicate indexes and bounded fragmentation diagnostics | Planned |
| HC-16 | Error log review | 22 | 19, 20 | Bounded recent errors, severity, recurrence and collection failures | Planned |

## Reporting rules

- Daily: compact fleet exceptions, including availability, backup, disk, jobs, blocking and sustained resource pressure. Show collection coverage and stale/unknown data.
- Weekly: resource trends, configuration risks, index and query opportunities, recurring errors.
- Monthly: table and database growth, capacity projections and remediation outcomes.
- On demand: detailed per-instance HTML and SSMS investigations. Do not concatenate every module report.
- Critical incidents: event-based notifications under approved thresholds; distinguish operational incidents from configuration findings.

## Additional framework coverage

Database states and configuration (03), integrity (05), waits (09), statistics (12), query performance (13), deadlocks (14), security (17), auditing (18), AG (19), FCI (20), maintenance (21), patching (23), baselines (24), final assessment (25), centralized collection and reports (26–31), thresholds (32) and improvement tracking (33).

## Validation gates

For each HC ID, record the actual script path, supported versions, permission and overhead tests, normal/exception/unknown cases, structured output mapping, and central reporting verification. Completion requires evidence, not merely a module assignment. Existing standalone verification does not establish AG/FCI or central collection compatibility.

Use bounded read-only queries, avoid application table scans for routine sizing, use counter deltas with reset detection where applicable, and do not deploy procedures, jobs or email infrastructure without separate approval. No fixed universal PLE or CPU threshold; use validated policies and trends. Do not collect full SQL text or credentials by default.

This checklist supplements Framework-Design.md; it does not change the design baseline. Initial statuses are provisional based on the development session, not an independent execution audit. The reference article's published scope was reviewed; its downloadable procedure was not audited.
