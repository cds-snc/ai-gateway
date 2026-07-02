
module "gateway_vpc" {
  source = "github.com/cds-snc/terraform-modules//vpc?ref=main"

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

  tags = local.common_tags
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

  tags = local.common_tags
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

  tags = local.common_tags
}

# The shared VPC module NACL allows 443 + ephemeral by default. ALB -> ECS
# health checks and app traffic use destination port 8080, so add explicit
# VPC-internal allow rules for port 8080 in both directions.
resource "aws_network_acl_rule" "bifrost_http_inbound_8080" {
  network_acl_id = module.gateway_vpc.main_nacl_id
  rule_number    = 80
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = var.vpc_cidr
  from_port      = 8080
  to_port        = 8080
}

resource "aws_network_acl_rule" "bifrost_http_outbound_8080" {
  network_acl_id = module.gateway_vpc.main_nacl_id
  rule_number    = 81
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = var.vpc_cidr
  from_port      = 8080
  to_port        = 8080
}