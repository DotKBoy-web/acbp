-- sql/000_ci_bootstrap.sql
-- Minimal ACBP mats for CI so the verifier can run on a clean DB.

-- Clinic Visit demo mats
DROP MATERIALIZED VIEW IF EXISTS public.clinic_visit_decision_space_mat;
CREATE MATERIALIZED VIEW public.clinic_visit_decision_space_mat AS
SELECT * FROM (VALUES
  (1::bigint,'apptA','siteA','adult','deptA','doc','inperson','09','Mon','InsA'),
  (2::bigint,'apptB','siteA','adult','deptA','doc','inperson','10','Mon','InsA')
) AS t(mask, appt_type, site, age_group, department, provider_role, modality, visit_hour, weekday, insurance);

DROP MATERIALIZED VIEW IF EXISTS public.clinic_visit_valid_masks_mat;
CREATE MATERIALIZED VIEW public.clinic_visit_valid_masks_mat AS
SELECT DISTINCT mask FROM public.clinic_visit_decision_space_mat;
CREATE UNIQUE INDEX IF NOT EXISTS clinic_visit_valid_masks_mat_pk
  ON public.clinic_visit_valid_masks_mat(mask);

-- Inpatient Admission demo mats (column names can differ; verifier is schema-agnostic)
DROP MATERIALIZED VIEW IF EXISTS public.inpatient_admission_decision_space_mat;
CREATE MATERIALIZED VIEW public.inpatient_admission_decision_space_mat AS
SELECT * FROM (VALUES
  (10::bigint,'admitA','siteX','adult','wardA','cons','inpatient','11','Tue','InsX'),
  (11::bigint,'admitB','siteX','adult','wardA','cons','inpatient','12','Tue','InsX')
) AS t(mask, admit_type, site, age_group, ward, consultant_role, modality, admit_hour, weekday, insurance);

DROP MATERIALIZED VIEW IF EXISTS public.inpatient_admission_valid_masks_mat;
CREATE MATERIALIZED VIEW public.inpatient_admission_valid_masks_mat AS
SELECT DISTINCT mask FROM public.inpatient_admission_decision_space_mat;
CREATE UNIQUE INDEX IF NOT EXISTS inpatient_admission_valid_masks_mat_pk
  ON public.inpatient_admission_valid_masks_mat(mask);
