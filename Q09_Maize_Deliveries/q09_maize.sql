/* =====================================================================
   ICT371 Advanced Database — Question 9: Farmer Cooperative Maize Deliveries
   DBMS  : PostgreSQL 14+ (tested on PostgreSQL 16) with pg_cron
   Prices: grade A K5/kg, grade B K4/kg, grade C K3/kg. Values must be
           calculated the same way even for direct SQL inserts.
   ===================================================================== */

DROP SCHEMA IF EXISTS q09_maize CASCADE;
CREATE SCHEMA q09_maize;
SET search_path TO q09_maize, public;

/* ---------------------------------------------------------------------
   (a) DATABASE — tables  [6 marks]
   unit_rate / total_value are NOT NULL; the trigger in (d) fills them.
   --------------------------------------------------------------------- */
CREATE TABLE farmers (
    farmer_id      SERIAL       PRIMARY KEY,
    farmer_number  VARCHAR(20)  NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE deliveries (
    delivery_id   SERIAL        PRIMARY KEY,
    farmer_id     INTEGER       NOT NULL REFERENCES farmers(farmer_id),
    grade         CHAR(1)       NOT NULL CHECK (grade IN ('A', 'B', 'C')),
    weight_kg     NUMERIC(10,2) NOT NULL CHECK (weight_kg > 0),
    unit_rate     NUMERIC(8,2)  NOT NULL CHECK (unit_rate > 0),
    total_value   NUMERIC(14,2) NOT NULL CHECK (total_value >= 0),
    delivered_on  DATE          NOT NULL DEFAULT CURRENT_DATE,
    is_paid       BOOLEAN       NOT NULL DEFAULT FALSE
);

CREATE TABLE daily_purchases (
    purchase_date  DATE          PRIMARY KEY,
    total_weight   NUMERIC(14,2) NOT NULL DEFAULT 0,
    total_value    NUMERIC(16,2) NOT NULL DEFAULT 0
);

/* ---------------------------------------------------------------------
   (b) FUNCTION fn_maize_rate(p_grade)  [6 marks]
   --------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade TEXT)
RETURNS NUMERIC
LANGUAGE plpgsql
SET search_path = q09_maize, public
AS $$
BEGIN
    IF p_grade IS NULL THEN
        RAISE EXCEPTION 'Grade is required' USING ERRCODE = '22023';
    END IF;

    CASE upper(trim(p_grade))
        WHEN 'A' THEN RETURN 5.00;
        WHEN 'B' THEN RETURN 4.00;
        WHEN 'C' THEN RETURN 3.00;
        ELSE
            RAISE EXCEPTION 'Unsupported maize grade "%" (use A, B or C)', p_grade USING ERRCODE = '22023';
    END CASE;
END;
$$;

/* ---------------------------------------------------------------------
   (c) PROCEDURE pr_receive_delivery(p_farmer_id, p_grade, p_weight, p_date)  [8 marks]
   Inserts only the basic fields with is_paid = FALSE. It deliberately does
   NOT supply unit_rate / total_value — the trigger does that.
   --------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE pr_receive_delivery(
    p_farmer_id INTEGER,
    p_grade     TEXT,
    p_weight    NUMERIC,
    p_date      DATE DEFAULT CURRENT_DATE
)
LANGUAGE plpgsql
SET search_path = q09_maize, public
AS $$
DECLARE
    v_id    INTEGER;
    v_value NUMERIC;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM farmers WHERE farmer_id = p_farmer_id) THEN
        RAISE EXCEPTION 'Delivery rejected: farmer % does not exist', p_farmer_id USING ERRCODE = 'P0002';
    END IF;

    IF p_weight IS NULL OR p_weight <= 0 THEN
        RAISE EXCEPTION 'Delivery rejected: weight must be greater than zero (got %)', p_weight
              USING ERRCODE = '22023';
    END IF;

    IF p_date IS NULL THEN
        RAISE EXCEPTION 'Delivery rejected: delivery date is required' USING ERRCODE = '22023';
    END IF;

    PERFORM fn_maize_rate(p_grade);          -- rejects NULL / unsupported grades early

    INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
    VALUES (p_farmer_id, upper(trim(p_grade)), p_weight, p_date, FALSE)
    RETURNING delivery_id, total_value INTO v_id, v_value;

    RAISE NOTICE 'Delivery % received: farmer %, grade %, % kg, value K%',
                 v_id, p_farmer_id, upper(trim(p_grade)), p_weight, v_value;
END;
$$;

/* ---------------------------------------------------------------------
   (d) TRIGGER — BEFORE INSERT OR UPDATE: pricing rule  [8 marks]
   Whatever rate/value a direct INSERT or UPDATE tries to supply is
   overwritten, so every row follows the same pricing rule.
   --------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION trg_fn_price_delivery()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = q09_maize, public
AS $$
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        RAISE EXCEPTION 'Weight must be greater than zero (got %)', NEW.weight_kg USING ERRCODE = '23514';
    END IF;

    NEW.grade       := upper(trim(NEW.grade));
    NEW.unit_rate   := fn_maize_rate(NEW.grade);
    NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);
    RETURN NEW;          -- BEFORE trigger: the modified NEW row is what gets stored
END;
$$;

CREATE TRIGGER trg_deliveries_pricing
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW
EXECUTE FUNCTION trg_fn_price_delivery();

/* ---------------------------------------------------------------------
   (a) SEED DATA — loaded AFTER the trigger: 3 farmers, 6 deliveries,
   all grades, paid and unpaid.
   --------------------------------------------------------------------- */
INSERT INTO farmers (farmer_number, full_name) VALUES
    ('MKF-001', 'Mwila Banda'),
    ('MKF-002', 'Chanda Phiri'),
    ('MKF-003', 'Natasha Zulu');

CALL pr_receive_delivery(1, 'A', 500.00, CURRENT_DATE - 2);
CALL pr_receive_delivery(2, 'B', 750.00, CURRENT_DATE - 2);
CALL pr_receive_delivery(3, 'C', 300.00, CURRENT_DATE - 1);
CALL pr_receive_delivery(1, 'B', 420.50, CURRENT_DATE - 1);
CALL pr_receive_delivery(2, 'A', 1000.00, CURRENT_DATE - 1);

-- direct SQL with a WRONG rate and value: the trigger corrects them
INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on)
VALUES (3, 'a', 200.00, 99.00, 1.00, CURRENT_DATE);

-- payments: Natasha is fully paid; Chanda's grade B load is paid
UPDATE deliveries SET is_paid = TRUE WHERE farmer_id = 3;
UPDATE deliveries SET is_paid = TRUE WHERE farmer_id = 2 AND grade = 'B';

SELECT * FROM deliveries ORDER BY delivery_id;   -- row 6: grade A, rate 5.00, value 1000.00

/* ---------------------------------------------------------------------
   TESTS for (b), (c), (d)
   --------------------------------------------------------------------- */
SELECT fn_maize_rate('A') AS a, fn_maize_rate('B') AS b, fn_maize_rate('C') AS c;

DO $$
BEGIN
    BEGIN PERFORM fn_maize_rate(NULL);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'fn_maize_rate(NULL)  -> %', SQLERRM; END;
    BEGIN PERFORM fn_maize_rate('D');
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'fn_maize_rate(D)     -> %', SQLERRM; END;
    BEGIN CALL pr_receive_delivery(99, 'A', 100, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Unknown farmer       -> %', SQLERRM; END;
    BEGIN CALL pr_receive_delivery(1, 'Z', 100, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Bad grade            -> %', SQLERRM; END;
    BEGIN CALL pr_receive_delivery(1, 'A', 0, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Zero weight (proc)   -> %', SQLERRM; END;
    BEGIN INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value)
          VALUES (1, 'A', -50, 5, -250);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Negative weight (SQL)-> %', SQLERRM; END;
END $$;

-- (d) on UPDATE the value is recalculated too (re-grading a load B -> C)
UPDATE deliveries SET grade = 'C' WHERE delivery_id = 4;
SELECT delivery_id, grade, weight_kg, unit_rate, total_value FROM deliveries WHERE delivery_id = 4;
-- 420.50 kg x K3 = K1261.50

/* ---------------------------------------------------------------------
   (e) VIEW v_farmer_amount_due — every farmer, zero if nothing unpaid  [5 marks]
   --------------------------------------------------------------------- */
CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT f.farmer_number,
       f.full_name,
       COALESCE(SUM(d.total_value), 0)::NUMERIC(16,2) AS amount_due
FROM   farmers f
LEFT JOIN deliveries d
       ON d.farmer_id = f.farmer_id
      AND d.is_paid = FALSE              -- filter in ON keeps fully-paid farmers
GROUP BY f.farmer_id, f.farmer_number, f.full_name;

SELECT * FROM v_farmer_amount_due ORDER BY farmer_number;   -- Natasha shows 0.00

/* ---------------------------------------------------------------------
   (f) COMPOSITE INDEX — a farmer's deliveries between two dates  [5 marks]
   Justification: farmer_id (equality) first, delivered_on (range) second,
   so one farmer's deliveries are stored together in date order and a
   statement for any period is a single short index range scan.
   --------------------------------------------------------------------- */
CREATE INDEX idx_deliveries_farmer_date ON deliveries (farmer_id, delivered_on);
ANALYZE deliveries;

EXPLAIN
SELECT delivery_id, grade, weight_kg, total_value, delivered_on
FROM   deliveries
WHERE  farmer_id = 1
AND    delivered_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;

BEGIN;
SET LOCAL enable_seqscan = off;
EXPLAIN ANALYZE
SELECT delivery_id, grade, weight_kg, total_value, delivered_on
FROM   deliveries
WHERE  farmer_id = 1
AND    delivered_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
COMMIT;

/* ---------------------------------------------------------------------
   (g) SCHEDULED JOB — pr_refresh_purchases(p_day)  [6 marks]
   --------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql
SET search_path = q09_maize, public
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'p_day is required' USING ERRCODE = '22023';
    END IF;

    INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
    SELECT p_day, COALESCE(SUM(weight_kg), 0), COALESCE(SUM(total_value), 0)
    FROM   deliveries
    WHERE  delivered_on = p_day
    ON CONFLICT (purchase_date) DO UPDATE
       SET total_weight = EXCLUDED.total_weight,
           total_value  = EXCLUDED.total_value;

    RAISE NOTICE 'daily_purchases refreshed for %', p_day;
END;
$$;

CALL pr_refresh_purchases(CURRENT_DATE - 1);
CALL pr_refresh_purchases(CURRENT_DATE - 1);   -- rerun replaces, never adds again
SELECT * FROM daily_purchases;                  -- 1720.50 kg, K7161.50

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'q09_refresh_purchases',
    '30 1 * * *',                                  -- 01:30 every day
    $$CALL q09_maize.pr_refresh_purchases(CURRENT_DATE - 1)$$
);

SELECT jobid, jobname, schedule, command, active
FROM cron.job WHERE jobname = 'q09_refresh_purchases';
