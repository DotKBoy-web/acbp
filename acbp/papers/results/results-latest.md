<!-- RESULTS:BEGIN -->
## 8.1 Results (synthetic; 50k rows per model)

_Run timestamps (UTC): clinic_visit=20250817T175223Z; inpatient_admission=20250817T175243Z_

### Clinic Visit

**Complexity & sanity (compiler)**

```text
Model: clinic_visit
  B (flags):       5
  B_eff (reduced): 5
  n_eff (cats):    101250
  Complexity:      2^5 * 101250
  Valid masks enumerated (bit-only): 6 / 32
  First few: [0, 1, 3, 7, 9, 17]
=== Sanity estimates (uniform, independent categories; FORBID_WHEN only) ===
  Flag prevalence among valid masks: booked=83.3%, checked_in=33.3%, seen_by_doctor=16.7%, canceled=16.7%, rescheduled=16.7%
  Theoretical max rows (bit-only):   607,500
  Est. remaining rows (cat rules):   478,125  (~78.7% of max)
  Est. pruned rows (cat rules):      129,375
  note: Applied FORBID_WHEN estimates: booked@50.00%; booked@33.33%. Excluded 4 FORBID_IF_SQL rule(s) from estimate.
=== Actuals (latest summary) ===
  Decision rows: 295,650  (~48.7% of theoretical; pruned 311,850)
  Present-only rows: 50,000
  Data rows: 50,000
```

**Simulated dashboard performance**

| scenario | queries | total ms | avg per query |
|---|---:|---:|---:|
| cold | 9 | 879.837 | 97.760 |
| warm | 9 | 825.539 | 91.727 |

_Artifacts_:
- `papers/results/20250817T175223Z/clinic_visit/summary.csv`
- `papers/results/20250817T175223Z/clinic_visit/valid_counts.csv`
- `papers/results/20250817T175223Z/clinic_visit/top_groups_full.csv`, plan: `papers/results/20250817T175223Z/clinic_visit/plan_top_groups_full.txt`
- `papers/results/20250817T175223Z/clinic_visit/top_groups_present.csv`, plan: `papers/results/20250817T175223Z/clinic_visit/plan_top_groups_present.txt`
- `papers/results/20250817T175223Z/clinic_visit/dashboard_perf.csv` (cold/warm timings)
- `papers/results/20250817T175223Z/clinic_visit/compiler_sanity.txt` (complexity & sanity output)
- `papers/results/20250817T175223Z/clinic_visit/kpi_by_age_group.csv`
- `papers/results/20250817T175223Z/clinic_visit/kpi_by_appt_type.csv`
- `papers/results/20250817T175223Z/clinic_visit/kpi_by_appt_type_site.csv`
- `papers/results/20250817T175223Z/clinic_visit/kpi_by_department.csv`
- `papers/results/20250817T175223Z/clinic_visit/kpi_by_provider_role.csv`
- `papers/results/20250817T175223Z/clinic_visit/kpi_by_site.csv`

### Inpatient Admission

**Complexity & sanity (compiler)**

```text
Model: inpatient_admission
  B (flags):       6
  B_eff (reduced): 6
  n_eff (cats):    24192
  Complexity:      2^6 * 24192
  Valid masks enumerated (bit-only): 10 / 64
  First few: [0, 1, 3, 7, 11, 15, 19, 23, 35, 39]
=== Sanity estimates (uniform, independent categories; FORBID_WHEN only) ===
  Flag prevalence among valid masks: booked=90.0%, checked_in=80.0%, in_icu=40.0%, discharged=20.0%, expired=20.0%, transferred=20.0%
  Theoretical max rows (bit-only):   241,920
  Est. remaining rows (cat rules):   117,279  (~48.5% of max)
  Est. pruned rows (cat rules):      124,641
  note: Applied FORBID_WHEN estimates: booked@33.33%; in_icu@25.00%; in_icu@25.00%; in_icu@25.00%; discharged@25.00%.
=== Actuals (latest summary) ===
  Decision rows: 126,000  (~52.1% of theoretical; pruned 115,920)
  Present-only rows: 50,000
  Data rows: 50,000
```

**Simulated dashboard performance**

| scenario | queries | total ms | avg per query |
|---|---:|---:|---:|
| cold | 9 | 609.826 | 67.758 |
| warm | 9 | 622.174 | 69.130 |

_Artifacts_:
- `papers/results/20250817T175243Z/inpatient_admission/summary.csv`
- `papers/results/20250817T175243Z/inpatient_admission/valid_counts.csv`
- `papers/results/20250817T175243Z/inpatient_admission/top_groups_full.csv`, plan: `papers/results/20250817T175243Z/inpatient_admission/plan_top_groups_full.txt`
- `papers/results/20250817T175243Z/inpatient_admission/top_groups_present.csv`, plan: `papers/results/20250817T175243Z/inpatient_admission/plan_top_groups_present.txt`
- `papers/results/20250817T175243Z/inpatient_admission/dashboard_perf.csv` (cold/warm timings)
- `papers/results/20250817T175243Z/inpatient_admission/compiler_sanity.txt` (complexity & sanity output)
- `papers/results/20250817T175243Z/inpatient_admission/kpi_by_admission_type.csv`
- `papers/results/20250817T175243Z/inpatient_admission/kpi_by_admission_type_site.csv`
- `papers/results/20250817T175243Z/inpatient_admission/kpi_by_age_group.csv`
- `papers/results/20250817T175243Z/inpatient_admission/kpi_by_payer.csv`
- `papers/results/20250817T175243Z/inpatient_admission/kpi_by_site.csv`
- `papers/results/20250817T175243Z/inpatient_admission/kpi_by_ward.csv`

<!-- RESULTS:END -->
