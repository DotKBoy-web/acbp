@echo off
setlocal
REM adjust if you prefer secrets.toml instead
set ACBP_DATABASE_URL=postgresql+psycopg2://postgres:acbp@127.0.0.1:5434/postgres
REM activate venv if you use it
IF EXIST ".venv\Scripts\activate.bat" CALL ".venv\Scripts\activate.bat"
python -m streamlit run acbp_app.py
