-- usp_batch_mark_overdue: flag installments more than 14 days past due.
-- UPDATE ... OUTPUT INTO @changed -> data-modifying CTE with RETURNING.
CREATE FUNCTION $(NS).usp_batch_mark_overdue(p_run_date date)
RETURNS TABLE (
    marked_overdue integer,
    policies_affected integer
)
LANGUAGE plpgsql
AS $$
#variable_conflict use_column
BEGIN
    RETURN QUERY
    WITH changed AS (
        UPDATE $(NS).premium_schedule AS s
        SET status = 'OVERDUE'
        WHERE s.status = 'DUE'
            AND s.due_date < p_run_date - 14
            AND s.paid_amount < s.amount_due
        RETURNING s.schedule_id, s.policy_id
    )
    SELECT
        count(*)::integer,
        count(DISTINCT changed.policy_id)::integer
    FROM changed;
END;
$$;
