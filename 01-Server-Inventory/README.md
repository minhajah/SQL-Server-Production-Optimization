# Module 01 - SQL Server Inventory & Discovery

## Objective

Collect essential information from existing production
SQL Server instances before performing configuration
changes, performance tuning or maintenance improvements.

This module establishes the initial inventory baseline
and provides input for daily and weekly health reports.

## Scripts

| Script | Description |
|---|---|
| 01-Server-Inventory.sql | SQL Server instance, version, CPU, RAM and uptime |
| 02-Database-Inventory.sql | Database configuration, status and allocated sizes |
| 03-Storage-Inventory.sql | Storage capacity and database file configuration |
| 04-HA-DR-Inventory.sql | Availability Groups, replicas and listeners |
| 05-SQL-Agent-Inventory.sql | Jobs, schedules, execution status and failures |
| 06-Server-Services.sql | SQL Server services and startup configuration |

## Requirements

- Microsoft SQL Server 2016 SP1 or later
- SQL Server Management Studio
- Appropriate server-level DMV permissions
- Access to SQL Agent metadata in msdb

## Execution Order

Execute scripts 01 through 06 in sequence.

## Production Safety

- All assessment scripts are read-only.
- No permanent database objects are created.
- No SQL Server configuration changes are performed.
- No services are restarted.
- No database maintenance operations are initiated.

## Assessment Areas

- SQL Server version and patching level
- CPU and memory allocation
- Database configuration
- Storage capacity
- Database file growth settings
- High availability configuration
- SQL Agent jobs and maintenance
- SQL Server service configuration

## Reporting Integration

The information collected in this module contributes to:

- Server Inventory Report
- Daily SQL Server Health Report
- Weekly SQL Server Health Report
- Database Capacity Report
- Production Improvement Tracker

## Validation Status

- Standalone SQL Server: Verified
- Always On Availability Groups: Pending full validation
- Failover Cluster Instance: Pending validation

## Limitations

- Storage inventory covers database-associated volumes.
- Service inventory covers supported SQL Server services.
- AG runtime visibility depends on the replica role.
- Historical information requires scheduled collection.
- SQL Agent history depends on retention settings.

## Next Module

Module 02 - SQL Server Configuration Assessment
