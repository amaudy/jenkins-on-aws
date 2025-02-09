variable "environment" {
  default = "production"
}

variable "instance_type" {
  default = "t3.large"
}

variable "cost_code" {
  type    = string
  default = "1234"
}

variable "default_tags" {
  type = map(string)
  default = {
    Environment = "dev"
    Application = "jenkins"
  }
}

variable "jenkins_admin_user" {
  description = "Jenkins admin username"
  type        = string
  default     = "admin"
}

variable "jenkins_admin_password" {
  description = "Jenkins admin password. Must be at least 8 characters and include uppercase, lowercase, numbers, and special characters."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.jenkins_admin_password) >= 8 && can(regex("[A-Z]", var.jenkins_admin_password)) && can(regex("[a-z]", var.jenkins_admin_password)) && can(regex("[0-9]", var.jenkins_admin_password)) && can(regex("[^A-Za-z0-9]", var.jenkins_admin_password))
    error_message = "Password must be at least 8 characters and include uppercase, lowercase, numbers, and special characters."
  }
}

# Removed unused variables for VPC CIDR and public subnet CIDR
