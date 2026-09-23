/*
    idempotency_checks.sql

    Executable checks for the staging -> validation -> transactional publish
    design. These tests REPLACE the contents of the covid_reporting tables with
    fixture data. Run them only against a disposable database whose name
    contains "test" or "dev", after applying sql/migrations/001-005:

        sqlcmd -S <server> -d <test-database> -G -b -i sql/tests/idempotency_checks.sql

    The script calls the procedures directly, simulating the ADF copy activity
    by inserting into covid_staging. It prints one row per check and fails
    with error 50999 if any check fails.

    Coverage:
      T1  rerunning the same snapshot yields identical row count and checksum
      T2  an ADF retry of publish for an already-published run is a no-op
      T3  no duplicate business keys are introduced
      T4  duplicate staged keys are rejected; production unchanged
      T5  a failed or partial staging load is rejected; production unchanged
      T6  a failed publication transaction rolls back completely
      T7  an empty stage is rejected; production unchanged
      T8  an older overlapping run cannot overwrite a newer published snapshot
      T9  production and staging column definitions match (mapping check)
      T10 hospital_admissions_daily and testing are idempotent too
      T11 unknown target names are rejected (no dynamic SQL path)
    Two-session lock contention is covered by concurrency_manual.sql.
*/
:on error exit
SET NOCOUNT ON;
GO

IF DB_NAME() NOT LIKE N'%test%' AND DB_NAME() NOT LIKE N'%dev%'
    THROW 50900, N'Refusing to run: these tests replace production-table contents. Use a database whose name contains "test" or "dev".', 1;
GO

IF OBJECT_ID(N'tempdb..#results') IS NOT NULL DROP TABLE #results;
CREATE TABLE #results (test_id varchar(10) NOT NULL, description nvarchar(200) NOT NULL, passed bit NOT NULL, detail nvarchar(400) NULL);
GO

DECLARE @fixture TABLE (country varchar(100), cc2 varchar(2), cc3 varchar(3), population bigint,
                        cases_count bigint, deaths_count bigint, reported_date date, source varchar(500));
INSERT INTO @fixture VALUES
    ('Testland',  'TL', 'TLD', 1000, 10, 1, '2021-01-01', 'Fixture source'),
    ('Testland',  'TL', 'TLD', 1000, 12, 0, '2021-01-02', 'Fixture source'),
    ('Otherland', 'OL', 'OLD', 2000,  5, 2, '2021-01-01', 'Fixture source');

DECLARE @fixture_b TABLE (country varchar(100), cc2 varchar(2), cc3 varchar(3), population bigint,
                          cases_count bigint, deaths_count bigint, reported_date date, source varchar(500));
INSERT INTO @fixture_b VALUES
    ('Newland', 'NL', 'NLD', 500, 1, 0, '2022-02-01', 'Fixture source B'),
    ('Newland', 'NL', 'NLD', 500, 3, 1, '2022-02-02', 'Fixture source B');

DECLARE @r1 uniqueidentifier = NEWID(), @r2 uniqueidentifier = NEWID(), @r3 uniqueidentifier = NEWID(),
        @r4 uniqueidentifier = NEWID(), @r5 uniqueidentifier = NEWID(), @r6 uniqueidentifier = NEWID(),
        @r_old uniqueidentifier = NEWID(), @r_new uniqueidentifier = NEWID();
DECLARE @cnt_base bigint, @chk_base int, @cnt bigint, @chk int, @err int, @status varchar(20),
        @stage_rows bigint, @summary nvarchar(400);

/* ---------- T1: publish the same snapshot twice ---------- */
EXEC covid_etl.usp_begin_load N'cases_and_deaths', @r1, N'idempotency_checks';
INSERT INTO covid_staging.cases_and_deaths
    (load_run_id, country, country_code_2_digit, country_code_3_digit, population, cases_count, deaths_count, reported_date, source)
SELECT @r1, country, cc2, cc3, population, cases_count, deaths_count, reported_date, source FROM @fixture;
EXEC covid_etl.usp_validate_cases_and_deaths @pipeline_run_id = @r1, @expected_row_count = 3;
EXEC covid_etl.usp_publish_cases_and_deaths @pipeline_run_id = @r1;

SELECT @cnt_base = COUNT_BIG(*),
       @chk_base = CHECKSUM_AGG(BINARY_CHECKSUM(country, country_code_2_digit, country_code_3_digit, population,
                                                cases_count, deaths_count, reported_date, source))
FROM covid_reporting.cases_and_deaths;

EXEC covid_etl.usp_begin_load N'cases_and_deaths', @r2, N'idempotency_checks';
INSERT INTO covid_staging.cases_and_deaths
    (load_run_id, country, country_code_2_digit, country_code_3_digit, population, cases_count, deaths_count, reported_date, source)
SELECT @r2, country, cc2, cc3, population, cases_count, deaths_count, reported_date, source FROM @fixture;
EXEC covid_etl.usp_validate_cases_and_deaths @pipeline_run_id = @r2, @expected_row_count = 3;
EXEC covid_etl.usp_publish_cases_and_deaths @pipeline_run_id = @r2;

SELECT @cnt = COUNT_BIG(*),
       @chk = CHECKSUM_AGG(BINARY_CHECKSUM(country, country_code_2_digit, country_code_3_digit, population,
                                           cases_count, deaths_count, reported_date, source))
FROM covid_reporting.cases_and_deaths;
SELECT @stage_rows = COUNT_BIG(*) FROM covid_staging.cases_and_deaths WHERE load_run_id IN (@r1, @r2);

INSERT INTO #results VALUES ('T1', N'Rerunning the same snapshot yields the same count and checksum; staging cleaned',
    CASE WHEN @cnt_base = 3 AND @cnt = @cnt_base AND @chk = @chk_base AND @stage_rows = 0 THEN 1 ELSE 0 END,
    CONCAT(N'first=', @cnt_base, N'/', @chk_base, N' second=', @cnt, N'/', @chk, N' leftover_stage=', @stage_rows));

/* ---------- T2: ADF retry of publish after commit ---------- */
SET @err = NULL;
BEGIN TRY EXEC covid_etl.usp_publish_cases_and_deaths @pipeline_run_id = @r2; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
SELECT @cnt = COUNT_BIG(*),
       @chk = CHECKSUM_AGG(BINARY_CHECKSUM(country, country_code_2_digit, country_code_3_digit, population,
                                           cases_count, deaths_count, reported_date, source))
FROM covid_reporting.cases_and_deaths;
SELECT @status = status FROM covid_etl.load_audit WHERE pipeline_run_id = @r2 AND target_table = N'cases_and_deaths';
INSERT INTO #results VALUES ('T2', N'Retrying publish for a completed run is a no-op',
    CASE WHEN @err IS NULL AND @cnt = @cnt_base AND @chk = @chk_base AND @status = 'Succeeded' THEN 1 ELSE 0 END,
    CONCAT(N'error=', @err, N' status=', @status));

/* ---------- T3: no duplicate business keys in production ---------- */
SELECT @cnt = COUNT_BIG(*) FROM (SELECT 1 AS k FROM covid_reporting.cases_and_deaths
                                 GROUP BY country, reported_date, source HAVING COUNT_BIG(*) > 1) AS d;
INSERT INTO #results VALUES ('T3', N'No duplicate business keys after repeated loads',
    CASE WHEN @cnt = 0 THEN 1 ELSE 0 END, CONCAT(N'duplicate_keys=', @cnt));

/* ---------- T4: duplicate staged keys are rejected ---------- */
EXEC covid_etl.usp_begin_load N'cases_and_deaths', @r3, N'idempotency_checks';
INSERT INTO covid_staging.cases_and_deaths
    (load_run_id, country, country_code_2_digit, country_code_3_digit, population, cases_count, deaths_count, reported_date, source)
SELECT @r3, country, cc2, cc3, population, cases_count, deaths_count, reported_date, source FROM @fixture
UNION ALL
SELECT TOP (1) @r3, country, cc2, cc3, population, cases_count + 1, deaths_count, reported_date, source FROM @fixture;
SET @err = NULL;
BEGIN TRY EXEC covid_etl.usp_validate_cases_and_deaths @pipeline_run_id = @r3, @expected_row_count = 4; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
DECLARE @err_publish int = NULL;
BEGIN TRY EXEC covid_etl.usp_publish_cases_and_deaths @pipeline_run_id = @r3; END TRY
BEGIN CATCH SET @err_publish = ERROR_NUMBER(); END CATCH;
EXEC covid_etl.usp_record_load_failure N'cases_and_deaths', @r3, N'test: simulated ADF failure path';
SELECT @cnt = COUNT_BIG(*),
       @chk = CHECKSUM_AGG(BINARY_CHECKSUM(country, country_code_2_digit, country_code_3_digit, population,
                                           cases_count, deaths_count, reported_date, source))
FROM covid_reporting.cases_and_deaths;
SELECT @status = status, @summary = error_summary FROM covid_etl.load_audit WHERE pipeline_run_id = @r3 AND target_table = N'cases_and_deaths';
SELECT @stage_rows = COUNT_BIG(*) FROM covid_staging.cases_and_deaths WHERE load_run_id = @r3;
INSERT INTO #results VALUES ('T4', N'Duplicate staged keys rejected; publish refused; production unchanged; stage cleared',
    CASE WHEN @err = 50022 AND @err_publish = 50011 AND @cnt = @cnt_base AND @chk = @chk_base
              AND @status = 'Failed' AND @summary LIKE N'%duplicated%' AND @stage_rows = 0 THEN 1 ELSE 0 END,
    CONCAT(N'validate_error=', @err, N' publish_error=', @err_publish, N' status=', @status, N' summary=', @summary));

/* ---------- T5: partial staging load (copy failed midway) ---------- */
EXEC covid_etl.usp_begin_load N'cases_and_deaths', @r4, N'idempotency_checks';
INSERT INTO covid_staging.cases_and_deaths
    (load_run_id, country, country_code_2_digit, country_code_3_digit, population, cases_count, deaths_count, reported_date, source)
SELECT TOP (1) @r4, country, cc2, cc3, population, cases_count, deaths_count, reported_date, source FROM @fixture;
SET @err = NULL;
BEGIN TRY EXEC covid_etl.usp_validate_cases_and_deaths @pipeline_run_id = @r4, @expected_row_count = 3; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
EXEC covid_etl.usp_record_load_failure N'cases_and_deaths', @r4, N'test: copy activity failed';
SELECT @cnt = COUNT_BIG(*),
       @chk = CHECKSUM_AGG(BINARY_CHECKSUM(country, country_code_2_digit, country_code_3_digit, population,
                                           cases_count, deaths_count, reported_date, source))
FROM covid_reporting.cases_and_deaths;
SELECT @stage_rows = COUNT_BIG(*) FROM covid_staging.cases_and_deaths WHERE load_run_id = @r4;
INSERT INTO #results VALUES ('T5', N'Partial staging load rejected (count mismatch); production unchanged',
    CASE WHEN @err = 50022 AND @cnt = @cnt_base AND @chk = @chk_base AND @stage_rows = 0 THEN 1 ELSE 0 END,
    CONCAT(N'validate_error=', @err, N' prod_count=', @cnt));

/* ---------- T6: publication fails mid-transaction and rolls back ---------- */
-- Fault injection: a CHECK constraint (not applied to existing rows) makes the
-- INSERT fail after the production DELETE has already run inside the transaction.
ALTER TABLE covid_reporting.cases_and_deaths WITH NOCHECK
    ADD CONSTRAINT ck_test_fault_injection CHECK (country <> 'ZZ_FAULT_INJECTION');

EXEC covid_etl.usp_begin_load N'cases_and_deaths', @r5, N'idempotency_checks';
INSERT INTO covid_staging.cases_and_deaths
    (load_run_id, country, country_code_2_digit, country_code_3_digit, population, cases_count, deaths_count, reported_date, source)
SELECT @r5, country, cc2, cc3, population, cases_count, deaths_count, reported_date, source FROM @fixture_b
UNION ALL
SELECT @r5, 'ZZ_FAULT_INJECTION', 'ZZ', 'ZZZ', 1, 1, 1, '2022-02-03', 'Fixture source B';
EXEC covid_etl.usp_validate_cases_and_deaths @pipeline_run_id = @r5, @expected_row_count = 3;
SET @err = NULL;
BEGIN TRY EXEC covid_etl.usp_publish_cases_and_deaths @pipeline_run_id = @r5; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;

ALTER TABLE covid_reporting.cases_and_deaths DROP CONSTRAINT ck_test_fault_injection;

SELECT @cnt = COUNT_BIG(*),
       @chk = CHECKSUM_AGG(BINARY_CHECKSUM(country, country_code_2_digit, country_code_3_digit, population,
                                           cases_count, deaths_count, reported_date, source))
FROM covid_reporting.cases_and_deaths;
SELECT @status = status, @summary = error_summary FROM covid_etl.load_audit WHERE pipeline_run_id = @r5 AND target_table = N'cases_and_deaths';
SELECT @stage_rows = COUNT_BIG(*) FROM covid_staging.cases_and_deaths WHERE load_run_id = @r5;
INSERT INTO #results VALUES ('T6', N'Failed publish rolls back fully; previous snapshot intact; stage kept for retry',
    CASE WHEN @err = 547 AND @cnt = @cnt_base AND @chk = @chk_base AND @status = 'Validated'
              AND @summary LIKE N'Publish failed (error 547)%' AND @stage_rows = 3 THEN 1 ELSE 0 END,
    CONCAT(N'publish_error=', @err, N' status=', @status, N' stage_rows=', @stage_rows));
EXEC covid_etl.usp_record_load_failure N'cases_and_deaths', @r5, N'test: retries exhausted';

/* ---------- T7: empty stage is rejected ---------- */
EXEC covid_etl.usp_begin_load N'cases_and_deaths', @r6, N'idempotency_checks';
SET @err = NULL;
BEGIN TRY EXEC covid_etl.usp_validate_cases_and_deaths @pipeline_run_id = @r6, @expected_row_count = 0; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
SET @err_publish = NULL;
BEGIN TRY EXEC covid_etl.usp_publish_cases_and_deaths @pipeline_run_id = @r6; END TRY
BEGIN CATCH SET @err_publish = ERROR_NUMBER(); END CATCH;
EXEC covid_etl.usp_record_load_failure N'cases_and_deaths', @r6, N'test: empty snapshot';
SELECT @cnt = COUNT_BIG(*) FROM covid_reporting.cases_and_deaths;
INSERT INTO #results VALUES ('T7', N'Empty staged snapshot rejected; production unchanged',
    CASE WHEN @err = 50022 AND @err_publish = 50011 AND @cnt = @cnt_base THEN 1 ELSE 0 END,
    CONCAT(N'validate_error=', @err, N' publish_error=', @err_publish, N' prod_count=', @cnt));

/* ---------- T8: overlapping runs, where the older run publishes last ---------- */
EXEC covid_etl.usp_begin_load N'cases_and_deaths', @r_old, N'idempotency_checks';
EXEC covid_etl.usp_begin_load N'cases_and_deaths', @r_new, N'idempotency_checks';
INSERT INTO covid_staging.cases_and_deaths
    (load_run_id, country, country_code_2_digit, country_code_3_digit, population, cases_count, deaths_count, reported_date, source)
SELECT @r_old, country, cc2, cc3, population, cases_count, deaths_count, reported_date, source FROM @fixture;
INSERT INTO covid_staging.cases_and_deaths
    (load_run_id, country, country_code_2_digit, country_code_3_digit, population, cases_count, deaths_count, reported_date, source)
SELECT @r_new, country, cc2, cc3, population, cases_count, deaths_count, reported_date, source FROM @fixture_b;
EXEC covid_etl.usp_validate_cases_and_deaths @pipeline_run_id = @r_old, @expected_row_count = 3;
EXEC covid_etl.usp_validate_cases_and_deaths @pipeline_run_id = @r_new, @expected_row_count = 2;
EXEC covid_etl.usp_publish_cases_and_deaths @pipeline_run_id = @r_new;
EXEC covid_etl.usp_publish_cases_and_deaths @pipeline_run_id = @r_old;

SELECT @cnt = COUNT_BIG(*) FROM covid_reporting.cases_and_deaths;
DECLARE @only_new bit = CASE WHEN NOT EXISTS (SELECT 1 FROM covid_reporting.cases_and_deaths WHERE country <> 'Newland') THEN 1 ELSE 0 END;
SELECT @status = status FROM covid_etl.load_audit WHERE pipeline_run_id = @r_old AND target_table = N'cases_and_deaths';
SELECT @stage_rows = COUNT_BIG(*) FROM covid_staging.cases_and_deaths WHERE load_run_id IN (@r_old, @r_new);
INSERT INTO #results VALUES ('T8', N'Older overlapping run is superseded and cannot overwrite the newer snapshot',
    CASE WHEN @cnt = 2 AND @only_new = 1 AND @status = 'Superseded' AND @stage_rows = 0 THEN 1 ELSE 0 END,
    CONCAT(N'prod_count=', @cnt, N' old_run_status=', @status));

/* ---------- T9: staging vs production column definitions ---------- */
SELECT @cnt = COUNT(*)
FROM (VALUES (N'cases_and_deaths'), (N'hospital_admissions_daily'), (N'testing')) AS t (name)
INNER JOIN sys.columns AS p ON p.object_id = OBJECT_ID(N'covid_reporting.' + t.name)
WHERE NOT EXISTS (SELECT 1 FROM sys.columns AS s
                  WHERE s.object_id = OBJECT_ID(N'covid_staging.' + t.name)
                    AND s.name = p.name AND s.system_type_id = p.system_type_id
                    AND s.max_length = p.max_length AND s.[precision] = p.[precision] AND s.scale = p.scale);
INSERT INTO #results VALUES ('T9', N'Every production column exists in staging with the same type',
    CASE WHEN @cnt = 0 THEN 1 ELSE 0 END, CONCAT(N'mismatched_columns=', @cnt));
GO

/* ---------- T10: other targets follow the same pattern ---------- */
DECLARE @i int = 1, @run uniqueidentifier, @cnt bigint, @chk int, @cnt_first bigint, @chk_first int;
WHILE @i <= 2
BEGIN
    SET @run = NEWID();
    EXEC covid_etl.usp_begin_load N'hospital_admissions_daily', @run, N'idempotency_checks';
    INSERT INTO covid_staging.hospital_admissions_daily
        (load_run_id, country, country_code_2_digit, country_code_3_digit, population, reported_date,
         hospital_occupancy_count, icu_occupancy_count, source)
    VALUES (@run, 'Testland', 'TL', 'TLD', 1000, '2021-03-01', 40, 4, 'Fixture source'),
           (@run, 'Testland', 'TL', 'TLD', 1000, '2021-03-02', 42, 5, 'Fixture source');
    EXEC covid_etl.usp_validate_hospital_admissions_daily @pipeline_run_id = @run, @expected_row_count = 2;
    EXEC covid_etl.usp_publish_hospital_admissions_daily @pipeline_run_id = @run;
    SELECT @cnt = COUNT_BIG(*),
           @chk = CHECKSUM_AGG(BINARY_CHECKSUM(country, country_code_2_digit, country_code_3_digit, population,
                                               reported_date, hospital_occupancy_count, icu_occupancy_count, source))
    FROM covid_reporting.hospital_admissions_daily;
    IF @i = 1 SELECT @cnt_first = @cnt, @chk_first = @chk;
    SET @i += 1;
END;
INSERT INTO #results VALUES ('T10a', N'hospital_admissions_daily: repeated load is idempotent',
    CASE WHEN @cnt = 2 AND @cnt = @cnt_first AND @chk = @chk_first THEN 1 ELSE 0 END,
    CONCAT(N'first=', @cnt_first, N'/', @chk_first, N' second=', @cnt, N'/', @chk));

SET @i = 1;
WHILE @i <= 2
BEGIN
    SET @run = NEWID();
    EXEC covid_etl.usp_begin_load N'testing', @run, N'idempotency_checks';
    INSERT INTO covid_staging.testing
        (load_run_id, country, country_code_2_digit, country_code_3_digit, year_week, week_start_date,
         week_end_date, new_cases, tests_done, population, testing_data_source)
    VALUES (@run, 'Testland', 'TL', 'TLD', '2021-W01', '2021-01-04', '2021-01-10', 100, 1000, 1000, 'Fixture'),
           (@run, 'Testland', 'TL', 'TLD', '2021-W02', '2021-01-11', '2021-01-17', 120, 1100, 1000, 'Fixture');
    EXEC covid_etl.usp_validate_testing @pipeline_run_id = @run, @expected_row_count = 2;
    EXEC covid_etl.usp_publish_testing @pipeline_run_id = @run;
    SELECT @cnt = COUNT_BIG(*),
           @chk = CHECKSUM_AGG(BINARY_CHECKSUM(country, country_code_2_digit, country_code_3_digit, year_week,
                                               week_start_date, week_end_date, new_cases, tests_done, population,
                                               testing_data_source))
    FROM covid_reporting.testing;
    IF @i = 1 SELECT @cnt_first = @cnt, @chk_first = @chk;
    SET @i += 1;
END;
INSERT INTO #results VALUES ('T10b', N'testing: repeated load is idempotent',
    CASE WHEN @cnt = 2 AND @cnt = @cnt_first AND @chk = @chk_first THEN 1 ELSE 0 END,
    CONCAT(N'first=', @cnt_first, N'/', @chk_first, N' second=', @cnt, N'/', @chk));

/* ---------- T11: unknown target rejected ---------- */
DECLARE @err int = NULL;
SET @run = NEWID();
BEGIN TRY EXEC covid_etl.usp_begin_load N'cases_and_deaths; DROP TABLE x', @run, N'idempotency_checks'; END TRY
BEGIN CATCH SET @err = ERROR_NUMBER(); END CATCH;
INSERT INTO #results VALUES ('T11', N'Unknown or malicious target name rejected',
    CASE WHEN @err = 50001 THEN 1 ELSE 0 END, CONCAT(N'error=', @err));
GO

SELECT test_id, CASE passed WHEN 1 THEN 'PASS' ELSE 'FAIL' END AS result, description, detail
FROM #results ORDER BY test_id;

IF EXISTS (SELECT 1 FROM #results WHERE passed = 0)
    THROW 50999, N'One or more idempotency checks failed; see the result set above.', 1;
PRINT N'All idempotency checks passed.';
GO
