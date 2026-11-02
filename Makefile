VENV := .venv/bin

.PHONY: setup db test run e2e fmt clean

setup:         ## create .venv (Python 3.11) and install dependencies; reuses an existing .venv
	test -x $(VENV)/python || python3.11 -m venv .venv
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

e2e: db        ## real-scanner walkthrough; needs the API running (make run) and a11y-audit (A11Y_SCAN)
	$(VENV)/python demo/e2e.py

clean:
	docker compose down -v
