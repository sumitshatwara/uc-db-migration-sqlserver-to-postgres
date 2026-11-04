CREATE FUNCTION $(NS).usp_report_loss_ratio(p_from_date date, p_to_date date)
RETURNS TABLE (
    product_code text,
    line_of_business text,
    policy_count integer,
    claim_count integer,
    earned_premium numeric,
    paid_claims numeric,
    loss_ratio_pct bigint,
    claims_per_100_policies integer,
    avg_report_lag_days integer
)
LANGUAGE plpgsql
STABLE
AS $$
#variable_conflict use_column
BEGIN
    RETURN QUERY
    WITH earned AS (
        SELECT
            p.product_id,
            round(sum(pp.amount) * 100, 0)::bigint AS premium_cents,
            count(DISTINCT p.policy_id)::integer AS policy_count
        FROM $(NS).premium_payment AS pp
        INNER JOIN $(NS).policy AS p ON p.policy_id = pp.policy_id
        WHERE pp.paid_at >= (p_from_date::timestamp AT TIME ZONE 'UTC')
            AND pp.paid_at < ((p_to_date + 1)::timestamp AT TIME ZONE 'UTC')
        GROUP BY p.product_id
    ),
    incurred AS (
        SELECT
            p.product_id,
            round(coalesce(sum(cp.paid), 0) * 100, 0)::bigint AS paid_cents,
            count(*)::integer AS claim_count,
            trunc(avg(c.reported_at::date - c.loss_date))::integer AS avg_report_lag_days
        FROM $(NS).claim AS c
        INNER JOIN $(NS).policy AS p ON p.policy_id = c.policy_id
        LEFT JOIN LATERAL (
            SELECT sum(x.amount) AS paid
            FROM $(NS).claim_payment AS x
            WHERE x.claim_id = c.claim_id
        ) AS cp ON true
        WHERE c.loss_date BETWEEN p_from_date AND p_to_date
            AND c.status <> 'DENIED'
        GROUP BY p.product_id
    )
    SELECT
        pr.product_code::text,
        pr.line_of_business::text,
        e.policy_count,
        coalesce(i.claim_count, 0),
        e.premium_cents::numeric(19, 2) / 100,
        coalesce(i.paid_cents, 0)::numeric(19, 2) / 100,
        coalesce(i.paid_cents, 0) * 100 / nullif(e.premium_cents, 0),
        coalesce(i.claim_count, 0) * 100 / e.policy_count,
        i.avg_report_lag_days
    FROM earned AS e
    INNER JOIN $(NS).product AS pr ON pr.product_id = e.product_id
    LEFT JOIN incurred AS i ON i.product_id = e.product_id
    ORDER BY pr.product_code;
END;
$$;
