/* =============================================================================
   04  Data checks (reconciliation)
   -----------------------------------------------------------------------------
   qa.usp_load_python_output  loads the Python totals (prep_purchases.py) for comparison
   qa.usp_reconcile           runs every check, saves the results in qa.reconcile_log
                              and returns them
   A check passes when actual = expected (within 1 cent for money).
   A check with expected = NULL is information only and always passes.
   ========================================================================== */
USE uplift;
GO
CREATE OR ALTER PROCEDURE qa.usp_load_python_output
AS
BEGIN
    SET NOCOUNT ON;
    TRUNCATE TABLE qa.python_client_purchases;
    BULK INSERT qa.python_client_purchases FROM '/pydata/purchases_by_client.csv'
        WITH (FORMAT = 'CSV', FIRSTROW = 2, ROWTERMINATOR = '0x0a');
END;
GO

CREATE OR ALTER PROCEDURE qa.usp_reconcile
    @expected_purchase_rows BIGINT   -- data lines in purchases.csv, counted outside SQL by setup_db.ps1
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @run_at DATETIME2(0) = SYSDATETIME();
    DECLARE @checks TABLE (check_name VARCHAR(200), expected DECIMAL(38,4), actual DECIMAL(38,4));

    -- Receipts rebuilt straight from the raw data, independently of the mart procedure
    DROP TABLE IF EXISTS #r;
    SELECT  client_id, transaction_id,
            MAX(purchase_sum) AS amount_max,
            MIN(purchase_sum) AS amount_min
    INTO    #r
    FROM    raw.purchases
    GROUP BY client_id, transaction_id;

    -- 1. Was the whole file loaded? (The old Excel extract silently stopped at 1,048,576 rows.)
    INSERT @checks SELECT 'raw.purchases rows = data lines in purchases.csv',
                          @expected_purchase_rows, (SELECT COUNT_BIG(*) FROM raw.purchases);

    -- 2. Do the summary tables contain every receipt, client and ruble?
    INSERT @checks SELECT 'Receipts: raw vs mart.client_purchases',
                          (SELECT COUNT(*) FROM #r), (SELECT SUM(transactions) FROM mart.client_purchases);
    INSERT @checks SELECT 'Receipts: raw vs mart.daily_sales',
                          (SELECT COUNT(*) FROM #r), (SELECT SUM(transactions) FROM mart.daily_sales);
    INSERT @checks SELECT 'Clients: raw vs mart.client_purchases',
                          (SELECT COUNT(DISTINCT client_id) FROM raw.purchases), (SELECT COUNT(*) FROM mart.client_purchases);
    INSERT @checks SELECT 'Total spend: raw vs mart.client_purchases',
                          (SELECT SUM(amount_max) FROM #r), (SELECT SUM(total_purchase) FROM mart.client_purchases);
    INSERT @checks SELECT 'Total spend: mart.client_purchases vs mart.daily_sales',
                          (SELECT SUM(total_purchase) FROM mart.client_purchases), (SELECT SUM(total_purchase) FROM mart.daily_sales);

    -- 3. Are the assumptions in 03 true? MAX(purchase_sum) only works if it is the same on every row of a receipt.
    INSERT @checks SELECT 'Receipts where purchase_sum differs between rows',
                          0, (SELECT COUNT(*) FROM #r WHERE amount_max <> amount_min);
    INSERT @checks SELECT 'Positive values in points-spent columns',
                          0, (SELECT COUNT_BIG(*) FROM raw.purchases WHERE regular_points_spent > 0 OR express_points_spent > 0);

    -- 4. Does every campaign client have purchase history and demographics?
    INSERT @checks SELECT 'Campaign clients without purchase history',
                          0, (SELECT COUNT(*) FROM raw.uplift_train u
                              WHERE NOT EXISTS (SELECT 1 FROM mart.client_purchases p WHERE p.client_id = u.client_id));
    INSERT @checks SELECT 'Campaign clients without demographics',
                          0, (SELECT COUNT(*) FROM raw.uplift_train u
                              WHERE NOT EXISTS (SELECT 1 FROM raw.clients c WHERE c.client_id = u.client_id));

    -- 5. Do SQL and the separate Python script agree for every single client?
    INSERT @checks SELECT 'Clients whose totals differ between SQL and Python',
                          0, (SELECT COUNT(*)
                              FROM mart.client_purchases m
                              FULL JOIN qa.python_client_purchases p ON p.client_id = m.client_id
                              WHERE m.client_id IS NULL OR p.client_id IS NULL          -- client missing on one side
                                 OR ABS(m.total_purchase       - p.total_purchase)       > 0.01
                                 OR ABS(m.total_points_spent   - p.total_points_spent)   > 0.01
                                 OR ABS(m.total_product_bought - p.total_product_bought) > 0.01
                                 OR m.transactions <> p.transactions);

    -- 6. Information only: a few receipt ids are reused by two different clients.
    --    Harmless, because receipts are grouped by client_id + transaction_id.
    INSERT @checks SELECT 'Receipt ids reused by more than one client (info)',
                          NULL, (SELECT COUNT(*) FROM (SELECT transaction_id FROM #r
                                                       GROUP BY transaction_id HAVING COUNT(*) > 1) AS d);

    INSERT qa.reconcile_log (run_at, check_name, expected, actual, passed)
    SELECT @run_at, check_name, expected, actual,
           CASE WHEN expected IS NULL THEN 1
                WHEN ABS(actual - expected) <= 0.01 THEN 1
                ELSE 0 END
    FROM   @checks;

    SELECT check_name, expected, actual, passed
    FROM   qa.reconcile_log
    WHERE  run_at = @run_at
    ORDER BY reconcile_log_id;
END;
GO
