-- Drop + create materialized views listing "dead" masks (bit-valid ∧ category-impossible)
DROP MATERIALIZED VIEW IF EXISTS public.clinic_visit_dead_masks_mat;
CREATE MATERIALIZED VIEW public.clinic_visit_dead_masks_mat AS
SELECT b.mask
FROM public.clinic_visit_valid_masks_bit_mat b
LEFT JOIN public.clinic_visit_valid_masks_mat m USING(mask)
WHERE m.mask IS NULL;

DROP MATERIALIZED VIEW IF EXISTS public.inpatient_admission_dead_masks_mat;
CREATE MATERIALIZED VIEW public.inpatient_admission_dead_masks_mat AS
SELECT b.mask
FROM public.inpatient_admission_valid_masks_bit_mat b
LEFT JOIN public.inpatient_admission_valid_masks_mat m USING(mask)
WHERE m.mask IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS clinic_visit_dead_masks_pk
  ON public.clinic_visit_dead_masks_mat(mask);
CREATE UNIQUE INDEX IF NOT EXISTS inpatient_admission_dead_masks_pk
  ON public.inpatient_admission_dead_masks_mat(mask);
