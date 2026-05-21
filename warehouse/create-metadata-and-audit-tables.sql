-- =============================================================================
-- Step 2 — Create metadata + audit tables in the Fabric Warehouse
-- =============================================================================
-- Run this script in the SQL editor of your Warehouse `wh_ingestion_demo`.
--
-- WHY a Warehouse (not the Lakehouse SQL analytics endpoint)?
--   - The Lakehouse SQL endpoint is READ-ONLY. The pipeline's Script activity
--     needs to INSERT into audit_log, which only a Warehouse supports.
--   - Both tables stay in T-SQL, so the same connection serves Lookup + Script.
--
-- The script is idempotent — safe to re-run.
-- =============================================================================

-- ---------- 1. config_ingestion (control table) ------------------------------

IF OBJECT_ID('dbo.config_ingestion', 'U') IS NOT NULL
    DROP TABLE dbo.config_ingestion;

CREATE TABLE dbo.config_ingestion (
    source_id       INT            NOT NULL,
    source_system   VARCHAR(100)   NOT NULL,
    source_path     VARCHAR(500)   NOT NULL,
    file_format     VARCHAR(20)    NOT NULL,
    target_table    VARCHAR(100)   NOT NULL,
    load_mode       VARCHAR(20)    NOT NULL,
    is_active       BIT            NOT NULL
);

-- Seed rows for the tutorial (3 active CSVs + 1 disabled to prove the filter works).
-- Row 5 (inventory) is added later to simulate "onboarding a new data source"
-- without touching the pipeline — just INSERT and re-run.
INSERT INTO dbo.config_ingestion
    (source_id, source_system, source_path,                  file_format, target_table, load_mode, is_active)
VALUES
    (1, 'adls_sales', 'raw/sales/customers.csv', 'csv', 'customers', 'full', 1),
    (2, 'adls_sales', 'raw/sales/orders.csv',    'csv', 'orders',    'full', 1),
    (3, 'adls_sales', 'raw/sales/products.csv',  'csv', 'products',  'full', 1),
    (4, 'adls_sales', 'raw/sales/legacy.csv',    'csv', 'legacy',    'full', 0),  -- disabled on purpose
    (5, 'adls_sales', 'raw/sales/inventory.csv', 'csv', 'inventory', 'full', 1),  -- NEW source added without changing the pipeline
    (6, 'adls_sales', 'raw/sales/shipments.csv', 'csv', 'shipments', 'full', 1);  -- NEW source added without changing the pipeline

-- ---------- 2. audit_log (run history) ---------------------------------------
--
-- SAFETY: only create audit_log if it doesn't already exist, so re-running this
-- script never wipes pipeline history. To force a recreate, drop it manually.

IF OBJECT_ID('dbo.audit_log', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.audit_log (
        run_id          VARCHAR(100)  NOT NULL,
        source_id       INT           NULL,
        target_table    VARCHAR(100)  NULL,
        start_time      DATETIME2(3)  NULL,
        end_time        DATETIME2(3)  NULL,
        duration_sec    INT           NULL,
        rows_copied     BIGINT        NULL,
        status          VARCHAR(20)   NOT NULL,
        error_message   VARCHAR(4000) NULL
    );
END;

-- ---------- 3. Verify --------------------------------------------------------

SELECT 'config_ingestion' AS table_name, COUNT(*) AS row_count FROM dbo.config_ingestion
UNION ALL
SELECT 'audit_log',                       COUNT(*)             FROM dbo.audit_log;
