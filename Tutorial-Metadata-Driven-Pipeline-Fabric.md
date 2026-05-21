---
title: "Tutorial: Building a Simple Metadata-Driven Pipeline in Microsoft Fabric (ADLS Gen2 → Lakehouse)"
author: "Fabric Data Engineering Team"
date: 2026-05-20
---

# Tutorial: Building a Simple Metadata-Driven Pipeline in Microsoft Fabric (ADLS Gen2 → Lakehouse)

> ℹ️ **Note:** This is a **simplified** version of the [official Metadata-driven Ingestion Framework](https://github.com/microsoft/fabric-samples/tree/main/community-samples/Metadata-driven%20Ingestion%20Framework) in `microsoft/fabric-samples`. It keeps the core loop — **read metadata → loop → copy → land in Lakehouse** — plus a **lightweight version of auditing, email notification, and reporting** so the pattern is useful in real day-to-day work, without dragging in multi-source connectors, schema drift, or watermark management.

---

## 1. Introduction

A **metadata-driven pipeline** is a single, generic pipeline whose behavior is steered entirely by a configuration table (the *control table*). Instead of building one pipeline per source file or table, you build one pipeline that reads a list of sources at runtime and processes them in a loop.

**Why this pattern matters**

- **Scalability** — onboarding a new source is a one-row `INSERT`, not a pipeline redesign.
- **Maintainability** — a single Copy activity to update means a single place to fix bugs.
- **No-code onboarding** — analysts and data stewards can extend the platform without touching the pipeline canvas.
- **Consistency** — every source flows through the same logging, naming, and error path.

**Architecture at a glance**

```mermaid
flowchart LR
    A[("ADLS Gen2<br/>raw files")] --> P
    M[("config_ingestion<br/>metadata table")] --> P
    subgraph P["Fabric Data Pipeline"]
        L["Lookup<br/>(read config)"] --> F["ForEach<br/>(per row)"]
        F --> C["Copy Activity<br/>(dynamic source/sink)"]
        C -->|on success| AS["Script: insert<br/>audit_log (success)"]
        C -->|on failure| AF["Script: insert<br/>audit_log (failed)"]
    end
    P --> LH[("Fabric Lakehouse<br/>Delta Tables + audit_log")]
    P -->|on overall success/failure| N["Office 365 Outlook<br/>(email notification)"]
    LH --> R["Power BI report<br/>(monitoring dashboard)"]
```

---

## 2. Prerequisites

- A **Microsoft Fabric** workspace backed by an active **Capacity** (F2 or higher works for this tutorial).
- An **Azure Data Lake Storage Gen2** account with a container.
- Workspace role: **Contributor** (or higher) so you can create Lakehouses, Pipelines, and Connections.
- Permission to create a **Data Connection** in Fabric. For ADLS Gen2, choose one of:
  - Account Key / SAS (testing only)
  - **Service Principal** (recommended for production)
  - Organizational Account / Workspace Identity (recommended for first-time exploration)
- An **Office 365 / Outlook** account that Fabric can authorize for sending notification emails.
- (Optional) **Power BI** authoring rights in the workspace for the reporting step.

### Sample data shipped with this tutorial

Three small CSV files are provided in the [`sample-data/`](sample-data) folder of this repo:

| File | Rows | Purpose |
|---|---|---|
| [`sample-data/customers.csv`](sample-data/customers.csv) | 10 | Customer master |
| [`sample-data/orders.csv`](sample-data/orders.csv) | 15 | Transaction fact |
| [`sample-data/products.csv`](sample-data/products.csv) | 8 | Product catalog |

Upload them to ADLS Gen2 so they land at:

```
<container>/raw/sales/customers.csv
<container>/raw/sales/orders.csv
<container>/raw/sales/products.csv
```

Quick upload with Azure CLI:

```powershell
$ACCOUNT = "<your-storage-account>"
$CONTAINER = "<your-container>"

az storage blob upload-batch `
  --account-name $ACCOUNT `
  --destination "$CONTAINER/raw/sales" `
  --source ".\sample-data" `
  --pattern "*.csv" `
  --auth-mode login
```

> 💡 **Tip:** Any small CSV/Parquet files will work — the framework is format-agnostic. The shipped files just give you a runnable baseline.

---

## 3. Architecture (Simplified)

The official framework defines six components (Control Table, Data Ingestion, Auditing, Notification, Config Management, Reporting). For this tutorial we keep all six, but in a **deliberately minimal** form:

| # | Component | Kept? | How it's simplified |
|---|---|---|---|
| 1 | Control Table | ✅ | 7-column `config_ingestion` Delta table |
| 2 | Data Ingestion (Copy) | ✅ | Single dynamic Copy activity |
| 3 | Auditing | ✅ *simple* | 8-column `audit_log` Delta table — no lineage, no `data_read`/`data_written` breakdowns |
| 4 | Notification | ✅ *simple* | One Office 365 Outlook activity on overall success/failure |
| 5 | Config Management | ⚠️ partial | Connection only, no env table |
| 6 | Reporting | ✅ *simple* | Two SQL queries + one Power BI page on `audit_log` |

```
ADLS Gen2 (raw files)
        │
        ▼
Metadata Table (config_ingestion) ──► Pipeline (Lookup → ForEach → Copy → Audit Script)
                                              │                            │
                                              ▼                            ▼
                                  Fabric Lakehouse (Delta Tables)     audit_log table
                                              │                            │
                                              ▼                            ▼
                                       Email notification           Power BI report
```

---

## 4. Step 1 — Create the Lakehouse

**What:** Provision a Lakehouse to host both the control table and the ingested data.

**Why:** Storing the control table inside the same Lakehouse keeps the demo self-contained and avoids a separate Warehouse SKU.

**How:**

1. Open your Fabric workspace.
2. Select **+ New item** → **Lakehouse**.
3. Name it `lh_ingestion_demo` and click **Create**.
4. In the Lakehouse explorer you will see two top-level folders:
   - `Tables/` — Delta tables (managed)
   - `Files/` — unmanaged file storage

> ℹ️ **Note:** The Fabric UI evolves quickly. If a menu name differs, check the [Microsoft Learn Lakehouse docs](https://learn.microsoft.com/fabric/data-engineering/lakehouse-overview).

---

## 5. Step 2 — Create the Metadata and Audit Tables

**What:** Two Delta tables — `config_ingestion` (drives every run) and `audit_log` (records every run).

**Why:** Treating the source list **and** the run history as data — not as pipeline JSON or log files — is what makes the framework both metadata-driven and observable. Adding a source becomes an `INSERT`; investigating last night's failure becomes a `SELECT`.

> 💡 **Run-once notebook:** All the PySpark in this section is bundled in [`notebooks/Step2-Create-Metadata-And-Audit-Tables.ipynb`](notebooks/Step2-Create-Metadata-And-Audit-Tables.ipynb). Import it into your workspace, attach `lh_ingestion_demo`, click **Run all**, and skip ahead to §6 if you don't need the walkthrough below.

### 5.1 `config_ingestion` schema

| Column | Type | Description |
|---|---|---|
| `source_id` | INT | Primary key (logical) |
| `source_system` | STRING | Friendly name of the source, e.g. `adls_sales` |
| `source_path` | STRING | Full path in ADLS Gen2 relative to the container, e.g. `raw/sales/customers.csv` |
| `file_format` | STRING | `csv` or `parquet` |
| `target_table` | STRING | Name of the Delta table in the Lakehouse |
| `load_mode` | STRING | `full` or `incremental` |
| `is_active` | BOOLEAN | `true` to include in the next run, `false` to skip |

### 5.2 Create and seed `config_ingestion` (PySpark notebook)

Open a new **Notebook**, attach it to `lh_ingestion_demo`, then run:

```python
from pyspark.sql import Row

rows = [
    Row(source_id=1, source_system="adls_sales",
        source_path="raw/sales/customers.csv",
        file_format="csv", target_table="customers",
        load_mode="full", is_active=True),
    Row(source_id=2, source_system="adls_sales",
        source_path="raw/sales/orders.csv",
        file_format="csv", target_table="orders",
        load_mode="full", is_active=True),
    Row(source_id=3, source_system="adls_sales",
        source_path="raw/sales/products.csv",
        file_format="csv", target_table="products",
        load_mode="full", is_active=True),
    Row(source_id=4, source_system="adls_sales",
        source_path="raw/sales/legacy.csv",
        file_format="csv", target_table="legacy",
        load_mode="full", is_active=False),  # disabled on purpose
]

(spark.createDataFrame(rows)
      .write.mode("overwrite")
      .format("delta")
      .saveAsTable("config_ingestion"))

spark.table("config_ingestion").show(truncate=False)
```

### 5.3 `audit_log` schema

A deliberately small audit table — just enough to answer *"what ran, when, how long, did it work, and how many rows?"*

| Column | Type | Description |
|---|---|---|
| `run_id` | STRING | Pipeline run ID (`@pipeline().RunId`) — groups all rows of one execution |
| `source_id` | INT | FK back to `config_ingestion.source_id` |
| `target_table` | STRING | Destination Delta table |
| `start_time` | TIMESTAMP | When the per-source copy started |
| `end_time` | TIMESTAMP | When the per-source copy ended |
| `duration_sec` | INT | `end_time - start_time` in seconds |
| `rows_copied` | BIGINT | `rowsCopied` reported by the Copy activity |
| `status` | STRING | `success` or `failed` |
| `error_message` | STRING | Activity error text on failure, `NULL` on success |

### 5.4 Create the empty `audit_log` table

In the same notebook:

```python
from pyspark.sql.types import (
    StructType, StructField, StringType, IntegerType,
    LongType, TimestampType
)

audit_schema = StructType([
    StructField("run_id",        StringType(),    False),
    StructField("source_id",     IntegerType(),   True),
    StructField("target_table",  StringType(),    True),
    StructField("start_time",    TimestampType(), True),
    StructField("end_time",      TimestampType(), True),
    StructField("duration_sec",  IntegerType(),   True),
    StructField("rows_copied",   LongType(),      True),
    StructField("status",        StringType(),    False),
    StructField("error_message", StringType(),    True),
])

(spark.createDataFrame([], audit_schema)
      .write.mode("overwrite")
      .format("delta")
      .saveAsTable("audit_log"))
```

> 💡 **Tip:** Prefer a JSON or CSV file in `Files/` for the control table? The Lookup activity can read either. A Delta table is recommended because `audit_log` will be appended to from the pipeline via the SQL endpoint.

---

## 6. Step 3 — Create the ADLS Gen2 Connection

**What:** A reusable Fabric **Connection** that the Copy activity will use to reach your storage account.

**Why:** Connections decouple credentials from pipeline JSON, so the same pipeline can be repointed across environments without code changes.

**How:**

1. From the workspace, open **Manage connections and gateways** (or **Settings → Manage connections**).
2. Click **+ New** → **Cloud** → **Azure Data Lake Storage Gen2**.
3. Provide the **URL** in the form `https://<account>.dfs.core.windows.net/<container>`.
4. Choose an authentication method:

   | Method | Use when |
   |---|---|
   | **Organizational account** | Quick test with your own identity |
   | **Service Principal** | Recommended for production / shared pipelines |
   | **Account Key** | Throwaway demos only |
   | **Workspace Identity** | Best-practice managed identity option |

5. Name the connection `conn_adls_sales` and save.

> ⚠️ **Warning:** Avoid Account Keys outside of throwaway labs — they are long-lived bearer secrets.

---

## 7. Step 4 — Build the Data Pipeline

**What:** A single pipeline with five activity types: **Lookup → ForEach { Copy → Audit Script (success / failure) } → Email notification**.

**Why:** This skeleton expresses the full pattern — read config, loop, copy, log the outcome, and tell a human.

### 7.1 Create the pipeline

1. In the workspace, **+ New item** → **Data pipeline**. Name it `pl_metadata_ingest`.

### 7.2 Add the Lookup activity

1. Drag a **Lookup** activity onto the canvas. Name it `LKP_Config`.
2. **Source:** select the **SQL analytics endpoint** of `lh_ingestion_demo`.
3. Toggle **Use query** and paste:

   ```sql
   SELECT *
   FROM config_ingestion
   WHERE is_active = 1;  -- Lakehouse SQL endpoint is T-SQL; use 1/0 for BIT, not true/false
   ```

4. **Important:** uncheck **First row only** so the activity returns all rows.

![Lookup configuration](images/lookup.png)

### 7.3 Add the ForEach activity

1. Drag a **ForEach** activity. Connect `LKP_Config` (On success) → `ForEach`.
2. Name it `FE_PerSource`.
3. In **Settings**, set **Items** to:

   ```text
   @activity('LKP_Config').output.value
   ```

4. Leave **Sequential** unchecked to allow parallel copies (Fabric will respect your capacity limits).

![ForEach configuration](images/foreach.png)

### 7.4 Add the Copy activity inside ForEach

1. Open the ForEach by clicking the pencil icon.
2. Drag a **Copy data** activity into it. Name it `CP_AdlsToLakehouse`.
3. **Source** tab:
   - Connection: `conn_adls_sales`
   - File path type: **File path**
   - File path: `@item().source_path`
   - File format: `@item().file_format` (or pick CSV/Parquet datasets dynamically as described in Step 5)
4. **Destination** tab:
   - Workspace: current
   - Lakehouse: `lh_ingestion_demo`
   - Root folder: **Tables**
   - Table name: `@item().target_table`
   - Table action: **Overwrite** for full loads, **Append** for incremental — see the expression in §8.

![Copy activity layout](images/copy.png)

### 7.5 Add the audit Script activities (success & failure)

Still inside the ForEach, add **two Script activities** wired to `CP_AdlsToLakehouse`:

- `SCR_Audit_Success` — connected from Copy via the **green (On success)** arrow.
- `SCR_Audit_Failure` — connected from Copy via the **red (On failure)** arrow.

For both, set the connection to the **SQL analytics endpoint** of `lh_ingestion_demo` and choose **Script type = Non-query**.

**`SCR_Audit_Success` script:**

```sql
INSERT INTO audit_log
(run_id, source_id, target_table, start_time, end_time,
 duration_sec, rows_copied, status, error_message)
VALUES (
  '@{pipeline().RunId}',
  @{item().source_id},
  '@{item().target_table}',
  '@{activity('CP_AdlsToLakehouse').executionStartTime}',
  '@{activity('CP_AdlsToLakehouse').executionEndTime}',
  @{activity('CP_AdlsToLakehouse').output.copyDuration},
  @{activity('CP_AdlsToLakehouse').output.rowsCopied},
  'success',
  NULL
);
```

**`SCR_Audit_Failure` script:**

```sql
INSERT INTO audit_log
(run_id, source_id, target_table, start_time, end_time,
 duration_sec, rows_copied, status, error_message)
VALUES (
  '@{pipeline().RunId}',
  @{item().source_id},
  '@{item().target_table}',
  '@{utcNow()}',
  '@{utcNow()}',
  0,
  0,
  'failed',
  '@{replace(coalesce(activity(''CP_AdlsToLakehouse'').error.message, ''unknown''), '''''''', ''"'')}'
);
```

> ⚠️ **Warning:** The single-quote escaping in the failure script is intentional — pipeline expressions use `''` to represent a literal apostrophe. Test the script once with a deliberately wrong `source_path` to confirm the failure path writes a row.

### 7.6 Add the email notification (outside the ForEach)

Back on the main canvas, drag two **Office 365 Outlook** activities after `FE_PerSource`:

- `EMAIL_Success` — connected via **green (On success)** arrow.
- `EMAIL_Failure` — connected via **red (On failure)** arrow.

For both, sign in with the account that should send the mail, then configure:

| Field | `EMAIL_Success` | `EMAIL_Failure` |
|---|---|---|
| **To** | `data-ops@yourcompany.com` | `data-ops@yourcompany.com` |
| **Subject** | `[Fabric] pl_metadata_ingest SUCCESS — @{pipeline().RunId}` | `[Fabric] pl_metadata_ingest FAILED — @{pipeline().RunId}` |
| **Body (HTML)** | see below | see below |

**Success body:**

```html
<p>Pipeline <b>pl_metadata_ingest</b> completed successfully.</p>
<ul>
  <li>Run ID: @{pipeline().RunId}</li>
  <li>Started: @{pipeline().TriggerTime}</li>
  <li>Workspace: @{pipeline().DataFactory}</li>
</ul>
<p>See the <b>Pipeline Monitoring</b> report for per-table row counts.</p>
```

**Failure body:**

```html
<p style="color:#b00020"><b>Pipeline pl_metadata_ingest FAILED.</b></p>
<ul>
  <li>Run ID: @{pipeline().RunId}</li>
  <li>Started: @{pipeline().TriggerTime}</li>
</ul>
<p>Query <code>audit_log</code> WHERE <code>run_id = '@{pipeline().RunId}'</code> for details.</p>
```

![Pipeline with audit + email](images/pipeline-with-audit.png)

---

## 8. Step 5 — Parameterization & Dynamic Expressions

**What:** The expressions that turn one static Copy activity into a generic one.

**Why:** Every property the pipeline needs to vary per row must be bound to a `@item().<column>` expression coming from ForEach.

Common expressions used in this tutorial:

```text
# Source path coming from the control table
@item().source_path

# Pick the destination table per iteration
@item().target_table

# Map load_mode -> Copy table action
@if(equals(item().load_mode, 'full'), 'Overwrite', 'Append')

# Format-aware dataset choice (used in If Condition if you split branches)
@equals(item().file_format, 'parquet')
```

> 💡 **Tip:** When a property only accepts a string (e.g. *Table action*), wrap the expression with `@{ ... }` so Fabric evaluates it inline:
>
> ```text
> @{if(equals(item().load_mode,'full'),'overwrite','append')}
> ```

### Dynamic dataset binding (optional)

If you want a single Copy activity to handle both CSV and Parquet without an `If Condition`, configure the source as a **Binary** dataset for the file path, and let the destination Lakehouse infer the schema. For maximum control, split into two Copy activities under an **If Condition** keyed on `@equals(item().file_format,'csv')`.

---

## 9. Step 6 — Run and Validate

**What:** Trigger the pipeline manually and confirm tables land in the Lakehouse and audit rows appear.

**How:**

1. Click **Run** on the pipeline toolbar.
2. Watch the **Output** pane — `LKP_Config` should return 3 rows (the active ones), and `FE_PerSource` should iterate three times.
3. Open `lh_ingestion_demo` → **Tables/** — you should see `customers`, `orders`, and `products` as Delta tables.
4. Check your inbox for the success email.
5. From the **SQL analytics endpoint**, validate row counts and audit rows:

   ```sql
   -- Data landed?
   SELECT 'customers' AS table_name, COUNT(*) AS row_count FROM customers
   UNION ALL
   SELECT 'orders',    COUNT(*) FROM orders
   UNION ALL
   SELECT 'products',  COUNT(*) FROM products;

   -- Audit captured?
   SELECT target_table, status, rows_copied, duration_sec, start_time
   FROM   audit_log
   WHERE  run_id = '<paste the run id from the pipeline monitor>'
   ORDER  BY start_time;
   ```

> ℹ️ **Note:** If a table is missing, check that its `is_active` flag is `true` and that the file path in the control table matches the actual ADLS layout. If the data landed but no audit row appeared, double-check the Script activity is connected to the Lakehouse **SQL analytics endpoint** (not the Lakehouse itself).

### 9.1 Force a failure to test the failure path

Temporarily flip one row's `source_path` to a non-existent file, re-run, and confirm:

- The Copy activity reports a red error.
- `SCR_Audit_Failure` runs and inserts a row with `status = 'failed'` and a non-null `error_message`.
- `EMAIL_Failure` fires (`EMAIL_Success` does not).

---

## 10. Step 7 — Add a New Source Without Touching the Pipeline

This is where the pattern earns its keep. Imagine a new `inventory.csv` arrives in ADLS. To onboard it:

```python
from pyspark.sql import Row

new_source = spark.createDataFrame([
    Row(source_id=5, source_system="adls_sales",
        source_path="raw/sales/inventory.csv",
        file_format="csv", target_table="inventory",
        load_mode="full",  is_active=True)
])

new_source.write.mode("append").format("delta").saveAsTable("config_ingestion")
```

Re-run `pl_metadata_ingest`. The Lookup now returns four rows, ForEach iterates four times, `inventory` appears in the Lakehouse, and a new `audit_log` row is recorded — **with zero pipeline edits**.

---

## 11. Step 8 — Monitoring & Reporting on `audit_log`

**What:** Turn `audit_log` into a one-page operational dashboard.

**Why:** Email tells you about *the latest run*; the dashboard tells you about *trends* (slow tables, recurring failures, row-count drift).

### 11.1 Useful SQL queries (SQL analytics endpoint)

```sql
-- Latest run summary (one row per table for the most recent run)
WITH latest AS (
  SELECT MAX(run_id) AS run_id FROM audit_log
)
SELECT a.target_table, a.status, a.rows_copied,
       a.duration_sec, a.start_time, a.error_message
FROM   audit_log a
JOIN   latest l ON a.run_id = l.run_id
ORDER  BY a.start_time;

-- Success rate per table (last 30 days)
SELECT target_table,
       COUNT(*)                                            AS runs,
       SUM(CASE WHEN status = 'success' THEN 1 ELSE 0 END) AS successes,
       SUM(CASE WHEN status = 'failed'  THEN 1 ELSE 0 END) AS failures,
       AVG(duration_sec)                                   AS avg_duration_sec,
       AVG(rows_copied)                                    AS avg_rows
FROM   audit_log
WHERE  start_time >= DATEADD(day, -30, GETUTCDATE())
GROUP  BY target_table
ORDER  BY failures DESC, target_table;

-- Daily throughput trend
SELECT CAST(start_time AS DATE) AS load_date,
       SUM(rows_copied)         AS total_rows,
       COUNT(DISTINCT run_id)   AS pipeline_runs
FROM   audit_log
WHERE  status = 'success'
GROUP  BY CAST(start_time AS DATE)
ORDER  BY load_date;
```

### 11.2 Build a simple Power BI report

1. In the Lakehouse, click **New Power BI report** (top toolbar) and pick **Continue** to create a new model.
2. Add `audit_log` to the model.
3. Build three visuals on a single page:

   | Visual | Type | Fields |
   |---|---|---|
   | **Latest run status** | Table | `target_table`, `status`, `rows_copied`, `duration_sec` — filtered to the latest `run_id` |
   | **Success vs Failure (last 30 days)** | Stacked column | Axis = `target_table`, Legend = `status`, Values = `Count of run_id` |
   | **Rows ingested per day** | Line chart | Axis = `start_time` (date), Values = `Sum of rows_copied` |

4. Save the report as `rpt_pipeline_monitoring` in the workspace.

> 💡 **Tip:** Pin the *Success vs Failure* visual to a dashboard and add a Data Activator rule on the count of `failed` rows to escalate beyond email when failures spike.

---

## 12. Best Practices (Lightweight)

Even in a simplified build, a few habits pay off:

- **Treat `audit_log` as a contract.** Never drop columns from it — only add. Downstream Power BI reports and alerts depend on its shape.
- **Wrap the Copy in an `If Condition`** for `Overwrite` vs `Append` if you also need an `If Condition` branch for format handling.
- **Use `@pipeline().RunId`** as the correlation ID in every audit row and every email subject.
- **Parameterize the connection** (or use **Workspace Identity**) so the same pipeline definition can be deployed across dev/test/prod.
- **Filter `is_active = true` in Lookup**, not in ForEach — it keeps the iteration set small.
- **Keep both `config_ingestion` and `audit_log` in the same Lakehouse** to avoid cross-item permission issues during early development.
- **Add an `OPTIMIZE audit_log` / VACUUM job** monthly once you cross a few hundred thousand audit rows.

---

## 13. Limitations of This Simplified Version

This tutorial gives you a usable audit, notification, and reporting baseline. It still deliberately omits the deeper production concerns that the [full `fabric-samples` framework](https://github.com/microsoft/fabric-samples/tree/main/community-samples/Metadata-driven%20Ingestion%20Framework) addresses:

- **Schema drift handling** — new/removed source columns are not detected.
- **Automatic incremental watermarks** — `load_mode = incremental` is declared but not enforced; you would need a `source_watermark_column` and a watermark table.
- **Rich audit fields** — `data_read`, `data_written`, `data_consistency_verification`, `event_triggered_by`, and lineage are not captured. Only the essentials (status, rows, duration, error) are.
- **Multi-channel notifications** — only Office 365 Outlook is wired; Teams, ServiceNow, and PagerDuty are not.
- **Advanced retry and SLA policies** — the Copy activity uses defaults only.
- **Multi-source connectors** — only ADLS Gen2 is wired up; SQL, S3, REST, and others are stubbed by design.
- **Environment promotion** — no dev/test/prod parameter file or deployment pipeline.

When you outgrow this baseline, graduate to the full framework — it extends the same Lookup → ForEach → Copy → Script skeleton you just built.

---

## 14. References

- Microsoft Fabric Community Blog — [*Demystifying data Ingestion in Fabric: fundamental components for a metadata-driven framework*](https://community.fabric.microsoft.com/t5/Fabric-Updates-Blog/Demystifying-data-Ingestion-in-Fabric-fundamental-components-for/ba-p/5173164)
- GitHub — [`microsoft/fabric-samples` — Metadata-driven Ingestion Framework](https://github.com/microsoft/fabric-samples/tree/main/community-samples/Metadata-driven%20Ingestion%20Framework)
- Microsoft Learn — [Microsoft Fabric Data Factory overview](https://learn.microsoft.com/fabric/data-factory/data-factory-overview)
- Microsoft Learn — [Lakehouse and Delta tables](https://learn.microsoft.com/fabric/data-engineering/lakehouse-overview)
- Microsoft Learn — [Pipeline expressions and functions](https://learn.microsoft.com/fabric/data-factory/expression-language)
- Microsoft Learn — [Copy activity in Fabric Data Factory](https://learn.microsoft.com/fabric/data-factory/copy-data-activity)
- Microsoft Learn — [Script activity in Data Factory](https://learn.microsoft.com/fabric/data-factory/script-activity)
- Microsoft Learn — [Office 365 Outlook activity](https://learn.microsoft.com/fabric/data-factory/office-365-outlook-activity)
- Microsoft Learn — [Data Activator alerts](https://learn.microsoft.com/fabric/data-activator/data-activator-introduction)

> ⚠️ **Disclaimer:** The Microsoft Fabric UI evolves frequently. If a menu, label, or property name differs from this tutorial, check the latest [Microsoft Learn documentation](https://learn.microsoft.com/fabric/) — the underlying pattern (Lookup → ForEach → Copy driven by a control table) remains the same.
