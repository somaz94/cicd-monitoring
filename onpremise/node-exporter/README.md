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
│   ├── playbook.yml                     # Installation playbook
│   ├── upgrade.yml                      # Upgrade playbook (with auto-rollback)
│   ├── rollback.yml                     # Manual rollback playbook
│   ├── uninstall.yml                    # Uninstall playbook
│   └── templates/
│       └── node_exporter.service.j2     # systemd unit template
├── docs/
│   └── troubleshooting.md              # Troubleshooting guide
└── README.md
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

**pip (all OS):**

```bash
pip install ansible
```

<br/>

### SSH Verification

```bash
# Test SSH connection
ssh -i ~/.ssh/id_rsa deploy@10.0.0.1

# Test Ansible connectivity
cd ansible
ansible -i inventory.ini node_exporter -m ping
```

<br/>

## Adding Servers

Edit `ansible/inventory.ini`:

```ini
[physical_servers]
server5 ansible_host=10.0.0.5

[virtual_machines]
vm1 ansible_host=10.0.0.100
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

### Run

```bash
cd ansible

# Upgrade to version defined in upgrade.yml
ansible-playbook -i inventory.ini upgrade.yml

# Upgrade to specific version
ansible-playbook -i inventory.ini upgrade.yml -e "node_exporter_version=1.12.0"

# Single server only
ansible-playbook -i inventory.ini upgrade.yml --limit server1

# Dry-run
ansible-playbook -i inventory.ini upgrade.yml --check
```

### Rollback

Previous binary is backed up to `/usr/local/bin/node_exporter.bak`.

```bash
cd ansible
ansible-playbook -i inventory.ini rollback.yml                    # Rollback all
ansible-playbook -i inventory.ini rollback.yml --limit server1    # Single server
```

> `.bak` file is automatically removed after successful rollback.

### Version Management

After upgrade, update `node_exporter_version` in both `playbook.yml` and `upgrade.yml`, then commit.

Check latest version: [GitHub Releases](https://github.com/prometheus/node_exporter/releases)

<br/>

## Verification

```bash
# Check metrics endpoint
curl http://10.0.0.1:9100/metrics | head

# Check service status (on server)
systemctl status node_exporter

# Check logs
journalctl -u node_exporter -f
```

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

## Prometheus Integration

Add server IPs to `kube-prometheus-stack/values/mgmt.yaml`:

```yaml
prometheus:
  prometheusSpec:
    additionalScrapeConfigs:
      - job_name: "physical-servers"
        static_configs:
          - targets:
              - "10.0.0.1:9100"
              - "10.0.0.2:9100"
```

Both `inventory.ini` and `mgmt.yaml` must be updated when adding new servers.

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
