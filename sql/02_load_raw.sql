/* =============================================================================
   02  ops.usp_load_raw: load the three CSV files into the raw tables
   -----------------------------------------------------------------------------
   Each table is emptied (TRUNCATE) and reloaded (BULK INSERT), so the procedure
   can be re-run safely. The CSVs are mounted into the container at /data.
   ========================================================================== */
USE uplift;
GO
CREATE OR ALTER PROCEDURE ops.usp_load_raw
AS
BEGIN
    SET NOCOUNT ON;

    -- Only one load or build may run at a time. During development two loads overlapped,
    -- both wrote into raw.purchases, and it ended up with 77.9M rows instead of 45.8M.
    -- The lock belongs to this connection and is released when it closes, even after an error.
    DECLARE @lock INT;
    EXEC @lock = sp_getapplock @Resource = 'uplift_pipeline', @LockMode = 'Exclusive',
                               @LockOwner = 'Session', @LockTimeout = 0;
    IF @lock < 0
        THROW 50001, 'Another load or build is already running.', 1;

    -- FORMAT = 'CSV' handles quoted fields; FIRSTROW = 2 skips the header; the files use LF line endings.
    TRUNCATE TABLE raw.uplift_train;
    BULK INSERT raw.uplift_train FROM '/data/uplift_train.csv'
        WITH (FORMAT = 'CSV', FIRSTROW = 2, ROWTERMINATOR = '0x0a');
    INSERT ops.run_log (step, row_count) SELECT 'load raw.uplift_train', COUNT(*) FROM raw.uplift_train;

    TRUNCATE TABLE raw.clients;
    BULK INSERT raw.clients FROM '/data/clients.csv'
        WITH (FORMAT = 'CSV', FIRSTROW = 2, ROWTERMINATOR = '0x0a');
    INSERT ops.run_log (step, row_count) SELECT 'load raw.clients', COUNT(*) FROM raw.clients;

    -- TABLOCK + 1M-row batches let SQL Server write straight into compressed columnstore segments.
    TRUNCATE TABLE raw.purchases;
    BULK INSERT raw.purchases FROM '/data/purchases.csv'
        WITH (FORMAT = 'CSV', FIRSTROW = 2, ROWTERMINATOR = '0x0a', TABLOCK, BATCHSIZE = 1048576);
    INSERT ops.run_log (step, row_count) SELECT 'load raw.purchases', COUNT_BIG(*) FROM raw.purchases;

    EXEC sp_releaseapplock @Resource = 'uplift_pipeline', @LockOwner = 'Session';
END;
GO
