variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "key_name" {
  description = "Name of the EC2 Key Pair"
  type        = string
  default     = "MyKeyPair"
}

variable "ami_id" {
  description = "AMI ID for EC2 instances"
  type        = string
  default     = "ami-0453ec754f44f9a4a"
}

# --- New tunables ---

# VPC + Subnets
variable "vpc_cidr" {
  description = "CIDR for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDRs for public subnets (index by AZ order)"
  type        = list(string)
  default     = ["10.0.1.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDRs for private subnets (index by AZ order)"
  type        = list(string)
  default     = ["10.0.2.0/24"]
}

# Instance types (single default with optional per-role overrides)
variable "instance_type" {
  description = "Default instance type for EC2 instances"
  type        = string
  default     = "t2.micro"
}

variable "public_instance_type" {
  description = "Override for the public instance type; null -> use instance_type"
  type        = string
  default     = null
}

variable "private_instance_type" {
  description = "Override for the private instance type; null -> use instance_type"
  type        = string
  default     = null
}

variable "jump_box_instance_type" {
  description = "Override for the jump-box instance type; null -> use instance_type"
  type        = string
  default     = null
}

# Tags
variable "name_prefix" {
  description = "Prefix used to build Name tags"
  type        = string
  default     = "FridayHITL"
}

variable "common_tags" {
  description = "Tags applied to all resources (merged with Name)"
  type        = map(string)
  default = {
    Project     = "HITL-Drift"
    Environment = "dev"
  }
}

# (Optional) SG allow lists — keep as tunables if you reference them
variable "allowed_ssh_cidrs" {
  description = "CIDRs allowed for SSH ingress"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "allowed_http_cidrs" {
  description = "CIDRs allowed for HTTP ingress"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
