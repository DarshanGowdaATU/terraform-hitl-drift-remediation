# Availability Zones
data "aws_availability_zones" "available" {}

# -------- Tunable instance types resolved via locals --------
locals {
  public_instance_type  = coalesce(var.public_instance_type,  var.instance_type)
  private_instance_type = coalesce(var.private_instance_type, var.instance_type)
  jump_instance_type    = coalesce(var.jump_box_instance_type, var.instance_type)
  tags_base             = var.common_tags
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
