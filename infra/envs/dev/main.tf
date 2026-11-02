locals {
  name = "findings-${var.environment}"
}

module "network" {
  source = "../../modules/network"

  name = local.name
  cidr = var.vpc_cidr
}

module "database" {
  source = "../../modules/database"

  name                     = local.name
  vpc_id                   = module.network.vpc_id
  subnet_ids               = module.network.database_subnet_ids
  client_security_group_id = module.service.task_security_group_id
}

module "service" {
  source = "../../modules/service"

  name               = local.name
  vpc_id             = module.network.vpc_id
  vpc_cidr           = module.network.vpc_cidr
  public_subnet_ids  = module.network.public_subnet_ids
  private_subnet_ids = module.network.private_subnet_ids
  s3_prefix_list_id  = module.network.s3_prefix_list_id

  database_host              = module.database.address
  database_port              = module.database.port
  database_name              = module.database.db_name
  database_secret_arn        = module.database.master_user_secret_arn
  database_security_group_id = module.database.security_group_id

  image_tag       = var.image_tag
  public          = var.public
  certificate_arn = var.certificate_arn
  # Internal by default: only addresses inside the VPC can reach the listener.
  allowed_cidrs = var.public ? var.allowed_cidrs : [module.network.vpc_cidr]
}
