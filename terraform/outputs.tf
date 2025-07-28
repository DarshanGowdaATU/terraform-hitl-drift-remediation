output "public_instance_ip" {
  description = "Public EC2 instance IP Address"
  value       = aws_instance.public_instance.public_ip
}

output "private_instance_ip" {
  description = "Private EC2 instance IP Address"
  value       = aws_instance.private_instance.private_ip
}

output "jump_box_ip" {
  description = "Jump Box EC2 instance IP Address"
  value       = aws_instance.jump_box_instance.public_ip
}
