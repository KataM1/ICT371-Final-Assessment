/* =====================================================================
   ICT371 Advanced Database — Question 7: Water Meter Readings and Billing
   DBMS  : PostgreSQL 14+ (tested on PostgreSQL 16) with pg_cron
   Tariff: first 10 units K5 each, every unit above 10 K8 each, 0 units = K0.
   ===================================================================== */

DROP SCHEMA IF EXISTS q07_water CASCADE;
CREATE SCHEMA q07_water;
SET search_path TO q07_water, public;

/* ---------------------------------------------------------------------
   (a) DATABASE — tables  [6 marks]
   (current_reading >= previous_reading is enforced by the trigger in (d))
   --------------------------------------------------------------------- */
CREATE TABLE customers (
    customer_id  SERIAL       PRIMARY KEY,
    full_name    VARCHAR(100) NOT NULL
);

CREATE TABLE readings (
    reading_id        SERIAL        PRIMARY KEY,
    customer_id       INTEGER       NOT NULL REFERENCES customers(customer_id),
    reading_month     DATE          NOT NULL
        CONSTRAINT chk_reading_month_start CHECK (reading_month = date_trunc('month', reading_month)::date),
    previous_reading  NUMERIC(12,2) NOT NULL CHECK (previous_reading >= 0),
    current_reading   NUMERIC(12,2) NOT NULL CHECK (current_reading  >= 0),
    CONSTRAINT uq_reading_customer_month UNIQUE (customer_id, reading_month)
);

CREATE TABLE bills (
    bill_id      SERIAL        PRIMARY KEY,
    reading_id   INTEGER       NOT NULL UNIQUE REFERENCES readings(reading_id),
    charge       NUMERIC(12,2) NOT NULL CHECK (charge >= 0),
    amount_paid  NUMERIC(12,2) NOT NULL DEFAULT 0,
    due_on       DATE          NOT NULL,
    CONSTRAINT chk_amount_paid_range CHECK (amount_paid >= 0 AND amount_paid <= charge)
);

CREATE TABLE receivable_snapshot (
    snapshot_date  DATE          PRIMARY KEY,
    total_due      NUMERIC(14,2) NOT NULL DEFAULT 0
);

/* ---------------------------------------------------------------------
   (b) FUNCTION fn_water_charge(p_units)  [6 marks]
   Band 1 = LEAST(units,10) x 5 ;  Band 2 = GREATEST(units-10,0) x 8
   --------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql
SET search_path = q07_water, public
AS $$
BEGIN
    IF p_units IS NULL OR p_units < 0 THEN
        RAISE EXCEPTION 'Consumption must be zero or more (got %)', p_units USING ERRCODE = '22023';
    END IF;

    RETURN ROUND(LEAST(p_units, 10) * 5.00
               + GREATEST(p_units - 10, 0) * 8.00, 2)::NUMERIC(12,2);
END;
$$;

/* ---------------------------------------------------------------------
   (c) PROCEDURE pr_generate_bill(p_reading_id, p_due_on)  [8 marks]
   --------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id INTEGER, p_due_on DATE)
LANGUAGE plpgsql
SET search_path = q07_water, public
AS $$
DECLARE
    v_units   NUMERIC(12,2);
    v_charge  NUMERIC(12,2);
    v_bill_id INTEGER;
BEGIN
    IF p_due_on IS NULL THEN
        RAISE EXCEPTION 'Bill rejected: due date is required' USING ERRCODE = '22023';
    END IF;

    SELECT current_reading - previous_reading INTO v_units
    FROM readings
    WHERE reading_id = p_reading_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Bill rejected: reading % does not exist', p_reading_id USING ERRCODE = 'P0002';
    END IF;

    IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
        RAISE EXCEPTION 'Bill rejected: reading % already has a bill', p_reading_id USING ERRCODE = '23505';
    END IF;

    v_charge := fn_water_charge(v_units);

    INSERT INTO bills (reading_id, charge, amount_paid, due_on)
    VALUES (p_reading_id, v_charge, 0, p_due_on)
    RETURNING bill_id INTO v_bill_id;

    RAISE NOTICE 'Bill % created: reading %, % units, charge K%', v_bill_id, p_reading_id, v_units, v_charge;
END;
$$;

/* ---------------------------------------------------------------------
   (d) TRIGGER — BEFORE INSERT OR UPDATE on readings  [8 marks]
   Rejects current_reading < previous_reading. Because the exception is
   raised BEFORE the row is written, a rejected reading is never stored,
   whether it came from the app, a procedure or a direct SQL import.
   --------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION trg_fn_check_meter()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = q07_water, public
AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION 'Reading rejected: current % is below previous % (customer %, %)',
                        NEW.current_reading, NEW.previous_reading, NEW.customer_id, NEW.reading_month
              USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_readings_check_meter
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW
EXECUTE FUNCTION trg_fn_check_meter();

/* ---------------------------------------------------------------------
   (a) SEED DATA — 3 customers, 6 readings: 0 units, exactly 10, above 10
   M1 = two months ago, M2 = last month.
   --------------------------------------------------------------------- */
INSERT INTO customers (full_name) VALUES ('Mwila Banda'), ('Chanda Phiri'), ('Natasha Zulu');

INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
    (1, (date_trunc('month', CURRENT_DATE) - INTERVAL '2 months')::date, 1200.00, 1200.00),  -- 0 units
    (2, (date_trunc('month', CURRENT_DATE) - INTERVAL '2 months')::date,  850.00,  860.00),  -- exactly 10
    (3, (date_trunc('month', CURRENT_DATE) - INTERVAL '2 months')::date,  400.00,  418.00),  -- 18 units
    (1, (date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date,  1200.00, 1207.00),  -- 7 units
    (2, (date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date,   860.00,  885.00),  -- 25 units
    (3, (date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date,   418.00,  428.50);  -- 10.5 units

-- generate all six bills through the procedure
CALL pr_generate_bill(1, CURRENT_DATE - 25);
CALL pr_generate_bill(2, CURRENT_DATE - 25);
CALL pr_generate_bill(3, CURRENT_DATE - 25);
CALL pr_generate_bill(4, CURRENT_DATE - 2);
CALL pr_generate_bill(5, CURRENT_DATE + 5);
CALL pr_generate_bill(6, CURRENT_DATE + 5);

-- some payments: bill 2 fully paid, bill 3 partly paid
UPDATE bills SET amount_paid = charge  WHERE bill_id = 2;
UPDATE bills SET amount_paid = 50.00   WHERE bill_id = 3;

SELECT r.reading_id, r.customer_id, r.reading_month,
       r.current_reading - r.previous_reading AS units,
       b.bill_id, b.charge, b.amount_paid, b.due_on
FROM readings r JOIN bills b ON b.reading_id = r.reading_id
ORDER BY r.reading_id;

/* ---------------------------------------------------------------------
   TESTS for (b), (c), (d)
   --------------------------------------------------------------------- */
SELECT fn_water_charge(0)    AS zero_units,     -- 0.00
       fn_water_charge(10)   AS ten_units,      -- 50.00
       fn_water_charge(18)   AS eighteen_units, -- 50 + 64 = 114.00
       fn_water_charge(10.5) AS ten_point_five; -- 50 + 4  = 54.00

DO $$
BEGIN
    BEGIN PERFORM fn_water_charge(NULL);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'fn_water_charge(NULL) -> %', SQLERRM; END;
    BEGIN PERFORM fn_water_charge(-3);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'fn_water_charge(-3)   -> %', SQLERRM; END;
    BEGIN CALL pr_generate_bill(999, CURRENT_DATE + 10);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Unknown reading       -> %', SQLERRM; END;
    BEGIN CALL pr_generate_bill(5, CURRENT_DATE + 10);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Already billed        -> %', SQLERRM; END;
    -- (d) direct SQL import with a meter going backwards
    BEGIN INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading)
          VALUES (1, date_trunc('month', CURRENT_DATE)::date, 1207.00, 1100.00);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Backwards INSERT      -> %', SQLERRM; END;
    BEGIN UPDATE readings SET current_reading = 100.00 WHERE reading_id = 6;
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Backwards UPDATE      -> %', SQLERRM; END;
END $$;

SELECT COUNT(*) AS readings_still_6 FROM readings;   -- rejected reading was not stored

/* ---------------------------------------------------------------------
   (e) VIEW v_overdue_bills  [5 marks]
   --------------------------------------------------------------------- */
CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT b.bill_id,
       c.full_name               AS customer_name,
       r.reading_month,
       b.due_on,
       b.charge,
       b.amount_paid,
       b.charge - b.amount_paid  AS outstanding_amount
FROM   bills b
JOIN   readings  r ON r.reading_id  = b.reading_id
JOIN   customers c ON c.customer_id = r.customer_id
WHERE  b.due_on < CURRENT_DATE
AND    b.amount_paid < b.charge;

SELECT * FROM v_overdue_bills ORDER BY due_on, bill_id;
-- bill 1 (K0 charge) counts as fully paid and bill 2 is paid, so both are excluded;
-- bill 3 owes K64 and bill 4 owes K35

/* ---------------------------------------------------------------------
   (f) INDEX — date-based search for overdue (unpaid) bills  [5 marks]
   Justification: a PARTIAL index on due_on that only contains bills not
   yet fully paid. Paid bills (most of the history) are left out, so the
   index is small, and the due_on order lets "due_on < today" be a single
   range scan.
   --------------------------------------------------------------------- */
CREATE INDEX idx_bills_unpaid_due_on ON bills (due_on) WHERE amount_paid < charge;
ANALYZE bills;

EXPLAIN
SELECT bill_id, reading_id, charge - amount_paid AS outstanding, due_on
FROM   bills
WHERE  due_on < CURRENT_DATE
AND    amount_paid < charge;

BEGIN;
SET LOCAL enable_seqscan = off;
EXPLAIN ANALYZE
SELECT bill_id, reading_id, charge - amount_paid AS outstanding, due_on
FROM   bills
WHERE  due_on < CURRENT_DATE
AND    amount_paid < charge;
COMMIT;

/* ---------------------------------------------------------------------
   (g) SCHEDULED JOB — pr_refresh_receivables()  [6 marks]
   Total of ALL unpaid balances today (overdue or not), one row per date.
   --------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql
SET search_path = q07_water, public
AS $$
BEGIN
    INSERT INTO receivable_snapshot (snapshot_date, total_due)
    SELECT CURRENT_DATE, COALESCE(SUM(charge - amount_paid), 0)
    FROM   bills
    WHERE  amount_paid < charge
    ON CONFLICT (snapshot_date) DO UPDATE
       SET total_due = EXCLUDED.total_due;

    RAISE NOTICE 'receivable_snapshot refreshed for %', CURRENT_DATE;
END;
$$;

CALL pr_refresh_receivables();
CALL pr_refresh_receivables();   -- rerun: still one row (64 + 35 + 170 + 54 = K323.00)
SELECT * FROM receivable_snapshot;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'q07_refresh_receivables',
    '30 0 * * *',                                  -- 00:30 every day
    $$CALL q07_water.pr_refresh_receivables()$$
);

SELECT jobid, jobname, schedule, command, active
FROM cron.job WHERE jobname = 'q07_refresh_receivables';
