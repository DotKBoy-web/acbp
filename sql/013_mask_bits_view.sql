-- Generic view to expand masks into bit positions (0..63)
DROP VIEW IF EXISTS public.mask_bits CASCADE;
CREATE VIEW public.mask_bits AS
SELECT m.model,
       m.mask::bigint AS mask,
       b.bit_index,
       ((m.mask::bigint >> b.bit_index) & 1)::int AS bit_value
FROM (
  SELECT 'clinic_visit' AS model, mask FROM public.clinic_visit_valid_masks_bit_mat
  UNION ALL
  SELECT 'inpatient_admission', mask FROM public.inpatient_admission_valid_masks_bit_mat
) AS m
CROSS JOIN LATERAL generate_series(0, 63) AS b(bit_index)
WHERE ((m.mask::bigint >> b.bit_index) & 1) = 1;
