# Question 5 — Hostel Room Allocation

**Script:** [`q05_hostel.sql`](q05_hostel.sql) · **Schema:** `q05_hostel` · **DBMS:** PostgreSQL 14+ with pg_cron

## How to run

pgAdmin: open the Query Tool, open `q05_hostel.sql` and press **F5**. Results appear in *Data Output*; the test messages (`RAISE NOTICE`) appear in *Messages*.

```bash
psql -d ict371 -f q05_hostel.sql
```

The script drops and recreates the `q05_hostel` schema, so it can be run as many times as you like. Part (g) needs pg_cron (setup steps are in the [main README](../README.md#setting-up-pg_cron-part-g)).

## What each part does

| Part | Object | How it meets the requirement |
|------|--------|------------------------------|
| (a) Database & seed [6] | `students`, `rooms`, `allocations`, `occupancy_snapshot` | `capacity > 0`. Status ACTIVE/ENDED, plus `CHECK ((status='ACTIVE' AND released_on IS NULL) OR (status='ENDED' AND released_on IS NOT NULL))`. Seed rooms: A101 **full** (2/2), A102 **partly occupied** (1/3), A103 **empty** (it has only an ENDED history row). |
| (b) Function [6] | `fn_free_beds(p_room_id)` | `capacity − COUNT(ACTIVE)`. ENDED rows are ignored, so A103 still shows 2 free beds. An unknown room raises an error. |
| (c) Procedure [8] | `pr_allocate_room(p_student_id, p_room_id, p_allocated_on)` | Validates the IDs, checks the student has no ACTIVE allocation, checks a bed is free, then inserts ACTIVE with `released_on NULL`. It locks the room row against races. |
| (d) Trigger [8] | `trg_allocations_rules` (BEFORE INSERT OR UPDATE) | Repeats the capacity rule and the one-ACTIVE-per-student rule for **direct SQL**. When counting, it excludes the row being updated (`allocation_id <> NEW.allocation_id`). Tests: a direct insert into a full room, a second ACTIVE row by direct insert, and an UPDATE moving a student into a full room are all rejected. Editing a student's own row is allowed. |
| (e) View [5] | `v_room_occupancy` | `rooms LEFT JOIN allocations ON … AND status='ACTIVE'`. Putting the filter in `ON` (not `WHERE`) keeps rooms that have no allocations. |
| (f) Index [5] | `idx_allocations_active_room (room_id) WHERE status = 'ACTIVE'` | A partial index holding only current occupants. The ENDED history is excluded, so capacity checks stay fast as the years pass. |
| (g) Job [6] | `pr_refresh_occupancy()` + cron `55 23 * * *` | Copies the view into `occupancy_snapshot` for `CURRENT_DATE`. The primary key `(snapshot_date, room_id)` plus an upsert gives one row per date and room, and a rerun replaces the values. |

## Expected results (verified on PostgreSQL 16)

Free beds are 0 / 2 / 2. Every rule-breaking insert or update is rejected. After the second refresh today's snapshot is A101 2/0, A102 2/1, A103 0/2, with no duplicate rows.

Dates are written relative to `CURRENT_DATE`, so the views and summaries show data whenever the script is run.
