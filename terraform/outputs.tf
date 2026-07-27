output "instance_id" {
  description = "EC2 instance ID for the Ghost server"
  value       = aws_instance.ghost.id
}

output "public_ip" {
  description = "Elastic IP attached to the Ghost server"
  value       = aws_eip.ghost.public_ip
}

output "domain_name" {
  description = "Domain the Ghost site is served on"
  value       = var.domain_name
}

output "ssh_command" {
  description = "Convenience SSH command (uses the locally-generated private key)"
  value       = "ssh -i ~/.ssh/${var.key_pair_name} ubuntu@${aws_eip.ghost.public_ip}"
}
