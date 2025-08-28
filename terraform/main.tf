# Availability Zones
data "aws_availability_zones" "available" {}

# Extra data for S3 naming
data "aws_caller_identity" "this" {}
data "aws_region" "this" {}

# -------- Tunable instance types resolved via locals --------
locals {
  public_instance_type  = coalesce(var.public_instance_type,  var.instance_type)
  private_instance_type = coalesce(var.private_instance_type, var.instance_type)
  jump_instance_type    = coalesce(var.jump_box_instance_type, var.instance_type)
  tags_base             = var.common_tags
}

# Deterministic, globally-unique bucket name (uses .id to avoid deprecated "name")
locals {
  private_bucket_name = lower("${var.name_prefix}-${data.aws_caller_identity.this.account_id}-${data.aws_region.this.id}-private")
}

# ---------------- VPC + IGW ----------------
resource "aws_vpc" "friday_hitt_vpc" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.tags_base, {
    Name = "${var.name_prefix}-vpc"
  })
}

resource "aws_internet_gateway" "friday_hitt_igw" {
  vpc_id = aws_vpc.friday_hitt_vpc.id

  tags = merge(local.tags_base, {
    Name = "${var.name_prefix}-igw"
  })
}

# ---------------- Subnets ----------------
resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.friday_hitt_vpc.id
  cidr_block              = var.public_subnet_cidrs[0]
  map_public_ip_on_launch = true
  availability_zone       = data.aws_availability_zones.available.names[0]

  tags = merge(local.tags_base, {
    Name = "${var.name_prefix}-public-a"
  })
}

resource "aws_subnet" "private_subnet" {
  vpc_id            = aws_vpc.friday_hitt_vpc.id
  cidr_block        = var.private_subnet_cidrs[0]
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = merge(local.tags_base, {
    Name = "${var.name_prefix}-private-a"
  })
}

# ---------------- Routing ----------------
resource "aws_route_table" "public_route_table" {
  vpc_id = aws_vpc.friday_hitt_vpc.id

  tags = merge(local.tags_base, {
    Name = "${var.name_prefix}-public-rt"
  })
}

resource "aws_route" "public_route" {
  route_table_id         = aws_route_table.public_route_table.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.friday_hitt_igw.id
}

resource "aws_route_table_association" "public_subnet_association" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_route_table.id
}

# ---------------- Security Groups ----------------
resource "aws_security_group" "public_ec2_sg" {
  vpc_id = aws_vpc.friday_hitt_vpc.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidrs
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.allowed_http_cidrs
  }

  tags = merge(local.tags_base, {
    Name = "${var.name_prefix}-sg-public"
  })
}

resource "aws_security_group" "private_ec2_sg" {
  vpc_id = aws_vpc.friday_hitt_vpc.id

  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.public_ec2_sg.id]
  }

  tags = merge(local.tags_base, {
    Name = "${var.name_prefix}-sg-private"
  })
}

# ---------------- EC2 Instances ----------------
resource "aws_instance" "public_instance" {
  ami           = var.ami_id
  instance_type = local.public_instance_type
  key_name      = var.key_name

  subnet_id                   = aws_subnet.public_subnet.id
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.public_ec2_sg.id]

  tags = merge(local.tags_base, {
    Name = "${var.name_prefix}-public"
  })
}

resource "aws_instance" "private_instance" {
  ami           = var.ami_id
  instance_type = local.private_instance_type
  key_name      = var.key_name

  subnet_id              = aws_subnet.private_subnet.id
  vpc_security_group_ids = [aws_security_group.private_ec2_sg.id]

  tags = merge(local.tags_base, {
    Name = "${var.name_prefix}-private"
  })
}

# Jump box (kept minimal, just made tunable)
resource "aws_instance" "jump_box_instance" {
  ami           = var.ami_id
  instance_type = local.jump_instance_type

  tags = merge(local.tags_base, {
    Name = "${var.name_prefix}-jump"
  })
}

# ================================
# Private S3 bucket (locked down)
# ================================
resource "aws_s3_bucket" "private_data" {
  bucket = local.private_bucket_name

  tags = merge(local.tags_base, {
    Name = "${var.name_prefix}-s3-private"
  })
}

# Disable ACLs (bucket-owner enforced)
resource "aws_s3_bucket_ownership_controls" "private_data" {
  bucket = aws_s3_bucket.private_data.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Block all public access
resource "aws_s3_bucket_public_access_block" "private_data" {
  bucket                  = aws_s3_bucket.private_data.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Versioning
resource "aws_s3_bucket_versioning" "private_data" {
  bucket = aws_s3_bucket.private_data.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Default SSE (AES256)
resource "aws_s3_bucket_server_side_encryption_configuration" "private_data" {
  bucket = aws_s3_bucket.private_data.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# TLS-only policy (deny non-HTTPS)
resource "aws_s3_bucket_policy" "private_data_tls_only" {
  bucket = aws_s3_bucket.private_data.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid       = "DenyInsecureTransport",
        Effect    = "Deny",
        Principal = "*",
        Action    = "s3:*",
        Resource  = [
          aws_s3_bucket.private_data.arn,
          "${aws_s3_bucket.private_data.arn}/*"
        ],
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      }
    ]
  })
}

# ================================
# IAM user: Developer
# ================================
resource "aws_iam_user" "developer" {
  name = "Developer"

  tags = merge(local.tags_base, {
    Name = "${var.name_prefix}-user-developer"
  })
}
