# SPDX-License-Identifier: LicenseRef-DotK-Proprietary-NC-1.0
# Copyright (c) 2025 DotK (Muteb Hail S Al Anazi)

import json
import os
import glob
import shutil
import subprocess
from typing import Any, Dict, List, Optional

import pandas as pd
import streamlit as st
from sqlalchemy import create_engine, text
from sqlalchemy.engine import Engine

st.set_page_config(page_title="ACBP Bench & Explorer", layout="wide")
st.title("ACBP Bench & Explorer")
st.subheader("Copyright (c) 2025 DotK (Muteb Hail S Al Anazi)")

# ============================== Connection helpers ==============================

def mask_dsn(dsn: str) -> str:
    try:
        prefix, rest = dsn.split("://", 1)
        if "@" in rest and ":" in rest.split("@", 1)[0]:
            creds, tail = rest.split("@", 1)
            user, _pass = creds.split(":", 1)
            return f"{prefix}://{user}:******@{tail}"
        return dsn
    except Exception:
        return dsn

def sidebar_inputs() -> dict[str, Any]:
    st.sidebar.header("Database settings")
    host = st.sidebar.text_input("Host", value=os.environ.get("ACBP_HOST", "127.0.0.1"))
    port = st.sidebar.number_input("Port", value=int(os.environ.get("ACBP_PORT", "5434")), step=1)
    user = st.sidebar.text_input("User", value=os.environ.get("ACBP_USER", "postgres"))
    password = st.sidebar.text_input("Password", value=os.environ.get("ACBP_PASS", "acbp"), type="password")
    database = st.sidebar.text_input("Database", value=os.environ.get("ACBP_DB", "postgres"))

    st.sidebar.header("Apply via Docker (optional)")
    use_docker_apply = st.sidebar.checkbox("Use docker exec + psql for large SQL scripts", value=True)
    container = st.sidebar.text_input("Container name", value=os.environ.get("CONTAINER", "acbp-pg"))
    return dict(
        host=host, port=int(port), user=user, password=password, database=database,
        use_docker_apply=use_docker_apply, container=container
    )

def dsn_from_dict(d: dict) -> str:
    return f"postgresql+psycopg2://{d['user']}:{d['password']}@{d['host']}:{int(d['port'])}/{d['database']}"

def resolve_dsn(override_sidebar: bool) -> tuple[str, dict[str, Any]]:
    """
    Priority:
      1) env ACBP_DATABASE_URL or DATABASE_URL
      2) if override_sidebar=True -> use sidebar inputs
      3) secrets.toml -> [postgres]
      4) sidebar inputs (fallback)
    """
    sb = sidebar_inputs()
    env_dsn = os.environ.get("ACBP_DATABASE_URL") or os.environ.get("DATABASE_URL")
    if env_dsn:
        return env_dsn, sb

    if override_sidebar:
        return dsn_from_dict(sb), sb

    if "postgres" in st.secrets:
        cfg = st.secrets["postgres"]
        host = cfg.get("host", "127.0.0.1")
        port = cfg.get("port", 5434)
        user = cfg.get("user", "postgres")
        password = cfg.get("password", "")
        database = cfg.get("database", "postgres")
        return f"postgresql+psycopg2://{user}:{password}@{host}:{int(port)}/{database}", sb

    return dsn_from_dict(sb), sb

@st.cache_resource(show_spinner=False)
def get_engine(dsn: str) -> Engine:
    return create_engine(dsn, pool_pre_ping=True)

def run_df(engine: Engine, sql: str, params: Optional[Dict] = None) -> pd.DataFrame:
    with engine.connect() as conn:
        return pd.read_sql_query(text(sql), conn, params=params or {})

def run_scalar(engine: Engine, sql: str, params: Optional[Dict] = None):
    with engine.connect() as conn:
        row = conn.execute(text(sql), params or {}).fetchone()
        return list(row)[0] if row is not None else None

def run_ddl_autocommit(engine: Engine, sql: str):
    # for VACUUM etc.
    with engine.connect().execution_options(isolation_level="AUTOCOMMIT") as conn:
        conn.exec_driver_sql(sql)

def table_or_view_exists(engine: Engine, name: str) -> bool:
    sql = "SELECT to_regclass(:n) IS NOT NULL"
    return bool(run_scalar(engine, sql, {"n": name}))

def function_exists(engine: Engine, fn_name: str) -> bool:
    sql = """
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = :name
        LIMIT 1;
    """
    return run_df(engine, sql, {"name": fn_name}).shape[0] > 0

def list_models(engine: Engine) -> List[str]:
    sql = """
        SELECT REPLACE(table_name, '_decision_space','') AS model
        FROM information_schema.views
        WHERE table_schema='public' AND table_name LIKE '%\\_decision_space' ESCAPE '\\'
        ORDER BY 1;
    """
    df = run_df(engine, sql)
    return df["model"].tolist()

# ============================== Connect UI ==============================

st.sidebar.header("Connection")
override = st.sidebar.checkbox("Override secrets with sidebar values", value=True)
dsn, sb_cfg = resolve_dsn(override_sidebar=override)
st.sidebar.caption("Resolved DSN (masked):")
st.sidebar.code(mask_dsn(dsn))
connect = st.sidebar.button("Connect / Reconnect", type="primary")
ping = st.sidebar.button("Ping server")

engine = st.session_state.get("engine")
if connect or engine is None or st.session_state.get("dsn") != dsn:
    try:
        engine = get_engine(dsn)
        info = run_df(
            engine,
            "SELECT current_user, inet_server_addr() AS server_ip, inet_client_addr() AS client_ip, "
            "       setting AS password_encryption "
            "FROM pg_settings WHERE name='password_encryption';"
        )
        st.session_state["engine"] = engine
        st.session_state["dsn"] = dsn
        st.sidebar.success(
            f"Connected as {info.loc[0,'current_user']} "
            f"@ {info.loc[0,'server_ip']} (client={info.loc[0,'client_ip']}) "
            f"[pw={info.loc[0,'password_encryption']}]"
        )
    except Exception as e:
        st.sidebar.error("Connection failed. Check credentials/host/port.")
        st.sidebar.code(str(e))
        st.stop()

if ping:
    try:
        df = run_df(engine, "SELECT now() AS server_time, inet_client_addr() AS client_ip;")
        st.sidebar.info(df.to_string(index=False))
    except Exception as e:
        st.sidebar.error("Ping failed.")
        st.sidebar.code(str(e))

# ============================== Common UI bits ==============================

models = list_models(engine)
if not models:
    st.warning("No models found (no *_decision_space views). Compile/apply JSON first.")
    st.stop()

with st.sidebar.expander("Model & data", expanded=True):
    model = st.selectbox("Model", models, index=0)
    default_table = f"{model}_data"
    data_table = st.text_input("Data table", value=default_table)

with st.sidebar.expander("Bench options", expanded=True):
    bench_variant = st.radio("Variant", ["Full decision space", "Present-only"], index=0)
    top_n = st.number_input("Top groups (N)", value=12, min_value=1, step=1)

st.divider()

# ============================== Helpers for summaries ==============================

def decision_cols(engine: Engine, model: str) -> pd.DataFrame:
    sql = """
      SELECT column_name, data_type, ordinal_position
      FROM information_schema.columns
      WHERE table_schema='public' AND table_name=:t
      ORDER BY ordinal_position;
    """
    return run_df(engine, sql, {"t": f"{model}_decision_space"})

def model_summary(engine: Engine, model: str, data_table: str) -> Dict[str, Optional[int]]:
    # decision rows = size of decision space
    dec_rows = run_scalar(engine, f'SELECT COUNT(*) FROM "{model}_decision_space";')
    # valid masks = rows in _valid_masks
    valid_mask_rows = run_scalar(engine, f'SELECT COUNT(*) FROM "{model}_valid_masks";')
    # present-only (if built)
    present_cnt = None
    if table_or_view_exists(engine, f"{model}_present_mat"):
        present_cnt = run_scalar(engine, f'SELECT COUNT(*) FROM "{model}_present_mat";')
    # data rows (if exists)
    data_rows = None
    if table_or_view_exists(engine, data_table):
        data_rows = run_scalar(engine, f'SELECT COUNT(*) FROM "{data_table}";')
    return dict(decision_rows=dec_rows, valid_masks=valid_mask_rows, present_rows=present_cnt, data_rows=data_rows)

def _to_mapping(x):
    """Accept psycopg2 jsonb (dict), JSON strings/bytes, or None."""
    if isinstance(x, dict):
        return x
    if x is None:
        return {}
    if isinstance(x, (bytes, bytearray)):
        try:
            x = x.decode("utf-8", errors="ignore")
        except Exception:
            return {}
    if isinstance(x, str):
        try:
            return json.loads(x)
        except Exception:
            return {}
    return {}

# ============================== Tabs ==============================

tab_overview, tab_bench, tab_dsl, tab_maint, tab_sql = st.tabs(
    ["Overview", "Benchmarks", "DSL / Compile", "Maintenance", "SQL"]
)

# ------------------------------ Overview ------------------------------
with tab_overview:
    st.subheader("Model snapshot")
    cols = decision_cols(engine, model)
    summ = model_summary(engine, model, data_table)

    c1, c2, c3, c4 = st.columns(4)
    c1.metric("Decision space rows", f"{(summ['decision_rows'] or 0):,}")
    c2.metric("Valid mask rows", f"{(summ['valid_masks'] or 0):,}")
    c3.metric("Present-only rows", "—" if summ["present_rows"] is None else f"{summ['present_rows']:,}")
    c4.metric("Data rows", "—" if summ["data_rows"] is None else f"{summ['data_rows']:,}")

    st.caption("Decision space columns (order matters for composite index):")
    st.dataframe(cols, use_container_width=True, hide_index=True)

# ------------------------------ Benchmarks ------------------------------
with tab_bench:
    c1, c2, c3 = st.columns([1, 1, 1])
    with c1:
        run_bench = st.button("Run Benchmarks", type="primary")
    with c2:
        do_refresh = st.button("Refresh Matviews")
    with c3:
        do_refresh_present = st.button("Refresh Present-only")

    st.divider()

    if do_refresh:
        try:
            run_scalar(engine, "SELECT acbp_refresh(:m);", {"m": model})
            st.success("Refreshed matviews.")
        except Exception as e:
            st.error("Refresh failed.")
            st.exception(e)

    if do_refresh_present:
        try:
            if function_exists(engine, "acbp_refresh_present"):
                run_scalar(engine, "SELECT acbp_refresh_present(:m);", {"m": model})
                st.success("Refreshed present-only matview.")
            else:
                st.warning("acbp_refresh_present() not installed.")
        except Exception as e:
            st.error("Present-only refresh failed.")
            st.exception(e)

    if run_bench:
        mc1, mc2 = st.columns(2)
        with mc1:
            try:
                vj = run_scalar(engine, "SELECT acbp_bench_valid_join(:m, :t, true);", {"m": model, "t": data_table})
            except Exception as e:
                vj = None
                st.error("valid_join failed.")
                st.exception(e)
        with mc2:
            try:
                vf = run_scalar(engine, "SELECT acbp_bench_valid_func(:m, :t);", {"m": model, "t": data_table})
            except Exception as e:
                vf = None
                st.error("valid_func failed.")
                st.exception(e)

        k1, k2 = st.columns(2)
        k1.metric("Valid masks via JOIN", f"{vj:,}" if vj is not None else "—")
        k2.metric("Valid masks via function", f"{vf:,}" if vf is not None else "—")

        st.subheader("Top groupings")
        try:
            if bench_variant == "Full decision space":
                groups = run_df(
                    engine,
                    "SELECT * FROM acbp_bench_full_join(:m, :t, true, :n);",
                    {"m": model, "t": data_table, "n": int(top_n)},
                )
            else:
                if function_exists(engine, "acbp_bench_full_join_present"):
                    groups = run_df(
                        engine,
                        "SELECT * FROM acbp_bench_full_join_present(:m, :t, :n);",
                        {"m": model, "t": data_table, "n": int(top_n)},
                    )
                else:
                    st.warning("acbp_bench_full_join_present() not installed; falling back to full.")
                    groups = run_df(
                        engine,
                        "SELECT * FROM acbp_bench_full_join(:m, :t, true, :n);",
                        {"m": model, "t": data_table, "n": int(top_n)},
                    )

            if not groups.empty and "group_obj" in groups.columns:
                expanded = pd.json_normalize(groups["group_obj"].apply(_to_mapping))
                show = pd.concat([expanded, groups[["visits"]]], axis=1)
                st.dataframe(show, use_container_width=True, height=480)

                # quick bar chart
                if "visits" in groups.columns:
                    st.bar_chart(groups["visits"])
                # download
                csv = show.to_csv(index=False).encode("utf-8")
                st.download_button("Download CSV", csv, file_name=f"{model}_top_groups.csv", mime="text/csv")
            else:
                st.dataframe(groups, use_container_width=True, height=480)
        except Exception as e:
            st.error("Grouping query failed.")
            st.exception(e)

    st.divider()
    st.subheader("Explain mask (bit-only rules)")
    em1, em2 = st.columns([1, 3])
    with em1:
        mask_to_explain = st.number_input("Mask", min_value=0, value=7, step=1, key="mask_explain")
        explain_now = st.button("Explain", key="explain_btn")
    with em2:
        st.caption(f'Uses function: "acbp_explain_rules__{model}"')

    if explain_now:
        sql = f'SELECT * FROM "acbp_explain_rules__{model}"(:mask) WHERE NOT ok;'
        try:
            expl = run_df(engine, sql, {"mask": int(mask_to_explain)})
            if expl.empty:
                st.success("Mask satisfies all bit-only rules.")
            else:
                st.dataframe(expl, use_container_width=True)
        except Exception as e:
            st.error("Explain failed.")
            st.exception(e)

# ------------------------------ DSL / Compile ------------------------------
with tab_dsl:
    st.subheader("ACBP JSON (DSL) viewer / compiler")

    left, right = st.columns([1, 1])
    with left:
        json_files = sorted(glob.glob("*.json"))
        chosen = st.selectbox("Pick a local JSON file", options=json_files, index=0 if json_files else None)
        uploaded = st.file_uploader("...or upload a JSON", type=["json"])
        json_text = ""
        json_path_for_compile = None

        if uploaded is not None:
            json_text = uploaded.getvalue().decode("utf-8")
        elif chosen:
            try:
                with open(chosen, "r", encoding="utf-8") as f:
                    json_text = f.read()
                    json_path_for_compile = os.path.abspath(chosen)
            except Exception as e:
                st.error(f"Failed to read {chosen}: {e}")

        st.caption("Preview (first 4000 chars):")
        st.code(json_text[:4000] if json_text else "(no JSON)")

    with right:
        st.caption("Compile & Apply (optional)")
        python_exe = shutil.which("py") or shutil.which("python") or shutil.which("python3")
        can_compile = bool(python_exe and (json_path_for_compile or uploaded))
        st.text(f"Python CLI found: {python_exe or 'not found'}")
        st.text(f"Docker apply: {'on' if sb_cfg['use_docker_apply'] else 'off'} (container={sb_cfg['container']})")

        do_compile = st.button("Compile & Apply JSON", disabled=not can_compile, type="primary")
        if do_compile:
            try:
                # If uploaded, write to a temp file next to app
                if uploaded is not None and not json_path_for_compile:
                    json_path_for_compile = os.path.abspath(f"_uploaded_{uploaded.name}")
                    with open(json_path_for_compile, "w", encoding="utf-8") as f:
                        f.write(json_text)

                sql_out = os.path.abspath(os.path.splitext(json_path_for_compile)[0] + ".sql")
                # Run the CLI: acbp_tester <json> --enumerate -o <out.sql>
                cmd = [python_exe, "-m", "acbp_tester", json_path_for_compile, "--enumerate", "-o", sql_out]
                res = subprocess.run(cmd, capture_output=True, text=True)
                if res.returncode != 0:
                    st.error("Compiler failed.")
                    st.code(res.stdout + "\n" + res.stderr)
                    st.stop()

                st.success(f"Compiled OK → {os.path.basename(sql_out)}")
                st.code(res.stdout or "(no compiler stdout)")

                # Apply SQL
                with open(sql_out, "r", encoding="utf-8") as f:
                    sql_text = f.read()

                if sb_cfg["use_docker_apply"]:
                    # use docker psql to apply full script safely
                    cmd = [
                        "docker", "exec", "-i", sb_cfg["container"],
                        "psql", "-U", "postgres", "-d", sb_cfg.get("database", "postgres"),
                        "-v", "ON_ERROR_STOP=1", "-f", "-"
                    ]
                    proc = subprocess.run(cmd, input=sql_text.encode("utf-8"), capture_output=True)
                    if proc.returncode != 0:
                        st.error("psql apply failed.")
                        st.code(proc.stdout.decode("utf-8") + "\n" + proc.stderr.decode("utf-8"))
                        st.stop()
                    st.success("Applied SQL via docker psql.")
                else:
                    # light fallback: try to execute as a single script — OK if compiler emits standard CREATEs
                    try:
                        with engine.begin() as conn:
                            for stmt in sql_text.split(";\n"):
                                s = stmt.strip()
                                if s:
                                    conn.exec_driver_sql(s + ";")
                        st.success("Applied SQL via SQLAlchemy.")
                    except Exception as e:
                        st.error("Direct apply failed; turn on Docker apply in the sidebar.")
                        st.exception(e)
            except Exception as e:
                st.error("Compile/apply failed.")
                st.exception(e)

# ------------------------------ Maintenance ------------------------------
with tab_maint:
    st.subheader("Model maintenance")
    c1, c2, c3 = st.columns(3)
    with c1:
        if st.button("Materialize"):
            try:
                run_scalar(engine, "SELECT acbp_materialize(:m);", {"m": model})
                st.success("Materialized (or already materialized).")
            except Exception as e:
                st.error("Materialize failed.")
                st.exception(e)
    with c2:
        if st.button("Rematerialize (force)"):
            try:
                run_scalar(engine, "SELECT acbp_materialize(:m, true);", {"m": model})
                st.success("Rematerialized.")
            except Exception as e:
                st.error("Rematerialize failed.")
                st.exception(e)
    with c3:
        if st.button("Refresh matviews"):
            try:
                run_scalar(engine, "SELECT acbp_refresh(:m);", {"m": model})
                st.success("Refreshed.")
            except Exception as e:
                st.error("Refresh failed.")
                st.exception(e)

    st.divider()
    st.subheader("Present-only utilities")
    pc1, pc2, pc3 = st.columns(3)
    with pc1:
        if st.button("Materialize present-only"):
            try:
                if function_exists(engine, "acbp_materialize_present"):
                    run_scalar(engine, "SELECT acbp_materialize_present(:m, :t);", {"m": model, "t": data_table})
                    st.success("Present-only built.")
                else:
                    st.warning("acbp_materialize_present() not installed.")
            except Exception as e:
                st.error("Present-only materialize failed.")
                st.exception(e)
    with pc2:
        if st.button("Refresh present-only"):
            try:
                if function_exists(engine, "acbp_refresh_present"):
                    run_scalar(engine, "SELECT acbp_refresh_present(:m);", {"m": model})
                    st.success("Present-only refreshed.")
                else:
                    st.warning("acbp_refresh_present() not installed.")
            except Exception as e:
                st.error("Present-only refresh failed.")
                st.exception(e)
    with pc3:
        if st.button("Bench (present-only) quick check"):
            try:
                if function_exists(engine, "acbp_bench_full_join_present"):
                    df = run_df(engine,
                        "SELECT * FROM acbp_bench_full_join_present(:m, :t, 12);",
                        {"m": model, "t": data_table})
                    st.dataframe(df, use_container_width=True, height=420)
                else:
                    st.warning("acbp_bench_full_join_present() not installed.")
            except Exception as e:
                st.error("Present-only bench failed.")
                st.exception(e)

    st.divider()
    st.subheader("Indexes & VACUUM")
    ic1, ic2, ic3 = st.columns(3)
    with ic1:
        if st.button("Create matching index on data table"):
            try:
                if function_exists(engine, "acbp_create_matching_index"):
                    idx = run_scalar(engine, "SELECT acbp_create_matching_index(:m, :t);", {"m": model, "t": data_table})
                    st.success(f"Matching index ensured: {idx}")
                else:
                    st.warning("acbp_create_matching_index() not installed.")
            except Exception as e:
                st.error("Index creation failed.")
                st.exception(e)
    with ic2:
        if st.button("VACUUM ANALYZE data table"):
            try:
                run_ddl_autocommit(engine, f'VACUUM ANALYZE "{data_table}";')
                st.success("Vacuumed.")
            except Exception as e:
                st.error("VACUUM failed.")
                st.exception(e)
    with ic3:
        if st.button("List indexes"):
            try:
                df = run_df(engine, """
                  SELECT tablename, indexname, indexdef
                  FROM pg_indexes
                  WHERE tablename = :t
                  ORDER BY 1,2;
                """, {"t": data_table})
                st.dataframe(df, use_container_width=True, height=360)
            except Exception as e:
                st.error("Listing indexes failed.")
                st.exception(e)

# ------------------------------ SQL ------------------------------
with tab_sql:
    st.subheader("Run raw SQL (dangerous!)")
    sql_text = st.text_area("SQL", value="SELECT COUNT(*) FROM clinic_visit_data;")
    if st.button("Run SQL"):
        try:
            df = run_df(engine, sql_text)
            st.dataframe(df, use_container_width=True, height=520)
        except Exception as e:
            st.error("Query failed.")
            st.exception(e)
