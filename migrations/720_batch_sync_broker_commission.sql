-- usp_batch_sync_broker_commission: re-tier broker commission from live premium;
-- deactivate brokers with no live book.
-- MERGE ... WHEN NOT MATCHED BY SOURCE needs PostgreSQL 17 and OUTPUT $action
-- needs RETURNING merge_action() (PG17). Both legacy branches are UPDATEs, so
-- one UPDATE over broker LEFT JOIN tier replays them on PostgreSQL 15+.
-- #tier -> CTE; @changes -> RETURNING; ISNULL(SUM(IIF(...)), 0) -> coalesce(sum(CASE)).
CREATE FUNCTION $(NS).usp_batch_sync_broker_commission(p_run_date date)
RETURNS TABLE (
    brokers_changed integer,
    brokers_deactivated integer
)
LANGUAGE plpgsql
AS $$
#variable_conflict use_column
BEGIN
    RETURN QUERY
    WITH tier AS (
        SELECT
            p.broker_id,
            sum(p.annual_premium)::numeric(19, 4) AS live_gwp,
            (CASE
                WHEN sum(p.annual_premium) >= 150000 THEN 15.00
                WHEN sum(p.annual_premium) >= 75000 THEN 12.50
                ELSE 10.00
            END)::numeric(5, 2) AS new_pct
        FROM $(NS).policy AS p
        WHERE p.status = 'ACTIVE' AND p.broker_id IS NOT NULL AND p.inception_date <= p_run_date
        GROUP BY p.broker_id
    ),

    src AS (
        SELECT
            b.broker_id,
            tr.new_pct,
            tr.broker_id IS NOT NULL AS matched
        FROM $(NS).broker AS b
        LEFT JOIN tier AS tr ON b.broker_id = tr.broker_id
    ),

    changes AS (
        UPDATE $(NS).broker AS t
        SET
            commission_pct = CASE WHEN src.matched THEN src.new_pct ELSE t.commission_pct END,
            is_active = src.matched
        FROM src
        WHERE
            t.broker_id = src.broker_id
            AND (
                (src.matched AND (t.commission_pct <> src.new_pct OR NOT t.is_active))
                OR (NOT src.matched AND t.is_active)
            )
        RETURNING t.broker_id, t.is_active
    )

    SELECT
        count(*)::integer,
        coalesce(sum(CASE WHEN NOT changes.is_active THEN 1 ELSE 0 END), 0)::integer
    FROM changes;
END;
$$;
