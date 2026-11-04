-- Renewal terms: no-claims discount by tenure, loading by recent claims.
CREATE FUNCTION $(NS).usp_rate_renewal(
    p_policy_id integer,
    p_renewal_date date
)
RETURNS TABLE (
    policy_id integer,
    tenure_months integer,
    claims_36m integer,
    sum_insured numeric,
    current_premium numeric,
    ncd_discount numeric,
    claims_loading numeric,
    renewal_premium numeric
)
LANGUAGE plpgsql
STABLE
AS $$
#variable_conflict use_column
DECLARE
    v_tenure_months integer;
    v_premium numeric(19, 4);
    v_sum_insured numeric(19, 4);
    v_claims integer;
    v_discount numeric(5, 4);
    v_loading numeric(5, 4);
BEGIN
    -- DATEDIFF(MONTH) counts month boundaries, not elapsed months.
    SELECT $(NS).fn_months_between(p.inception_date, p_renewal_date) INTO v_tenure_months
    FROM $(NS).policy AS p
    WHERE p.policy_id = p_policy_id;

    IF v_tenure_months IS NULL THEN
        RAISE EXCEPTION 'Policy not found' USING ERRCODE = 'P0001', DETAIL = '50120';
    END IF;

    -- current terms: legacy TOP (1) without ORDER BY reads the clustered index
    -- cx_policy_version_latest (policy_id, effective_from DESC, version_no DESC).
    SELECT v.annual_premium, v.sum_insured INTO v_premium, v_sum_insured
    FROM $(NS).policy_version AS v
    WHERE v.policy_id = p_policy_id
    ORDER BY v.effective_from DESC, v.version_no DESC
    LIMIT 1;

    SELECT count(*)::integer INTO v_claims
    FROM $(NS).claim AS c
    WHERE
        c.policy_id = p_policy_id
        AND c.loss_date >= (p_renewal_date - make_interval(months => 36))::date
        AND c.status <> 'DENIED';

    v_discount := CASE
        WHEN v_claims > 0 THEN 0
        WHEN v_tenure_months >= 60 THEN 0.1500
        WHEN v_tenure_months >= 36 THEN 0.1000
        WHEN v_tenure_months >= 12 THEN 0.0500
        ELSE 0
    END;

    v_loading := CASE
        WHEN v_claims >= 3 THEN 0.5000
        WHEN v_claims = 2 THEN 0.2500
        WHEN v_claims = 1 THEN 0.1000
        ELSE 0
    END;

    RETURN QUERY
    SELECT
        p_policy_id,
        v_tenure_months,
        v_claims,
        v_sum_insured::numeric,
        v_premium::numeric,
        v_discount::numeric,
        v_loading::numeric,
        round(v_premium * (1 - v_discount + v_loading), 2);
END;
$$;
