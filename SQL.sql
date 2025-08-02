-- =============================================
-- CTE 1: monthly_revenue
-- Purpose: Calculate total monthly revenue per user per game
-- מטרה: לחשב את הרווח החודשי הכולל לכל משתמש ולמשחק
-- =============================================

WITH monthly_revenue AS (
    SELECT 
        DATE(DATE_TRUNC('month', payment_date)) AS payment_month,  -- Truncate payment_date to the first day of the month / חותכים את תאריך התשלום ליום הראשון של החודש
        user_id,                                                    -- User identifier / מזהה משתמש
        game_name,                                                  -- Game name / שם המשחק
        SUM(revenue_amount_usd) AS total_revenue                    -- Sum all revenue in USD for the month / סכום כל ההכנסות בדולרים אמריקאים לחודש
    FROM project.games_payments gp
    GROUP BY 1, 2, 3                                                -- Group by month, user, and game / קבוצות לפי חודש, משתמש ומשחק
),

-- =============================================
-- CTE 2: revenue_lag_lead_months
-- Purpose: Add previous and next calendar months, and lag/lead revenue for churn & growth analysis
-- מטרה: להוסיף את החודש הקודם והבא, וכן הכנסות קודמות/באות לניתוח עזיבה וצמיחה
-- =============================================

revenue_lag_lead_months AS (
    SELECT
        *,
        DATE(payment_month - INTERVAL '1 month') AS previous_calendar_month,  -- Previous month (e.g., Jan -> Dec) / החודש הקודם (למשל ינואר → דצמבר)
        DATE(payment_month + INTERVAL '1 month') AS next_calendar_month,      -- Next month (e.g., Jan -> Feb) / החודש הבא (למשל ינואר → פברואר)
        LAG(total_revenue) OVER (PARTITION BY user_id ORDER BY payment_month) AS previous_paid_month_revenue,  -- Revenue from last paid month / הכנסות מהחודש האחרון ששילמו בו
        LAG(payment_month) OVER (PARTITION BY user_id ORDER BY payment_month) AS previous_paid_month,          -- Last payment month / חודש התשלום האחרון
        LEAD(payment_month) OVER (PARTITION BY user_id ORDER BY payment_month) AS next_paid_month             -- Next payment month / חודש התשלום הבא
    FROM monthly_revenue
),

-- =============================================
-- CTE 3: revenue_metrics
-- Purpose: Calculate key MRR metrics: new, churned, expansion, contraction
-- מטרה: לחשב מדדי MRR מרכזיים: חדשים, עזיבה, הרחבה, הכנה
-- =============================================

revenue_metrics AS (
    SELECT
        payment_month,                                    -- Current month of payment / חודש התשלום הנוכחי
        user_id,                                          -- User ID / מזהה משתמש
        game_name,                                        -- Game name / שם המשחק
        total_revenue,                                    -- Total revenue this month / סה"כ הכנסות בחודש זה
        
        -- NEW MRR: Revenue from users who paid this month but didn't pay last month
        -- MRR חדש: הכנסות ממשתמשים ששילמו החודש אך לא שילמו בחודש הקודם
        CASE
            WHEN previous_paid_month IS NULL
            THEN total_revenue
        END AS new_mrr,

        -- CHURN MONTH: When user stops paying (next payment is missing or not in next calendar month)
        -- חודש עזיבה: כאשר משתמש מפסיק לשלם (אין תשלום הבא או שאינו בחודש הקאלנדרי הבא)
        CASE
            WHEN next_paid_month IS NULL
                 OR next_paid_month != next_calendar_month
            THEN next_calendar_month
        END AS churn_month,

        -- CHURNED REVENUE: Revenue lost when user churns
        -- הכנסות מאבדות: הכנסות שנאבדות כאשר משתמש עוזב
        CASE
            WHEN next_paid_month IS NULL
                 OR next_paid_month != next_calendar_month
            THEN total_revenue
        END AS churned_revenue,

        -- EXPANSION REVENUE: Increase in revenue from existing users (vs. previous month)
        -- הכנסות מתרחבות: עלייה בהכנסות ממשתמשים קיימים (בהשוואה לחודש הקודם)
        CASE
            WHEN previous_paid_month = previous_calendar_month
                 AND total_revenue > previous_paid_month_revenue
            THEN total_revenue - previous_paid_month_revenue
        END AS expansion_revenue,

        -- CONTRACTION REVENUE: Decrease in revenue from existing users
        -- הכנסות מכווצות: ירידה בהכנסות ממשתמשים קיימים
        CASE
            WHEN previous_paid_month = previous_calendar_month
                 AND total_revenue < previous_paid_month_revenue
            THEN total_revenue - previous_paid_month_revenue  -- Negative value / ערך שלילי
        END AS contraction_revenue
    FROM revenue_lag_lead_months
)

-- =============================================
-- Final Output: Revenue metrics + User demographics
-- פלט סופי: מדדי הכנסות + דמוגרפיה של המשתמשים
-- =============================================

SELECT
    rm.*,                                                  -- All revenue metrics / כל מדדי ההכנסות
    gpu.language,                                          -- User's language / שפת המשתמש
    gpu.has_older_device_model,                            -- Whether user has older device / האם למשתמש יש מודל מכשיר ישן
    gpu.age                                                -- User's age group / קבוצת גיל של המשתמש
FROM revenue_metrics rm
LEFT JOIN project.games_paid_users gpu USING (user_id);   -- Join user info / חיבור מידע על המשתמש