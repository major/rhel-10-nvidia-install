output "instance_id" {
  description = "EC2 instance ID."
  value       = aws_instance.this.id
}

output "public_ip" {
  description = "Public IPv4 of the instance."
  value       = aws_instance.this.public_ip
}

output "public_dns" {
  description = "Public DNS of the instance."
  value       = aws_instance.this.public_dns
}

output "ami_id" {
  description = "AMI ID resolved for RHEL 10.x PAYG."
  value       = data.aws_ami.rhel.id
}

output "ami_name" {
  description = "AMI name resolved for RHEL 10.x PAYG."
  value       = data.aws_ami.rhel.name
}

output "ssh_command" {
  description = "Ready-to-paste SSH command (assumes your private key is loaded in ssh-agent or default location)."
  value       = "ssh ec2-user@${aws_instance.this.public_ip}"
}

output "verification_help" {
  description = "Commands to check install + verification progress on the instance."
  value = join("\n", [
    "ssh ec2-user@${aws_instance.this.public_ip} 'sudo rhel-nvidia-status'",
    "ssh ec2-user@${aws_instance.this.public_ip} 'sudo cat /var/lib/rhel-nvidia/status'",
    "ssh ec2-user@${aws_instance.this.public_ip} 'sudo nvidia-smi'",
  ])
}
