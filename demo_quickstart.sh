# SPDX-License-Identifier: LicenseRef-DotK-Proprietary-NC-1.0
# Copyright (c) 2025 DotK (Muteb Hail S Al Anazi)

#!/usr/bin/env bash
set -euo pipefail
PORT=${PORT:-5434}

./acbp.sh down || true
PORT=$PORT ./acbp.sh up

./acbp.sh apply create_tables.sql

docker cp clinic_visit_data_part1.csv acbp-pg:/tmp/
docker cp clinic_visit_data_part2.csv acbp-pg:/tmp/
docker cp inpatient_admission_data_part1.csv acbp-pg:/tmp/
docker cp inpatient_admission_data_part2.csv acbp-pg:/tmp/

docker exec -i acbp-pg psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c "\
  COPY clinic_visit_data FROM '/tmp/clinic_visit_data_part1.csv' CSV HEADER; \
  COPY clinic_visit_data FROM '/tmp/clinic_visit_data_part2.csv' CSV HEADER; \
  COPY inpatient_admission_data FROM '/tmp/inpatient_admission_data_part1.csv' CSV HEADER; \
  COPY inpatient_admission_data FROM '/tmp/inpatient_admission_data_part2.csv' CSV HEADER;"

./acbp.sh compile-apply clinic_visit.json
./acbp.sh compile-apply inpatient_admission.json

./acbp.sh reinstall-db-utils
./acbp.sh materialize clinic_visit
./acbp.sh materialize inpatient_admission

./acbp.sh vacuum clinic_visit_data
./acbp.sh vacuum inpatient_admission_data

./acbp.sh bench-all clinic_visit clinic_visit_data
./acbp.sh bench-all inpatient_admission inpatient_admission_data
