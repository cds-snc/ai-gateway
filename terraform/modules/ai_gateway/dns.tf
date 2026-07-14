locals {
  gateway_dns_enabled = var.gateway_domain_name != ""

  gateway_hosted_zone_id = aws_route53_zone.gateway.zone_id

  gateway_certificate_arn_effective = (
    var.gateway_certificate_arn != ""
    ? var.gateway_certificate_arn
    : try(aws_acm_certificate_validation.gateway[0].certificate_arn, null)
  )

  gateway_endpoint_host = (
    local.gateway_dns_enabled
    ? var.gateway_domain_name
    : aws_lb.litellm.dns_name
  )
}

resource "aws_route53_zone" "gateway" {
  name    = var.gateway_domain_name
  comment = "Delegated zone for the AI gateway"

  tags = merge(local.common_tags, { Name = var.gateway_domain_name })
}

resource "aws_acm_certificate" "gateway" {
  count = (local.gateway_dns_enabled && var.gateway_certificate_arn == "") ? 1 : 0

  domain_name               = var.gateway_domain_name
  validation_method         = "DNS"
  subject_alternative_names = var.gateway_subject_alternative_names

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-gateway-cert" })
}

resource "aws_route53_record" "gateway_certificate_validation" {
  for_each = (
    local.gateway_dns_enabled &&
    var.gateway_certificate_arn == "" &&
    local.gateway_hosted_zone_id != null
    ) ? {
    for dvo in aws_acm_certificate.gateway[0].domain_validation_options :
    dvo.domain_name => {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }
  } : {}

  allow_overwrite = true
  zone_id         = local.gateway_hosted_zone_id
  name            = each.value.name
  type            = each.value.type
  ttl             = 60
  records         = [each.value.value]
}

resource "aws_acm_certificate_validation" "gateway" {
  count = (
    local.gateway_dns_enabled &&
    var.gateway_certificate_arn == "" &&
    local.gateway_hosted_zone_id != null
  ) ? 1 : 0

  certificate_arn         = aws_acm_certificate.gateway[0].arn
  validation_record_fqdns = [for record in aws_route53_record.gateway_certificate_validation : record.fqdn]
}

resource "aws_route53_record" "gateway_alias_a" {
  count = (local.gateway_dns_enabled && local.gateway_hosted_zone_id != null) ? 1 : 0

  zone_id = local.gateway_hosted_zone_id
  name    = var.gateway_domain_name
  type    = "A"

  alias {
    name                   = aws_lb.litellm.dns_name
    zone_id                = aws_lb.litellm.zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "gateway_alias_aaaa" {
  count = (local.gateway_dns_enabled && local.gateway_hosted_zone_id != null) ? 1 : 0

  zone_id = local.gateway_hosted_zone_id
  name    = var.gateway_domain_name
  type    = "AAAA"

  alias {
    name                   = aws_lb.litellm.dns_name
    zone_id                = aws_lb.litellm.zone_id
    evaluate_target_health = true
  }
}

output "gateway_domain_name" {
  description = "Configured public domain name for the AI gateway."
  value       = var.gateway_domain_name
}

output "gateway_hosted_zone_id" {
  description = "Hosted zone used for gateway DNS records in this account."
  value       = local.gateway_hosted_zone_id
}

output "gateway_delegation_name_servers" {
  description = "Name servers for delegating gateway_domain_name from the parent zone."
  value       = aws_route53_zone.gateway.name_servers
}

output "gateway_certificate_arn_effective" {
  description = "Certificate ARN currently attached to the HTTPS listener."
  value       = local.gateway_certificate_arn_effective
}
