CREATE FUNCTION $(NS).usp_claim_open(
    p_policy_number citext,
    p_loss_date date,
    p_reported_at timestamp,
    p_cause_code citext DEFAULT NULL,
    p_description text DEFAULT NULL,
    p_initial_estimate numeric DEFAULT NULL,
    p_set_by text DEFAULT 'claims.intake'
)
RETURNS TABLE (
    claim_id integer,
    claim_number text,
    policy_id integer,
    loss_date date,
    status text,
    sum_insured numeric,
    indemnity_reserve numeric
)
LANGUAGE plpgsql
AS $$
#variable_conflict use_column
DECLARE
    -- Legacy parameter types: VARCHAR/NVARCHAR(n) truncate, DATETIME2(0) and DECIMAL(19,4) round on entry.
    v_policy_number citext := left(p_policy_number::text, 20);
    v_reported_at timestamp(0) := p_reported_at;
    v_cause_code citext := left(p_cause_code::text, 10);
    v_description varchar(400) := left(p_description, 400);
    v_initial_estimate numeric(19, 4) := p_initial_estimate;
    v_set_by varchar(50) := left(p_set_by, 50);
    v_policy_id integer;
    v_status citext;
    v_inception date;
    v_expiry date;
    v_sum_insured numeric(19, 4);
    v_reserve numeric(19, 4);
    v_claim_number text;
    v_claim_id integer;
BEGIN
    SELECT p.policy_id, p.status, p.inception_date, p.expiry_date
    INTO v_policy_id, v_status, v_inception, v_expiry
    FROM $(NS).policy AS p
    WHERE p.policy_number = v_policy_number;

    IF v_policy_id IS NULL THEN
        RAISE EXCEPTION 'Policy not found' USING ERRCODE = 'P0001', DETAIL = '50200';
    END IF;

    IF v_status IN ('QUOTE', 'CANCELLED') THEN
        RAISE EXCEPTION 'Policy is not on cover' USING ERRCODE = 'P0001', DETAIL = '50201';
    END IF;

    IF p_loss_date < v_inception OR p_loss_date > v_expiry THEN
        RAISE EXCEPTION 'Loss date is outside the period of cover' USING ERRCODE = 'P0001', DETAIL = '50202';
    END IF;

    -- TOP (1) without ORDER BY reads the clustered index cx_policy_version_latest
    -- (policy_id, effective_from DESC, version_no DESC): the current version.
    SELECT v.sum_insured INTO v_sum_insured
    FROM $(NS).policy_version AS v
    WHERE v.policy_id = v_policy_id
    ORDER BY v.effective_from DESC, v.version_no DESC
    LIMIT 1;

    v_reserve := CASE WHEN v_initial_estimate > v_sum_insured THEN v_sum_insured ELSE v_initial_estimate END;
    -- RIGHT('000000000' + n, 9) keeps the rightmost nine digits; lpad() would cut on the right.
    v_claim_number := 'C' || right('000000000' || nextval('$(NS).seq_claim_number')::text, 9);

    INSERT INTO $(NS).claim (claim_number, policy_id, loss_date, reported_at, cause_code, status, description)
    VALUES (v_claim_number, v_policy_id, p_loss_date, v_reported_at, v_cause_code, 'OPEN', v_description)
    RETURNING claim.claim_id INTO v_claim_id;

    INSERT INTO $(NS).claim_reserve (claim_id, reserve_type, amount, set_at, set_by)
    VALUES (v_claim_id, 'INDEMNITY', v_reserve, v_reported_at::timestamp(3), v_set_by);

    RETURN QUERY
    SELECT
        c.claim_id,
        c.claim_number::text,
        c.policy_id,
        c.loss_date,
        c.status::text,
        v_sum_insured,
        r.amount
    FROM $(NS).claim AS c
    INNER JOIN $(NS).claim_reserve AS r ON r.claim_id = c.claim_id AND r.reserve_type = 'INDEMNITY'
    WHERE c.claim_id = v_claim_id;
END;
$$;
