# Uploading Processed CSVs to Databricks

This guide shows how to move the cleaned NHS RTT CSVs produced by `data_processing.py` into Databricks and create Delta tables from them.

---

## Prerequisites

- Databricks Community Edition workspace (free tier is sufficient)
- Python ETL pipeline already run: `data/processed/` must contain the four `combined.csv` files
- SQL Warehouse running in your Databricks workspace

---

## Step 1 — Rename CSVs for upload

The Databricks FileStore path becomes part of the table definition. Rename the output files before uploading so the names match the SQL in `02_create_delta_tables.sql`.

| Local path | Upload as |
| --- | --- |
| `data/processed/incomplete/combined.csv` | `fact_rtt_incomplete.csv` |
| `data/processed/completed_admitted/combined.csv` | `fact_rtt_completed_admitted.csv` |
| `data/processed/completed_non_admitted/combined.csv` | `fact_rtt_completed_non_admitted.csv` |
| `data/processed/new_periods/combined.csv` | `fact_rtt_new_periods.csv` |

---

## Step 2 — Upload to Databricks FileStore

In your Databricks workspace:

1. Click **Data** in the left sidebar
2. Click **Add Data** → **Upload File**
3. Upload all four renamed CSV files one at a time
4. Each file lands at `/FileStore/tables/<filename>.csv`

Verify the uploads landed correctly by running this in the SQL Editor:

```sql
LIST '/FileStore/tables/';
```

You should see all four files listed.

---

## Step 3 — Run `02_create_delta_tables.sql`

Open the Databricks SQL Editor and run `02_create_delta_tables.sql` in full.

This creates the `nhs_waiting_list` database and converts each CSV into a Delta table. Delta format gives you:

- Faster queries than CSV
- ACID transactions
- Efficient predicate pushdown

Verify the tables exist:

```sql
USE nhs_waiting_list;
SHOW TABLES;
```

Expected output:

```text
fact_rtt_completed
fact_rtt_incomplete
fact_rtt_new_periods
```

---

## Step 4 — Run `03_create_gold_views.sql`

This creates the two analytical mart views (`v_monthly_summary` and `v_national_monthly`) that mirror the MySQL reporting layer.

Verify:

```sql
SHOW VIEWS IN nhs_waiting_list;
```

---

## Step 5 — Connect DbVisualizer

1. Open DbVisualizer
2. Create a new connection → **Databricks**
3. Enter your SQL Warehouse JDBC URL (from Databricks: SQL Warehouses → your warehouse → Connection Details → JDBC URL)
4. Enter your personal access token as the password
5. Test the connection

Once connected, run in DbVisualizer:

```sql
SHOW SCHEMAS;
USE nhs_waiting_list;
SHOW TABLES;
SELECT * FROM nhs_waiting_list.fact_rtt_incomplete LIMIT 10;
```

---

## Step 6 — Connect Power BI (optional)

1. Open Power BI Desktop
2. **Get Data** → **Azure Databricks**
3. Enter your Server hostname and HTTP path (from SQL Warehouse → Connection Details)
4. Choose **Import** mode for dashboards or **DirectQuery** for live data
5. Select `nhs_waiting_list.v_monthly_summary` and `nhs_waiting_list.v_national_monthly`

---

## Data volumes (approximate)

| Table | Rows (FY 2019/20 – 2024/25) |
| --- | --- |
| `fact_rtt_incomplete` | ~2.8 million |
| `fact_rtt_completed` | ~1.8 million |
| `fact_rtt_new_periods` | ~500 thousand |
