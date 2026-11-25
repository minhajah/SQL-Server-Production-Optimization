# Module 30 – Consolidated Technical Review

## 1. Review baseline

| Property | Value |
|---|---|
| Project | SQL Server Production Optimization |
| Scope | Modules 26 and 30 |
| Source | SQL-Server-Production-Optimization-main (1).zip |
| Review type | Targeted static source review |
| Review date | 2026-11-25 |
| Repository schema target | 1.0.6 |
| Status | OPEN – validation pending |

The archive integrity check passed. It contains 42 SQL files, including 16 Module 26 collectors and 10 Module 30 scripts. This review uses the uploaded SQL baseline, not a live GitHub revision. Documentation replacements reported by the maintainer do not alter the SQL baseline. No SQL was compiled, executed or deployed. Source line references below refer to the uploaded baseline and will change after corrections.

## 2. Defect register

IDs below preserve the CM-001 through CM-010 mapping from the latest consolidated review; additional findings extend it. Earlier validation checklist IDs are a separate list, not a one-to-one mapping. Priority is a proposed engineering assessment. All items are OPEN.

| ID | Priority | Source evidence | Required correction | Acceptance criterion |
|---|---|---|---|---|
| CM-001 | Critical | M30/02 defines MetricDefinitions (420–485); M30/08 rejects unknown metric IDs; no registration INSERT exists in M30 scripts | Add 11-Register-Metric-Definitions.sql from actual collector output; review diagnostic IDs, units and policies | Every emitted metric has a valid definition; unknown IDs rejected; registration rerunnable without overwriting approved policies |
| CM-002 | Critical | M30/09 uses temporary #VerifiedHours (1053,1197,1224,1350); verification compares remaining samples to original aggregate | Persist verified cleanup coverage or delete entire verified groups atomically; reconcile late data before sealing | Interrupted cleanup resumes without losing or stranding historical observations |
| CM-003 | High | M26/13 reads sys.dm_os_wait_stats without filtering (181–199); M30/05 COL-13 interval 300 seconds and output limit 15000 | Measure volume, suppress unnecessary zero deltas, preserve baselines, define wait filtering and retention | Representative wait workload fits agreed storage and execution limits; reset and delta totals remain correct |
| CM-004 | High | M26/11 reads @EventFilePath with NULL position parameters (237–246) and fixed lookback | Implement validated XE file/offset progression, rollover and gap reporting | Multiple files, restart, missing file and duplicate replay tests pass; checkpoint advances only with committed data |
| CM-005 | High | M26/12 fixed lookback and 50 MB guard (28–29), xp_readerrorlog (200), unverified coverage metric (662) | Implement bounded incremental scanning, rotation awareness and explicit coverage gaps; retain large-file safeguard | Rotation and outage replay do not silently omit or double-count available events; oversized logs skipped safely |
| CM-006 | High | M30/08 refreshes resource IsActive; M30/10 consumes IsActive in freshness logic (733,775) | Define collector-scoped resource lifecycle and current-run membership for transient requests | Completed sessions disappear from current-active reporting without erasing valid history |
| CM-007 | High | M30/08 resolves definitions by CollectorID and MetricID; input validation does not enforce catalog category/resource/unit (635 onward) | Validate allowed categories, resource types and units; support legitimate dynamic units explicitly | Invalid combinations rejected; supported variable-unit metrics accepted; no mixed-unit aggregation |
| CM-008 | High | M30/01–05 use IF @AllowDeployment <> 1 (64,50,56,57,59); all ten server guards compare nullable approved identity | Fail closed for NULL/blank/placeholder approval and wrong server/database; review USE/GO and transaction guards | NULL flags/identity, wrong server, missing database and failed context switch cannot deploy any object |
| CM-009 | Medium | M26/13 WAI-002 unit CumulativeMilliseconds (322–328); M30/08 delta retains original unit | Standardize delta unit semantics and reporting examples | Wait reports return expected rows with correct units and interval totals |
| CM-010 | High | No CREATE ROLE or GRANT implementation found in M30 baseline | Add 12-Repository-Security.sql; separate ingestion, reporting and administrative access | Monitoring identity cannot reset checkpoints, delete history or modify safety configuration; approved procedures work |
| CM-011 | High | M30/02 MetricDefinitions lacks CollectorID foreign key (420–485) | Add FK after orphan validation; enforce sample collector ownership via ingestion and restricted direct writes | Orphan definitions and cross-collector ingestion rejected |
| CM-012 | High | M30/06 completion accepts caller row counts/status (551–599,722–724); M30/07 checkpoint save relies on caller transaction | Enforce ingestion/finalization consistency, restrict write APIs, verify commit reconciliation | Failure injection after each step leaves no advanced checkpoint or partially committed successful run |
| CM-013 | High | M30/08 updates LastSuccessfulCaptureUTC only when latest observation is replaced (1357 onward) | Define handling of out-of-order successful observations and equal-time conflicts | Last successful value is correct after delayed success followed by newer failure |
| CM-014 | High | M30/08 uses one CounterEpoch parameter per batch (501,1114); M26/13 reads cumulative counters | Define source-specific generation and reset detection, including database/file recreation | Restart, decrease, generation change and undetectable-reset limitations tested and documented |
| CM-015 | High | M30/08 hourly aggregation refuses existing rollups; M30/09 relies on exact coverage verification | Define reconciliation and immutable/sealed hour protocol | Late samples before/after sealing handled explicitly; no deletion of unrepresented observations |
| CM-016 | High | M26/16 uses min/max history IDs (163–183) and checkpoint progression (299 onward) | Reconcile purge, restore, concurrent insertion, ID reuse and bounded overlap | Normal purge does not silently skip available executions; restored/reset history identified and audited |
| CM-017 | High | M26/05 uses sys.master_files and sys.dm_os_volume_stats (74–79) | Add separately approved host-volume coverage without enabling xp_cmdshell | Required OS, backup and log volumes reported or marked unavailable |
| CM-018 | High | M26/06 uses local msdb.dbo.backupset (208,252) | Reconcile AG replica history and enterprise backup evidence; distinguish backup history from restore verification | Replica backup placement does not trigger false missing-backup conclusions; coverage gaps visible |
| CM-019 | High | M30/05 defines intervals and output caps; M30/06 limits reservations; no Python runner exists in baseline | Benchmark scheduling, stagger runs, implement instance-wide circuit breaker and cancellation | Approved concurrency respected; collection delays and outage attempts remain within agreed limits |
| CM-020 | High | M30/09 uses session-owned maintenance locks and bounded batch loop (1246 onward) | Test cancellation, connection disposal and abandoned audit recovery | Interrupted maintenance releases locks when connection closes; committed deletes remain auditable |
| CM-021 | Medium | M30/09 retains event registry and references to first collection runs | Define safe event replay horizon and resource/registry lifecycle | Registry growth bounded by approved policy without reintroducing duplicate events |
| CM-022 | High | M30/10 freshness logic uses schedule and age (775 onward); resource health thresholds absent | Keep freshness separate from resource severity; add threshold framework after ingestion validation | Missing, failed or stale data never shown as healthy; current metrics evaluated by approved thresholds |

## 3. Metric catalog discovery

Distinct quoted metric-ID literals, extracted using the pattern `[A-Z]{2,4}-[0-9]{3}` in the 16 collector files. These are candidates, not yet a verified executable output catalog.

| Collector | Candidate IDs |
|---|---:|
| 01 Instance Health | 5 |
| 02 Database Health | 8 |
| 03 CPU | 13 |
| 04 Memory | 20 |
| 05 Storage | 19 |
| 06 Backup | 28 |
| 07 HA | 34 |
| 08 SQL Agent | 21 |
| 09 Blocking | 25 |
| 10 Transaction Log | 25 |
| 11 Deadlock | 15 |
| 12 Error Log | 26 |
| 13 Wait Statistics | 11 |
| 14 TempDB | 28 |
| 15 Long-Running Query | 29 |
| 16 SQL Agent History | 20 |
| Total | 327 |

Each catalog row must be checked against actual SELECT/INSERT output branches. Literal counting alone does not establish completeness of dynamically generated metrics or supported runtime units.

## 4. Implementation sequence

1. Correct deployment guards in existing M30 scripts; preserve filenames and default disabled settings.
2. Prepare complete metric definition catalog and registration script.
3. Correct ingestion validation, referential integrity and transaction contracts.
4. Correct historical aggregation and retention recovery before enabling deletion.
5. Optimize wait storage and implement incremental collector enhancements.
6. Implement transient resource lifecycle and reporting corrections.
7. Implement repository security script.
8. Develop independent Python runner and validate scheduling, timeout and recovery behavior.
9. Develop thresholds, daily reporting and approved email delivery.
10. Execute non-production integration tests, then approved production pilot and staged expansion.

Work may be staged: unvalidated incremental collectors and retention remain disabled for a limited non-production pilot. No production activation until applicable blockers are closed or formally excluded from scope.

## 5. Change control

- Preserve existing module numbers and SQL filenames; use complete replacement files.
- Keep all deployment, production collection, deletion and notification flags disabled by default.
- Do not alter the existing inventory application or existing production monitoring.
- Keep confidential server names, addresses, credentials and production evidence outside public GitHub.
- Update schema versions and documentation when schema changes are made.
- Record source revision, changed files, reviewer and test evidence for each correction.

## 6. Resolution tracking

| Issue | Changed files | Static review | Test evidence | Status |
|---|---|---|---|---|
| CM-001 | TBD | Pending | TBD | OPEN |
| CM-002 | TBD | Pending | TBD | OPEN |
| CM-003 | TBD | Pending | TBD | OPEN |
| CM-004 | TBD | Pending | TBD | OPEN |
| CM-005 | TBD | Pending | TBD | OPEN |
| CM-006 | TBD | Pending | TBD | OPEN |
| CM-007 | TBD | Pending | TBD | OPEN |
| CM-008 | TBD | Pending | TBD | OPEN |
| CM-009 | TBD | Pending | TBD | OPEN |
| CM-010 | TBD | Pending | TBD | OPEN |
| CM-011 | TBD | Pending | TBD | OPEN |
| CM-012 | TBD | Pending | TBD | OPEN |
| CM-013 | TBD | Pending | TBD | OPEN |
| CM-014 | TBD | Pending | TBD | OPEN |
| CM-015 | TBD | Pending | TBD | OPEN |
| CM-016 | TBD | Pending | TBD | OPEN |
| CM-017 | TBD | Pending | TBD | OPEN |
| CM-018 | TBD | Pending | TBD | OPEN |
| CM-019 | TBD | Pending | TBD | OPEN |
| CM-020 | TBD | Pending | TBD | OPEN |
| CM-021 | TBD | Pending | TBD | OPEN |
| CM-022 | TBD | Pending | TBD | OPEN |

Status progression: OPEN → FIX PREPARED → STATIC REVIEWED → TEST PASSED → CLOSED. Preparing a replacement file does not constitute a passed runtime test.

## 7. Deployment gates

- Approved non-production environment and complete metric catalog.
- Successful schema compilation, negative safety tests and transaction failure tests.
- Approved least-privilege security and connection configuration.
- Measured collector overhead and central repository capacity.
- Verified backup/restore and emergency stop procedures.
- Approved pilot scope; automated retention and notifications independently gated.

## 8. References

- [Module 30 README](README.md)
- [Repository Schema](Repository-Schema.md)
- [Validation Checklist](Validation-Checklist.md)
- [Module 26 Data Collection](../26-Data-Collection/)

This register is a targeted static assessment, not an exhaustive SQL audit or production-readiness certification.
