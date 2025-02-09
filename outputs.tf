# Output the EFS ID for reference
output "efs_id" {
  description = "ID of the EFS file system"
  value       = aws_efs_file_system.jenkins_data.id
}
