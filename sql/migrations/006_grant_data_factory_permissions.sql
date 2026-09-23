/*
    006_grant_data_factory_permissions.sql

    Least-privilege access for the Data Factory system-assigned managed identity.
    Run as the server's Microsoft Entra administrator, in sqlcmd mode:

        sqlcmd -S <sql-server-name>.database.windows.net -d <sql-database-name> -G \
               -v DataFactoryName="<data-factory-name>" \
               -i sql/migrations/006_grant_data_factory_permissions.sql

    (In SSMS or Azure Data Studio, enable SQLCMD mode and edit the :setvar line.)

    What the identity can do:
      * EXECUTE the covid_etl procedures (begin, validate, publish, fail).
      * INSERT and SELECT on the three covid_staging tables: the copy activity
        bulk-inserts there and reads the table metadata.
    What it cannot do:
      * Read or modify covid_reporting tables directly. The publish procedures
        change them through ownership chaining: procedures and tables are all
        owned by dbo, so EXECUTE is the only permission needed.
      * DELETE or UPDATE staging rows directly, modify the audit table, or
        run DDL. No db_owner, db_ddladmin, db_datawriter, or ALTER.
*/
:on error exit
:setvar DataFactoryName "<data-factory-name>"
SET NOCOUNT ON;
GO

IF N'$(DataFactoryName)' = N'<data-factory-name>'
    THROW 50090, N'Set the DataFactoryName sqlcmd variable to your factory name before running this script.', 1;
GO

-- Ownership chaining requires a single owner for all three schemas.
IF EXISTS (SELECT 1 FROM sys.schemas
           WHERE name IN (N'covid_reporting', N'covid_staging', N'covid_etl')
             AND principal_id <> DATABASE_PRINCIPAL_ID(N'dbo'))
    THROW 50091, N'covid_reporting, covid_staging and covid_etl must all be owned by dbo for ownership chaining.', 1;
GO

IF DATABASE_PRINCIPAL_ID(N'$(DataFactoryName)') IS NULL
    CREATE USER [$(DataFactoryName)] FROM EXTERNAL PROVIDER;
GO

GRANT EXECUTE ON SCHEMA::covid_etl TO [$(DataFactoryName)];

GRANT SELECT, INSERT ON OBJECT::covid_staging.cases_and_deaths          TO [$(DataFactoryName)];
GRANT SELECT, INSERT ON OBJECT::covid_staging.hospital_admissions_daily TO [$(DataFactoryName)];
GRANT SELECT, INSERT ON OBJECT::covid_staging.testing                   TO [$(DataFactoryName)];
GO

-- Remove grants from the previous direct truncate-and-copy design, if present.
REVOKE SELECT, INSERT, ALTER ON OBJECT::covid_reporting.cases_and_deaths          FROM [$(DataFactoryName)];
REVOKE SELECT, INSERT, ALTER ON OBJECT::covid_reporting.hospital_admissions_daily FROM [$(DataFactoryName)];
REVOKE SELECT, INSERT, ALTER ON OBJECT::covid_reporting.testing                   FROM [$(DataFactoryName)];
GO

-- Show the resulting grants for review.
SELECT pr.name AS principal_name, pe.permission_name, pe.state_desc, pe.class_desc,
       CASE pe.class_desc
           WHEN N'SCHEMA' THEN SCHEMA_NAME(pe.major_id)
           WHEN N'OBJECT_OR_COLUMN' THEN CONCAT(OBJECT_SCHEMA_NAME(pe.major_id), N'.', OBJECT_NAME(pe.major_id))
           ELSE N'(database)'
       END AS securable
FROM sys.database_permissions AS pe
JOIN sys.database_principals AS pr ON pr.principal_id = pe.grantee_principal_id
WHERE pr.name = N'$(DataFactoryName)'
ORDER BY pe.class_desc, securable, pe.permission_name;
GO
