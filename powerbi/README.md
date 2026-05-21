# Pipeline Monitoring — Power BI Report

A Power BI report that visualizes the `audit_log` produced by `pl_metadata_ingest`. It shows run-by-run success/failure trends, per-source row counts, and durations — so a data ops engineer can spot a degraded source at a glance.

---

## 1. Prerequisites

- Pipeline `pl_metadata_ingest` has produced at least a couple of runs (so `audit_log` is not empty).
- Warehouse `wh_ingestion_demo` is reachable from your Fabric workspace.

---

## 2. Create the reporting views

Open the SQL editor for **`wh_ingestion_demo`** and run [warehouse/create-monitoring-views.sql](../warehouse/create-monitoring-views.sql). It creates two views:

| View | Purpose |
|---|---|
| `dbo.vw_audit_log` | Per-source detail (one row per source per run) |
| `dbo.vw_run_summary` | Per-run rollup (one row per `run_id`) |

> The Power BI visuals below use these views so the DAX stays minimal.

---

## 3. Create the semantic model

1. In your Fabric workspace, open Warehouse `wh_ingestion_demo`.
2. Top ribbon → **Reporting** → **New semantic model**.
3. Name it **`sm_pipeline_monitoring`** and add these tables:
   - `dbo.vw_audit_log`
   - `dbo.vw_run_summary`
4. Save.

> The two views share `run_id`. If Power BI does not auto-detect the relationship, in **Model view** drag `vw_run_summary[run_id]` to `vw_audit_log[run_id]` (1 → many, single direction).

---

## 4. Add the DAX measures

Open the semantic model → **New measure** for each entry below. Put them all on the `vw_audit_log` table.

```dax
Total Runs              = DISTINCTCOUNT(vw_audit_log[run_id])

Total Sources Processed = COUNTROWS(vw_audit_log)

Success Count           = CALCULATE(COUNTROWS(vw_audit_log), vw_audit_log[status] = "success")

Failure Count           = CALCULATE(COUNTROWS(vw_audit_log), vw_audit_log[status] = "failed")

Success Rate %          =
DIVIDE(
    [Success Count],
    [Total Sources Processed],
    0
) * 100

Total Rows Copied       = SUM(vw_audit_log[rows_copied])

Avg Duration (sec)      = AVERAGE(vw_audit_log[duration_sec])

Last Run Status         =
VAR _last =
    TOPN(
        1,
        VALUES(vw_run_summary[run_id]),
        CALCULATE(MAX(vw_run_summary[run_start])),
        DESC
    )
RETURN
    CALCULATE(
        MAX(vw_run_summary[run_status]),
        _last
    )
```

---

## 5. Build the report page

Create a new report on `sm_pipeline_monitoring` and lay out:

### Header row — KPI cards

| Card | Field |
|---|---|
| **Total Runs** | `[Total Runs]` |
| **Success Rate %** | `[Success Rate %]` (format: `0.0 %`) |
| **Failures** | `[Failure Count]` (conditional color: red if > 0) |
| **Rows Copied** | `[Total Rows Copied]` |
| **Last Run Status** | `[Last Run Status]` (background green / red based on value) |

### Middle row

- **Clustered column chart** — *Runs over time*
  - X axis: `vw_audit_log[run_date]`
  - Y axis: `[Success Count]`, `[Failure Count]` (legend by status; green for success, red for failure).
- **Donut chart** — *Run outcome share*
  - Legend: `vw_audit_log[status]`
  - Values: `[Total Sources Processed]`.

### Bottom row

- **Table** — *Source health*
  - Columns: `target_table`, `[Success Count]`, `[Failure Count]`, `[Success Rate %]`, `[Avg Duration (sec)]`, `[Total Rows Copied]`.
  - Conditional formatting on `[Failure Count]` — color scale 0 → red.
- **Table** — *Recent runs*
  - Columns: `run_id`, `run_start`, `run_status`, `sources_total`, `sources_succeeded`, `sources_failed`, `total_rows_copied`.
  - Sort: `run_start` descending. Show top 20.
  - Conditional formatting on `run_status` — value = "failed" → red background.

### Slicers (top of page)

- `vw_audit_log[run_date]` (between)
- `vw_audit_log[target_table]` (dropdown)
- `vw_run_summary[run_status]` (buttons)

---

## 6. Optional: drill-through to error detail

1. Create a second page **Error Detail**.
2. Add a table with: `run_id`, `target_table`, `start_time`, `duration_sec`, `error_message`.
3. Filter the page (via drill-through) on `target_table`.
4. On the *Source health* table on the main page, right-click any row → *Drill through* → *Error Detail*.

---

## 7. Refresh schedule

Because the model points at the Warehouse via SQL, you can either:

- Use **Direct Lake / DirectQuery** (no refresh needed — always live).
- Or **Import mode** with a scheduled refresh: in the workspace, open the semantic model → **Settings** → **Refresh** → add 1–2 daily refreshes (or one after the pipeline schedule).

---

## 8. Smoke test

1. Run `pl_metadata_ingest` once.
2. Force one failure: e.g. flip `legacy` to `is_active = 1` in `config_ingestion` so the missing `legacy.csv` triggers a failed iteration.
3. Refresh the report — you should see `Failure Count > 0`, the donut should show a red slice, and *Last Run Status* should turn red.
