# Node Exporter Troubleshooting

Common issues and solutions when deploying node-exporter with Ansible.

<br/>

## Ansible Python Version Compatibility Error

### Symptom

```
server1 | FAILED! => {
    "msg": "Ansible requires Python 3.9 or newer on the target. Current version: 3.8.10"
}
```

### Cause

Ansible 13.x (ansible-core 2.20) requires **Python 3.9+** on target servers.
Ubuntu 20.04 ships with Python 3.8 by default.

### Solution

**Option 1: deadsnakes PPA (recommended)**

```bash
ssh deploy@<SERVER_IP>
sudo apt update
sudo apt install -y software-properties-common
sudo apt-key adv --keyserver keyserver.ubuntu.com --recv-keys BA6932366A755776
sudo add-apt-repository -y ppa:deadsnakes/ppa
sudo apt update
sudo apt install -y python3.10
```

> If GPG error (`NO_PUBKEY BA6932366A755776`), run `apt-key adv` first.

**Option 2: Source build (when PPA is unreachable)**

```bash
ssh deploy@<SERVER_IP>
sudo apt update
sudo apt install -y build-essential zlib1g-dev libncurses5-dev libgdbm-dev \
  libnss3-dev libssl-dev libreadline-dev libffi-dev libsqlite3-dev wget

wget https://www.python.org/ftp/python/3.10.17/Python-3.10.17.tgz
tar xzf Python-3.10.17.tgz
cd Python-3.10.17
./configure --enable-optimizations
make -j$(nproc)
sudo make altinstall    # altinstall = keeps existing python3 symlink

python3.10 --version
```

> Source build takes 5-10 minutes. `altinstall` preserves existing Python 3.8.

**Specify Python path in inventory.ini:**

```ini
server1 ansible_host=10.0.0.1 ansible_python_interpreter=/usr/bin/python3.10
```

<br/>

## Dry-run (--check) Extract Error

### Symptom

```
fatal: [server1]: FAILED! => {"msg": "Source '/tmp/node_exporter-1.11.0.tar.gz' does not exist"}
```

### Cause

`--check` mode does not actually download files, so the extract step fails because the file doesn't exist. **This is expected behavior.**

### Solution

Run without `--check`:

```bash
ansible-playbook -i inventory.ini playbook.yml
```

<br/>

## Port 9100 Already in Use

### Symptom

```
FAILED! => {
    "msg": "Port 9100 is already in use on server1..."
}
```

### Solution

```bash
ssh deploy@<SERVER_IP>
sudo ss -tlnp | grep 9100

# Use alternative port:
ansible-playbook -i inventory.ini playbook.yml -e "node_exporter_port=9101"
```

<br/>

## SSH Connection Failure

### Solution

```bash
ssh -i ~/.ssh/id_rsa deploy@10.0.0.1     # Test directly
chmod 600 ~/.ssh/id_rsa                    # Fix key permissions
ssh-keygen -R 10.0.0.1                     # Reset host key
```

<br/>

## Python Interpreter Warning

Warning only, no functional impact. Suppress by specifying in inventory:

```ini
server1 ansible_host=10.0.0.1 ansible_python_interpreter=/usr/bin/python3.10
```
