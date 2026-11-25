# Question 7 — Water Meter Readings and Billing

**Script:** [`q07_water.sql`](q07_water.sql) · **Schema:** `q07_water` · **DBMS:** PostgreSQL 14+ with pg_cron

## How to run

pgAdmin: open the Query Tool, open `q07_water.sql` and press **F5**. Results appear in *Data Output*; the test messages (`RAISE NOTICE`) appear in *Messages*.

```bash
psql -d ict371 -f q07_water.sql
```

The script drops and recreates the `q07_water` schema, so it can be run as many times as you like. Part (g) needs pg_cron (setup steps are in the [main README](../README.md#setting-up-pg_cron-part-g)).

## What each part does

| Part | Object | How it meets the requirement |
|------|--------|------------------------------|
| (a) Database & seed [6] | `customers`, `readings`, `bills`, `receivable_snapshot` | Meter values `>= 0`. `reading_month` must be a month start. `UNIQUE (customer_id, reading_month)`. `bills.reading_id` is UNIQUE. `CHECK (amount_paid BETWEEN 0 AND charge)`. Six readings cover **0 units, exactly 10, and above 10** (18, 25 and 10.5). |
| (b) Function [6] | `fn_water_charge(p_units)` | `LEAST(units,10)×5 + GREATEST(units−10,0)×8`, rounded to 2 dp. Results: 0→0.00, 10→50.00, 18→114.00, 10.5→54.00. NULL or negative input raises an error. |
| (c) Procedure [8] | `pr_generate_bill(p_reading_id, p_due_on)` | Works out consumption, calls the function and inserts the bill with `amount_paid = 0`. Rejects an unknown reading or one that already has a bill. |
| (d) Trigger [8] | `trg_readings_check_meter` (BEFORE INSERT OR UPDATE) | Raises an error when `current_reading < previous_reading`. Because it fires BEFORE the write, the bad row is never stored. The test shows a direct SQL import and an update both rejected, and the row count stays 6. |
| (e) View [5] | `v_overdue_bills` | Customer name, due date and outstanding amount (`charge − amount_paid`) where `due_on < CURRENT_DATE` and the bill is not fully paid. |
| (f) Index [5] | `idx_bills_unpaid_due_on (due_on) WHERE amount_paid < charge` | A partial index on unpaid bills only, in due-date order, so `due_on < today` is one short range scan over a small index. |
| (g) Job [6] | `pr_refresh_receivables()` + cron `30 0 * * *` | Total of all unpaid balances for `CURRENT_DATE`, upserted so a rerun replaces the value. |

## Expected results (verified on PostgreSQL 16)

Charges are 0 / 50 / 114 / 35 / 170 / 54. The overdue view shows bill 3 (K64) and bill 4 (K35). Receivables are K323.00.

Dates are written relative to `CURRENT_DATE`, so the views and summaries show data whenever the script is run.
