# rhel-10-nvidia-install

End-to-end NVIDIA driver install on **RHEL 10.1+** in AWS, using the new `rhel-drivers` CLI that ships in RHEL 10.1+ AppStream. cloud-init drives the whole thing end to end, including the reboot between install and verify.

What this does, in order:

1. Terraform brings up a `g6.xlarge` (NVIDIA L4) on the latest PAYG/Hourly RHEL 10.x AMI in `us-east-2`.
2. cloud-init drops two Ansible playbooks, a CUDA smoke test, and a systemd unit onto the host, installs `ansible-core` from AppStream, and runs the install playbook.
3. Install playbook installs `rhel-drivers`, runs `rhel-drivers install nvidia` (signed NVIDIA driver + CUDA toolkit from Red Hat's Extensions/Supplementary repos), and writes `/var/lib/rhel-nvidia/stage1.ok` on success.
4. cloud-init's `power_state` module reboots the instance once `cloud-final.service` exits cleanly and `stage1.ok` exists. Set `auto_reboot = false` to keep the box up for debugging instead.
5. After reboot, `nvidia-verify.service` runs the verify playbook: confirms the `nvidia` kernel module is loaded, runs `nvidia-smi`, compiles and runs a CUDA `vector_add` sample, and writes a final status file.

Reference: [Introducing a new and simplified AI accelerator driver experience in RHEL](https://www.redhat.com/en/blog/introducing-new-and-simplified-ai-accelerator-driver-experience-rhel).

## Prerequisites

- AWS credentials in `~/.aws/credentials` (or equivalent) with permission to manage EC2 in the default VPC of `us-east-2`. The default profile is **`lightspeed`**; override with the `aws_profile` Terraform variable or the `AWS_PROFILE` env var.
- Terraform >= 1.13.0.
- An SSH private key matching the public key in `terraform/variables.tf` (default is the ed25519 key supplied by the project owner). Override `ssh_public_key` to use your own.

### Using a different AWS profile

```sh
# One-off, via the Makefile (also exports it for Terraform):
make apply AWS_PROFILE=my-other-profile

# Or persist it in terraform/terraform.tfvars:
echo 'aws_profile = "my-other-profile"' >> terraform/terraform.tfvars

# Or fall back to ambient credentials (env vars, SSO default, instance role):
echo 'aws_profile = ""' >> terraform/terraform.tfvars
```

## Usage

```sh
make plan          # review what will be created
make apply         # bring up the instance; stage 1 + auto-reboot + stage 2
make outputs       # see public_ip, ssh_command, etc.
make status        # inspect state and verifier journal over SSH
make ssh           # interactive shell on the instance
make verify        # dump /var/lib/rhel-nvidia/status (the final pass/fail)
make destroy       # tear it all down
```

With `auto_reboot = true` (the default), nothing manual is required between stages. `make apply` returns once stage 1 finishes; cloud-init then reboots the instance and `nvidia-verify.service` runs stage 2. Poll `make status` until `/var/lib/rhel-nvidia/status` shows up, then `make verify`.

If you want to inspect the box between stages, set `auto_reboot = false` in `terraform/terraform.tfvars` and run `sudo reboot` (or `make ssh` + `sudo reboot`) yourself once `make status` shows `stage1.ok`.

Expected total time from `make apply` to verified install: **~10-15 minutes** (instance boot + dnf metadata + driver install + auto-reboot + verify playbook + CUDA compile/run).

### Where things land on the instance

| Path | Purpose |
|---|---|
| `/opt/rhel-nvidia/ansible/` | Playbooks + CUDA source dropped by cloud-init |
| `/var/lib/rhel-nvidia/` | State markers (`stage1.ok`, `stage2.started`, `status`, `nvidia-smi.txt`, `vector_add.out`) |
| `/usr/local/bin/rhel-nvidia-status` | Convenience helper printing state markers and verifier journal tail |
| `/etc/systemd/system/nvidia-verify.service` | Oneshot unit for stage 2 |

### Reading success/failure

`make verify` or `ssh ec2-user@<ip> sudo cat /var/lib/rhel-nvidia/status` will print one of:

```text
status: OK
completed: 2026-05-21T17:12:34Z
kernel: 5.14.0-...
```

...or the file will be missing if stage 2 has not finished (or failed). When in doubt, `make status` shows state files and the `nvidia-verify.service` journal tail. If `stage1.ok` exists but `status` is missing after a couple of minutes, the auto-reboot may have been disabled or skipped; reboot the instance manually to start stage 2.

## Cost note

`g6.xlarge` is ~$0.80/hr on-demand in `us-east-2`. Don't forget `make destroy`.

## Caveat: PAYG and RHUI vs CDN repos

`rhel-drivers` pulls the NVIDIA kernel module from the **RHEL Extensions** repo and the CUDA toolkit from **RHEL Supplementary**. On PAYG RHEL via AWS RHUI, those repos *do* exist, but they ship under different IDs and disabled by default:

| Channel | CDN repo ID (BYOS/registered) | RHUI repo ID (PAYG) |
|---|---|---|
| Extensions | `rhel-10-for-x86_64-extensions-rpms` | `rhel-10-extensions-rhui-rpms` |
| Supplementary | `rhel-10-for-x86_64-supplementary-rpms` | `rhel-10-supplementary-rhui-rpms` |

Internally, `rhel-drivers` knows only the CDN IDs and tries to enable them via `subscription-manager`, which is a no-op on an unregistered PAYG box (`manage_repos=0` by default, and the CDN repos aren't reachable anyway). The result is a misleading `error: no drivers available for detected hardware`.

`ansible/install.yml` works around this by enabling the RHUI variants directly with `dnf config-manager --enable rhel-10-extensions-rhui-rpms rhel-10-supplementary-rhui-rpms` before invoking `rhel-drivers install --auto-detect --batch`. The enable task is skipped on AMIs that don't expose those repo IDs (e.g. BYOS), so on a registered BYOS host the standard `subscription-manager repos --enable=...` flow still applies.

You do **not** need to flip `subscription-manager config --rhsm.manage_repos=1` on PAYG. That actually makes things worse: `rhel-drivers` then expects to find the CDN repos, can't, and fails harder.

## Security group

The instance gets a security group that allows SSH (tcp/22) from `var.allowed_ssh_cidrs` (default `0.0.0.0/0`) and all egress. Tighten the CIDR for anything beyond a smoke test, e.g.:

```hcl
# terraform/terraform.tfvars
allowed_ssh_cidrs = ["203.0.113.10/32"]
```

## Layout

```text
.
|-- Makefile
|-- ansible/
|   |-- install.yml          # stage 1: rhel-drivers install nvidia
|   |-- verify.yml           # stage 2: nvidia-smi + CUDA vector_add
|   `-- files/
|       |-- vector_add.cu        # CUDA smoke test
|       `-- nvidia-verify.service
`-- terraform/
    |-- ami.tf               # RHEL 10.x PAYG AMI lookup
    |-- main.tf              # VPC, SG, key pair, EC2 instance
    |-- outputs.tf
    |-- templates/
    |   `-- cloud-init.yaml.tftpl
    |-- terraform.tfvars.example
    |-- user-data.tf
    |-- variables.tf
    `-- versions.tf
```
