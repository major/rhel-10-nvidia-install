variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-2"
}

variable "name_prefix" {
  description = "Name prefix applied to AWS resources."
  type        = string
  default     = "rhel10-nvidia"
}

variable "instance_type" {
  description = "EC2 instance type. Must have an NVIDIA datacenter GPU for rhel-drivers."
  type        = string
  default     = "g6.xlarge"
}

variable "root_volume_size" {
  description = "Root EBS volume size in GiB. CUDA toolkit + drivers need ~15 GiB."
  type        = number
  default     = 40
}

variable "aws_profile" {
  description = <<-EOT
    Named profile in your AWS shared credentials/config to use.
    Set to "" (empty string) to fall back to ambient credentials
    (env vars, instance profile, SSO default, etc.).
  EOT
  type        = string
  default     = "lightspeed"
}

variable "allowed_ssh_cidrs" {
  description = <<-EOT
    CIDRs permitted to SSH to the instance on port 22.
    Default is permissive (0.0.0.0/0) for convenience during bring-up;
    tighten to your office/VPN/home CIDR for anything beyond a smoke test.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "ssh_public_key" {
  description = <<-EOT
    OpenSSH-format public key to install in ec2-user's authorized_keys.
    Use the matching private key locally for SSH.
  EOT
  type        = string
  default     = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDyoH6gU4lgEiSiwihyD0Rxk/o5xYIfA3stVDgOGM9N0"
}

variable "ami_owner" {
  description = "AWS account that owns the RHEL AMIs (309956199498 = Red Hat)."
  type        = string
  default     = "309956199498"
}

variable "ami_name_filter" {
  description = "AMI name pattern for PAYG (Hourly) RHEL 10.x x86_64 GP3."
  type        = string
  default     = "RHEL-10.*HVM-*-x86_64-*-Hourly2-GP3"
}

variable "auto_reboot" {
  description = <<-EOT
    Whether cloud-init should automatically reboot the instance between
    stage 1 (install) and stage 2 (verify). When true, cloud-init runs
    its `power_state` module after `cloud-final.service` finishes cleanly
    and a `/var/lib/rhel-nvidia/stage1.ok` marker is present. When false,
    the operator must run `sudo reboot` to trigger stage 2.

    Set to false for debugging runs where you want the instance to stay
    up after stage 1 fails or completes.
  EOT
  type        = bool
  default     = true
}

variable "tags" {
  description = "Extra tags applied to every resource."
  type        = map(string)
  default     = {}
}
