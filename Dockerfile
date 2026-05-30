# ============================================================
#  NexusServer - Railway Deployment
#
#  Required env vars (Railway dashboard -> Variables):
#    SSH_PASSWORD      - SSH password for the nexus user
#    TAILSCALE_AUTHKEY - Tailscale auth key
# ============================================================
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Install QEMU (TCG software emulation, no KVM required),
# SSH client, network tools, and Python
RUN apt-get update -qq && \
    apt-get install -y \
        qemu-system-x86 \
        qemu-utils \
        qemu-img \
        openssh-client \
        sshpass \
        curl \
        wget \
        socat \
        xz-utils \
        iproute2 \
        ca-certificates \
        python3 \
        python3-pip && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Install Tailscale
RUN curl -fsSL https://tailscale.com/install.sh | sh

# TUN device node for Tailscale
RUN mkdir -p /dev/net && \
    mknod /dev/net/tun c 10 200 2>/dev/null || true

# Install sshx
RUN curl -sSf https://sshx.io/get | sh

RUN mkdir -p /vms /app
WORKDIR /app

COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

EXPOSE 2222 8080 3000

ENTRYPOINT ["/app/entrypoint.sh"]
