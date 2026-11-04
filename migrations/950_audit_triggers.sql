CREATE OR REPLACE FUNCTION $(NS).trg_policy_status_audit_fn()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_rows integer;
BEGIN
    SELECT count(*) INTO v_rows FROM inserted;
    IF v_rows = 0 THEN
        RETURN NULL;
    END IF;

    INSERT INTO $(NS).audit_log (table_name, action, key_value, old_value, new_value, row_count)
    SELECT 'policy', 'STATUS', i.policy_number, d.status, i.status, v_rows
    FROM inserted AS i
    INNER JOIN deleted AS d ON d.policy_id = i.policy_id
    WHERE i.status IS DISTINCT FROM d.status;
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_policy_status_audit
AFTER UPDATE ON $(NS).policy
REFERENCING OLD TABLE AS deleted NEW TABLE AS inserted
FOR EACH STATEMENT EXECUTE FUNCTION $(NS).trg_policy_status_audit_fn();

CREATE OR REPLACE FUNCTION $(NS).trg_claim_status_audit_fn()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_rows integer;
BEGIN
    SELECT count(*) INTO v_rows FROM inserted;
    IF v_rows = 0 THEN
        RETURN NULL;
    END IF;

    INSERT INTO $(NS).audit_log (table_name, action, key_value, old_value, new_value, row_count)
    SELECT 'claim', 'STATUS', i.claim_number, d.status, i.status, v_rows
    FROM inserted AS i
    INNER JOIN deleted AS d ON d.claim_id = i.claim_id
    WHERE i.status IS DISTINCT FROM d.status;
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_claim_status_audit
AFTER UPDATE ON $(NS).claim
REFERENCING OLD TABLE AS deleted NEW TABLE AS inserted
FOR EACH STATEMENT EXECUTE FUNCTION $(NS).trg_claim_status_audit_fn();

CREATE OR REPLACE FUNCTION $(NS).trg_claim_payment_audit_fn()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_rows integer;
BEGIN
    SELECT count(*) INTO v_rows FROM inserted;
    IF v_rows = 0 THEN
        RETURN NULL;
    END IF;

    INSERT INTO $(NS).audit_log (table_name, action, key_value, old_value, new_value, row_count)
    SELECT
        'claim_payment',
        'PAYMENT',
        string_agg(c.claim_number::text, ',' ORDER BY c.claim_number),
        NULL,
        sum(i.amount)::numeric(38, 4)::text,
        v_rows
    FROM inserted AS i
    INNER JOIN $(NS).claim AS c ON c.claim_id = i.claim_id;
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_claim_payment_audit
AFTER INSERT ON $(NS).claim_payment
REFERENCING NEW TABLE AS inserted
FOR EACH STATEMENT EXECUTE FUNCTION $(NS).trg_claim_payment_audit_fn();
