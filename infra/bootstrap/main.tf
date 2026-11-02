# One-time setup, applied by hand with admin credentials:
#   1. an encrypted, versioned S3 bucket for Terraform state (S3-native locking)
#   2. GitHub's OIDC identity provider, so CI gets short-lived credentials instead of
#      stored access keys
#   3. a read-only plan role for pull requests and a scoped apply role for deployments

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  bucket     = "${var.name_prefix}-tfstate-${local.account_id}"
}

# --- State bucket ------------------------------------------------------------------

resource "aws_s3_bucket" "state" {
  #checkov:skip=CKV_AWS_18:Access logging needs a second log bucket; CloudTrail data events are the stronger audit trail if this becomes a shared account.
  #checkov:skip=CKV2_AWS_62:No consumer for bucket event notifications.
  #checkov:skip=CKV_AWS_144:Cross-region replication is out of scope for a disposable learning account; versioning covers bad applies.
  #checkov:skip=CKV_AWS_145:SSE-S3 (AES256) is enabled; a customer-managed KMS key adds cost and key-policy work without changing who can read state here.
  bucket = local.bucket
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled" # a bad apply that corrupts state can be rolled back to a prior version
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

data "aws_iam_policy_document" "state_tls_only" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_tls_only.json
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# --- GitHub OIDC -------------------------------------------------------------------

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

# The `sub` claim is what scopes each role. A pull request can only get the read-only
# role; only a job running in the protected GitHub environment can get the apply role.
data "aws_iam_policy_document" "github_assume" {
  for_each = {
    plan  = "repo:${var.github_repository}:pull_request"
    apply = "repo:${var.github_repository}:environment:${var.deploy_environment}"
  }

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [each.value]
    }
  }
}

resource "aws_iam_role" "plan" {
  name                 = "${var.name_prefix}-ci-plan"
  assume_role_policy   = data.aws_iam_policy_document.github_assume["plan"].json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "plan_read_only" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/ReadOnlyAccess"
}

# Plan must read state and take the lock (a .tflock object next to the state file).
data "aws_iam_policy_document" "state_access" {
  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
  }
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.state.arn}/*"]
  }
  statement {
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/*.tflock"]
  }
}

resource "aws_iam_role_policy" "plan_state" {
  name   = "terraform-state-lock"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.state_access.json
}

resource "aws_iam_role" "apply" {
  name                 = "${var.name_prefix}-ci-apply"
  assume_role_policy   = data.aws_iam_policy_document.github_assume["apply"].json
  max_session_duration = 3600
}

# PowerUserAccess covers every service the stack uses but excludes IAM. IAM is then
# granted only for roles and policies under this project's name prefix, so a compromised
# deploy job cannot create an admin role or touch anything else in the account.
# Tradeoff, stated plainly: PowerUser is still broad. A production account would replace
# it with a policy generated from CloudTrail activity (IAM Access Analyzer).
resource "aws_iam_role_policy_attachment" "apply_power_user" {
  role       = aws_iam_role.apply.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/PowerUserAccess"
}

data "aws_iam_policy_document" "apply_iam_scoped" {
  statement {
    sid = "ManageProjectRoles"
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:UpdateRole",
      "iam:TagRole", "iam:UntagRole", "iam:ListRoleTags",
      "iam:UpdateAssumeRolePolicy", "iam:PassRole",
      "iam:PutRolePolicy", "iam:GetRolePolicy", "iam:DeleteRolePolicy",
      "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
      "iam:AttachRolePolicy", "iam:DetachRolePolicy",
      "iam:ListInstanceProfilesForRole",
    ]
    resources = ["arn:${data.aws_partition.current.partition}:iam::${local.account_id}:role/${var.name_prefix}-*"]
  }
  statement {
    sid       = "ServiceLinkedRoles"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]
    condition {
      test     = "StringLike"
      variable = "iam:AWSServiceName"
      values = [
        "ecs.amazonaws.com",
        "elasticloadbalancing.amazonaws.com",
        "rds.amazonaws.com",
      ]
    }
  }
}

resource "aws_iam_role_policy" "apply_iam" {
  name   = "manage-project-iam"
  role   = aws_iam_role.apply.id
  policy = data.aws_iam_policy_document.apply_iam_scoped.json
}

resource "aws_iam_role_policy" "apply_state" {
  name   = "terraform-state-lock"
  role   = aws_iam_role.apply.id
  policy = data.aws_iam_policy_document.state_access.json
}
