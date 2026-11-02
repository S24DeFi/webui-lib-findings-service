# The FastAPI container on ECS Fargate behind an Application Load Balancer.
#
# The service applies migrations at startup (app/migrate.py), and those are
# advisory-locked, so a rolling deployment with two tasks briefly overlapping cannot
# apply the same migration twice.
#
# The load balancer is internal by default. The app has no authentication yet
# (docs/DECISIONS.md, "Deferred"), so a public listener is refused unless TLS is
# configured, and exposing it is still a separate owner decision -- see infra/README.md.

data "aws_region" "current" {}

locals {
  container_name = "api"
  container_port = 8000
  https          = var.certificate_arn != ""
}

# --- Image registry ----------------------------------------------------------------

resource "aws_ecr_repository" "this" {
  #checkov:skip=CKV_AWS_136:AES256 encryption is enabled; a customer-managed KMS key is a production-account control.
  name                 = var.name
  image_tag_mutability = "IMMUTABLE" # a tag always means the same image; rollback = redeploy an old tag
  force_delete         = var.force_delete_images

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the 10 most recent images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

# --- Logs and cluster --------------------------------------------------------------

resource "aws_cloudwatch_log_group" "this" {
  #checkov:skip=CKV_AWS_158:Log groups are encrypted with AWS-managed keys; a customer-managed key is a production-account control.
  #checkov:skip=CKV_AWS_338:Retention is variable-controlled and short by default; synthetic data only.
  name              = "/ecs/${var.name}"
  retention_in_days = var.log_retention_days
}

resource "aws_ecs_cluster" "this" {
  name = var.name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

# --- IAM ---------------------------------------------------------------------------
# Two roles with different jobs. The execution role is used by ECS itself to pull the
# image, write logs and read the database secret before the container starts. The task
# role is what the application code runs as; it starts with no permissions.

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${var.name}-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "read_db_secret" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.database_secret_arn]
  }
}

resource "aws_iam_role_policy" "execution_db_secret" {
  name   = "read-db-secret"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.read_db_secret.json
}

resource "aws_iam_role" "task" {
  name               = "${var.name}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

# ECS Exec: a shell inside a private task without SSH, a bastion or a public IP.
# Sessions are authorised by IAM and recorded by Systems Manager. Note that the
# ssmmessages endpoint must then be added to the network module's interface endpoints.
data "aws_iam_policy_document" "ecs_exec" {
  statement {
    actions = [
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"] # these actions do not support resource-level permissions
  }
}

resource "aws_iam_role_policy" "task_ecs_exec" {
  count = var.enable_execute_command ? 1 : 0

  name   = "ecs-exec"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.ecs_exec.json
}

# --- Security groups ---------------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "${var.name}-alb"
  description = "Load balancer listeners"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "alb_listener" {
  for_each = toset(var.allowed_cidrs)

  security_group_id = aws_security_group.alb.id
  description       = "Listener traffic from an allowed range"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = local.https ? 443 : 80
  to_port           = local.https ? 443 : 80
}

resource "aws_vpc_security_group_ingress_rule" "alb_redirect" {
  for_each = local.https ? toset(var.allowed_cidrs) : toset([])

  security_group_id = aws_security_group.alb.id
  description       = "HTTP, redirected to HTTPS"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_egress_rule" "alb_to_tasks" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Forward to the application tasks"
  referenced_security_group_id = aws_security_group.tasks.id
  ip_protocol                  = "tcp"
  from_port                    = local.container_port
  to_port                      = local.container_port
}

resource "aws_security_group" "tasks" {
  name        = "${var.name}-tasks"
  description = "Application tasks"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "tasks_from_alb" {
  security_group_id            = aws_security_group.tasks.id
  description                  = "From the load balancer only"
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = local.container_port
  to_port                      = local.container_port
}

# Egress is listed, not 0.0.0.0/0: interface endpoints inside the VPC, S3 through its
# gateway endpoint, and PostgreSQL. Anything else the code tries to reach is dropped
# here, and shows up as REJECT in the flow logs.
resource "aws_vpc_security_group_egress_rule" "tasks_to_endpoints" {
  security_group_id = aws_security_group.tasks.id
  description       = "HTTPS to interface endpoints"
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "tasks_to_s3" {
  security_group_id = aws_security_group.tasks.id
  description       = "HTTPS to S3 for ECR image layers"
  prefix_list_id    = var.s3_prefix_list_id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "tasks_to_db" {
  security_group_id            = aws_security_group.tasks.id
  description                  = "PostgreSQL"
  referenced_security_group_id = var.database_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

# --- Load balancer -----------------------------------------------------------------

resource "aws_lb" "this" {
  #checkov:skip=CKV_AWS_150:A disposable environment must be destroyable without a manual console step.
  #checkov:skip=CKV_AWS_91:Access logs need a dedicated bucket with an ELB-specific policy; tracked as follow-up with public exposure.
  #checkov:skip=CKV2_AWS_28:Internal by default. WAF is required before public = true and lands with the Cognito/public-exposure change.
  #checkov:skip=CKV2_AWS_20:Port 80 redirects to HTTPS whenever a certificate is set; plain HTTP is allowed only on an internal ALB (precondition below).
  name                       = var.name
  load_balancer_type         = "application"
  internal                   = !var.public
  subnets                    = var.public ? var.public_subnet_ids : var.private_subnet_ids
  security_groups            = [aws_security_group.alb.id]
  drop_invalid_header_fields = true

  lifecycle {
    precondition {
      condition     = !var.public || local.https
      error_message = "A public load balancer requires certificate_arn: the API must not be served over plain HTTP on the internet."
    }
  }
}

resource "aws_lb_target_group" "this" {
  #checkov:skip=CKV_AWS_378:TLS terminates at the ALB; the hop to the task stays inside the VPC and is restricted to the ALB security group.
  name                 = var.name
  port                 = local.container_port
  protocol             = "HTTP"
  target_type          = "ip" # Fargate tasks register by ENI address
  vpc_id               = var.vpc_id
  deregistration_delay = 30

  # /healthz runs SELECT 1, so a task with a dead connection pool leaves the rotation.
  health_check {
    path                = "/healthz"
    matcher             = "200"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "https" {
  count = local.https ? 1 : 0

  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}

resource "aws_lb_listener" "http" {
  #checkov:skip=CKV_AWS_103:This listener redirects to HTTPS when a certificate is set, and serves HTTP only on an internal ALB.
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  # With TLS configured, port 80 only redirects. Without it (internal only, enforced by
  # the precondition above) it serves the API.
  dynamic "default_action" {
    for_each = local.https ? [1] : []
    content {
      type = "redirect"
      redirect {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }

  dynamic "default_action" {
    for_each = local.https ? [] : [1]
    content {
      type             = "forward"
      target_group_arn = aws_lb_target_group.this.arn
    }
  }
}

# --- Task definition and service ---------------------------------------------------

resource "aws_ecs_task_definition" "this" {
  family                   = var.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name                   = local.container_name
    image                  = "${aws_ecr_repository.this.repository_url}:${var.image_tag}"
    essential              = true
    readonlyRootFilesystem = true
    portMappings           = [{ containerPort = local.container_port, protocol = "tcp" }]

    environment = [
      { name = "FINDINGS_DB_HOST", value = var.database_host },
      { name = "FINDINGS_DB_PORT", value = tostring(var.database_port) },
      { name = "FINDINGS_DB_NAME", value = var.database_name },
    ]

    # Injected from the RDS-managed secret's JSON keys when the task starts. The app
    # assembles the URL itself (app/config.py), so the password is never concatenated
    # into a string anywhere in this configuration.
    secrets = [
      { name = "FINDINGS_DB_USER", valueFrom = "${var.database_secret_arn}:username::" },
      { name = "FINDINGS_DB_PASSWORD", valueFrom = "${var.database_secret_arn}:password::" },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.this.name
        awslogs-region        = data.aws_region.current.region
        awslogs-stream-prefix = local.container_name
      }
    }
  }])
}

resource "aws_ecs_service" "this" {
  name                   = var.name
  cluster                = aws_ecs_cluster.this.id
  task_definition        = aws_ecs_task_definition.this.arn
  desired_count          = var.desired_count
  launch_type            = "FARGATE"
  enable_execute_command = var.enable_execute_command
  propagate_tags         = "SERVICE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.this.arn
    container_name   = local.container_name
    container_port   = local.container_port
  }

  # A deployment whose tasks never pass health checks is rolled back automatically
  # instead of leaving the service half-replaced.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  depends_on = [aws_lb_listener.http, aws_lb_listener.https]
}
