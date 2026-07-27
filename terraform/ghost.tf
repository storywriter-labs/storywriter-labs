# Ghost CMS instance + the AWS "bones" worth version-controlling: SG, EIP, DNS.
# Ghost itself is provisioned manually with ghost-cli after apply (see README).

data "aws_vpc" "selected" {
  id = var.vpc_id
}

data "aws_subnet" "selected" {
  id = var.subnet_id
}

# Latest Ubuntu 24.04 ARM64 AMI. The architecture filter must stay in step with
# var.instance_type — an x86 instance type will not boot this image.
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }
}

# Key pair dedicated to this host, so access can be rotated or revoked without
# touching anything else. The private key stays on your machine; only the public
# half lives here (and never in state as a secret).
resource "aws_key_pair" "ghost" {
  key_name   = var.key_pair_name
  public_key = var.ssh_public_key
}

resource "aws_security_group" "ghost" {
  name        = "${var.app_name}-sg"
  description = "Security group for ${var.app_name} (Ghost CMS)"
  vpc_id      = data.aws_vpc.selected.id

  # SSH — restricted to trusted IPs (Ghost has no CI deploy, so no need to open it wide)
  ingress {
    description = "SSH from trusted sources"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidrs
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
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
    Name        = "${var.app_name}-sg"
    Environment = var.environment
  }
}

resource "aws_eip" "ghost" {
  domain = "vpc"

  tags = {
    Name        = "${var.app_name}-eip"
    Environment = var.environment
  }
}

resource "aws_instance" "ghost" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.ghost.key_name
  subnet_id              = data.aws_subnet.selected.id
  vpc_security_group_ids = [aws_security_group.ghost.id]

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
    encrypted   = true
  }

  # Enforce IMDSv2 to prevent SSRF-based credential theft.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    instance_metadata_tags      = "enabled"
  }

  # Minimal bootstrap: just create a swap file. ghost-cli does everything else.
  user_data = templatefile("${path.module}/user-data.sh", {
    swap_size_gb = var.swap_size_gb
  })

  tags = {
    Name        = var.app_name
    Environment = var.environment
  }
}

resource "aws_eip_association" "ghost" {
  instance_id   = aws_instance.ghost.id
  allocation_id = aws_eip.ghost.id
}

resource "aws_route53_record" "ghost" {
  zone_id = var.route53_zone_id
  name    = var.domain_name
  type    = "A"
  ttl     = 300
  records = [aws_eip.ghost.public_ip]
}
