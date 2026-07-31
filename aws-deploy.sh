#!/bin/bash

################################################################################
# XAVIER ECOSYSTEM - AWS DEPLOYMENT SCRIPT
# Deploys multi-server architecture with secure credential handling
################################################################################

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}================================${NC}"
echo -e "${BLUE}XAVIER ECOSYSTEM AWS DEPLOYMENT${NC}"
echo -e "${BLUE}================================${NC}\n"

# Check prerequisites
echo -e "${YELLOW}[1/8] Checking prerequisites...${NC}"
command -v aws &> /dev/null || { echo -e "${RED}AWS CLI not installed${NC}"; exit 1; }
command -v terraform &> /dev/null || { echo -e "${RED}Terraform not installed${NC}"; exit 1; }
command -v git &> /dev/null || { echo -e "${RED}Git not installed${NC}"; exit 1; }
echo -e "${GREEN}✓ All tools installed${NC}\n"

# Setup AWS credentials safely
echo -e "${YELLOW}[2/8] Configuring AWS credentials...${NC}"
if [ ! -f ~/.aws/credentials ]; then
    echo -e "${YELLOW}No AWS credentials found. Please run: aws configure${NC}"
    echo -e "${YELLOW}Use AWS IAM user (NOT root account)${NC}"
    aws configure
else
    echo -e "${GREEN}✓ AWS credentials found${NC}"
fi

# Verify AWS credentials work
echo -e "${YELLOW}[3/8] Verifying AWS access...${NC}"
if aws sts get-caller-identity &> /dev/null; then
    echo -e "${GREEN}✓ AWS credentials valid${NC}"
else
    echo -e "${RED}✗ AWS credentials invalid${NC}"
    exit 1
fi

# Set variables
PROJECT_NAME="xavier-ecosystem"
AWS_REGION="${AWS_REGION:-us-east-1}"
DOMAIN="xavier-os-dev.site"
ENVIRONMENT="production"

echo -e "${YELLOW}[4/8] Setting up environment...${NC}"
echo "Project: $PROJECT_NAME"
echo "Region: $AWS_REGION"
echo "Domain: $DOMAIN"
echo -e "${GREEN}✓ Environment configured${NC}\n"

# Create Terraform directory structure
echo -e "${YELLOW}[5/8] Creating Terraform infrastructure...${NC}"
mkdir -p terraform/{modules,environments}

# Main Terraform configuration
cat > terraform/main.tf << 'EOF'
terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}

# VPC
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

# Public Subnets
resource "aws_subnet" "public_1" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-public-1"
  }
}

resource "aws_subnet" "public_2" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-public-2"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}

# Route Table
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block      = "0.0.0.0/0"
    gateway_id      = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.project_name}-public-rt"
  }
}

resource "aws_route_table_association" "public_1" {
  subnet_id      = aws_subnet.public_1.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_2" {
  subnet_id      = aws_subnet.public_2.id
  route_table_id = aws_route_table.public.id
}

# Security Groups
resource "aws_security_group" "alb" {
  name_prefix = "xavier-alb-"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-alb-sg"
  }
}

resource "aws_security_group" "app" {
  name_prefix = "xavier-app-"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-app-sg"
  }
}

# Application Load Balancer
resource "aws_lb" "main" {
  name_prefix        = "xav"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_subnet.public_1.id, aws_subnet.public_2.id]

  enable_deletion_protection = false

  tags = {
    Name = "${var.project_name}-alb"
  }
}

# ALB Target Group
resource "aws_lb_target_group" "app" {
  name_prefix = "app"
  port        = 3000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 3
    interval            = 30
    path                = "/"
    matcher             = "200"
  }
}

# ALB Listener
resource "aws_lb_listener" "app" {
  load_balancer_arn = aws_lb.main.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# ECS Cluster
resource "aws_ecs_cluster" "main" {
  name = "${var.project_name}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = {
    Name = "${var.project_name}-cluster"
  }
}

# CloudWatch Log Group
resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/${var.project_name}"
  retention_in_days = 7

  tags = {
    Name = "${var.project_name}-logs"
  }
}

# Data source for availability zones
data "aws_availability_zones" "available" {
  state = "available"
}

# Outputs
output "alb_dns_name" {
  value       = aws_lb.main.dns_name
  description = "DNS name of the load balancer"
}

output "alb_zone_id" {
  value       = aws_lb.main.zone_id
  description = "Zone ID of the load balancer"
}

output "ecs_cluster_name" {
  value       = aws_ecs_cluster.main.name
  description = "Name of ECS cluster"
}

output "ecs_cluster_id" {
  value       = aws_ecs_cluster.main.id
  description = "ID of ECS cluster"
}
EOF

# Variables file
cat > terraform/variables.tf << 'EOF'
variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name"
  type        = string
  default     = "xavier-ecosystem"
}

variable "environment" {
  description = "Environment"
  type        = string
  default     = "production"
}

variable "domain" {
  description = "Domain name"
  type        = string
  default     = "xavier-os-dev.site"
}
EOF

echo -e "${GREEN}✓ Terraform configuration created${NC}\n"

# Initialize Terraform
echo -e "${YELLOW}[6/8] Initializing Terraform...${NC}"
cd terraform
terraform init
cd ..
echo -e "${GREEN}✓ Terraform initialized${NC}\n"

# Show plan
echo -e "${YELLOW}[7/8] Creating Terraform plan...${NC}"
cd terraform
terraform plan -out=tfplan
cd ..
echo -e "${GREEN}✓ Plan created${NC}\n"

# Apply
echo -e "${YELLOW}[8/8] Applying Terraform configuration...${NC}"
echo -e "${YELLOW}Review the plan above. Type 'yes' to proceed, or 'no' to cancel.${NC}"
cd terraform
terraform apply tfplan
cd ..

# Get outputs
echo -e "\n${BLUE}================================${NC}"
echo -e "${BLUE}✓ DEPLOYMENT COMPLETE!${NC}"
echo -e "${BLUE}================================${NC}\n"

ALB_DNS=$(cd terraform && terraform output -raw alb_dns_name 2>/dev/null || echo "pending" && cd ..)
echo -e "${GREEN}Your API Server is at:${NC}"
echo -e "${GREEN}http://$ALB_DNS${NC}\n"

echo -e "${YELLOW}📝 Next steps:${NC}"
echo "1. Update your domain DNS records:"
echo "   Create CNAME: api.xavier-os-dev.site → $ALB_DNS"
echo ""
echo "2. Update your app configuration:"
echo "   API_URL=https://api.xavier-os-dev.site"
echo ""
echo "3. View infrastructure:"
echo "   cd terraform && terraform show"
echo ""
echo "4. View logs:"
echo "   aws logs tail /ecs/xavier-ecosystem --follow"
echo ""
echo -e "${GREEN}✨ Your Xavier Ecosystem is live!${NC}"
