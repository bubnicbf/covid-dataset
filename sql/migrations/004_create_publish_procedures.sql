/*
    004_create_publish_procedures.sql

    Stored procedures behind the SQL-loading pipelines. Each pipeline:

        usp_begin_load                    -> audit row "Started", empty run-scoped staging
        (copy activity -> covid_staging.* with load_run_id = pipeline run ID;
         its pre-copy script calls usp_clear_staged_load so copy retries start clean)
        usp_validate_<table>              -> audit row "Validated", or error
        usp_publish_<table>               -> one transaction: replace production, audit "Succeeded"
        usp_record_load_failure           -> ADF failure path: audit "Failed", clear staging

    Design rules:
      * Production tables change only inside usp_publish_*: DELETE + INSERT in one
        transaction, under an exclusive application lock per table.
        Any error rolls back, so the previous snapshot stays intact.
      * SET XACT_ABORT ON plus TRY/CATCH: roll back on every error, then rethrow
        the original error with THROW.
      * No dynamic SQL. Target tables are chosen from a fixed list with static
        branches.
      * All procedures are idempotent for a given pipeline run ID, so ADF activity
        retries are safe.
      * All objects are owned by dbo, so ownership chaining lets the Data Factory
        identity change production data only through these procedures (see 006).

    Error numbers: 50001-50099 (see each THROW).
*/
SET NOCOUNT ON;
GO

/* ---------------------------------------------------------------------------
   usp_clear_staged_load: delete this run's staged rows for one target.
   Called by usp_begin_load and by the copy activity's pre-copy script, so a
   copy retry never duplicates staged rows.
--------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE covid_etl.usp_clear_staged_load
    @target_table    sysname,
    @pipeline_run_id uniqueidentifier
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @target_table = N'cases_and_deaths'
        DELETE FROM covid_staging.cases_and_deaths WHERE load_run_id = @pipeline_run_id;
    ELSE IF @target_table = N'hospital_admissions_daily'
        DELETE FROM covid_staging.hospital_admissions_daily WHERE load_run_id = @pipeline_run_id;
    ELSE IF @target_table = N'testing'
        DELETE FROM covid_staging.testing WHERE load_run_id = @pipeline_run_id;
    ELSE
        THROW 50001, N'Unknown target table. Allowed: cases_and_deaths, hospital_admissions_daily, testing.', 1;
END;
GO

/* ---------------------------------------------------------------------------
   usp_purge_abandoned_staging: remove staged rows that no active run owns.
   A run is active if its audit row is Started/Validated and is less than
   24 hours old. Rows from finished, failed, or abandoned runs are removed.
--------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE covid_etl.usp_purge_abandoned_staging
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @cutoff datetime2(3) = DATEADD(HOUR, -24, SYSUTCDATETIME());

    DELETE s
    FROM covid_staging.cases_and_deaths AS s
    WHERE NOT EXISTS (SELECT 1 FROM covid_etl.load_audit AS a
                      WHERE a.pipeline_run_id = s.load_run_id
                        AND a.target_table = N'cases_and_deaths'
                        AND a.status IN ('Started', 'Validated')
                        AND a.started_at_utc >= @cutoff);

    DELETE s
    FROM covid_staging.hospital_admissions_daily AS s
    WHERE NOT EXISTS (SELECT 1 FROM covid_etl.load_audit AS a
                      WHERE a.pipeline_run_id = s.load_run_id
                        AND a.target_table = N'hospital_admissions_daily'
                        AND a.status IN ('Started', 'Validated')
                        AND a.started_at_utc >= @cutoff);

    DELETE s
    FROM covid_staging.testing AS s
    WHERE NOT EXISTS (SELECT 1 FROM covid_etl.load_audit AS a
                      WHERE a.pipeline_run_id = s.load_run_id
                        AND a.target_table = N'testing'
                        AND a.status IN ('Started', 'Validated')
                        AND a.started_at_utc >= @cutoff);
END;
GO

/* ---------------------------------------------------------------------------
   usp_begin_load: register the run and give it an empty staging area.
   Safe to retry. A run that already published cannot be restarted.
--------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE covid_etl.usp_begin_load
    @target_table    sysname,
    @pipeline_run_id uniqueidentifier,
    @pipeline_name   nvarchar(260) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @target_table NOT IN (N'cases_and_deaths', N'hospital_admissions_daily', N'testing')
        THROW 50001, N'Unknown target table. Allowed: cases_and_deaths, hospital_admissions_daily, testing.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        IF EXISTS (SELECT 1 FROM covid_etl.load_audit WITH (UPDLOCK, HOLDLOCK)
                   WHERE pipeline_run_id = @pipeline_run_id
                     AND target_table = @target_table
                     AND status IN ('Succeeded', 'Superseded'))
            THROW 50002, N'This pipeline run already completed for this target; start a new pipeline run.', 1;

        UPDATE covid_etl.load_audit
        SET status              = 'Started',
            pipeline_name       = COALESCE(@pipeline_name, pipeline_name),
            started_at_utc      = SYSUTCDATETIME(),
            validated_at_utc    = NULL,
            completed_at_utc    = NULL,
            copied_row_count    = NULL,
            staged_row_count    = NULL,
            previous_row_count  = NULL,
            published_row_count = NULL,
            error_summary       = NULL
        WHERE pipeline_run_id = @pipeline_run_id
          AND target_table = @target_table;

        IF @@ROWCOUNT = 0
            INSERT INTO covid_etl.load_audit (pipeline_run_id, target_table, pipeline_name, status, started_at_utc)
            VALUES (@pipeline_run_id, @target_table, @pipeline_name, 'Started', SYSUTCDATETIME());

        EXEC covid_etl.usp_clear_staged_load @target_table = @target_table, @pipeline_run_id = @pipeline_run_id;
        EXEC covid_etl.usp_purge_abandoned_staging;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

/* ---------------------------------------------------------------------------
   usp_record_load_failure: called by the ADF failure path after retries
   are exhausted. Marks the run Failed, keeps any specific error already
   recorded by validation or publication, and clears the run's staged rows.
   Production data is never touched. Safe to retry. Never downgrades a
   completed run.
--------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE covid_etl.usp_record_load_failure
    @target_table    sysname,
    @pipeline_run_id uniqueidentifier,
    @error_summary   nvarchar(400) = NULL,
    @pipeline_name   nvarchar(260) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @target_table NOT IN (N'cases_and_deaths', N'hospital_admissions_daily', N'testing')
        THROW 50001, N'Unknown target table. Allowed: cases_and_deaths, hospital_admissions_daily, testing.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE covid_etl.load_audit
        SET status           = 'Failed',
            completed_at_utc = SYSUTCDATETIME(),
            error_summary    = COALESCE(error_summary, @error_summary, N'Load failed; see ADF Monitor for the pipeline run.')
        WHERE pipeline_run_id = @pipeline_run_id
          AND target_table = @target_table
          AND status NOT IN ('Succeeded', 'Superseded');

        -- The run may have failed before usp_begin_load created its audit row.
        IF @@ROWCOUNT = 0
           AND NOT EXISTS (SELECT 1 FROM covid_etl.load_audit
                           WHERE pipeline_run_id = @pipeline_run_id AND target_table = @target_table)
            INSERT INTO covid_etl.load_audit
                (pipeline_run_id, target_table, pipeline_name, status, started_at_utc, completed_at_utc, error_summary)
            VALUES
                (@pipeline_run_id, @target_table, @pipeline_name, 'Failed', SYSUTCDATETIME(), SYSUTCDATETIME(),
                 COALESCE(@error_summary, N'Load failed before it was registered; see ADF Monitor.'));

        EXEC covid_etl.usp_clear_staged_load @target_table = @target_table, @pipeline_run_id = @pipeline_run_id;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

/* ===========================================================================
   cases_and_deaths
   Business key: (country, reported_date, source), which is the data flow's
   pivot grain minus the per-country attributes (population, country code).
=========================================================================== */
CREATE OR ALTER PROCEDURE covid_etl.usp_validate_cases_and_deaths
    @pipeline_run_id    uniqueidentifier,
    @expected_row_count bigint = NULL,   -- rowsCopied from the ADF copy activity
    @allow_empty        bit    = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @target sysname = N'cases_and_deaths',
            @status varchar(20), @staged bigint, @null_keys bigint, @dup_keys bigint,
            @error nvarchar(400);

    BEGIN TRY
        SELECT @status = status FROM covid_etl.load_audit
        WHERE pipeline_run_id = @pipeline_run_id AND target_table = @target;

        IF @status IS NULL
            THROW 50020, N'No load_audit row for this run; call covid_etl.usp_begin_load first.', 1;
        IF @status NOT IN ('Started', 'Validated')
            THROW 50021, N'Load is not in a state that can be validated (expected Started or Validated).', 1;

        SELECT @staged    = COUNT_BIG(*),
               @null_keys = ISNULL(SUM(CASE WHEN country IS NULL OR reported_date IS NULL THEN 1 ELSE 0 END), 0)
        FROM covid_staging.cases_and_deaths
        WHERE load_run_id = @pipeline_run_id;

        SELECT @dup_keys = COUNT_BIG(*)
        FROM (SELECT 1 AS k
              FROM covid_staging.cases_and_deaths
              WHERE load_run_id = @pipeline_run_id
              GROUP BY country, reported_date, source
              HAVING COUNT_BIG(*) > 1) AS d;

        SET @error = CASE
            WHEN @staged = 0 AND @allow_empty = 0
                THEN N'Staged snapshot is empty; publication rejected (set allowEmptySnapshot to override).'
            WHEN @expected_row_count IS NOT NULL AND @staged <> @expected_row_count
                THEN CONCAT(N'Staged row count (', @staged, N') does not match rows copied (', @expected_row_count, N').')
            WHEN @null_keys > 0
                THEN CONCAT(@null_keys, N' staged row(s) have a NULL country or reported_date.')
            WHEN @dup_keys > 0
                THEN CONCAT(@dup_keys, N' business key(s) (country, reported_date, source) are duplicated in the staged snapshot.')
        END;

        IF @error IS NOT NULL
        BEGIN
            UPDATE covid_etl.load_audit
            SET status = 'Started', copied_row_count = @expected_row_count, staged_row_count = @staged,
                validated_at_utc = NULL, error_summary = @error
            WHERE pipeline_run_id = @pipeline_run_id AND target_table = @target;

            THROW 50022, @error, 1;
        END;

        UPDATE covid_etl.load_audit
        SET status = 'Validated', copied_row_count = @expected_row_count, staged_row_count = @staged,
            validated_at_utc = SYSUTCDATETIME(), error_summary = NULL
        WHERE pipeline_run_id = @pipeline_run_id AND target_table = @target;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE covid_etl.usp_publish_cases_and_deaths
    @pipeline_run_id uniqueidentifier,
    @allow_empty     bit = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @target sysname = N'cases_and_deaths',
            @lock_result int, @audit_id bigint, @status varchar(20), @validated_count bigint,
            @staged bigint, @previous bigint, @published bigint, @error nvarchar(400);

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Serialize publication for this table across all sessions and runs.
        EXEC @lock_result = sys.sp_getapplock
            @Resource = N'covid_etl.publish.cases_and_deaths',
            @LockMode = 'Exclusive', @LockOwner = 'Transaction', @LockTimeout = 60000;
        IF @lock_result < 0
            THROW 50016, N'Could not acquire the publication lock (another run is publishing); retry later.', 1;

        SELECT @audit_id = load_audit_id, @status = status, @validated_count = staged_row_count
        FROM covid_etl.load_audit WITH (UPDLOCK, HOLDLOCK)
        WHERE pipeline_run_id = @pipeline_run_id AND target_table = @target;

        IF @audit_id IS NULL
            THROW 50010, N'No load_audit row for this run; call covid_etl.usp_begin_load first.', 1;

        -- Idempotent retry: this run already published (or was superseded).
        IF @status IN ('Succeeded', 'Superseded')
        BEGIN
            COMMIT TRANSACTION;
            RETURN 0;
        END;

        IF @status <> 'Validated'
            THROW 50011, N'Staged snapshot has not passed validation; publication refused.', 1;

        -- Never replace a newer published snapshot with an older run's data.
        IF EXISTS (SELECT 1 FROM covid_etl.load_audit
                   WHERE target_table = @target AND status = 'Succeeded' AND load_audit_id > @audit_id)
        BEGIN
            DELETE FROM covid_staging.cases_and_deaths WHERE load_run_id = @pipeline_run_id;
            UPDATE covid_etl.load_audit
            SET status = 'Superseded', completed_at_utc = SYSUTCDATETIME(),
                error_summary = N'A newer run already published this table; production left unchanged.'
            WHERE load_audit_id = @audit_id;
            COMMIT TRANSACTION;
            RETURN 0;
        END;

        -- Re-check the stage inside the transaction (defense in depth).
        SELECT @staged = COUNT_BIG(*) FROM covid_staging.cases_and_deaths WHERE load_run_id = @pipeline_run_id;
        IF @staged <> @validated_count
            THROW 50012, N'Staged row count changed after validation; publication refused.', 1;
        IF @staged = 0 AND @allow_empty = 0
            THROW 50013, N'Staged snapshot is empty; publication rejected.', 1;
        IF EXISTS (SELECT 1 FROM covid_staging.cases_and_deaths
                   WHERE load_run_id = @pipeline_run_id
                   GROUP BY country, reported_date, source HAVING COUNT_BIG(*) > 1)
           OR EXISTS (SELECT 1 FROM covid_staging.cases_and_deaths
                      WHERE load_run_id = @pipeline_run_id AND (country IS NULL OR reported_date IS NULL))
            THROW 50014, N'Staged snapshot has NULL or duplicate business keys; publication refused.', 1;

        -- Atomic replacement. Readers see the old or the new snapshot, never a mix.
        SELECT @previous = COUNT_BIG(*) FROM covid_reporting.cases_and_deaths WITH (TABLOCKX);

        DELETE FROM covid_reporting.cases_and_deaths;

        INSERT INTO covid_reporting.cases_and_deaths
            (country, country_code_2_digit, country_code_3_digit, population,
             cases_count, deaths_count, reported_date, source)
        SELECT country, country_code_2_digit, country_code_3_digit, population,
               cases_count, deaths_count, reported_date, source
        FROM covid_staging.cases_and_deaths
        WHERE load_run_id = @pipeline_run_id;

        SET @published = @@ROWCOUNT;
        IF @published <> @staged
            THROW 50015, N'Published row count does not match staged row count; rolling back.', 1;

        DELETE FROM covid_staging.cases_and_deaths WHERE load_run_id = @pipeline_run_id;

        UPDATE covid_etl.load_audit
        SET status = 'Succeeded', previous_row_count = @previous, published_row_count = @published,
            completed_at_utc = SYSUTCDATETIME(), error_summary = NULL
        WHERE load_audit_id = @audit_id;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        SET @error = LEFT(CONCAT(N'Publish failed (error ', ERROR_NUMBER(), N'): ', ERROR_MESSAGE()), 400);
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

        -- Record the reason but keep status Validated so an ADF retry can
        -- publish the same staged snapshot. The ADF failure path marks the run
        -- Failed once retries are exhausted. Auditing must never mask the
        -- original error.
        BEGIN TRY
            UPDATE covid_etl.load_audit SET error_summary = @error
            WHERE pipeline_run_id = @pipeline_run_id AND target_table = @target
              AND status NOT IN ('Succeeded', 'Superseded');
        END TRY
        BEGIN CATCH
        END CATCH;

        THROW;
    END CATCH;
END;
GO

/* ===========================================================================
   hospital_admissions_daily
   Business key: (country, reported_date, source), which is the data flow's
   daily pivot grain minus the per-country attributes.
=========================================================================== */
CREATE OR ALTER PROCEDURE covid_etl.usp_validate_hospital_admissions_daily
    @pipeline_run_id    uniqueidentifier,
    @expected_row_count bigint = NULL,
    @allow_empty        bit    = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @target sysname = N'hospital_admissions_daily',
            @status varchar(20), @staged bigint, @null_keys bigint, @dup_keys bigint,
            @error nvarchar(400);

    BEGIN TRY
        SELECT @status = status FROM covid_etl.load_audit
        WHERE pipeline_run_id = @pipeline_run_id AND target_table = @target;

        IF @status IS NULL
            THROW 50020, N'No load_audit row for this run; call covid_etl.usp_begin_load first.', 1;
        IF @status NOT IN ('Started', 'Validated')
            THROW 50021, N'Load is not in a state that can be validated (expected Started or Validated).', 1;

        SELECT @staged    = COUNT_BIG(*),
               @null_keys = ISNULL(SUM(CASE WHEN country IS NULL OR reported_date IS NULL THEN 1 ELSE 0 END), 0)
        FROM covid_staging.hospital_admissions_daily
        WHERE load_run_id = @pipeline_run_id;

        SELECT @dup_keys = COUNT_BIG(*)
        FROM (SELECT 1 AS k
              FROM covid_staging.hospital_admissions_daily
              WHERE load_run_id = @pipeline_run_id
              GROUP BY country, reported_date, source
              HAVING COUNT_BIG(*) > 1) AS d;

        SET @error = CASE
            WHEN @staged = 0 AND @allow_empty = 0
                THEN N'Staged snapshot is empty; publication rejected (set allowEmptySnapshot to override).'
            WHEN @expected_row_count IS NOT NULL AND @staged <> @expected_row_count
                THEN CONCAT(N'Staged row count (', @staged, N') does not match rows copied (', @expected_row_count, N').')
            WHEN @null_keys > 0
                THEN CONCAT(@null_keys, N' staged row(s) have a NULL country or reported_date.')
            WHEN @dup_keys > 0
                THEN CONCAT(@dup_keys, N' business key(s) (country, reported_date, source) are duplicated in the staged snapshot.')
        END;

        IF @error IS NOT NULL
        BEGIN
            UPDATE covid_etl.load_audit
            SET status = 'Started', copied_row_count = @expected_row_count, staged_row_count = @staged,
                validated_at_utc = NULL, error_summary = @error
            WHERE pipeline_run_id = @pipeline_run_id AND target_table = @target;

            THROW 50022, @error, 1;
        END;

        UPDATE covid_etl.load_audit
        SET status = 'Validated', copied_row_count = @expected_row_count, staged_row_count = @staged,
            validated_at_utc = SYSUTCDATETIME(), error_summary = NULL
        WHERE pipeline_run_id = @pipeline_run_id AND target_table = @target;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE covid_etl.usp_publish_hospital_admissions_daily
    @pipeline_run_id uniqueidentifier,
    @allow_empty     bit = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @target sysname = N'hospital_admissions_daily',
            @lock_result int, @audit_id bigint, @status varchar(20), @validated_count bigint,
            @staged bigint, @previous bigint, @published bigint, @error nvarchar(400);

    BEGIN TRY
        BEGIN TRANSACTION;

        EXEC @lock_result = sys.sp_getapplock
            @Resource = N'covid_etl.publish.hospital_admissions_daily',
            @LockMode = 'Exclusive', @LockOwner = 'Transaction', @LockTimeout = 60000;
        IF @lock_result < 0
            THROW 50016, N'Could not acquire the publication lock (another run is publishing); retry later.', 1;

        SELECT @audit_id = load_audit_id, @status = status, @validated_count = staged_row_count
        FROM covid_etl.load_audit WITH (UPDLOCK, HOLDLOCK)
        WHERE pipeline_run_id = @pipeline_run_id AND target_table = @target;

        IF @audit_id IS NULL
            THROW 50010, N'No load_audit row for this run; call covid_etl.usp_begin_load first.', 1;

        IF @status IN ('Succeeded', 'Superseded')
        BEGIN
            COMMIT TRANSACTION;
            RETURN 0;
        END;

        IF @status <> 'Validated'
            THROW 50011, N'Staged snapshot has not passed validation; publication refused.', 1;

        IF EXISTS (SELECT 1 FROM covid_etl.load_audit
                   WHERE target_table = @target AND status = 'Succeeded' AND load_audit_id > @audit_id)
        BEGIN
            DELETE FROM covid_staging.hospital_admissions_daily WHERE load_run_id = @pipeline_run_id;
            UPDATE covid_etl.load_audit
            SET status = 'Superseded', completed_at_utc = SYSUTCDATETIME(),
                error_summary = N'A newer run already published this table; production left unchanged.'
            WHERE load_audit_id = @audit_id;
            COMMIT TRANSACTION;
            RETURN 0;
        END;

        SELECT @staged = COUNT_BIG(*) FROM covid_staging.hospital_admissions_daily WHERE load_run_id = @pipeline_run_id;
        IF @staged <> @validated_count
            THROW 50012, N'Staged row count changed after validation; publication refused.', 1;
        IF @staged = 0 AND @allow_empty = 0
            THROW 50013, N'Staged snapshot is empty; publication rejected.', 1;
        IF EXISTS (SELECT 1 FROM covid_staging.hospital_admissions_daily
                   WHERE load_run_id = @pipeline_run_id
                   GROUP BY country, reported_date, source HAVING COUNT_BIG(*) > 1)
           OR EXISTS (SELECT 1 FROM covid_staging.hospital_admissions_daily
                      WHERE load_run_id = @pipeline_run_id AND (country IS NULL OR reported_date IS NULL))
            THROW 50014, N'Staged snapshot has NULL or duplicate business keys; publication refused.', 1;

        SELECT @previous = COUNT_BIG(*) FROM covid_reporting.hospital_admissions_daily WITH (TABLOCKX);

        DELETE FROM covid_reporting.hospital_admissions_daily;

        INSERT INTO covid_reporting.hospital_admissions_daily
            (country, country_code_2_digit, country_code_3_digit, population,
             reported_date, hospital_occupancy_count, icu_occupancy_count, source)
        SELECT country, country_code_2_digit, country_code_3_digit, population,
               reported_date, hospital_occupancy_count, icu_occupancy_count, source
        FROM covid_staging.hospital_admissions_daily
        WHERE load_run_id = @pipeline_run_id;

        SET @published = @@ROWCOUNT;
        IF @published <> @staged
            THROW 50015, N'Published row count does not match staged row count; rolling back.', 1;

        DELETE FROM covid_staging.hospital_admissions_daily WHERE load_run_id = @pipeline_run_id;

        UPDATE covid_etl.load_audit
        SET status = 'Succeeded', previous_row_count = @previous, published_row_count = @published,
            completed_at_utc = SYSUTCDATETIME(), error_summary = NULL
        WHERE load_audit_id = @audit_id;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        SET @error = LEFT(CONCAT(N'Publish failed (error ', ERROR_NUMBER(), N'): ', ERROR_MESSAGE()), 400);
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

        BEGIN TRY
            UPDATE covid_etl.load_audit SET error_summary = @error
            WHERE pipeline_run_id = @pipeline_run_id AND target_table = @target
              AND status NOT IN ('Succeeded', 'Superseded');
        END TRY
        BEGIN CATCH
        END CATCH;

        THROW;
    END CATCH;
END;
GO

/* ===========================================================================
   testing
   Business key: (country, year_week, testing_data_source). No transformation
   in this repository produces processed/ecdc/testing, so this key is an
   assumption based on the ECDC weekly testing dataset (one row per country,
   week, and data source at national level). If the input contains
   subnational rows, validation rejects the load instead of publishing
   ambiguous data.
=========================================================================== */
CREATE OR ALTER PROCEDURE covid_etl.usp_validate_testing
    @pipeline_run_id    uniqueidentifier,
    @expected_row_count bigint = NULL,
    @allow_empty        bit    = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @target sysname = N'testing',
            @status varchar(20), @staged bigint, @null_keys bigint, @dup_keys bigint,
            @error nvarchar(400);

    BEGIN TRY
        SELECT @status = status FROM covid_etl.load_audit
        WHERE pipeline_run_id = @pipeline_run_id AND target_table = @target;

        IF @status IS NULL
            THROW 50020, N'No load_audit row for this run; call covid_etl.usp_begin_load first.', 1;
        IF @status NOT IN ('Started', 'Validated')
            THROW 50021, N'Load is not in a state that can be validated (expected Started or Validated).', 1;

        SELECT @staged    = COUNT_BIG(*),
               @null_keys = ISNULL(SUM(CASE WHEN country IS NULL OR year_week IS NULL THEN 1 ELSE 0 END), 0)
        FROM covid_staging.testing
        WHERE load_run_id = @pipeline_run_id;

        SELECT @dup_keys = COUNT_BIG(*)
        FROM (SELECT 1 AS k
              FROM covid_staging.testing
              WHERE load_run_id = @pipeline_run_id
              GROUP BY country, year_week, testing_data_source
              HAVING COUNT_BIG(*) > 1) AS d;

        SET @error = CASE
            WHEN @staged = 0 AND @allow_empty = 0
                THEN N'Staged snapshot is empty; publication rejected (set allowEmptySnapshot to override).'
            WHEN @expected_row_count IS NOT NULL AND @staged <> @expected_row_count
                THEN CONCAT(N'Staged row count (', @staged, N') does not match rows copied (', @expected_row_count, N').')
            WHEN @null_keys > 0
                THEN CONCAT(@null_keys, N' staged row(s) have a NULL country or year_week.')
            WHEN @dup_keys > 0
                THEN CONCAT(@dup_keys, N' business key(s) (country, year_week, testing_data_source) are duplicated in the staged snapshot.')
        END;

        IF @error IS NOT NULL
        BEGIN
            UPDATE covid_etl.load_audit
            SET status = 'Started', copied_row_count = @expected_row_count, staged_row_count = @staged,
                validated_at_utc = NULL, error_summary = @error
            WHERE pipeline_run_id = @pipeline_run_id AND target_table = @target;

            THROW 50022, @error, 1;
        END;

        UPDATE covid_etl.load_audit
        SET status = 'Validated', copied_row_count = @expected_row_count, staged_row_count = @staged,
            validated_at_utc = SYSUTCDATETIME(), error_summary = NULL
        WHERE pipeline_run_id = @pipeline_run_id AND target_table = @target;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE covid_etl.usp_publish_testing
    @pipeline_run_id uniqueidentifier,
    @allow_empty     bit = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @target sysname = N'testing',
            @lock_result int, @audit_id bigint, @status varchar(20), @validated_count bigint,
            @staged bigint, @previous bigint, @published bigint, @error nvarchar(400);

    BEGIN TRY
        BEGIN TRANSACTION;

        EXEC @lock_result = sys.sp_getapplock
            @Resource = N'covid_etl.publish.testing',
            @LockMode = 'Exclusive', @LockOwner = 'Transaction', @LockTimeout = 60000;
        IF @lock_result < 0
            THROW 50016, N'Could not acquire the publication lock (another run is publishing); retry later.', 1;

        SELECT @audit_id = load_audit_id, @status = status, @validated_count = staged_row_count
        FROM covid_etl.load_audit WITH (UPDLOCK, HOLDLOCK)
        WHERE pipeline_run_id = @pipeline_run_id AND target_table = @target;

        IF @audit_id IS NULL
            THROW 50010, N'No load_audit row for this run; call covid_etl.usp_begin_load first.', 1;

        IF @status IN ('Succeeded', 'Superseded')
        BEGIN
            COMMIT TRANSACTION;
            RETURN 0;
        END;

        IF @status <> 'Validated'
            THROW 50011, N'Staged snapshot has not passed validation; publication refused.', 1;

        IF EXISTS (SELECT 1 FROM covid_etl.load_audit
                   WHERE target_table = @target AND status = 'Succeeded' AND load_audit_id > @audit_id)
        BEGIN
            DELETE FROM covid_staging.testing WHERE load_run_id = @pipeline_run_id;
            UPDATE covid_etl.load_audit
            SET status = 'Superseded', completed_at_utc = SYSUTCDATETIME(),
                error_summary = N'A newer run already published this table; production left unchanged.'
            WHERE load_audit_id = @audit_id;
            COMMIT TRANSACTION;
            RETURN 0;
        END;

        SELECT @staged = COUNT_BIG(*) FROM covid_staging.testing WHERE load_run_id = @pipeline_run_id;
        IF @staged <> @validated_count
            THROW 50012, N'Staged row count changed after validation; publication refused.', 1;
        IF @staged = 0 AND @allow_empty = 0
            THROW 50013, N'Staged snapshot is empty; publication rejected.', 1;
        IF EXISTS (SELECT 1 FROM covid_staging.testing
                   WHERE load_run_id = @pipeline_run_id
                   GROUP BY country, year_week, testing_data_source HAVING COUNT_BIG(*) > 1)
           OR EXISTS (SELECT 1 FROM covid_staging.testing
                      WHERE load_run_id = @pipeline_run_id AND (country IS NULL OR year_week IS NULL))
            THROW 50014, N'Staged snapshot has NULL or duplicate business keys; publication refused.', 1;

        SELECT @previous = COUNT_BIG(*) FROM covid_reporting.testing WITH (TABLOCKX);

        DELETE FROM covid_reporting.testing;

        INSERT INTO covid_reporting.testing
            (country, country_code_2_digit, country_code_3_digit, year_week, week_start_date,
             week_end_date, new_cases, tests_done, population, testing_data_source)
        SELECT country, country_code_2_digit, country_code_3_digit, year_week, week_start_date,
               week_end_date, new_cases, tests_done, population, testing_data_source
        FROM covid_staging.testing
        WHERE load_run_id = @pipeline_run_id;

        SET @published = @@ROWCOUNT;
        IF @published <> @staged
            THROW 50015, N'Published row count does not match staged row count; rolling back.', 1;

        DELETE FROM covid_staging.testing WHERE load_run_id = @pipeline_run_id;

        UPDATE covid_etl.load_audit
        SET status = 'Succeeded', previous_row_count = @previous, published_row_count = @published,
            completed_at_utc = SYSUTCDATETIME(), error_summary = NULL
        WHERE load_audit_id = @audit_id;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        SET @error = LEFT(CONCAT(N'Publish failed (error ', ERROR_NUMBER(), N'): ', ERROR_MESSAGE()), 400);
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

        BEGIN TRY
            UPDATE covid_etl.load_audit SET error_summary = @error
            WHERE pipeline_run_id = @pipeline_run_id AND target_table = @target
              AND status NOT IN ('Succeeded', 'Superseded');
        END TRY
        BEGIN CATCH
        END CATCH;

        THROW;
    END CATCH;
END;
GO
