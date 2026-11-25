/* =====================================================================
   ICT371 Advanced Database — Question 3: Library Returns and Overdue Fines
   DBMS : PostgreSQL 14+ (tested on PostgreSQL 16) with pg_cron
   Rule : K2 per day after due_on. Returning ON the due date = no fine.
          A returned loan stops accumulating fines.
   ===================================================================== */

DROP SCHEMA IF EXISTS q03_library CASCADE;
CREATE SCHEMA q03_library;
SET search_path TO q03_library, public;

/* ---------------------------------------------------------------------
   (a) DATABASE — tables  [6 marks]
   --------------------------------------------------------------------- */
CREATE TABLE books (
    book_id  SERIAL       PRIMARY KEY,
    title    VARCHAR(150) NOT NULL
);

CREATE TABLE loans (
    loan_id        SERIAL        PRIMARY KEY,
    book_id        INTEGER       NOT NULL REFERENCES books(book_id),
    borrower_name  VARCHAR(100)  NOT NULL,
    borrowed_on    DATE          NOT NULL,
    due_on         DATE          NOT NULL,
    returned_on    DATE          NULL,
    fine_amount    NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fine_amount >= 0),
    CONSTRAINT chk_due_after_borrow    CHECK (due_on >= borrowed_on),
    CONSTRAINT chk_return_after_borrow CHECK (returned_on IS NULL OR returned_on >= borrowed_on)
);

CREATE TABLE loan_audit (
    audit_id         SERIAL      PRIMARY KEY,
    loan_id          INTEGER     NOT NULL REFERENCES loans(loan_id),
    old_returned_on  DATE        NULL,
    new_returned_on  DATE        NULL,
    changed_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE overdue_summary (
    snapshot_date  DATE          PRIMARY KEY,
    overdue_count  INTEGER       NOT NULL DEFAULT 0,
    total_fine     NUMERIC(12,2) NOT NULL DEFAULT 0
);

/* ---------------------------------------------------------------------
   (b) FUNCTION fn_loan_fine(p_loan_id, p_as_of)  [6 marks]
   Fine = K2 x days late, never below zero. If the book was returned, the
   clock stops at the EARLIER of p_as_of and returned_on.
   --------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INTEGER, p_as_of DATE)
RETURNS NUMERIC
LANGUAGE plpgsql
SET search_path = q03_library, public
AS $$
DECLARE
    v_due      DATE;
    v_returned DATE;
    v_end      DATE;
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'p_as_of date is required' USING ERRCODE = '22023';
    END IF;

    SELECT due_on, returned_on INTO v_due, v_returned
    FROM loans
    WHERE loan_id = p_loan_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Loan % does not exist', p_loan_id USING ERRCODE = 'P0002';
    END IF;

    IF v_returned IS NOT NULL THEN
        v_end := LEAST(p_as_of, v_returned);
    ELSE
        v_end := p_as_of;
    END IF;

    -- date - date gives whole days in PostgreSQL
    RETURN (GREATEST(v_end - v_due, 0) * 2.00)::NUMERIC(10,2);
END;
$$;

/* ---------------------------------------------------------------------
   (c) PROCEDURE pr_return_loan(p_loan_id, p_returned_on)  [8 marks]
   Rejects unknown / already-returned loans and returns before borrowed_on.
   Saves the return date AND the final fine in ONE update.
   --------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INTEGER, p_returned_on DATE)
LANGUAGE plpgsql
SET search_path = q03_library, public
AS $$
DECLARE
    v_loan loans%ROWTYPE;
    v_fine NUMERIC(10,2);
BEGIN
    IF p_returned_on IS NULL THEN
        RAISE EXCEPTION 'Return rejected: return date is required' USING ERRCODE = '22023';
    END IF;

    SELECT * INTO v_loan FROM loans WHERE loan_id = p_loan_id FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Return rejected: loan % does not exist', p_loan_id USING ERRCODE = 'P0002';
    END IF;

    IF v_loan.returned_on IS NOT NULL THEN
        RAISE EXCEPTION 'Return rejected: loan % was already returned on %', p_loan_id, v_loan.returned_on
              USING ERRCODE = 'P0001';
    END IF;

    IF p_returned_on < v_loan.borrowed_on THEN
        RAISE EXCEPTION 'Return rejected: % is before the borrow date %', p_returned_on, v_loan.borrowed_on
              USING ERRCODE = 'P0001';
    END IF;

    v_fine := GREATEST(p_returned_on - v_loan.due_on, 0) * 2.00;

    UPDATE loans
    SET    returned_on = p_returned_on,
           fine_amount = v_fine
    WHERE  loan_id = p_loan_id;

    RAISE NOTICE 'Loan % returned on %, final fine K%', p_loan_id, p_returned_on, v_fine;
END;
$$;

/* ---------------------------------------------------------------------
   (d) TRIGGER — AFTER UPDATE: log returned_on changes with OLD and NEW  [8 marks]
   IS DISTINCT FROM treats NULL correctly (NULL -> date counts as a change,
   date -> same date does not).
   --------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION trg_fn_loan_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = q03_library, public
AS $$
BEGIN
    IF OLD.returned_on IS DISTINCT FROM NEW.returned_on THEN
        INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on, changed_at)
        VALUES (NEW.loan_id, OLD.returned_on, NEW.returned_on, now());
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_loans_returned_audit
AFTER UPDATE ON loans
FOR EACH ROW
EXECUTE FUNCTION trg_fn_loan_audit();

/* ---------------------------------------------------------------------
   (a) SEED DATA — 3 books, 6 loans (dates relative to today so the
   overdue view always has data). The library holds several copies of
   each title, so one title can be on loan to more than one borrower.
   --------------------------------------------------------------------- */
INSERT INTO books (title) VALUES
    ('Database System Concepts'),
    ('Fundamentals of Software Engineering'),
    ('Introduction to Algorithms');

INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on) VALUES
    (1, 'Mwila Banda',   CURRENT_DATE - 30, CURRENT_DATE - 16),  -- 1 OPEN & OVERDUE (16 days)
    (2, 'Chanda Phiri',  CURRENT_DATE - 10, CURRENT_DATE - 3),   -- 2 returned ON TIME (below)
    (3, 'Bwalya Mulenga',CURRENT_DATE - 20, CURRENT_DATE - 12),  -- 3 returned LATE (below)
    (1, 'Natasha Zulu',  CURRENT_DATE - 5,  CURRENT_DATE + 9),   -- 4 open, not yet due
    (2, 'Kondwani Tembo',CURRENT_DATE - 25, CURRENT_DATE - 11),  -- 5 OPEN & OVERDUE (11 days)
    (3, 'Lubuto Sakala', CURRENT_DATE - 2,  CURRENT_DATE + 12);  -- 6 open, not yet due

CALL pr_return_loan(2, CURRENT_DATE - 3);   -- on the due date  -> K0
CALL pr_return_loan(3, CURRENT_DATE - 7);   -- 5 days late      -> K10

SELECT loan_id, book_id, borrower_name, borrowed_on, due_on, returned_on, fine_amount
FROM loans ORDER BY loan_id;

/* ---------------------------------------------------------------------
   TESTS for (b), (c), (d)
   --------------------------------------------------------------------- */
SELECT loan_id,
       fn_loan_fine(loan_id, CURRENT_DATE)      AS fine_today,
       fn_loan_fine(loan_id, CURRENT_DATE + 10) AS fine_in_10_days   -- returned loans do not grow
FROM loans ORDER BY loan_id;

DO $$
BEGIN
    BEGIN PERFORM fn_loan_fine(500, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'fn_loan_fine(500)   -> %', SQLERRM; END;
    BEGIN CALL pr_return_loan(500, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Unknown loan        -> %', SQLERRM; END;
    BEGIN CALL pr_return_loan(2, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Already returned    -> %', SQLERRM; END;
    BEGIN CALL pr_return_loan(6, CURRENT_DATE - 10);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Before borrowed_on  -> %', SQLERRM; END;
END $$;

-- (d) an update that does NOT change returned_on creates no audit row
UPDATE loans SET borrower_name = borrower_name WHERE loan_id = 3;
UPDATE loans SET returned_on   = returned_on   WHERE loan_id = 3;
SELECT * FROM loan_audit ORDER BY audit_id;   -- only the 2 real returns

/* ---------------------------------------------------------------------
   (e) VIEW v_overdue_loans — unreturned and due before today  [5 marks]
   --------------------------------------------------------------------- */
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT l.loan_id,
       b.title,
       l.borrower_name,
       l.due_on,
       CURRENT_DATE - l.due_on              AS days_overdue,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_as_of_today
FROM   loans l
JOIN   books b ON b.book_id = l.book_id
WHERE  l.returned_on IS NULL
AND    l.due_on < CURRENT_DATE;

SELECT * FROM v_overdue_loans ORDER BY due_on;   -- loans 1 (K32) and 5 (K22)

/* ---------------------------------------------------------------------
   (f) INDEX — a given book's UNRETURNED loans  [5 marks]
   Justification: a PARTIAL index keeps only rows WHERE returned_on IS NULL.
   Returned loans (the large, growing history) are left out, so the index
   stays small and every entry it holds is a candidate for this search.
   --------------------------------------------------------------------- */
CREATE INDEX idx_loans_book_unreturned ON loans (book_id) WHERE returned_on IS NULL;
ANALYZE loans;

EXPLAIN
SELECT loan_id, borrower_name, borrowed_on, due_on
FROM   loans
WHERE  book_id = 1
AND    returned_on IS NULL;

BEGIN;
SET LOCAL enable_seqscan = off;
EXPLAIN ANALYZE
SELECT loan_id, borrower_name, borrowed_on, due_on
FROM   loans
WHERE  book_id = 1
AND    returned_on IS NULL;
COMMIT;

/* ---------------------------------------------------------------------
   (g) SCHEDULED JOB — pr_refresh_overdue(p_as_of)  [6 marks]
   A loan is "still unreturned as of p_as_of" if it was borrowed by then and
   either has no return date or was returned AFTER that date. Of those, the
   overdue ones (due before p_as_of) are counted; their fines are summed with
   fn_loan_fine(loan, p_as_of). (Loans not yet due carry K0 anyway.)
   --------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql
SET search_path = q03_library, public
AS $$
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'p_as_of is required' USING ERRCODE = '22023';
    END IF;

    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    SELECT p_as_of,
           COUNT(*),
           COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0)
    FROM   loans
    WHERE  borrowed_on <= p_as_of
    AND    (returned_on IS NULL OR returned_on > p_as_of)
    AND    due_on < p_as_of
    ON CONFLICT (snapshot_date) DO UPDATE
       SET overdue_count = EXCLUDED.overdue_count,
           total_fine    = EXCLUDED.total_fine;

    RAISE NOTICE 'overdue_summary refreshed for %', p_as_of;
END;
$$;

CALL pr_refresh_overdue(CURRENT_DATE);
CALL pr_refresh_overdue(CURRENT_DATE);   -- rerun replaces: 2 loans, K54.00
SELECT * FROM overdue_summary;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'q03_refresh_overdue',
    '10 0 * * *',                                  -- 00:10 every day
    $$CALL q03_library.pr_refresh_overdue(CURRENT_DATE)$$
);

SELECT jobid, jobname, schedule, command, active
FROM cron.job WHERE jobname = 'q03_refresh_overdue';
