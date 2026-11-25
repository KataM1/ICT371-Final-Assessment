# Question 3 — Library Returns and Overdue Fines

**Script:** [`q03_library.sql`](q03_library.sql) · **Schema:** `q03_library` · **DBMS:** PostgreSQL 14+ with pg_cron

## How to run

pgAdmin: open the Query Tool, open `q03_library.sql` and press **F5**. Results appear in *Data Output*; the test messages (`RAISE NOTICE`) appear in *Messages*.

```bash
psql -d ict371 -f q03_library.sql
```

The script drops and recreates the `q03_library` schema, so it can be run as many times as you like. Part (g) needs pg_cron (setup steps are in the [main README](../README.md#setting-up-pg_cron-part-g)).

## What each part does

| Part | Object | How it meets the requirement |
|------|--------|------------------------------|
| (a) Database & seed [6] | `books`, `loans`, `loan_audit`, `overdue_summary` | `CHECK (due_on >= borrowed_on)` and `CHECK (returned_on IS NULL OR returned_on >= borrowed_on)`. Six loans with dates relative to today: two open overdue loans, one returned on the due date, one returned late, and two open loans not yet due. |
| (b) Function [6] | `fn_loan_fine(p_loan_id, p_as_of)` | `K2 × GREATEST(end − due_on, 0)`, where `end = LEAST(p_as_of, returned_on)` if the loan was returned, otherwise `p_as_of`. A returned loan stops growing (see the `fine_in_10_days` column). An unknown loan raises an error. |
| (c) Procedure [8] | `pr_return_loan(p_loan_id, p_returned_on)` | Rejects an unknown loan, an already returned loan, or a return before `borrowed_on`. Saves `returned_on` **and** `fine_amount` in one `UPDATE`. |
| (d) Trigger [8] | `trg_loans_returned_audit` (AFTER UPDATE, FOR EACH ROW) | Logs `OLD.returned_on` → `NEW.returned_on` only if they are `IS DISTINCT FROM` each other. Updating the borrower name, or setting the same date again, writes nothing. |
| (e) View [5] | `v_overdue_loans` | Unreturned loans with `due_on < CURRENT_DATE`: title, borrower, due date, days overdue and the fine as of today. |
| (f) Index [5] | `idx_loans_book_unreturned (book_id) WHERE returned_on IS NULL` | A **partial** index holds only open loans, so the growing returned history never bloats it. The query must include `returned_on IS NULL` to use it. |
| (g) Job [6] | `pr_refresh_overdue(p_as_of)` + cron `10 0 * * *` | Counts loans still unreturned as of the date (`returned_on IS NULL OR returned_on > p_as_of`) that are past due, and sums `fn_loan_fine(loan, p_as_of)`. An upsert keeps one row per `snapshot_date`. The job runs at 00:10 for `CURRENT_DATE`. |

## Expected results (verified on PostgreSQL 16)

Overdue loans are 1 (16 days, K32) and 5 (11 days, K22). The snapshot is 2 loans, K54.00. Only the two real returns appear in `loan_audit`.

Dates are written relative to `CURRENT_DATE`, so the views and summaries show data whenever the script is run.
