/*
    005_create_business_key_indexes.sql

    Unique indexes that enforce each production table's business key at the
    database level, in addition to the checks in the publish procedures.

    Tables loaded by the old append-only pipeline may already contain
    duplicates (for example cases_and_deaths after a rerun). In that case this
    script does not fail. It prints a notice and skips the index. Run the new
    pipeline once, which replaces the table with a clean validated snapshot,
    then run this script again.

    Unique indexes treat NULLs as equal, which matches the GROUP BY used by
    validation.
*/
SET NOCOUNT ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE object_id = OBJECT_ID(N'covid_reporting.cases_and_deaths')
                 AND name = N'ux_cases_and_deaths_business_key')
BEGIN
    IF EXISTS (SELECT 1 FROM covid_reporting.cases_and_deaths
               GROUP BY country, reported_date, source HAVING COUNT_BIG(*) > 1)
        PRINT N'SKIPPED ux_cases_and_deaths_business_key: existing duplicates. Publish a clean snapshot, then rerun 005.';
    ELSE
        CREATE UNIQUE NONCLUSTERED INDEX ux_cases_and_deaths_business_key
            ON covid_reporting.cases_and_deaths (country, reported_date, source);
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE object_id = OBJECT_ID(N'covid_reporting.hospital_admissions_daily')
                 AND name = N'ux_hospital_admissions_daily_business_key')
BEGIN
    IF EXISTS (SELECT 1 FROM covid_reporting.hospital_admissions_daily
               GROUP BY country, reported_date, source HAVING COUNT_BIG(*) > 1)
        PRINT N'SKIPPED ux_hospital_admissions_daily_business_key: existing duplicates. Publish a clean snapshot, then rerun 005.';
    ELSE
        CREATE UNIQUE NONCLUSTERED INDEX ux_hospital_admissions_daily_business_key
            ON covid_reporting.hospital_admissions_daily (country, reported_date, source);
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE object_id = OBJECT_ID(N'covid_reporting.testing')
                 AND name = N'ux_testing_business_key')
BEGIN
    IF EXISTS (SELECT 1 FROM covid_reporting.testing
               GROUP BY country, year_week, testing_data_source HAVING COUNT_BIG(*) > 1)
        PRINT N'SKIPPED ux_testing_business_key: existing duplicates. Publish a clean snapshot, then rerun 005.';
    ELSE
        CREATE UNIQUE NONCLUSTERED INDEX ux_testing_business_key
            ON covid_reporting.testing (country, year_week, testing_data_source);
END;
GO
