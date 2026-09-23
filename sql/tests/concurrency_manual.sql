/*
    concurrency_manual.sql

    Manual two-session check that publication is serialized by sp_getapplock.
    Use a disposable test database with sql/migrations/001-004 applied.

    Session A (hold the publication lock for cases_and_deaths):

        BEGIN TRANSACTION;
        EXEC sys.sp_getapplock @Resource = N'covid_etl.publish.cases_and_deaths',
                               @LockMode = 'Exclusive', @LockOwner = 'Transaction';
        -- leave this transaction open

    Session B (try to publish a validated run while A holds the lock):
*/
DECLARE @run uniqueidentifier = NEWID();
DECLARE @before bigint = (SELECT COUNT_BIG(*) FROM covid_reporting.cases_and_deaths);

EXEC covid_etl.usp_begin_load N'cases_and_deaths', @run, N'concurrency_manual';
INSERT INTO covid_staging.cases_and_deaths
    (load_run_id, country, country_code_2_digit, country_code_3_digit, population, cases_count, deaths_count, reported_date, source)
VALUES (@run, 'Lockland', 'LL', 'LLD', 1, 1, 0, '2023-01-01', 'Concurrency test');
EXEC covid_etl.usp_validate_cases_and_deaths @pipeline_run_id = @run, @expected_row_count = 1;

BEGIN TRY
    EXEC covid_etl.usp_publish_cases_and_deaths @pipeline_run_id = @run;   -- waits up to 60 s
    PRINT N'Published (Session A was not holding the lock).';
END TRY
BEGIN CATCH
    PRINT CONCAT(N'Expected while A holds the lock: error ', ERROR_NUMBER(), N' - ', ERROR_MESSAGE());
END CATCH;

SELECT @before AS rows_before,
       (SELECT COUNT_BIG(*) FROM covid_reporting.cases_and_deaths) AS rows_after,   -- equal on error 50016
       status, error_summary
FROM covid_etl.load_audit WHERE pipeline_run_id = @run;

/*
    Expected: after about 60 seconds Session B fails with error 50016,
    rows_after = rows_before, and the audit row stays 'Validated' with the error
    recorded. Then ROLLBACK in Session A and rerun the EXEC in Session B. It
    publishes, because the run is still Validated and its staged rows were kept
    for retry.
*/
