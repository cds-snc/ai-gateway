# Security group for the LiteLLM ALB (rules defined separately to avoid cycle)
resource "aws_security_group" "litellm_alb" {
  name        = "${var.name_prefix}-litellm-alb-sg"
  description = "Allow inbound HTTP to the LiteLLM ALB"
  vpc_id      = module.gateway_vpc.vpc_id

  tags = merge(local.common_tags, {
    Name      = "${var.name_prefix}-litellm-alb-sg"
    ssc_cbrid = "22DH"
  })
}

resource "aws_security_group_rule" "litellm_alb_ingress_http" {
  security_group_id = aws_security_group.litellm_alb.id
  type              = "ingress"
  description       = "HTTP from approved ingress CIDRs"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = var.public_ingress_cidrs
}

resource "aws_security_group_rule" "litellm_alb_ingress_https" {
  security_group_id = aws_security_group.litellm_alb.id
  type              = "ingress"
  description       = "HTTPS from approved ingress CIDRs"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = var.public_ingress_cidrs
}

resource "aws_security_group_rule" "litellm_alb_egress_to_ecs" {
  security_group_id        = aws_security_group.litellm_alb.id
  type                     = "egress"
  description              = "Forward traffic to LiteLLM ECS tasks"
  from_port                = var.litellm_container_port
  to_port                  = var.litellm_container_port
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.litellm_ecs.id
}

# Internet-facing ALB in public subnets
resource "aws_lb" "litellm" {
  name               = "${var.name_prefix}-litellm"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.litellm_alb.id]
  subnets            = module.gateway_vpc.public_subnet_ids
  depends_on         = [aws_s3_bucket_policy.alb_access_logs]

  enable_deletion_protection = false

  access_logs {
    bucket  = module.alb_access_logs_bucket.s3_bucket_id
    prefix  = var.alb_access_logs_prefix
    enabled = var.enable_alb_access_logs
  }

  tags = merge(local.common_tags, {
    Name      = "${var.name_prefix}-litellm"
    ssc_cbrid = "22DH"
  })
}

# Target group for LiteLLM on port 4000
resource "aws_lb_target_group" "litellm" {
  name        = "${var.name_prefix}-litellm"
  port        = var.litellm_container_port
  protocol    = "HTTP"
  vpc_id      = module.gateway_vpc.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = "/health/readiness"
    protocol            = "HTTP"
    port                = "traffic-port"
    healthy_threshold   = var.health_check_healthy_threshold
    unhealthy_threshold = var.health_check_unhealthy_threshold
    interval            = var.health_check_interval_seconds
    timeout             = var.health_check_timeout_seconds
    matcher             = "200"
  }

  tags = merge(local.common_tags, {
    Name      = "${var.name_prefix}-litellm"
    ssc_cbrid = "22DH"
  })
}

resource "aws_lb_listener" "litellm_http_redirect" {
  load_balancer_arn = aws_lb.litellm.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }

  tags = merge(local.common_tags, {
    Name      = "${var.name_prefix}-litellm-http-redirect"
    ssc_cbrid = "22DH"
  })
}

resource "aws_lb_listener" "litellm_https" {
  load_balancer_arn = aws_lb.litellm.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = var.gateway_tls_policy
  certificate_arn   = local.gateway_certificate_arn_effective

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.litellm.arn
  }

  tags = merge(local.common_tags, {
    Name      = "${var.name_prefix}-litellm-https"
    ssc_cbrid = "22DH"
  })
}

output "litellm_url" {
  description = "Canonical URL to access the LiteLLM AI gateway API."
  value       = "https://${local.gateway_endpoint_host}"
}

output "litellm_http_url" {
  description = "HTTP endpoint for client traffic."
  value       = "http://${local.gateway_endpoint_host}"
}

output "litellm_https_url" {
  description = "HTTPS endpoint for client traffic when certificate is configured."
  value       = "https://${local.gateway_endpoint_host}"
}