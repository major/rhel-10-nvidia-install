# AGENTS.md

Instructions for OpenCode / agents working in this repo. Read this before touching
anything. The repo is small but has a few non-obvious failure modes.

## 🚨 Keep docs in sync with code (high priority)

**Any change to Terraform, Ansible, or cloud-init MUST be reflected in `README.md`
and (where relevant) this `AGENTS.md` in the same change.** Stale docs here are
worse than no docs, because the wrong mental model causes wasted AWS spend on
broken instances. Specifically re-check:

- `README.md` "Layout", "Where things land on the instance", and "Usage" tables
- Any Makefile target changes need a matching `help` entry and README bullet
- New Ansible state files or log paths must be added to README's path table
- AMI name filter / region / instance type changes must update README prereqs

If you change behavior and skip the doc update, the change is not done.

## What this repo is

End-to-end automation: Terraform launches a RHEL 10.1+ GPU instance on AWS, and
cloud-init drives a two-stage NVIDIA driver install via Ansible + the
`rhel-drivers` CLI. There is **no application code**, only IaC + config.

## Architecture in one paragraph (the part you'll miss)

Terraform renders `terraform/templates/cloud-init.yaml.tftpl` and embeds the
contents of `ansible/install.yml`, `ansible/verify.yml`, `ansible/files/vector_add.cu`,
and `ansible/files/nvidia-verify.service` as **inline strings inside user-data**
(see `terraform/user-data.tf`). The files on the instance are written by
cloud-init's `write_files`, not fetched from anywhere. On first boot cloud-init
runs `install.yml`. When `var.auto_reboot` is true (default), cloud-init's
`power_state` module then waits for `cloud-final.service` to exit cleanly and
fires `shutdown -r`, gated on a `test -f /var/lib/rhel-nvidia/stage1.ok`
condition so a failed stage 1 leaves the box up for debugging. On the next
boot `nvidia-verify.service` runs `verify.yml`. The systemd unit has
`ConditionPathExists=!/var/lib/rhel-nvidia/status` so it self-disables once
verify succeeds. cloud-init's per-instance semaphores prevent `power_state`
from firing again on the post-reboot run, so there is no reboot loop from
this mechanism. `make status` / `make verify` SSH in and inspect
`/var/lib/rhel-nvidia/`.

## Critical gotcha: re-applying to test Ansible changes

Because the playbooks are baked into user-data at `terraform apply` time, editing
`ansible/*.yml` does **not** affect a running instance. The `aws_instance` is
configured with `user_data_replace_on_change = true`, so a fresh `terraform apply`
after a playbook edit will force-replace the instance (destroy + create). The
two valid workflows are:

1. `make apply` after editing a playbook (instance is force-replaced; stage 1
   runs automatically, cloud-init auto-reboots if `auto_reboot = true`, then
   stage 2 verifies), or
2. `scp` the edited playbook onto the instance and re-run it manually under
   `sudo ansible-playbook -i localhost, -c local <file>`. Use this for fast
   iteration but commit & redeploy before claiming a fix works end-to-end.

For debugging runs where you want the instance to stay up between stages,
set `auto_reboot = false` in `terraform/terraform.tfvars` before `make apply`.

Do **not** revert `user_data_replace_on_change` to false. Without it, AWS
performs an in-place stop/update/start cycle that updates the user-data metadata
but never re-runs cloud-init, so the new playbook is silently ignored and the
test is meaningless.

There is no remote-pull mechanism. Do not add one without discussing first; the
self-contained user-data is intentional.

## Commands (use the Makefile, not raw terraform)

| Command | Notes |
|---|---|
| `make plan` / `make apply` / `make destroy` | Wrap `terraform -chdir=terraform`. `apply` and `destroy` use `-auto-approve`. Power off the instance before destroy; see Cost & safety. |
| `make outputs` | `public_ip`, `ssh_command`, `ami_id`, `verification_help`. |
| `make ssh` / `make status` / `make verify` | SSH helpers. Resolve IP via `terraform output -raw public_ip`. |
| `make lint` | `terraform fmt -check -recursive` + `yamllint ansible/`. Run before every commit. |
| `make fmt` | Auto-fix Terraform formatting. There is no Ansible auto-formatter. |

`AWS_PROFILE` defaults to `lightspeed` in the Makefile and in `var.aws_profile`.
Override on the CLI (`make apply AWS_PROFILE=foo`) or in `terraform/terraform.tfvars`
(gitignored). Empty string means ambient credentials.

## Conventions

- **Terraform**: provider pins live in `terraform/versions.tf` (`aws ~> 6.46`,
  `cloudinit ~> 2.4`, `required_version >= 1.13.0`). Always run `make fmt` and
  `make lint` before committing.
- **Ansible**: every playbook starts with `---` (yamllint enforces
  `document-start: present`). Line length warning at 140 (see `.yamllint`).
  Playbooks always run `hosts: localhost`, `connection: local`, `become: true`.
  Use FQCN (`ansible.builtin.*`) for modules.
- **State files** live under `/var/lib/rhel-nvidia/` on the instance:
  `stage1.started`, `stage1.ok`, `stage2.started`, `status`, `nvidia-smi.txt`,
  `vector_add.out`, `rhel-drivers-install.log`. If you add a new marker, update
  the table in `README.md` and the `rhel-nvidia-status` helper in
  `terraform/templates/cloud-init.yaml.tftpl`.
- **Logs** use platform defaults only. Stage 1 output goes through cloud-init
  logging, and stage 2 output goes to the `nvidia-verify.service` journal. Do
  not add project-specific `/var/log/rhel-nvidia-*.log` files; customers do not
  want those in production images.
- **Idempotency**: install.yml uses `nvidia_pre` (rpm query) to set
  `changed_when` on the `rhel-drivers install nvidia` task. Preserve this when
  editing; rerunning the playbook on an already-installed host should report
  `changed=0`.

## Cost & safety

- `g6.xlarge` is ~$0.80/hr on-demand in `us-east-2`. **Always clean up test
  instances when finished.** If you spawn an instance during agent work, do not
  leave it running across sessions.
- Before `make destroy`, power off the instance from inside the guest with
  `sudo systemctl poweroff` (for example via `make ssh`). Wait for SSH to drop,
  then run `make destroy`. This speeds up EC2 termination compared with asking
  Terraform to terminate a fully running GPU instance.
- Default security group allows SSH from `0.0.0.0/0`. Fine for short-lived
  smoke tests; do not productionize without tightening `allowed_ssh_cidrs`.
- `terraform.tfstate` is local (no remote backend). Do not commit it
  (`.gitignore` already covers `*.tfstate*`).

## Known fragile areas

- **PAYG + RHUI repos**: `rhel-drivers` knows only the CDN repo IDs
  (`rhel-10-for-x86_64-{extensions,supplementary}-rpms`) and enables them via
  `subscription-manager`, which is a no-op on PAYG/RHUI. The RHUI equivalents
  (`rhel-10-{extensions,supplementary}-rhui-rpms`) exist but ship disabled.
  `install.yml` enables them with `dnf config-manager --enable ...` before
  calling `rhel-drivers install --auto-detect --batch`, and conditional-skips
  on AMIs that don't have those repo IDs (BYOS). See README "Caveat" section.
  Do **not** flip `manage_repos=1` on PAYG; rhel-drivers then expects CDN
  repos and fails harder. Do not silently swap AMIs; ask first.
- **rhel-drivers CLI**: `rhel-drivers install <vendor>` (bare) is rejected
  with `invalid driver ID format`. Use `--auto-detect` or pass an explicit
  `vendor:version` (see `rhel-drivers list`). The package ships as `radii`
  with `Provides: rhel-drivers`; either name works in `dnf install`.
- **AMI filter** (`var.ami_name_filter` = `RHEL-10.*HVM-*-x86_64-*-Hourly2-GP3`)
  intentionally tracks the latest RHEL 10.x PAYG image because RHEL 10.2 may not
  be published in every region. Confirm the resolved `ami_name` during testing
  and do not silently swap to non-RHEL or non-PAYG images.
- **CUDA source path mismatch**: `verify.yml` reads `/var/lib/rhel-nvidia/vector_add.cu`,
  but `write_files` drops it at `/opt/rhel-nvidia/ansible/files/vector_add.cu`.
  cloud-init `runcmd` copies it into place. If you reorganize either path,
  update the `cp` line in `cloud-init.yaml.tftpl`.

## Testing

There is no unit test suite. The only meaningful test is `make apply` →
wait for `/var/lib/rhel-nvidia/status` to appear (auto-reboot drives stage 2
for you) → `make verify` and confirm it contains `status: OK`. Budget ~15 min
and ~$0.20 per full cycle. For debugging, set `auto_reboot = false` and reboot
manually between stages.

For fast iteration on Ansible without redeploying, see the "Critical gotcha"
section above.

## What not to do

- Do not commit `terraform.tfvars`, `terraform.tfstate*`, or `.terraform/`.
- Do not run `terraform` directly from the repo root; the Makefile uses
  `-chdir=terraform` and that is the supported invocation.
- Do not add a remote Ansible inventory or pull mechanism; the design is
  self-contained user-data on purpose.
- Do not relax SSH CIDR defaults further.
- Do not commit with `make lint` failing.
