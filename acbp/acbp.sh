# SPDX-License-Identifier: LicenseRef-DotK-Proprietary-NC-1.0
# Copyright (c) 2025 DotK (Muteb Hail S Al Anazi)

#!/usr/bin/env bash
set -euo pipefail

# ========= CONFIG =========
CONTAINER=${CONTAINER:-acbp-pg}
IMAGE=${IMAGE:-postgres:16-alpine}
DB=${DB:-postgres}
USER=${USER:-postgres}
PASS=${PASS:-acbp}
PORT=${PORT:-5434}          # host port (maps to 5432 in container)
VOLUME=${VOLUME:-acbp-data}
PY=${PY:-py}

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
      -p "$PORT:5432" \
      -v "$VOLUME:/var/lib/postgresql/data" \
      -d "$IMAGE" >/dev/null
  else
    echo ">> container exists; starting $CONTAINER"
    docker start "$CONTAINER" >/dev/null
  fi
  echo ">> waiting for DB ..."

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

  -- Gather stats once so the dashboard queries plan well
  EXECUTE format('ANALYZE %s', pm);
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

-- Run an arbitrary SELECT query N times and return the average wall time in ms.
-- NOTE: results are discarded; the full query still executes in the server.
CREATE OR REPLACE FUNCTION acbp_time_ms(q text, iters int DEFAULT 1, warmup boolean DEFAULT false)
RETURNS double precision
LANGUAGE plpgsql AS $$
DECLARE
  i int;
  t1 timestamp;
  t2 timestamp;
  acc double precision := 0;
BEGIN
  IF warmup THEN
    EXECUTE q; -- one warmup run (ignored)
  END IF;

  IF iters < 1 THEN
    RETURN 0;
  END IF;

  FOR i IN 1..iters LOOP
    t1 := clock_timestamp();
    EXECUTE q; -- discard results
    t2 := clock_timestamp();
    acc := acc + EXTRACT(EPOCH FROM (t2 - t1)) * 1000.0;
  END LOOP;
  RETURN acc / iters;
END$$;
-- explicit cache heater (no-op if already there)
CREATE EXTENSION IF NOT EXISTS pg_prewarm;

-- time many queries in a single backend session
CREATE OR REPLACE FUNCTION acbp_time_ms_many(
  labels  text[],
  queries text[],
  iters   int    DEFAULT 1,
  warmup  boolean DEFAULT false
) RETURNS TABLE(label text, ms double precision)
LANGUAGE plpgsql AS $$
DECLARE i int;
BEGIN
  IF coalesce(array_length(labels,1),0) <> coalesce(array_length(queries,1),0) THEN
    RAISE EXCEPTION 'labels and queries must be same length';
  END IF;
  IF warmup THEN
    FOR i IN 1..coalesce(array_length(queries,1),0) LOOP
      PERFORM acbp_time_ms(queries[i], 1, false);  -- one warmup run per query
    END LOOP;
  END IF;
  FOR i IN 1..coalesce(array_length(queries,1),0) LOOP
    RETURN QUERY SELECT labels[i], acbp_time_ms(queries[i], iters, false);
  END LOOP;
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
DROP FUNCTION IF EXISTS acbp_time_ms(text,int,boolean);
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

checks() {
  local model="${1:-clinic_visit}"
  echo ">> valid mask count ($model)"
  run-sql "SELECT COUNT(*) AS valid_masks FROM \"${model}_valid_masks\";" || true
  echo ">> decision space rows ($model)"
  run-sql "SELECT COUNT(*) AS decision_rows FROM \"${model}_decision_space\";" || true
  echo ">> sample validator ($model, mask=7)"
  run-sql "SELECT 7 AS mask, \"acbp_is_valid__${model}\"(7) AS is_valid;" || true
}

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

# ---------- Dashboard helpers ----------

# Small helper: run a timing measurement on the server and print ms
_db_time_ms() {
  local sql="$1"
  local warm="${2:-false}"   # true|false -> acbp_time_ms warmup parameter
  local iters="${3:-1}"
  docker exec -i "$CONTAINER" psql -U "$USER" -d "$DB" -At -v ON_ERROR_STOP=1 \
    -c "SELECT ROUND(acbp_time_ms(\$\$${sql}\$\$, ${iters}, ${warm})::numeric, 3);"
}

# Export a resultset to CSV (runs inside the container)
_db_copy_csv() {
  local sql="$1"; local out="$2"
  mkdir -p "$(dirname "$out")"
  docker exec -i "$CONTAINER" psql -U "$USER" -d "$DB" -v ON_ERROR_STOP=1 \
    -c "\COPY (${sql}) TO STDOUT WITH CSV HEADER" > "$out"
}

# Build the list of category columns for a model (excluding mask), in order
_model_cat_cols() {
  local model="$1"
  docker exec -i "$CONTAINER" psql -U "$USER" -d "$DB" -At -v ON_ERROR_STOP=1 \
    -c "SELECT column_name
          FROM information_schema.columns
         WHERE table_schema='public' AND table_name='${model}_decision_space'
           AND column_name <> 'mask'
         ORDER BY ordinal_position;"
}

# Simulated dashboard: counts + top groups + a few KPI tables.
# Creates:
#  papers/results/<ts>/<model>/dashboard_perf.csv
#  papers/results/<ts>/<model>/kpi_*.csv
paper_bench_dashboard() {
  set -euo pipefail
  local model="${1:?usage: $0 paper-bench-dashboard <model> [topN] [iters]}"
  local topN="${2:-12}"
  local iters="${3:-2}"   # a bit higher smooths variance
  local data_table="${model}_data"

  local TS="$(date -u +%Y%m%dT%H%M%SZ)"
  local OUTDIR="papers/results/${TS}/${model}"
  mkdir -p "$OUTDIR"

  mapfile -t COLS < <(_model_cat_cols "$model")
  local C1="${COLS[0]:-}"
  local C2="${COLS[1]:-}"

  declare -A Q
  Q["count_all"]="SELECT COUNT(*) FROM \"${data_table}\""
  Q["top_groups_present"]="SELECT * FROM acbp_bench_full_join_present('${model}', '${data_table}', ${topN})"
  Q["top_groups_full"]="SELECT * FROM acbp_bench_full_join('${model}', '${data_table}', true, ${topN})"

  local i=0
  for col in "${COLS[@]}"; do
    Q["kpi_by_${col}"]="SELECT ${col} AS key, COUNT(*) AS cnt
                          FROM \"${data_table}\"
                         GROUP BY 1 ORDER BY 2 DESC LIMIT ${topN}"
    i=$((i+1)); [ "$i" -ge 5 ] && break
  done
  if [ -n "${C1}" ] && [ -n "${C2}" ]; then
    Q["kpi_by_${C1}_${C2}"]="SELECT ${C1} AS k1, ${C2} AS k2, COUNT(*) AS cnt
                               FROM \"${data_table}\"
                              GROUP BY 1,2 ORDER BY 3 DESC LIMIT ${topN}"
  fi

  # stable alphabetical order for reproducibility
  mapfile -t ORDERED < <(printf '%s\n' "${!Q[@]}" | sort)

  _labels_array_sql() {
    local first=1
    printf "ARRAY["
    for lbl in "${ORDERED[@]}"; do
      [ $first -eq 0 ] && printf ","
      printf "'%s'" "$lbl"
      first=0
    done
    printf "]::text[]"
  }
  _queries_array_sql() {
    local first=1
    printf "ARRAY["
    for lbl in "${ORDERED[@]}"; do
      [ $first -eq 0 ] && printf ","
      # use $$…$$ to avoid bash history/param expansion issues
      printf "\$\$%s\$\$" "${Q[$lbl]}"
      first=0
    done
    printf "]::text[]"
  }

  _export_csvs() {
    for lbl in "${ORDERED[@]}"; do
      case "$lbl" in
        top_groups_full)    _db_copy_csv "${Q[$lbl]}" "${OUTDIR}/top_groups_full.csv" ;;
        top_groups_present) _db_copy_csv "${Q[$lbl]}" "${OUTDIR}/top_groups_present.csv" ;;
        kpi_by_*)           _db_copy_csv "${Q[$lbl]}" "${OUTDIR}/${lbl}.csv" ;;
      esac
    done
  }

  _scenario_run() {
    local scenario="$1"   # cold|warm
    local warm_flag="$2"  # true|false for warmup inside server
    local PERF="${OUTDIR}/dashboard_perf.csv"
    [ -f "$PERF" ] || echo "scenario,label,ms" > "$PERF"

    local lbls qrys
    lbls="$(_labels_array_sql)"
    qrys="$(_queries_array_sql)"

    # optional warm primer using pg_prewarm, if available
    if [ "$scenario" = "warm" ]; then
      docker exec -i "$CONTAINER" psql -U "$USER" -d "$DB" -At -v ON_ERROR_STOP=1 \
        -c "CREATE EXTENSION IF NOT EXISTS pg_prewarm;" >/dev/null 2>&1 || true
      docker exec -i "$CONTAINER" psql -U "$USER" -d "$DB" -At -v ON_ERROR_STOP=1 \
        -c "SELECT pg_prewarm('${data_table}'::regclass, 'buffer');" >/dev/null 2>&1 || true
      docker exec -i "$CONTAINER" psql -U "$USER" -d "$DB" -At -v ON_ERROR_STOP=1 \
        -c "SELECT pg_prewarm('${model}_decision_space_mat'::regclass, 'buffer');" >/dev/null 2>&1 || true
      if docker exec -i "$CONTAINER" psql -U "$USER" -d "$DB" -At -v ON_ERROR_STOP=1 \
           -c "SELECT to_regclass('${model}_present_mat') IS NOT NULL;" | grep -q t; then
        docker exec -i "$CONTAINER" psql -U "$USER" -d "$DB" -At -v ON_ERROR_STOP=1 \
          -c "SELECT pg_prewarm('${model}_present_mat'::regclass, 'buffer');" >/dev/null 2>&1 || true
      fi
      # prewarm likely indexes (best-effort)
      docker exec -i "$CONTAINER" psql -U "$USER" -d "$DB" -At -v ON_ERROR_STOP=1 \
        -c "SELECT pg_prewarm('uq_${model}_decision_space_mat'::regclass, 'buffer')" >/dev/null 2>&1 || true
      docker exec -i "$CONTAINER" psql -U "$USER" -d "$DB" -At -v ON_ERROR_STOP=1 \
        -c "SELECT pg_prewarm('uq_${model}_present_mat'::regclass, 'buffer')" >/dev/null 2>&1 || true
      docker exec -i "$CONTAINER" psql -U "$USER" -d "$DB" -At -v ON_ERROR_STOP=1 \
        -c "SELECT pg_prewarm('idx_${data_table}_match'::regclass, 'buffer')" >/dev/null 2>&1 || true
    fi

    # one-shot timing of all queries in a single backend
    docker exec -i "$CONTAINER" psql -U "$USER" -d "$DB" -At -v ON_ERROR_STOP=1 \
      -c "SELECT '${scenario}', label, ROUND(ms::numeric,3)
            FROM acbp_time_ms_many(${lbls}, ${qrys}, ${iters}, ${warm_flag});" \
      | awk -F'|' '{printf("%s,%s,%.3f\n",$1,$2,$3)}' >> "$PERF"

    _export_csvs
  }

  echo ">> dashboard bench for ${model}"

  echo ">> cold run (restart container)"
  docker restart "$CONTAINER" >/dev/null
  up >/dev/null
  _scenario_run cold false

  echo ">> warm run"
  _scenario_run warm true

  echo ">> wrote ${OUTDIR}/dashboard_perf.csv and KPI CSVs"
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

# ========= PAPER RESULTS (seed + export) =========
RESULTS_DIR=${RESULTS_DIR:-papers/results}

# Low-level helper: copy a query as CSV to host
_copy_csv() {
  local outfile="$1"; shift
  local sql="$*"
  mkdir -p "$(dirname "$outfile")"
  docker exec -i "$CONTAINER" psql -U "$USER" -d "$DB" -v ON_ERROR_STOP=1 \
    -c "\COPY ($sql) TO STDOUT WITH CSV HEADER" > "$outfile"
  echo ">> wrote $outfile"
}

# Low-level helper: capture EXPLAIN text to host
_capture_explain() {
  local outfile="$1"; shift
  local sql="$*"
  mkdir -p "$(dirname "$outfile")"
  docker exec -i "$CONTAINER" psql -U "$USER" -d "$DB" -v ON_ERROR_STOP=1 -X -qAt \
    -c "EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT) $sql" > "$outfile"
  echo ">> wrote $outfile"
}

# Seed <model>_data with N random rows sampled from the model's decision_space
paper_seed() {
  local model="${1:?usage: $0 paper-seed <model> [N] [rebuild|force]}"
  local n="${2:-50000}"
  local mode="${3:-}"
  local tbl="${model}_data"
  local dsv="${model}_decision_space"

  echo ">> seeding ${tbl} with ${n} rows from ${dsv}"

  # If rebuild/force: drop dependent present-only matview first, then table
  if [ "$mode" = "rebuild" ] || [ "$mode" = "force" ]; then
    run-sql "DROP MATERIALIZED VIEW IF EXISTS \"${model}_present_mat\" CASCADE;"
    run-sql "DROP TABLE IF EXISTS \"${tbl}\";"
    run-sql "CREATE TABLE \"${tbl}\" AS SELECT * FROM \"${dsv}\" WITH NO DATA;"
  else
    # Create if missing
    run-sql "CREATE TABLE IF NOT EXISTS \"${tbl}\" AS SELECT * FROM \"${dsv}\" WITH NO DATA;"

    # Check schema match (same columns/order)
    local want have
    want=$(docker exec -i "$CONTAINER" psql -U "$USER" -d "$DB" -X -qAt \
      -c "SELECT string_agg(column_name, ',' ORDER BY ordinal_position)
            FROM information_schema.columns
           WHERE table_schema='public' AND table_name='${dsv}'")
    have=$(docker exec -i "$CONTAINER" psql -U "$USER" -d "$DB" -X -qAt \
      -c "SELECT string_agg(column_name, ',' ORDER BY ordinal_position)
            FROM information_schema.columns
           WHERE table_schema='public' AND table_name='${tbl}'")

    if [ "$want" != "$have" ]; then
      echo "!! ${tbl} schema != ${dsv}. Re-run with:  ./acbp.sh paper-seed ${model} ${n} rebuild"
      return 1
    fi
  fi

  run-sql "TRUNCATE TABLE \"${tbl}\";"
  run-sql "INSERT INTO \"${tbl}\" SELECT * FROM \"${dsv}\" ORDER BY random() LIMIT ${n};"
  run-sql "VACUUM ANALYZE \"${tbl}\";"

  # optional index + mats (if helpers installed)
  if docker exec -i "$CONTAINER" psql -U "$USER" -d "$DB" -X -qAt \
       -c "SELECT 1 FROM pg_proc WHERE proname='acbp_create_matching_index' LIMIT 1;" | grep -q 1; then
    run-sql "SELECT acbp_create_matching_index('${model}', '${tbl}');"
  fi

  # Build decision-space mats (and present-only); the present mat function ANALYZEs itself.
  run-sql "SELECT acbp_materialize('${model}');"
  if docker exec -i "$CONTAINER" psql -U "$USER" -d "$DB" -X -qAt \
       -c "SELECT 1 FROM pg_proc WHERE proname='acbp_materialize_present' LIMIT 1;" | grep -q 1; then
    run-sql "SELECT acbp_materialize_present('${model}', '${tbl}');"
  fi
}

# Export metrics/top-groups/EXPLAIN for one model
paper_bench() {
  local model="${1:?usage: $0 paper-bench <model> [TOP_N]}"; shift || true
  local topn="${1:-12}"
  local ts; ts="$(date -u +%Y%m%dT%H%M%SZ)"
  local outdir="${RESULTS_DIR}/${ts}/${model}"
  mkdir -p "$outdir"

  echo ">> exporting summary metrics for $model"
  _copy_csv "${outdir}/summary.csv" "
    SELECT '${model}' AS model,
           (SELECT COUNT(*) FROM \"${model}_valid_masks\")       AS valid_masks,
           (SELECT COUNT(*) FROM \"${model}_decision_space\")    AS decision_rows,
           (SELECT COUNT(*) FROM \"${model}_data\")              AS data_rows,
           CASE WHEN to_regclass('${model}_present_mat') IS NULL
                THEN NULL
                ELSE (SELECT COUNT(*) FROM \"${model}_present_mat\")
           END                                                   AS present_rows,
           now()                                                 AS collected_at
  "

  echo ">> exporting valid counts via JOIN/FUNC for $model"
  _copy_csv "${outdir}/valid_counts.csv" "
    SELECT 'valid_join' AS metric, acbp_bench_valid_join('${model}','${model}_data', true) AS value
    UNION ALL
    SELECT 'valid_func' AS metric, acbp_bench_valid_func('${model}','${model}_data')       AS value
  "

  echo ">> exporting top groups (full decision space) for $model"
  _copy_csv "${outdir}/top_groups_full.csv" "
    SELECT * FROM acbp_bench_full_join('${model}','${model}_data', true, ${topn})
  "
  _capture_explain "${outdir}/plan_top_groups_full.txt" \
    "SELECT * FROM acbp_bench_full_join('${model}','${model}_data', true, ${topn});"

  echo ">> exporting top groups (present-only) for $model (if available)"
  if docker exec -i "$CONTAINER" psql -U "$USER" -d "$DB" -X -qAt \
       -c "SELECT 1 FROM pg_proc WHERE proname='acbp_bench_full_join_present' LIMIT 1;" | grep -q 1; then
    _copy_csv "${outdir}/top_groups_present.csv" "
      SELECT * FROM acbp_bench_full_join_present('${model}','${model}_data', ${topn})
    "
    _capture_explain "${outdir}/plan_top_groups_present.txt" \
      "SELECT * FROM acbp_bench_full_join_present('${model}','${model}_data', ${topn});"
  else
    echo ">> present-only benches not installed; skipping"
  fi

  echo ">> done. Files in: ${outdir}"
}

# One-shot: compile/apply models, install utils, seed, and export for all
paper_results_all() {
  local seed_n="${1:-50000}"
  local topn="${2:-12}"
  echo "== PAPER RESULTS (all models) =="
  "$0" install-db-utils

  # Compile/apply if not present (use models/*)
  if ! docker exec -i "$CONTAINER" psql -U "$USER" -d "$DB" -X -qAt \
       -c "SELECT 1 FROM pg_views WHERE viewname='clinic_visit_decision_space';" | grep -q 1; then
    "$0" compile-apply models/clinic_visit.v0.json
  fi
  if ! docker exec -i "$CONTAINER" psql -U "$USER" -d "$DB" -X -qAt \
       -c "SELECT 1 FROM pg_views WHERE viewname='inpatient_admission_decision_space';" | grep -q 1; then
    "$0" compile-apply models/inpatient_admission.v0.json
  fi

  "$0" paper-seed clinic_visit "${seed_n}"
  "$0" paper-bench clinic_visit "${topn}"

  "$0" paper-seed inpatient_admission "${seed_n}"
  "$0" paper-bench inpatient_admission "${topn}"
}

# ========= PAPER: MAKE MARKDOWN SNIPPET FROM LATEST RESULTS =========
latest_results_dir() {
  local base="papers/results"
  [ -d "$base" ] || { echo "!! no results dir ($base)"; return 1; }
  ls -1 "$base" | sort | tail -n1
}

paper_results_md() {
  set -euo pipefail
  local BASE="papers/results"
  mkdir -p "$BASE"

  _latest_for_model() {
    local model="$1"
    ls -1 "$BASE" 2>/dev/null | grep -E '^[0-9]{8}T[0-9]{6}Z$' | \
    while read -r ts; do
      [ -d "$BASE/$ts/$model" ] && echo "$ts"
    done | sort | tail -n1
  }

  # small cross-platform mktemp helper
  _mktemp_sql() {
    if command -v mktemp >/dev/null 2>&1; then
      mktemp "${TMPDIR:-/tmp}/acbp_sql_XXXXXX.sql"
    else
      echo "${BASE}/tmp_sql_$$.sql"
    fi
  }

  local M1="clinic_visit"
  local M2="inpatient_admission"
  local TS1 TS2
  TS1="$(_latest_for_model "$M1" 2>/dev/null || echo "")"
  TS2="$(_latest_for_model "$M2" 2>/dev/null || echo "")"

  if [ -z "${TS1}" ] && [ -z "${TS2}" ]; then
    echo "!! no model result dirs found under $BASE" >&2
    return 1
  fi

  local OUT="$BASE/results-latest.md"
  {
    echo "<!-- RESULTS:BEGIN -->"
    echo "## 8.1 Results (synthetic; 50k rows per model)"
    echo
    if [ -n "$TS1" ] && [ -n "$TS2" ] && [ "$TS1" != "$TS2" ]; then
      echo "_Run timestamps (UTC): clinic_visit=${TS1}; inpatient_admission=${TS2}_"
    else
      echo "_Run timestamp (UTC): ${TS1:-$TS2}_"
    fi
    echo

    for M in "$M1" "$M2"; do
      local TS SUM VC PERF
      TS="$(_latest_for_model "$M" 2>/dev/null || echo "")"
      [ -z "$TS" ] && continue

      case "$M" in
        clinic_visit)        echo "### Clinic Visit" ;;
        inpatient_admission) echo "### Inpatient Admission" ;;
        *)                   echo "### $M" ;;
      esac
      echo

      # ---------- Complexity & sanity (from compiler) ----------
      local MODEL_JSON="models/${M}.v0.json"
      if [ -f "$MODEL_JSON" ]; then
        local OUTDIR="$BASE/$TS/$M"
        mkdir -p "$OUTDIR"
        local TMP_SQL; TMP_SQL="$(_mktemp_sql)"
        "$PY" -m acbp_tester "$MODEL_JSON" --enumerate -o "$TMP_SQL" > "${OUTDIR}/compiler_sanity.txt" 2>&1 || true
        rm -f "$TMP_SQL"

        if [ -s "${OUTDIR}/compiler_sanity.txt" ]; then
          echo "**Complexity & sanity (compiler)**"
          echo
          echo '```text'
          if ! grep -E '^(Model:|  B \(flags\)|  B_eff|  n_eff|  Complexity:|  Valid masks|  First few:|=== Sanity estimates|  Flag prevalence|  Theoretical max|  Est\. remaining|  Est\. pruned|^=== Actuals|  Decision rows:|  Present-only rows:|  Data rows:|  note: )' \
              "${OUTDIR}/compiler_sanity.txt" ; then
            cat "${OUTDIR}/compiler_sanity.txt"
          fi
          echo '```'
          echo
        fi
      fi

      # ---------- Metric/value table ----------
      SUM="$BASE/$TS/$M/summary.csv"
      VC="$BASE/$TS/$M/valid_counts.csv"
      PERF="$BASE/$TS/$M/dashboard_perf.csv"

      if [ -f "$SUM" ]; then
        local VM DS DR PR
        VM=$(awk -F',' 'NR==2{print $2}' "$SUM")
        DS=$(awk -F',' 'NR==2{print $3}' "$SUM")
        DR=$(awk -F',' 'NR==2{print $4}' "$SUM")
        PR=$(awk -F',' 'NR==2{print $5}' "$SUM")

        local VJ VF
        if [ -f "$VC" ]; then
          VJ=$(awk -F',' '$1=="valid_join"{print $2}' "$VC")
          VF=$(awk -F',' '$1=="valid_func"{print $2}' "$VC")
        fi

        local FULL_MS PRESENT_MS
        if [ -f "$PERF" ]; then
          FULL_MS=$(awk -F',' '$1=="warm" && $2=="top_groups_full"{printf("%.3f",$3)}' "$PERF")
          [ -z "$FULL_MS" ] && FULL_MS=$(awk -F',' '$1=="cold" && $2=="top_groups_full"{printf("%.3f",$3)}' "$PERF")
          PRESENT_MS=$(awk -F',' '$1=="warm" && $2=="top_groups_present"{printf("%.3f",$3)}' "$PERF")
          [ -z "$PRESENT_MS" ] && PRESENT_MS=$(awk -F',' '$1=="cold" && $2=="top_groups_present"{printf("%.3f",$3)}' "$PERF")
        fi

        echo "| metric | value |"
        echo "|---|---:|"
        [ -n "${DS:-}" ] && echo "| Decision space rows | ${DS} |"
        [ -n "${VM:-}" ] && echo "| Valid masks | ${VM} |"
        [ -n "${DR:-}" ] && echo "| Data rows | ${DR} |"
        [ -n "${PR:-}" ] && echo "| Present-only rows | ${PR} |"
        [ -n "${VJ:-}" ] && echo "| Valid via JOIN | ${VJ} |"
        [ -n "${VF:-}" ] && echo "| Valid via function | ${VF} |"
        [ -n "${FULL_MS:-}" ] && echo "| Top-groups latency (full) | ${FULL_MS} ms |"
        [ -n "${PRESENT_MS:-}" ] && echo "| Top-groups latency (present-only) | ${PRESENT_MS} ms |"
        # show present-only speedup if both latencies exist
        if [ -n "${FULL_MS:-}" ] && [ -n "${PRESENT_MS:-}" ]; then
          awk -v f="$FULL_MS" -v p="$PRESENT_MS" \
          'BEGIN{ if (f>0) printf("| Present-only speedup | %.1f%% |\n", (100*(f-p)/f)) }'
        fi
        echo
      fi

      # ---------- Dashboard summary ----------
      if [ -f "$PERF" ]; then
        local COLD_TOT WARM_TOT COLD_Q WARM_Q
        COLD_TOT=$(awk -F, 'NR>1 && $1=="cold"{s+=$3} END{printf("%.3f", s+0)}' "$PERF")
        WARM_TOT=$(awk -F, 'NR>1 && $1=="warm"{s+=$3} END{printf("%.3f", s+0)}' "$PERF")
        COLD_Q=$(awk -F, 'NR>1 && $1=="cold"{n++} END{print n+0}' "$PERF")
        WARM_Q=$(awk -F, 'NR>1 && $1=="warm"{n++} END{print n+0}' "$PERF")

        echo "**Simulated dashboard performance**"
        echo
        echo "| scenario | queries | total ms | avg per query |"
        echo "|---|---:|---:|---:|"
        awk -v ct="$COLD_TOT" -v cq="$COLD_Q" 'BEGIN{printf("| cold | %d | %.3f | %.3f |\n", cq, ct, (cq?ct/cq:0))}'
        awk -v wt="$WARM_TOT" -v wq="$WARM_Q" 'BEGIN{printf("| warm | %d | %.3f | %.3f |\n", wq, wt, (wq?wt/wq:0))}'
        echo
      fi

      # ---------- Artifacts ----------
      echo "_Artifacts_:"
      echo "- \`$BASE/$TS/$M/summary.csv\`"
      echo "- \`$BASE/$TS/$M/valid_counts.csv\`"
      echo "- \`$BASE/$TS/$M/top_groups_full.csv\`, plan: \`$BASE/$TS/$M/plan_top_groups_full.txt\`"
      echo "- \`$BASE/$TS/$M/top_groups_present.csv\`, plan: \`$BASE/$TS/$M/plan_top_groups_present.txt\`"
      [ -f "$PERF" ] && echo "- \`$BASE/$TS/$M/dashboard_perf.csv\` (cold/warm timings)"
      [ -f "$BASE/$TS/$M/compiler_sanity.txt" ] && echo "- \`$BASE/$TS/$M/compiler_sanity.txt\` (complexity & sanity output)"
      if ls "$BASE/$TS/$M"/kpi_*.csv >/dev/null 2>&1; then
        for f in "$BASE/$TS/$M"/kpi_*.csv; do
          bn=$(basename "$f")
          echo "- \`$BASE/$TS/$M/$bn\`"
        done
      fi
      echo
    done

    echo "<!-- RESULTS:END -->"
  } > "$OUT"

  echo ">> wrote $OUT"
}

# ========= PAPER: INJECT RESULTS INTO THE PAPER (between markers) =========
paper_update_paper() {
  local md="papers/acbp-systems-paper.md"
  local snippet="papers/results/results-latest.md"

  [ -f "$snippet" ] || { echo "!! $snippet not found. Run: ./acbp.sh paper-results-md"; return 1; }
  [ -f "$md" ] || { echo "!! $md not found"; return 1; }

  if ! grep -q '<!-- RESULTS:BEGIN -->' "$md"; then
    printf '\n\n## 8 Evaluation & Results\n\n<!-- RESULTS:BEGIN -->\n<!-- RESULTS:END -->\n' >> "$md"
  fi

  awk -v inc="$snippet" '
    BEGIN{copy=1}
    /<!-- RESULTS:BEGIN -->/ {print; system("cat " inc); copy=0; next}
    /<!-- RESULTS:END -->/   {print; copy=1; next}
    copy==1 {print}
  ' "$md" > "${md}.tmp" && mv "${md}.tmp" "$md"

  echo ">> injected results into ${md}"
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

Dashboard simulation:
  paper-bench-dashboard <model> [topN] [iters]   Cold+warm timings + KPI CSVs

Maintenance:
  vacuum <table>                   VACUUM ANALYZE a table
  psql-c "SQL..."                  Run one-off SQL via -c

Backup:
  backup [file.sql]                Dump the DB
  restore file.sql                 Restore from a dump
  restore-clean file.sql           Drop & recreate schema before restore

Paper:
  paper-seed <model> [N] [rebuild]  Seed <model>_data from decision_space
  paper-bench <model> [TOP_N]       Export summary + top-groups (+EXPLAIN)
  paper-results-all [N] [TOP_N]     Compile/apply, seed, export for all
  paper-results-md                  Build papers/results/results-latest.md
  paper-update-paper                Inject latest results into paper MD

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
  paper-bench-dashboard) paper_bench_dashboard "$@" ;;

  vacuum) vacuum "$@" ;;
  psql-c) psql-c "$@" ;;

  backup) backup "${1:-}" ;;
  restore) restore "$@" ;;
  restore-clean) restore-clean "$@" ;;

  paper-seed) paper_seed "$@" ;;
  paper-bench) paper_bench "$@" ;;
  paper-results-all) paper_results_all "${1:-50000}" "${2:-12}" ;;
  paper-results-md) paper_results_md "$@" ;;
  paper-update-paper) paper_update_paper "$@" ;;

  *) usage ;;
esac
