/* =============================================================================
   03  Build the summary ("mart") tables and views
   -----------------------------------------------------------------------------
   raw.purchases has one row per product. A receipt with 5 products has 5 rows,
   and the receipt total (purchase_sum) and points are repeated on all 5. So:
     step 1  collapse product rows into one row per receipt
               receipt total   = MAX(purchase_sum)       (same value on every row)
               points received = MAX(points received)
               points spent    = -MIN(points spent)      (stored as negatives)
               items bought    = SUM(product_quantity)   (differs per row, so add up)
     step 2  add receipts up per client  -> mart.client_purchases
     step 3  add receipts up per day     -> mart.daily_sales
   qa.usp_reconcile (04) checks that purchase_sum really is the same on every row.
   ========================================================================== */
USE uplift;
GO
CREATE OR ALTER PROCEDURE mart.usp_build_marts
AS
BEGIN
    SET NOCOUNT ON;

    -- never build while a load is running (see ops.usp_load_raw)
    DECLARE @lock INT;
    EXEC @lock = sp_getapplock @Resource = 'uplift_pipeline', @LockMode = 'Exclusive',
                               @LockOwner = 'Session', @LockTimeout = 0;
    IF @lock < 0
        THROW 50001, 'Another load or build is already running.', 1;

    -- Step 1: one row per receipt, kept in a temporary table (#) for steps 2 and 3
    DROP TABLE IF EXISTS #receipts;
    SELECT  client_id,
            transaction_id,
            CAST(MIN(transaction_datetime) AS DATE) AS sales_date,
            MAX(purchase_sum)                       AS amount,
            MAX(regular_points_received)            AS points_received,
            -MIN(regular_points_spent)              AS points_spent,
            MAX(express_points_received)            AS express_received,
            -MIN(express_points_spent)              AS express_spent,
            SUM(product_quantity)                   AS items
    INTO    #receipts
    FROM    raw.purchases
    GROUP BY client_id, transaction_id;     -- client too: a few receipt ids are reused by different clients

    -- Step 2: one row per client
    TRUNCATE TABLE mart.client_purchases;
    INSERT mart.client_purchases (client_id, total_points_received, total_points_spent,
                                  total_express_received, total_express_spent,
                                  total_product_bought, total_purchase, transactions)
    SELECT  client_id,
            SUM(points_received),
            SUM(points_spent),
            SUM(express_received),
            SUM(express_spent),
            SUM(items),
            SUM(amount),
            COUNT(*)                         -- one row per receipt, so this counts receipts
    FROM    #receipts
    GROUP BY client_id;
    INSERT ops.run_log (step, row_count) SELECT 'build mart.client_purchases', COUNT(*) FROM mart.client_purchases;

    -- Step 3: one row per day
    TRUNCATE TABLE mart.daily_sales;
    INSERT mart.daily_sales (sales_date, total_purchase, transactions)
    SELECT  sales_date, SUM(amount), COUNT(*)
    FROM    #receipts
    GROUP BY sales_date;
    INSERT ops.run_log (step, row_count) SELECT 'build mart.daily_sales', COUNT(*) FROM mart.daily_sales;

    EXEC sp_releaseapplock @Resource = 'uplift_pipeline', @LockOwner = 'Session';
END;
GO

-- Cleaned demographics. The source has impossible ages (e.g. -7491, 1901): anything outside 14-99 becomes NULL.
CREATE OR ALTER VIEW mart.clients
AS
SELECT  client_id,
        first_issue_date  AS card_issued,
        first_redeem_date AS first_redeemed,
        CASE WHEN age BETWEEN 14 AND 99 THEN age END AS age,      -- no ELSE, so other ages become NULL
        CASE gender WHEN 'F' THEN 'Female'
                    WHEN 'M' THEN 'Male'
                    ELSE 'Not stated' END             AS gender,
        age    AS age_raw,                                       -- original values, kept for checking
        gender AS gender_raw
FROM    raw.clients;
GO

-- One row per campaign client, with the segments used in the analysis.
CREATE OR ALTER VIEW mart.campaign_clients
AS
WITH joined AS (
    -- LEFT JOIN keeps every campaign client even if a match were missing
    -- (qa.usp_reconcile confirms that none are).
    SELECT  u.client_id, u.treatment_flg, u.target,
            p.total_purchase, p.total_points_spent,
            c.age, c.gender
    FROM    raw.uplift_train AS u
    LEFT JOIN mart.client_purchases AS p ON p.client_id = u.client_id
    LEFT JOIN mart.clients          AS c ON c.client_id = u.client_id
),
cuts AS (
    -- Spend quartile boundaries: the 25th, 50th and 75th percentile of spend.
    -- PERCENTILE_CONT is a window function, so every row gets the same values; DISTINCT keeps one row.
    SELECT DISTINCT
            PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY total_purchase) OVER () AS q1,
            PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY total_purchase) OVER () AS q2,
            PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY total_purchase) OVER () AS q3
    FROM    joined
)
SELECT  j.client_id, j.treatment_flg, j.target, j.total_purchase, j.age, j.gender,
        CASE WHEN j.total_purchase <= k.q1 THEN 'Q1 (lowest spend)'
             WHEN j.total_purchase <= k.q2 THEN 'Q2'
             WHEN j.total_purchase <= k.q3 THEN 'Q3'
             ELSE 'Q4 (highest spend)' END             AS spend_quartile,
        CASE WHEN j.age IS NULL THEN 'Unknown age'
             WHEN j.age < 25 THEN '14-24'
             WHEN j.age < 35 THEN '25-34'
             WHEN j.age < 45 THEN '35-44'
             WHEN j.age < 55 THEN '45-54'
             WHEN j.age < 65 THEN '55-64'
             ELSE '65+' END                            AS age_band,
        CASE WHEN j.total_points_spent > 0 THEN 'Redeemed points'
             ELSE 'Never redeemed points' END          AS points_segment
FROM    joined AS j
CROSS JOIN cuts AS k;      -- cuts has one row, so this just adds q1/q2/q3 to every client
GO
