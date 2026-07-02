# Security group for the Bifrost ALB (rules defined separately to avoid cycle)
resource "aws_security_group" "bifrost_alb" {
  name        = "${var.name_prefix}-bifrost-alb-sg"
  description = "Allow inbound HTTP to the Bifrost ALB from internal networks"
  vpc_id      = module.gateway_vpc.vpc_id

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-bifrost-alb-sg" })
}

resource "aws_security_group_rule" "bifrost_alb_ingress_http" {
  security_group_id = aws_security_group.bifrost_alb.id
  type              = "ingress"
  description       = "HTTP from anywhere (redirects to HTTPS)"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "bifrost_alb_ingress_https" {
  security_group_id = aws_security_group.bifrost_alb.id
  type              = "ingress"
  description       = "HTTPS from anywhere"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "bifrost_alb_egress_to_ecs" {
  security_group_id        = aws_security_group.bifrost_alb.id
  type                     = "egress"
  description              = "Forward traffic to Bifrost ECS tasks"
  from_port                = 8080
  to_port                  = 8080
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.bifrost_ecs.id
}

# Security group for Bifrost ECS tasks (rules defined separately to avoid cycle)
resource "aws_security_group" "bifrost_ecs" {
  name        = "${var.name_prefix}-bifrost-ecs-sg"
  description = "Allow inbound from ALB and outbound to Bedrock VPC endpoints and ECR"
  vpc_id      = module.gateway_vpc.vpc_id

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-bifrost-ecs-sg" })
}

resource "aws_security_group_rule" "bifrost_ecs_ingress_from_alb" {
  security_group_id        = aws_security_group.bifrost_ecs.id
  type                     = "ingress"
  description              = "HTTP from ALB"
  from_port                = 8080
  to_port                  = 8080
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.bifrost_alb.id
}

resource "aws_security_group_rule" "bifrost_ecs_egress_https" {
  security_group_id = aws_security_group.bifrost_ecs.id
  type              = "egress"
  description       = "HTTPS outbound (ECR image pull, Bedrock VPC endpoints, Secrets Manager)"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
}

# Internet-facing ALB in public subnets
resource "aws_lb" "bifrost" {
  name               = "${var.name_prefix}-bifrost"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.bifrost_alb.id]
  subnets            = module.gateway_vpc.public_subnet_ids

  enable_deletion_protection = false

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-bifrost" })
}

# Target group for Bifrost on port 8080
resource "aws_lb_target_group" "bifrost" {
  name        = "${var.name_prefix}-bifrost"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = module.gateway_vpc.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = "/health"
    protocol            = "HTTP"
    port                = "traffic-port"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 30
    timeout             = 5
    matcher             = "200"
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-bifrost" })
}

# ACM certificate for bifrost.cdssandbox.xyz
resource "aws_acm_certificate" "bifrost" {
  domain_name       = "bifrost.cdssandbox.xyz"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-bifrost" })
}

# Hosted zone for bifrost.cdssandbox.xyz (delegated from parent cdssandbox.xyz)
resource "aws_route53_zone" "bifrost" {
  name = "bifrost.cdssandbox.xyz"

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-bifrost" })
}

# ACM DNS validation record
resource "aws_route53_record" "bifrost_acm_validation" {
  for_each = {
    for dvo in aws_acm_certificate.bifrost.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id         = aws_route53_zone.bifrost.zone_id
  name            = each.value.name
  type            = each.value.type
  ttl             = 300
  records         = [each.value.record]
  allow_overwrite = true
}

# A record pointing to the ALB
resource "aws_route53_record" "bifrost_alb" {
  zone_id = aws_route53_zone.bifrost.zone_id
  name    = "bifrost.cdssandbox.xyz"
  type    = "A"

  alias {
    name                   = aws_lb.bifrost.dns_name
    zone_id                = aws_lb.bifrost.zone_id
    evaluate_target_health = true
  }
}

# Wait for ACM certificate to be validated before use
resource "aws_acm_certificate_validation" "bifrost" {
  certificate_arn         = aws_acm_certificate.bifrost.arn
  validation_record_fqdns = [for record in aws_route53_record.bifrost_acm_validation : record.fqdn]
}

# HTTPS listener: forward traffic to Bifrost target group
resource "aws_lb_listener" "bifrost_https" {
  load_balancer_arn = aws_lb.bifrost.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.bifrost.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.bifrost.arn
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-bifrost-https" })
}

# HTTP listener: redirect to HTTPS
resource "aws_lb_listener" "bifrost_http" {
  load_balancer_arn = aws_lb.bifrost.arn
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

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-bifrost-http" })
}

output "bifrost_url" {
  description = "URL to access the Bifrost AI gateway web UI and API."
  value       = "https://bifrost.cdssandbox.xyz"
}

output "bifrost_name_servers" {
  description = "NS records to add in the parent cdssandbox.xyz hosted zone to delegate bifrost.cdssandbox.xyz."
  value       = aws_route53_zone.bifrost.name_servers
}
