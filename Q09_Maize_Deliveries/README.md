# Question 9 — Farmer Cooperative Maize Deliveries

**Script:** [`q09_maize.sql`](q09_maize.sql) · **Schema:** `q09_maize` · **DBMS:** PostgreSQL 14+ with pg_cron

## How to run

pgAdmin: open the Query Tool, open `q09_maize.sql` and press **F5**. Results appear in *Data Output*; the test messages (`RAISE NOTICE`) appear in *Messages*.

```bash
psql -d ict371 -f q09_maize.sql
```

The script drops and recreates the `q09_maize` schema, so it can be run as many times as you like. Part (g) needs pg_cron (setup steps are in the [main README](../README.md#setting-up-pg_cron-part-g)).

## What each part does

| Part | Object | How it meets the requirement |
|------|--------|------------------------------|
| (a) Database & seed [6] | `farmers`, `deliveries`, `daily_purchases` | NUMERIC weight and money columns, `grade` CHECK A/B/C, `is_paid BOOLEAN`. Six deliveries **loaded after the trigger** cover grades A, B and C, paid and unpaid. One is a direct SQL insert with a deliberately wrong rate, which the trigger corrects. |
| (b) Function [6] | `fn_maize_rate(p_grade)` | A→5.00, B→4.00, C→3.00. NULL or any other grade raises an error. |
| (c) Procedure [8] | `pr_receive_delivery(p_farmer_id, p_grade, p_weight, p_date)` | Rejects an unknown farmer, weight ≤ 0, a NULL date or a bad grade. Inserts only the basic fields with `is_paid = FALSE`. `unit_rate` and `total_value` come from the trigger. |
| (d) Trigger [8] | `trg_deliveries_pricing` (BEFORE INSERT OR UPDATE) | Rejects non-positive weight, sets `NEW.unit_rate := fn_maize_rate(NEW.grade)` and `NEW.total_value := weight × rate`. Any rate or value sent by direct SQL is overwritten, and re-grading on UPDATE recalculates the value. |
| (e) View [5] | `v_farmer_amount_due` | `farmers LEFT JOIN deliveries ON … AND is_paid = FALSE` with `COALESCE(SUM, 0)`, so a farmer with nothing unpaid still shows **0.00**. |
| (f) Index [5] | `idx_deliveries_farmer_date (farmer_id, delivered_on)` | Composite index: farmer (=) then date (range), which matches 'a farmer's deliveries between two dates'. |
| (g) Job [6] | `pr_refresh_purchases(p_day)` + cron `30 1 * * *` | Upserts that day's total weight and value, so a rerun replaces rather than adds. The job runs at 01:30 for the previous day. |

## Expected results (verified on PostgreSQL 16)

The direct insert at rate 99 is stored as rate 5.00 and value K1 000.00. Amounts due are 3 761.50 / 5 000.00 / 0.00. Yesterday's purchases are 1 720.50 kg and K7 161.50.

Dates are written relative to `CURRENT_DATE`, so the views and summaries show data whenever the script is run.
