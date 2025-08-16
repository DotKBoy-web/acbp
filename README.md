> See also: **[The ACBP Equation](docs/ACBP-Equation.md)** — canonical definition & compiler contract.

# ACBP — Bitmask DSL, Benchmarks & Explorer
A tiny domain-specific language (DSL) for composing And/Constraint/Bitmask/Policy models, plus a Postgres toolkit and a Streamlit app for exploration and benchmarking.

## (Quickstart)

### 0) Start Postgres in Docker on port 5434
./acbp.sh down
PORT=5434 ./acbp.sh up

### 1) Create demo tables & load sample data
./acbp.sh apply create_tables.sql
docker cp clinic_visit_data_part1.csv acbp-pg:/tmp/
docker cp clinic_visit_data_part2.csv acbp-pg:/tmp/
docker cp inpatient_admission_data_part1.csv acbp-pg:/tmp/
docker cp inpatient_admission_data_part2.csv acbp-pg:/tmp/
docker exec -i acbp-pg psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c "\
  COPY clinic_visit_data      FROM '/tmp/clinic_visit_data_part1.csv'      CSV HEADER; \
  COPY clinic_visit_data      FROM '/tmp/clinic_visit_data_part2.csv'      CSV HEADER; \
  COPY inpatient_admission_data FROM '/tmp/inpatient_admission_data_part1.csv' CSV HEADER; \
  COPY inpatient_admission_data FROM '/tmp/inpatient_admission_data_part2.csv' CSV HEADER;"

### 2) Compile and apply DSL -> SQL
./acbp.sh compile-apply clinic_visit.json
./acbp.sh compile-apply inpatient_admission.json

### 3) Install helper functions & materialize
./acbp.sh reinstall-db-utils
./acbp.sh materialize clinic_visit
./acbp.sh materialize inpatient_admission

### 4) Benchmarks (CLI)
./acbp.sh bench-all clinic_visit clinic_visit_data
./acbp.sh bench-all inpatient_admission inpatient_admission_data

### 5) Streamlit app (UI)
#### set DSN via secrets or just use the sidebar; default is 127.0.0.1:5434 postgres/acbp
python -m streamlit run acbp_app.py

## Project layout

.ACBP V0.1/
├─ acbp.sh                     # Docker + DB utilities & benches
├─ acbp_tester.py              # DSL compiler CLI (JSON -> SQL)
├─ acbp_app.py                 # Streamlit "Bench & Explorer"
├─ acbp_app_demo.py            # Optional demo/alternate app
├─ clinic_visit.json           # DSL model (OPD)
├─ inpatient_admission.json    # DSL model (IPD)
├─ clinic_visit.sql            # Generated SQL (from compiler)
├─ inpatient_admission.sql     # Generated SQL (from compiler)
├─ create_tables.sql           # Demo tables + COPY targets
├─ clinic_visit_data_part*.csv # Demo data
├─ inpatient_admission_data_*.csv
├─ make_data.py                # Dataset generator (optional)
├─ requirements.txt            # Python deps
└─ .streamlit/secrets.toml     # Optional Streamlit DSN

## Requirements

Docker Desktop
Python 3.11+ (virtualenv recommended)
Git Bash (or WSL/PowerShell; examples use Git Bash)
Postgres client inside container (handled by postgres:16-alpine image)

### Python deps:

python -m venv .venv
source .venv/Scripts/activate  # (Windows Git Bash)
pip install -r requirements.txt

## The DSL

### The JSON models (e.g., clinic_visit.json, inpatient_admission.json) define:
Bit rules (the mask semantics)
Category dimensions (decision space)

### Auto-generated artifacts:
*_valid_masks (view) + *_valid_masks_mat (matview)
*_decision_space (view) + *_decision_space_mat (matview)
acbp_is_valid__<model>() (bit-only validator)
acbp_is_valid__<model>_cats(...) (bit + category validator)
acbp_explain_rules__<model>(mask) (explain violated bit rules)
#### Compile with:
./acbp.sh compile-apply clinic_visit.json
The compiler prints model complexity and enumerated valid masks.

## Helper functions (DB)

### Install/update utility functions:
./acbp.sh reinstall-db-utils

### Key functions:
acbp_materialize(model text, force bool default false)
acbp_refresh(model text)
acbp_bench_valid_join(model, data_table, use_mat bool)
acbp_bench_valid_func(model, data_table)
acbp_bench_full_join(model, data_table, use_mat bool, top_n int)

### Present-only variants:
acbp_materialize_present(model, data_table)
acbp_refresh_present(model)
acbp_bench_full_join_present(model, data_table, top_n int)

### Matching index:
acbp_create_matching_index(model, data_table)

## Benchmarks (CLI)

./acbp.sh bench-all clinic_visit clinic_visit_data
./acbp.sh bench-all inpatient_admission inpatient_admission_data

### You’ll see three measurements:
valid masks via JOIN
valid masks via function
top groupings (JSONB group keys + visit counts)

### Present-only decision-space (faster when data sparsity is high):
./acbp.sh materialize-present clinic_visit clinic_visit_data
./acbp.sh bench-all-present clinic_visit clinic_visit_data

## Streamlit app
python -m streamlit run acbp_app.py

### Configure connection

#### Option A (secrets): .streamlit/secrets.toml
[postgres]
host = "127.0.0.1"
port = 5434
user = "postgres"
password = "acbp"
database = "postgres"

#### Option B (env): ACBP_DATABASE_URL=postgresql+psycopg2://postgres:acbp@127.0.0.1:5434/postgres
#### Option C: Use the sidebar “Override” fields.

### Tabs

Overview: decision space columns & row counts
Benchmarks: run JOIN vs function counts, top groupings, explain mask
DSL / Compile: preview JSON, compile via acbp_tester, apply via Docker psql
Maintenance: materialize/refresh, present-only utilities, index & VACUUM
SQL: run ad-hoc queries (careful!)

## Data loading

### Tables (from create_tables.sql):
clinic_visit_data(mask, patient_mrn, sex, language, city, appt_type, site, age_group, department, provider_role, modality, visit_hour, weekday, insurance)
inpatient_admission_data(mask, patient_mrn, sex, language, city, admission_type, site, age_group, ward, payer, arrival_source, admit_hour, weekday)

### Re-load CSVs:
docker cp clinic_visit_data_part1.csv acbp-pg:/tmp/
docker cp clinic_visit_data_part2.csv acbp-pg:/tmp/
docker cp inpatient_admission_data_part1.csv acbp-pg:/tmp/
docker cp inpatient_admission_data_part2.csv acbp-pg:/tmp/

docker exec -i acbp-pg psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c "\
  COPY clinic_visit_data FROM '/tmp/clinic_visit_data_part1.csv' CSV HEADER; \
  COPY clinic_visit_data FROM '/tmp/clinic_visit_data_part2.csv' CSV HEADER; \
  COPY inpatient_admission_data FROM '/tmp/inpatient_admission_data_part1.csv' CSV HEADER; \
  COPY inpatient_admission_data FROM '/tmp/inpatient_admission_data_part2.csv' CSV HEADER;"

### After large loads:
./acbp.sh vacuum clinic_visit_data
./acbp.sh vacuum inpatient_admission_data

## Troubleshooting

Port conflict with local PostgreSQL:
    Use a different host port: PORT=5434 ./acbp.sh up
Password auth fails:
    Inside container, set: ALTER ROLE postgres WITH PASSWORD 'acbp';
“No models found” in UI:
    Run ./acbp.sh compile-apply <model>.json and ./acbp.sh reinstall-db-utils
Top grouping error in UI:
    Fixed—JSONB is now handled as native dicts.
Matview drift (columns changed in DSL):
    ./acbp.sh rematerialize <model> (drops & rebuilds matviews)

## License

Source-available for **noncommercial, personal evaluation only** under
**DotK Proprietary Noncommercial License v1.0**. Commercial or production
use requires a paid license.
Contact: `dotkboy@outlook.com`
SPDX-License-Identifier: LicenseRef-DotK-Proprietary-NC-1.0

[![DOI](https://zenodo.org/badge/DOI/10.5281/zenodo.16888028.svg)](https://doi.org/10.5281/zenodo.16888028)
