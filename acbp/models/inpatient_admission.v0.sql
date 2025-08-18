-- ACBP Postgres SQL for model: inpatient_admission
-- Flags:
--                   booked : bit 0
--               checked_in : bit 1
--                   in_icu : bit 2
--               discharged : bit 3
--                  expired : bit 4
--              transferred : bit 5

-- === ACBP helpers (idempotent) ===
CREATE OR REPLACE FUNCTION acbp_popcount(x bigint)
RETURNS int
LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT length(replace((x)::bit(64)::text, '0',''));
$$;

-- === Categories for inpatient_admission ===
CREATE OR REPLACE VIEW "inpatient_admission_categories" AS
WITH cats AS (
  SELECT * FROM (SELECT unnest(ARRAY['Elective', 'Emergency', 'Transfer']) AS "admission_type") c1
  CROSS JOIN (SELECT unnest(ARRAY['Main', 'Annex']) AS "site") c2
  CROSS JOIN (SELECT unnest(ARRAY['Adult', 'Peds']) AS "age_group") c3
  CROSS JOIN (SELECT unnest(ARRAY['Medical', 'Surgical', 'ICU', 'StepDown']) AS "ward") c4
  CROSS JOIN (SELECT unnest(ARRAY['SelfPay', 'Private', 'Public']) AS "payer") c5
  CROSS JOIN (SELECT unnest(ARRAY['ED', 'Clinic', 'Transfer', 'Direct']) AS "arrival_source") c6
  CROSS JOIN (SELECT unnest(ARRAY['00:00', '04:00', '08:00', '12:00', '16:00', '20:00']) AS "admit_hour") c7
  CROSS JOIN (SELECT unnest(ARRAY['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']) AS "weekday") c8
)
SELECT * FROM cats;

-- === Decision space for inpatient_admission (PRUNED by bit + category rules) ===
CREATE OR REPLACE VIEW "inpatient_admission_decision_space" AS
WITH masks AS (
  SELECT gs::bigint AS mask FROM generate_series(0, 63) gs
),
cats AS (
  SELECT * FROM (SELECT unnest(ARRAY['Elective', 'Emergency', 'Transfer']) AS "admission_type") c1
  CROSS JOIN (SELECT unnest(ARRAY['Main', 'Annex']) AS "site") c2
  CROSS JOIN (SELECT unnest(ARRAY['Adult', 'Peds']) AS "age_group") c3
  CROSS JOIN (SELECT unnest(ARRAY['Medical', 'Surgical', 'ICU', 'StepDown']) AS "ward") c4
  CROSS JOIN (SELECT unnest(ARRAY['SelfPay', 'Private', 'Public']) AS "payer") c5
  CROSS JOIN (SELECT unnest(ARRAY['ED', 'Clinic', 'Transfer', 'Direct']) AS "arrival_source") c6
  CROSS JOIN (SELECT unnest(ARRAY['00:00', '04:00', '08:00', '12:00', '16:00', '20:00']) AS "admit_hour") c7
  CROSS JOIN (SELECT unnest(ARRAY['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']) AS "weekday") c8
)
SELECT m.mask, c.*
FROM masks m
CROSS JOIN cats c
WHERE
  (((((m.mask >> 1) & 1)) = 0 OR (((m.mask >> 0) & 1)) = 1) AND
    ((((m.mask >> 2) & 1)) = 0 OR (((m.mask >> 1) & 1)) = 1) AND
    ((((m.mask >> 3) & 1)) = 0 OR (((m.mask >> 1) & 1)) = 1) AND
    ((((m.mask >> 4) & 1)) = 0 OR (((m.mask >> 1) & 1)) = 1) AND
    ((((m.mask >> 5) & 1)) = 0 OR (((m.mask >> 1) & 1)) = 1) AND
    ((((m.mask >> 3) & 1)) + (((m.mask >> 4) & 1)) <= 1) AND
    ((((m.mask >> 3) & 1)) + (((m.mask >> 5) & 1)) <= 1) AND
    ((((m.mask >> 4) & 1)) + (((m.mask >> 5) & 1)) <= 1)) AND (
    NOT ( ((admission_type = 'Emergency')) AND ((((m.mask >> 0) & 1)) = 1) ) AND
    NOT ( ((ward = 'Medical')) AND ((((m.mask >> 2) & 1)) = 1) ) AND
    NOT ( ((ward = 'Surgical')) AND ((((m.mask >> 2) & 1)) = 1) ) AND
    NOT ( ((ward = 'StepDown')) AND ((((m.mask >> 2) & 1)) = 1) ) AND
    NOT ( ((arrival_source = 'Transfer')) AND ((((m.mask >> 3) & 1)) = 1) )
  )
;

-- === Valid masks for inpatient_admission (derived from PRUNED decision space) ===
CREATE OR REPLACE VIEW "inpatient_admission_valid_masks" AS
SELECT DISTINCT mask FROM "inpatient_admission_decision_space";

-- === Bit-explained view for inpatient_admission ===
CREATE OR REPLACE VIEW "inpatient_admission_explain" AS
SELECT
  mask,
  ((((mask >> 0) & 1))) AS "booked",
  ((((mask >> 1) & 1))) AS "checked_in",
  ((((mask >> 2) & 1))) AS "in_icu",
  ((((mask >> 3) & 1))) AS "discharged",
  ((((mask >> 4) & 1))) AS "expired",
  ((((mask >> 5) & 1))) AS "transferred"
FROM "inpatient_admission_valid_masks";

-- === Validator (bit-only) for inpatient_admission ===
CREATE OR REPLACE FUNCTION "acbp_is_valid__inpatient_admission"(mask bigint)
RETURNS boolean
LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT (((((mask >> 1) & 1)) = 0 OR (((mask >> 0) & 1)) = 1) AND
    ((((mask >> 2) & 1)) = 0 OR (((mask >> 1) & 1)) = 1) AND
    ((((mask >> 3) & 1)) = 0 OR (((mask >> 1) & 1)) = 1) AND
    ((((mask >> 4) & 1)) = 0 OR (((mask >> 1) & 1)) = 1) AND
    ((((mask >> 5) & 1)) = 0 OR (((mask >> 1) & 1)) = 1) AND
    ((((mask >> 3) & 1)) + (((mask >> 4) & 1)) <= 1) AND
    ((((mask >> 3) & 1)) + (((mask >> 5) & 1)) <= 1) AND
    ((((mask >> 4) & 1)) + (((mask >> 5) & 1)) <= 1));
$$;

-- === Bit-only explainer for inpatient_admission ===
CREATE OR REPLACE FUNCTION "acbp_explain_rules__inpatient_admission"(mask bigint)
RETURNS TABLE(rule text, ok boolean)
LANGUAGE sql IMMUTABLE STRICT AS $$
SELECT 'IMPLIES(checked_in -> booked)'::text AS rule, (((((mask >> 1) & 1)) = 0 OR (((mask >> 0) & 1)) = 1))::boolean AS ok
UNION ALL
SELECT 'IMPLIES(in_icu -> checked_in)'::text AS rule, (((((mask >> 2) & 1)) = 0 OR (((mask >> 1) & 1)) = 1))::boolean AS ok
UNION ALL
SELECT 'IMPLIES(discharged -> checked_in)'::text AS rule, (((((mask >> 3) & 1)) = 0 OR (((mask >> 1) & 1)) = 1))::boolean AS ok
UNION ALL
SELECT 'IMPLIES(expired -> checked_in)'::text AS rule, (((((mask >> 4) & 1)) = 0 OR (((mask >> 1) & 1)) = 1))::boolean AS ok
UNION ALL
SELECT 'IMPLIES(transferred -> checked_in)'::text AS rule, (((((mask >> 5) & 1)) = 0 OR (((mask >> 1) & 1)) = 1))::boolean AS ok
UNION ALL
SELECT 'MUTEX(discharged, expired)'::text AS rule, (((((mask >> 3) & 1)) + (((mask >> 4) & 1)) <= 1))::boolean AS ok
UNION ALL
SELECT 'MUTEX(discharged, transferred)'::text AS rule, (((((mask >> 3) & 1)) + (((mask >> 5) & 1)) <= 1))::boolean AS ok
UNION ALL
SELECT 'MUTEX(expired, transferred)'::text AS rule, (((((mask >> 4) & 1)) + (((mask >> 5) & 1)) <= 1))::boolean AS ok
$$;

-- === Category-aware validator for inpatient_admission ===
CREATE OR REPLACE FUNCTION "acbp_is_valid__inpatient_admission_cats"(mask bigint, admission_type text, site text, age_group text, ward text, payer text, arrival_source text, admit_hour text, weekday text)
RETURNS boolean
LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT (((((mask >> 1) & 1)) = 0 OR (((mask >> 0) & 1)) = 1) AND
    ((((mask >> 2) & 1)) = 0 OR (((mask >> 1) & 1)) = 1) AND
    ((((mask >> 3) & 1)) = 0 OR (((mask >> 1) & 1)) = 1) AND
    ((((mask >> 4) & 1)) = 0 OR (((mask >> 1) & 1)) = 1) AND
    ((((mask >> 5) & 1)) = 0 OR (((mask >> 1) & 1)) = 1) AND
    ((((mask >> 3) & 1)) + (((mask >> 4) & 1)) <= 1) AND
    ((((mask >> 3) & 1)) + (((mask >> 5) & 1)) <= 1) AND
    ((((mask >> 4) & 1)) + (((mask >> 5) & 1)) <= 1) AND NOT ( ((admission_type = 'Emergency')) AND ((((mask >> 0) & 1)) = 1) ) AND NOT ( ((ward = 'Medical')) AND ((((mask >> 2) & 1)) = 1) ) AND NOT ( ((ward = 'Surgical')) AND ((((mask >> 2) & 1)) = 1) ) AND NOT ( ((ward = 'StepDown')) AND ((((mask >> 2) & 1)) = 1) ) AND NOT ( ((arrival_source = 'Transfer')) AND ((((mask >> 3) & 1)) = 1) ));
$$;

-- === Category-aware explainer for inpatient_admission ===
CREATE OR REPLACE FUNCTION "acbp_explain__inpatient_admission"(mask bigint, admission_type text, site text, age_group text, ward text, payer text, arrival_source text, admit_hour text, weekday text)
RETURNS TABLE(rule text, ok boolean)
LANGUAGE sql IMMUTABLE STRICT AS $$
WITH bit_rules AS (
SELECT 'IMPLIES(checked_in -> booked)'::text AS rule, (((((mask >> 1) & 1)) = 0 OR (((mask >> 0) & 1)) = 1))::boolean AS ok
UNION ALL
SELECT 'IMPLIES(in_icu -> checked_in)'::text AS rule, (((((mask >> 2) & 1)) = 0 OR (((mask >> 1) & 1)) = 1))::boolean AS ok
UNION ALL
SELECT 'IMPLIES(discharged -> checked_in)'::text AS rule, (((((mask >> 3) & 1)) = 0 OR (((mask >> 1) & 1)) = 1))::boolean AS ok
UNION ALL
SELECT 'IMPLIES(expired -> checked_in)'::text AS rule, (((((mask >> 4) & 1)) = 0 OR (((mask >> 1) & 1)) = 1))::boolean AS ok
UNION ALL
SELECT 'IMPLIES(transferred -> checked_in)'::text AS rule, (((((mask >> 5) & 1)) = 0 OR (((mask >> 1) & 1)) = 1))::boolean AS ok
UNION ALL
SELECT 'MUTEX(discharged, expired)'::text AS rule, (((((mask >> 3) & 1)) + (((mask >> 4) & 1)) <= 1))::boolean AS ok
UNION ALL
SELECT 'MUTEX(discharged, transferred)'::text AS rule, (((((mask >> 3) & 1)) + (((mask >> 5) & 1)) <= 1))::boolean AS ok
UNION ALL
SELECT 'MUTEX(expired, transferred)'::text AS rule, (((((mask >> 4) & 1)) + (((mask >> 5) & 1)) <= 1))::boolean AS ok
), cat_rules AS (
SELECT 'FORBID(booked when admission_type=Emergency)'::text AS rule, (NOT ( ((admission_type = 'Emergency')) AND ((((mask >> 0) & 1)) = 1) ))::boolean AS ok
UNION ALL
SELECT 'FORBID(in_icu when ward=Medical)'::text AS rule, (NOT ( ((ward = 'Medical')) AND ((((mask >> 2) & 1)) = 1) ))::boolean AS ok
UNION ALL
SELECT 'FORBID(in_icu when ward=Surgical)'::text AS rule, (NOT ( ((ward = 'Surgical')) AND ((((mask >> 2) & 1)) = 1) ))::boolean AS ok
UNION ALL
SELECT 'FORBID(in_icu when ward=StepDown)'::text AS rule, (NOT ( ((ward = 'StepDown')) AND ((((mask >> 2) & 1)) = 1) ))::boolean AS ok
UNION ALL
SELECT 'FORBID(discharged when arrival_source=Transfer)'::text AS rule, (NOT ( ((arrival_source = 'Transfer')) AND ((((mask >> 3) & 1)) = 1) ))::boolean AS ok
)
SELECT * FROM bit_rules
UNION ALL
SELECT * FROM cat_rules;
$$;
