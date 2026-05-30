#!/usr/bin/env bash
# ============================================================
#  NexusServer - Railway entrypoint
#
#  Required environment variables (Railway dashboard -> Variables):
#    SSH_PASSWORD      - Password for the nexus VM user
#    TAILSCALE_AUTHKEY - Tailscale auth key
# ============================================================
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
section() { echo -e "\n${GREEN}======  $*  ======${NC}"; }

# ── Validate required env vars ────────────────────────────────────────────────
for var in SSH_PASSWORD TAILSCALE_AUTHKEY; do
    if [[ -z "${!var:-}" ]]; then
        error "Missing required environment variable: $var"
        exit 1
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
section "System Info"
# ─────────────────────────────────────────────────────────────────────────────
info "CPUs: $(nproc) | RAM: $(free -h | awk '/^Mem:/{print $2}')"
df -h / | tail -1

if [[ -e /dev/kvm ]]; then
    chmod 666 /dev/kvm 2>/dev/null || true
    info "KVM available - hardware acceleration enabled!"
    KVM_FLAGS="-enable-kvm -cpu host,+x2apic"
else
    warn "No KVM - running in TCG software emulation mode"
    KVM_FLAGS="-cpu qemu64,+ssse3,+sse4.1,+sse4.2,+popcnt -accel tcg,thread=multi"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "Download Ubuntu 24.04 Server Image"
# ─────────────────────────────────────────────────────────────────────────────
UBUNTU_URL="https://releases.ubuntu.com/24.04/ubuntu-24.04-live-server-amd64.iso"
UBUNTU_ISO="/vms/ubuntu-24.04-server.iso"
UBUNTU_DISK="/vms/nexusserver.qcow2"
DISK_SIZE="40G"
CLOUD_INIT_ISO="/vms/cloud-init.iso"

mkdir -p /vms

info "Downloading Ubuntu 24.04 Server ISO..."
curl -L \
    -o "$UBUNTU_ISO" \
    --progress-bar \
    --retry 3 \
    --retry-delay 5 \
    "$UBUNTU_URL"
info "ISO ready: $(du -sh "$UBUNTU_ISO")"

# ─────────────────────────────────────────────────────────────────────────────
section "Prepare Cloud-Init for Unattended Setup"
# ─────────────────────────────────────────────────────────────────────────────
# Build a cloud-init datasource ISO so the VM configures itself on first boot:
#   - Creates user 'nexus' with the provided password
#   - Enables SSH (password auth)
#   - Installs Chrome and sshx on first boot
apt-get install -y genisoimage cloud-image-utils -qq 2>/dev/null || \
    apt-get install -y cloud-utils -qq 2>/dev/null || true

mkdir -p /tmp/cloud-init

# user-data: cloud-config
cat > /tmp/cloud-init/user-data << USERDATA
#cloud-config
autoinstall:
  version: 1
  locale: en_US.UTF-8
  keyboard:
    layout: us
  network:
    network:
      version: 2
      ethernets:
        ens3:
          dhcp4: true
  storage:
    layout:
      name: lvm
  identity:
    hostname: nexusserver
    username: nexus
    password: $(echo "$SSH_PASSWORD" | python3 -c "import sys, crypt; print(crypt.crypt(sys.stdin.read().strip(), crypt.mksalt(crypt.METHOD_SHA512)))")
  ssh:
    install-server: true
    allow-pw: true
  packages:
    - openssh-server
    - curl
    - wget
    - git
    - build-essential
    - software-properties-common
    - apt-transport-https
    - gnupg
    - ca-certificates
    - net-tools
    - unzip
    - htop
    - vim
  late-commands:
    - curtin in-target --target=/target -- bash -c "echo 'nexus ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers"
    - curtin in-target --target=/target -- bash -c "sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config"
    - curtin in-target --target=/target -- bash -c "sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config"
    - curtin in-target --target=/target -- bash -c "wget -q -O /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb && apt install -y /tmp/chrome.deb || true"
    - curtin in-target --target=/target -- bash -c "curl -sSf https://sshx.io/get | sh || true"
    - curtin in-target --target=/target -- bash -c "mkdir -p /etc/systemd/system && cat > /etc/systemd/system/sshx.service << 'EOF'
[Unit]
Description=sshx terminal sharing
After=network.target

[Service]
Type=simple
User=nexus
Group=nexus
ExecStartPre=/bin/bash -c \"pkill -9 sshx || true; sleep 1\"
ExecStart=/usr/local/bin/sshx
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
systemctl enable sshx"
  user-data:
    hostname: nexusserver
USERDATA

# meta-data (minimal)
cat > /tmp/cloud-init/meta-data << EOF
instance-id: nexusserver-01
local-hostname: nexusserver
EOF

# Create cloud-init ISO
if command -v genisoimage &>/dev/null; then
    genisoimage -output "$CLOUD_INIT_ISO" \
        -volid cidata -joliet -rock \
        /tmp/cloud-init/user-data \
        /tmp/cloud-init/meta-data
elif command -v cloud-localds &>/dev/null; then
    cloud-localds "$CLOUD_INIT_ISO" \
        /tmp/cloud-init/user-data \
        /tmp/cloud-init/meta-data
else
    warn "No ISO tool found - cloud-init ISO will be skipped"
    CLOUD_INIT_ISO=""
fi

# ─────────────────────────────────────────────────────────────────────────────
section "Create VM Disk and Install Ubuntu"
# ─────────────────────────────────────────────────────────────────────────────
info "Creating ${DISK_SIZE} qcow2 disk..."
qemu-img create -f qcow2 "$UBUNTU_DISK" "$DISK_SIZE"

TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')
VM_RAM=$(( TOTAL_RAM * 75 / 100 ))
CPUS=$(nproc)
info "Installing Ubuntu with ${VM_RAM}MB RAM and ${CPUS} vCPUs (this takes ~10-20 min)..."

EXTRA_DRIVES=""
if [[ -n "$CLOUD_INIT_ISO" && -f "$CLOUD_INIT_ISO" ]]; then
    EXTRA_DRIVES="-drive file=${CLOUD_INIT_ISO},format=raw,if=virtio,readonly=on"
fi

# Boot from ISO for installation - autoinstall via cloud-init
qemu-system-x86_64 \
    $KVM_FLAGS \
    -machine q35,mem-merge=off \
    -m "${VM_RAM}" \
    -smp "${CPUS}" \
    -drive file="$UBUNTU_DISK",format=qcow2,if=virtio,cache=writeback \
    -drive file="$UBUNTU_ISO",format=raw,if=virtio,readonly=on \
    $EXTRA_DRIVES \
    -boot d \
    -device e1000,netdev=n0 \
    -netdev user,id=n0,hostfwd=tcp::2222-:22 \
    -object rng-random,filename=/dev/urandom,id=rng0 \
    -device virtio-rng-pci,rng=rng0 \
    -serial file:/vms/install.log \
    -display none \
    -no-reboot \
    -append "autoinstall ds=nocloud-net;s=file:///cdrom/ cloud-config-url=/dev/null" \
    2>&1 &

INSTALL_PID=$!

# Wait for installation to complete (up to 30 min)
info "Waiting for Ubuntu installation to complete..."
for i in $(seq 1 180); do
    if ! kill -0 $INSTALL_PID 2>/dev/null; then
        info "Installation process exited after ${i}0s"
        break
    fi
    if (( i % 6 == 0 )); then
        info "Still installing... $(( i * 10 / 60 )) min elapsed"
        tail -2 /vms/install.log 2>/dev/null || true
    fi
    sleep 10
done

info "Installation phase complete. Disk: $(du -sh "$UBUNTU_DISK")"

# ─────────────────────────────────────────────────────────────────────────────
section "Boot Installed VM"
# ─────────────────────────────────────────────────────────────────────────────
info "Booting installed Ubuntu 24.04 VM..."

qemu-system-x86_64 \
    $KVM_FLAGS \
    -machine q35,mem-merge=off \
    -m "${VM_RAM}" \
    -smp "${CPUS}" \
    -drive file="$UBUNTU_DISK",format=qcow2,if=virtio,cache=writeback,discard=unmap,aio=threads \
    -boot order=c \
    -device e1000,netdev=n0 \
    -netdev user,id=n0,hostfwd=tcp::2222-:22,hostfwd=tcp::8080-:8080,hostfwd=tcp::3000-:3000 \
    -object rng-random,filename=/dev/urandom,id=rng0 \
    -device virtio-rng-pci,rng=rng0 \
    -serial file:/vms/nexusserver.serial.log \
    -monitor unix:/vms/nexusserver.monitor,server,nowait \
    -display none \
    -daemonize \
    -pidfile /vms/nexusserver.pid

info "VM booted!"

# ─────────────────────────────────────────────────────────────────────────────
section "Wait for SSH"
# ─────────────────────────────────────────────────────────────────────────────
info "Waiting for SSH to become available..."
VM_READY=false
for i in $(seq 1 120); do
    if sshpass -p "$SSH_PASSWORD" \
        ssh -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=5 \
            -p 2222 nexus@localhost \
            "echo SSH_READY" 2>/dev/null | grep -q "SSH_READY"; then
        info "SSH ready after ${i}0s!"
        VM_READY=true
        break
    fi
    if (( i % 3 == 0 )); then
        info "Still waiting... ${i}0s elapsed"
        tail -2 /vms/nexusserver.serial.log 2>/dev/null || true
    fi
    sleep 10
done

if [[ "$VM_READY" != "true" ]]; then
    warn "SSH never became ready. Serial log:"
    cat /vms/nexusserver.serial.log 2>/dev/null || true
    exit 1
fi

# ── SSH helper ────────────────────────────────────────────────────────────────
vm_ssh() {
    sshpass -p "$SSH_PASSWORD" \
        ssh -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=30 \
            -p 2222 nexus@localhost \
            "$@"
}

# ─────────────────────────────────────────────────────────────────────────────
section "Post-Boot Setup"
# ─────────────────────────────────────────────────────────────────────────────
info "Running post-boot configuration..."
vm_ssh bash << 'ENDSSH'
set -e

echo "=== Installing Chrome ==="
if ! command -v google-chrome &>/dev/null && ! command -v google-chrome-stable &>/dev/null; then
    wget -q -O /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
    sudo apt-get install -y /tmp/chrome.deb 2>/dev/null || \
    sudo dpkg -i /tmp/chrome.deb && sudo apt-get install -f -y
    rm -f /tmp/chrome.deb
    echo "Chrome installed: $(google-chrome --version 2>/dev/null || google-chrome-stable --version)"
else
    echo "Chrome already installed: $(google-chrome --version 2>/dev/null || google-chrome-stable --version)"
fi

echo "=== Installing sshx ==="
if ! command -v sshx &>/dev/null; then
    curl -sSf https://sshx.io/get | sh
fi

echo "=== Setting up sshx service ==="
sudo tee /etc/systemd/system/sshx.service > /dev/null << 'EOF'
[Unit]
Description=sshx terminal sharing
After=network.target

[Service]
Type=simple
User=nexus
Group=nexus
ExecStartPre=/bin/bash -c "pkill -9 sshx || true; sleep 1"
ExecStart=/usr/local/bin/sshx
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable sshx
sudo systemctl restart sshx
sleep 3
echo "sshx service started"

echo "=== Ensuring SSH config is clean ==="
sudo sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sudo systemctl restart ssh 2>/dev/null || sudo systemctl restart sshd 2>/dev/null || true

echo "=== System ready ==="
uname -a
df -h /
ENDSSH

# ─────────────────────────────────────────────────────────────────────────────
section "Connect Tailscale"
# ─────────────────────────────────────────────────────────────────────────────
vm_ssh "sudo tailscale up \
    --authkey='${TAILSCALE_AUTHKEY}' \
    --hostname=nexusserver-railway \
    --accept-routes 2>/dev/null || true"
sleep 3
TAILSCALE_IP=$(vm_ssh "tailscale ip -4 2>/dev/null || echo pending" 2>/dev/null || echo "pending")
info "Tailscale IP: ${TAILSCALE_IP}"

# ─────────────────────────────────────────────────────────────────────────────
section "Server Is Live!"
# ─────────────────────────────────────────────────────────────────────────────
sleep 10
SSHX_LINK=$(vm_ssh "sudo journalctl -u sshx -n 20 --no-pager 2>/dev/null | grep -o 'https://sshx.io/s/[^ ]*' | tail -1 || echo 'not ready'" 2>/dev/null || echo "not ready")
PUBLIC_IP=$(vm_ssh "curl -s ifconfig.me 2>/dev/null" 2>/dev/null || echo "unknown")

echo ""
echo "======================================================="
echo "    NEXUSSERVER IS LIVE ON RAILWAY!"
echo "      Ubuntu 24.04 - Clean Server"
echo "======================================================="
echo "  Public IP:    ${PUBLIC_IP}"
echo "  Tailscale IP: ${TAILSCALE_IP}"
echo "======================================================="
echo "  SSH:      ssh nexus@${TAILSCALE_IP}"
echo "  Local:    ssh -p 2222 nexus@localhost"
echo "  TERMINAL: ${SSHX_LINK}"
echo "======================================================="
echo "  Chrome:   google-chrome-stable --no-sandbox"
echo "  Ports:    8080, 3000 forwarded"
echo "======================================================="

# ─────────────────────────────────────────────────────────────────────────────
section "Health Monitor (runs forever on Railway)"
# ─────────────────────────────────────────────────────────────────────────────
CYCLE=0
START=$(date +%s)

while true; do
    sleep 600
    CYCLE=$(( CYCLE + 1 ))
    ELAPSED=$(( ($(date +%s) - START) / 60 ))
    info "[health #${CYCLE}] Uptime: ${ELAPSED} min | $(date '+%Y-%m-%d %H:%M:%S')"
    vm_ssh "echo OK && tailscale ip -4 2>/dev/null && df -h / | tail -1" \
        2>/dev/null || warn "Health check #${CYCLE} failed"
done
