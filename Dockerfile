# ============================================================
#  NexusServer - Railway Deployment
#
#  Set these in Railway dashboard -> Variables:
#    HF_TOKEN          - Hugging Face token
#    SSH_PASSWORD      - Password for nexus VM user
#    TAILSCALE_AUTHKEY - Tailscale auth key
#
#  No KVM required - runs QEMU in software emulation (TCG)
#  Railway keeps it alive 24/7 with no restarts needed
# ============================================================

FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV HF_HUB_ENABLE_HF_TRANSFER=1

# Install QEMU (software emulation, no KVM), network tools, Python
RUN apt-get update -qq && \
    apt-get install -y \
        qemu-system-x86 \
        qemu-utils \
        openssh-client \
        sshpass \
        curl \
        wget \
        socat \
        iproute2 \
        iptables \
        ca-certificates \
        python3 \
        python3-pip && \
    pip3 install --break-system-packages huggingface_hub hf_transfer && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Install Tailscale
RUN curl -fsSL https://tailscale.com/install.sh | sh

# Create TUN device node for Tailscale
RUN mkdir -p /dev/net && \
    mknod /dev/net/tun c 10 200 2>/dev/null || true

# Install sshx
RUN curl -sSf https://sshx.io/get | sh

RUN mkdir -p /vms /app
WORKDIR /app

COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

EXPOSE 2222 8443 8080 3000 2055

ENTRYPOINT ["/app/entrypoint.sh"]
