VENV := .venv/bin
PYTHON ?= python3.11

.PHONY: setup db test run e2e clean

setup:         ## create the Python environment and install dependencies
	@test -x $(VENV)/python || $(PYTHON) -m venv .venv
	$(VENV)/python -m pip install -r requirements.txt

db:            ## start Postgres and wait for it to accept connections
	docker compose up -d
	@until docker compose exec -T db pg_isready -U genesis -d findings >/dev/null 2>&1; do sleep 1; done
	@docker compose exec -T db psql -U genesis -d findings -c \
		"SELECT 'findings_test' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname='findings_test')\gexec" >/dev/null 2>&1 || true
	@docker compose exec -T db createdb -U genesis findings_test 2>/dev/null || true
	@echo "postgres ready on :55432 (findings, findings_test)"

test: db
	$(VENV)/pytest -q

run: db
	$(VENV)/uvicorn app.main:app --reload --port 8000

e2e:           ## run the scanner walkthrough against an already-running service
	$(VENV)/python demo/e2e.py

clean:
	docker compose down -v
