CREATE FUNCTION $(NS).usp_claim_close(
    p_claim_id integer,
    p_expected_row_ver xid DEFAULT NULL,
    p_as_of timestamp DEFAULT NULL
)
RETURNS TABLE (
    claim_id integer,
    claim_number text,
    status text,
    closed_at timestamp
)
LANGUAGE plpgsql
AS $$
#variable_conflict use_column
DECLARE
    v_now timestamp(0) := coalesce(p_as_of, now() AT TIME ZONE 'UTC');
    v_rows integer;
BEGIN
    -- ROWVERSION is not migrated: xmin carries the optimistic-concurrency check.
    UPDATE $(NS).claim AS c
    SET status = 'CLOSED', closed_at = v_now
    WHERE c.claim_id = p_claim_id
        AND c.status IN ('OPEN', 'REOPENED')
        AND (p_expected_row_ver IS NULL OR c.xmin = p_expected_row_ver);

    GET DIAGNOSTICS v_rows = ROW_COUNT;

    IF v_rows = 0 THEN
        RAISE EXCEPTION 'Claim is not open or was changed by another user' USING ERRCODE = 'P0001', DETAIL = '50230';
    END IF;

    -- OUTER APPLY (SELECT SUM(...)) -> correlated scalar subquery; ISNULL keeps 0 for unpaid types.
    UPDATE $(NS).claim_reserve AS r
    SET amount = coalesce((
            SELECT sum(cp.amount)
            FROM $(NS).claim_payment AS cp
            WHERE cp.claim_id = r.claim_id AND cp.reserve_type = r.reserve_type
        ), 0),
        set_at = v_now::timestamp(3),
        set_by = 'claims.close'
    WHERE r.claim_id = p_claim_id;

    RETURN QUERY
    SELECT c.claim_id, c.claim_number::text, c.status::text, c.closed_at::timestamp
    FROM $(NS).claim AS c
    WHERE c.claim_id = p_claim_id;
END;
$$;
