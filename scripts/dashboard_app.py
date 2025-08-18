#!/usr/bin/env python3
"""
ACBP — Live Dashboard (Latency + Business KPIs)

What changed:
- Keeps your latency section (uses mats from sql/020_dashboard_live_latency_sim.sql)
- Business KPIs no longer require a real DATE column:
  * Option A: Calendar grouping (date/day parse) — same as before
  * Option B: Categorical grouping (e.g., weekday / visit_hour / site / department)
- Status is derived from ACBP bits in `mask` (no need for a literal 'status' column):
  Clinic bits:    0=booked,1=checked_in,2=seen_by_doctor,3=canceled,4=rescheduled
  Inpatient bits: 0=booked,1=checked_in,2=in_icu,3=discharged,4=expired,5=transferred
- Uses matplotlib only (no seaborn), one chart per figure, default colors
"""

from __future__ import annotations

import contextlib
import io
import os
from dataclasses import dataclass
from typing import Iterable, List, Tuple, Dict, Optional

import matplotlib.pyplot as plt
import pandas as pd
import psycopg
import streamlit as st


# ------------------------
# Minimal .env loader
# ------------------------
def load_dotenv_file(path: str = ".env") -> None:
    if not os.path.exists(path):
        return
    with open(path, "r", encoding="utf-8") as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            os.environ.setdefault(k.strip(), v.strip())


def ensure_database_url() -> str:
    dsn = os.environ.get("DATABASE_URL")
    if dsn:
        return dsn
    load_dotenv_file()
    dsn = os.environ.get("DATABASE_URL")
    if dsn:
        return dsn
    host = os.environ.get("PGHOST", "localhost")
    port = os.environ.get("HOST_PORT", "5432")
    user = os.environ.get("POSTGRES_USER", "postgres")
    pwd = os.environ.get("POSTGRES_PASSWORD", "")
    db = os.environ.get("POSTGRES_DB", "postgres")
    dsn = f"postgresql://{user}:{pwd}@{host}:{port}/{db}"
    os.environ["DATABASE_URL"] = dsn
    return dsn


DB_URL = ensure_database_url()


@contextlib.contextmanager
def get_conn():
    if not DB_URL:
        raise RuntimeError("DATABASE_URL is not set")
    # autocommit avoids transaction-aborted cascades on UI errors
    with psycopg.connect(DB_URL, autocommit=True) as conn:
        yield conn


# ------------------------
# DB helpers
# ------------------------
def fetch_df(conn, sql: str, params: Dict | None = None) -> pd.DataFrame:
    with conn.cursor() as cur:
        cur.execute(sql, params or {})
        cols = [d[0] for d in cur.description]
        rows = cur.fetchall()
    return pd.DataFrame(rows, columns=cols)


def try_fetch(conn, label: str, sql: str, params: Dict | None = None) -> pd.DataFrame:
    try:
        return fetch_df(conn, sql, params=params)
    except Exception as e:
        try:
            conn.rollback()
        except Exception:
            pass
        st.error(f"Query failed: {label}")
        st.exception(e)
        return pd.DataFrame()


def to_regclass_exists(conn, name: str) -> bool:
    q = "SELECT to_regclass(%(n)s)"
    with conn.cursor() as cur:
        cur.execute(q, {"n": name})
        row = cur.fetchone()
        if row and row[0]:
            return True
        if "." not in name:
            cur.execute(q, {"n": f"public.{name}"})
            row = cur.fetchone()
            return bool(row and row[0])
        return False


def list_tables(conn, schemas: Iterable[str] = ("public",)) -> List[str]:
    q = """
    SELECT table_schema, table_name
    FROM information_schema.tables
    WHERE table_type='BASE TABLE' AND table_schema = ANY(%(schemas)s)
    ORDER BY 1, 2
    """
    with conn.cursor() as cur:
        cur.execute(q, {"schemas": list(schemas)})
        return [f"{s}.{t}" for (s, t) in cur.fetchall()]


def list_columns_with_types(conn, name: str) -> List[Tuple[str, str]]:
    schema, dot, tbl = name.partition(".")
    if not dot:
        schema, tbl = "public", schema
    q = """
      SELECT column_name, data_type
      FROM information_schema.columns
      WHERE table_schema=%(s)s AND table_name=%(t)s
      ORDER BY ordinal_position
    """
    with conn.cursor() as cur:
        cur.execute(q, {"s": schema, "t": tbl})
        return [(r[0], r[1]) for r in cur.fetchall()]


# ------------------------
# Column inference & validation
# ------------------------
DATEY_NAMES = {
    "day", "date", "visit_day", "visit_date", "appt_day", "appt_date",
    "admit_day", "admit_date", "discharge_day", "discharge_date",
}
TIMEY_NAMES = {"time", "visit_time", "appt_time", "admit_time", "discharge_time"}

NUMERIC_TYPES = {"smallint", "integer", "bigint", "numeric", "real", "double precision"}
TEXT_TYPES = {"text", "character varying", "character"}
DATE_TYPES = {"date"}
TS_TYPES = {"timestamp without time zone", "timestamp with time zone"}

def categorize_type(pg_type: str) -> str:
    t = pg_type.lower()
    if t in DATE_TYPES:
        return "date"
    if t in TS_TYPES:
        return "timestamp"
    if t in TEXT_TYPES:
        return "text"
    if t in NUMERIC_TYPES:
        return "number"
    return "other"

def guess_day_candidates(cols: List[Tuple[str, str]]) -> List[str]:
    # Prefer name+type hints; fall back to any date/timestamp/text
    by_name = [c for (c,t) in cols if c in DATEY_NAMES and categorize_type(t) in {"date","timestamp","text","number"}]
    if by_name:
        return by_name
    type_pref = [c for (c,t) in cols if categorize_type(t) in {"date","timestamp","text"}]
    if type_pref:
        return type_pref
    # allow numeric for YYYYMMDD
    return [c for (c,t) in cols if categorize_type(t) == "number"]

def guess_time_candidates(cols: List[Tuple[str, str]]) -> List[str]:
    out = [c for c,t in cols if c in TIMEY_NAMES and categorize_type(t) == "text"]
    out += [c for c,t in cols if "time" in c and categorize_type(t) == "text" and c not in out]
    return out

def guess_text_group_candidates(cols: List[Tuple[str, str]]) -> List[str]:
    # candidates for categorical grouping (textual enums)
    return [c for c,t in cols if categorize_type(t) == "text"]

def safe_ident(col: str, allowed: set[str]) -> str:
    if col not in allowed:
        raise ValueError(f"Column {col} not in table")
    return f'"{col}"'

@dataclass
class DayMode:
    key: str
    label: str
    compatible_types: tuple[str, ...]

DAY_MODES: List[DayMode] = [
    DayMode("iso_text_or_date", "Already DATE or 'YYYY-MM-DD' text", ("date", "timestamp", "text")),
    DayMode("yyyymmdd_int",     "Integer YYYYMMDD (e.g., 20250818)", ("number",)),
    DayMode("yyyymmdd_text",    "Text YYYYMMDD (e.g., '20250818')", ("text",)),
    DayMode("yyyy_mm_dd_text",  "Text YYYY-MM-DD", ("text",)),
    DayMode("mmddyyyy_text",    "Text MM/DD/YYYY", ("text",)),
    DayMode("epoch_seconds_int","Epoch seconds (int)", ("number",)),
    DayMode("combine_day_time_iso", "Combine day('YYYY-MM-DD') + time('HH:MI')", ("text","date")),
]

def validate_day_choice(mode_key: str, day_col: str, col_types: Dict[str, str]) -> tuple[bool, str]:
    mode = next(m for m in DAY_MODES if m.key == mode_key)
    base_type = categorize_type(col_types[day_col])
    if base_type not in mode.compatible_types:
        return False, f"Column '{day_col}' is {base_type}; parser '{mode.label}' expects {', '.join(mode.compatible_types)}."
    return True, ""

def build_day_expr(mode: str, day_col: str, time_col: Optional[str], allowed: set[str]) -> str:
    d = safe_ident(day_col, allowed)
    t_expr = safe_ident(time_col, allowed) if time_col else None
    if mode == "iso_text_or_date":
        return f"date_trunc('day', {d}::timestamp)::date"
    if mode == "yyyymmdd_int":
        return f"date_trunc('day', to_timestamp({d}::text, 'YYYYMMDD'))::date"
    if mode == "yyyymmdd_text":
        return f"date_trunc('day', to_timestamp({d}, 'YYYYMMDD'))::date"
    if mode == "yyyy_mm_dd_text":
        return f"date_trunc('day', to_timestamp({d}, 'YYYY-MM-DD'))::date"
    if mode == "mmddyyyy_text":
        return f"date_trunc('day', to_timestamp({d}, 'MM/DD/YYYY'))::date"
    if mode == "epoch_seconds_int":
        return f"date_trunc('day', to_timestamp({d}))::date"
    if mode == "combine_day_time_iso":
        if not t_expr:
            raise ValueError("time_col required for combine_day_time_iso")
        return f"date_trunc('day', to_timestamp({d} || ' ' || {t_expr}, 'YYYY-MM-DD HH24:MI'))::date"
    return f"date_trunc('day', {d}::timestamp)::date"


# ------------------------
# Bit helpers (ACBP DSL indexes)
# ------------------------
def bit_expr(mask_col: str, idx: int) -> str:
    m = f'"{mask_col}"' if not mask_col.startswith('"') else mask_col
    return f"(({m} >> {idx}) & 1) = 1"

# Clinic: 0=booked,1=checked_in,2=seen_by_doctor,3=canceled,4=rescheduled
def clinic_exprs(mask_col: str) -> Dict[str, str]:
    b = bit_expr(mask_col, 0)
    ci = bit_expr(mask_col, 1)
    s  = bit_expr(mask_col, 2)
    c  = bit_expr(mask_col, 3)
    r  = bit_expr(mask_col, 4)
    noshow = f"({b}) AND NOT ({ci}) AND NOT ({c}) AND NOT ({r})"
    return {"booked": b, "checked_in": ci, "seen": s, "canceled": c, "rescheduled": r, "noshow": noshow}

# Inpatient: 0=booked,1=checked_in,2=in_icu,3=discharged,4=expired,5=transferred
def inpatient_exprs(mask_col: str) -> Dict[str, str]:
    return {"discharged": bit_expr(mask_col, 3)}


# ------------------------
# Ordering helpers for categorical groups
# ------------------------
def weekday_order_expr(col: str) -> str:
    c = f'"{col}"'
    return (
        f"array_position(ARRAY['Mon','Tue','Wed','Thu','Fri','Sat','Sun']::text[], {c}), {c}"
    )

def visit_hour_order_expr(col: str) -> str:
    # order lexically '00:00','04:00','08:00',...'20:00'
    c = f'"{col}"'
    return f"{c}"

def generic_order_expr(col: str) -> str:
    return f'"{col}"'


# ------------------------
# UI
# ------------------------
st.set_page_config(page_title="ACBP — Live Dashboard", layout="wide")
st.title("ACBP — Live Dashboard")
st.caption(f"DB: {DB_URL}")

# Actions
a1, a2 = st.columns([1, 3], gap="large")
with a1:
    if st.button("Refresh ACBP mats", use_container_width=True):
        with get_conn() as conn:
            try:
                with conn.cursor() as cur:
                    cur.execute("SELECT acbp_refresh_dashboard();")
                st.success("Refreshed mats.")
            except Exception:
                st.info("Helper function not found; skipped.")
with a2:
    st.code(
        "cat sql/020_dashboard_live_latency_sim.sql | docker exec -i acbp-pg psql -U postgres -d postgres\n"
        "streamlit run scripts/dashboard.py",
        language="bash",
    )

st.divider()

# ------------------------
# Latency (ACBP mats)
# ------------------------
st.header("Latency (ACBP mats)")

with get_conn() as conn:
    have_summary = to_regclass_exists(conn, "dashboard_summary_mat")
    have_daily   = to_regclass_exists(conn, "dashboard_daily_percentiles_mat")
    have_slo     = to_regclass_exists(conn, "dashboard_daily_slo_mat")
    have_raw     = to_regclass_exists(conn, "dashboard_runs_raw")

lat_cols = st.columns(4)
lat_cols[0].metric("summary_mat", "yes" if have_summary else "no")
lat_cols[1].metric("daily_percentiles_mat", "yes" if have_daily else "no")
lat_cols[2].metric("daily_slo_mat", "yes" if have_slo else "no")
lat_cols[3].metric("runs_raw", "yes" if have_raw else "no")

summary = daily = slo = raw = pd.DataFrame()
with get_conn() as conn:
    if have_summary:
        summary = try_fetch(conn, "dashboard_summary_mat", "SELECT * FROM dashboard_summary_mat ORDER BY model;")
    if have_daily:
        daily = try_fetch(conn, "dashboard_daily_percentiles_mat",
                          "SELECT * FROM dashboard_daily_percentiles_mat ORDER BY day, model;")
    if have_slo:
        slo = try_fetch(conn, "dashboard_daily_slo_mat",
                        "SELECT * FROM dashboard_daily_slo_mat ORDER BY day, model;")
    if have_raw:
        raw = try_fetch(conn, "dashboard_runs_raw (last 14d)", """
            SELECT ts::date AS day, model, duration_ms
            FROM dashboard_runs_raw
            WHERE ts >= now() - interval '14 days'
            ORDER BY ts DESC
            LIMIT 8000;""")

if not summary.empty:
    st.subheader("Overall latency (all data)")
    k1, k2, k3 = st.columns(3)
    for _, row in summary.iterrows():
        k1.metric(f"{row['model']} — P50", f"{row['p50_ms']:.0f} ms")
        k2.metric(f"{row['model']} — P95", f"{row['p95_ms']:.0f} ms")
        k3.metric(f"{row['model']} — samples", f"{int(row['n']):,}")

if not slo.empty:
    st.subheader("Daily SLO (≤ threshold) — one-sided 95% Wilson lower bound")
    slo_fmt = slo.copy()
    slo_fmt["pct_at_or_below_thr"] = slo_fmt["pct_at_or_below_thr"].map(lambda x: f"{x:.2f}%")
    slo_fmt["wilson_lower_pct"] = slo_fmt["wilson_lower_pct"].map(lambda x: f"{x:.2f}%")
    st.dataframe(slo_fmt, use_container_width=True, hide_index=True)

if not daily.empty:
    st.subheader("Daily P50 / P95 (ms)")
    # P50
    fig1, ax1 = plt.subplots()
    for model, sub in daily.groupby("model"):
        ax1.plot(pd.to_datetime(sub["day"]), sub["p50_ms"], label=f"{model} P50")
    ax1.set_title("Daily P50 (ms)")
    ax1.set_xlabel("Day")
    ax1.set_ylabel("ms")
    ax1.legend()
    st.pyplot(fig1)
    # P95
    fig2, ax2 = plt.subplots()
    for model, sub in daily.groupby("model"):
        ax2.plot(pd.to_datetime(sub["day"]), sub["p95_ms"], label=f"{model} P95")
    ax2.set_title("Daily P95 (ms)")
    ax2.set_xlabel("Day")
    ax2.set_ylabel("ms")
    ax2.legend()
    st.pyplot(fig2)

if not raw.empty:
    st.subheader("Duration distribution (last 14 days)")
    for model, sub in raw.groupby("model"):
        figH, axH = plt.subplots()
        axH.hist(sub["duration_ms"], bins=40)
        axH.set_title(f"{model} — duration histogram (ms)")
        axH.set_xlabel("ms")
        axH.set_ylabel("count")
        st.pyplot(figH)

if not summary.empty:
    st.subheader("Export")
    buf = io.StringIO()
    summary.to_csv(buf, index=False)
    st.download_button("Download summary.csv", data=buf.getvalue(), file_name="summary.csv", mime="text/csv")

st.divider()

# ------------------------
# Business KPIs (from your tables)
# ------------------------
st.header("Business KPIs — from your data")

with get_conn() as conn:
    tables = list_tables(conn, schemas=("public",))

defaults = {
    "clinic": "public.clinic_visit_data" if "public.clinic_visit_data" in tables else "",
    "inpat":  "public.inpatient_admission_data" if "public.inpatient_admission_data" in tables else "",
}

pick_cols = st.columns(2)
with pick_cols[0]:
    clinic_tbl = st.selectbox("Clinic table", options=[""] + tables,
                              index=(tables.index(defaults["clinic"]) + 1 if defaults["clinic"] in tables else 0))
with pick_cols[1]:
    inpat_tbl = st.selectbox("Inpatient table", options=[""] + tables,
                             index=(tables.index(defaults["inpat"]) + 1 if defaults["inpat"] in tables else 0))

# --- Common helpers for KPI sections ---
def resolve_columns(table_name: str) -> tuple[list[str], dict[str,str], set[str]]:
    with get_conn() as conn:
        cols_t = list_columns_with_types(conn, table_name)
    cols = [c for c,_ in cols_t]
    types = {c:t for c,t in cols_t}
    allowed = set(cols)
    return cols, types, allowed

def guess_mask_col(cols: list[str]) -> str:
    # prefer standard 'mask'
    if "mask" in cols:
        return "mask"
    # next: bitmask, flags, etc.
    for c in cols:
        if c.lower() in {"bitmask","flags","flag_bits"}:
            return c
    # fallback to first integer-like name (unsafe but a last resort)
    return "mask"

def order_expr_for_group(col: str) -> str:
    c = col.lower()
    if c == "weekday":
        return weekday_order_expr(col)
    if c == "visit_hour" or c == "admit_hour":
        return visit_hour_order_expr(col)
    return generic_order_expr(col)

# --- Clinic KPIs ---
def render_clinic_block():
    st.subheader("Clinic KPIs")
    if not clinic_tbl:
        st.info("Pick a Clinic table.")
        return

    cols, types, allowed = resolve_columns(clinic_tbl)

    # UI: mode choice
    mode = st.radio(
        "Grouping mode (Clinic)",
        options=["Categorical (weekday / visit_hour / site / department)", "Calendar (parse a day/date)"],
        index=0,
        horizontal=False,
    )

    # Which column holds the mask?
    mask_col = st.selectbox("Mask column", options=[c for c in cols if c in {"mask"}] or cols, index=(cols.index("mask") if "mask" in cols else 0))

    # Derived status from bits
    cexp = clinic_exprs(mask_col)
    booked_expr = cexp["booked"]
    seen_expr   = cexp["seen"]
    noshow_expr = cexp["noshow"]

    if mode.startswith("Categorical"):
        # Choose a categorical column to group by (prefer weekday)
        text_groups = guess_text_group_candidates([(c, types[c]) for c in cols])
        default_idx = (text_groups.index("weekday") if "weekday" in text_groups else 0) if text_groups else 0
        grp_col = st.selectbox("Group by (categorical)", options=text_groups or cols, index=default_idx)

        g = safe_ident(grp_col, allowed)
        order_by = order_expr_for_group(grp_col)

        booked_sql = f"""
            SELECT {g} AS grp,
                   COUNT(*) FILTER (WHERE {booked_expr}) AS booked_count
            FROM {clinic_tbl}
            GROUP BY 1
            ORDER BY {order_by};
        """

        noshow_sql = f"""
            WITH base AS (
              SELECT {g} AS grp,
                     COUNT(*) FILTER (WHERE {noshow_expr}) AS noshows,
                     COUNT(*) FILTER (WHERE ({seen_expr}) OR ({noshow_expr})) AS completed_plus_ns
              FROM {clinic_tbl}
              GROUP BY 1
            )
            SELECT grp, noshows, completed_plus_ns,
                   CASE WHEN completed_plus_ns=0 THEN 0
                        ELSE ROUND(100.0 * noshows::numeric / completed_plus_ns, 2) END AS no_show_rate_pct
            FROM base
            ORDER BY {order_by};
        """

        with get_conn() as conn:
            kpi_booked = try_fetch(conn, "clinic_booked_by_group", booked_sql)
            kpi_noshow = try_fetch(conn, "clinic_noshow_rate_by_group", noshow_sql)

        if not kpi_booked.empty:
            fig, ax = plt.subplots()
            ax.plot(kpi_booked["grp"], kpi_booked["booked_count"])
            ax.set_title(f"Clinic — Booked per {grp_col}")
            ax.set_xlabel(grp_col)
            ax.set_ylabel("count")
            plt.xticks(rotation=45, ha="right")
            st.pyplot(fig)

        if not kpi_noshow.empty:
            fig, ax = plt.subplots()
            ax.plot(kpi_noshow["grp"], kpi_noshow["no_show_rate_pct"])
            ax.set_title(f"Clinic — No-show rate (%) per {grp_col}")
            ax.set_xlabel(grp_col)
            ax.set_ylabel("%")
            plt.xticks(rotation=45, ha="right")
            st.pyplot(fig)

    else:
        # Calendar mode (same idea as before)
        day_opts = guess_day_candidates([(c, types[c]) for c in cols])
        time_opts = guess_time_candidates([(c, types[c]) for c in cols])

        m1, m2 = st.columns(2)
        with m1:
            mode_key = st.selectbox("Clinic day parsing",
                                    options=[m.key for m in DAY_MODES],
                                    format_func=lambda k: next(m.label for m in DAY_MODES if m.key == k),
                                    index=0)
            day_col = st.selectbox("Clinic 'day' column", options=day_opts or cols, index=0)
        with m2:
            time_col = None
            if mode_key == "combine_day_time_iso":
                time_col = st.selectbox("Clinic 'time' column", options=time_opts or cols, index=0)

        ok, msg = validate_day_choice(mode_key, day_col, types)
        if not ok:
            st.warning(f"Fix selection: {msg}")
            with get_conn() as conn:
                prev = try_fetch(conn, "preview (first 10)", f'SELECT "{day_col}" AS chosen_day, * FROM {clinic_tbl} LIMIT 10;')
            if not prev.empty:
                st.dataframe(prev, use_container_width=True)
            return

        try:
            day_expr = build_day_expr(mode_key, day_col, time_col, allowed)
        except Exception as e:
            st.error("Invalid date/time selection.")
            st.exception(e)
            return

        with get_conn() as conn:
            prev = try_fetch(conn, "preview day parse", f"SELECT {day_expr} AS day, COUNT(*) c FROM {clinic_tbl} GROUP BY 1 ORDER BY 1 DESC LIMIT 10;")
            if not prev.empty:
                st.caption("Sample parsed days (top 10):")
                st.dataframe(prev, use_container_width=True, hide_index=True)

        booked_sql = f"""
            SELECT {day_expr} AS day,
                   COUNT(*) FILTER (WHERE {booked_expr}) AS booked_count
            FROM {clinic_tbl}
            GROUP BY 1
            ORDER BY 1;
        """

        noshow_sql = f"""
            WITH base AS (
              SELECT {day_expr} AS day,
                     COUNT(*) FILTER (WHERE {noshow_expr}) AS noshows,
                     COUNT(*) FILTER (WHERE ({seen_expr}) OR ({noshow_expr})) AS completed_plus_ns
              FROM {clinic_tbl}
              GROUP BY 1
            )
            SELECT day, noshows, completed_plus_ns,
                   CASE WHEN completed_plus_ns=0 THEN 0
                        ELSE ROUND(100.0 * noshows::numeric / completed_plus_ns, 2) END AS no_show_rate_pct
            FROM base
            ORDER BY 1;
        """

        with get_conn() as conn:
            kpi_booked = try_fetch(conn, "kpi_booked_daily", booked_sql)
            kpi_noshow = try_fetch(conn, "kpi_no_show_rate_daily", noshow_sql)

        if not kpi_booked.empty:
            fig, ax = plt.subplots()
            ax.plot(pd.to_datetime(kpi_booked["day"]), kpi_booked["booked_count"])
            ax.set_title("Clinic — Booked per day")
            ax.set_xlabel("Day")
            ax.set_ylabel("count")
            st.pyplot(fig)
        if not kpi_noshow.empty:
            fig, ax = plt.subplots()
            ax.plot(pd.to_datetime(kpi_noshow["day"]), kpi_noshow["no_show_rate_pct"])
            ax.set_title("Clinic — No-show rate (%) per day")
            ax.set_xlabel("Day")
            ax.set_ylabel("%")
            st.pyplot(fig)

# --- Inpatient KPIs ---
def render_inpatient_block():
    st.subheader("Inpatient KPIs")
    if not inpat_tbl:
        st.info("Pick an Inpatient table.")
        return

    cols, types, allowed = resolve_columns(inpat_tbl)

    mode = st.radio(
        "Grouping mode (Inpatient)",
        options=["Categorical (weekday / admit_hour / site / ward / admission_type)", "Calendar (parse a day/date)"],
        index=0,
        horizontal=False,
    )

    mask_col = st.selectbox("Mask column (inpatient)", options=[c for c in cols if c in {"mask"}] or cols, index=(cols.index("mask") if "mask" in cols else 0))
    iexp = inpatient_exprs(mask_col)
    discharged_expr = iexp["discharged"]

    if mode.startswith("Categorical"):
        text_groups = guess_text_group_candidates([(c, types[c]) for c in cols])
        # prefer weekday or admit_hour if available
        default = "weekday" if "weekday" in text_groups else ("admit_hour" if "admit_hour" in text_groups else (text_groups[0] if text_groups else cols[0]))
        grp_col = st.selectbox("Group by (categorical)", options=text_groups or cols, index=(text_groups.index(default) if default in (text_groups or []) else 0))

        g = safe_ident(grp_col, allowed)
        order_by = order_expr_for_group(grp_col)

        dis_sql = f"""
            SELECT {g} AS grp,
                   COUNT(*) FILTER (WHERE {discharged_expr}) AS discharge_count
            FROM {inpat_tbl}
            GROUP BY 1
            ORDER BY {order_by};
        """

        with get_conn() as conn:
            kpi_disch = try_fetch(conn, "inpatient_discharges_by_group", dis_sql)

        if not kpi_disch.empty:
            fig, ax = plt.subplots()
            ax.plot(kpi_disch["grp"], kpi_disch["discharge_count"])
            ax.set_title(f"Inpatient — Discharges per {grp_col}")
            ax.set_xlabel(grp_col)
            ax.set_ylabel("count")
            plt.xticks(rotation=45, ha="right")
            st.pyplot(fig)

    else:
        day_opts = guess_day_candidates([(c, types[c]) for c in cols])
        time_opts = guess_time_candidates([(c, types[c]) for c in cols])

        m1, m2 = st.columns(2)
        with m1:
            mode_key = st.selectbox("Inpatient day parsing",
                                    options=[m.key for m in DAY_MODES],
                                    format_func=lambda k: next(m.label for m in DAY_MODES if m.key == k),
                                    index=0)
            day_col = st.selectbox("Inpatient 'day' column", options=day_opts or cols, index=0)
        with m2:
            time_col = None
            if mode_key == "combine_day_time_iso":
                time_col = st.selectbox("Inpatient 'time' column", options=time_opts or cols, index=0)

        ok, msg = validate_day_choice(mode_key, day_col, types)
        if not ok:
            st.warning(f"Fix selection: {msg}")
            with get_conn() as conn:
                prev = try_fetch(conn, "preview (first 10)", f'SELECT "{day_col}" AS chosen_day, * FROM {inpat_tbl} LIMIT 10;')
            if not prev.empty:
                st.dataframe(prev, use_container_width=True)
            return

        try:
            day_expr = build_day_expr(mode_key, day_col, time_col, allowed)
        except Exception as e:
            st.error("Invalid date/time selection.")
            st.exception(e)
            return

        with get_conn() as conn:
            prev = try_fetch(conn, "preview day parse", f"SELECT {day_expr} AS day, COUNT(*) c FROM {inpat_tbl} GROUP BY 1 ORDER BY 1 DESC LIMIT 10;")
            if not prev.empty:
                st.caption("Sample parsed days (top 10):")
                st.dataframe(prev, use_container_width=True, hide_index=True)

        dis_sql = f"""
            SELECT {day_expr} AS day,
                   COUNT(*) FILTER (WHERE {discharged_expr}) AS discharge_count
            FROM {inpat_tbl}
            GROUP BY 1
            ORDER BY 1;
        """
        with get_conn() as conn:
            kpi_disch = try_fetch(conn, "kpi_discharges_daily", dis_sql)

        if not kpi_disch.empty:
            fig, ax = plt.subplots()
            ax.plot(pd.to_datetime(kpi_disch["day"]), kpi_disch["discharge_count"])
            ax.set_title("Inpatient — Discharges per day")
            ax.set_xlabel("Day")
            ax.set_ylabel("count")
            st.pyplot(fig)

# Render KPI blocks side-by-side
c1, c2 = st.columns(2)
with c1:
    render_clinic_block()
with c2:
    render_inpatient_block()

st.caption(
    "Notes: P50/P95 are latency percentiles (not p-values). "
    "If you don't have a calendar column, use 'Categorical' grouping (e.g., weekday / visit_hour). "
    "Clinic noshow is derived: booked=1 AND NOT(checked_in OR canceled OR rescheduled). "
    "Bit indexes follow your DSL flag order."
)
