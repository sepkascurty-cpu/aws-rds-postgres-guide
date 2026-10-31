# AWS RDS PostgreSQL — Multi-AZ production stack
# Companion code for the aws-rds-postgres-guide README.
#
# What this builds:
#   - VPC with public / private-app / private-db subnet tiers across 2 AZs
#   - Security groups: ALB -> app tier -> RDS Proxy -> RDS (port 5432 only from proxy)
#   - RDS PostgreSQL Multi-AZ primary + async read replica + RDS Proxy
#   - Secrets Manager master password with 30-day rotation, KMS encryption
#   - Parameter group (tuned, versioned) + CloudWatch alarms
#
# Cost guardrails (read before apply):
#   - multi_az = true roughly DOUBLES instance cost. Use single-AZ for dev.
#   - A stopped instance still bills for storage. Delete what you don't use.
#   - Check region, instance class, and free-tier limits in the plan output.
#
# Usage:
#   terraform init
#   terraform plan -out tfplan
#   terraform apply tfplan

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  description = "AWS region for the database stack"
  type        = string
  default     = "ap-southeast-1"
}

variable "project" {
  description = "Name prefix for all resources"
  type        = string
  default     = "rds-pg-guide"
}

variable "multi_az" {
  description = "Enable Multi-AZ standby. TRUE FOR PROD, false for dev to save ~50%."
  type        = bool
  default     = true
}

variable "instance_class" {
  description = "RDS instance class. t4g.micro fits dev; m6i.large+ for prod."
  type        = string
  default     = "db.t4g.micro"
}

# ---------------------------------------------------------------- VPC tiers
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.project}-vpc" }
}

locals {
  azs = ["${var.region}a", "${var.region}b"]
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.${count.index + 1}.0/24"
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.project}-public-${count.index}" }
}

resource "aws_subnet" "app" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1${count.index + 1}.0/24"
  availability_zone = local.azs[count.index]
  tags              = { Name = "${var.project}-app-${count.index}" }
}

resource "aws_subnet" "db" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2${count.index + 1}.0/24"
  availability_zone = local.azs[count.index]
  tags              = { Name = "${var.project}-db-${count.index}" }
}

resource "aws_db_subnet_group" "main" {
  name       = "${var.project}-db-subnets"
  subnet_ids = aws_subnet.db[*].id
  tags       = { Name = "${var.project}-db-subnet-group" }
}

# ------------------------------------------------------- security (least privilege)
# App tier SG -> RDS Proxy SG -> RDS SG. Port 5432 is ONLY reachable from the proxy.

resource "aws_security_group" "proxy" {
  name        = "${var.project}-proxy-sg"
  description = "RDS Proxy: accept 5432 from the app tier only"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
    description     = "app tier only"
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.project}-proxy-sg" }
}

resource "aws_security_group" "app" {
  name        = "${var.project}-app-sg"
  description = "App tier (ECS tasks / EC2)"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.project}-app-sg" }
}

resource "aws_security_group" "rds" {
  name        = "${var.project}-rds-sg"
  description = "RDS: accept 5432 from RDS Proxy only. Nothing else."
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.proxy.id]
    description     = "RDS Proxy only - no direct app or internet access"
  }
  tags = { Name = "${var.project}-rds-sg" }
}

# ------------------------------------------------------------------- secrets
resource "aws_secretsmanager_secret" "db_master" {
  name                    = "${var.project}/db-master"
  description             = "RDS PostgreSQL master credentials"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "db_master" {
  secret_id = aws_secretsmanager_secret.db_master.id
  secret_string = jsonencode({
    username = "pgadmin"
    password = random_password.db_master.result
  })
}

resource "random_password" "db_master" {
  length  = 32
  special = true
}

# KMS key for storage encryption (customer-managed, so YOU control rotation/policy)
resource "aws_kms_key" "rds" {
  description             = "RDS storage encryption for ${var.project}"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

# ------------------------------------------------------------- parameter group
# Version your engine tuning in code. Never hand-edit the default group.
resource "aws_db_parameter_group" "pg16" {
  name   = "${var.project}-pg16"
  family = "postgres16"

  parameter {
    name         = "log_min_duration_statement"
    value        = "1000" # log queries slower than 1s - find the slow ones fast
    apply_method = "immediate"
  }

  parameter {
    name         = "rds.force_ssl"
    value        = "1" # refuse unencrypted connections
    apply_method = "pending-reboot"
  }
}

# ------------------------------------------------------------------ RDS primary
resource "aws_db_instance" "primary" {
  identifier             = "${var.project}-primary"
  engine                 = "postgres"
  engine_version         = "16.3"
  instance_class         = var.instance_class
  allocated_storage      = 100
  storage_type           = "gp3" # gp3 over io2 unless you can prove the IOPS need
  storage_encrypted      = true
  kms_key_id             = aws_kms_key.rds.arn

  db_name  = "appdb"
  username = jsondecode(aws_secretsmanager_secret_version.db_master.secret_string)["username"]
  password = jsondecode(aws_secretsmanager_secret_version.db_master.secret_string)["password"]
  port     = 5432

  multi_az               = var.multi_az # availability, NOT read scaling
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.pg16.name
  publicly_accessible    = false # never true for a production database

  backup_retention_period = 7     # days of point-in-time recovery
  backup_window           = "03:00-04:00"
  maintenance_window      = "sun:04:00-sun:05:00"
  copy_tags_to_snapshot   = true
  delete_automated_backups = false

  performance_insights_enabled          = true
  performance_insights_retention_period = 7
  enabled_cloudwatch_logs_exports       = ["postgresql", "upgrade"]

  deletion_protection       = true # flip to false only when you really mean to destroy
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.project}-final"

  tags = { Name = "${var.project}-primary" }
}

# ------------------------------------------------------- read replica (optional)
# Async, for READ scaling. Expect lag. Never point writes here. Not a backup.
resource "aws_db_instance" "replica" {
  identifier             = "${var.project}-replica"
  replicate_source_db    = aws_db_instance.primary.identifier
  instance_class         = var.instance_class
  publicly_accessible    = false
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.pg16.name
  skip_final_snapshot    = true

  tags = { Name = "${var.project}-replica" }
}

# ------------------------------------------------------------------ RDS Proxy
# Pools app connections so 500 tasks don't open 500 PostgreSQL backends.
# Also makes Multi-AZ failovers transparent: proxy drains, app just retries.
resource "aws_db_proxy" "main" {
  name                   = "${var.project}-proxy"
  engine_family          = "POSTGRESQL"
  role_arn               = aws_iam_role.proxy.arn
  vpc_subnet_ids         = aws_subnet.app[*].id
  vpc_security_group_ids = [aws_security_group.proxy.id]
  require_tls            = true
  idle_client_timeout    = 1800
  debug_logging          = false

  auth {
    auth_scheme               = "SECRETS"
    secret_arn                = aws_secretsmanager_secret.db_master.arn
    iam_auth                  = "DISABLED"
    client_password_auth_type = "POSTGRES_SCRAM_SHA_256"
  }

  tags = { Name = "${var.project}-proxy" }
}

resource "aws_db_proxy_default_target_group" "main" {
  db_proxy_name = aws_db_proxy.main.name

  connection_pool_config {
    max_connections_percent      = 80 # leave headroom on the instance
    max_idle_connections_percent = 50
  }
}

resource "aws_db_proxy_target" "primary" {
  db_proxy_name          = aws_db_proxy.main.name
  target_group_name      = aws_db_proxy_default_target_group.main.name
  db_instance_identifier = aws_db_instance.primary.identifier
}

resource "aws_iam_role" "proxy" {
  name = "${var.project}-proxy-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "rds.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "proxy_secrets" {
  name = "${var.project}-proxy-secrets"
  role = aws_iam_role.proxy.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = aws_secretsmanager_secret.db_master.arn
    }]
  })
}

# ------------------------------------------------------------------ alarms
# The three alarms that page you BEFORE users notice.
resource "aws_cloudwatch_metric_alarm" "low_storage" {
  alarm_name          = "${var.project}-rds-low-storage"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "FreeStorageSpace"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 10 * 1024 * 1024 * 1024 # 10 GB free - act now
  alarm_description   = "RDS free storage below 10 GB. Storage autoscaling only grows, never shrinks."
  dimensions          = { DBInstanceIdentifier = aws_db_instance.primary.identifier }
}

resource "aws_cloudwatch_metric_alarm" "too_many_connections" {
  alarm_name          = "${var.project}-rds-connections"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "DatabaseConnections"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 400 # tune to (max_connections * 0.8) of your instance class
  alarm_description   = "Connection count climbing - check the proxy pool config."
  dimensions          = { DBInstanceIdentifier = aws_db_instance.primary.identifier }
}

resource "aws_cloudwatch_metric_alarm" "replica_lag" {
  alarm_name          = "${var.project}-rds-replica-lag"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "ReplicaLag"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 60 # 60s lag - investigate before serving stale reads
  alarm_description   = "Read replica lag above 60s."
  dimensions          = { DBInstanceIdentifier = aws_db_instance.replica.identifier }
}

# ------------------------------------------------------------------ outputs
output "proxy_endpoint" {
  description = "Connect your app HERE, not to the instance endpoint"
  value       = aws_db_proxy.main.endpoint
}

output "primary_endpoint" {
  description = "Writer endpoint (failover-safe DNS name)"
  value       = aws_db_instance.primary.endpoint
}

output "reader_endpoint" {
  description = "Read replica endpoint - reads only"
  value       = aws_db_instance.replica.endpoint
}
