# Declarative import for one existing child hosted zone.
# Set the hosted zone ID directly before plan/apply.
import {
  to = aws_route53_zone.gateway
  id = "Z09765752UQ2T8K77L02P"
}
