#!/usr/bin/env bash
set -euo pipefail

# ========= CONFIG =========
CONTAINER=${CONTAINER:-acbp-pg}
IMAGE=${IMAGE:-postgres:16-alpine}
DB=${DB:-postgres}
USER=${USER:-postgres}
PASS=${PASS:-acbp}
PORT=${PORT:-5434}
VOLUME=${VOLUME:-acbp-data}
PY=${PY:-py}  # use 'python' if Windows doesn't have 'py'

# ========= HELPERS =========
psqlc()  { docker exec -i  "$CONTAINER" psql -v ON_ERROR_STOP=1 -U "$USER" -d "$DB" "$@"; }
psqlsh() { docker exec -it "$CONTAINER" psql -U "$USER" -d "$DB"; }
run-sql(){ docker exec -it "$CONTAINER" psql -U "$USER" -d "$DB" -v ON_ERROR_STOP=1 -c "$1"; }

# ========= LIFECYCLE =========
up() {
  if ! docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    echo ">> starting new container $CONTAINER (port $PORT, volume $VOLUME)"
    docker run --name "$CONTAINER" \
      -e POSTGRES_PASSWORD="$PASS" \
      -e POSTGRES_DB="$DB" \
      -p "$PORT:5434" \
      -v "$VOLUME:/var/lib/postgresql/data" \
      -d "$IMAGE" >/dev/null
  else
    echo ">> container exists; starting $CONTAINER"
    docker start "$CONTAINER" >/dev/null
  fi
  echo ">> waiting for DB ..."
  # Retry until ready
  for i in {1..60}; do
    if docker exec "$CONTAINER" pg_isready -U "$USER" -d "$DB" >/dev/null 2>&1; then
      echo ">> DB is ready"
      return 0
    fi
    sleep 1
  done
  echo "!! DB did not become ready in time"; exit 1
}

down() {
  docker rm -f "$CONTAINER" 2>/dev/null || true
  echo ">> container removed: $CONTAINER"
}

# ========= BUILD / APPLY =========
compile() {
  local json="${1:?usage: $0 compile model.json out.sql}"
  local out="${2:?usage: $0 compile model.json out.sql}"
  echo ">> compiling ACBP JSON -> SQL: $json -> $out"
  "$PY" -m acbp_tester "$json" --enumerate -o "$out"
}

compile-apply() {
  local json="${1:?usage: $0 compile-apply model.json}"
  local out
  out="$(dirname "$json")/$(basename "$json" .json).sql"
  "$0" compile "$json" "$out"
  "$0" apply "$out"
}

apply() {
  local sql_path="${1:?usage: $0 apply /path/to/file.sql}"
  echo ">> applying SQL from: $sql_path"
  cat "$sql_path" | psqlc
}

# ========= DB UTILS (ADOPTABLE) =========
install-db-utils() {
psqlc <<'SQL'
-- Create/refresh matviews & indexes for any <model>, with schema-drift handling
CREATE OR REPLACE FUNCTION acbp_materialize(model text, force boolean DEFAULT false)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  vm_view text := quote_ident(model || '_valid_masks');
  ds_view text := quote_ident(model || '_decision_space');
  vm_mat  text := quote_ident(model || '_valid_masks_mat');
  ds_mat  text := quote_ident(model || '_decision_space_mat');
  idx1    text := quote_ident('uq_' || model || '_valid_masks_mat');
  idx2    text := quote_ident('uq_' || model || '_decision_space_mat');
  desired_cols text;
  existing_cols text;
BEGIN
  IF force THEN
    EXECUTE format('DROP MATERIALIZED VIEW IF EXISTS %s CASCADE', vm_mat);
    EXECUTE format('DROP MATERIALIZED VIEW IF EXISTS %s CASCADE', ds_mat);
  END IF;

  EXECUTE format('CREATE MATERIALIZED VIEW IF NOT EXISTS %s AS SELECT * FROM %s', vm_mat, vm_view);
  EXECUTE format('CREATE UNIQUE INDEX IF NOT EXISTS %s ON %s(mask)', idx1, vm_mat);

  EXECUTE format('CREATE MATERIALIZED VIEW IF NOT EXISTS %s AS SELECT * FROM %s', ds_mat, ds_view);

  SELECT string_agg(quote_ident(column_name), ',' ORDER BY ordinal_position)
    INTO desired_cols
  FROM information_schema.columns
  WHERE table_schema='public'
    AND table_name=(model || '_decision_space')
    AND column_name <> 'mask';

  SELECT string_agg(quote_ident(column_name), ',' ORDER BY ordinal_position)
    INTO existing_cols
  FROM information_schema.columns
  WHERE table_schema='public'
    AND table_name=(model || '_decision_space_mat')
    AND column_name <> 'mask';

  IF desired_cols IS DISTINCT FROM existing_cols THEN
    EXECUTE format('DROP MATERIALIZED VIEW IF EXISTS %s CASCADE', ds_mat);
    EXECUTE format('CREATE MATERIALIZED VIEW %s AS SELECT * FROM %s', ds_mat, ds_view);
  END IF;

  IF desired_cols IS NOT NULL AND desired_cols <> '' THEN
    EXECUTE format('CREATE UNIQUE INDEX IF NOT EXISTS %s ON %s(mask, %s)', idx2, ds_mat, desired_cols);
  ELSE
    EXECUTE format('CREATE UNIQUE INDEX IF NOT EXISTS %s ON %s(mask)', idx2, ds_mat);
  END IF;
END$$;

-- Concurrent refresh (requires unique indexes)
CREATE OR REPLACE FUNCTION acbp_refresh(model text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE format('REFRESH MATERIALIZED VIEW CONCURRENTLY %I', model || '_valid_masks_mat');
  EXECUTE format('REFRESH MATERIALIZED VIEW CONCURRENTLY %I', model || '_decision_space_mat');
END$$;

-- COUNT via JOIN against valid_masks
CREATE OR REPLACE FUNCTION acbp_bench_valid_join(model text, data_table text, use_mat boolean DEFAULT true)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
  vm text := CASE WHEN use_mat THEN quote_ident(model || '_valid_masks_mat') ELSE quote_ident(model || '_valid_masks') END;
  sql text; cnt bigint;
BEGIN
  sql := format('SELECT COUNT(*) FROM %I d JOIN %s v ON d.mask = v.mask', data_table, vm);
  EXECUTE sql INTO cnt;
  RETURN cnt;
END$$;

-- COUNT via validator function
CREATE OR REPLACE FUNCTION acbp_bench_valid_func(model text, data_table text)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
  sql text; cnt bigint;
BEGIN
  sql := format('SELECT COUNT(*) FROM %I WHERE acbp_is_valid__%I(mask)', data_table, model);
  EXECUTE sql INTO cnt;
  RETURN cnt;
END$$;

-- FULL decision-space join; builds JSON groups and counts
CREATE OR REPLACE FUNCTION acbp_bench_full_join(
  model text,
  data_table text,
  use_mat boolean DEFAULT true,
  top_n int DEFAULT 12)
RETURNS TABLE(group_obj jsonb, visits bigint)
LANGUAGE plpgsql AS $$
DECLARE
  ds text := CASE WHEN use_mat THEN quote_ident(model || '_decision_space_mat') ELSE quote_ident(model || '_decision_space') END;
  using_cols text;
  group_cols text;
  json_build text;
  sql text;
BEGIN
  WITH
  mc AS (
    SELECT column_name, ordinal_position
    FROM information_schema.columns
    WHERE table_schema='public' AND table_name=(model || '_decision_space')
  ),
  dc AS (
    SELECT column_name
    FROM information_schema.columns
    WHERE table_schema='public' AND table_name=data_table
  ),
  inter_all AS (
    SELECT mc.column_name, mc.ordinal_position
    FROM mc JOIN dc USING (column_name)
  ),
  inter_group AS (
    SELECT column_name, ordinal_position
    FROM inter_all
    WHERE column_name <> 'mask'
  )
  SELECT
    (SELECT string_agg(quote_ident(column_name), ',' ORDER BY ordinal_position) FROM inter_all),
    (SELECT string_agg(quote_ident(column_name), ',' ORDER BY ordinal_position) FROM inter_group),
    (SELECT string_agg(format('%L, d.%I', column_name, column_name), ', ' ORDER BY ordinal_position) FROM inter_group)
  INTO using_cols, group_cols, json_build;

  IF using_cols IS NULL OR using_cols = '' THEN
    RAISE EXCEPTION 'No common columns between % and %', data_table, model || '_decision_space';
  END IF;

  IF group_cols IS NULL OR group_cols = '' THEN
    group_cols := 'mask';
  END IF;
  IF json_build IS NULL OR json_build = '' THEN
    json_build := '''mask'', d.mask';
  END IF;

  sql := format(
    'SELECT jsonb_build_object(%s) AS group_obj, COUNT(*) AS visits
       FROM %I d JOIN %s USING (%s)
      GROUP BY %s
      ORDER BY visits DESC
      LIMIT %s',
    json_build, data_table, ds, using_cols, group_cols, top_n::text
  );

  RETURN QUERY EXECUTE sql;
END$$;

-- ======== PRESENT-ONLY helpers ========

-- Build a present-only decision space (distinct combos that actually occur in data AND are valid)
CREATE OR REPLACE FUNCTION acbp_materialize_present(model text, data_table text, force boolean DEFAULT false)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  ds text;
  pm text := quote_ident(model || '_present_mat');
  idx text := quote_ident('uq_' || model || '_present_mat');
  using_cols text;
  desired_cols text;
  sql text;
BEGIN
  IF to_regclass(model || '_decision_space_mat') IS NOT NULL THEN
    ds := quote_ident(model || '_decision_space_mat');
  ELSE
    ds := quote_ident(model || '_decision_space');
  END IF;

  IF force THEN
    EXECUTE format('DROP MATERIALIZED VIEW IF EXISTS %s CASCADE', pm);
  END IF;

  WITH
  mc AS (
    SELECT column_name, ordinal_position
    FROM information_schema.columns
    WHERE table_schema='public' AND table_name=(model || '_decision_space')
  ),
  dc AS (
    SELECT column_name
    FROM information_schema.columns
    WHERE table_schema='public' AND table_name=data_table
  ),
  inter_all AS (
    SELECT mc.column_name, mc.ordinal_position
    FROM mc JOIN dc USING (column_name)
  ),
  inter_group AS (
    SELECT column_name, ordinal_position
    FROM inter_all
    WHERE column_name <> 'mask'
  )
  SELECT
    (SELECT string_agg(quote_ident(column_name), ',' ORDER BY ordinal_position) FROM inter_all),
    (SELECT string_agg(quote_ident(column_name), ',' ORDER BY ordinal_position) FROM inter_group)
  INTO using_cols, desired_cols;

  IF using_cols IS NULL OR using_cols = '' THEN
    RAISE EXCEPTION 'No common columns between % and %', data_table, model || '_decision_space';
  END IF;

  EXECUTE format(
    'CREATE MATERIALIZED VIEW IF NOT EXISTS %s AS
       SELECT DISTINCT ds.* FROM %I d JOIN %s ds USING (%s)',
    pm, data_table, ds, using_cols
  );

  IF desired_cols IS NOT NULL AND desired_cols <> '' THEN
    EXECUTE format('CREATE UNIQUE INDEX IF NOT EXISTS %s ON %s(mask, %s)', idx, pm, desired_cols);
  ELSE
    EXECUTE format('CREATE UNIQUE INDEX IF NOT EXISTS %s ON %s(mask)', idx, pm);
  END IF;
END$$;

CREATE OR REPLACE FUNCTION acbp_refresh_present(model text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE format('REFRESH MATERIALIZED VIEW CONCURRENTLY %I', model || '_present_mat');
END$$;

CREATE OR REPLACE FUNCTION acbp_bench_full_join_present(
  model text,
  data_table text,
  top_n int DEFAULT 12)
RETURNS TABLE(group_obj jsonb, visits bigint)
LANGUAGE plpgsql AS $$
DECLARE
  pm text := quote_ident(model || '_present_mat');
  using_cols text;
  group_cols text;
  json_build text;
  sql text;
BEGIN
  WITH
  mc AS (
    SELECT column_name, ordinal_position
    FROM information_schema.columns
    WHERE table_schema='public' AND table_name=(model || '_decision_space')
  ),
  dc AS (
    SELECT column_name
    FROM information_schema.columns
    WHERE table_schema='public' AND table_name=data_table
  ),
  inter_all AS (
    SELECT mc.column_name, mc.ordinal_position
    FROM mc JOIN dc USING (column_name)
  ),
  inter_group AS (
    SELECT column_name, ordinal_position
    FROM inter_all
    WHERE column_name <> 'mask'
  )
  SELECT
    (SELECT string_agg(quote_ident(column_name), ',' ORDER BY ordinal_position) FROM inter_all),
    (SELECT string_agg(quote_ident(column_name), ',' ORDER BY ordinal_position) FROM inter_group),
    (SELECT string_agg(format('%L, d.%I', column_name, column_name), ', ' ORDER BY ordinal_position) FROM inter_group)
  INTO using_cols, group_cols, json_build;

  IF group_cols IS NULL OR group_cols = '' THEN group_cols := 'mask'; END IF;
  IF json_build IS NULL OR json_build = '' THEN json_build := '''mask'', d.mask'; END IF;

  sql := format(
    'SELECT jsonb_build_object(%s) AS group_obj, COUNT(*) AS visits
       FROM %I d JOIN %s USING (%s)
      GROUP BY %s
      ORDER BY visits DESC
      LIMIT %s',
    json_build, data_table, pm, using_cols, group_cols, top_n::text
  );
  RETURN QUERY EXECUTE sql;
END$$;

-- Optional convenience: build a matching composite index on the data table (mask + cats)
CREATE OR REPLACE FUNCTION acbp_create_matching_index(model text, data_table text)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  cols text;
  idxname text := format('idx_%s_match', data_table);
BEGIN
  SELECT string_agg(quote_ident(column_name), ',' ORDER BY ordinal_position)
    INTO cols
  FROM information_schema.columns
  WHERE table_schema='public'
    AND table_name = (model || '_decision_space')
    AND column_name <> 'mask';

  IF cols IS NULL OR cols = '' THEN
    RAISE EXCEPTION 'No category columns found for %', model;
  END IF;

  EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON %I (mask, %s)', idxname, data_table, cols);
  RETURN idxname;
END$$;
SQL
  echo ">> DB utility functions installed (materialize/refresh/bench + present-only)"
}

reinstall-db-utils() {
psqlc <<'SQL'
DROP FUNCTION IF EXISTS acbp_bench_full_join_present(text,text,int);
DROP FUNCTION IF EXISTS acbp_refresh_present(text);
DROP FUNCTION IF EXISTS acbp_materialize_present(text,text,boolean);
DROP FUNCTION IF EXISTS acbp_create_matching_index(text,text);
DROP FUNCTION IF EXISTS acbp_bench_full_join(text,text,boolean,int);
DROP FUNCTION IF EXISTS acbp_bench_valid_func(text,text);
DROP FUNCTION IF EXISTS acbp_bench_valid_join(text,text,boolean);
DROP FUNCTION IF EXISTS acbp_refresh(text);
DROP FUNCTION IF EXISTS acbp_materialize(text,boolean);
DROP FUNCTION IF EXISTS acbp_materialize(text);
SQL
  install-db-utils
}

# ========= MODEL-AWARE OPS =========
materialize() {
  local model="${1:?usage: $0 materialize <model_name>}"
  echo ">> materializing for model: $model"
  run-sql "SELECT acbp_materialize('$model');"
}

rematerialize() {
  local model="${1:?usage: $0 rematerialize <model_name>}"
  echo ">> re-materializing (forced) for model: $model"
  run-sql "SELECT acbp_materialize('$model', true);"
}

refresh() {
  local model="${1:?usage: $0 refresh <model_name>}"
  echo ">> refreshing matviews for model: $model"
  run-sql "SELECT acbp_refresh('$model');"
}

materialize-present() {
  local model="${1:?usage: $0 materialize-present <model> <data_table>}"
  local data="${2:?usage: $0 materialize-present <model> <data_table>}"
  echo ">> materializing present-only decision space for model: $model using $data"
  run-sql "SELECT acbp_materialize_present('$model', '$data');"
}

rematerialize-present() {
  local model="${1:?usage: $0 rematerialize-present <model> <data_table>}"
  local data="${2:?usage: $0 rematerialize-present <model> <data_table>}"
  echo ">> re-materializing (forced) present-only decision space for model: $model using $data"
  run-sql "SELECT acbp_materialize_present('$model', '$data', true);"
}

refresh-present() {
  local model="${1:?usage: $0 refresh-present <model>}"
  echo ">> refreshing present-only matview for model: $model"
  run-sql "SELECT acbp_refresh_present('$model');"
}

# quick sanity checks for a model
checks() {
  local model="${1:-clinic_visit}"
  echo ">> valid mask count ($model)"
  run-sql "SELECT COUNT(*) AS valid_masks FROM \"${model}_valid_masks\";" || true
  echo ">> decision space rows ($model)"
  run-sql "SELECT COUNT(*) AS decision_rows FROM \"${model}_decision_space\";" || true
  echo ">> sample validator ($model, mask=7)"
  run-sql "SELECT 7 AS mask, \"acbp_is_valid__${model}\"(7) AS is_valid;" || true
}

# bit-only rule explainer (mask)
explain() {
  local model="${1:?usage: $0 explain <model_name> <mask>}"
  local mask="${2:?usage: $0 explain <model_name> <mask>}"
  echo ">> bit-only explain ($model, mask=$mask)"
  run-sql "SELECT * FROM \"acbp_explain_rules__${model}\"($mask) WHERE NOT ok;"
}

# ========= GENERIC BENCHMARK WRAPPERS =========
bench-valid-join() {
  local model="${1:-clinic_visit}"
  local data="${2:-${model}_data}"
  echo ">> Benchmark: valid masks JOIN [$model] on table [$data]"
  run-sql "SELECT acbp_bench_valid_join('$model', '$data', true) AS valid_join;"
}

bench-valid-func() {
  local model="${1:-clinic_visit}"
  local data="${2:-${model}_data}"
  echo ">> Benchmark: valid masks FUNCTION [$model] on table [$data]"
  run-sql "SELECT acbp_bench_valid_func('$model', '$data') AS valid_func;"
}

bench-full-join() {
  local model="${1:-clinic_visit}"
  local data="${2:-${model}_data}"
  echo ">> Benchmark: full decision-space join [$model] on table [$data]"
  run-sql "SELECT * FROM acbp_bench_full_join('$model', '$data', true, 12);"
}

bench-full-join-present() {
  local model="${1:-clinic_visit}"
  local data="${2:-${model}_data}"
  echo ">> Benchmark: full decision-space join (present-only) [$model] on table [$data]"
  run-sql "SELECT * FROM acbp_bench_full_join_present('$model', '$data', 12);"
}

bench-all() {
  local model="${1:-clinic_visit}"
  local data="${2:-${model}_data}"
  echo "== ACBP Benchmarks: $model =="
  echo "Table: $data"
  echo "Timestamp: $(date)"
  time bench-valid-join "$model" "$data"
  time bench-valid-func "$model" "$data"
  time bench-full-join "$model" "$data"
}

bench-all-present() {
  local model="${1:-clinic_visit}"
  local data="${2:-${model}_data}"
  echo "== ACBP Benchmarks (present-only): $model =="
  echo "Table: $data"
  echo "Timestamp: $(date)"
  time bench-valid-join "$model" "$data"
  time bench-valid-func "$model" "$data"
  time bench-full-join-present "$model" "$data"
}

# ========= BACKUP / RESTORE / MAINT =========
backup() {
  local out="${1:-acbp_backup_$(date +%Y%m%d_%H%M%S).sql}"
  echo ">> writing backup to $out"
  docker exec "$CONTAINER" pg_dump -U "$USER" -d "$DB" > "$out"
  echo ">> done"
}

restore() {
  local file="${1:?usage: $0 restore backup.sql}"
  echo ">> restoring into $DB from $file (objects may already exist)"
  cat "$file" | psqlc
}

restore-clean() {
  local file="${1:?usage: $0 restore-clean backup.sql}"
  echo ">> dropping and recreating schema public, then restoring $file"
  psqlc -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"
  cat "$file" | psqlc
}

vacuum() {
  local table="${1:?usage: $0 vacuum <table_name>}"
  echo ">> VACUUM ANALYZE $table"
  run-sql "VACUUM ANALYZE $table;"
}

psql-c() {
  local sql="${1:?usage: $0 psql-c \"SELECT 1;\"}"
  run-sql "$sql"
}

# ========= USAGE =========
usage() {
  cat <<USAGE
Usage: $0 <cmd> [args]

Lifecycle:
  up                               Start Postgres container ($CONTAINER)
  down                             Stop & remove container
  psql                             Open interactive psql shell

Build / Apply:
  compile model.json out.sql       Compile ACBP JSON -> SQL (requires acbp_tester.py)
  compile-apply model.json         Compile and apply in one go
  apply file.sql                   Apply an SQL file via stdin

DB Utilities:
  install-db-utils                 Install helper functions (matviews/bench)
  reinstall-db-utils               Drop old helper funcs then reinstall
  materialize <model>              Create/repair matviews & indexes (auto drift fix)
  rematerialize <model>            Force drop/rebuild of matviews & indexes
  refresh <model>                  Refresh the model's matviews concurrently

Present-only Decision Space:
  materialize-present <model> <data_table>
  rematerialize-present <model> <data_table>
  refresh-present <model>
  bench-full-join-present [model] [data]   Grouped counts via <model>_present_mat
  bench-all-present [model] [data]         JOIN, FUNC, PRESENT join trio

Model checks:
  checks [model]                   Sanity checks (counts + validator)
  explain <model> <mask>           Show violated bit rules for a given mask

Benchmarks (generic):
  bench-valid-join [model] [data]  Count via JOIN on <model>_valid_masks_mat
  bench-valid-func [model] [data]  Count via acbp_is_valid__<model>(mask)
  bench-full-join [model] [data]   Grouped counts via decision_space_mat
  bench-all [model] [data]         Run all three

Maintenance:
  vacuum <table>                   VACUUM ANALYZE a table
  psql-c "SQL..."                  Run one-off SQL via -c

Backup:
  backup [file.sql]                Dump the DB
  restore file.sql                 Restore from a dump
  restore-clean file.sql           Drop & recreate schema before restore

Notes:
- Data table defaults to <model>_data. Override by passing [data] explicitly.
- Works for OPD, inpatient, and any new model you compile/apply.
USAGE
}

# ========= DISPATCH =========
cmd="${1:-}"; shift || true
case "${cmd}" in
  up) up ;;
  down) down ;;
  psql) psqlsh ;;
  compile) compile "$@" ;;
  compile-apply) compile-apply "$@" ;;
  apply) apply "$@" ;;

  install-db-utils) install-db-utils ;;
  reinstall-db-utils) reinstall-db-utils ;;
  materialize) materialize "$@" ;;
  rematerialize) rematerialize "$@" ;;
  refresh) refresh "$@" ;;

  materialize-present) materialize-present "$@" ;;
  rematerialize-present) rematerialize-present "$@" ;;
  refresh-present) refresh-present "$@" ;;

  checks) checks "${1:-clinic_visit}" ;;
  explain) explain "$@" ;;

  bench-valid-join) bench-valid-join "${1:-clinic_visit}" "${2:-${1:-clinic_visit}_data}" ;;
  bench-valid-func) bench-valid-func "${1:-clinic_visit}" "${2:-${1:-clinic_visit}_data}" ;;
  bench-full-join)  bench-full-join  "${1:-clinic_visit}" "${2:-${1:-clinic_visit}_data}" ;;
  bench-full-join-present) bench-full-join-present "${1:-clinic_visit}" "${2:-${1:-clinic_visit}_data}" ;;
  bench-all)        bench-all        "${1:-clinic_visit}" "${2:-${1:-clinic_visit}_data}" ;;
  bench-all-present) bench-all-present "${1:-clinic_visit}" "${2:-${1:-clinic_visit}_data}" ;;

  vacuum) vacuum "$@" ;;
  psql-c) psql-c "$@" ;;

  backup) backup "${1:-}" ;;
  restore) restore "$@" ;;
  restore-clean) restore-clean "$@" ;;

  *) usage ;;
esac
