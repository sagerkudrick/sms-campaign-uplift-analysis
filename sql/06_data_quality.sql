/* =============================================================================
   06  Data quality: look for odd or contradictory data in the source files
   -----------------------------------------------------------------------------
   04_reconcile.sql asks "did the pipeline lose or change anything?".
   This file asks "is the source data itself sensible?".

   qa.usp_data_quality runs every check and saves one row per check in
   qa.data_quality_results (so results can be compared over time), then
   returns this run's rows. scripts/data_quality_report.py turns them into HTML.

   status:  OK       nothing found
            Info     worth knowing, no action needed
            Warning  real inconsistency in the source data: understand it before using that field

   Examples use + rather than CONCAT so they become NULL (blank) when a check finds nothing.
   ========================================================================== */
USE uplift;
GO
IF OBJECT_ID('qa.data_quality_results') IS NULL
CREATE TABLE qa.data_quality_results (
    result_id   INT IDENTITY PRIMARY KEY,
    run_at      DATETIME2(0)  NOT NULL,
    section     VARCHAR(50)   NOT NULL,
    check_name  VARCHAR(200)  NOT NULL,
    found       BIGINT        NOT NULL,   -- how many rows / receipts / clients have the issue
    out_of      BIGINT        NULL,       -- how many were checked (for a percentage)
    status      VARCHAR(10)   NOT NULL,
    explanation VARCHAR(500)  NOT NULL,
    example     VARCHAR(200)  NULL
);
GO

CREATE OR ALTER PROCEDURE qa.usp_data_quality
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @run_at DATETIME2(0) = SYSDATETIME();

    -- One row per receipt, used by several checks below
    DROP TABLE IF EXISTS #r;
    SELECT  client_id, transaction_id,
            MIN(transaction_datetime) AS receipt_time,
            MAX(purchase_sum)         AS receipt_total,
            SUM(trn_sum_from_iss)     AS line_amounts,      -- product line amounts added up
            -MIN(regular_points_spent) AS points_spent
    INTO    #r
    FROM    raw.purchases
    GROUP BY client_id, transaction_id;

    DECLARE @receipts BIGINT = (SELECT COUNT(*) FROM #r);
    DECLARE @lines    BIGINT = (SELECT COUNT_BIG(*) FROM raw.purchases);
    DECLARE @clients  BIGINT = (SELECT COUNT(*) FROM raw.clients);
    DECLARE @campaign BIGINT = (SELECT COUNT(*) FROM raw.uplift_train);
    DECLARE @history_end DATETIME2(0) = (SELECT MAX(receipt_time) FROM #r);

    -- First / last purchase per client, for the client checks
    DROP TABLE IF EXISTS #c;
    SELECT  client_id,
            MIN(receipt_time) AS first_purchase,
            MIN(CASE WHEN points_spent > 0 THEN receipt_time END) AS first_points_spent
    INTO    #c
    FROM    #r
    GROUP BY client_id;

    DECLARE @results TABLE (section VARCHAR(50), check_name VARCHAR(200), found BIGINT, out_of BIGINT,
                            status VARCHAR(10), explanation VARCHAR(500), example VARCHAR(200));

    /* ---------------- Purchases ---------------- */
    INSERT @results
    SELECT 'Purchases', 'Receipts with a total of 0 or less', COUNT(*), @receipts,
           CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'Warning' END,
           'Possibly returns or voided sales. They are kept in spend totals as recorded.',
           'e.g. receipt ' + MIN(transaction_id)
    FROM #r WHERE receipt_total <= 0;

    INSERT @results
    SELECT 'Purchases', 'Product lines with quantity 0', COUNT_BIG(*), @lines,
           CASE WHEN COUNT_BIG(*) = 0 THEN 'OK' ELSE 'Warning' END,
           'Almost all of these still have a price, so they are probably items sold by weight. '
           + '"Items bought" undercounts them; spend is not affected.',
           CONCAT(FORMAT(SUM(CASE WHEN trn_sum_from_iss > 0 THEN 1 ELSE 0 END), 'N0'), ' of them have a price')
    FROM raw.purchases WHERE product_quantity = 0;

    INSERT @results
    SELECT 'Purchases', 'Receipts where the product line amounts do not add up to the receipt total (more than 1 apart)',
           COUNT(*), @receipts,
           CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'Warning' END,
           'Likely discounts or points payments; the dataset does not document them. '
           + 'Spend uses the receipt total (purchase_sum), not the line amounts.',
           CONCAT('largest gap: ', FORMAT(MAX(ABS(receipt_total - line_amounts)), 'N0'))
    FROM #r WHERE ABS(receipt_total - line_amounts) > 1;

    -- Days with under a quarter of a typical day's receipts: a partial day or missing data
    DECLARE @typical_day FLOAT = (SELECT DISTINCT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY transactions) OVER ()
                                  FROM mart.daily_sales);
    INSERT @results
    SELECT 'Purchases', 'Days with unusually few receipts (under 25% of a typical day)', COUNT(*),
           (SELECT COUNT(*) FROM mart.daily_sales),
           CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'Warning' END,
           CONCAT('A typical day has ', FORMAT(@typical_day, 'N0'), ' receipts. Low days are usually a partial day '
                  , 'at the start or end of the extract; leave them out of daily trends. '
                  , 'Note: days here are in purchases.csv time, 3 hours behind local time.'),
           STRING_AGG(CONCAT(FORMAT(sales_date, 'yyyy-MM-dd'), ' (', transactions, ')'), ', ')
    FROM mart.daily_sales WHERE transactions < 0.25 * @typical_day;

    INSERT @results
    SELECT 'Purchases', 'Receipts between midnight and 6 am', COUNT(*), @receipts, 'Info',
           'Purchase times look 3 hours behind local time (see the time-zone check under Clients), '
           + 'so most of these are really 3 am to 9 am.', NULL
    FROM #r WHERE DATEPART(HOUR, receipt_time) < 6;

    INSERT @results
    SELECT 'Purchases', 'Receipt ids used by more than one client', COUNT(*), NULL, 'Info',
           'Probably id collisions. Harmless here because receipts are identified by client id + receipt id.',
           'e.g. receipt ' + MIN(transaction_id)
    FROM (SELECT transaction_id FROM #r GROUP BY transaction_id HAVING COUNT(*) > 1) AS d;

    /* ---------------- Clients ---------------- */
    INSERT @results
    SELECT 'Clients', 'Impossible ages (outside 14-99)', COUNT(*), @clients,
           CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'Warning' END,
           'Treated as unknown age in the analysis.',
           CONCAT('lowest ', MIN(age), ', highest ', MAX(age))
    FROM raw.clients WHERE age NOT BETWEEN 14 AND 99;

    INSERT @results
    SELECT 'Clients', 'Gender not stated (U)', COUNT(*), @clients, 'Info',
           'Shown as "Not stated". Too many to ignore, so gender results have a large unknown group.', NULL
    FROM raw.clients WHERE gender = 'U';

    INSERT @results
    SELECT 'Clients', 'First points redemption recorded before the card was issued', COUNT(*), @clients,
           CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'Warning' END,
           'Impossible order of events, so one of the two dates is wrong for these clients.',
           'e.g. client ' + MIN(client_id)
    FROM raw.clients WHERE first_redeem_date < first_issue_date;

    /* Time zones. For many clients the card-issue time in clients.csv is exactly 3 hours after their first
       purchase in purchases.csv (e.g. 10:33:11 vs 13:33:11), and the first-redemption time is exactly 3 hours
       after their first points spend. So the files use different time zones: clients.csv runs 3 hours ahead
       (likely Moscow time vs UTC). Without allowing for this, ~47k clients appear to buy before getting their
       card and ~71k to spend points before redeeming; after shifting by 3 hours almost all of that disappears. */
    INSERT @results
    SELECT 'Clients', 'Time zone: clients.csv is exactly 3 hours ahead of purchases.csv', COUNT(*), @clients,
           'Warning',
           'Counted: clients whose card was issued exactly 3h 00m 00s after their first purchase. '
           + 'Shift purchase times by +3 hours before comparing them with client dates. '
           + 'It also explains the short first day: the history starts at 21:02 on 21 Nov, i.e. 00:02 on 22 Nov.',
           'e.g. client 000048b7a6: first purchase 10:33:11, card issued 13:33:11'
    FROM #c AS k JOIN raw.clients AS c ON c.client_id = k.client_id
    WHERE DATEDIFF(SECOND, k.first_purchase, c.first_issue_date) = 3 * 3600;

    INSERT @results
    SELECT 'Clients', 'Purchases before the card was issued (after the 3-hour time-zone shift)', COUNT(*), @clients,
           CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'Warning' END,
           'Still before the issue date even after allowing for the time zone, so one of the dates is wrong. '
           + 'Do not use first_issue_date as the date a client joined.',
           'e.g. client ' + MIN(k.client_id)
    FROM #c AS k JOIN raw.clients AS c ON c.client_id = k.client_id
    WHERE DATEADD(HOUR, 3, k.first_purchase) < c.first_issue_date;

    INSERT @results
    SELECT 'Clients', 'Points spent before the recorded first redemption (after the 3-hour time-zone shift)', COUNT(*), @clients,
           CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'Warning' END,
           'Checks that first_redeem_date agrees with the purchase history once time zones are aligned.',
           'e.g. client ' + MIN(k.client_id)
    FROM #c AS k JOIN raw.clients AS c ON c.client_id = k.client_id
    WHERE DATEADD(HOUR, 3, k.first_points_spent) < c.first_redeem_date;

    INSERT @results
    SELECT 'Clients', 'First redemption date after the purchase history ends', COUNT(*), @clients, 'Info',
           CONCAT('The clients file was extracted later than the purchases (history ends ',
                  FORMAT(@history_end, 'yyyy-MM-dd'), '), so the two files are not from the same moment.'),
           CONCAT('latest: ', FORMAT(MAX(first_redeem_date), 'yyyy-MM-dd'))
    FROM raw.clients WHERE first_redeem_date > @history_end;

    INSERT @results
    SELECT 'Clients', 'Clients with purchases but missing from the clients file', COUNT(*), NULL,
           CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'Warning' END,
           'Every client in the purchase history should have a clients row.', NULL
    FROM #c AS k WHERE NOT EXISTS (SELECT 1 FROM raw.clients AS c WHERE c.client_id = k.client_id);

    /* ---------------- Campaign ---------------- */
    INSERT @results
    SELECT 'Campaign', 'Group sizes: received SMS vs control', SUM(treatment_flg), @campaign, 'Info',
           CONCAT(FORMAT(SUM(treatment_flg), 'N0'), ' received the SMS, ',
                  FORMAT(COUNT(*) - SUM(treatment_flg), 'N0'), ' did not: close to the 50/50 a random split should give.'),
           NULL
    FROM (SELECT CAST(treatment_flg AS INT) AS treatment_flg FROM raw.uplift_train) AS u;

    INSERT @results
    SELECT 'Campaign', 'Unexpected values in treatment_flg or target (not 0 or 1)', COUNT(*), @campaign,
           CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'Warning' END,
           'Both columns should only contain 0 or 1.', NULL
    FROM raw.uplift_train WHERE treatment_flg NOT IN (0, 1) OR target NOT IN (0, 1);

    INSERT @results
    SELECT 'Campaign', 'Campaign clients with no purchase history or no clients row', COUNT(*), @campaign,
           CASE WHEN COUNT(*) = 0 THEN 'OK' ELSE 'Warning' END,
           'Clients without history cannot be put in spend or age segments.', NULL
    FROM raw.uplift_train AS u
    WHERE NOT EXISTS (SELECT 1 FROM #c AS k WHERE k.client_id = u.client_id)
       OR NOT EXISTS (SELECT 1 FROM raw.clients AS c WHERE c.client_id = u.client_id);

    INSERT qa.data_quality_results (run_at, section, check_name, found, out_of, status, explanation, example)
    SELECT @run_at, section, check_name, found, out_of, status, explanation, example FROM @results;

    SELECT section, check_name, found, out_of, status, explanation, example
    FROM   qa.data_quality_results
    WHERE  run_at = @run_at
    ORDER BY result_id;
END;
GO
