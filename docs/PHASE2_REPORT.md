# Phase 2 conversion report

Phase 2 converts the 18 rating, claims, reporting, batch and audit-trigger objects to PostgreSQL (Aurora PostgreSQL-compatible).
Five agents did the work, one per group, each in its own namespace and branch. Their branches were combined into `migration/phase2-verify` with git; none of their PRs was merged.

## Reconcile summary

| Run | PASS | FAIL | NOT CONVERTED |
|---|---|---|---|
| Baseline `main`, `NS=dev` | 33 | 0 | 18 |
| Integrated `migration/phase2-verify`, `NS=live` | 51 | 0 | 0 |
| Fixture `make reconcile-naive` (expected to fail) | 50 | 1 (`dbo.usp_report_claims_ageing`) | 0 |

Other gates run on `migration/phase2-verify`:

- `make functional NS=live`: OK. Every scenario step passed: policyholder, policy, endorsement, premium payment, claim open, claim close, and all 7 resulting-state checks, including the audit trail.
- `make batch NS=live` (run date 2026-11-01, rolled back): SQL Server and PostgreSQL return the same counts: marked_overdue=10, policies_affected=10, policies_lapsed=138, installments_cancelled=295, brokers_changed=34, brokers_deactivated=0.
- `make coverage`: 38/38 constructs present. `make lint` (sqlfluff, ruff, yamllint): clean. `make tf-validate`: valid. Terraform was validated only, never planned or applied.

The naive fixture still fails. In its version of `usp_report_claims_ageing`, PostgreSQL uses `COALESCE` where SQL Server's `ISNULL(cause_code, 'UNSPECIFIED')` truncates the fallback to `UNSPECIFIE` (VARCHAR(10)). Its month bands also don't match the SQL Server `DATEDIFF(MONTH)` boundary counts. `migrations/610_report_claims_ageing.sql` handles both.

## Per-object results

### Triggers

Branch `devin/1793793186-phase2-triggers`, PR https://github.com/sumitshatwara/uc-db-migration-sqlserver-to-postgres/pull/2. Objects passing: 3/3. Agent's namespace result: wf_triggers: PASS 36, FAIL 0, NOT CONVERTED 15.

| Object | Target file | T-SQL constructs | Semantic issues handled | Status (`live`) |
|---|---|---|---|---|
| `dbo.trg_claim_payment_audit` | `migrations/950_audit_triggers.sql` | STRING_AGG, triggers (inserted/deleted), @@ROWCOUNT | - SQL Server fires once per statement and exposes inserted-row count through @@ROWCOUNT. PostgreSQL needs a statement transition table; an empty insert must not generate an aggregate audit row.<br>- Translate ordered STRING_AGG into PostgreSQL aggregate ordering, retaining duplicate claim numbers and one audit row for the entire statement.<br>- Source amounts are DECIMAL(19,4), not MONEY. SQL Server SUM returns DECIMAL(38,4); its NVARCHAR representation retains four decimals, including trailing zeroes. Two-decimal formatting failed reconciliation and was corrected. | PASS |
| `dbo.trg_claim_status_audit` | `migrations/950_audit_triggers.sql` | triggers (inserted/deleted), @@ROWCOUNT, UPDATE() in trigger | - PostgreSQL has no UPDATE(status). Audit only actual case-insensitive status changes while row_count includes all claims touched, even unchanged rows. NOT NULL citext statuses preserve the legacy comparison. | PASS |
| `dbo.trg_policy_status_audit` | `migrations/950_audit_triggers.sql` | triggers (inserted/deleted), @@ROWCOUNT, UPDATE() in trigger | - Preserve statement-wide touched-row count, including unchanged policies, while emitting only actual case-insensitive status changes. A per-row trigger would change audit row_count semantics. | PASS |

### Rating

Branch `devin/1793793188-phase2-rating`, PR https://github.com/sumitshatwara/uc-db-migration-sqlserver-to-postgres/pull/1. Objects passing: 3/3. Agent's namespace result: wf_rating: PASS 36, FAIL 0, NOT CONVERTED 15.

| Object | Target file | T-SQL constructs | Semantic issues handled | Status (`live`) |
|---|---|---|---|---|
| `dbo.usp_rate_quote` | `migrations/400_rate_quote.sql` | THROW, DATEADD, DATEDIFF, IIF, money, decimal(19,4), UPPER, ROUND | - Case-insensitive collation lookup; control passes 'motor-priv' and 'de'<br>- DATEDIFF counts year boundaries and DATEADD clamps 29 Feb to 28 Feb: DOB 2000-02-29 on 2025-02-28 gives age 25 (age() gives 24, which would apply the 0.25 under-25 loading)<br>- MONEY variables round to 4 dp on every assignment before ROUND(...,2)<br>- Returns the upper-cased input parameter, not the stored code<br>- Error text must be identical | PASS |
| `dbo.usp_premium_schedule_build` | `migrations/410_premium_schedule_build.sql` | temp tables (#t), THROW, DATEADD, EOMONTH, IIF, money, WHILE loop | - MONEY / TINYINT stays MONEY and truncates at 4 dp (289.0050/12 = 24.0837); numeric would round to 24.0838<br>- Last installment absorbs the truncation remainder<br>- int/int truncates<br>- Month-end anchoring via EOMONTH; each due date is a single DATEADD from inception (not chained), which clamps to month end<br>- Temp table + WHILE loop + conditional insert; a PL/pgSQL temp table would outlive the call<br>- Error text must be identical | PASS |
| `dbo.usp_rate_renewal` | `migrations/420_rate_renewal.sql` | TOP (n), THROW, DATEADD, DATEDIFF, money, decimal(19,4), ROUND, TOP (1) without ORDER BY | - DATEDIFF(MONTH) counts month boundaries: 2023-03-31 to 2026-03-01 is 36 (elapsed is 35), so the 0.10 NCD tier applies<br>- TOP (1) without ORDER BY relies on clustered index cx_policy_version_latest (policy_id, effective_from DESC, version_no DESC); same-day correction (policy 3 versions 2 and 3 both effective 2023-05-06) must return version 3<br>- Single month add (clamps identically); case-insensitive status compare; COUNT(*) is int<br>- MONEY * DECIMAL yields DECIMAL (no intermediate 4-dp rounding), ROUND half away from zero<br>- Error text must be identical | PASS |

### Claims

Branch `devin/1793793752-phase2-claims`, PR https://github.com/sumitshatwara/uc-db-migration-sqlserver-to-postgres/pull/4. Objects passing: 4/4. Agent's namespace result: wf_claims: PASS 40, FAIL 0, NOT CONVERTED 11.

| Object | Target file | T-SQL constructs | Semantic issues handled | Status (`live`) |
|---|---|---|---|---|
| `dbo.usp_claim_open` | `migrations/500_claim_open.sql` | SCOPE_IDENTITY(), TOP (n), THROW, IIF, decimal(19,4), datetime2, NEXT VALUE FOR, BEGIN TRAN / COMMIT / ROLLBACK, SET XACT_ABORT ON, string + concatenation, OUTPUT parameter, TOP (1) without ORDER BY | - TOP (1) without ORDER BY relies on clustered index cx_policy_version_latest (policy_id, effective_from DESC, version_no DESC); PG has no clustered order<br>- NEXT VALUE FOR -> nextval; RIGHT keeps rightmost 9 digits whereas lpad truncates on the right for >9 digits<br>- IIF and SCOPE_IDENTITY do not exist; OUTPUT param @claim_id already the first result column<br>- lower-case policy number must match CI collation; DECIMAL(19,4)/DATETIME2(0)/VARCHAR(n) params round/truncate on entry; PG ignores typmods on params | PASS |
| `dbo.usp_claim_reserve_set` | `migrations/510_claim_reserve_set.sql` | MERGE, table variables, THROW, ISNULL, decimal(19,4), datetime2, OUTPUT $action, OUTPUT deleted.*, UPPER, SYSUTCDATETIME() | - PG15/16 MERGE has no RETURNING and merge_action() is PG17+; table variable output<br>- MERGE_ACTION is a keyword in PostgreSQL 17+/18, bare column name is a syntax error<br>- lower-case reserve type must match case-insensitively (CI collation) | PASS |
| `dbo.usp_claim_payment_record` | `migrations/520_claim_payment_record.sql` | TRY...CATCH, RAISERROR, ISNULL, decimal(19,4), datetime2, @@ROWCOUNT, BEGIN TRAN / COMMIT / ROLLBACK, @@TRANCOUNT, UPPER | - RAISERROR formats with printf args, error number 50000, NULL args print '(null)', message keeps caller's casing<br>- no explicit transactions in PG functions; @@ROWCOUNT<br>- half-cent 100.005 must be held as numeric(19,4) like the legacy param | PASS |
| `dbo.usp_claim_close` | `migrations/530_claim_close.sql` | OUTER APPLY, THROW, ISNULL, datetime2, @@ROWCOUNT, BEGIN TRAN / COMMIT / ROLLBACK, SET XACT_ABORT ON, SYSUTCDATETIME() | - OUTER APPLY in UPDATE ... FROM not available<br>- ROWVERSION not migrated; @@ROWCOUNT<br>- SYSUTCDATETIME and DATETIME2(0) rounding | PASS |

### Reporting

Branch `devin/1793793186-phase2-reporting`, PR https://github.com/sumitshatwara/uc-db-migration-sqlserver-to-postgres/pull/3. Objects passing: 4/4. Agent's namespace result: wf_reporting: PASS 37, FAIL 0, NOT CONVERTED 14.

| Object | Target file | T-SQL constructs | Semantic issues handled | Status (`live`) |
|---|---|---|---|---|
| `dbo.usp_report_loss_ratio` | `migrations/600_report_loss_ratio.sql` | OUTER APPLY, temp tables (#t), DATEADD, DATEDIFF, ISNULL, datetimeoffset, ROUND, CAST AS DATETIMEOFFSET, integer division | - DATE to DATETIMEOFFSET casts use midnight UTC; preserve the half-open range without depending on session timezone.<br>- DATEDIFF(DAY) counts calendar boundaries and AVG(integer) truncates. PostgreSQL AVG returns numeric and a direct integer cast rounds.<br>- Round aggregate MONEY to cents before doing deliberate integer percentage division; preserve NULL on a zero denominator.<br>- BIGINT/INT division must truncate; numeric percentages would change legacy results. | PASS |
| `dbo.usp_report_claims_ageing` | `migrations/610_report_claims_ageing.sql` | CROSS APPLY, OUTER APPLY, DATEDIFF, ISNULL, UPPER, string + concatenation | - ISNULL uses cause_code VARCHAR(10), truncating the fallback UNSPECIFIED to UNSPECIFIE; COALESCE alone does not.<br>- DATEDIFF counts month boundaries, not elapsed months; use the existing helper for every age threshold. | PASS |
| `dbo.usp_report_broker_production` | `migrations/620_report_broker_production.sql` | TOP ... WITH TIES, sp_executesql, string + concatenation | - TOP WITH TIES includes every broker at the cutoff; LIMIT alone loses rows.<br>- Keep dynamic query values bound and retain case-insensitive country/business filters with citext rather than text.<br>- String + propagates NULL email; concat() would omit the NULL operand. | PASS |
| `dbo.usp_report_policy_json` | `migrations/630_report_policy_json.sql` | FOR JSON PATH, WITHOUT_ARRAY_WRAPPER | - FOR JSON PATH omits NULL keys and the all-NULL broker parent, nests dotted paths, emits ordered coverage arrays (including [] when empty), and returns scalar NULL for no policy. A citext lookup preserves case-insensitive policy numbers. | PASS |

### Batch

Branch `devin/1793793759-phase2-batch`, PR https://github.com/sumitshatwara/uc-db-migration-sqlserver-to-postgres/pull/5. Objects passing: 4/4. Agent's namespace result: wf_batch: PASS 40, FAIL 0, NOT CONVERTED 11.

| Object | Target file | T-SQL constructs | Semantic issues handled | Status (`live`) |
|---|---|---|---|---|
| `dbo.usp_batch_mark_overdue` | `migrations/700_batch_mark_overdue.sql` | OUTPUT INSERTED.*, table variables, DATEADD | - OUTPUT INTO table variable and DATEADD have no PG equivalent | PASS |
| `dbo.usp_batch_lapse_overdue` | `migrations/710_batch_lapse_overdue.sql` | cursor, @@FETCH_STATUS, DATEDIFF, datetime2, @@ROWCOUNT, WHILE loop | - Cursor issues one UPDATE per policy, so statement-level trg_policy_status_audit writes one audit_log row per policy with row_count = 1; a set-based UPDATE would write row_count = N and fail the audit_log state check<br>- DATEDIFF(MONTH) counts month boundaries, age() counts elapsed months<br>- @@ROWCOUNT has no PG equivalent; must be read straight after the statement | PASS |
| `dbo.usp_batch_sync_broker_commission` | `migrations/720_batch_sync_broker_commission.sql` | MERGE, temp tables (#t), table variables, ISNULL, IIF, money, OUTPUT $action, OUTPUT deleted.* | - MERGE WHEN NOT MATCHED BY SOURCE and RETURNING merge_action() are PG17-only; not allowed for Aurora PG15+<br>- ISNULL/IIF are T-SQL only | PASS |
| `dbo.usp_batch_nightly` | `migrations/730_batch_nightly.sql` | temp tables (#t), TRY...CATCH, RAISERROR, ISNULL, INSERT ... EXEC, ERROR_MESSAGE(), SYSUTCDATETIME() | - INSERT ... EXEC and TRY/CATCH/RAISERROR (error 50000, @msg NVARCHAR(2048)) are T-SQL only. SQL Server also keeps the earlier steps' changes after a failure (no outer transaction, XACT_ABORT off), but PG rolls back the whole call. No control covers that case.<br>- SYSUTCDATETIME() is UTC wall clock | PASS |

## Known behavioural differences

- `usp_batch_nightly`: if a step fails, SQL Server keeps the changes from the steps that already ran (there is no explicit transaction) and then raises `Nightly batch failed: ...` (50000). PostgreSQL functions run inside the caller's transaction, so the whole call is undone. The error text is the same. The cutover runbook should say that a failed nightly run on PostgreSQL leaves no partial changes.
- `usp_claim_close`: `ROWVERSION` is not migrated. The optimistic-concurrency check uses `xmin` (`p_expected_row_ver xid`), so callers must pass the value they read from PostgreSQL, not a SQL Server rowversion.
- `usp_claim_reserve_set`: PostgreSQL 15 and 16 have no `MERGE ... RETURNING` and no `merge_action()`, so the function reads and locks the existing row, then runs either an UPDATE or an INSERT. The legacy result column `merge_action` is quoted because `MERGE_ACTION` is a keyword from PostgreSQL 17.
