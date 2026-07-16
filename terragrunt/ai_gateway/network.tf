
module "gateway_vpc" {
  source = "github.com/cds-snc/terraform-modules//vpc?ref=v11.4.4"

  name               = var.name_prefix
  billing_tag_value  = var.billing_tag_value
  cidr               = var.vpc_cidr
  availability_zones = length(var.subnet_cidrs)
  private_subnets    = var.subnet_cidrs
  public_subnets     = var.public_subnet_cidrs
  single_nat_gateway = true
  enable_flow_log    = true

  allow_https_request_out          = true
  allow_https_request_out_response = true
  allow_https_request_in           = true
  allow_https_request_in_response  = true
}


resource "aws_vpc_endpoint" "bedrock_runtime" {
  vpc_id              = module.gateway_vpc.vpc_id
  service_name        = "com.amazonaws.${var.primary_region}.bedrock-runtime"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.gateway_vpc.private_subnet_ids
  security_group_ids  = [aws_security_group.vpce.id]
  private_dns_enabled = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = "*"
      Action = [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream"
      ]
      Resource = "*"
      Condition = {
        StringLike = {
          "aws:PrincipalArn" = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/BedrockConsumer-*"
        }
      }
    }]
  })

  tags = merge(local.common_tags, { ssc_cbrid = "22DH" })
}

resource "aws_vpc_endpoint" "bedrock_agent_runtime" {
  vpc_id              = module.gateway_vpc.vpc_id
  service_name        = "com.amazonaws.${var.primary_region}.bedrock-agent-runtime"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.gateway_vpc.private_subnet_ids
  security_group_ids  = [aws_security_group.vpce.id]
  private_dns_enabled = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = "*"
      Action    = "bedrock:*"
      Resource  = "*"
      Condition = {
        StringLike = {
          "aws:PrincipalArn" = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/BedrockConsumer-*"
        }
      }
    }]
  })

  tags = merge(local.common_tags, { ssc_cbrid = "22DH" })
}


resource "aws_security_group" "vpce" {
  name        = "${var.name_prefix}-vpce-sg"
  description = "Allow TLS to Bedrock interface endpoints"
  vpc_id      = module.gateway_vpc.vpc_id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.allowed_endpoint_ingress_cidrs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { ssc_cbrid = "22DH" })
}

locals {
  approved_listener_ports = {
    for port in var.approved_public_listener_ports : tostring(port) => port
  }
}

# Explicit listener-path NACL coverage for approved public ports.
resource "aws_network_acl_rule" "public_listener_inbound" {
  for_each = local.approved_listener_ports

  network_acl_id = module.gateway_vpc.main_nacl_id
  rule_number    = var.listener_nacl_rule_start + each.value
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = each.value
  to_port        = each.value
}

resource "aws_network_acl_rule" "public_listener_outbound" {
  for_each = local.approved_listener_ports

  network_acl_id = module.gateway_vpc.main_nacl_id
  rule_number    = var.listener_nacl_rule_start + 100 + each.value
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = each.value
  to_port        = each.value
}

# The shared VPC module NACL allows 443 + ephemeral by default. ALB -> ECS
# health checks and app traffic use destination port 4000, so add explicit
# VPC-internal allow rules for port 4000 in both directions.
resource "aws_network_acl_rule" "litellm_http_inbound_4000" {
  network_acl_id = module.gateway_vpc.main_nacl_id
  rule_number    = 80
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = var.vpc_cidr
  from_port      = var.litellm_container_port
  to_port        = var.litellm_container_port
}

resource "aws_network_acl_rule" "litellm_http_outbound_4000" {
  network_acl_id = module.gateway_vpc.main_nacl_id
  rule_number    = 81
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = var.vpc_cidr
  from_port      = var.litellm_container_port
  to_port        = var.litellm_container_port
}

# Allow ECS <-> Aurora PostgreSQL traffic on 5432 within the VPC.
resource "aws_network_acl_rule" "litellm_postgres_inbound_5432" {
  network_acl_id = module.gateway_vpc.main_nacl_id
  rule_number    = 82
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = var.vpc_cidr
  from_port      = 5432
  to_port        = 5432
}

resource "aws_network_acl_rule" "litellm_postgres_outbound_5432" {
  network_acl_id = module.gateway_vpc.main_nacl_id
  rule_number    = 83
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = var.vpc_cidr
  from_port      = 5432
  to_port        = 5432
}

# Allow ECS <-> Redis traffic on 6379 within the VPC.
resource "aws_network_acl_rule" "litellm_redis_inbound_6379" {
  network_acl_id = module.gateway_vpc.main_nacl_id
  rule_number    = 84
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = var.vpc_cidr
  from_port      = 6379
  to_port        = 6379
}

resource "aws_network_acl_rule" "litellm_redis_outbound_6379" {
  network_acl_id = module.gateway_vpc.main_nacl_id
  rule_number    = 85
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = var.vpc_cidr
  from_port      = 6379
  to_port        = 6379
}

# Security group for LiteLLM ECS tasks
resource "aws_security_group" "litellm_ecs" {
  name        = "${var.name_prefix}-litellm-ecs-sg"
  description = "Allow inbound from ALB and outbound to Bedrock endpoints, RDS, and Redis"
  vpc_id      = module.gateway_vpc.vpc_id

  tags = merge(local.common_tags, {
    Name      = "${var.name_prefix}-litellm-ecs-sg"
    ssc_cbrid = "22DH"
  })
}

resource "aws_security_group_rule" "litellm_ecs_ingress_from_alb" {
  security_group_id        = aws_security_group.litellm_ecs.id
  type                     = "ingress"
  description              = "HTTP from ALB"
  from_port                = var.litellm_container_port
  to_port                  = var.litellm_container_port
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.litellm_alb.id
}

resource "aws_security_group_rule" "litellm_ecs_egress_https" {
  security_group_id = aws_security_group.litellm_ecs.id
  type              = "egress"
  description       = "HTTPS outbound (ECR, Bedrock endpoint, Secrets Manager, S3)"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "litellm_ecs_egress_rds" {
  security_group_id        = aws_security_group.litellm_ecs.id
  type                     = "egress"
  description              = "PostgreSQL outbound to RDS"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = module.litellm_rds.cluster_security_group_id
}

resource "aws_security_group_rule" "litellm_ecs_egress_redis" {
  security_group_id        = aws_security_group.litellm_ecs.id
  type                     = "egress"
  description              = "Redis outbound to Elasticache"
  from_port                = 6379
  to_port                  = 6379
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.litellm_redis.id
}

# Security group for LiteLLM Redis
resource "aws_security_group" "litellm_redis" {
  name        = "${var.name_prefix}-litellm-redis-sg"
  description = "Allow Redis ingress from LiteLLM ECS tasks only"
  vpc_id      = module.gateway_vpc.vpc_id

  tags = merge(local.common_tags, {
    Name      = "${var.name_prefix}-litellm-redis-sg"
    ssc_cbrid = "22DH"
  })
}

# Dedicated SG attached to Aurora cluster for ECS access on 5432.
resource "aws_security_group" "litellm_rds" {
  name        = "${var.name_prefix}-litellm-rds-sg"
  description = "Allow PostgreSQL ingress from LiteLLM ECS tasks only"
  vpc_id      = module.gateway_vpc.vpc_id

  lifecycle {
    prevent_destroy = true
  }

  tags = merge(local.common_tags, {
    Name      = "${var.name_prefix}-litellm-rds-sg"
    ssc_cbrid = "22DH"
  })
}

resource "aws_security_group_rule" "litellm_rds_ingress_from_ecs" {
  security_group_id        = aws_security_group.litellm_rds.id
  type                     = "ingress"
  description              = "PostgreSQL from LiteLLM ECS"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.litellm_ecs.id
}

resource "aws_security_group_rule" "litellm_rds_module_sg_ingress_from_ecs" {
  security_group_id        = module.litellm_rds.cluster_security_group_id
  type                     = "ingress"
  description              = "PostgreSQL from LiteLLM ECS to module-managed RDS SG"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.litellm_ecs.id
}

resource "aws_security_group_rule" "litellm_redis_ingress_from_ecs" {
  security_group_id        = aws_security_group.litellm_redis.id
  type                     = "ingress"
  description              = "Redis from LiteLLM ECS"
  from_port                = 6379
  to_port                  = 6379
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.litellm_ecs.id
}