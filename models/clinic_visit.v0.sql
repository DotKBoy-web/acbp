-- ACBP Postgres SQL for model: clinic_visit
-- Flags:
--                   booked : bit 0
--               checked_in : bit 1
--           seen_by_doctor : bit 2
--                 canceled : bit 3
--              rescheduled : bit 4

-- === ACBP helpers (idempotent) ===
CREATE OR REPLACE FUNCTION acbp_popcount(x bigint)
RETURNS int
LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT length(replace((x)::bit(64)::text, '0',''));
$$;

-- === Categories for clinic_visit ===
CREATE OR REPLACE VIEW "clinic_visit_categories" AS
WITH cats AS (
  SELECT * FROM (SELECT unnest(ARRAY['NewPatient', 'FollowUp', 'Urgent', 'Procedure', 'Teleconsult']) AS "appt_type") c1
  CROSS JOIN (SELECT unnest(ARRAY['Main', 'Annex', 'Downtown']) AS "site") c2
  CROSS JOIN (SELECT unnest(ARRAY['Peds', 'Adult', 'Geriatric']) AS "age_group") c3
  CROSS JOIN (SELECT unnest(ARRAY['General', 'Cardiology', 'Orthopedics', 'Imaging', 'Pediatrics']) AS "department") c4
  CROSS JOIN (SELECT unnest(ARRAY['Attending', 'Resident', 'NP/PA']) AS "provider_role") c5
  CROSS JOIN (SELECT unnest(ARRAY['InPerson', 'Virtual']) AS "modality") c6
  CROSS JOIN (SELECT unnest(ARRAY['08:00', '09:00', '10:00', '11:00', '14:00']) AS "visit_hour") c7
  CROSS JOIN (SELECT unnest(ARRAY['Mon', 'Tue', 'Wed', 'Thu', 'Fri']) AS "weekday") c8
  CROSS JOIN (SELECT unnest(ARRAY['SelfPay', 'Private', 'Government']) AS "insurance") c9
)
SELECT * FROM cats;

-- === Decision space for clinic_visit (PRUNED by bit + category rules) ===
CREATE OR REPLACE VIEW "clinic_visit_decision_space" AS
WITH masks AS (
  SELECT gs::bigint AS mask FROM generate_series(0, 31) gs
),
cats AS (
  SELECT * FROM (SELECT unnest(ARRAY['NewPatient', 'FollowUp', 'Urgent', 'Procedure', 'Teleconsult']) AS "appt_type") c1
  CROSS JOIN (SELECT unnest(ARRAY['Main', 'Annex', 'Downtown']) AS "site") c2
  CROSS JOIN (SELECT unnest(ARRAY['Peds', 'Adult', 'Geriatric']) AS "age_group") c3
  CROSS JOIN (SELECT unnest(ARRAY['General', 'Cardiology', 'Orthopedics', 'Imaging', 'Pediatrics']) AS "department") c4
  CROSS JOIN (SELECT unnest(ARRAY['Attending', 'Resident', 'NP/PA']) AS "provider_role") c5
  CROSS JOIN (SELECT unnest(ARRAY['InPerson', 'Virtual']) AS "modality") c6
  CROSS JOIN (SELECT unnest(ARRAY['08:00', '09:00', '10:00', '11:00', '14:00']) AS "visit_hour") c7
  CROSS JOIN (SELECT unnest(ARRAY['Mon', 'Tue', 'Wed', 'Thu', 'Fri']) AS "weekday") c8
  CROSS JOIN (SELECT unnest(ARRAY['SelfPay', 'Private', 'Government']) AS "insurance") c9
)
SELECT m.mask, c.*
FROM masks m
CROSS JOIN cats c
WHERE
  (((((m.mask >> 1) & 1)) = 0 OR (((m.mask >> 0) & 1)) = 1) AND
    ((((m.mask >> 2) & 1)) = 0 OR (((m.mask >> 1) & 1)) = 1) AND
    ((((m.mask >> 4) & 1)) = 0 OR (((m.mask >> 0) & 1)) = 1) AND
    ((((m.mask >> 3) & 1)) = 0 OR (((m.mask >> 0) & 1)) = 1) AND
    ((((m.mask >> 3) & 1)) + (((m.mask >> 1) & 1)) <= 1) AND
    ((((m.mask >> 3) & 1)) + (((m.mask >> 4) & 1)) <= 1) AND
    ((((m.mask >> 4) & 1)) + (((m.mask >> 1) & 1)) <= 1) AND
    ((((m.mask >> 4) & 1)) + (((m.mask >> 2) & 1)) <= 1)) AND (
    NOT ( ((modality = 'Virtual') AND (department IN ('Imaging', 'Orthopedics'))) AND ((((m.mask >> 0) & 1)) = 1) ) AND
    NOT ( ((appt_type = 'Teleconsult' AND modality <> 'Virtual')) AND ((((m.mask >> 0) & 1)) = 1) ) AND
    NOT ( ((modality = 'Virtual' AND appt_type NOT IN ('FollowUp','Teleconsult'))) AND ((((m.mask >> 0) & 1)) = 1) ) AND
    NOT ( ((visit_hour NOT IN ('09:00','10:00','11:00','14:00'))) AND ((((m.mask >> 2) & 1)) = 1) ) AND
    NOT ( ((site = 'Annex') AND (department = 'Cardiology')) AND ((((m.mask >> 0) & 1)) = 1) ) AND
    NOT ( ((department = 'Pediatrics' AND age_group <> 'Peds')) AND ((((m.mask >> 0) & 1)) = 1) )
  )
;

-- === Valid masks for clinic_visit (derived from PRUNED decision space) ===
CREATE OR REPLACE VIEW "clinic_visit_valid_masks" AS
SELECT DISTINCT mask FROM "clinic_visit_decision_space";

-- === Bit-explained view for clinic_visit ===
CREATE OR REPLACE VIEW "clinic_visit_explain" AS
SELECT
  mask,
  ((((mask >> 0) & 1))) AS "booked",
  ((((mask >> 1) & 1))) AS "checked_in",
  ((((mask >> 2) & 1))) AS "seen_by_doctor",
  ((((mask >> 3) & 1))) AS "canceled",
  ((((mask >> 4) & 1))) AS "rescheduled"
FROM "clinic_visit_valid_masks";

-- === Validator (bit-only) for clinic_visit ===
CREATE OR REPLACE FUNCTION "acbp_is_valid__clinic_visit"(mask bigint)
RETURNS boolean
LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT (((((mask >> 1) & 1)) = 0 OR (((mask >> 0) & 1)) = 1) AND
    ((((mask >> 2) & 1)) = 0 OR (((mask >> 1) & 1)) = 1) AND
    ((((mask >> 4) & 1)) = 0 OR (((mask >> 0) & 1)) = 1) AND
    ((((mask >> 3) & 1)) = 0 OR (((mask >> 0) & 1)) = 1) AND
    ((((mask >> 3) & 1)) + (((mask >> 1) & 1)) <= 1) AND
    ((((mask >> 3) & 1)) + (((mask >> 4) & 1)) <= 1) AND
    ((((mask >> 4) & 1)) + (((mask >> 1) & 1)) <= 1) AND
    ((((mask >> 4) & 1)) + (((mask >> 2) & 1)) <= 1));
$$;

-- === Bit-only explainer for clinic_visit ===
CREATE OR REPLACE FUNCTION "acbp_explain_rules__clinic_visit"(mask bigint)
RETURNS TABLE(rule text, ok boolean)
LANGUAGE sql IMMUTABLE STRICT AS $$
SELECT 'IMPLIES(checked_in -> booked)'::text AS rule, (((((mask >> 1) & 1)) = 0 OR (((mask >> 0) & 1)) = 1))::boolean AS ok
UNION ALL
SELECT 'IMPLIES(seen_by_doctor -> checked_in)'::text AS rule, (((((mask >> 2) & 1)) = 0 OR (((mask >> 1) & 1)) = 1))::boolean AS ok
UNION ALL
SELECT 'IMPLIES(rescheduled -> booked)'::text AS rule, (((((mask >> 4) & 1)) = 0 OR (((mask >> 0) & 1)) = 1))::boolean AS ok
UNION ALL
SELECT 'IMPLIES(canceled -> booked)'::text AS rule, (((((mask >> 3) & 1)) = 0 OR (((mask >> 0) & 1)) = 1))::boolean AS ok
UNION ALL
SELECT 'MUTEX(canceled, checked_in)'::text AS rule, (((((mask >> 3) & 1)) + (((mask >> 1) & 1)) <= 1))::boolean AS ok
UNION ALL
SELECT 'MUTEX(canceled, rescheduled)'::text AS rule, (((((mask >> 3) & 1)) + (((mask >> 4) & 1)) <= 1))::boolean AS ok
UNION ALL
SELECT 'MUTEX(rescheduled, checked_in)'::text AS rule, (((((mask >> 4) & 1)) + (((mask >> 1) & 1)) <= 1))::boolean AS ok
UNION ALL
SELECT 'MUTEX(rescheduled, seen_by_doctor)'::text AS rule, (((((mask >> 4) & 1)) + (((mask >> 2) & 1)) <= 1))::boolean AS ok
$$;

-- === Category-aware validator for clinic_visit ===
CREATE OR REPLACE FUNCTION "acbp_is_valid__clinic_visit_cats"(mask bigint, appt_type text, site text, age_group text, department text, provider_role text, modality text, visit_hour text, weekday text, insurance text)
RETURNS boolean
LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT (((((mask >> 1) & 1)) = 0 OR (((mask >> 0) & 1)) = 1) AND
    ((((mask >> 2) & 1)) = 0 OR (((mask >> 1) & 1)) = 1) AND
    ((((mask >> 4) & 1)) = 0 OR (((mask >> 0) & 1)) = 1) AND
    ((((mask >> 3) & 1)) = 0 OR (((mask >> 0) & 1)) = 1) AND
    ((((mask >> 3) & 1)) + (((mask >> 1) & 1)) <= 1) AND
    ((((mask >> 3) & 1)) + (((mask >> 4) & 1)) <= 1) AND
    ((((mask >> 4) & 1)) + (((mask >> 1) & 1)) <= 1) AND
    ((((mask >> 4) & 1)) + (((mask >> 2) & 1)) <= 1) AND NOT ( ((modality = 'Virtual') AND (department IN ('Imaging', 'Orthopedics'))) AND ((((mask >> 0) & 1)) = 1) ) AND NOT ( ((appt_type = 'Teleconsult' AND modality <> 'Virtual')) AND ((((mask >> 0) & 1)) = 1) ) AND NOT ( ((modality = 'Virtual' AND appt_type NOT IN ('FollowUp','Teleconsult'))) AND ((((mask >> 0) & 1)) = 1) ) AND NOT ( ((visit_hour NOT IN ('09:00','10:00','11:00','14:00'))) AND ((((mask >> 2) & 1)) = 1) ) AND NOT ( ((site = 'Annex') AND (department = 'Cardiology')) AND ((((mask >> 0) & 1)) = 1) ) AND NOT ( ((department = 'Pediatrics' AND age_group <> 'Peds')) AND ((((mask >> 0) & 1)) = 1) ));
$$;

-- === Category-aware explainer for clinic_visit ===
CREATE OR REPLACE FUNCTION "acbp_explain__clinic_visit"(mask bigint, appt_type text, site text, age_group text, department text, provider_role text, modality text, visit_hour text, weekday text, insurance text)
RETURNS TABLE(rule text, ok boolean)
LANGUAGE sql IMMUTABLE STRICT AS $$
WITH bit_rules AS (
SELECT 'IMPLIES(checked_in -> booked)'::text AS rule, (((((mask >> 1) & 1)) = 0 OR (((mask >> 0) & 1)) = 1))::boolean AS ok
UNION ALL
SELECT 'IMPLIES(seen_by_doctor -> checked_in)'::text AS rule, (((((mask >> 2) & 1)) = 0 OR (((mask >> 1) & 1)) = 1))::boolean AS ok
UNION ALL
SELECT 'IMPLIES(rescheduled -> booked)'::text AS rule, (((((mask >> 4) & 1)) = 0 OR (((mask >> 0) & 1)) = 1))::boolean AS ok
UNION ALL
SELECT 'IMPLIES(canceled -> booked)'::text AS rule, (((((mask >> 3) & 1)) = 0 OR (((mask >> 0) & 1)) = 1))::boolean AS ok
UNION ALL
SELECT 'MUTEX(canceled, checked_in)'::text AS rule, (((((mask >> 3) & 1)) + (((mask >> 1) & 1)) <= 1))::boolean AS ok
UNION ALL
SELECT 'MUTEX(canceled, rescheduled)'::text AS rule, (((((mask >> 3) & 1)) + (((mask >> 4) & 1)) <= 1))::boolean AS ok
UNION ALL
SELECT 'MUTEX(rescheduled, checked_in)'::text AS rule, (((((mask >> 4) & 1)) + (((mask >> 1) & 1)) <= 1))::boolean AS ok
UNION ALL
SELECT 'MUTEX(rescheduled, seen_by_doctor)'::text AS rule, (((((mask >> 4) & 1)) + (((mask >> 2) & 1)) <= 1))::boolean AS ok
), cat_rules AS (
SELECT 'FORBID(booked when modality=Virtual, department={Imaging|Orthopedics})'::text AS rule, (NOT ( ((modality = 'Virtual') AND (department IN ('Imaging', 'Orthopedics'))) AND ((((mask >> 0) & 1)) = 1) ))::boolean AS ok
UNION ALL
SELECT 'FORBID(booked when SQL: (appt_type = ''Teleconsult'' AND modality <> ''Virtual''))'::text AS rule, (NOT ( ((appt_type = 'Teleconsult' AND modality <> 'Virtual')) AND ((((mask >> 0) & 1)) = 1) ))::boolean AS ok
UNION ALL
SELECT 'FORBID(booked when SQL: (modality = ''Virtual'' AND appt_type NOT IN (''FollowUp'',''Teleconsult'')))'::text AS rule, (NOT ( ((modality = 'Virtual' AND appt_type NOT IN ('FollowUp','Teleconsult'))) AND ((((mask >> 0) & 1)) = 1) ))::boolean AS ok
UNION ALL
SELECT 'FORBID(seen_by_doctor when SQL: (visit_hour NOT IN (''09:00'',''10:00'',''11:00'',''14:00'')))'::text AS rule, (NOT ( ((visit_hour NOT IN ('09:00','10:00','11:00','14:00'))) AND ((((mask >> 2) & 1)) = 1) ))::boolean AS ok
UNION ALL
SELECT 'FORBID(booked when site=Annex, department=Cardiology)'::text AS rule, (NOT ( ((site = 'Annex') AND (department = 'Cardiology')) AND ((((mask >> 0) & 1)) = 1) ))::boolean AS ok
UNION ALL
SELECT 'FORBID(booked when SQL: (department = ''Pediatrics'' AND age_group <> ''Peds''))'::text AS rule, (NOT ( ((department = 'Pediatrics' AND age_group <> 'Peds')) AND ((((mask >> 0) & 1)) = 1) ))::boolean AS ok
)
SELECT * FROM bit_rules
UNION ALL
SELECT * FROM cat_rules;
$$;
