variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
}

variable "aws_profile" {
  description = "Named AWS CLI profile to authenticate with. Leave null to use the default credential chain (env vars, instance role, etc.)."
  type        = string
  default     = null
}

variable "vpc_id" {
  description = "ID of an existing VPC to deploy into. Read as a data source — never created or modified by this config."
  type        = string
}

variable "subnet_id" {
  description = "ID of a public subnet within vpc_id for the EC2 instance. Must auto-assign public IPs or the instance will be unreachable."
  type        = string
}

variable "key_pair_name" {
  description = "Name for the AWS key pair created for this instance. Use a key pair dedicated to this host so access can be rotated or revoked without affecting anything else."
  type        = string
}

variable "ssh_public_key" {
  description = "OpenSSH-format public key to register as the key pair. Generate the pair locally with ssh-keygen and paste the .pub contents here."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type. Must be an ARM (Graviton) family — the AMI lookup filters on arm64, so an x86 type will fail to launch."
  type        = string
}

variable "domain_name" {
  description = "Fully-qualified domain name to serve the Ghost site on. An A record is created for it in route53_zone_id."
  type        = string
}

variable "app_name" {
  description = "Application name used as the prefix for resource names and tags"
  type        = string
}

variable "environment" {
  description = "Environment name, applied as an Environment tag"
  type        = string
}

variable "route53_zone_id" {
  description = "ID of the Route 53 hosted zone that contains domain_name"
  type        = string
}

variable "allowed_ssh_cidrs" {
  description = "CIDR blocks allowed to SSH in. Nothing deploys to this box from CI, so keep the list to trusted addresses — one /32 per operator."
  type        = list(string)
}

variable "swap_size_gb" {
  description = "Size of the swap file to create on first boot (GB). Recommended on a 1 GB instance so MySQL and Node don't OOM under load."
  type        = number
  default     = 2
}

variable "root_volume_size" {
  description = "Root EBS volume size in GB"
  type        = number
  default     = 20
}
