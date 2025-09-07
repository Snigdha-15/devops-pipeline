############################################
# Terraform + Provider
############################################
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

############################################
# Data Sources (Default VPC, Subnets, AMI)
############################################
data "aws_vpc" "default" {
  default = true
}

# Provider v5+ subnets data source; grab default subnets in the default VPC
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

# Amazon Linux 2 x86_64 (works with amazon-linux-extras for Docker)
data "aws_ami" "al2" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

############################################
# Security Group (HTTP 80 + optional SSH 22)
############################################
resource "aws_security_group" "web_sg" {
  name_prefix           = "web-sg-"                       # avoids name collision so new SG can be created first
  description           = "Allow HTTP and SSH inbound traffic"
  vpc_id                = data.aws_vpc.default.id
  revoke_rules_on_delete = true                            # ensures rules are revoked so delete succeeds

  lifecycle {
    create_before_destroy = true                           # <-- key to avoid the stall
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "web-sg" }
}

############################################
# IAM for EC2: SSM + CloudWatch Agent
############################################
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "ec2_role" {
  name               = "DevOpsWebApp-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cw_agent" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "DevOpsWebApp-ec2-profile"
  role = aws_iam_role.ec2_role.name
}

############################################
# EC2 Instance (Free Tier–eligible micro)
############################################
resource "aws_instance" "web" {
  ami                         = data.aws_ami.al2.id
  instance_type               = var.instance_type # e.g., t3.micro
  subnet_id                   = element(data.aws_subnets.default.ids, 0)
  vpc_security_group_ids      = [aws_security_group.web_sg.id]
  key_name                    = var.key_name # e.g., "snigdha-key"
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.ec2_profile.name

  # SSM + CloudWatch Agent + Docker + your container
  user_data = <<-EOT
    #!/bin/bash
    set -eux

    # System + Docker
    yum update -y
    amazon-linux-extras install -y docker
    systemctl enable docker
    systemctl start docker
    usermod -aG docker ec2-user

    # Ensure SSM agent is running (preinstalled on AL2)
    systemctl enable amazon-ssm-agent || true
    systemctl start amazon-ssm-agent || true

    # Install CloudWatch Agent
    CW_RPM="/tmp/cw.rpm"
    curl -fsSL -o "$CW_RPM" https://s3.amazonaws.com/amazoncloudwatch-agent/amazon_linux/amd64/latest/amazon-cloudwatch-agent.rpm
    rpm -Uvh "$CW_RPM" || true

    # CloudWatch config: Docker logs + CPU/Mem metrics
    cat >/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<'JSON'
    {
      "agent": { "metrics_collection_interval": 30 },
      "logs": {
        "logs_collected": {
          "files": {
            "collect_list": [
              {
                "file_path": "/var/lib/docker/containers/*/*-json.log",
                "log_group_name": "/DevOpsWebApp/app",
                "log_stream_name": "{instance_id}-docker",
                "timestamp_format": "%Y-%m-%dT%H:%M:%S.%fZ"
              }
            ]
          }
        }
      },
      "metrics": {
        "namespace": "DevOpsWebApp/EC2",
        "append_dimensions": { "InstanceId": "$${instance_id}" },
        "metrics_collected": {
          "mem": { "measurement": ["mem_used_percent"], "metrics_collection_interval": 30 },
          "cpu": { "measurement": ["cpu_usage_user","cpu_usage_system","cpu_usage_idle"], "metrics_collection_interval": 30 }
        }
      }
    }
    JSON

    /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
      -a fetch-config -m ec2 \
      -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json -s

    # Your app container
    docker pull snigdha415/devops-app:latest
    docker rm -f devops_app_container || true
    docker run -d --name devops_app_container --restart always -p 80:5000 snigdha415/devops-app:latest
  EOT

  tags = { Name = "DevOpsWebApp" }
}

############################################
# Outputs
############################################
output "ec2_public_ip" {
  value = aws_instance.web.public_ip
}

output "connect_command" {
  value = "ssh -i ${var.key_name}.pem ec2-user@${aws_instance.web.public_ip}"
}

output "app_url" {
  value = "http://${aws_instance.web.public_dns}"
}
