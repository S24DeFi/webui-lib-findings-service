# AWS infrastructure (Terraform)

Private learning deployment of the findings service on AWS, tracked in
[issue #15](https://github.com/adswebwork/webui-lib-findings-service/issues/15). Nothing here
has been applied yet. Provisioning, and separately any public exposure, need explicit owner
authorization (see [AI permissions](../docs/AI_PERMISSIONS.md)).

## What it builds

```
                        internet
                            |
                  (only if public = true, TLS required)
                            |
   VPC 10.40.0.0/16 --------+-------------------------------------------------
   | public subnets      [ ALB ]  :443 -> :8000                                |
   |                        |                                                  |
   | private subnets   [ ECS Fargate task: FastAPI ] --443--> VPC endpoints    |
   | (no internet route)    |                         ecr.api, ecr.dkr, logs,  |
   |                        |                         secretsmanager,          |
   |                        |                         bedrock-runtime, S3 (gw) |
   |                      5432                                                 |
   | database subnets  [ RDS PostgreSQL 16 ]  encrypted, force_ssl, no route out|
   ---------------------------------------------------------------------------
```

| Layer | Resource | Why this way |
|---|---|---|
| Network | 3 tiers × 2 AZs, no NAT gateway | Private tasks can reach only listed AWS services through endpoints; no general internet egress |
| Network | Security groups chained by reference (ALB → tasks → DB) | Rules name the caller, not an IP range, so scaling tasks changes nothing |
| Network | VPC flow logs (ALL) | `REJECT` records answer "why can't X reach Y" with evidence |
| Compute | ECS Fargate behind an ALB, health check `/healthz` (runs `SELECT 1`) | FastAPI and the asyncpg pool run unchanged; see decision 11 |
| Compute | Deployment circuit breaker with rollback | A release that never passes health checks reverts itself |
| Data | RDS PostgreSQL 16, `manage_master_user_password` | Password generated and held by Secrets Manager; never in code, plan output or state |
| Secrets | ECS injects `username`/`password` JSON keys at task start | `app/config.py` assembles the URL with escaping |
| Images | ECR, immutable tags, scan on push | A tag always means one image; rollback = redeploy an older SHA |
| CI auth | GitHub OIDC → read-only plan role / scoped apply role | No stored AWS keys; a PR can never obtain write credentials |
| State | S3, versioned, encrypted, TLS-only, `use_lockfile` | S3-native locking (Terraform 1.10+); no DynamoDB table |

Layout:

```
infra/
  bootstrap/        one-time: state bucket, GitHub OIDC provider, CI roles (local state)
  modules/network   VPC, subnets, routes, endpoints, flow logs
  modules/database  RDS, subnet group, parameter group, security group
  modules/service   ECR, ECS cluster/service/task, ALB, IAM roles, log group
  envs/dev          composes the modules; one directory per environment
```

## Cost (estimate, us-east-1, while running)

Verify with the [AWS Pricing Calculator](https://calculator.aws/) before applying; prices change.

| Item | Approx. |
|---|---|
| 5 interface endpoints × 2 AZs | ~$2.40/day |
| Application Load Balancer | ~$0.55/day + usage |
| RDS db.t4g.micro + 20 GB gp3 | ~$0.40/day + ~$2.30/month |
| Fargate 0.25 vCPU / 0.5 GB, 1 task | ~$0.30/day |
| CloudWatch logs, ECR storage | cents at this volume |
| **Total** | **~$3.50–4/day (~$110/month if left running); $0 after teardown** |

The endpoints are the largest line. Dropping to `az_count = 2` is already the minimum (RDS
needs two AZs); removing `bedrock-runtime` from `interface_endpoints` saves ~$0.48/day until
the Bedrock feature lands. Set an AWS Budget alert before the first apply.

## Prerequisites

- Terraform >= 1.10, AWS CLI v2, Docker
- An AWS account you control, with admin credentials for the one-time bootstrap only
- `aws sts get-caller-identity` confirms you are in the intended account

## First-time setup

```bash
# 1. Bootstrap (local state; keep infra/bootstrap/terraform.tfstate safe and out of git)
cd infra/bootstrap
terraform init
terraform apply          # review: 1 bucket, 1 OIDC provider, 2 roles

# 2. Repository settings, from the bootstrap outputs
#    Variables:  AWS_PLAN_ROLE_ARN, TF_STATE_BUCKET, AWS_REGION
#    Environment "dev" with required reviewer(s); variable AWS_APPLY_ROLE_ARN
#    PRs touching infra/ will now show a plan in the job summary.

# 3. Environment backend
cd ../envs/dev
cp backend.hcl.example backend.hcl            # fill in the bucket name
cp terraform.tfvars.example terraform.tfvars
terraform init -backend-config=backend.hcl
```

Commit `.terraform.lock.hcl` once it is generated against the public registry for every
platform that runs Terraform:
`terraform providers lock -platform=linux_amd64 -platform=darwin_arm64`.

## Deploy (manual until the deploy workflow lands)

The ECR repository is created by Terraform, so the first apply is two steps.

```bash
cd infra/envs/dev
SHA=$(git rev-parse --short=12 HEAD)

# 1. Create everything; the service starts failing health checks until an image exists
terraform apply -var "image_tag=$SHA"

# 2. Build and push, then let ECS pick it up
REPO=$(terraform output -raw repository_url)
aws ecr get-login-password | docker login --username AWS --password-stdin "${REPO%%/*}"
docker build -t "$REPO:$SHA" ../../..
docker push "$REPO:$SHA"
aws ecs update-service --cluster "$(terraform output -raw cluster_name)" \
  --service "$(terraform output -raw service_name)" --force-new-deployment
```

The ALB is internal, so reach it from inside the VPC (ECS Exec, after adding `ssmmessages`
to the endpoints and `enable_execute_command = true`) until auth and public exposure ship.

## Verify

- `aws logs tail "$(terraform output -raw log_group_name)" --follow` shows migrations
  applied and uvicorn started.
- Target group health is `healthy`; `/healthz` returns `{"status":"ok","database":"ok"}`.
- Database not reachable from outside: RDS `publicly_accessible = false`, database subnets
  have no route out, and its security group admits only the task group.
- Run the report lifecycle checks from issue #15 (replay, conflict, stale, partial/failed)
  with synthetic fixtures only.

## Teardown

```bash
cd infra/envs/dev && terraform destroy -var "image_tag=unused"
```

`skip_final_snapshot = true` and `deletion_protection = false` by default so this completes
unattended; both are wrong for real data. Bootstrap is cheap to leave (an empty-ish bucket
and IAM), or destroy it last after emptying the bucket.

## Known gaps (deliberate, tracked)

- **No authentication yet**, so the ALB stays internal. Next: Cognito JWT verification in
  FastAPI (`reports:write` for producers, `findings:read` for the dashboard), WAF, ACM.
- **App connects as the RDS master user.** Next: a least-privilege `findings_app` role,
  ideally with IAM database authentication (already enabled on the instance).
- **Secret rotation**: RDS rotates the managed secret (7 days by default), but ECS reads it
  only at task start. After a rotation, new connections fail until the service is
  redeployed. Fix with IAM auth tokens or fetching the secret at connect time.
- **TLS to RDS** is enforced server-side (`rds.force_ssl`), but the client does not yet
  verify the RDS CA certificate.
- **No deploy workflow yet**: CI plans; applies are manual. Next: build → push → apply in
  the protected `dev` environment with the apply role.
- Customer-managed KMS keys, ALB access logs and long log retention are skipped for cost;
  each skip is annotated inline where checkov would flag it.

## Mapping to the AWS / platform topics this exercises

| Topic | Where |
|---|---|
| VPC design, subnets, route tables, IGW, endpoints | `modules/network` |
| Security groups vs. NACLs, least-privilege egress | `modules/service`, `modules/database` |
| IAM: execution vs. task roles, OIDC federation, scoped CI roles | `modules/service`, `bootstrap` |
| Secrets Manager, RDS-managed credentials | `modules/database`, `app/config.py` |
| ECS Fargate, ALB target groups, health checks, rollbacks | `modules/service` |
| Terraform: modules, remote state and locking, preconditions, validation | everywhere |
| Policy as code: checkov with reviewed inline exceptions; tflint | `.github/workflows/terraform.yml` |
