-- =============================================================================
-- Reporting view for the Pipeline Monitoring Power BI report.
-- Run in the Warehouse `wh_ingestion_demo` (same connection as audit_log).
--
-- Adds friendly column names + run-level rollups so Power BI visuals can stay
-- simple (no heavy DAX needed for the basic dashboard).
-- =============================================================================

-- ---------- Per-source detail view -------------------------------------------

CREATE OR ALTER VIEW dbo.vw_audit_log AS
SELECT
    a.run_id,
    a.source_id,
    c.source_system,
    a.target_table,
    a.start_time,
    a.end_time,
    a.duration_sec,
    a.rows_copied,
    a.status,
    a.error_message,
    CAST(a.start_time AS DATE)                              AS run_date,
    DATEPART(HOUR, a.start_time)                            AS run_hour,
    CASE WHEN a.status = 'success' THEN 1 ELSE 0 END        AS is_success,
    CASE WHEN a.status = 'failed'  THEN 1 ELSE 0 END        AS is_failure
FROM dbo.audit_log a
LEFT JOIN dbo.config_ingestion c ON c.source_id = a.source_id;

-- ---------- Per-run rollup view ----------------------------------------------

CREATE OR ALTER VIEW dbo.vw_run_summary AS
SELECT
    run_id,
    MIN(start_time)                                         AS run_start,
    MAX(end_time)                                           AS run_end,
    COUNT(*)                                                AS sources_total,
    SUM(CASE WHEN status = 'success' THEN 1 ELSE 0 END)     AS sources_succeeded,
    SUM(CASE WHEN status = 'failed'  THEN 1 ELSE 0 END)     AS sources_failed,
    COALESCE(SUM(rows_copied), 0)                           AS total_rows_copied,
    CASE
        WHEN SUM(CASE WHEN status = 'failed' THEN 1 ELSE 0 END) > 0 THEN 'failed'
        ELSE 'success'
    END                                                     AS run_status
FROM dbo.audit_log
GROUP BY run_id;
