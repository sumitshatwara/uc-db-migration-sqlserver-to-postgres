-- New-business quote: base rate, age loading, minimum premium, premium tax.
CREATE FUNCTION $(NS).usp_rate_quote(
    p_product_code citext,
    p_country_code citext,
    p_sum_insured numeric,
    p_date_of_birth date,
    p_start_date date
)
RETURNS TABLE (
    product_code text,
    rated_age integer,
    age_loading numeric,
    net_premium numeric,
    premium_tax numeric,
    gross_premium numeric
)
LANGUAGE plpgsql
STABLE
AS $$
#variable_conflict use_column
DECLARE
    -- DECIMAL(19,4) parameter: rounded to four decimals on entry like the legacy proc.
    v_sum_insured numeric(19, 4) := p_sum_insured;
    v_base_rate numeric(9, 6);
    v_min_premium numeric(19, 4);
    v_tax_rate numeric(5, 4);
    v_years integer;
    v_age integer;
    v_loading numeric(5, 4);
    -- MONEY variables: every assignment rounds to four decimals.
    v_net numeric(19, 4);
    v_tax numeric(19, 4);
BEGIN
    SELECT pr.base_rate, pr.min_premium INTO v_base_rate, v_min_premium
    FROM $(NS).product AS pr
    WHERE pr.product_code = p_product_code AND pr.is_active;

    IF v_base_rate IS NULL THEN
        RAISE EXCEPTION 'Unknown or inactive product' USING ERRCODE = 'P0001', DETAIL = '50100';
    END IF;

    SELECT c.premium_tax_rate INTO v_tax_rate
    FROM $(NS).country AS c
    WHERE c.country_code = p_country_code;

    IF v_tax_rate IS NULL THEN
        RAISE EXCEPTION 'Unknown country code' USING ERRCODE = 'P0001', DETAIL = '50101';
    END IF;

    -- DATEDIFF(YEAR) counts year boundaries; DATEADD(YEAR) clamps 29 February to 28 February,
    -- so a 29 February birthday has its birthday on 28 February in non-leap years.
    v_years := (extract(YEAR FROM p_start_date) - extract(YEAR FROM p_date_of_birth))::integer;
    v_age := v_years
        - CASE WHEN (p_date_of_birth + make_interval(years => v_years))::date > p_start_date THEN 1 ELSE 0 END;

    v_loading := CASE
        WHEN v_age < 25 THEN 0.2500
        WHEN v_age >= 70 THEN 0.1500
        ELSE 0
    END;

    v_net := v_sum_insured * v_base_rate * (1 + v_loading);
    v_net := CASE WHEN v_net < v_min_premium THEN v_min_premium ELSE v_net END;
    v_tax := v_net * v_tax_rate;

    RETURN QUERY
    SELECT
        upper(p_product_code::text),
        v_age,
        v_loading::numeric,
        round(v_net, 2),
        round(v_tax, 2),
        round(v_net, 2) + round(v_tax, 2);
END;
$$;
