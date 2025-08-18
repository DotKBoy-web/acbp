-- verify_theorems_public.sql (fixed)
-- Works with public.clinic_visit_* and public.inpatient_admission_* matviews you listed.

-- 0) Scratch table for results (persist through the DO; drop at end)
DROP TABLE IF EXISTS verify_results;
CREATE TEMP TABLE verify_results(
  model   TEXT,
  metric  TEXT,
  value   BIGINT,
  details TEXT
) ON COMMIT PRESERVE ROWS;

DO $$
DECLARE
  mdl TEXT;
  models TEXT[] := ARRAY['clinic_visit','inpatient_admission'];

  ds_table TEXT;  -- public.<model>_decision_space_mat
  vm_table TEXT;  -- public.<model>_valid_masks_mat

  cols TEXT[];           -- columns in decision_space
  excl TEXT[] := ARRAY['route','priority','allow','decision','action','action_code','policy_version','created_at','updated_at'];
  key_cols TEXT[];       -- inferred key = (all cols EXCEPT excl), must include mask
  key_csv TEXT;
  act_cols TEXT[];
  act_csv TEXT;
  act_expr TEXT;

  cnt_missing_masks BIGINT;
  cnt_unused_masks  BIGINT;
  cnt_dup_keys      BIGINT;
  cnt_multi_action  BIGINT;

  have_mask BOOLEAN;
BEGIN
  FOREACH mdl IN ARRAY models LOOP
    ds_table := format('public.%I_decision_space_mat', mdl);
    vm_table := format('public.%I_valid_masks_mat',    mdl);

    -- Ensure matviews exist
    PERFORM 1 FROM pg_matviews WHERE schemaname='public' AND matviewname=(mdl||'_decision_space_mat');
    IF NOT FOUND THEN
      INSERT INTO verify_results VALUES (mdl,'error',NULL, ds_table||' not found'); CONTINUE;
    END IF;

    PERFORM 1 FROM pg_matviews WHERE schemaname='public' AND matviewname=(mdl||'_valid_masks_mat');
    IF NOT FOUND THEN
      INSERT INTO verify_results VALUES (mdl,'error',NULL, vm_table||' not found'); CONTINUE;
    END IF;

    -- Collect columns from decision_space
    SELECT array_agg(column_name::TEXT ORDER BY ordinal_position)
      INTO cols
      FROM information_schema.columns
     WHERE table_schema='public' AND table_name=(mdl||'_decision_space_mat');

    -- Require 'mask'
    have_mask := EXISTS (SELECT 1 FROM unnest(cols) c(col) WHERE col='mask');
    IF NOT have_mask THEN
      INSERT INTO verify_results VALUES (mdl,'error',NULL,'mask column not found in '||ds_table);
      CONTINUE;
    END IF;

    -- Key columns = all minus exclusions, always include mask
    SELECT array_agg(quote_ident(col) ORDER BY col) INTO key_cols
    FROM (
      SELECT col FROM unnest(cols) c(col)
      WHERE col <> ALL(excl)
    ) s;

    IF NOT EXISTS (SELECT 1 FROM unnest(key_cols) k(col) WHERE col='"mask"') THEN
      key_cols := key_cols || ARRAY['"mask"'];
    END IF;

    SELECT string_agg(col, ',') INTO key_csv FROM unnest(key_cols) t(col);

    -- Detect action columns present
    SELECT array_agg(quote_ident(col) ORDER BY col) INTO act_cols
    FROM (
      SELECT col FROM unnest(cols) c(col)
      WHERE col = ANY(ARRAY['route','priority','allow','decision','action','action_code'])
    ) s;

    IF act_cols IS NULL OR array_length(act_cols,1) IS NULL THEN
      act_expr := NULL;
    ELSE
      SELECT string_agg(col, ',') INTO act_csv FROM unnest(act_cols) t(col);
      act_expr := 'concat_ws(''|'', '||act_csv||')';
    END IF;

    -- 1) Bit-soundness: every decision row mask exists in valid_masks
    EXECUTE format($f$
      SELECT count(*) FROM %s d
      LEFT JOIN %s m ON m.mask = d.mask
      WHERE m.mask IS NULL
    $f$, ds_table, vm_table) INTO cnt_missing_masks;

    INSERT INTO verify_results VALUES (mdl, 'soundness_mask_subset_violations', cnt_missing_masks, 'd.mask without match in valid_masks');

    -- 2) Mask coverage: every valid mask appears at least once in decision space
    EXECUTE format($f$
      SELECT count(*) FROM %s m
      LEFT JOIN %s d ON d.mask = m.mask
      WHERE d.mask IS NULL
    $f$, vm_table, ds_table) INTO cnt_unused_masks;

    INSERT INTO verify_results VALUES (mdl, 'mask_coverage_missing', cnt_unused_masks, 'valid mask with no rows in decision_space');

    -- 3) Duplicate keys: same key appears > 1 time
    EXECUTE format($f$
      SELECT count(*) FROM (
        SELECT 1 FROM %s GROUP BY %s HAVING count(*) > 1
      ) t
    $f$, ds_table, key_csv) INTO cnt_dup_keys;

    INSERT INTO verify_results VALUES (mdl, 'duplicate_keys', cnt_dup_keys, 'rows with identical key columns repeated');

    -- 4) Multi-action ambiguity: same key -> >1 distinct action tuple (if action cols exist)
    IF act_expr IS NULL THEN
      INSERT INTO verify_results VALUES (mdl, 'multi_action_ambiguity', NULL, 'skipped (no action columns found)');
    ELSE
      EXECUTE format($f$
        SELECT count(*) FROM (
          SELECT 1 FROM %s GROUP BY %s HAVING COUNT(DISTINCT %s) > 1
        ) t
      $f$, ds_table, key_csv, act_expr) INTO cnt_multi_action;

      INSERT INTO verify_results VALUES (mdl, 'multi_action_ambiguity', cnt_multi_action, 'same key maps to multiple actions');
    END IF;

  END LOOP;

  RAISE NOTICE E'\n=== ACBP verification results (public schema) ===';
END $$;

-- 5) Output + cleanup
TABLE verify_results ORDER BY model, metric;
DROP TABLE IF EXISTS verify_results;
