-- verify_theorems_public_auto.sql (v3: pg_catalog-aware)
-- Models: clinic_visit, inpatient_admission
-- Checks: mask soundness, mask coverage, duplicate keys, multi-action ambiguity

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

  ds_tbl TEXT; vm_tbl TEXT;

  -- columns fetched from pg_catalog for materialized views
  ds_cols TEXT[]; vm_cols TEXT[];
  ds_cols_csv TEXT; vm_cols_csv TEXT;

  ds_mask_col TEXT; vm_mask_col TEXT;

  excl TEXT[] := ARRAY[
    'route','priority','allow','decision','action','action_code',
    'policy_version','created_at','updated_at','n','cnt','count'
  ];
  key_cols TEXT[]; key_csv TEXT;

  act_cols TEXT[]; act_csv TEXT; act_expr TEXT;

  cnt_missing_masks BIGINT;
  cnt_unused_masks  BIGINT;
  cnt_dup_keys      BIGINT;
  cnt_multi_action  BIGINT;

  msg TEXT;
BEGIN
  FOR mdl IN SELECT unnest(models) LOOP
    ds_tbl := format('public.%I_decision_space_mat', mdl);
    vm_tbl := format('public.%I_valid_masks_mat',    mdl);

    -- Ensure the matviews exist
    PERFORM 1 FROM pg_matviews WHERE schemaname='public' AND matviewname=(mdl||'_decision_space_mat');
    IF NOT FOUND THEN
      INSERT INTO verify_results VALUES (mdl,'error',NULL, ds_tbl||' not found'); CONTINUE;
    END IF;
    PERFORM 1 FROM pg_matviews WHERE schemaname='public' AND matviewname=(mdl||'_valid_masks_mat');
    IF NOT FOUND THEN
      INSERT INTO verify_results VALUES (mdl,'error',NULL, vm_tbl||' not found'); CONTINUE;
    END IF;

    -- Fetch columns for matviews from pg_catalog (works for relkind = 'm')
    SELECT array_agg(a.attname::TEXT ORDER BY a.attnum)
      INTO ds_cols
      FROM pg_attribute a
      JOIN pg_class c ON c.oid=a.attrelid
      JOIN pg_namespace n ON n.oid=c.relnamespace
     WHERE n.nspname='public'
       AND c.relname=(mdl||'_decision_space_mat')
       AND a.attnum>0 AND NOT a.attisdropped;

    SELECT array_agg(a.attname::TEXT ORDER BY a.attnum)
      INTO vm_cols
      FROM pg_attribute a
      JOIN pg_class c ON c.oid=a.attrelid
      JOIN pg_namespace n ON n.oid=c.relnamespace
     WHERE n.nspname='public'
       AND c.relname=(mdl||'_valid_masks_mat')
       AND a.attnum>0 AND NOT a.attisdropped;

    SELECT string_agg(quote_ident(c), ',') INTO ds_cols_csv FROM unnest(ds_cols) AS c;
    SELECT string_agg(quote_ident(c), ',') INTO vm_cols_csv FROM unnest(vm_cols) AS c;

    -- Detect mask-like columns (prefer exact 'mask', else mask/flag/bit)
    SELECT col INTO ds_mask_col FROM (
      SELECT c AS col,
             CASE
               WHEN c='mask' THEN 0
               WHEN c ILIKE '%mask%' THEN 1
               WHEN c ILIKE '%flag%' THEN 2
               WHEN c ILIKE '%bit%'  THEN 3
               ELSE 9
             END AS rank
      FROM unnest(ds_cols) AS t(c)
    ) s
    WHERE rank < 9
    ORDER BY rank, col
    LIMIT 1;

    SELECT col INTO vm_mask_col FROM (
      SELECT c AS col,
             CASE
               WHEN c='mask' THEN 0
               WHEN c ILIKE '%mask%' THEN 1
               WHEN c ILIKE '%flag%' THEN 2
               WHEN c ILIKE '%bit%'  THEN 3
               ELSE 9
             END AS rank
      FROM unnest(vm_cols) AS t(c)
    ) s
    WHERE rank < 9
    ORDER BY rank, col
    LIMIT 1;

    IF ds_mask_col IS NULL THEN
      msg := format('no mask-like column in %s; columns=[%s]', ds_tbl, COALESCE(ds_cols_csv,'<none>'));
      INSERT INTO verify_results VALUES (mdl,'error',NULL,msg);
      CONTINUE;
    END IF;
    IF vm_mask_col IS NULL THEN
      msg := format('no mask-like column in %s; columns=[%s]', vm_tbl, COALESCE(vm_cols_csv,'<none>'));
      INSERT INTO verify_results VALUES (mdl,'warn',NULL,msg);
      -- we can still run dup/ambiguity tests; skip mask subset/coverage
    END IF;

    -- Key columns = all ds cols minus exclusions, ensure mask included
    SELECT array_agg(quote_ident(col) ORDER BY col) INTO key_cols
    FROM (
      SELECT col FROM unnest(ds_cols) c(col)
      WHERE col <> ALL(excl)
    ) s;
    IF NOT EXISTS (SELECT 1 FROM unnest(key_cols) k(c) WHERE c = quote_ident(ds_mask_col)) THEN
      key_cols := key_cols || ARRAY[quote_ident(ds_mask_col)];
    END IF;
    SELECT string_agg(c, ',') INTO key_csv FROM unnest(key_cols) t(c);

    -- Action columns present?
    SELECT array_agg(quote_ident(col) ORDER BY col) INTO act_cols
    FROM (
      SELECT col FROM unnest(ds_cols) c(col)
      WHERE col = ANY(ARRAY['route','priority','allow','decision','action','action_code'])
    ) s;
    IF act_cols IS NULL OR array_length(act_cols,1) IS NULL THEN
      act_expr := NULL;
    ELSE
      SELECT string_agg(c, ',') INTO act_csv FROM unnest(act_cols) t(c);
      act_expr := 'concat_ws(''|'', '||act_csv||')';
    END IF;

    -- 1) Soundness: every ds mask ∈ vm masks
    IF vm_mask_col IS NOT NULL THEN
      EXECUTE format($f$
        SELECT count(*) FROM %s d
        LEFT JOIN %s m ON m.%I = d.%I
        WHERE m.%I IS NULL
      $f$, ds_tbl, vm_tbl, vm_mask_col, ds_mask_col, vm_mask_col)
      INTO cnt_missing_masks;
      INSERT INTO verify_results VALUES (mdl,'soundness_mask_subset_violations', cnt_missing_masks,
        format('d.%I without match in %s.%I', ds_mask_col, vm_tbl, vm_mask_col));
    ELSE
      INSERT INTO verify_results VALUES (mdl,'soundness_mask_subset_violations', NULL,
        'skipped (valid_masks mat has no mask-like column)');
    END IF;

    -- 2) Coverage: each vm mask appears in ds
    IF vm_mask_col IS NOT NULL THEN
      EXECUTE format($f$
        SELECT count(*) FROM %s m
        LEFT JOIN %s d ON d.%I = m.%I
        WHERE d.%I IS NULL
      $f$, vm_tbl, ds_tbl, ds_mask_col, vm_mask_col, ds_mask_col)
      INTO cnt_unused_masks;
      INSERT INTO verify_results VALUES (mdl,'mask_coverage_missing', cnt_unused_masks,
        format('vm.%I with no rows in %s', vm_mask_col, ds_tbl));
    ELSE
      INSERT INTO verify_results VALUES (mdl,'mask_coverage_missing', NULL,
        'skipped (valid_masks mat has no mask-like column)');
    END IF;

    -- 3) Duplicate keys
    EXECUTE format($f$
      SELECT count(*) FROM (SELECT 1 FROM %s GROUP BY %s HAVING count(*) > 1) t
    $f$, ds_tbl, key_csv)
    INTO cnt_dup_keys;
    INSERT INTO verify_results VALUES (mdl,'duplicate_keys', cnt_dup_keys, 'rows with identical key columns repeated');

    -- 4) Multi-action ambiguity
    IF act_expr IS NULL THEN
      INSERT INTO verify_results VALUES (mdl,'multi_action_ambiguity', NULL, 'skipped (no action columns found)');
    ELSE
      EXECUTE format($f$
        SELECT count(*) FROM (
          SELECT 1 FROM %s GROUP BY %s HAVING COUNT(DISTINCT %s) > 1
        ) t
      $f$, ds_tbl, key_csv, act_expr)
      INTO cnt_multi_action;
      INSERT INTO verify_results VALUES (mdl,'multi_action_ambiguity', cnt_multi_action, 'same key maps to multiple actions');
    END IF;

  END LOOP;

  RAISE NOTICE E'\n=== ACBP verification (public schema, auto-detect) ===';
END $$;

TABLE verify_results ORDER BY model, metric;
DROP TABLE IF EXISTS verify_results;
