/* =====================================================================
   ICT371 Advanced Database — Question 5: Hostel Room Allocation
   DBMS : PostgreSQL 14+ (tested on PostgreSQL 16) with pg_cron
   Rules: never exceed room capacity; one ACTIVE allocation per student;
          ENDED allocations are history and do not occupy beds.
   ===================================================================== */

DROP SCHEMA IF EXISTS q05_hostel CASCADE;
CREATE SCHEMA q05_hostel;
SET search_path TO q05_hostel, public;

/* ---------------------------------------------------------------------
   (a) DATABASE — tables  [6 marks]
   --------------------------------------------------------------------- */
CREATE TABLE students (
    student_id      SERIAL       PRIMARY KEY,
    student_number  VARCHAR(20)  NOT NULL UNIQUE,
    full_name       VARCHAR(100) NOT NULL
);

CREATE TABLE rooms (
    room_id      SERIAL      PRIMARY KEY,
    room_number  VARCHAR(10) NOT NULL UNIQUE,
    capacity     INTEGER     NOT NULL CONSTRAINT chk_capacity_positive CHECK (capacity > 0)
);

CREATE TABLE allocations (
    allocation_id  SERIAL      PRIMARY KEY,
    student_id     INTEGER     NOT NULL REFERENCES students(student_id),
    room_id        INTEGER     NOT NULL REFERENCES rooms(room_id),
    allocated_on   DATE        NOT NULL,
    released_on    DATE        NULL,
    status         VARCHAR(6)  NOT NULL DEFAULT 'ACTIVE'
        CONSTRAINT chk_alloc_status CHECK (status IN ('ACTIVE', 'ENDED')),
    -- ACTIVE  => released_on must be NULL;  ENDED => release date required
    CONSTRAINT chk_status_release CHECK (
        (status = 'ACTIVE' AND released_on IS NULL) OR
        (status = 'ENDED'  AND released_on IS NOT NULL)),
    CONSTRAINT chk_release_after_alloc CHECK (released_on IS NULL OR released_on >= allocated_on)
);

CREATE TABLE occupancy_snapshot (
    snapshot_date  DATE    NOT NULL,
    room_id        INTEGER NOT NULL REFERENCES rooms(room_id),
    occupied_beds  INTEGER NOT NULL CHECK (occupied_beds >= 0),
    free_beds      INTEGER NOT NULL CHECK (free_beds >= 0),
    PRIMARY KEY (snapshot_date, room_id)
);

/* ---------------------------------------------------------------------
   (b) FUNCTION fn_free_beds(p_room_id)  [6 marks]
   capacity minus ACTIVE allocations only (ENDED rows are ignored).
   --------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INTEGER)
RETURNS INTEGER
LANGUAGE plpgsql
SET search_path = q05_hostel, public
AS $$
DECLARE
    v_capacity rooms.capacity%TYPE;
    v_active   INTEGER;
BEGIN
    SELECT capacity INTO v_capacity FROM rooms WHERE room_id = p_room_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Room % does not exist', p_room_id USING ERRCODE = 'P0002';
    END IF;

    SELECT COUNT(*) INTO v_active
    FROM allocations
    WHERE room_id = p_room_id
    AND   status  = 'ACTIVE';

    RETURN v_capacity - v_active;
END;
$$;

/* ---------------------------------------------------------------------
   (c) PROCEDURE pr_allocate_room(p_student_id, p_room_id, p_allocated_on)  [8 marks]
   --------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE pr_allocate_room(
    p_student_id   INTEGER,
    p_room_id      INTEGER,
    p_allocated_on DATE DEFAULT CURRENT_DATE
)
LANGUAGE plpgsql
SET search_path = q05_hostel, public
AS $$
DECLARE
    v_id INTEGER;
BEGIN
    IF p_allocated_on IS NULL THEN
        RAISE EXCEPTION 'Allocation rejected: allocation date is required' USING ERRCODE = '22023';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM students WHERE student_id = p_student_id) THEN
        RAISE EXCEPTION 'Allocation rejected: student % does not exist', p_student_id USING ERRCODE = 'P0002';
    END IF;

    -- lock the room so two wardens cannot fill the last bed at the same time
    PERFORM 1 FROM rooms WHERE room_id = p_room_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Allocation rejected: room % does not exist', p_room_id USING ERRCODE = 'P0002';
    END IF;

    IF EXISTS (SELECT 1 FROM allocations
               WHERE student_id = p_student_id AND status = 'ACTIVE') THEN
        RAISE EXCEPTION 'Allocation rejected: student % already has an ACTIVE allocation', p_student_id
              USING ERRCODE = 'P0001';
    END IF;

    IF fn_free_beds(p_room_id) <= 0 THEN
        RAISE EXCEPTION 'Allocation rejected: room % is full', p_room_id USING ERRCODE = 'P0001';
    END IF;

    INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
    VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE')
    RETURNING allocation_id INTO v_id;

    RAISE NOTICE 'Allocation % created: student % -> room %', v_id, p_student_id, p_room_id;
END;
$$;

/* ---------------------------------------------------------------------
   (d) TRIGGER — BEFORE INSERT OR UPDATE: capacity + one ACTIVE per student  [8 marks]
   Protects direct SQL too. When counting other allocations the row being
   updated is excluded (allocation_id <> NEW.allocation_id), so a harmless
   edit of an existing ACTIVE row is not counted twice.
   --------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION trg_fn_allocation_rules()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = q05_hostel, public
AS $$
DECLARE
    v_capacity  INTEGER;
    v_others    INTEGER;
BEGIN
    -- ENDED rows never occupy a bed, so nothing to check
    IF NEW.status <> 'ACTIVE' THEN
        RETURN NEW;
    END IF;

    SELECT capacity INTO v_capacity
    FROM rooms WHERE room_id = NEW.room_id
    FOR UPDATE;                           -- serialise changes to the same room

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Room % does not exist', NEW.room_id USING ERRCODE = '23503';
    END IF;

    -- 1) capacity: other ACTIVE rows already in this room
    SELECT COUNT(*) INTO v_others
    FROM   allocations
    WHERE  room_id = NEW.room_id
    AND    status  = 'ACTIVE'
    AND    (TG_OP = 'INSERT' OR allocation_id <> NEW.allocation_id);

    IF v_others >= v_capacity THEN
        RAISE EXCEPTION 'Room % is full (capacity %)', NEW.room_id, v_capacity USING ERRCODE = 'P0001';
    END IF;

    -- 2) one ACTIVE allocation per student
    IF EXISTS (SELECT 1
               FROM   allocations
               WHERE  student_id = NEW.student_id
               AND    status = 'ACTIVE'
               AND    (TG_OP = 'INSERT' OR allocation_id <> NEW.allocation_id)) THEN
        RAISE EXCEPTION 'Student % already has an ACTIVE allocation', NEW.student_id
              USING ERRCODE = 'P0001';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_allocations_rules
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW
EXECUTE FUNCTION trg_fn_allocation_rules();

/* ---------------------------------------------------------------------
   (a) SEED DATA — rooms that end up FULL, PARTLY occupied and EMPTY
   --------------------------------------------------------------------- */
INSERT INTO rooms (room_number, capacity) VALUES
    ('A101', 2),    -- will be FULL
    ('A102', 3),    -- will be PARTLY occupied (1 of 3)
    ('A103', 2);    -- will be EMPTY (only an ENDED history row)

INSERT INTO students (student_number, full_name) VALUES
    ('2024020001', 'Mwila Banda'),
    ('2024020002', 'Chanda Phiri'),
    ('2024020003', 'Natasha Zulu'),
    ('2024020004', 'Kondwani Tembo'),
    ('2024020005', 'Lubuto Sakala');

-- history: Kondwani lived in A103 last term (ENDED, so it frees the bed)
INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
VALUES (4, 3, DATE '2026-01-15', DATE '2026-06-30', 'ENDED');

CALL pr_allocate_room(1, 1, CURRENT_DATE - 60);
CALL pr_allocate_room(2, 1, CURRENT_DATE - 60);   -- A101 now FULL
CALL pr_allocate_room(3, 2, CURRENT_DATE - 30);   -- A102 1 of 3

SELECT * FROM allocations ORDER BY allocation_id;

/* ---------------------------------------------------------------------
   TESTS for (b), (c), (d)
   --------------------------------------------------------------------- */
SELECT room_id, room_number, capacity, fn_free_beds(room_id) AS free_beds
FROM rooms ORDER BY room_id;      -- 0, 2, 2  (ENDED row does not reduce A103)

DO $$
BEGIN
    BEGIN PERFORM fn_free_beds(99);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'fn_free_beds(99)       -> %', SQLERRM; END;
    BEGIN CALL pr_allocate_room(5, 1, CURRENT_DATE);                 -- room full
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Full room (procedure)  -> %', SQLERRM; END;
    BEGIN CALL pr_allocate_room(1, 2, CURRENT_DATE);                 -- already ACTIVE
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Second ACTIVE (proc)   -> %', SQLERRM; END;
    BEGIN CALL pr_allocate_room(99, 2, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Unknown student        -> %', SQLERRM; END;
    BEGIN CALL pr_allocate_room(5, 99, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Unknown room           -> %', SQLERRM; END;
    -- direct SQL that skips the procedure is still stopped by the trigger
    BEGIN INSERT INTO allocations (student_id, room_id, allocated_on) VALUES (5, 1, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Full room (direct SQL) -> %', SQLERRM; END;
    BEGIN INSERT INTO allocations (student_id, room_id, allocated_on) VALUES (3, 3, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE '2nd ACTIVE (direct)    -> %', SQLERRM; END;
    BEGIN UPDATE allocations SET room_id = 1 WHERE student_id = 3 AND status = 'ACTIVE';
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Move into full room    -> %', SQLERRM; END;
END $$;

-- allowed: editing Natasha's own ACTIVE row does not count her twice
UPDATE allocations SET allocated_on = allocated_on + 1 WHERE student_id = 3 AND status = 'ACTIVE';
SELECT COUNT(*) AS allocations_total FROM allocations;    -- still 4

/* ---------------------------------------------------------------------
   (e) VIEW v_room_occupancy — every room, even with no allocations  [5 marks]
   --------------------------------------------------------------------- */
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT r.room_id,
       r.room_number,
       r.capacity,
       COUNT(a.allocation_id)              AS occupied_beds,
       r.capacity - COUNT(a.allocation_id) AS free_beds
FROM   rooms r
LEFT JOIN allocations a
       ON a.room_id = r.room_id
      AND a.status  = 'ACTIVE'            -- condition in ON keeps empty rooms
GROUP BY r.room_id, r.room_number, r.capacity;

SELECT * FROM v_room_occupancy ORDER BY room_number;

/* ---------------------------------------------------------------------
   (f) INDEX — ACTIVE allocations filtered by room_id  [5 marks]
   Justification: a PARTIAL index on room_id WHERE status = 'ACTIVE' stores
   only current occupants. ENDED history grows every term but is never in
   this index, so capacity checks and the view stay fast over the years.
   --------------------------------------------------------------------- */
CREATE INDEX idx_allocations_active_room ON allocations (room_id) WHERE status = 'ACTIVE';
ANALYZE allocations;

EXPLAIN
SELECT allocation_id, student_id, allocated_on
FROM   allocations
WHERE  room_id = 1
AND    status = 'ACTIVE';

BEGIN;
SET LOCAL enable_seqscan = off;
EXPLAIN ANALYZE
SELECT allocation_id, student_id, allocated_on
FROM   allocations
WHERE  room_id = 1
AND    status = 'ACTIVE';
COMMIT;

/* ---------------------------------------------------------------------
   (g) SCHEDULED JOB — pr_refresh_occupancy()  [6 marks]
   One row per (date, room); a rerun on the same date replaces the values.
   --------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql
SET search_path = q05_hostel, public
AS $$
BEGIN
    INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
    SELECT CURRENT_DATE, room_id, occupied_beds, free_beds
    FROM   v_room_occupancy
    ON CONFLICT (snapshot_date, room_id) DO UPDATE
       SET occupied_beds = EXCLUDED.occupied_beds,
           free_beds     = EXCLUDED.free_beds;

    RAISE NOTICE 'occupancy_snapshot refreshed for %', CURRENT_DATE;
END;
$$;

CALL pr_refresh_occupancy();
CALL pr_allocate_room(5, 2, CURRENT_DATE);   -- occupancy changes during the day
CALL pr_refresh_occupancy();                 -- rerun replaces today's values (no duplicates)
SELECT * FROM occupancy_snapshot ORDER BY snapshot_date, room_id;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'q05_refresh_occupancy',
    '55 23 * * *',                               -- 23:55 every day
    $$CALL q05_hostel.pr_refresh_occupancy()$$
);

SELECT jobid, jobname, schedule, command, active
FROM cron.job WHERE jobname = 'q05_refresh_occupancy';
