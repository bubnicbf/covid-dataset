/*
    003_create_load_audit_table.sql

    One row per (ADF pipeline run, target table). Holds only operational
    metadata: run ID, timestamps, row counts, status, and a short error
    summary. It never stores row data.

    Status lifecycle:
      Started    -> usp_begin_load ran; staging for this run is empty
      Validated  -> staged snapshot passed validation
      Succeeded  -> snapshot published to production (terminal)
      Superseded -> a newer run already published; nothing changed (terminal)
      Failed     -> the ADF failure path recorded the failure (terminal)
*/
SET NOCOUNT ON;
GO

IF SCHEMA_ID(N'covid_etl') IS NULL
    EXEC (N'CREATE SCHEMA covid_etl AUTHORIZATION dbo;');
GO

IF OBJECT_ID(N'covid_etl.load_audit', N'U') IS NULL
BEGIN
    CREATE TABLE covid_etl.load_audit
    (
        load_audit_id        bigint IDENTITY(1, 1) NOT NULL
            CONSTRAINT pk_load_audit PRIMARY KEY CLUSTERED,
        pipeline_run_id      uniqueidentifier NOT NULL,
        target_table         sysname          NOT NULL
            CONSTRAINT ck_load_audit_target CHECK
                (target_table IN (N'cases_and_deaths', N'hospital_admissions_daily', N'testing')),
        pipeline_name        nvarchar(260)    NULL,
        status               varchar(20)      NOT NULL
            CONSTRAINT ck_load_audit_status CHECK
                (status IN ('Started', 'Validated', 'Succeeded', 'Superseded', 'Failed')),
        started_at_utc       datetime2(3)     NOT NULL,
        validated_at_utc     datetime2(3)     NULL,
        completed_at_utc     datetime2(3)     NULL,
        copied_row_count     bigint           NULL,  -- rowsCopied reported by the ADF copy activity
        staged_row_count     bigint           NULL,  -- rows found in staging at validation
        previous_row_count   bigint           NULL,  -- production rows replaced by this publish
        published_row_count  bigint           NULL,  -- production rows after this publish
        error_summary        nvarchar(400)    NULL,
        CONSTRAINT uq_load_audit_run_target UNIQUE (pipeline_run_id, target_table)
    );

    CREATE INDEX ix_load_audit_target_status
        ON covid_etl.load_audit (target_table, status, load_audit_id);
END;
GO
