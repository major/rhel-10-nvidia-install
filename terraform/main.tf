locals {
  common_tags = merge(
    {
      Project   = var.name_prefix
      ManagedBy = "terraform"
    },
    var.tags,
  )
}

# --- Networking: use the default VPC. Public subnet, public IP. ----------

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

resource "aws_security_group" "this" {
  name        = "${var.name_prefix}-sg"
  description = "SSH + egress for ${var.name_prefix}"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidrs
  }

  egress {
    description = "All egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.common_tags
}

# --- SSH key: caller-supplied public key, installed in ec2-user's authkeys

resource "aws_key_pair" "this" {
  key_name   = "${var.name_prefix}-key"
  public_key = var.ssh_public_key
  tags       = local.common_tags
}

# --- The instance --------------------------------------------------------

resource "aws_instance" "this" {
  ami                         = data.aws_ami.rhel.id
  instance_type               = var.instance_type
  key_name                    = aws_key_pair.this.key_name
  subnet_id                   = tolist(data.aws_subnets.default.ids)[0]
  vpc_security_group_ids      = [aws_security_group.this.id]
  associate_public_ip_address = true

  # cloudinit_config renders gzip+base64, so feed it via user_data_base64 to
  # avoid the AWS provider's "value is base64 encoded" warning that fires when
  # an already-encoded blob is handed to user_data.
  user_data_base64 = data.cloudinit_config.this.rendered

  # Any change to the rendered cloud-init payload (i.e. an Ansible playbook
  # edit) MUST force-replace the instance. Without this, terraform performs
  # an in-place stop/update/start cycle that updates the user-data metadata
  # but never re-runs cloud-init, so the new playbook is silently ignored.
  user_data_replace_on_change = true

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size
    delete_on_termination = true
    encrypted             = true
  }

  tags = merge(local.common_tags, {
    Name = var.name_prefix
  })
}
