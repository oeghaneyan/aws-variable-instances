terraform {
  required_providers {
    aws = {
      version = "4.67.0"
      source  = "hashicorp/aws"
    }
    doormat = {
      source  = "doormat.hashicorp.services/hashicorp-security/doormat"
      version = "~> 0.0.2"
    }
  }
}

provider "aws" {
  access_key = data.doormat_aws_credentials.creds.access_key
  secret_key = data.doormat_aws_credentials.creds.secret_key
  token      = data.doormat_aws_credentials.creds.token
  region = var.aws_region
}

data "aws_availability_zones" "available" {
  state = "available"
}

provider "doormat" {}

data "doormat_aws_credentials" "creds" {
  provider = doormat
  role_arn = "arn:aws:iam::407603399482:role/omid-eghaneyan-tfc-aws-variable-instances"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "2.66.0"
  tags = {
    purpose = "oeghaneyan-demo"
  }
  for_each = var.project

  cidr = var.vpc_cidr_block

  azs             = data.aws_availability_zones.available.names
  private_subnets = slice(var.private_subnet_cidr_blocks, 0, each.value.private_subnet_count)
  public_subnets  = slice(var.public_subnet_cidr_blocks, 0, each.value.public_subnet_count)

  enable_nat_gateway = true
  enable_vpn_gateway = false
}

module "app_security_group" {
  source  = "terraform-aws-modules/security-group/aws//modules/web"
  version = "3.17.0"
  tags = {
    purpose = "oeghaneyan-demo"
  }    
  for_each = var.project

  name        = "web-server-sg-${each.key}-${each.value.environment}"
  description = "Security group for web-servers with HTTP ports open within VPC"
  vpc_id      = module.vpc[each.key].vpc_id

  ingress_cidr_blocks = module.vpc[each.key].public_subnets_cidr_blocks
}

module "lb_security_group" {
  source  = "terraform-aws-modules/security-group/aws//modules/web"
  version = "3.17.0"
  tags = {
    purpose = "oeghaneyan-demo"
  }    
  for_each = var.project

  name = "load-balancer-sg-${each.key}-${each.value.environment}"

  description = "Security group for load balancer with HTTP ports open within VPC"
  vpc_id      = module.vpc[each.key].vpc_id

  ingress_cidr_blocks = ["0.0.0.0/0"]
}

resource "random_string" "lb_id" {
  length  = 4
  special = false
}

module "elb_http" {
  source  = "terraform-aws-modules/elb/aws"
  version = "2.4.0"
  tags = {
    purpose = "oeghaneyan-demo"
  }    
  for_each = var.project

  # Comply with ELB name restrictions 
  # https://docs.aws.amazon.com/elasticloadbalancing/2012-06-01/APIReference/API_CreateLoadBalancer.html
  name     = trimsuffix(substr(replace(join("-", ["lb", random_string.lb_id.result, each.key, each.value.environment]), "/[^a-zA-Z0-9-]/", ""), 0, 32), "-")
  internal = false

  security_groups = [module.lb_security_group[each.key].this_security_group_id]
  subnets         = module.vpc[each.key].public_subnets

  number_of_instances = length(module.standard-instance[each.key].instance_ids)
  instances           = module.standard-instance[each.key].instance_ids

  listener = [{
    instance_port     = "80"
    instance_protocol = "HTTP"
    lb_port           = "80"
    lb_protocol       = "HTTP"
  }]

  health_check = {
    target              = "HTTP:80/index.html"
    interval            = 10
    healthy_threshold   = 3
    unhealthy_threshold = 10
    timeout             = 5
  }
}

module "standard-instance" {
  source  = "app.terraform.io/TF-Cloud-Demo-OE/standard-instance/aws"
  version = "7.1.0"
  for_each = var.project

  instance_count     = each.value.instances_per_subnet * length(module.vpc[each.key].private_subnets)
  instance_type      = each.value.instance_type
  subnet_ids         = module.vpc[each.key].private_subnets[*]
  security_group_ids = [module.app_security_group[each.key].this_security_group_id]

  project_name = each.key
  environment  = each.value.environment
}
