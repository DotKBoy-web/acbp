# Contributing to ACBP

> Status: limited contributions accepted

Thanks for your interest! This repo is licensed under the
**DotK Proprietary Noncommercial License v1.0**. To protect the core IP:

- We welcome **issues** (bugs, docs fixes, feature proposals).
- We accept **small PRs** for docs, tooling, CI, schema, or examples.
- **Core code changes** (e.g., `acbp_tester.py`, rule engine internals) require
  **prior written approval**. Open an issue first.

## Quick dev setup

- Python 3.11+, Docker Desktop, Git
- (Optional) virtual env:
```bash
  python -m venv .venv && . .venv/Scripts/activate  # on Windows PowerShell: .\.venv\Scripts\Activate.ps1
  pip install -r requirements.txt
```
- Start Postgres:
```bash
./acbp.sh up
```
- (Re)compile a model:
```bash
./acbp.sh compile-apply clinic_visit.json
```
- Run the app:
```bash
streamlit run acbp_app.py
```

## Style & commits

* Use Conventional Commits (e.g., docs: ..., fix: ..., chore: ...).
* Keep PRs focused and small; include a short rationale.

## License of contributions

By submitting a PR, you agree your contribution is licensed under
DotK Proprietary Noncommercial License v1.0 for inclusion in this project.
