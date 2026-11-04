CREATE FUNCTION $(NS).usp_report_policy_json(p_policy_number citext)
RETURNS TABLE (policy_json text)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT (
        SELECT json_strip_nulls(json_build_object(
            'policyNumber', p.policy_number,
            'status', p.status,
            'inceptionDate', p.inception_date,
            'annualPremium', p.annual_premium,
            'product', json_build_object('code', pr.product_code, 'name', pr.product_name),
            'holder', json_build_object('name', ph.full_name, 'email', ph.email),
            'broker', CASE WHEN b.broker_code IS NOT NULL THEN json_build_object('code', b.broker_code) END,
            'coverages', (
                SELECT coalesce(json_agg(json_build_object(
                    'code', c.coverage_code,
                    'limit', c.limit_amount,
                    'deductible', c.deductible
                ) ORDER BY c.coverage_code, c.coverage_id), '[]'::json)
                FROM $(NS).coverage AS c
                WHERE c.policy_id = p.policy_id
            )
        ))::text
        FROM $(NS).policy AS p
        INNER JOIN $(NS).product AS pr ON pr.product_id = p.product_id
        INNER JOIN $(NS).policyholder AS ph ON ph.policyholder_id = p.policyholder_id
        LEFT JOIN $(NS).broker AS b ON b.broker_id = p.broker_id
        WHERE p.policy_number = p_policy_number
    );
END;
$$;
