-- Build the installment plan for a policy. Installments are kept to the
-- fourth decimal (as finance books them); the last one absorbs the remainder
-- so the plan always adds up to the annual premium.
CREATE FUNCTION $(NS).usp_premium_schedule_build(
    p_policy_id integer,
    p_commit boolean DEFAULT true
)
RETURNS TABLE (
    installment_no smallint,
    due_date date,
    amount_due numeric
)
LANGUAGE plpgsql
AS $$
#variable_conflict use_column
DECLARE
    v_annual numeric(19, 4);
    v_frequency smallint;
    v_inception date;
    v_installment numeric(19, 4);
    v_step integer;
    v_month_end boolean;
BEGIN
    SELECT p.annual_premium, p.payment_frequency, p.inception_date
    INTO v_annual, v_frequency, v_inception
    FROM $(NS).policy AS p
    WHERE p.policy_id = p_policy_id;

    IF v_annual IS NULL THEN
        RAISE EXCEPTION 'Policy not found' USING ERRCODE = 'P0001', DETAIL = '50110';
    END IF;

    IF EXISTS (SELECT 1 FROM $(NS).premium_schedule AS s WHERE s.policy_id = p_policy_id) THEN
        RAISE EXCEPTION 'Policy already has a premium schedule' USING ERRCODE = 'P0001', DETAIL = '50111';
    END IF;

    -- MONEY / TINYINT stays MONEY and truncates at four decimals; numeric would round.
    v_installment := trunc(v_annual / v_frequency, 4);
    -- int / int truncates in both engines.
    v_step := 12 / v_frequency;
    v_month_end := v_inception = (date_trunc('month', v_inception) + interval '1 month - 1 day')::date;

    -- The #plan temp table and WHILE loop become one CTE over generate_series;
    -- the data-modifying CTE runs only when p_commit is set.
    RETURN QUERY
    WITH plan AS (
        SELECT
            g.n::smallint AS installment_no,
            CASE
                WHEN v_month_end
                    THEN (
                        date_trunc('month', v_inception + make_interval(months => (g.n - 1) * v_step))
                        + interval '1 month - 1 day'
                    )::date
                ELSE (v_inception + make_interval(months => (g.n - 1) * v_step))::date
            END AS due_date,
            CASE
                WHEN g.n = v_frequency THEN v_annual - v_installment * (v_frequency - 1)
                ELSE v_installment
            END::numeric(19, 4) AS amount_due
        FROM generate_series(1, v_frequency::integer) AS g (n)
    ),

    ins AS (
        INSERT INTO $(NS).premium_schedule (policy_id, installment_no, due_date, amount_due, paid_amount, status)
        SELECT p_policy_id, pl.installment_no, pl.due_date, pl.amount_due, 0, 'DUE'
        FROM plan AS pl
        WHERE p_commit
        ORDER BY pl.installment_no
    )

    SELECT pl.installment_no, pl.due_date, pl.amount_due::numeric
    FROM plan AS pl
    ORDER BY pl.installment_no;
END;
$$;
