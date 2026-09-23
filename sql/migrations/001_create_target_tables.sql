/*
    001_create_target_tables.sql

    Production (published) tables read by reporting.
    Idempotent: each object is created only if it does not already exist, so the
    script is safe to run against a database where the tables were created by hand.

    If your existing tables use different column lengths, align the staging
    tables in 002 with them. Publication inserts from staging into these tables,
    so an incompatible type fails the publish transaction and rolls it back.
    Existing data is never changed.

    Business keys (enforced by validation and, after the first clean publish,
    by the unique indexes in 005):
      cases_and_deaths           (country, reported_date, source)
      hospital_admissions_daily  (country, reported_date, source)
      testing                    (country, year_week, testing_data_source)
*/
SET NOCOUNT ON;
GO

-- CREATE SCHEMA must be the only statement in its batch, so it is run through
-- EXEC with a constant string. No user input is involved.
IF SCHEMA_ID(N'covid_reporting') IS NULL
    EXEC (N'CREATE SCHEMA covid_reporting AUTHORIZATION dbo;');
GO

IF OBJECT_ID(N'covid_reporting.cases_and_deaths', N'U') IS NULL
BEGIN
    CREATE TABLE covid_reporting.cases_and_deaths
    (
        country              varchar(100) NOT NULL,
        country_code_2_digit varchar(2)   NULL,
        country_code_3_digit varchar(3)   NULL,
        population           bigint       NULL,
        cases_count          bigint       NULL,
        deaths_count         bigint       NULL,
        reported_date        date         NOT NULL,
        source               varchar(500) NULL
    );
END;
GO

IF OBJECT_ID(N'covid_reporting.hospital_admissions_daily', N'U') IS NULL
BEGIN
    CREATE TABLE covid_reporting.hospital_admissions_daily
    (
        country                  varchar(100) NOT NULL,
        country_code_2_digit     varchar(2)   NULL,
        country_code_3_digit     varchar(3)   NULL,
        population               bigint       NULL,
        reported_date            date         NOT NULL,
        hospital_occupancy_count bigint       NULL,
        icu_occupancy_count      bigint       NULL,
        source                   varchar(500) NULL
    );
END;
GO

IF OBJECT_ID(N'covid_reporting.testing', N'U') IS NULL
BEGIN
    CREATE TABLE covid_reporting.testing
    (
        country              varchar(100) NOT NULL,
        country_code_2_digit varchar(2)   NULL,
        country_code_3_digit varchar(3)   NULL,
        year_week            varchar(8)   NOT NULL,
        week_start_date      date         NULL,
        week_end_date        date         NULL,
        new_cases            bigint       NULL,
        tests_done           bigint       NULL,
        population           bigint       NULL,
        testing_data_source  varchar(500) NULL
    );
END;
GO
