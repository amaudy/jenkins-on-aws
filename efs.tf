resource "aws_efs_file_system" "jenkins_data" {
  creation_token = "jenkins-data"
  encrypted      = true

  tags = merge(
    {
      cost_code = var.cost_code
    },
    {
      Name = "jenkins-data"
    }
  )

  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }
}

# Enable EFS backup
resource "aws_efs_backup_policy" "policy" {
  file_system_id = aws_efs_file_system.jenkins_data.id

  backup_policy {
    status = "ENABLED"
  }
}

resource "aws_efs_mount_target" "jenkins_efs_mount" {
  file_system_id  = aws_efs_file_system.jenkins_data.id
  subnet_id       = data.aws_subnet.default.id
  security_groups = [aws_security_group.efs_sg.id]


}

resource "aws_security_group" "efs_sg" {
  name        = "jenkins-efs-sg"
  description = "Security group for EFS mount target"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.jenkins_sg.id]
  }

  tags = merge(
    {
      cost_code = var.cost_code
    },
    {
      Environment = "dev"
      Application = "jenkins"
    }
  )
}
