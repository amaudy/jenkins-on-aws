# Jenkins on AWS with Terraform

This project provisions an AWS infrastructure for Jenkins using Terraform. It sets up Jenkins to run in a Docker container on an EC2 instance managed by an Auto Scaling Group, with persistent data storage using EFS, and HTTPS enabled through ACM.

## Prerequisites

- Terraform installed on your local machine
- AWS account with appropriate permissions to create resources
- A domain name (for DNS and SSL/TLS)

*Note*: The cost code variable is set to "1234" by default, but you can modify it in the `variables.tf` file if needed.

*Note*: The Terraform using local backend is used for simplicity, but you can use S3 or DynamoDB for a more robust solution.

## High-level Architecture

```
                                     AWS Cloud
                                   +----------------------------------------------------------------------------------------+
                                   |                                                                                        |
                                   |            VPC                                                                         |
Internet ----[HTTPS/443]--> ALB    |            +----------------------------------------------------------------+        |
            ----[HTTP/80]----> (public) |            |                                                                |        |
                                  |            |     +-------------+          +-----------------+               |        |
                                  |            |     |             |          |                 |               |        |
                                  |            |     | Jenkins ASG |          |  EFS Storage   |               |        |
                                  |            |     | (public)    |<-------->| (jenkins_home) |               |        |
                                  |            |     |             |          |                 |               |        |
                                  |            |     +-------------+          +-----------------+               |        |
                                  |            |           ^                                                   |        |
                                  |            |           |                                                   |        |
Jenkins Agent ---[50000]------------>----------+           |                                                   |        |
                                  |            |     CloudWatch                                               |        |
                                  |            |     Monitoring                                               |        |
                                  |            |                                                                |        |
                                  |            +----------------------------------------------------------------+        |
                                  |                                                                                        |
                                  +----------------------------------------------------------------------------------------+

Security Groups:
---------------
ALB SG: Allow 80 and 443 from Internet
Jenkins SG: Allow 8080 from ALB SG, 50000 from VPC
EFS SG: Allow NFS from Jenkins SG
```

## Features

- High Availability with Auto Scaling Group
- Persistent storage with EFS
- HTTPS enabled with ACM certificate
- CloudWatch monitoring
- Automated security configuration
- Build agent support

## Components

### Build Agents
Jenkins uses a master-agent architecture to distribute build tasks:

1. **Master Node** (Current Setup):
   - Handles scheduling and job distribution
   - Manages security and authentication
   - Serves the web interface
   - Port 50000 open for agent connections

2. **Build Agents** (Can be added as needed):
   - Execute actual build tasks
   - Can be configured as:
     - EC2 instances
     - Docker containers
     - Kubernetes pods
     - Physical/virtual machines

3. **Connection Methods**:
   - JNLP (Java Web Start)
   - SSH
   - WebSocket
   - Docker API

4. **Benefits**:
   - Distributed builds
   - Parallel execution
   - Environment isolation
   - Scalable build capacity

### Auto Scaling Group
   - Manages EC2 instances running Jenkins
   - Ensures high availability
   - Configured with launch template

2. **Application Load Balancer (ALB)**
   - Routes traffic to Jenkins instances
   - SSL/TLS termination
   - HTTP to HTTPS redirection

3. **Amazon EFS**
   - Persistent storage for Jenkins data
   - Mounted at `/var/jenkins_home`
   - Shared across all ASG instances

4. **Security**
   - ACM certificate for HTTPS
   - Security groups for ALB and EC2
   - VPC-only access for Jenkins agent port

5. **Monitoring**
   - CloudWatch logging enabled
   - EC2 instance monitoring
   - ALB health checks

## Build Agents and Docker Support

### Included Build Agent
This Jenkins setup comes with a pre-configured Docker-based build agent that:
- Runs on the same instance as Jenkins master
- Can build Docker images
- Supports Docker-in-Docker operations
- Auto-scales based on build load

### Using Docker in Pipelines

1. **Basic Pipeline with Docker Agent**:
```groovy
pipeline {
    agent {
        docker {
            image 'jenkins/agent:latest-jdk11'
        }
    }
    stages {
        stage('Build') {
            steps {
                sh 'java -version'
            }
        }
    }
}
```

2. **Building Docker Images**:
```groovy
pipeline {
    agent any
    stages {
        stage('Build Docker Image') {
            steps {
                sh 'docker build -t myapp:latest .'
            }
        }
        stage('Push Image') {
            steps {
                sh 'docker push myapp:latest'
            }
        }
    }
}
```

### Features
- Docker-in-Docker support
- Automatic agent provisioning
- Pipeline support
- Docker image building capability
- Shared Docker daemon with host
- Plugin pre-installation:
  - docker-plugin
  - docker-workflow
  - docker-commons
  - workflow-aggregator
  - git

### Security Notes
- The build agent has access to the host's Docker daemon
- Proper security groups are configured
- Jenkins security is enabled by default
- Agent workspace is isolated

## Build Agent Verification

A verification job named `verify-agent` is automatically created during initialization. This job:

1. **Runs Automatically**:
   - Triggered immediately after Jenkins starts
   - Runs every 30 minutes automatically
   - Can be triggered manually anytime

2. **Verifies Three Components**:
   - Java Build Agent functionality
   - Docker build capability
   - Docker agent functionality

3. **How to Use**:
   - Access Jenkins web interface
   - Go to job `verify-agent`
   - Click "Build Now" to run verification
   - Check console output for results

4. **What it Tests**:
   ```groovy
   // Stage 1: Verifies Java agent
   - Runs Java agent container
   - Checks Java version
   
   // Stage 2: Verifies Docker build
   - Creates test Dockerfile
   - Builds container image
   - Runs container
   - Removes test image
   
   // Stage 3: Verifies Docker agent
   - Runs Docker agent
   - Checks Docker info
   ```

5. **Troubleshooting**:
   If verification fails:
   - Check Docker daemon status
   - Verify Docker socket permissions
   - Review Jenkins agent logs
   - Ensure all required plugins are installed

## Instance Updates and Maintenance

### Update Strategy

The Jenkins instance is managed by an Auto Scaling Group (ASG) with a controlled update strategy:

1. **Launch Template Updates**:
   - When you modify the launch template (e.g., changing user data or AMI):
     ```bash
     # Update launch template and create new version
     terraform apply
     ```
   - Changes don't automatically trigger instance replacement
   - Instances continue running with old configuration

2. **Triggering Instance Refresh**:
   ```bash
   # Option 1: Tag-based trigger
   aws autoscaling tag-resource \
     --resource-id jenkins-asg \
     --tags "Key=refresh,Value=$(date +%s)"

   # Option 2: Manual refresh
   aws autoscaling start-instance-refresh \
     --auto-scaling-group-name jenkins-asg
   ```

3. **Refresh Process**:
   - Maintains 50% minimum healthy capacity
   - Launches new instance with updated configuration
   - Waits 5 minutes for instance warmup
   - Verifies health via ALB health checks
   - Only terminates old instance after new one is healthy

4. **Safety Measures**:
   - No automatic instance replacement
   - Jenkins data persisted on EFS
   - Health checks ensure service availability
   - Rolling update strategy prevents downtime

5. **Monitoring Updates**:
   ```bash
   # Check refresh status
   aws autoscaling describe-instance-refreshes \
     --auto-scaling-group-name jenkins-asg

   # View ASG events
   aws autoscaling describe-scaling-activities \
     --auto-scaling-group-name jenkins-asg
   ```

### When to Update

1. **Security Updates**:
   - New AMI with security patches
   - Updated Jenkins version
   - Configuration changes

2. **Feature Updates**:
   - New plugins or tools
   - Changed initialization script
   - Modified instance type

3. **Troubleshooting**:
   - Instance health issues
   - Configuration problems
   - Performance concerns

### Best Practices

1. **Before Update**:
   - Backup important jobs and configurations
   - Schedule during low-usage periods
   - Test changes in staging if possible
   - Review CloudWatch metrics

2. **During Update**:
   - Monitor instance health
   - Watch CloudWatch logs
   - Check Jenkins availability
   - Verify build agent connectivity

3. **After Update**:
   - Confirm Jenkins is accessible
   - Run verification job
   - Check plugin status
   - Test critical pipelines

## DNS Configuration

The following DNS records need to be configured:

1. **Jenkins ALB Record**
   - Type: `CNAME`
   - Name: `<your-domain>`
   - Value: `<ALB DNS name>`
   - Proxy status: Disabled (grey cloud)

2. **ACM Validation Record**
   - Type: `CNAME`
   - Name: `_<validation>.<domain>`
   - Value: `<ACM validation value>`
   - Proxy status: Disabled (grey cloud)

## Project Structure

- `provider.tf`: Configures the AWS provider.
- `variables.tf`: Contains variable definitions for the project.
- `vpc.tf`: Uses the default VPC and subnets for the setup.
- `security.tf`: Defines security groups for the Jenkins server and EFS.
- `efs.tf`: Provisions an EFS file system for Jenkins data.
- `ec2.tf`: Configures the EC2 instance to run Jenkins.
- `jenkins-init.sh`: User data script for initializing Jenkins.
- `.gitignore`: Specifies files to ignore in version control.

## Setup Instructions

```bash
export AWS_PROFILE=your-profile
export AWS_REGION=us-east-1
```

1. Clone the repository:
   ```bash
   git clone <repository-url>
   cd <repository-directory>
   ```

2. Initialize Terraform:
   ```bash
   terraform init
   ```

3. Create `terraform.tfvars` file with your Jenkins admin password:
   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```
   Edit `terraform.tfvars` and set a secure password that meets these requirements:
   - At least 8 characters
   - Contains uppercase letters
   - Contains lowercase letters
   - Contains numbers
   - Contains special characters

4. Review the changes:
   ```bash
   terraform plan
   ```

5. Apply the changes:
   ```bash
   terraform apply
   ```

6. After applying, configure the DNS records using the outputs.

7. Access Jenkins at `https://<your-domain>`

## Initial Setup and Access

### Jenkins Admin Credentials
The Jenkins instance is automatically configured with secure admin credentials. You need to:

1. Create your `terraform.tfvars` file:
   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```

2. Edit `terraform.tfvars` to set your admin password. The password must meet these security requirements:
   - Minimum 8 characters
   - At least one uppercase letter
   - At least one lowercase letter
   - At least one number
   - At least one special character

   Example `terraform.tfvars`:
   ```hcl
   jenkins_admin_user     = "admin"
   jenkins_admin_password = "YourSecurePassword123!"  # Replace with your secure password
   ```

### What to Expect After Deployment

1. **Initial Access**:
   - Jenkins URL: `https://<your-domain>` (from ALB DNS or your custom domain)
   - Username: The value of `jenkins_admin_user` (default: "admin")
   - Password: The value you set in `jenkins_admin_password`

2. **DNS Configuration**:
   - Create a CNAME record pointing to the ALB DNS name
   - Add ACM certificate validation CNAME record (details provided in Terraform output)
   - Wait for SSL certificate validation (usually 5-15 minutes)

## Usage

1. Initialize Terraform:
   ```bash
   terraform init
   ```

2. Configure your domain and SSL:
   - Set your domain in variables
   - Request ACM certificate
   - Configure DNS records (see DNS Configuration section)

3. Create `terraform.tfvars` file with your Jenkins admin password:
   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```
   Edit `terraform.tfvars` and set a secure password that meets these requirements:
   - At least 8 characters
   - Contains uppercase letters
   - Contains lowercase letters
   - Contains numbers
   - Contains special characters

4. Review the changes:
   ```bash
   terraform plan
   ```

5. Apply the changes:
   ```bash
   terraform apply
   ```

6. After applying:
   - Note the ALB DNS name from the outputs
   - Configure your DNS records
   - Wait for SSL certificate validation

7. Access Jenkins:
   - Open `https://<your-domain>` in your browser
   - Log in with your configured credentials
   - Change your password after first login

## Cleanup

To remove all resources created by Terraform, run:
```bash
terraform destroy
```

*Note*: Make sure to back up any important Jenkins data before destroying the infrastructure.

## License

This project is licensed under the MIT License.
