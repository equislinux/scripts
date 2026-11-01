#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------------
# QEMU / KVM / LIBVIRT Installation Script
# -------------------------------------------------------------------------

echo "[XOs] Installing Virtualization Stack (QEMU + Libvirt)..."

log() {
    echo -e "\033[1;32m[XOs]\033[0m $1"
}

run_privileged() {
    if [ "$EUID" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/install/helpers/pkg.sh"

# -------------------------------------------------------------------------
# 1. INSTALL PACKAGES
# -------------------------------------------------------------------------

# Package list updated for 2024/Arch best practices
# - qemu-desktop: Meta package for desktop use (replacing huge qemu-full) or qemu-base
# - dnsmasq: For NAT networking
# - iptables-nft: Modern firewall backend for libvirt NAT
# - swtpm: TPM emulator (Required for Windows 11)
# - edk2-ovmf: UEFI firmware

PKGS=(
    qemu-desktop
    libvirt
    virt-manager
    virt-viewer
    dnsmasq
    vde2
    bridge-utils
    openbsd-netcat
    edk2-ovmf
    swtpm
    iptables-nft
    guestfs-tools
)

log "Installing packages: ${PKGS[*]}"
x_pkg_install "${PKGS[@]}"

# -------------------------------------------------------------------------
# 2. CONFIGURE LIBVIRT
# -------------------------------------------------------------------------

log "Enabling libvirt services..."
# Enable daemon and socket activation
run_privileged systemctl enable --now libvirtd.service
run_privileged systemctl enable --now virtlogd.socket
# virtlockd is often managed automatically but good to ensure
run_privileged systemctl enable --now virtlockd.socket

# -------------------------------------------------------------------------
# 3. USER PERMISSIONS
# -------------------------------------------------------------------------

CURRENT_USER="${SUDO_USER:-$(whoami)}"
log "Adding user '$CURRENT_USER' to libvirt groups..."

# libvirt: Manage VMs
# kvm: Hardware acceleration access
# input: Input devices (sometimes needed)
# disk: Disk access (sometimes needed, use with caution, sticking to libvirt/kvm is safer usually)

run_privileged usermod -aG libvirt,kvm,input "$CURRENT_USER"

# -------------------------------------------------------------------------
# 4. CONFIGURE NETWORKING
# -------------------------------------------------------------------------

log "Configuring default NAT network..."

# Check if default network exists
if ! list_networks=$(run_privileged virsh net-list --all); then
    # Usually fails if permissions aren't refresh, run as root/sudo
    true
fi

# Define if missing (file usually at /usr/share/libvirt/networks/default.xml)
if [ -f /usr/share/libvirt/networks/default.xml ]; then
    run_privileged virsh net-define /usr/share/libvirt/networks/default.xml 2>/dev/null || true
fi

# Autostart and Start
run_privileged virsh net-autostart default || true
run_privileged virsh net-start default || true

# -------------------------------------------------------------------------
# 5. CONFIGURE KVM (MODULES)
# -------------------------------------------------------------------------

# Optional: Set kvm_intel nested=1 for nested virtualization if desired, 
# but for now we just verify modules are loaded.
log "Checking KVM modules..."
if lsmod | grep -q kvm; then
    log "KVM modules loaded."
else
    log "KVM modules NOT loaded. Loading..."
    run_privileged modprobe kvm || true
    # Attempt to load specific CPU module
    run_privileged modprobe kvm_intel || run_privileged modprobe kvm_amd || true
fi

# -------------------------------------------------------------------------
# FINISH
# -------------------------------------------------------------------------

log "Installation complete!"
log "1. Please REBOOT or LOG OUT/IN to apply group permissions."
log "2. Run 'virt-manager' to start."