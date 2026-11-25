# Question 1 — Pharmacy Stock and Daily Sales

**Script:** [`q01_pharmacy.sql`](q01_pharmacy.sql) · **Schema:** `q01_pharmacy` · **DBMS:** PostgreSQL 14+ with pg_cron

## How to run

pgAdmin: open the Query Tool, open `q01_pharmacy.sql` and press **F5**. Results appear in *Data Output*; the test messages (`RAISE NOTICE`) appear in *Messages*.

```bash
psql -d ict371 -f q01_pharmacy.sql
```

The script drops and recreates the `q01_pharmacy` schema, so it can be run as many times as you like. Part (g) needs pg_cron (setup steps are in the [main README](../README.md#setting-up-pg_cron-part-g)).

## What each part does

| Part | Object | How it meets the requirement |
|------|--------|------------------------------|
| (a) Database & seed [6] | `medicines`, `sales`, `stock_audit`, `daily_sales` | CHECK constraints: `unit_price > 0`, `stock_qty >= 0`, `quantity > 0`. Three medicines are created, then six sales are loaded **through `pr_record_sale`**, so stock and audit stay consistent. |
| (b) Function [6] | `fn_sale_value(p_medicine_id, p_quantity)` | Returns the current `unit_price × quantity`, rounded to 2 dp. Raises an error for a NULL/zero/negative quantity or an unknown medicine. |
| (c) Procedure [8] | `pr_record_sale(p_medicine_id, p_quantity, p_sold_on)` | Locks the medicine row (`FOR UPDATE`), checks stock, runs **one** `UPDATE` to deduct stock, and stores the price in force at that moment in `sales.unit_price`. Any `RAISE EXCEPTION` rolls back the whole `CALL`, so an invalid sale changes neither table. The test prints the row counts before and after to prove it. |
| (d) Trigger [8] | `trg_medicines_stock_audit` (AFTER UPDATE OF stock_qty, FOR EACH ROW) | `WHEN (OLD.stock_qty IS DISTINCT FROM NEW.stock_qty)` means a row is logged only when stock really changes. Price-only updates, or setting stock to the same value, write nothing. |
| (e) View [5] | `v_low_stock` | Name, price and remaining stock where `stock_qty < 10`. Queried before and after a sale; Cough Syrup appears once it drops to 8. |
| (f) Index [5] | `idx_sales_medicine_soldon (medicine_id, sold_on)` | Equality column first, range column second, so the index jumps to one medicine and reads only the date slice. Plain `EXPLAIN` and forced-index `EXPLAIN ANALYZE` are both shown. |
| (g) Job [6] | `pr_refresh_sales(p_day)` + cron `15 0 * * *` | `INSERT … ON CONFLICT (sales_date) DO UPDATE` **replaces** the day's totals, so reruns never duplicate or double-count. The job runs at 00:15 daily for `CURRENT_DATE - 1`. |

## Expected results (verified on PostgreSQL 16)

Stock ends at 64 / 21 / 8. Oversell, unknown-medicine and negative-quantity sales are rejected and the row counts stay the same. Yesterday's summary is 23 units, K155.00, before and after a rerun.

Dates are written relative to `CURRENT_DATE`, so the views and summaries show data whenever the script is run.
