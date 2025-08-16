# test_db_connect.py
from sqlalchemy import create_engine, text

url = "postgresql+psycopg2://postgres:acbp@127.0.0.1:5434/postgres?sslmode=disable"
engine = create_engine(url, pool_pre_ping=True, pool_recycle=1800, future=True)

with engine.begin() as con:
    rows = con.execute(text("SELECT current_user, inet_client_addr();")).all()
    print(rows)
