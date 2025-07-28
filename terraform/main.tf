# Availability Zones
data "aws_availability_zones" "available" {}


# VPC
resource "aws_vpc" "friday_hitt_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "FridayHITT-VPC"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "friday_hitt_igw" {
  vpc_id = aws_vpc.friday_hitt_vpc.id

  tags = {
    Name = "FridayHITT-IGW"
  }
}

# Public Subnet
resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.friday_hitt_vpc.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = data.aws_availability_zones.available.names[0]

  tags = {
    Name = "Public-Subnet"
  }
}

# Private Subnet
resource "aws_subnet" "private_subnet" {
  vpc_id            = aws_vpc.friday_hitt_vpc.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = {
    Name = "Private-Subnet"
  }
}

# Public Route Table
resource "aws_route_table" "public_route_table" {
  vpc_id = aws_vpc.friday_hitt_vpc.id

  tags = {
    Name = "Public-Route-Table"
  }
}

# Route to Internet
resource "aws_route" "public_route" {
  route_table_id         = aws_route_table.public_route_table.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.friday_hitt_igw.id
}

# Associate Public Subnet with Route Table
resource "aws_route_table_association" "public_subnet_association" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_route_table.id
}

# Security Group for Public EC2
resource "aws_security_group" "public_ec2_sg" {
  vpc_id = aws_vpc.friday_hitt_vpc.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "Public-EC2-SG"
  }
}

# Security Group for Private EC2
resource "aws_security_group" "private_ec2_sg" {
  vpc_id = aws_vpc.friday_hitt_vpc.id

  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.public_ec2_sg.id]
  }

  tags = {
    Name = "Private-EC2-SG"
  }
}

# Public EC2 Instance
resource "aws_instance" "public_instance" {
  ami           = var.ami_id
  instance_type = "t2.micro"
  key_name      = var.key_name

  subnet_id                   = aws_subnet.public_subnet.id
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.public_ec2_sg.id]

  tags = {
    Name = "Public-EC2-Instance"
  }
}

# Private EC2 Instance
resource "aws_instance" "private_instance" {
  ami           = var.ami_id
  instance_type = "t2.micro"
  key_name      = var.key_name

  subnet_id              = aws_subnet.private_subnet.id
  vpc_security_group_ids = [aws_security_group.private_ec2_sg.id]

  tags = {
    Name = "Private-EC2-Instance"
  }
}

resource "aws_instance" "jump_box_instance" {
  ami           = "ami-0453ec754f44f9a4a"  
  instance_type = "t2.micro"
  
  tags = {
    Name = "Jump-Box"
  }
}


