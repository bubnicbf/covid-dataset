/*
    002_create_staging_tables.sql

    Run-scoped staging tables. ADF copies each processed snapshot here, never
    into the production tables. Every row carries the ADF pipeline run ID
    (load_run_id), so a retry or an overlapping run can only see and clear its
    own rows.

    Business columns are nullable on purpose. Bad input should land in staging
    and be reported by validation, not fail the bulk copy with an opaque error.
    Column types match the production tables in 001.
*/
SET NOCOUNT ON;
GO

IF SCHEMA_ID(N'covid_staging') IS NULL
    EXEC (N'CREATE SCHEMA covid_staging AUTHORIZATION dbo;');
GO

IF OBJECT_ID(N'covid_staging.cases_and_deaths', N'U') IS NULL
BEGIN
    CREATE TABLE covid_staging.cases_and_deaths
    (
        load_run_id          uniqueidentifier NOT NULL,
        country              varchar(100)     NULL,
        country_code_2_digit varchar(2)       NULL,
        country_code_3_digit varchar(3)       NULL,
        population           bigint           NULL,
        cases_count          bigint           NULL,
        deaths_count         bigint           NULL,
        reported_date        date             NULL,
        source               varchar(500)     NULL,
        staged_at_utc        datetime2(3)     NOT NULL
            CONSTRAINT df_stg_cases_and_deaths_staged_at DEFAULT (SYSUTCDATETIME())
    );
    CREATE CLUSTERED INDEX cx_stg_cases_and_deaths_run
        ON covid_staging.cases_and_deaths (load_run_id);
END;
GO

IF OBJECT_ID(N'covid_staging.hospital_admissions_daily', N'U') IS NULL
BEGIN
    CREATE TABLE covid_staging.hospital_admissions_daily
    (
        load_run_id              uniqueidentifier NOT NULL,
        country                  varchar(100)     NULL,
        country_code_2_digit     varchar(2)       NULL,
        country_code_3_digit     varchar(3)       NULL,
        population               bigint           NULL,
        reported_date            date             NULL,
        hospital_occupancy_count bigint           NULL,
        icu_occupancy_count      bigint           NULL,
        source                   varchar(500)     NULL,
        staged_at_utc            datetime2(3)     NOT NULL
            CONSTRAINT df_stg_hospital_admissions_daily_staged_at DEFAULT (SYSUTCDATETIME())
    );
    CREATE CLUSTERED INDEX cx_stg_hospital_admissions_daily_run
        ON covid_staging.hospital_admissions_daily (load_run_id);
END;
GO

IF OBJECT_ID(N'covid_staging.testing', N'U') IS NULL
BEGIN
    CREATE TABLE covid_staging.testing
    (
        load_run_id          uniqueidentifier NOT NULL,
        country              varchar(100)     NULL,
        country_code_2_digit varchar(2)       NULL,
        country_code_3_digit varchar(3)       NULL,
        year_week            varchar(8)       NULL,
        week_start_date      date             NULL,
        week_end_date        date             NULL,
        new_cases            bigint           NULL,
        tests_done           bigint           NULL,
        population           bigint           NULL,
        testing_data_source  varchar(500)     NULL,
        staged_at_utc        datetime2(3)     NOT NULL
            CONSTRAINT df_stg_testing_staged_at DEFAULT (SYSUTCDATETIME())
    );
    CREATE CLUSTERED INDEX cx_stg_testing_run
        ON covid_staging.testing (load_run_id);
END;
GO
