# SPDX-License-Identifier: LicenseRef-DotK-Proprietary-NC-1.0
# Copyright (c) 2025 DotK (Muteb Hail S Al Anazi)
#!/usr/bin/env bash
set -e
export ACBP_DATABASE_URL="postgresql+psycopg2://postgres:acbp@127.0.0.1:5434/postgres"
[ -f ".venv/Scripts/activate" ] && source ".venv/Scripts/activate"
python -m streamlit run acbp_app.py
