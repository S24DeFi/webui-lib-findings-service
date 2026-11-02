# Findings service: understanding, operation and AWS roadmap

Owner: Andre. Planning baseline: November 2, 2026.
Repository: https://github.com/S24DeFi/webui-lib-findings-service
AWS implementation tracking: [issue #15](https://github.com/S24DeFi/webui-lib-findings-service/issues/15),
which holds the phase checklist and the owner's hosting decisions. This roadmap
summarizes it for learning purposes; if they disagree, the issue and the decision
log win.

## Purpose and intended users

This is a website issue-tracking service. It receives automated checker reports,
remembers recurring problems and shows developers what still needs fixing. It does
not scan websites or repair website code itself.

Potential users include developers, QA engineers, accessibility specialists and
website audit teams. The repository demonstrates a personal project and portfolio
tool; it does not establish external customer adoption or production use.

A typical workflow is to run a separate scanner after a website change, translate
its results, submit a report and inspect the dashboard. The implemented adapter
supports accessibility results from the external a11y-audit scanner. Automated
accessibility results do not establish WCAG or legal compliance.

## How it works

| Component | Responsibility | Source |
| --- | --- | --- |
| External scanner | Inspect a webpage using Playwright and axe-core | a11y-audit; installed separately |
| Adapter | Translate scanner JSON into v2 reports | `tools/a11y_adapter.py` |
| FastAPI application | Validate reports and expose the API | `app/main.py`, `app/api_v2.py` |
| Processing rules | Identify issues and apply eligible reports | `app/ingest_v2.py`, `app/schemas_v2.py` |
| PostgreSQL | Persist reports, scopes and issue state | `app/models.py`, `migrations/` |
| Read-only dashboard | Filter and inspect findings and evidence | `app/static/dashboard.html` |

For example, a scan finds missing image alternative text and an unlabeled input on
a checkout page. Both become open issues. A new scan finding the same problems
updates those issues. A complete, newer scan after the image is fixed resolves
that issue. If it returns later, the same issue reopens.

Rules to be able to explain:

- Replaying the same project/report ID with the same content changes nothing;
  reusing it with different content returns a conflict. This is idempotency.
- A fresh scan has a new report ID and can count as another observation.
- Only a complete report newer than the last applied complete report can resolve
  issues, and only for its exact project/source/category/page/ruleset scope.
- Failed, partial and stale reports cannot falsely resolve issues.
- Description and severity changes update an issue; they do not create its identity.
- PostgreSQL constraints and scope row locks protect retries and concurrent writes.

## Current baseline and gaps

The API, PostgreSQL schema/migrations, adapter, dashboard, demo fixtures and test
suite are implemented. GitHub Actions defines PostgreSQL tests and an image build.
This describes available code, not a claim that the latest checks have passed.

The Makefile now has `setup` and `e2e` targets, matching the README. `make setup` was
run twice in a Linux cloud container (2026-11-02); `make e2e` has not been run.
Docker Compose starts only PostgreSQL; the API runs separately on the host.
Starting the database does not start the dashboard or run the tests successfully.

There is no authentication or project authorization. Keep the current service on
localhost. Dashboard-triggered scans, manual issue resolution, transition history,
trend metrics and distributed rate limiting remain deferred. Preserve legacy v1
compatibility while using v2 for new integrations.

## Milestone 1: operate and explain it locally

Goal: understand a full report lifecycle before adding cloud infrastructure.

- [ ] Confirm Python 3.11 and a running Docker daemon on the computer being used.
- [ ] Confirm `make setup` works on the computer being used (the targets are committed).
- [ ] Install dependencies, verify the disposable test database, and run `make test`.
- [ ] Run the API and confirm health, API documentation and dashboard access.
- [ ] Submit the synthetic fixture twice; explain why the retry creates no duplicates.
- [ ] Inspect the relevant route, adapter and processing code while tracing one report.
- [ ] Record actual results and failures, including the computer/environment tested.

From the repository root:

```bash
make setup
make test
make run
```

`make setup` creates `.venv` only if it is missing; override the interpreter with
`make setup PYTHON=python3.11`.

Reuse an existing working Python 3.11 environment rather than recreating it.
The tests delete rows: verify the target is the project's disposable local
`findings_test` database before running them. Never point the suite at production.
`make run` stays active in that terminal; stop the API with Ctrl+C.

Open:

- Dashboard: http://127.0.0.1:8000/dashboard
- Interactive API documentation: http://127.0.0.1:8000/docs
- Health check: http://127.0.0.1:8000/healthz

In a second terminal in the repository root:

```bash
.venv/bin/python -m tools.a11y_adapter \
  demo/fixtures/scan-broken.json \
  --project learning-demo \
  --api http://127.0.0.1:8000
```

Open `/dashboard?project=learning-demo`. For a new project the fixture creates two
issues. Repeat the exact command: expect a replay and unchanged observation counts.
The adapter derives each `report_id` from the project, the scan's `generated` time and
the page URL, so re-running the same file replays the same report. This uses existing
synthetic scanner output; it does not run a real scan.

Troubleshooting:

| Symptom | Meaning and next check |
| --- | --- |
| No rule to make target `setup` | Checkout predates the targets; update from `main` |
| Docker socket missing | Docker engine is unavailable to that terminal; start Docker and check `docker info` |
| `.venv/bin/pytest` missing | Create the Python environment and install requirements |
| Database started but dashboard unavailable | Start `make run`; check its terminal output |
| Project absent from dashboard | Submit a report with that project name |

Do not use `make clean` as routine shutdown: it invokes `docker compose down -v`.
For ordinary database shutdown use `docker compose stop`; preserve data unless
deletion is explicitly intended and authorized.

## Milestone 2: demonstrate the lifecycle with a local scanner

- [ ] Install Node and the external a11y-audit scanner dependencies.
- [ ] Set `A11Y_SCAN` if automatic scanner discovery does not find `scan.mjs`.
- [ ] With the API running (`make run`), execute `make e2e`.
- [ ] Observe new issues, retry, fix, reopen, stale delivery, failed scan and recovery.
- [ ] Explain the distinction between open issue state and latest scan health.

Use the included local demo pages. Real-site scans require separate target
authorization. Completion means observed assertions and a recorded result, not
merely installing the scanner or reading the walkthrough.

## Milestone 3: design the AWS transfer

Tracked in [issue #15](https://github.com/S24DeFi/webui-lib-findings-service/issues/15)
(phases 0-1). Decisions recorded there on 2026-11-02:

- Hosting: ECS Fargate behind an ALB with RDS PostgreSQL 16. Lambda/API Gateway was
  rejected for the first path because the connection pool, row locks and startup
  migrations suit a long-running container. Decision 11 in `docs/DECISIONS.md` is
  tracked on the scaffold branch, not yet on `main`.
- Infrastructure as code: Terraform under `infra/`, S3 remote state.
- Region: us-east-1. Access: Cognito JWT before any public listener.

Remaining work:

- [ ] Owner review of the resource inventory, estimated recurring cost, budget alert,
  retention, backup/restore, rollback and teardown plan.
- [ ] Explain the Fargate-versus-Lambda tradeoff in your own words.
- [ ] Obtain separate owner authorization before paid provisioning or deployment.

No existing production migration is assumed. Start with synthetic data and preserve
the local workflow. Never deploy the local demonstration credentials or expose the
current unauthenticated API unchanged. The `Dockerfile` starts uvicorn on `0.0.0.0`,
so any container run must publish its port on loopback or behind a protected load
balancer only.

## Milestone 4: deploy and operate an authorized learning environment

Requires separate authorization; issue #15 phases 2-5.

- [ ] Apply the bootstrap and `envs/dev` stacks with synthetic data only.
- [ ] Add CI/CD using scoped deployment identity (GitHub OIDC, no stored AWS keys).
- [ ] Add Cognito authentication and project authorization before public exposure.
- [ ] Verify migrations and demonstrate an application rollback and database restore.
- [ ] Add request logs, health monitoring, metrics, alerts and bounded retention.
- [ ] Verify retries, conflicts, concurrency, scope isolation and failed/partial/stale handling.
- [ ] Demonstrate that unauthenticated requests are denied and database access is private.
- [ ] Optional: Bedrock remediation guidance that never changes issue state, then an
  AgentCore stretch (issue #15 phase 4).
- [ ] Record actual cost, teardown steps and evidence from the deployed environment.

## Milestone 5: connect the work to AWS Developer learning

The immediate certification target is AWS Certified Developer – Associate.
Solutions Architect – Associate and Generative AI Developer – Professional are
possible later paths, not prerequisites for this project. Existing Hugging Face
fine-tuning, MCP and AI agents coursework, plus Anthropic AI fluency coursework,
provide AI context; this project adds hands-on backend and deployment evidence.

| Project work | Learning topic | Evidence to retain |
| --- | --- | --- |
| Deploy the service | Packaging and deployment configuration | Repeatable deployment and architecture explanation |
| Connect PostgreSQL | Connectivity, secrets and access controls | Working connection and denied unauthorized access |
| Replay scanner reports | Idempotency and retry handling | Original/replayed responses and unchanged issue counts |
| Configure logs and health | Observability and debugging | Diagnosis and recovery from a controlled failure |
| Build delivery automation | CI/CD and scoped deployment identity | Verified pipeline and rollback |
| Review resources | Cost awareness and lifecycle management | Cost record and verified teardown |

Use the current official AWS exam guide to identify topics this project does not
cover; a successful deployment alone does not establish exam readiness.

## Ownership and completion evidence

Andre should be able to demonstrate the workflow, locate the responsible code,
explain one design tradeoff, diagnose a failure and make a small verified change.
AI assistance can support each step; understanding is demonstrated by operating
and explaining the system, not by claiming to have manually authored every line.

Suggested project description:

> A FastAPI and PostgreSQL service that tracks website scanner findings across
> repeated checks, prevents duplicate report effects, tracks fixes and regressions,
> and protects issue state from failed or outdated scans.

Record evidence beside each completed milestone: date, environment, command or
workflow, result, and limitations. Leave unchecked items pending until verified.
See [context](CONTEXT.md), [decisions](DECISIONS.md) and
[AI permissions](AI_PERMISSIONS.md) for existing behavior and operating boundaries.
