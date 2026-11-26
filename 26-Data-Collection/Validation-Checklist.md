# Module 26 – Validation Checklist

## Status

Static inspection of snapshot 1345bbb6df9434836601a63ceb8d41f04791b4d2. All 16 files and intended final projections verified. No SQL Server execution, compilation or load test performed. The following findings remain subject to validation. Safety patches have been prepared since that snapshot; verify the final committed revision.

## Review findings

| Priority | Scope | Finding / required action |
|---|---|---|
| High | All | Standardize collection envelope and status mapping; verify all-server visibility and least privilege; prevent partial output from being interpreted as healthy. |
| High | 11 | Reads current XE file only; rollover and service interruption can lose events. Implement durable file/offset checkpoint and deduplication. |
| High | 12 | English error-header parser misses text-only warnings; current file only, overlapping counts. Validate error-log procedure signatures, size guard and runtime timeout; implement incremental event capture. |
| High | 13 | At 1,000 wait types, five rows each at 60 seconds across 25 targets yields about 180 million rows/day; use dedicated baseline/delta processing and bounded retention. |
| High | 16 | Checkpoint can halt after normal retention; high-watermark advancement can miss late-visible history. Add overlap/reconciliation, reset generation and atomic commit; test history purge/restore. |
| High | 05 | Only SQL database-file volumes visible; dedicated backup/error log drives can be missed. Add approved host-level volume collection. |
| High | 06–07 | Local msdb and asymmetric replica visibility require topology correlation; validate PPDM history, GUIDs and expected backup policies. |
| High | 10 | Per-database advanced log-statistics isolation prepared; test inaccessible databases, secondary behavior and overhead. |
| Medium | 03 | Ring-buffer XML and sample age require version checks; stale samples cannot drive alerts. |
| Medium | 04 | Validate counter types, ratio semantics and reset handling. |
| Medium | 05 | File IDs can be reused; map identity generations, verify mount point length handling and allocation accuracy. |
| Medium | 08 | Cached schedules can be stale; verify service detection and activity race cases. |
| Medium | 09, 15 | Different request identity formats require normalization; point-in-time observations miss short incidents; validate high-session overhead. |
| Medium | 14 | Page-number heuristics need validation; coverage count should be reconciled with expected data files. |
| Medium | 15 | Elapsed-first ranking can hide shorter CPU/I/O-heavy requests; completion percentage only valid for supported commands. |
| Medium | 01–02 | Availability means connection succeeded; HAS_DBACCESS is login-specific. Expected offline/restoring/read-only states need policy. |

## Safety patch acceptance

- [ ] Confirm all 16 scripts contain LOCK_TIMEOUT 5000 and DEADLOCK_PRIORITY LOW.
- [ ] Test lock timeout, deadlock victim behavior and connection setting isolation.
- [ ] Test collector 10 with one inaccessible database and verify healthy database output.
- [ ] Confirm COL-11, COL-12 and COL-16 remain disabled until incremental acceptance tests pass.

## Pre-production checklist

- [ ] Compile and execute every collector on an approved SQL Server 2019 test instance.
- [ ] Validate 2017/2022 compatibility and feature gates where applicable.
- [ ] Compare metrics with SSMS and independent known-good observations.
- [ ] Validate one final result set, types, keys, nulls, statuses and failure paths.
- [ ] Test restricted permissions and metadata visibility; no blanket sysadmin grant.
- [ ] Test standalone, named instance, AG primary/secondary, FCI and SQL Agent disabled/unavailable.
- [ ] Test unavailable databases, snapshots, restart, counter reset, file reuse and timezone conversion.
- [ ] Test PPDM backup history and AG-wide policy, restore evidence separately.
- [ ] Test XE rollover and error-log size limit, event gaps, parsing, history purge and concurrent inserts.
- [ ] Measure CPU, logical reads, duration, network and tempdb overhead under representative load.
- [ ] Test bounded concurrency, timeout, retry, backoff, no overlapping target runs and cancellation.
- [ ] Test central persistence, checkpoint atomicity, deduplication, retention and recovery after interruption.
- [ ] Test alert lifecycle: new, ongoing, recovered, unknown, approved exception, maintenance suppression.
- [ ] Review credentials, encryption, access, audit, data sanitization and storage sizing.
- [ ] Obtain approval for a single production pilot; preserve current monitoring and rollback by stopping external polling.
- [ ] Record pilot evidence and obtain rollout approval before expanding to other targets.

## Sign-off

All items remain pending except static file/projection verification. No production deployment is authorized by this document.
