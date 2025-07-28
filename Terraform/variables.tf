variable "aws_region" {
  default = "us-east-1"
}

variable "key_name" {
  description = "Name of the EC2 Key Pair"
  default     = "MyKeyPair"
}

variable "ami_id" {
  description = "AMI ID for EC2 instances"
  default     = "ami-0453ec754f44f9a4a"
}
