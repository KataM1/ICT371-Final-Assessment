/* =====================================================================
   ICT371 Advanced Database — Question 1: Pharmacy Stock and Daily Sales
   DBMS     : PostgreSQL 14+ (tested on PostgreSQL 16) with pg_cron
   Run      : open in pgAdmin Query Tool (or psql) and run the whole file.
              Everything lives in its own schema, so it is safe to rerun.
   ===================================================================== */

DROP SCHEMA IF EXISTS q01_pharmacy CASCADE;
CREATE SCHEMA q01_pharmacy;
SET search_path TO q01_pharmacy, public;

/* ---------------------------------------------------------------------
   (a) DATABASE — the four tables  [6 marks]
   Rules: positive prices, non-negative stock, positive quantities.
   --------------------------------------------------------------------- */
CREATE TABLE medicines (
    medicine_id    SERIAL        PRIMARY KEY,
    medicine_name  VARCHAR(100)  NOT NULL UNIQUE,
    unit_price     NUMERIC(10,2) NOT NULL CONSTRAINT chk_med_price_positive CHECK (unit_price > 0),
    stock_qty      INTEGER       NOT NULL CONSTRAINT chk_med_stock_nonneg  CHECK (stock_qty >= 0)
);

CREATE TABLE sales (
    sale_id      SERIAL        PRIMARY KEY,
    medicine_id  INTEGER       NOT NULL REFERENCES medicines(medicine_id),
    quantity     INTEGER       NOT NULL CONSTRAINT chk_sale_qty_positive   CHECK (quantity > 0),
    unit_price   NUMERIC(10,2) NOT NULL CONSTRAINT chk_sale_price_positive CHECK (unit_price > 0),
    sold_on      DATE          NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE stock_audit (
    audit_id     SERIAL      PRIMARY KEY,
    medicine_id  INTEGER     NOT NULL REFERENCES medicines(medicine_id),
    old_qty      INTEGER     NOT NULL,
    new_qty      INTEGER     NOT NULL,
    changed_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE daily_sales (
    sales_date    DATE          PRIMARY KEY,
    total_qty     INTEGER       NOT NULL DEFAULT 0 CHECK (total_qty >= 0),
    total_amount  NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (total_amount >= 0)
);

/* ---------------------------------------------------------------------
   (b) FUNCTION fn_sale_value(p_medicine_id, p_quantity)  [6 marks]
   Returns current unit_price * quantity. Rejects bad quantity / unknown id.
   --------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION fn_sale_value(p_medicine_id INTEGER, p_quantity INTEGER)
RETURNS NUMERIC
LANGUAGE plpgsql
SET search_path = q01_pharmacy, public
AS $$
DECLARE
    v_price medicines.unit_price%TYPE;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Quantity must be a positive whole number (got %)', p_quantity
              USING ERRCODE = '22023';
    END IF;

    SELECT unit_price INTO v_price
    FROM medicines
    WHERE medicine_id = p_medicine_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Medicine % does not exist', p_medicine_id
              USING ERRCODE = 'P0002';
    END IF;

    RETURN ROUND(v_price * p_quantity, 2);
END;
$$;

/* ---------------------------------------------------------------------
   (c) PROCEDURE pr_record_sale(p_medicine_id, p_quantity, p_sold_on)  [8 marks]
   - locks the medicine row (FOR UPDATE) so two tills cannot oversell
   - checks stock, saves the CURRENT price in the sale
   - deducts stock exactly once (one UPDATE)
   - any RAISE EXCEPTION rolls back the whole CALL, so an invalid sale
     leaves BOTH tables unchanged
   --------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE pr_record_sale(
    p_medicine_id INTEGER,
    p_quantity    INTEGER,
    p_sold_on     DATE DEFAULT CURRENT_DATE
)
LANGUAGE plpgsql
SET search_path = q01_pharmacy, public
AS $$
DECLARE
    v_price   medicines.unit_price%TYPE;
    v_stock   medicines.stock_qty%TYPE;
    v_sale_id INTEGER;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Sale rejected: quantity must be positive (got %)', p_quantity
              USING ERRCODE = '22023';
    END IF;

    IF p_sold_on IS NULL THEN
        RAISE EXCEPTION 'Sale rejected: sale date is required' USING ERRCODE = '22023';
    END IF;

    SELECT unit_price, stock_qty INTO v_price, v_stock
    FROM medicines
    WHERE medicine_id = p_medicine_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Sale rejected: medicine % does not exist', p_medicine_id
              USING ERRCODE = 'P0002';
    END IF;

    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Sale rejected: only % in stock, % requested', v_stock, p_quantity
              USING ERRCODE = 'P0001';
    END IF;

    -- deduct stock exactly once
    UPDATE medicines
    SET    stock_qty = stock_qty - p_quantity
    WHERE  medicine_id = p_medicine_id;

    -- store the price that applied at the moment of sale
    INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_price, p_sold_on)
    RETURNING sale_id INTO v_sale_id;

    RAISE NOTICE 'Sale % recorded: medicine %, qty %, value K%',
                 v_sale_id, p_medicine_id, p_quantity, fn_sale_value(p_medicine_id, p_quantity);
END;
$$;

/* ---------------------------------------------------------------------
   (d) TRIGGER — AFTER UPDATE row trigger on medicines  [8 marks]
   Writes OLD and NEW stock to stock_audit ONLY when stock_qty changes.
   The WHEN clause stops the trigger firing for price-only updates.
   --------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION trg_fn_stock_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = q01_pharmacy, public
AS $$
BEGIN
    INSERT INTO stock_audit (medicine_id, old_qty, new_qty, changed_at)
    VALUES (NEW.medicine_id, OLD.stock_qty, NEW.stock_qty, now());
    RETURN NEW;   -- return value is ignored for AFTER triggers
END;
$$;

CREATE TRIGGER trg_medicines_stock_audit
AFTER UPDATE OF stock_qty ON medicines
FOR EACH ROW
WHEN (OLD.stock_qty IS DISTINCT FROM NEW.stock_qty)
EXECUTE FUNCTION trg_fn_stock_audit();

/* ---------------------------------------------------------------------
   (a) SEED DATA — 3 medicines, 6 valid sales loaded THROUGH the procedure
   --------------------------------------------------------------------- */
INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
    ('Paracetamol 500mg (strip)', 2.50, 100),
    ('Amoxicillin 250mg (strip)', 12.00, 30),
    ('Cough Syrup 100ml',         35.00, 15);

CALL pr_record_sale(1, 10, CURRENT_DATE - 2);
CALL pr_record_sale(2,  5, CURRENT_DATE - 2);
CALL pr_record_sale(1, 20, CURRENT_DATE - 1);
CALL pr_record_sale(3,  3, CURRENT_DATE - 1);
CALL pr_record_sale(2,  4, CURRENT_DATE);
CALL pr_record_sale(1,  6, CURRENT_DATE);

SELECT * FROM medicines ORDER BY medicine_id;   -- stock: 64, 21, 12
SELECT * FROM sales     ORDER BY sale_id;       -- 6 sales with stored prices

/* ---------------------------------------------------------------------
   TESTS for (b), (c), (d)
   --------------------------------------------------------------------- */
-- (b) valid call: 4 x K12.00 = 48.00
SELECT fn_sale_value(2, 4) AS value_of_4_amoxicillin;

-- (b) invalid calls are rejected (errors caught so the script continues)
DO $$
BEGIN
    BEGIN PERFORM fn_sale_value(99, 1);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'fn_sale_value(99,1) -> %', SQLERRM; END;
    BEGIN PERFORM fn_sale_value(1, 0);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'fn_sale_value(1,0)  -> %', SQLERRM; END;
END $$;

-- (c) invalid sales leave BOTH tables unchanged
SELECT (SELECT COUNT(*) FROM sales) AS sales_rows_before,
       (SELECT stock_qty FROM medicines WHERE medicine_id = 3) AS syrup_stock_before;

DO $$
BEGIN
    BEGIN CALL pr_record_sale(3, 500, CURRENT_DATE);        -- oversell
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Oversell     -> %', SQLERRM; END;
    BEGIN CALL pr_record_sale(42, 1, CURRENT_DATE);         -- unknown medicine
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Unknown med  -> %', SQLERRM; END;
    BEGIN CALL pr_record_sale(3, -2, CURRENT_DATE);         -- negative quantity
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Negative qty -> %', SQLERRM; END;
END $$;

SELECT (SELECT COUNT(*) FROM sales) AS sales_rows_after,
       (SELECT stock_qty FROM medicines WHERE medicine_id = 3) AS syrup_stock_after;

-- (d) price-only update: NO audit row;  stock update: ONE audit row
UPDATE medicines SET unit_price = 36.00 WHERE medicine_id = 3;   -- no audit
UPDATE medicines SET stock_qty  = stock_qty WHERE medicine_id = 3; -- same value, no audit
SELECT * FROM stock_audit ORDER BY audit_id;   -- one row per sale only (6 rows)

/* ---------------------------------------------------------------------
   (e) VIEW v_low_stock — medicines with stock below 10  [5 marks]
   --------------------------------------------------------------------- */
CREATE OR REPLACE VIEW v_low_stock AS
SELECT medicine_id,
       medicine_name,
       unit_price,
       stock_qty AS remaining_stock
FROM   medicines
WHERE  stock_qty < 10;

SELECT * FROM v_low_stock;            -- empty: nothing is below 10 yet
CALL pr_record_sale(3, 4, CURRENT_DATE);   -- syrup 12 -> 8
SELECT * FROM v_low_stock;            -- Cough Syrup now appears with 8 left

/* ---------------------------------------------------------------------
   (f) INDEX — one medicine's sales within a sold_on date range  [5 marks]
   Justification: the query filters medicine_id with "=" and sold_on with a
   range. A composite B-tree with the equality column FIRST and the range
   column SECOND lets PostgreSQL jump to that medicine and read only the
   contiguous slice of dates, instead of scanning every sale.
   --------------------------------------------------------------------- */
CREATE INDEX idx_sales_medicine_soldon ON sales (medicine_id, sold_on);
ANALYZE sales;

-- Plan with real statistics (on 7 rows the planner may still choose a Seq Scan,
-- because reading one tiny page is cheaper than using any index)
EXPLAIN
SELECT sale_id, quantity, unit_price, sold_on
FROM   sales
WHERE  medicine_id = 1
AND    sold_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;

-- Same query with sequential scans discouraged, to prove the index matches it
BEGIN;
SET LOCAL enable_seqscan = off;
EXPLAIN ANALYZE
SELECT sale_id, quantity, unit_price, sold_on
FROM   sales
WHERE  medicine_id = 1
AND    sold_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
COMMIT;

/* ---------------------------------------------------------------------
   (g) SCHEDULED JOB — pr_refresh_sales(p_day)  [6 marks]
   INSERT ... ON CONFLICT DO UPDATE *replaces* the day's totals, so rerunning
   never duplicates the row or double-counts. Days with no sales get zeros.
   --------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql
SET search_path = q01_pharmacy, public
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'p_day is required' USING ERRCODE = '22023';
    END IF;

    INSERT INTO daily_sales (sales_date, total_qty, total_amount)
    SELECT p_day,
           COALESCE(SUM(quantity), 0),
           COALESCE(SUM(quantity * unit_price), 0)
    FROM   sales
    WHERE  sold_on = p_day
    ON CONFLICT (sales_date) DO UPDATE
       SET total_qty    = EXCLUDED.total_qty,
           total_amount = EXCLUDED.total_amount;

    RAISE NOTICE 'daily_sales refreshed for %', p_day;
END;
$$;

-- Run twice for yesterday: still ONE row with the same totals (23 units, K155.00)
CALL pr_refresh_sales(CURRENT_DATE - 1);
CALL pr_refresh_sales(CURRENT_DATE - 1);
SELECT * FROM daily_sales ORDER BY sales_date;

-- Schedule: every day at 00:15, summarising the PREVIOUS day.
-- (pg_cron must be in shared_preload_libraries; see the README.)
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'q01_refresh_daily_sales',          -- job name (re-scheduling the same name replaces it)
    '15 0 * * *',                       -- min hour day month weekday  => 00:15 daily
    $$CALL q01_pharmacy.pr_refresh_sales(CURRENT_DATE - 1)$$
);

SELECT jobid, jobname, schedule, command, active
FROM   cron.job
WHERE  jobname = 'q01_refresh_daily_sales';
