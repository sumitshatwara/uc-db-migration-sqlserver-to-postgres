CREATE FUNCTION $(NS).usp_claim_reserve_set(
    p_claim_id integer,
    p_reserve_type citext,
    p_amount numeric,
    p_set_by text,
    p_as_of timestamp DEFAULT NULL
)
RETURNS TABLE (
    -- MERGE_ACTION is a keyword since PostgreSQL 17, so the legacy column name must be quoted.
    "merge_action" text, -- noqa: RF06
    reserve_type text,
    old_amount numeric,
    new_amount numeric
)
LANGUAGE plpgsql
AS $$
#variable_conflict use_column
DECLARE
    v_reserve_type citext := left(p_reserve_type::text, 10);
    v_amount numeric(19, 4) := p_amount;
    v_set_by varchar(50) := left(p_set_by, 50);
    v_now timestamp(3) := coalesce(p_as_of, now() AT TIME ZONE 'UTC');
    v_paid numeric(19, 4);
    v_old_amount numeric(19, 4);
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM $(NS).claim AS c
        WHERE c.claim_id = p_claim_id AND c.status IN ('OPEN', 'REOPENED')
    ) THEN
        RAISE EXCEPTION 'Claim is not open' USING ERRCODE = 'P0001', DETAIL = '50210';
    END IF;

    SELECT coalesce(sum(cp.amount), 0) INTO v_paid
    FROM $(NS).claim_payment AS cp
    WHERE cp.claim_id = p_claim_id AND cp.reserve_type = v_reserve_type;

    IF v_amount < v_paid THEN
        RAISE EXCEPTION 'Reserve cannot be lower than the amount already paid' USING ERRCODE = 'P0001', DETAIL = '50211';
    END IF;

    -- MERGE ... OUTPUT $action, deleted.amount, inserted.amount: RETURNING on MERGE needs PG17,
    -- so the matched row is read (and locked) first and the branch is taken explicitly.
    SELECT r.amount INTO v_old_amount
    FROM $(NS).claim_reserve AS r
    WHERE r.claim_id = p_claim_id AND r.reserve_type = upper(v_reserve_type)
    FOR UPDATE;

    IF FOUND THEN
        RETURN QUERY
        UPDATE $(NS).claim_reserve AS r
        SET amount = v_amount, set_at = v_now, set_by = v_set_by
        WHERE r.claim_id = p_claim_id AND r.reserve_type = upper(v_reserve_type)
        RETURNING 'UPDATE'::text, r.reserve_type::text, v_old_amount, r.amount;
    ELSE
        RETURN QUERY
        INSERT INTO $(NS).claim_reserve AS r (claim_id, reserve_type, amount, set_at, set_by)
        VALUES (p_claim_id, upper(v_reserve_type), v_amount, v_now, v_set_by)
        RETURNING 'INSERT'::text, r.reserve_type::text, NULL::numeric, r.amount;
    END IF;
END;
$$;
