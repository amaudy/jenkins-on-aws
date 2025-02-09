# Get all subnets in the VPC
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Get specific subnet for EC2 instance
data "aws_subnet" "ec2_subnet" {
  id = data.aws_subnet.default.id
}

# Get another subnet in a different AZ for ALB redundancy
data "aws_subnet" "alb_subnet" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "availability-zone"
    values = ["us-east-1b"]  # Different AZ from EC2 instance
  }
}

# ALB Security Group
resource "aws_security_group" "alb_sg" {
  name        = "jenkins-alb-sg"
  description = "Security group for Jenkins ALB"
  vpc_id      = data.aws_vpc.default.id

  # Allow HTTP from anywhere
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow HTTP from anywhere"
  }

  # Allow HTTPS from anywhere
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow HTTPS from anywhere"
  }

  # Allow all outbound
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    var.default_tags,
    {
      Name = "jenkins-alb-sg"
    }
  )
}

# Target Group
resource "aws_lb_target_group" "jenkins" {
  name     = "jenkins-target-group"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id

  health_check {
    enabled             = true
    healthy_threshold   = 2
    interval            = 30
    matcher            = "200-299"
    path               = "/login"
    port               = "traffic-port"
    timeout            = 5
    unhealthy_threshold = 5
  }

  tags = merge(
    var.default_tags,
    {
      Name = "jenkins-target-group"
    }
  )
}

# Application Load Balancer
resource "aws_lb" "jenkins" {
  name               = "jenkins-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [data.aws_subnet.ec2_subnet.id, data.aws_subnet.alb_subnet.id]

  enable_deletion_protection = false

  tags = merge(
    var.default_tags,
    {
      Name = "jenkins-alb"
    }
  )
}

# HTTP Listener - Redirect to HTTPS
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.jenkins.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# HTTPS Listener
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.jenkins.arn
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-2016-08"
  certificate_arn   = aws_acm_certificate.jenkins.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.jenkins.arn
  }
}

# Output the ALB DNS name
output "jenkins_url" {
  description = "URL to access Jenkins"
  value       = "https://jenkins-aws.example.xyz"
}

# Output ALB DNS name for DNS configuration
output "alb_dns_name" {
  description = "ALB DNS name for CNAME record"
  value       = aws_lb.jenkins.dns_name
}
