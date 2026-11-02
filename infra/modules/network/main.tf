# Three subnet tiers per availability zone:
#   public   -- the load balancer only; the one tier with a route to the internet
#   private  -- ECS tasks; no internet route, AWS APIs reached through VPC endpoints
#   database -- RDS; no route out of the VPC at all
#
# There is deliberately no NAT gateway. Tasks reach ECR, CloudWatch Logs, Secrets Manager
# and Bedrock through private endpoints, so nothing in the private tier can call an
# arbitrary internet host. That is the property a bank network team asks for first.

data "aws_availability_zones" "available" {
  #checkov:skip=CKV_AWS_394:slice() takes the first az_count zones, so a newly added zone does not change the subnet layout.
  state = "available"
}

data "aws_region" "current" {}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # /24s carved from the VPC range: public 0-9, private 10-19, database 20-29.
  public_cidrs   = { for i, az in local.azs : az => cidrsubnet(var.cidr, 8, i) }
  private_cidrs  = { for i, az in local.azs : az => cidrsubnet(var.cidr, 8, 10 + i) }
  database_cidrs = { for i, az in local.azs : az => cidrsubnet(var.cidr, 8, 20 + i) }
}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr
  enable_dns_support   = true
  enable_dns_hostnames = true # required for private DNS on interface endpoints

  tags = { Name = var.name }
}

# Take ownership of the default security group and strip its rules, so nothing can be
# launched into an allow-all group by accident.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-default-unused" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = var.name }
}

resource "aws_subnet" "public" {
  for_each = local.public_cidrs

  vpc_id            = aws_vpc.this.id
  availability_zone = each.key
  cidr_block        = each.value

  tags = { Name = "${var.name}-public-${each.key}", Tier = "public" }
}

resource "aws_subnet" "private" {
  for_each = local.private_cidrs

  vpc_id            = aws_vpc.this.id
  availability_zone = each.key
  cidr_block        = each.value

  tags = { Name = "${var.name}-private-${each.key}", Tier = "private" }
}

resource "aws_subnet" "database" {
  for_each = local.database_cidrs

  vpc_id            = aws_vpc.this.id
  availability_zone = each.key
  cidr_block        = each.value

  tags = { Name = "${var.name}-database-${each.key}", Tier = "database" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-public" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# Private and database tables carry only the implicit local route (plus the S3 gateway
# endpoint for private). Absence of a 0.0.0.0/0 route is the control, not a gap.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-private" }
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table" "database" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-database" }
}

resource "aws_route_table_association" "database" {
  for_each = aws_subnet.database

  subnet_id      = each.value.id
  route_table_id = aws_route_table.database.id
}

# --- VPC endpoints -----------------------------------------------------------------

# ECR stores image layers in S3, so pulling an image needs S3 as well as the ECR APIs.
# Gateway endpoints are free; interface endpoints are billed per AZ-hour.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = { Name = "${var.name}-s3" }
}

resource "aws_security_group" "endpoints" {
  name        = "${var.name}-endpoints"
  description = "HTTPS from inside the VPC to interface endpoints"
  vpc_id      = aws_vpc.this.id
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_https" {
  security_group_id = aws_security_group.endpoints.id
  description       = "HTTPS from the VPC"
  cidr_ipv4         = var.cidr
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_endpoint" "interface" {
  for_each = toset(var.interface_endpoints)

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [for s in aws_subnet.private : s.id]
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = { Name = "${var.name}-${each.value}" }
}

# --- Flow logs ---------------------------------------------------------------------

# Rejected-traffic records are what answer "why can't the task reach the database?"
# without guessing. ALL rather than REJECT so accepted flows can be compared too.
resource "aws_cloudwatch_log_group" "flow_logs" {
  #checkov:skip=CKV_AWS_158:Log groups are encrypted with AWS-managed keys; a customer-managed key is a production-account control.
  #checkov:skip=CKV_AWS_338:Retention is variable-controlled and short by default; synthetic traffic only.
  name              = "/vpc/${var.name}/flow-logs"
  retention_in_days = var.log_retention_days
}

data "aws_iam_policy_document" "flow_logs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "flow_logs" {
  name               = "${var.name}-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume.json
}

data "aws_iam_policy_document" "flow_logs_write" {
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = ["${aws_cloudwatch_log_group.flow_logs.arn}:*"]
  }
}

resource "aws_iam_role_policy" "flow_logs" {
  name   = "write-flow-logs"
  role   = aws_iam_role.flow_logs.id
  policy = data.aws_iam_policy_document.flow_logs_write.json
}

resource "aws_flow_log" "this" {
  vpc_id          = aws_vpc.this.id
  traffic_type    = "ALL"
  log_destination = aws_cloudwatch_log_group.flow_logs.arn
  iam_role_arn    = aws_iam_role.flow_logs.arn
}
