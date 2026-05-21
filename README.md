# Metadata-Driven Ingestion Pipeline on Microsoft Fabric

End-to-end tutorial for building a **metadata-driven data ingestion pipeline** in Microsoft Fabric — read source list from a config table, loop, copy CSV files from ADLS Gen2 into Lakehouse Delta tables, log every run, and email success/failure summaries.

## Contents

- **[Tutorial-Metadata-Driven-Pipeline-Fabric.md](Tutorial-Metadata-Driven-Pipeline-Fabric.md)** — full 14-section walkthrough.
- **[warehouse/create-metadata-and-audit-tables.sql](warehouse/create-metadata-and-audit-tables.sql)** — one-click T-SQL script to provision `config_ingestion` and `audit_log` in a Fabric Warehouse.
- **[pipeline/pl_metadata_ingest.json](pipeline/pl_metadata_ingest.json)** — pipeline JSON ready to paste into Fabric's *Edit JSON code* dialog.
- **[sample-data/](sample-data/)** — three small CSV files (`customers.csv`, `orders.csv`, `products.csv`) for the tutorial. All data is fictional and uses `@example.com` addresses.

## Prerequisites

- Microsoft Fabric workspace with **Contributor** role, capacity **F2+** (or trial).
- Azure Data Lake Storage Gen2 account for source files.
- Office 365 mailbox for the optional Outlook notification step.

## Quick start

1. In your Fabric workspace, create a Lakehouse named `lh_ingestion_demo` and a Warehouse named `wh_ingestion_demo`.
2. Upload the three CSVs from [sample-data/](sample-data/) into a `raw/sales/` folder in your ADLS Gen2 container.
3. In `wh_ingestion_demo`, open **New SQL query**, paste [warehouse/create-metadata-and-audit-tables.sql](warehouse/create-metadata-and-audit-tables.sql), and **Run**.
4. Create a new Data pipeline `pl_metadata_ingest`, open *Edit JSON code*, paste the contents of [pipeline/pl_metadata_ingest.json](pipeline/pl_metadata_ingest.json), and replace the `<PLACEHOLDER>` connection / workspace / lakehouse IDs.
5. Follow [Tutorial-Metadata-Driven-Pipeline-Fabric.md](Tutorial-Metadata-Driven-Pipeline-Fabric.md) for the full walkthrough, monitoring, and Power BI reporting steps.

## License

MIT — see source for details. Sample data is fictional and provided for educational use only.
