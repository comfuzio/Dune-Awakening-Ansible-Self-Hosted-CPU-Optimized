# Dune: Awakening self-hosted server — Ubuntu 26.04 amd64v3 on Proxmox

One command takes a Proxmox VE node to a running Dune: Awakening battlegroup:

```
Proxmox template ─► tuned VM ─► Ubuntu 26.04 LTS (amd64v3) ─► Funcom payload
                                       │
                                       └─► k3s ─► Funcom operators ─► your world
```

Funcom's own appliance is a Hyper-V image running Alpine Linux. This project
runs the same Funcom containers and scripts on a current Ubuntu LTS kernel in
a VM sized and tuned for a game server. Everything is plain Ansible: one
playbook (`site.yml`), seven roles, one config file.

## Requirements

**Proxmox VE node**
- A CPU with **x86-64-v3** (AVX2, BMI2, FMA, MOVBE). Funcom's server needs
  AVX2 regardless; the playbook checks for v3 using glibc's own CPU check and
  stops if it is missing.
- About 120 GB free on the VM storage, and a bridge such as `vmbr0`.
- SSH access as root (or a sudo user) from the controller. Connect once by
  hand (`ssh root@<node>`) so the node's host key is already known.

**Controller** (Linux, macOS or WSL)
- `python3`, `ssh`, and Ansible (`pip install ansible-core`).
- An SSH key pair for the VM, for example
  `ssh-keygen -t ed25519 -f ~/.ssh/dune_ed25519`.

**Game**
- A Funcom self-host token from your Dune account page.
- A static LAN address for the VM, and port forwards for outside players:
  UDP 7777–7890 and TCP 31982. Don't forward Funcom's admin and management ports.
- Hosting for outside players does not work behind carrier-grade NAT.

## Quick start

```bash
git clone https://github.com/comfuzio/Dune-Awakening-Ansible-Self-Hosted-CPU-Optimized.git
cd Dune-Awakening-Ansible-Self-Hosted-CPU-Optimized
python3 -m venv .venv && .venv/bin/pip install ansible-core
scripts/deploy.sh
```

On the first run, the wizard asks for the Proxmox node, VM sizing, network,
SSH key and world settings, and saves them to `config/local.yml` (git-ignored).
Every run asks for the self-host token as hidden input. Alternatively, export
`DUNE_SELFHOST_TOKEN` before you start. The token is passed to Ansible only
through the environment. It is never written to disk and never shown in logs.

A fresh deployment takes roughly 30–60 minutes, mostly spent downloading the
server payload.

## Configuration

`config/example.yml` lists the common settings. Every role also documents its
own options in `roles/<role>/defaults/main.yml`. You can override any of them
in `config/local.yml`.

| Setting | Default | Meaning |
|---|---|---|
| `pve_template_vmid` | `8010` | Template to clone. If it doesn't exist (and `pve_template_build` is true), it is built from Canonical's amd64v3 image after checking `SHA256SUMS`. |
| `vm_id`, `vm_name` | `201`, `dune-server` | Re-running against the same VM is safe. A different VM at that VMID is never touched. |
| `vm_cores` / `vm_memory_gib` / `vm_disk_gib` | `6` / `40` / `110` | Minimums are 4 cores, 24 GiB and 100 GiB. |
| `dune_world_region` | `europe` | `asia`, `europe`, `north-america`, `oceania` or `south-america`. |
| `dune_public_ip` | detect | The address players connect to. For a LAN-only server, use the VM's LAN IP. |
| `dune_payload_archive` | — | Use a Linux package archive (local path or URL) instead of SteamCMD. |
| `k3s_version` | channel `stable` | Pin an exact k3s release. |
| `k3s_disable_apparmor` | `true` | See [AppArmor](#apparmor-on-kernels-700-42-and-newer). |

## Stages

Each role is tagged, and you can re-run any of them at any time:

| Tag | Role | What it does |
|---|---|---|
| `template` | `pve_template` | Checks for an x86-64-v3 CPU. Builds or validates the Ubuntu 26.04 amd64v3 cloud-init template. |
| `vm` | `pve_vm` | Full-clones the template and applies the hardware and performance settings, cloud-init and the static IP, then boots the VM and waits for SSH. |
| `guest` | `guest` | Runs a full upgrade (rebooting if the kernel changed), removes snapd, applies kernel tuning, and sets up the `dune` account. |
| `payload` | `steam` | Installs SteamCMD and downloads or updates the server (app `4754530`), or unpacks an archive. |
| `k3s` | `k3s` | Writes the k3s config, the pod DNS file and the containerd AppArmor drop-in **before** k3s starts, then installs k3s. |
| `operators` | `funcom` | Imports the payload images, deploys the cert-manager version bundled with the payload, and deploys Funcom's CRDs and the four operators with cert-manager webhook certificates. |
| `world` | `world` | Prepares Funcom's world template, runs `world.sh`, reconciles IP, host ID, title and service key, starts the world, and waits until it is healthy. |

```bash
scripts/deploy.sh --tags world        # only the world stage
scripts/deploy.sh --tags payload,world  # pull a new server build and apply it
scripts/deploy.sh --reconfigure       # answer the wizard again
```

**Updating the server:** run `scripts/deploy.sh --tags payload,world`. If
SteamCMD downloaded a new build, the world stage runs Funcom's
`battlegroup.sh update-from-downloads` and then reconciles the world again.
Set `dune_apply_updates: true` to force that step, or `false` to never run it.

## Performance

The game server itself is Funcom's prebuilt Unreal binary, so it is the same
on every host. What this project tunes is everything around it:

**VM (Proxmox)**
- CPU type `host`, so the guest gets the full v3+ instruction set rather than a
  generic model.
- RAM is fully dedicated: ballooning off and KSM page merging off for this VM.
  Optionally, `vm_hugepages: "1024"` backs guest RAM with 1 GiB host
  hugepages (reserve them on the host first).
- Disk: `virtio-scsi-single` with a dedicated I/O thread, `aio=io_uring`,
  `cache=none`, discard/TRIM and SSD emulation.
- Network: multiqueue virtio-net, one queue per vCPU (up to 8), so UDP
  interrupts spread across cores.
- Optional `vm_cpu_affinity` pins the VM to chosen host cores, and `vm_numa`
  exposes NUMA topology on multi-socket hosts.
- The tablet device is off (it causes idle USB polling), and the VM starts on
  host boot.

**Guest (Ubuntu 26.04 LTS, kernel 7.0)**
- amd64v3 userspace: libraries such as glibc, OpenSSL and Python are built for
  x86-64-v3. k3s and containerd ship as their own static binaries, and the game
  containers are Funcom's, so the gain is mainly on the host side.
- Larger UDP and TCP socket buffers, a larger netdev backlog, BBR with `fq`,
  and a wider ephemeral port range.
- `vm.max_map_count` raised for Unreal, inotify limits raised for kubelet and
  the operators, autogroup scheduling and the NMI watchdog off, and
  `irqbalance` on.
- snapd removed.

**Cluster**
- Traefik disabled (unused). Operators log at `info` instead of `debug`.
- Kubelet image garbage collection starts only at 95% disk use. Funcom's images
  are imported from the payload and cannot be pulled again from a registry, so
  losing them would break restarts.

## AppArmor on kernels 7.0.0-42 and newer

From Ubuntu kernel `7.0.0-42`, AppArmor labels container peers as
`cri-containerd.apparmor.d//&unconfined`. containerd's default profile does
not allow signals to that label. As a result, the kernel blocks postgres's
`SIGUSR1`, which breaks the database pod, and Go's `SIGURG` preemption signal,
which breaks the Go-based game services. You can check for it like this:

```bash
journalctl -k | grep 'apparmor="DENIED".*cri-containerd'
```

The `k3s` role writes the following drop-in before k3s first starts. On an
existing node, it restarts k3s once.

```toml
# /var/lib/rancher/k3s/agent/etc/containerd/config-v3.toml.d/10-dune-no-apparmor.toml
version = 3
[plugins.'io.containerd.cri.v1.runtime']
  disable_apparmor = true
```

After k3s starts, the role checks what containerd *actually* uses
(`k3s crictl info` → `.config.disableApparmor`) rather than trusting the file.
That matters because only some k3s releases read the drop-in directory. For
example, v1.34 imports `config-v3.toml.d/`, but v1.33 generates a
`config.toml` without the import line and silently ignores the drop-in. When
the drop-in is ignored, the role writes a `config.toml.tmpl` (k3s's own
override mechanism) containing the generated config plus `disable_apparmor`,
restarts k3s, and fails loudly if AppArmor is still on. Re-run
`--tags k3s` after upgrading k3s in that case.

**Trade-off:** containers on this VM run without an AppArmor profile.

**Existing server:** stop the world first (`battlegroup stop`), run
`scripts/deploy.sh --tags k3s`, then run `battlegroup start`.

## Day-to-day

On the VM, as `dune` (`~/.dune/bin` is on the PATH):

```bash
battlegroup status
battlegroup stop | start | restart
kubectl get pods -A
dune-world wait --ns "$(dune-world namespace)"   # block until healthy
```

## Troubleshooting

- **The world doesn't appear in the server list:** check `dune_public_ip` and
  your port forwards. `kubectl -n <ns> get battlegroup -o yaml | grep -A1
  HOST_DATACENTER_IP_ADDRESS` should show your public IP.
- **Pods stuck in `ImagePullBackOff`:** run `scripts/deploy.sh --tags world`
  again. It re-imports the images and re-creates the tag aliases.
- **The database pod restarts, or Go services hang after a kernel update:** see
  [AppArmor](#apparmor-on-kernels-700-42-and-newer).
- **`x86-64-v3` check fails inside the VM:** the VM CPU type must be `host`.

## Notes

- The x86-64-v3 check, VM tuning values and sysctls are general Linux and KVM
  practice. Measure on your own hardware.
- Funcom's payload, scripts and images are Funcom's and are downloaded from
  Steam at deploy time. Nothing of theirs is redistributed here.
- Licensed under the GNU AGPL v3, see `LICENSE`. Project history is described
  in `HISTORY.md`.
