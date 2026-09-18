# Node Exporter

Deploy [Prometheus Node Exporter](https://github.com/prometheus/node_exporter) to physical servers, VMs and macOS build machines using Ansible.

<br/>

## Collected Metrics

- CPU usage / load average
- Memory usage
- Disk usage / I/O
- Network traffic
- systemd service status (Linux only)
- Process statistics

<br/>

## Platform Support

The playbooks serve Linux and macOS from one code path. The OS is detected with `ansible_facts.system` and every derived value lives in `group_vars/all.yml`, where the Linux branch resolves to exactly the literals used before macOS support existed — Linux hosts are unaffected by the split.

| | Linux | macOS |
|---|---|---|
| Service manager | systemd unit under `/etc/systemd/system` | launchd LaunchDaemon under `/Library/LaunchDaemons` |
| Runs as | dedicated `node_exporter` nologin account | an existing unprivileged login |
| Logs | journald | the file named by `node_exporter_launchd_log` |
| Archive extraction | `unarchive` module | `tar` (the module rejects macOS's bundled bsdtar) |
| Port pre-check | `ss` | `lsof` |

Three macOS behaviours are worth knowing before editing these playbooks:

- **The run user must be overridden in `group_vars/<group>.yml`, not in `inventory.ini`.** macOS cannot create the nologin service account portably, so a macOS group sets `node_exporter_run_user` to an existing login. An inline `[group:vars]` block does not work — inventory-file group vars lose to `group_vars/` files.
- **launchd opens the log path as the job's user.** An unprivileged run user cannot create a file under root-owned `/var/log`, and the daemon then fails to spawn with no symptom beyond a refused connection on the port. The playbook creates that file with the right owner first.
- **launchd keeps the plist it read at bootstrap time.** Editing the plist and restarting the process is not enough; the job must be unloaded and reloaded. The playbook compares the loaded job's arguments against the rendered plist and reloads when they differ, so an interrupted run cannot leave the exporter running a stale config.

<br/>

## Directory Structure

```
node-exporter/
├── ansible/
│   ├── inventory.ini                    # Server list (physical + VM)
│   ├── group_vars/
│   │   ├── all.yml                      # Shared variables (version, port, paths)
│   │   └── build_machines.yml           # macOS group overrides (run user)
│   ├── playbook.yml                     # Installation playbook
│   ├── upgrade.yml                      # Upgrade playbook (with auto-rollback)
│   ├── rollback.yml                     # Manual rollback playbook
│   ├── uninstall.yml                    # Uninstall playbook
│   └── templates/
│       ├── node_exporter.service.j2     # systemd unit template (Linux)
│       └── node_exporter.plist.j2       # launchd LaunchDaemon template (macOS)
├── docs/
│   ├── troubleshooting.md               # Troubleshooting guide
│   └── troubleshooting-en.md
├── upgrade.py                           # Version-bump helper (managed by upgrade-sync)
├── backup/                              # Previous value snapshots left by upgrade.py
├── README.md
└── README-en.md
```

<br/>

## Documentation

| Document | Description |
|----------|-------------|
| [Troubleshooting](docs/troubleshooting.md) | Resolving issues during Ansible deployment (Python version compatibility, port 9100 in use, SSH connection failure, Python interpreter warning) |

<br/>

## Prerequisites

### Install Ansible

**macOS:**

```bash
brew install ansible
```

**Ubuntu/Debian:**

```bash
sudo apt update && sudo apt install -y ansible
```

**RHEL/Rocky Linux:**

```bash
sudo dnf install -y epel-release && sudo dnf install -y ansible
```

**pip (all OS):**

```bash
pip install ansible
```

Verify the install:

```bash
ansible --version
```

<br/>

### SSH Verification

SSH access to the target servers is required.

```bash
# Test SSH connection
ssh -i ~/.ssh/id_rsa_example example@192.0.2.10

# Test Ansible connectivity
cd ansible
ansible -i inventory.ini node_exporter -m ping
```

<br/>

## Adding Servers

Edit `ansible/inventory.ini`:

```ini
[physical_servers]
server5 ansible_host=192.0.2.30

[virtual_machines]
vm1 ansible_host=192.0.2.100

[build_machines]
mac-mini ansible_host=192.0.2.80
```

A macOS host also needs `node_exporter_run_user` set to an existing login in that group's `group_vars/<group>.yml` — see Platform Support.

<br/>

## Installation

```bash
cd ansible
ansible-playbook -i inventory.ini playbook.yml                             # Install all
ansible-playbook -i inventory.ini playbook.yml --limit physical_servers    # Physical servers only
ansible-playbook -i inventory.ini playbook.yml --limit virtual_machines    # VMs only
ansible-playbook -i inventory.ini playbook.yml --limit server1             # Single server

ansible-playbook -i inventory.ini playbook.yml --limit build_machines -K   # macOS (asks for sudo password)

# Dry-run: --check skips actual download, so extract step will fail — this is expected.
ansible-playbook -i inventory.ini playbook.yml --check
```

<br/>

## Upgrade

### Upgrade Flow

1. Check current installed version
2. Download new binary
3. Backup existing binary to `.bak`
4. Stop node_exporter service
5. Replace binary
6. Restart service
7. Verify `/metrics` endpoint responds

### Recommended: `./upgrade.py` for version bumps

Like the other components in this repo, `./upgrade.py` is provided (built on the `ansible-github-release` canonical). It fetches the latest GA version from GitHub Releases and updates `ansible/group_vars/all.yml`.

```bash
cd observability/monitoring/node-exporter

./upgrade.py --dry-run            # Fetch latest + preview the diff
./upgrade.py                      # Bump to latest
./upgrade.py --version 1.12.0     # Pin to a specific version
./upgrade.py --rollback           # Restore previous group_vars/all.yml from backup/
./upgrade.py --list-backups       # List backups
```

`./upgrade.py` only updates the source file (`group_vars/all.yml`). **Applying the new version to remote hosts is a separate ansible-playbook run** (see below).

### Apply to remote hosts via Ansible

```bash
cd ansible

# Use the version from group_vars/all.yml (typical after ./upgrade.py)
ansible-playbook -i inventory.ini upgrade.yml

# Override version via CLI without touching source files (one-off)
ansible-playbook -i inventory.ini upgrade.yml -e "node_exporter_version=1.12.0"

# Single server only
ansible-playbook -i inventory.ini upgrade.yml --limit server1

# Dry-run
ansible-playbook -i inventory.ini upgrade.yml --check
```

### Rollback

Previous binary is backed up to `/usr/local/bin/node_exporter.bak`.

Linux:

```bash
ssh example@192.0.2.10
sudo systemctl stop node_exporter
sudo mv /usr/local/bin/node_exporter.bak /usr/local/bin/node_exporter
sudo systemctl start node_exporter
```

macOS — the daemon has to be unloaded and reloaded, because launchd keeps the
plist it read at bootstrap time:

```bash
ssh example@192.0.2.80
sudo launchctl bootout system/com.prometheus.node_exporter
sudo mv /usr/local/bin/node_exporter.bak /usr/local/bin/node_exporter
sudo launchctl bootstrap system /Library/LaunchDaemons/com.prometheus.node_exporter.plist
```

### Version Management

All shared variables (`node_exporter_version`, `node_exporter_arch`, `node_exporter_port`, etc.) live in `ansible/group_vars/all.yml`. After an upgrade, update `node_exporter_version` in that single file and commit.

The `-e "node_exporter_version=..."` CLI override still works (extra-vars have higher precedence than group_vars in Ansible), so the existing one-off workflow is preserved.

Check latest version: [GitHub Releases](https://github.com/prometheus/node_exporter/releases)

<br/>

## Verification

```bash
# Check metrics endpoint
curl http://192.0.2.10:9100/metrics | head

# Check service status (on a Linux server)
systemctl status node_exporter
journalctl -u node_exporter -f

# Check service status (on a macOS host)
sudo launchctl print system/com.prometheus.node_exporter
tail -f /var/log/node_exporter.log
```

<br/>

## Prometheus Integration

Add server IPs to `kube-prometheus-stack/values/dev.yaml`:

```yaml
prometheus:
  prometheusSpec:
    additionalScrapeConfigs:
      - job_name: "physical-servers"
        static_configs:
          - targets:
              - "192.0.2.10:9100"
              - "192.0.2.12:9100"

      - job_name: "build-machines"
        static_configs:
          - targets:
              - "192.0.2.80:9100"
```

Both `inventory.ini` and `dev.yaml` must be updated when adding new servers.

<br/>

## Rollback

Restore previous version from `.bak` backup after a failed upgrade.

```bash
cd ansible
ansible-playbook -i inventory.ini rollback.yml                    # Rollback all
ansible-playbook -i inventory.ini rollback.yml --limit server1    # Single server
```

> `.bak` file is automatically removed after successful rollback.

<br/>

## Uninstall

Completely remove node-exporter (stop service + remove binary + remove user).

```bash
cd ansible
ansible-playbook -i inventory.ini uninstall.yml                    # Uninstall all
ansible-playbook -i inventory.ini uninstall.yml --limit server1    # Single server
ansible-playbook -i inventory.ini uninstall.yml --check            # Dry-run
```

<br/>

## Grafana Dashboard

Grafana → **Dashboards** → **New** → **Import** → ID: `1860` → Data source: **Prometheus** → Import

- Dashboard: [Node Exporter Full](https://grafana.com/grafana/dashboards/1860)
- Physical servers: select `physical-servers` in `job` dropdown
- VMs: select `virtual-machines` in `job` dropdown
- Individual server: select in `instance` dropdown

<br/>

## Troubleshooting

See [Troubleshooting Guide](docs/troubleshooting.md) for common issues:

- Python version compatibility (Ubuntu 20.04 Python 3.8)
- Port 9100 already in use
- SSH connection failure
- Python interpreter warning

<br/>

## Reference

- [Prometheus Node Exporter](https://github.com/prometheus/node_exporter)
- [Ansible Documentation](https://docs.ansible.com/)
