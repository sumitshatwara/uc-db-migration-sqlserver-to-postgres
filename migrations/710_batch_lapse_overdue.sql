-- usp_batch_lapse_overdue: lapse active policies whose oldest overdue installment
-- is two months old.
-- The legacy cursor updates one policy per statement, so trg_policy_status_audit
-- fires once per policy (audit_log.row_count = 1). Keep the row-by-row loop; a
-- set-based UPDATE would write one audit row per policy with row_count = N.
-- DATEDIFF(MONTH) counts month boundaries: fn_months_between, not age().
CREATE FUNCTION $(NS).usp_batch_lapse_overdue(p_run_date date)
RETURNS TABLE (
    policies_lapsed integer,
    installments_cancelled integer
)
LANGUAGE plpgsql
AS $$
#variable_conflict use_column
DECLARE
    v_policy_id integer;
    v_rows integer;
    v_lapsed integer := 0;
    v_cancelled integer := 0;
BEGIN
    FOR v_policy_id IN
        SELECT ps.policy_id
        FROM $(NS).premium_schedule AS ps
        INNER JOIN $(NS).policy AS p ON ps.policy_id = p.policy_id
        WHERE ps.status = 'OVERDUE' AND p.status = 'ACTIVE'
        GROUP BY ps.policy_id
        HAVING $(NS).fn_months_between(min(ps.due_date), p_run_date) >= 2
        ORDER BY ps.policy_id
    LOOP
        UPDATE $(NS).policy AS p
        SET status = 'LAPSED', updated_at = p_run_date::timestamp(3)
        WHERE p.policy_id = v_policy_id;
        GET DIAGNOSTICS v_rows = ROW_COUNT;
        v_lapsed := v_lapsed + v_rows;

        UPDATE $(NS).premium_schedule AS s
        SET status = 'CANCELLED'
        WHERE s.policy_id = v_policy_id AND s.status = 'DUE' AND s.due_date >= p_run_date;
        GET DIAGNOSTICS v_rows = ROW_COUNT;
        v_cancelled := v_cancelled + v_rows;
    END LOOP;

    RETURN QUERY SELECT v_lapsed, v_cancelled;
END;
$$;
