# PostgreSQL 16 on RDS, matching the version CI tests against.
#
# The master password is generated and stored by RDS in Secrets Manager
# (manage_master_user_password), so it never appears in Terraform code, plan output or
# state. ECS reads it from the secret at task start.

resource "aws_db_subnet_group" "this" {
  name       = var.name
  subnet_ids = var.subnet_ids
}

resource "aws_security_group" "this" {
  name        = "${var.name}-db"
  description = "PostgreSQL, reachable only from the application tasks"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "from_app" {
  security_group_id            = aws_security_group.this.id
  description                  = "PostgreSQL from the application security group"
  referenced_security_group_id = var.client_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_db_parameter_group" "this" {
  name   = var.name
  family = "postgres16"

  # Refuse unencrypted connections at the server, not just by client convention.
  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "500"
  }
}

resource "aws_db_instance" "this" {
  #checkov:skip=CKV_AWS_293:Deletion protection is variable-controlled and off by default so a synthetic-data environment can be torn down.
  #checkov:skip=CKV_AWS_157:Multi-AZ is variable-controlled and off by default; it doubles cost for a single-user learning environment.
  #checkov:skip=CKV_AWS_118:Enhanced monitoring needs an extra IAM role and CloudWatch cost; CloudWatch metrics and exported postgres logs cover diagnosis here.
  #checkov:skip=CKV_AWS_353:Performance Insights deferred until there is real query load to analyse.
  identifier     = var.name
  engine         = "postgres"
  engine_version = "16"
  instance_class = var.instance_class

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name                     = "findings"
  username                    = "findings_admin"
  manage_master_user_password = true
  # Enabled now so a later change can move the app to short-lived IAM tokens instead
  # of the master password (see infra/README.md, "Known gaps").
  iam_database_authentication_enabled = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.this.id]
  parameter_group_name   = aws_db_parameter_group.this.name
  publicly_accessible    = false
  multi_az               = var.multi_az

  backup_retention_period         = var.backup_retention_days
  copy_tags_to_snapshot           = true
  auto_minor_version_upgrade      = true
  enabled_cloudwatch_logs_exports = ["postgresql"]

  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${var.name}-final"

  # Applied in the next maintenance window by default; a learning environment would
  # rather see the change (and any downtime) when it runs `apply`.
  apply_immediately = true
}
