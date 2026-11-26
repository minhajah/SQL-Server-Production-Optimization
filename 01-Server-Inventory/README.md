# Module 01 - SQL Server Inventory & Discovery

## Objective

Establish an inventory baseline for existing production
SQL Server instances and provide the foundation for
automated daily and weekly health reporting.

## Scripts

| Script | Description |
|---|---|
| 01-Server-Inventory.sql | Instance, version, CPU, RAM and uptime |
| 02-Database-Inventory.sql | Database configuration and allocated sizes |
| 03-Storage-Inventory.sql | Disk capacity and database file configuration |
| 04-HA-DR-Inventory.sql | Availability Groups, replicas and listeners |
| 05-SQL-Agent-Inventory.sql | Jobs, schedules and execution history |
| 06-Server-Services.sql | SQL Server services and startup configuration |
| 07-Consolidated-Inventory-Report.sql | Single-row inventory summary |
| 08-HTML-Inventory-Report.sql | Formatted HTML inventory report |

## Requirements

- SQL Server 2016 SP1 or later
- SQL Server Management Studio
- Appropriate DMV permissions
- Access to SQL Agent metadata in msdb

## Execution Order

Execute scripts 01 through 08 sequentially.

Scripts 01 through 06 provide detailed inventory.
Script 07 provides a consolidated summary.
Script 08 generates a formatted HTML report.

## Production Safety

- Classification: Read-only, low expected impact
- Permanent database objects: None
- Configuration changes: None
- Service restarts: None
- Email delivery: None
- Maintenance window: Normally not required
- Rollback: Not applicable

Review resource usage during initial execution.

## Reporting Integration

The HTML inventory report includes:

1. Server information
2. Database information
3. Storage information
4. High availability configuration
5. SQL Agent information
6. SQL Server services

## How to View the HTML Report

1. Execute 08-HTML-Inventory-Report.sql in SSMS.
2. Copy the complete HTMLReport output.
3. Save the content as an HTML file using UTF-8.
4. Open the file in a web browser.

## Revision and compatibility notes

Script 05 replacement improves failed-step diagnostics and integer date/time filtering. Retest job-history correlation and performance; prior standalone results do not cover the revised script.

## Validation Status

| Environment | Status |
|---|---|
| Standalone SQL Server | Verified |
| Always On Availability Groups | Pending validation |
| Failover Cluster Instance | Pending validation |
| Consolidated Inventory Report | Verified |
| HTML Report Generation | Verified |
| Automated Email Delivery | Planned |

## Limitations

- Storage inventory covers database-associated volumes.
- Service inventory does not cover all Windows services.
- AG health assessment requires further validation.
- SQL Agent history depends on retention and permissions.
- Historical performance collection is not yet implemented.
- Inventory status does not represent complete server health.
- HTML email client compatibility requires validation.

## Module Status

Completed for standalone pilot implementation.

## Next Module

Module 02 - SQL Server Configuration Assessment
