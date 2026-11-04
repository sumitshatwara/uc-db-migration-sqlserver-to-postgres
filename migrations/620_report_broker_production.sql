CREATE FUNCTION $(NS).usp_report_broker_production(
    p_country_code citext DEFAULT NULL,
    p_line_of_business citext DEFAULT NULL,
    p_top_n integer DEFAULT 10
)
RETURNS TABLE (
    broker_code text,
    broker_contact text,
    country_code text,
    live_policies integer,
    products integer,
    gross_written_premium numeric
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_sql text := '
        SELECT
            b.broker_code::text,
            b.broker_name || '' <'' || b.email::text || ''>'' AS broker_contact,
            b.country_code::text,
            count(*)::integer AS live_policies,
            count(DISTINCT pr.product_code)::integer AS products,
            sum(p.annual_premium) AS gross_written_premium
        FROM $(NS).policy AS p
        INNER JOIN $(NS).broker AS b ON b.broker_id = p.broker_id
        INNER JOIN $(NS).product AS pr ON pr.product_id = p.product_id
        WHERE p.status = ''ACTIVE''';
BEGIN
    IF p_country_code IS NOT NULL THEN
        v_sql := v_sql || ' AND b.country_code = $1';
    END IF;
    IF p_line_of_business IS NOT NULL THEN
        v_sql := v_sql || ' AND pr.line_of_business = $2';
    END IF;
    v_sql := v_sql || '
        GROUP BY b.broker_code, b.broker_name, b.email, b.country_code
        ORDER BY sum(p.annual_premium) DESC
        FETCH FIRST ($3) ROWS WITH TIES';
    RETURN QUERY EXECUTE v_sql USING p_country_code, p_line_of_business, p_top_n;
END;
$$;
