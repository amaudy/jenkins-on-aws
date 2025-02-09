#!/bin/bash
set -e  # Exit on any error

# Function to log messages
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
    logger -t jenkins-init "$1"  # Also log to syslog
}

# Function to check service status
check_service() {
    if ! systemctl is-active --quiet $1; then
        log "ERROR: $1 failed to start"
        systemctl status $1
        return 1
    fi
    log "$1 is running"
    return 0
}

# Function to check system resources
check_resources() {
    # Check available memory
    local total_mem=$(free -g | awk '/^Mem:/{print $2}')
    if [ "$total_mem" -lt 6 ]; then  # We want at least 6GB for t3.large
        log "ERROR: Insufficient memory. Found $total_mem GB, need at least 6GB"
        return 1
    fi
    
    # Check available disk space
    local free_space=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
    if [ "$free_space" -lt 10 ]; then  # We want at least 10GB free
        log "ERROR: Insufficient disk space. Found $free_space GB free, need at least 10GB"
        return 1
    fi
    
    log "System resources check passed"
    return 0
}

# Configure apt to prefer IPv4
log "Configuring apt to prefer IPv4..."
echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4

# Update system
log "Updating system..."
apt-get update
apt-get upgrade -y

# Install required packages
log "Installing required packages..."
apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    software-properties-common \
    nfs-common \
    unzip \
    jq

# Install Docker
log "Installing Docker..."
curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh

# Wait for Docker to start
log "Waiting for Docker to start..."
systemctl start docker
for i in {1..30}; do
    if systemctl is-active --quiet docker; then
        break
    fi
    log "Waiting for Docker service... ($i/30)"
    sleep 2
done
check_service docker || exit 1

# Install CloudWatch agent
log "Installing CloudWatch agent..."
wget https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb
dpkg -i amazon-cloudwatch-agent.deb
rm amazon-cloudwatch-agent.deb

# Configure CloudWatch agent
log "Configuring CloudWatch agent..."
mkdir -p /opt/aws/amazon-cloudwatch-agent/etc/
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<'EOF'
{
    "agent": {
        "metrics_collection_interval": 60,
        "run_as_user": "root",
        "region": "us-east-1"
    },
    "metrics": {
        "metrics_collected": {
            "disk": {
                "measurement": ["used_percent"],
                "resources": ["/"],
                "drop_device": true
            },
            "mem": {
                "measurement": ["mem_used_percent"]
            },
            "swap": {
                "measurement": ["swap_used_percent"]
            }
        },
        "append_dimensions": {
            "InstanceId": "$${aws:InstanceId}"
        }
    },
    "logs": {
        "logs_collected": {
            "files": {
                "collect_list": [
                    {
                        "file_path": "/var/log/syslog",
                        "log_group_name": "/jenkins/system/syslog",
                        "log_stream_name": "{instance_id}",
                        "timestamp_format": "%b %d %H:%M:%S"
                    },
                    {
                        "file_path": "/jenkins_home/jenkins.log",
                        "log_group_name": "/jenkins/application/jenkins",
                        "log_stream_name": "{instance_id}",
                        "timestamp_format": "%Y-%m-%d %H:%M:%S"
                    },
                    {
                        "file_path": "/var/log/docker/jenkins.log",
                        "log_group_name": "/jenkins/docker/jenkins",
                        "log_stream_name": "{instance_id}",
                        "timestamp_format": "%Y-%m-%d %H:%M:%S"
                    }
                ]
            }
        }
    }
}
EOF

# Create log directories
mkdir -p /var/log/docker
mkdir -p /var/log/jenkins

# Start CloudWatch agent
log "Starting CloudWatch agent..."
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a start
systemctl enable amazon-cloudwatch-agent
systemctl start amazon-cloudwatch-agent
check_service amazon-cloudwatch-agent || exit 1

# Mount EFS
log "Mounting EFS..."
mkdir -p /jenkins_home

# Try DNS-based mount first
log "Attempting DNS-based mount..."
if mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport ${efs_id}.efs.us-east-1.amazonaws.com:/ /jenkins_home; then
    log "EFS mounted successfully via DNS"
else
    # If DNS fails, try IP-based mount
    log "DNS-based mount failed, trying IP-based mount..."
    if mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport 172.31.8.141:/ /jenkins_home; then
        log "EFS mounted successfully via IP"
    else
        log "ERROR: Failed to mount EFS via both DNS and IP"
        exit 1
    fi
fi

# Add EFS mount to fstab using IP address for reliability
echo "172.31.8.141:/ /jenkins_home nfs4 nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport 0 0" >> /etc/fstab

# Set permissions after mounting
chown -R 1000:1000 /jenkins_home
chmod -R 755 /jenkins_home

# Configure Docker logging
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<EOF
{
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "10m",
        "max-file": "3"
    }
}
EOF

# Pull Jenkins image with verification
log "Pulling Jenkins Docker image..."
if ! docker pull jenkins/jenkins:lts; then
    log "ERROR: Failed to pull Jenkins Docker image"
    exit 1
fi
log "Jenkins image pulled successfully"

# Create Jenkins configuration
mkdir -p /jenkins_home/init.groovy.d
cat > /jenkins_home/init.groovy.d/basic-security.groovy <<EOF
#!groovy

import jenkins.model.*
import hudson.security.*
import jenkins.security.s2m.AdminWhitelistRule
import hudson.model.*
import hudson.plugins.sshslaves.*
import hudson.slaves.*
import hudson.plugins.sshslaves.verifiers.*

def instance = Jenkins.getInstance()

// Create admin user
def hudsonRealm = new HudsonPrivateSecurityRealm(false)
hudsonRealm.createAccount("${admin_user}", "${admin_password}")
instance.setSecurityRealm(hudsonRealm)

def strategy = new FullControlOnceLoggedInAuthorizationStrategy()
strategy.setAllowAnonymousRead(false)
instance.setAuthorizationStrategy(strategy)

// Configure Docker Cloud
import com.nirima.jenkins.plugins.docker.*
import com.nirima.jenkins.plugins.docker.launcher.*
import com.nirima.jenkins.plugins.docker.strategy.*

def dockerCloud = new DockerCloud(
    "docker-local",
    [
        new DockerTemplate(
            new DockerTemplateBase(
                "jenkins/agent:latest-jdk11",
                "",
                "docker",
                "/home/jenkins/agent",
                "jenkins",
                "",
                "",
                "",
                "1",
                "1",
                "1"
            ),
            new DockerComputerAttachConnector(),
            "docker-agent",
            "/home/jenkins/agent",
            "1"
        )
    ],
    "unix:///var/run/docker.sock",
    "",
    "",
    "",
    "100",
    5,
    0,
    600
)

instance.clouds.add(dockerCloud)

// Save configuration
instance.save()

Jenkins.instance.getInjector().getInstance(AdminWhitelistRule.class).setMasterKillSwitch(false)
EOF

# Create Jenkins plugins list
cat > /jenkins_home/plugins.txt <<EOF
docker-plugin:1.5
docker-workflow:563.vd5d2e5c4007f
docker-commons:419.v8e3cd84ef49c
workflow-aggregator:590.v6a_d052e5a_a_b_5
git:5.2.0
EOF

# Create systemd service file for Jenkins
log "Creating Jenkins service..."
cat > /etc/systemd/system/jenkins.service <<EOF
[Unit]
Description=Jenkins Docker Container
Requires=docker.service
After=docker.service network.target remote-fs.target

[Service]
Restart=always
RestartSec=10
ExecStartPre=/bin/bash -c 'until docker info; do sleep 1; done'
ExecStartPre=-/usr/bin/docker stop jenkins
ExecStartPre=-/usr/bin/docker rm jenkins
ExecStart=/usr/bin/docker run --name jenkins \
    -p 8080:8080 -p 50000:50000 \
    -v /jenkins_home:/var/jenkins_home \
    --log-driver=json-file \
    --log-opt max-size=10m \
    --log-opt max-file=3 \
    --user jenkins \
    --memory=2g \
    --memory-reservation=1.5g \
    --health-cmd="curl -f http://localhost:8080/login || exit 1" \
    --health-interval=30s \
    --health-timeout=10s \
    --health-retries=3 \
    jenkins/jenkins:lts
ExecStop=/usr/bin/docker stop jenkins
ExecStopPost=/usr/bin/docker rm jenkins

[Install]
WantedBy=multi-user.target
EOF

# Enable and start Jenkins service
log "Starting Jenkins service..."
systemctl daemon-reload
systemctl enable jenkins
systemctl start jenkins

# Wait for Jenkins to be fully initialized
log "Waiting for Jenkins to initialize..."
INIT_TIMEOUT=300  # 5 minutes timeout
start_time=$(date +%s)
while true; do
    if curl -s -f http://localhost:8080/login > /dev/null; then
        log "Jenkins is responding to HTTP requests"
        break
    fi
    
    current_time=$(date +%s)
    if [ $((current_time - start_time)) -gt $INIT_TIMEOUT ]; then
        log "ERROR: Jenkins failed to initialize after $INIT_TIMEOUT seconds"
        exit 1
    fi
    
    log "Waiting for Jenkins to become available... $(($INIT_TIMEOUT - $current_time + $start_time))s remaining"
    sleep 10
done

check_service jenkins || exit 1
log "Initialization complete!"

# Install required plugins
JENKINS_HOME=/jenkins_home
JENKINS_URL=http://localhost:8080
JENKINS_CRUMB=$(curl -s "$${JENKINS_URL}/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,\":\",//crumb)")
JENKINS_TOKEN=$(cat $${JENKINS_HOME}/secrets/initialAdminPassword)

while read plugin; do
    curl -X POST -H "$${JENKINS_CRUMB}" --user "admin:$${JENKINS_TOKEN}" \
        --data "<jenkins><install plugin=\"$${plugin}\"/></jenkins>" \
        --header 'Content-Type: text/xml' \
        "$${JENKINS_URL}/pluginManager/installNecessaryPlugins"
done < /jenkins_home/plugins.txt

# Restart Jenkins to apply plugins
docker restart jenkins

# Create verification job
cat > /var/jenkins_home/init.groovy.d/create-test-job.groovy <<'EOF'
import jenkins.model.*
import org.jenkinsci.plugins.workflow.cps.*
import org.jenkinsci.plugins.workflow.job.WorkflowJob
import org.jenkinsci.plugins.workflow.job.WorkflowDefinition
import hudson.model.*

def jenkins = Jenkins.getInstance()

// Create "verify-agent" job
def jobName = "verify-agent"
def job = jenkins.getItem(jobName)
if (job == null) {
    def flowDefinition = new CpsFlowDefinition('''
pipeline {
    stages {
        stage('Verify Java Agent') {
            agent {
                docker {
                    image 'jenkins/agent:latest-jdk11'
                    args '-v /var/run/docker.sock:/var/run/docker.sock'
                }
            }
            steps {
                sh 'java -version'
                sh 'echo "Java agent is working"'
            }
        }
        
        stage('Verify Docker Build') {
            agent any
            steps {
                // Create a test Dockerfile
                writeFile file: 'Dockerfile', text: """
                    FROM alpine:latest
                    RUN echo 'Test container' > /test.txt
                    CMD cat /test.txt
                """
                
                // Build and test Docker image
                sh '''
                    docker build -t test-image:latest .
                    docker run --rm test-image:latest
                    docker rmi test-image:latest
                '''
                
                echo "Docker build capability verified"
            }
        }
        
        stage('Verify Docker Agent') {
            agent {
                docker {
                    image 'docker:dind'
                    args '-v /var/run/docker.sock:/var/run/docker.sock'
                }
            }
            steps {
                sh 'docker info'
                echo "Docker agent is working"
            }
        }
    }
    
    post {
        success {
            echo "All verifications passed! Build agent is ready."
        }
    }
}
''', true)
    
    def job = new WorkflowJob(jenkins, jobName)
    job.definition = flowDefinition
    
    // Set job properties
    job.addProperty(new ParametersDefinitionProperty([
        new StringParameterDefinition("DESCRIPTION", "Verifies build agent functionality", "Job to verify build agent and Docker capabilities")
    ]))
    
    // Save the job
    jenkins.add(job, jobName)
    
    // Schedule the job to run periodically
    def trigger = new hudson.triggers.TimerTrigger("H/30 * * * *")  // Run every 30 minutes
    job.addTrigger(trigger)
}

// Save configuration
jenkins.save()
EOF

# Wait for Jenkins to start and trigger the verification job
sleep 30
curl -X POST -H "$${JENKINS_CRUMB}" --user "admin:$${JENKINS_TOKEN}" \
    "$${JENKINS_URL}/job/verify-agent/build"

echo "Verification job created and triggered"

echo "Jenkins setup completed"
