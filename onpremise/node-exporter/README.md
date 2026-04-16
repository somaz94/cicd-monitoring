# Node Exporter

Deploy [Prometheus Node Exporter](https://github.com/prometheus/node_exporter) to physical servers and VMs using Ansible.

<br/>

## Collected Metrics

- CPU usage / load average
- Memory usage
- Disk usage / I/O
- Network traffic
- systemd service status
- Process statistics

<br/>

## Directory Structure

```
node-exporter/
├── ansible/
│   ├── inventory.ini                    # Server list (physical + VM)
│   ├── group_vars/
│   │   └── all.yml                      # Shared variables (version, port, paths)
│   ├── playbook.yml                     # Installation playbook
│   ├── upgrade.yml                      # Upgrade playbook (with auto-rollback)
│   ├── rollback.yml                     # Manual rollback playbook
│   ├── uninstall.yml                    # Uninstall playbook
│   └── templates/
│       └── node_exporter.service.j2     # systemd unit template
├── upgrade.sh                           # Version-bump helper (managed by upgrade-sync)
├── README.md
└── README-en.md
```

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

<br/>

### SSH Verification

```bash
# Test SSH connection
ssh -i ~/.ssh/id_rsa_example example@192.168.1.10

# Test Ansible connectivity
cd ansible
ansible -i inventory.ini node_exporter -m ping
```

<br/>

## Adding Servers

Edit `ansible/inventory.ini`:

```ini
[physical_servers]
server5 ansible_host=192.168.1.30

[virtual_machines]
vm1 ansible_host=192.168.1.100
```

<br/>

## Installation

```bash
cd ansible
ansible-playbook -i inventory.ini playbook.yml                             # Install all
ansible-playbook -i inventory.ini playbook.yml --limit physical_servers    # Physical servers only
ansible-playbook -i inventory.ini playbook.yml --limit virtual_machines    # VMs only
ansible-playbook -i inventory.ini playbook.yml --limit server1             # Single server

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

### Recommended: `./upgrade.sh` for version bumps

Like the other components in this repo, `./upgrade.sh` is provided (built on the `ansible-github-release` canonical). It fetches the latest GA version from GitHub Releases and updates `ansible/group_vars/all.yml`.

```bash
cd observability/monitoring/node-exporter

./upgrade.sh --dry-run            # Fetch latest + preview the diff
./upgrade.sh                      # Bump to latest
./upgrade.sh --version 1.12.0     # Pin to a specific version
./upgrade.sh --rollback           # Restore previous group_vars/all.yml from backup/
./upgrade.sh --list-backups       # List backups
```

`./upgrade.sh` only updates the source file (`group_vars/all.yml`). **Applying the new version to remote hosts is a separate ansible-playbook run** (see below).

### Apply to remote hosts via Ansible

```bash
cd ansible

# Use the version from group_vars/all.yml (typical after ./upgrade.sh)
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

```bash
ssh example@192.168.1.10
sudo systemctl stop node_exporter
sudo mv /usr/local/bin/node_exporter.bak /usr/local/bin/node_exporter
sudo systemctl start node_exporter
```

### Version Management

All shared variables (`node_exporter_version`, `node_exporter_arch`, `node_exporter_port`, etc.) live in `ansible/group_vars/all.yml`. After an upgrade, update `node_exporter_version` in that single file and commit.

The `-e "node_exporter_version=..."` CLI override still works (extra-vars have higher precedence than group_vars in Ansible), so the existing one-off workflow is preserved.

Check latest version: [GitHub Releases](https://github.com/prometheus/node_exporter/releases)

<br/>

## Verification

```bash
# Check metrics endpoint
curl http://192.168.1.10:9100/metrics | head

# Check service status (on server)
systemctl status node_exporter

# Check logs
journalctl -u node_exporter -f
```

<br/>

## Prometheus Integration

Add server IPs to `kube-prometheus-stack/values/mgmt.yaml`:

```yaml
prometheus:
  prometheusSpec:
    additionalScrapeConfigs:
      - job_name: "physical-servers"
        static_configs:
          - targets:
              - "192.168.1.10:9100"
              - "192.168.1.12:9100"
```

Both `inventory.ini` and `mgmt.yaml` must be updated when adding new servers.

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

See [Troubleshooting Guide](docs/troubleshooting-en.md) for common issues:

- Python version compatibility (Ubuntu 20.04 Python 3.8)
- Port 9100 already in use
- SSH connection failure
- Python interpreter warning

<br/>

## Reference

- [Prometheus Node Exporter](https://github.com/prometheus/node_exporter)
- [Ansible Documentation](https://docs.ansible.com/)
