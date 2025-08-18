PG_CONTAINER ?= acbp-pg
PGUSER ?= postgres
PGDB   ?= postgres

.PHONY: verify-theorems
verify-theorems:
\tcat sql/verify_theorems_public_auto.sql | docker exec -i $(PG_CONTAINER) psql -v ON_ERROR_STOP=1 -U $(PGUSER) -d $(PGDB)
