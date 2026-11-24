/* =============================================================================
   05  rpt.usp_uplift_by_segment: did the SMS work, and for which customers?
   -----------------------------------------------------------------------------
   For each segment: conversion rate of clients who got the SMS, conversion rate
   of the control group, the difference (uplift), and a 95% confidence interval.

     EXEC rpt.usp_uplift_by_segment @segment = 'all';      -- whole campaign
     EXEC rpt.usp_uplift_by_segment @segment = 'spend';    -- by spend quartile
     EXEC rpt.usp_uplift_by_segment @segment = 'age';
     EXEC rpt.usp_uplift_by_segment @segment = 'gender';
     EXEC rpt.usp_uplift_by_segment @segment = 'points';   -- redeemed loyalty points or not
   ========================================================================== */
USE uplift;
GO
CREATE OR ALTER PROCEDURE rpt.usp_uplift_by_segment
    @segment VARCHAR(10) = 'all'
AS
BEGIN
    SET NOCOUNT ON;

    WITH labelled AS (
        -- pick the column to group by
        SELECT  CASE @segment
                    WHEN 'spend'  THEN spend_quartile
                    WHEN 'age'    THEN age_band
                    WHEN 'gender' THEN gender
                    WHEN 'points' THEN points_segment
                    ELSE 'All campaign clients'
                END AS segment,
                treatment_flg,
                -- FLOAT so AVG gives a fraction, not a whole number. Not DECIMAL: SQL Server keeps only
                -- 6 decimal places in DECIMAL division, which cut the tiny p(1-p)/n values and made the CIs wrong.
                CAST(target AS FLOAT) AS target
        FROM    mart.campaign_clients
    ),
    rates AS (
        -- AVG of a 0/1 column = the share of 1s, i.e. the conversion rate.
        -- CASE without ELSE returns NULL for the other group, and AVG ignores NULLs.
        SELECT  segment,
                COUNT(*)                                          AS clients,
                SUM(CASE WHEN treatment_flg = 1 THEN 1 ELSE 0 END) AS sms_clients,
                SUM(CASE WHEN treatment_flg = 0 THEN 1 ELSE 0 END) AS control_clients,
                AVG(CASE WHEN treatment_flg = 1 THEN target END)  AS sms_rate,
                AVG(CASE WHEN treatment_flg = 0 THEN target END)  AS control_rate
        FROM    labelled
        GROUP BY segment
    ),
    uplift AS (
        -- standard error of a difference between two proportions
        SELECT  *,
                sms_rate - control_rate AS uplift,
                SQRT(sms_rate * (1 - sms_rate) / sms_clients
                   + control_rate * (1 - control_rate) / control_clients) AS std_error
        FROM    rates
    )
    -- CAST to DECIMAL(5,2) only for display: percentages with 2 decimals
    SELECT  segment,
            clients,
            CAST(100 * sms_rate                     AS DECIMAL(5,2)) AS sms_conversion_pct,
            CAST(100 * control_rate                 AS DECIMAL(5,2)) AS control_conversion_pct,
            CAST(100 * uplift                       AS DECIMAL(5,2)) AS uplift_pp,     -- percentage points
            CAST(100 * (uplift - 1.96 * std_error)  AS DECIMAL(5,2)) AS ci_low_pp,     -- 95% interval:
            CAST(100 * (uplift + 1.96 * std_error)  AS DECIMAL(5,2)) AS ci_high_pp,    -- uplift +/- 1.96 x SE
            CASE WHEN uplift - 1.96 * std_error > 0 THEN 'yes' ELSE 'no' END AS clearly_above_zero
    FROM    uplift
    ORDER BY segment;
END;
GO
