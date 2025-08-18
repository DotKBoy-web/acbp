-- ACBP demo: live dashboard latency sim + percentiles + SLO (Wilson bound)
-- Safe: keeps raw rows forever; derives analytics in views/matviews.

SET search_path = public;

-- 1) RAW TABLE (append-only)
CREATE TABLE IF NOT EXISTS dashboard_runs_raw (
  id           BIGSERIAL PRIMARY KEY,
  ts           timestamptz NOT NULL DEFAULT now(),
  model        text        NOT NULL CHECK (model IN ('clinic','inpatient')),
  bundle_name  text        NOT NULL DEFAULT 'kpi9',
  duration_ms  integer     NOT NULL CHECK (duration_ms > 0),
  ok           boolean     NOT NULL DEFAULT true
);
COMMENT ON TABLE  dashboard_runs_raw IS 'Raw dashboard bundle runs (append-only).';
COMMENT ON COLUMN dashboard_runs_raw.duration_ms IS 'Bundle wall time in milliseconds (9-query KPI pack).';

-- 2) SLO / THRESHOLDS (reference table)
CREATE TABLE IF NOT EXISTS dashboard_slo_thresholds (
  model        text PRIMARY KEY,
  threshold_ms integer NOT NULL
);
INSERT INTO dashboard_slo_thresholds (model, threshold_ms) VALUES
  ('clinic',    920),
  ('inpatient', 700)
ON CONFLICT (model) DO UPDATE SET threshold_ms = EXCLUDED.threshold_ms;
COMMENT ON TABLE dashboard_slo_thresholds IS 'Per-model latency thresholds for SLO (95% ≤ threshold).';

-- 3) SEED SYNTHETIC DATA (only if empty)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM dashboard_runs_raw) THEN
    -- 14 days × 2 models × ~120 runs/day ≈ 3,360 rows
    -- Clinic: 95% in [0.70..0.92]s (median ~0.81s), 5% tail [0.92..1.30]s
    INSERT INTO dashboard_runs_raw (ts, model, duration_ms)
    SELECT
      gs_day + (i * interval '12 minutes') AS ts,
      'clinic'::text AS model,
      GREATEST(1,
        ROUND( (1000 * (
          CASE WHEN random() < 0.95
               THEN 0.70 + random() * 0.22           -- main mass
               ELSE 0.92 + random() * 0.38           -- tail
          END
        ))::numeric, 0 )
      )::int AS duration_ms
    FROM generate_series(date_trunc('day', now()) - interval '13 days'
                       , date_trunc('day', now())
                       , interval '1 day') AS gs_day
    CROSS JOIN generate_series(0, 119) AS i;

    -- Inpatient: 95% in [0.50..0.72]s (median ~0.61s), 5% tail [0.70..1.00]s
    INSERT INTO dashboard_runs_raw (ts, model, duration_ms)
    SELECT
      gs_day + (i * interval '12 minutes') AS ts,
      'inpatient'::text AS model,
      GREATEST(1,
        ROUND( (1000 * (
          CASE WHEN random() < 0.95
               THEN 0.50 + random() * 0.22
               ELSE 0.70 + random() * 0.30
          END
        ))::numeric, 0 )
      )::int AS duration_ms
    FROM generate_series(date_trunc('day', now()) - interval '13 days'
                       , date_trunc('day', now())
                       , interval '1 day') AS gs_day
    CROSS JOIN generate_series(0, 119) AS i;
  END IF;
END$$;

-- 4) DAILY PERCENTILES (view → matview)
CREATE OR REPLACE VIEW dashboard_daily_percentiles AS
SELECT
  (date_trunc('day', ts))::date         AS day,
  model,
  percentile_cont(0.50) WITHIN GROUP (ORDER BY duration_ms) AS p50_ms,
  percentile_cont(0.95) WITHIN GROUP (ORDER BY duration_ms) AS p95_ms,
  COUNT(*)::int AS n
FROM dashboard_runs_raw
GROUP BY 1,2;

DROP MATERIALIZED VIEW IF EXISTS dashboard_daily_percentiles_mat;
CREATE MATERIALIZED VIEW dashboard_daily_percentiles_mat AS
SELECT * FROM dashboard_daily_percentiles;

CREATE UNIQUE INDEX IF NOT EXISTS idx_daily_percentiles_mat_pk
  ON dashboard_daily_percentiles_mat(day, model);

COMMENT ON MATERIALIZED VIEW dashboard_daily_percentiles_mat
IS 'Daily P50/P95 per model (materialized).';

-- 5) OVERALL SUMMARY (matview)
DROP MATERIALIZED VIEW IF EXISTS dashboard_summary_mat;
CREATE MATERIALIZED VIEW dashboard_summary_mat AS
SELECT
  model,
  percentile_cont(0.50) WITHIN GROUP (ORDER BY duration_ms) AS p50_ms,
  percentile_cont(0.95) WITHIN GROUP (ORDER BY duration_ms) AS p95_ms,
  COUNT(*)::int AS n
FROM dashboard_runs_raw
GROUP BY model
ORDER BY model;

CREATE UNIQUE INDEX IF NOT EXISTS idx_dashboard_summary_mat_model
  ON dashboard_summary_mat(model);

COMMENT ON MATERIALIZED VIEW dashboard_summary_mat
IS 'Overall P50/P95 per model (materialized).';

-- 6) DAILY SLO: proportion ≤ threshold + one-sided 95% Wilson lower bound
DROP MATERIALIZED VIEW IF EXISTS dashboard_daily_slo_mat;
CREATE MATERIALIZED VIEW dashboard_daily_slo_mat AS
WITH base AS (
  SELECT
    (date_trunc('day', ts))::date AS day,
    r.model,
    COUNT(*)::float8 AS n,
    COUNT(*) FILTER (WHERE r.duration_ms <= t.threshold_ms)::float8 AS k,
    t.threshold_ms::float8 AS thr
  FROM dashboard_runs_raw r
  JOIN dashboard_slo_thresholds t USING (model)
  GROUP BY 1,2, t.threshold_ms
), params AS (
  SELECT 1.64485362695147::float8 AS z  -- one-sided 95%
), calc AS (
  SELECT
    b.day,
    b.model,
    b.thr AS threshold_ms,
    b.n::int AS samples,
    b.k::int AS at_or_below_thr,
    (b.k/b.n) AS p_hat,
    -- Wilson one-sided LOWER bound for p = k/n (proportion in [0,1])
    (
      ((b.k/b.n) + (p.z*p.z)/(2.0*b.n) - p.z * sqrt( ((b.k/b.n)*(1.0-(b.k/b.n)) + (p.z*p.z)/(4.0*b.n)) / b.n ))
      / (1.0 + (p.z*p.z)/b.n)
    ) AS wilson_lower_prop
  FROM base b, params p
)
SELECT
  day,
  model,
  threshold_ms,
  samples,
  at_or_below_thr,
  ROUND( (100.0 * p_hat)::numeric, 2 )           AS pct_at_or_below_thr,
  ROUND( (100.0 * wilson_lower_prop)::numeric, 2 ) AS wilson_lower_pct
FROM calc
ORDER BY 1,2;

CREATE UNIQUE INDEX IF NOT EXISTS idx_daily_slo_mat_pk
  ON dashboard_daily_slo_mat(day, model);

COMMENT ON MATERIALIZED VIEW dashboard_daily_slo_mat
IS 'Per-day success rate ≤ threshold + Wilson lower bound (one-sided 95%).';

-- 7) Convenience function to refresh all mats
CREATE OR REPLACE FUNCTION acbp_refresh_dashboard()
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  -- Use CONCURRENTLY when possible (unique indexes present)
  BEGIN
    EXECUTE 'REFRESH MATERIALIZED VIEW CONCURRENTLY dashboard_daily_percentiles_mat';
  EXCEPTION WHEN feature_not_supported THEN
    EXECUTE 'REFRESH MATERIALIZED VIEW dashboard_daily_percentiles_mat';
  END;

  BEGIN
    EXECUTE 'REFRESH MATERIALIZED VIEW CONCURRENTLY dashboard_summary_mat';
  EXCEPTION WHEN feature_not_supported THEN
    EXECUTE 'REFRESH MATERIALIZED VIEW dashboard_summary_mat';
  END;

  BEGIN
    EXECUTE 'REFRESH MATERIALIZED VIEW CONCURRENTLY dashboard_daily_slo_mat';
  EXCEPTION WHEN feature_not_supported THEN
    EXECUTE 'REFRESH MATERIALIZED VIEW dashboard_daily_slo_mat';
  END;
END$$;
COMMENT ON FUNCTION acbp_refresh_dashboard() IS 'Refresh all dashboard materialized views.';
