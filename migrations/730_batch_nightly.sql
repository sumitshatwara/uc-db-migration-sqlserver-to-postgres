-- usp_batch_nightly: nightly batch driver.
-- INSERT INTO #t EXEC proc -> SELECT ... INTO from the converted functions.
-- TRY/CATCH + RAISERROR(N'Nightly batch failed: %s', 16, 1, @msg) -> EXCEPTION block
-- re-raising the same text (RAISERROR with a string message is error 50000).
-- @msg is NVARCHAR(2048), so ERROR_MESSAGE() is cut to 2048 characters.
CREATE FUNCTION $(NS).usp_batch_nightly(p_run_date date DEFAULT NULL)
RETURNS TABLE (
    run_date date,
    marked_overdue integer,
    policies_affected integer,
    policies_lapsed integer,
    installments_cancelled integer,
    brokers_changed integer,
    brokers_deactivated integer
)
LANGUAGE plpgsql
AS $$
#variable_conflict use_column
DECLARE
    v_run_date date := coalesce(p_run_date, (now() AT TIME ZONE 'UTC')::date);
    v_overdue record;
    v_lapse record;
    v_commission record;
BEGIN
    BEGIN
        SELECT * INTO v_overdue FROM $(NS).usp_batch_mark_overdue(p_run_date => v_run_date);
        SELECT * INTO v_lapse FROM $(NS).usp_batch_lapse_overdue(p_run_date => v_run_date);
        SELECT * INTO v_commission FROM $(NS).usp_batch_sync_broker_commission(p_run_date => v_run_date);
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'Nightly batch failed: %', left(SQLERRM, 2048)
            USING ERRCODE = 'P0001', DETAIL = '50000';
    END;

    RETURN QUERY SELECT
        v_run_date,
        v_overdue.marked_overdue,
        v_overdue.policies_affected,
        v_lapse.policies_lapsed,
        v_lapse.installments_cancelled,
        v_commission.brokers_changed,
        v_commission.brokers_deactivated;
END;
$$;
