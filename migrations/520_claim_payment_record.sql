CREATE FUNCTION $(NS).usp_claim_payment_record(
    p_claim_id integer,
    p_reserve_type citext,
    p_amount numeric,
    p_payee_name text,
    p_paid_at timestamp,
    p_payee_iban text DEFAULT NULL
)
RETURNS TABLE (
    claim_id integer,
    reserve_type text,
    amount numeric,
    rows_written integer,
    outstanding_after numeric
)
LANGUAGE plpgsql
AS $$
#variable_conflict use_column
DECLARE
    v_reserve_type citext := left(p_reserve_type::text, 10);
    v_amount numeric(19, 4) := p_amount;
    v_payee_name varchar(200) := left(p_payee_name, 200);
    v_payee_iban varchar(34) := left(p_payee_iban, 34);
    v_paid_at timestamp(3) := p_paid_at;
    v_status citext;
    v_reserve numeric(19, 4);
    v_paid numeric(19, 4);
    v_payment_rows integer;
BEGIN
    SELECT c.status INTO v_status FROM $(NS).claim AS c WHERE c.claim_id = p_claim_id;

    -- RAISERROR without a message number raises 50000; %d / %s print NULL as '(null)'.
    IF v_status IS NULL OR v_status NOT IN ('OPEN', 'REOPENED') THEN
        RAISE EXCEPTION 'Claim % is not open for payment', coalesce(p_claim_id::text, '(null)')
            USING ERRCODE = 'P0001', DETAIL = '50000';
    END IF;

    SELECT r.amount INTO v_reserve
    FROM $(NS).claim_reserve AS r
    WHERE r.claim_id = p_claim_id AND r.reserve_type = v_reserve_type;

    SELECT coalesce(sum(cp.amount), 0) INTO v_paid
    FROM $(NS).claim_payment AS cp
    WHERE cp.claim_id = p_claim_id AND cp.reserve_type = v_reserve_type;

    IF v_paid + v_amount > coalesce(v_reserve, 0) THEN
        RAISE EXCEPTION 'Payment exceeds the outstanding % reserve', coalesce(v_reserve_type::text, '(null)')
            USING ERRCODE = 'P0001', DETAIL = '50000';
    END IF;

    INSERT INTO $(NS).claim_payment (claim_id, reserve_type, paid_at, amount, payee_name, payee_iban)
    VALUES (p_claim_id, upper(v_reserve_type), v_paid_at, v_amount, v_payee_name, v_payee_iban);

    GET DIAGNOSTICS v_payment_rows = ROW_COUNT;

    RETURN QUERY
    SELECT
        p_claim_id,
        upper(v_reserve_type)::text,
        v_amount,
        v_payment_rows,
        coalesce(v_reserve, 0) - v_paid - v_amount;
END;
$$;
