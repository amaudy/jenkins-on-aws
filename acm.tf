# Request an ACM certificate
resource "aws_acm_certificate" "jenkins" {
  domain_name       = "your-domain"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# Output ACM validation records for DNS configuration
output "acm_validation_records" {
  description = "ACM certificate validation records"
  value = {
    for dvo in aws_acm_certificate.jenkins.domain_validation_options : dvo.domain_name => {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }
  }
}
