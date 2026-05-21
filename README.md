# rhel-10-nvidia-install

End-to-end NVIDIA driver install on **RHEL 10.1+** in AWS, using the new `rhel-drivers` CLI from RHEL 10.1+ AppStream. cloud-init drives the whole thing, including the reboot between install and verify.

1. Terraform brings up a `g6.xlarge` (NVIDIA L4) on the latest PAYG/Hourly RHEL 10.x AMI in `us-east-2`.
2. cloud-init installs `ansible-core` and runs the install playbook (`rhel-drivers install nvidia` -> signed NVIDIA driver + CUDA toolkit from Red Hat's Extensions/Supplementary repos).
3. cloud-init auto-reboots the instance once stage 1 succeeds.
4. After reboot, `nvidia-verify.service` runs the verify playbook: `nvidia-smi`, builds + runs a CUDA `vector_add` sample, and writes `/var/lib/rhel-nvidia/status`.

Reference: [Introducing a new and simplified AI accelerator driver experience in RHEL](https://www.redhat.com/en/blog/introducing-new-and-simplified-ai-accelerator-driver-experience-rhel).

## Prerequisites

- AWS credentials with EC2 permissions in `us-east-2`. Default profile is **`lightspeed`**; override with the `AWS_PROFILE` env var or the `aws_profile` Terraform variable.
- Terraform >= 1.13.0.
- An SSH private key matching `ssh_public_key` in `terraform/variables.tf` (override to use your own).

## Usage

```sh
make plan          # review what will be created
make apply         # bring up the instance; stage 1 + auto-reboot + stage 2
make outputs       # see public_ip, ssh_command, etc.
make status        # inspect state and verifier journal over SSH
make ssh           # interactive shell on the instance
make verify        # dump /var/lib/rhel-nvidia/status (final pass/fail)
make destroy       # tear it all down
```

Expected total time from `make apply` to `status: OK`: **~5-6 minutes** on a `g6.xlarge` in `us-east-2`.

`make apply` returns once Terraform finishes creating the instance. Stage 1, the auto-reboot, and stage 2 then run unattended. Poll `make status` until `/var/lib/rhel-nvidia/status` shows up, then `make verify`.

## Cost note

`g6.xlarge` is ~$0.80/hr on-demand in `us-east-2`. Don't forget `make destroy`.

<details>
<summary><b>Using a different AWS profile</b></summary>

```sh
# One-off, via the Makefile (also exports it for Terraform):
make apply AWS_PROFILE=my-other-profile

# Or persist it in terraform/terraform.tfvars:
echo 'aws_profile = "my-other-profile"' >> terraform/terraform.tfvars

# Or fall back to ambient credentials (env vars, SSO default, instance role):
echo 'aws_profile = ""' >> terraform/terraform.tfvars
```

</details>

<details>
<summary><b>Debugging between stages (disable auto-reboot)</b></summary>

Set `auto_reboot = false` in `terraform/terraform.tfvars` to keep the box up after stage 1. Then `make ssh` to poke around, and `sudo reboot` yourself once `make status` shows `stage1.ok` to kick off stage 2.

</details>

<details>
<summary><b>Where things land on the instance</b></summary>

| Path | Purpose |
|---|---|
| `/opt/rhel-nvidia/ansible/` | Playbooks + CUDA source dropped by cloud-init |
| `/var/lib/rhel-nvidia/` | State markers (`stage1.ok`, `stage2.started`, `status`, `nvidia-smi.txt`, `vector_add.out`) |
| `/usr/local/bin/rhel-nvidia-status` | Helper printing state markers + verifier journal tail |
| `/etc/systemd/system/nvidia-verify.service` | Oneshot unit for stage 2 |

</details>

<details>
<summary><b>Reading success/failure</b></summary>

`make verify` (or `ssh ec2-user@<ip> sudo cat /var/lib/rhel-nvidia/status`) prints something like:

```text
status: OK
completed: 2026-05-21T15:58:20Z
kernel: 6.12.0-124.56.1.el10_1.x86_64
```

If the file is missing, stage 2 hasn't finished (or failed). `make status` shows state files and the `nvidia-verify.service` journal tail. If `stage1.ok` exists but `status` is missing after a couple of minutes, auto-reboot may have been disabled or skipped; reboot the instance manually to kick off stage 2.

</details>

<details>
<summary><b>Caveat: PAYG and RHUI vs CDN repos</b></summary>

`rhel-drivers` pulls the NVIDIA kernel module from the **RHEL Extensions** repo and the CUDA toolkit from **RHEL Supplementary**. On PAYG RHEL via AWS RHUI, those repos *do* exist, but under different IDs and disabled by default:

| Channel | CDN repo ID (BYOS/registered) | RHUI repo ID (PAYG) |
|---|---|---|
| Extensions | `rhel-10-for-x86_64-extensions-rpms` | `rhel-10-extensions-rhui-rpms` |
| Supplementary | `rhel-10-for-x86_64-supplementary-rpms` | `rhel-10-supplementary-rhui-rpms` |

Internally, `rhel-drivers` knows only the CDN IDs and tries to enable them via `subscription-manager`, which is a no-op on an unregistered PAYG box (`manage_repos=0` by default, and the CDN repos aren't reachable anyway). The result is a misleading `error: no drivers available for detected hardware`.

`ansible/install.yml` works around this by enabling the RHUI variants directly with `dnf config-manager --enable rhel-10-extensions-rhui-rpms rhel-10-supplementary-rhui-rpms` before invoking `rhel-drivers install --auto-detect --batch`. The enable task is skipped on AMIs that don't expose those repo IDs (e.g. BYOS), so on a registered BYOS host the standard `subscription-manager repos --enable=...` flow still applies.

You do **not** need to flip `subscription-manager config --rhsm.manage_repos=1` on PAYG. That actually makes things worse: `rhel-drivers` then expects to find the CDN repos, can't, and fails harder.

</details>

<details>
<summary><b>Security group</b></summary>

The instance gets a security group that allows SSH (tcp/22) from `var.allowed_ssh_cidrs` (default `0.0.0.0/0`) and all egress. Tighten the CIDR for anything beyond a smoke test:

```hcl
# terraform/terraform.tfvars
allowed_ssh_cidrs = ["203.0.113.10/32"]
```

</details>

<details>
<summary><b>Repo layout</b></summary>

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

</details>
