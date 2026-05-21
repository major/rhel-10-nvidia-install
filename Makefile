SHELL := /bin/sh
TF    := terraform -chdir=terraform

# Use AWS_PROFILE from the environment if set; otherwise default to the
# project's "lightspeed" profile. Override on the command line:
#   make apply AWS_PROFILE=other-profile
AWS_PROFILE ?= lightspeed
export AWS_PROFILE

.PHONY: help init fmt validate plan apply destroy outputs ssh status verify lint clean

help:
	@echo "Targets:"
	@echo "  init      - terraform init"
	@echo "  fmt       - terraform fmt -recursive"
	@echo "  validate  - terraform validate (after init)"
	@echo "  plan      - terraform plan"
	@echo "  apply     - terraform apply -auto-approve"
	@echo "  destroy   - terraform destroy -auto-approve"
	@echo "  outputs   - terraform output"
	@echo "  ssh       - SSH to the instance"
	@echo "  status    - run rhel-nvidia-status on the instance"
	@echo "  verify    - dump /var/lib/rhel-nvidia/status from instance"
	@echo "  lint      - terraform fmt -check + yamllint on ansible/"
	@echo "  clean     - remove local terraform state cache (.terraform/)"

init:
	$(TF) init -upgrade

fmt:
	$(TF) fmt -recursive

validate: init
	$(TF) validate

plan: init
	$(TF) plan

apply: init
	$(TF) apply -auto-approve

destroy:
	$(TF) destroy -auto-approve

outputs:
	$(TF) output

# Quick SSH using the public IP output. Assumes your private key is in
# ssh-agent or one of the default locations (e.g., ~/.ssh/id_ed25519).
ssh:
	@ip=$$($(TF) output -raw public_ip); ssh -o StrictHostKeyChecking=accept-new ec2-user@$$ip

status:
	@ip=$$($(TF) output -raw public_ip); ssh -o StrictHostKeyChecking=accept-new ec2-user@$$ip sudo /usr/local/bin/rhel-nvidia-status

verify:
	@ip=$$($(TF) output -raw public_ip); ssh -o StrictHostKeyChecking=accept-new ec2-user@$$ip sudo cat /var/lib/rhel-nvidia/status

lint:
	$(TF) fmt -check -recursive
	yamllint ansible/

clean:
	rm -rf terraform/.terraform terraform/.terraform.lock.hcl
