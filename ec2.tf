data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

resource "aws_iam_role" "jenkins_role" {
  name = "jenkins_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = merge(
    {
      cost_code = var.cost_code
    },
    {
      Name = "jenkins-role"
    }
  )
}

resource "aws_iam_role_policy_attachment" "ssm_policy" {
  role       = aws_iam_role.jenkins_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cloudwatch_policy" {
  role       = aws_iam_role.jenkins_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# Add CloudWatch Logs policy for creating log groups
resource "aws_iam_role_policy" "cloudwatch_logs_policy" {
  name = "cloudwatch_logs_policy"
  role = aws_iam_role.jenkins_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams"
        ]
        Resource = [
          "arn:aws:logs:*:*:log-group:/jenkins/*:*"
        ]
      }
    ]
  })
}

resource "aws_iam_instance_profile" "jenkins_profile" {
  name = "jenkins_profile"
  role = aws_iam_role.jenkins_role.name

  tags = merge(
    {
      cost_code = var.cost_code
    },
    {
      Name = "jenkins-profile"
    }
  )
}

resource "aws_launch_template" "jenkins" {
  name_prefix   = "jenkins-"
  image_id      = data.aws_ami.ubuntu.id
  instance_type = var.instance_type

  network_interfaces {
    associate_public_ip_address = true
    security_groups            = [aws_security_group.jenkins_sg.id]
  }

  iam_instance_profile {
    name = aws_iam_instance_profile.jenkins_profile.name
  }

  user_data = base64encode(templatefile("${path.module}/jenkins-init.sh", {
    efs_id        = aws_efs_file_system.jenkins_data.id
    admin_user    = var.jenkins_admin_user
    admin_password = var.jenkins_admin_password
  }))

  monitoring {
    enabled = true
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(
      {
        cost_code = var.cost_code
      },
      {
        Name = "jenkins-server"
      },
      var.default_tags
    )
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "jenkins" {
  name                = "jenkins-asg"
  desired_capacity    = 1
  max_size            = 1
  min_size            = 1
  target_group_arns   = [aws_lb_target_group.jenkins.arn]
  vpc_zone_identifier = [data.aws_subnet.alb_subnet.id]
  health_check_type   = "ELB"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.jenkins.id
    version = aws_launch_template.jenkins.latest_version
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
      instance_warmup = 300  # 5 minutes to allow Jenkins to start
      checkpoint_delay = 60  # Wait 1 minute between checking instance health
    }
    triggers = ["tag"]  # Only refresh on tag changes, not launch template changes
  }

  tag {
    key                 = "Name"
    value               = "jenkins-server"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}
