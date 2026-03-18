#!/usr/bin/env bash
# ============================================================
#  NexusServer - Railway entrypoint
#
#  Required environment variables (set in Railway dashboard):
#    HF_TOKEN          - Hugging Face token
#    SSH_PASSWORD      - Password for nexus VM user
#    TAILSCALE_AUTHKEY - Tailscale auth key
# ============================================================
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
section() { echo -e "\n${GREEN}======  $*  ======${NC}"; }

# ── validate required env vars ────────────────────────────────────────────────
for var in HF_TOKEN SSH_PASSWORD TAILSCALE_AUTHKEY; do
    if [[ -z "${!var:-}" ]]; then
        echo -e "${RED}[ERROR]${NC} Missing required environment variable: $var"
        exit 1
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
section "System Info"
# ─────────────────────────────────────────────────────────────────────────────
info "CPUs: $(nproc) | RAM: $(free -h | awk '/^Mem:/{print $2}')"
df -h / | tail -1

# Check KVM (won't be available on Railway but try anyway)
if [[ -e /dev/kvm ]]; then
    chmod 666 /dev/kvm 2>/dev/null || true
    info "KVM available - hardware acceleration enabled!"
    KVM_FLAGS="-enable-kvm -cpu host,+x2apic"
else
    warn "No KVM - running in software emulation (TCG) mode"
    warn "VM will be slower but fully functional on Railway"
    # Use max CPU emulation performance without KVM
    KVM_FLAGS="-cpu qemu64,+ssse3,+sse4.1,+sse4.2,+popcnt -accel tcg,thread=multi"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "Download VM Image from Hugging Face"
# ─────────────────────────────────────────────────────────────────────────────
mkdir -p /vms
info "Downloading VM image via curl..."
HF_URL="https://huggingface.co/datasets/Paul1212crp/nexusserver-vm/resolve/main/nexusserver.img.compressed"
curl -L \
    -H "Authorization: Bearer ${HF_TOKEN}" \
    -o /vms/nexusserver.img \
    --progress-bar \
    --retry 3 \
    --retry-delay 5 \
    "${HF_URL}"

info "Image ready: $(du -sh /vms/nexusserver.img)"
qemu-img info /vms/nexusserver.img

# ─────────────────────────────────────────────────────────────────────────────
section "Boot VM"
# ─────────────────────────────────────────────────────────────────────────────
TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')
VM_RAM=$(( TOTAL_RAM * 80 / 100 ))
CPUS=$(nproc)
info "Allocating ${VM_RAM}MB RAM and ${CPUS} vCPUs"

qemu-system-x86_64 \
    $KVM_FLAGS \
    -machine q35,mem-merge=off \
    -m 35840 \
    -smp 8,sockets=1,cores=8,threads=1 \
    -drive file=/vms/nexusserver.img,format=qcow2,if=virtio,cache=writeback,discard=unmap,aio=threads,l2-cache-size=256M \
    -boot order=c \
    -device e1000,netdev=n0 \
    -netdev user,id=n0,hostfwd=tcp::2222-:22,hostfwd=tcp::8443-:8443,hostfwd=tcp::8080-:8080,hostfwd=tcp::3000-:3000,hostfwd=tcp::2055-:2055 \
    -object rng-random,filename=/dev/urandom,id=rng0 \
    -device virtio-rng-pci,rng=rng0 \
    -watchdog-action reset \
    -serial file:/vms/nexusserver.serial.log \
    -monitor unix:/vms/nexusserver.monitor,server,nowait \
    -display none \
    -daemonize \
    -pidfile /vms/nexusserver.pid

info "VM booted!"

# ─────────────────────────────────────────────────────────────────────────────
section "Wait for SSH"
# ─────────────────────────────────────────────────────────────────────────────
info "Waiting for VM SSH..."
VM_READY=false
for i in $(seq 1 120); do
    if sshpass -p "$SSH_PASSWORD" \
        ssh -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=5 \
            -p 2222 nexus@localhost \
            "echo SSH_READY" 2>/dev/null | grep -q "SSH_READY"; then
        info "VM SSH ready after ${i}0s!"
        VM_READY=true
        break
    fi
    # TCG is slower to boot - log every 30s
    if (( i % 3 == 0 )); then
        info "Still waiting... ${i}0s elapsed"
        tail -2 /vms/nexusserver.serial.log 2>/dev/null || true
    fi
    sleep 10
done

if [[ "$VM_READY" != "true" ]]; then
    warn "VM SSH never became ready. Serial log:"
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
section "Start Tailscale inside VM"
# ─────────────────────────────────────────────────────────────────────────────
vm_ssh "sudo tailscale up \
    --authkey='${TAILSCALE_AUTHKEY}' \
    --hostname=nexusserver-railway \
    --accept-routes 2>/dev/null || true"
sleep 3
TAILSCALE_IP=$(vm_ssh "tailscale ip -4 2>/dev/null || echo pending" 2>/dev/null || echo "pending")
info "Tailscale IP: ${TAILSCALE_IP}"

# ─────────────────────────────────────────────────────────────────────────────
section "Setup sshx Service inside VM"
# ─────────────────────────────────────────────────────────────────────────────
# Systemd unit content base64-encoded to avoid shell quoting issues
SSHX_UNIT_B64="W1VuaXRdCkRlc2NyaXB0aW9uPXNzaHggdGVybWluYWwgc2hhcmluZwpBZnRlcj1uZXR3b3JrLnRhcmdldAoKW1NlcnZpY2VdClR5cGU9c2ltcGxlClVzZXI9bmV4dXMKR3JvdXA9bmV4dXMKRXhlY1N0YXJ0UHJlPS9iaW4vYmFzaCAtYyAicGtpbGwgLTkgc3NoeCB8fCB0cnVlOyBzbGVlcCAxIgpFeGVjU3RhcnQ9L3Vzci9sb2NhbC9iaW4vc3NoeApSZXN0YXJ0PWFsd2F5cwpSZXN0YXJ0U2VjPTEwCgpbSW5zdGFsbF0KV2FudGVkQnk9bXVsdGktdXNlci50YXJnZXQK"

vm_ssh "
    sudo systemctl stop sshx 2>/dev/null || true
    echo '$SSHX_UNIT_B64' | base64 -d | sudo tee /etc/systemd/system/sshx.service > /dev/null
    sudo systemctl daemon-reload
    sudo systemctl enable sshx
    sudo systemctl restart sshx
    sleep 3
    echo 'sshx started'
"

# ─────────────────────────────────────────────────────────────────────────────
section "Start Pelican Services"
# ─────────────────────────────────────────────────────────────────────────────
vm_ssh bash << ENDSSH
    echo "=== Fixing Nginx ==="
    sudo sed -i '/# Disable caching for Livewire/,/^}/d' /etc/nginx/sites-available/pelican.conf 2>/dev/null || true
    sudo nginx -t 2>/dev/null && sudo systemctl restart nginx 2>/dev/null || true

    echo "=== Starting Services ==="
    if [[ -f /root/.pelican.env ]] || [[ -f /var/www/pelican/.env ]]; then
        BASE_URL="https://raw.githubusercontent.com/Adexx-11234/newrepo/main"
        curl -fsSL "\${BASE_URL}/restart.sh" -o /tmp/nexus-restart.sh
        sudo bash /tmp/nexus-restart.sh
        rm -f /tmp/nexus-restart.sh
    else
        echo "WARNING: No Pelican config found!"
    fi

    echo "=== Services Status ==="
    sudo systemctl is-active wings nginx php8.3-fpm cloudflared 2>/dev/null || true
ENDSSH

# ─────────────────────────────────────────────────────────────────────────────
section "NexusServer is Live on Railway!"
# ─────────────────────────────────────────────────────────────────────────────
sleep 10
SSHX_LINK=$(vm_ssh "sudo journalctl -u sshx -n 20 --no-pager 2>/dev/null | grep -o 'https://sshx.io/s/[^ ]*' | tail -1 || echo 'not ready'" 2>/dev/null || echo "not ready")
PUBLIC_IP=$(vm_ssh "curl -s ifconfig.me 2>/dev/null" 2>/dev/null || echo "unknown")

echo ""
echo "======================================================="
echo "       NEXUSSERVER IS LIVE ON RAILWAY!"
echo "         Created by NexusTechPro"
echo "======================================================="
echo "  Public IP:    ${PUBLIC_IP}"
echo "  Tailscale IP: ${TAILSCALE_IP}"
echo "======================================================="
echo "  Panel:   https://panel.nexusbot.qzz.io"
echo "  Wings:   https://node-1.nexusbot.qzz.io"
echo "======================================================="
echo "  TERMINAL: ${SSHX_LINK}"
echo "  SSH:      ssh nexus@${TAILSCALE_IP}"
echo "======================================================="

# ─────────────────────────────────────────────────────────────────────────────
section "Health Monitor (Railway runs forever)"
# ─────────────────────────────────────────────────────────────────────────────
# Railway keeps container alive 24/7 - just health check every 10 mins
CYCLE=0
START=$(date +%s)

while true; do
    sleep 600
    CYCLE=$(( CYCLE + 1 ))
    ELAPSED=$(( ($(date +%s) - START) / 60 ))
    info "[health #${CYCLE}] Uptime: ${ELAPSED} min | $(date '+%Y-%m-%d %H:%M:%S')"
    vm_ssh "echo OK && sudo systemctl is-active wings nginx 2>/dev/null && tailscale ip -4 2>/dev/null" \
        2>/dev/null || warn "Health check #${CYCLE} failed"
done
