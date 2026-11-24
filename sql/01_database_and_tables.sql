/* =============================================================================
   01  Create the database, schemas and tables
   -----------------------------------------------------------------------------
   Schemas group the tables by purpose:
     raw   untouched copies of the CSV files
     mart  cleaned, summarised tables that the reports read
     qa    reconciliation (data check) results
     rpt   reporting queries
     ops   a simple log of each load / build step
   ========================================================================== */
IF DB_ID('uplift') IS NULL
    CREATE DATABASE uplift;
GO
USE uplift;
GO
IF SCHEMA_ID('raw')  IS NULL EXEC ('CREATE SCHEMA raw');
IF SCHEMA_ID('mart') IS NULL EXEC ('CREATE SCHEMA mart');
IF SCHEMA_ID('qa')   IS NULL EXEC ('CREATE SCHEMA qa');
IF SCHEMA_ID('rpt')  IS NULL EXEC ('CREATE SCHEMA rpt');
IF SCHEMA_ID('ops')  IS NULL EXEC ('CREATE SCHEMA ops');
GO

-- One row per product on a receipt (45.8 million rows).
-- Receipt-level values (purchase_sum, points) repeat on every product row of the same receipt.
IF OBJECT_ID('raw.purchases') IS NULL
CREATE TABLE raw.purchases (
    client_id               VARCHAR(10)   NOT NULL,
    transaction_id          VARCHAR(10)   NOT NULL,   -- receipt id
    transaction_datetime    DATETIME2(0)  NOT NULL,
    regular_points_received DECIMAL(18,4),
    express_points_received DECIMAL(18,4),
    regular_points_spent    DECIMAL(18,4),            -- stored as negative numbers
    express_points_spent    DECIMAL(18,4),            -- stored as negative numbers
    purchase_sum            DECIMAL(18,4),            -- receipt total
    store_id                VARCHAR(10),
    product_id              VARCHAR(10),
    product_quantity        DECIMAL(18,4),
    trn_sum_from_iss        DECIMAL(18,4),
    trn_sum_from_red        DECIMAL(18,4),
    -- columnstore = compressed, column-by-column storage; makes totals over 45M rows fast
    INDEX cci_purchases CLUSTERED COLUMNSTORE
);

IF OBJECT_ID('raw.clients') IS NULL
CREATE TABLE raw.clients (
    client_id         VARCHAR(10) NOT NULL PRIMARY KEY,
    first_issue_date  DATETIME2(0),
    first_redeem_date DATETIME2(0),
    age               INT,
    gender            CHAR(1)      -- F, M or U (unknown)
);

IF OBJECT_ID('raw.uplift_train') IS NULL
CREATE TABLE raw.uplift_train (
    client_id     VARCHAR(10) NOT NULL PRIMARY KEY,
    treatment_flg TINYINT     NOT NULL,   -- 1 = received the SMS, 0 = control group
    target        TINYINT     NOT NULL    -- 1 = bought after the campaign
);

-- One row per client: totals over all of that client's receipts
IF OBJECT_ID('mart.client_purchases') IS NULL
CREATE TABLE mart.client_purchases (
    client_id              VARCHAR(10)   NOT NULL PRIMARY KEY,
    total_points_received  DECIMAL(18,4) NOT NULL,
    total_points_spent     DECIMAL(18,4) NOT NULL,
    total_express_received DECIMAL(18,4) NOT NULL,
    total_express_spent    DECIMAL(18,4) NOT NULL,
    total_product_bought   DECIMAL(18,4) NOT NULL,
    total_purchase         DECIMAL(18,4) NOT NULL,
    transactions           INT           NOT NULL   -- number of receipts
);

-- One row per day
IF OBJECT_ID('mart.daily_sales') IS NULL
CREATE TABLE mart.daily_sales (
    sales_date     DATE          NOT NULL PRIMARY KEY,
    total_purchase DECIMAL(18,4) NOT NULL,
    transactions   INT           NOT NULL
);

IF OBJECT_ID('ops.run_log') IS NULL
CREATE TABLE ops.run_log (
    run_log_id INT IDENTITY PRIMARY KEY,
    logged_at  DATETIME2(0) NOT NULL DEFAULT SYSDATETIME(),
    step       VARCHAR(100) NOT NULL,
    row_count  BIGINT
);

IF OBJECT_ID('qa.reconcile_log') IS NULL
CREATE TABLE qa.reconcile_log (
    reconcile_log_id INT IDENTITY PRIMARY KEY,
    run_at     DATETIME2(0)  NOT NULL,
    check_name VARCHAR(200)  NOT NULL,
    expected   DECIMAL(38,4),
    actual     DECIMAL(38,4),
    passed     BIT           NOT NULL
);

-- The Python version of client totals (data/purchases_by_client.csv), loaded only to compare with SQL
IF OBJECT_ID('qa.python_client_purchases') IS NULL
CREATE TABLE qa.python_client_purchases (
    client_id              VARCHAR(10) NOT NULL PRIMARY KEY,
    total_points_received  DECIMAL(18,4),
    total_points_spent     DECIMAL(18,4),
    total_express_received DECIMAL(18,4),
    total_express_spent    DECIMAL(18,4),
    total_product_bought   DECIMAL(18,4),
    total_purchase         DECIMAL(18,4),
    transactions           INT
);
GO
