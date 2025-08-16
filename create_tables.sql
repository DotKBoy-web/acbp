-- SPDX-License-Identifier: LicenseRef-DotK-Proprietary-NC-1.0
-- Copyright (c) 2025 DotK (Muteb Hail S Al Anazi)

-- ===== CLINIC DATA =====
DROP TABLE IF EXISTS clinic_visit_data CASCADE;
CREATE TABLE clinic_visit_data (
  mask          bigint NOT NULL,
  patient_mrn   text   NOT NULL,
  sex           text   NOT NULL,
  language      text   NOT NULL,
  city          text   NOT NULL,
  appt_type     text   NOT NULL,
  site          text   NOT NULL,
  age_group     text   NOT NULL,
  department    text   NOT NULL,
  provider_role text   NOT NULL,
  modality      text   NOT NULL,
  visit_hour    text   NOT NULL,
  weekday       text   NOT NULL,
  insurance     text   NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_clinic_mrn ON clinic_visit_data(patient_mrn);
CREATE INDEX IF NOT EXISTS idx_clinic_mask ON clinic_visit_data(mask);

-- ===== INPATIENT DATA =====
DROP TABLE IF EXISTS inpatient_admission_data CASCADE;
CREATE TABLE inpatient_admission_data (
  mask            bigint NOT NULL,
  patient_mrn     text   NOT NULL,
  sex             text   NOT NULL,
  language        text   NOT NULL,
  city            text   NOT NULL,
  admission_type  text   NOT NULL,
  site            text   NOT NULL,
  age_group       text   NOT NULL,
  ward            text   NOT NULL,
  payer           text   NOT NULL,
  arrival_source  text   NOT NULL,
  admit_hour      text   NOT NULL,
  weekday         text   NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_ip_mrn ON inpatient_admission_data(patient_mrn);
CREATE INDEX IF NOT EXISTS idx_ip_mask ON inpatient_admission_data(mask);
