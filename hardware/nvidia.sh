#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------------
# HELPER FUNCTIONS
# -------------------------------------------------------------------------

log() {
    echo -e "\033[1;32m[XOs]\033[0m $1"
}

warn() {
    echo -e "\033[1;33m[WARNING]\033[0m $1"
}

error() {
    echo -e "\033[1;31m[ERROR]\033[0m $1"
    exit 1
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
# PRE-FLIGHT CHECKS
# -------------------------------------------------------------------------

log "Starting proprietary NVIDIA driver installation..."

# Check if multilib is enabled in pacman.conf
MULTILIB_ENABLED=false
if grep -q "^\[multilib\]" /etc/pacman.conf; then
    MULTILIB_ENABLED=true
    log "Multilib repository detected."
fi

# -------------------------------------------------------------------------
# 1. REMOVE OPEN-SOURCE DRIVERS
# -------------------------------------------------------------------------

if x_pkg_installed vulkan-nouveau || x_pkg_installed xf86-video-nouveau; then
    log "Removing open-source drivers (nouveau)..."
    x_pkg_remove --recursive --nosave vulkan-nouveau xf86-video-nouveau || true
fi

# -------------------------------------------------------------------------
# 2. INSTALL NVIDIA PACKAGES
# -------------------------------------------------------------------------

PACKAGES="nvidia nvidia-utils nvidia-settings opencl-nvidia egl-wayland libva-nvidia-driver"

if [ "$MULTILIB_ENABLED" = true ]; then
    PACKAGES="$PACKAGES lib32-nvidia-utils lib32-opencl-nvidia"
fi

log "Installing NVIDIA packages: $PACKAGES"
x_pkg_install $PACKAGES

# -------------------------------------------------------------------------
# 3. CONFIGURE MKINITCPIO (EARLY LOADING)
# -------------------------------------------------------------------------

log "Configuring early loading (mkinitcpio)..."

MKINIT_CONF="/etc/mkinitcpio.conf"

if [ -f "$MKINIT_CONF" ]; then
    # Helper to check if a module is already in the list
    if ! grep -q "nvidia_drm" "$MKINIT_CONF"; then
        log "Adding nvidia modules to $MKINIT_CONF..."
        # Backup first
        run_privileged cp "$MKINIT_CONF" "${MKINIT_CONF}.bak"
        
        # Add modules. We use sed to insert them if they aren't there.
        # This regex looks for MODULES=(...) and inserts nvidia modules inside the parentheses
        # Attempting to be safe: replacing 'MODULES=(' with 'MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm '
        # But only if they don't exist. using a simpler approach is safer:
        
        run_privileged sed -i 's/^MODULES=(\(.*\))/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm \1)/' "$MKINIT_CONF"
        
        # Clean up double spaces if any
        run_privileged sed -i 's/( /(/g; s/  / /g' "$MKINIT_CONF"
        
        log "Rebuilding initramfs..."
        run_privileged mkinitcpio -P
    else
        log "Nvidia modules already present in mkinitcpio.conf. Skipping..."
    fi
else
    warn "$MKINIT_CONF not found. Skipping early loading configuration."
fi

# -------------------------------------------------------------------------
# 4. CONFIGURE BOOTLOADER (KERNEL PARAMETERS)
# -------------------------------------------------------------------------

# Parameters to add: nvidia-drm.modeset=1 (mandatory for Wayland) and nvidia-drm.fbdev=1 (modern, for smooth tty)
KERNEL_PARAMS="nvidia-drm.modeset=1 nvidia-drm.fbdev=1"

log "Detecting bootloader..."

if command -v bootctl &>/dev/null && bootctl is-installed &>/dev/null; then
    BOOTLOADER="systemd-boot"
    log "Bootloader detected: systemd-boot"
elif [ -d "/sys/firmware/efi" ] && [ -f "/boot/grub/grub.cfg" ]; then
    BOOTLOADER="grub"
    log "Bootloader detected: Grub (EFI)"
elif [ -f "/boot/grub/grub.cfg" ]; then
    BOOTLOADER="grub"
    log "Bootloader detected: Grub (BIOS)"
else
    BOOTLOADER="unknown"
    warn "Could not reliably detect bootloader (Grub/systemd-boot). You may need to add kernel parameters manually: $KERNEL_PARAMS"
fi

apply_kernel_params_grub() {
    GRUB_CONF="/etc/default/grub"
    if [ -f "$GRUB_CONF" ]; then
        log "Updating Grub configuration..."
        
        # Check if params already exist to avoid duplication
        CURRENT_PARAMS=$(grep "^GRUB_CMDLINE_LINUX_DEFAULT=" "$GRUB_CONF" | cut -d'"' -f2)
        
        NEW_PARAMS="$CURRENT_PARAMS"
        if [[ "$CURRENT_PARAMS" != *"nvidia-drm.modeset=1"* ]]; then
            NEW_PARAMS="$NEW_PARAMS nvidia-drm.modeset=1"
        fi
        if [[ "$CURRENT_PARAMS" != *"nvidia-drm.fbdev=1"* ]]; then
            NEW_PARAMS="$NEW_PARAMS nvidia-drm.fbdev=1"
        fi
        
        if [ "$CURRENT_PARAMS" != "$NEW_PARAMS" ]; then
            # Escape sed replacement
            ESCAPED_PARAMS=$(echo "$NEW_PARAMS" | sed 's/[\/&]/\\&/g')
             run_privileged sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=\".*\"/GRUB_CMDLINE_LINUX_DEFAULT=\"$ESCAPED_PARAMS\"/" "$GRUB_CONF"
             
             log "Regenerating Grub config..."
             run_privileged grub-mkconfig -o /boot/grub/grub.cfg
        else
            log "Kernel parameters already set in Grub."
        fi
    else
        warn "/etc/default/grub not found."
    fi
}

apply_kernel_params_systemd_boot() {
    ENTRIES_DIR="/boot/loader/entries"
    if [ -d "$ENTRIES_DIR" ]; then
        log "Updating systemd-boot entries in $ENTRIES_DIR..."
        
        # Update all conf files
        for entry in "$ENTRIES_DIR"/*.conf; do
            [ -f "$entry" ] || continue
            
            # Check if options line exists
            if grep -q "^options" "$entry"; then
                # Append if not present
                if ! grep -q "nvidia-drm.modeset=1" "$entry"; then
                     run_privileged sed -i '/^options/ s/$/ nvidia-drm.modeset=1/' "$entry"
                fi
                if ! grep -q "nvidia-drm.fbdev=1" "$entry"; then
                     run_privileged sed -i '/^options/ s/$/ nvidia-drm.fbdev=1/' "$entry"
                fi
            else
                # If no options line (rare but possible), append it
                echo "options root=PARTUUID=... $KERNEL_PARAMS"
                warn "Entry $entry has no options line. Skipped automatic update specific to this file to avoid breaking boot."
            fi
        done
    else
         warn "Systemd-boot entries directory not found."
    fi
}

if [ "$BOOTLOADER" == "grub" ]; then
    apply_kernel_params_grub
elif [ "$BOOTLOADER" == "systemd-boot" ]; then
    apply_kernel_params_systemd_boot
fi

# -------------------------------------------------------------------------
# 5. CREATE MODPROBE CONFIG
# -------------------------------------------------------------------------

log "Configuring modprobe..."
# Force modeset just in case
run_privileged bash -c 'echo "options nvidia_drm modeset=1 fbdev=1" > /etc/modprobe.d/nvidia.conf'

# -------------------------------------------------------------------------
# 6. ENABLE SERVICES
# -------------------------------------------------------------------------

log "Enabling NVIDIA services..."

# Power management services
run_privileged systemctl enable --now nvidia-suspend.service
run_privileged systemctl enable --now nvidia-hibernate.service
run_privileged systemctl enable --now nvidia-resume.service

# Persistenced (optional but good for wayland/desktop response)
# run_privileged systemctl enable --now nvidia-persistenced.service

# Powerd (for laptops/TDP management, failure tolerant)
run_privileged systemctl enable --now nvidia-powerd.service || true

# -------------------------------------------------------------------------
# FINISH
# -------------------------------------------------------------------------

log "Installation complete!"
log "Changes applied:"
log "- Drivers installed"
log "- Initramfs updated (early loading)"
log "- Kernel parameters added ($BOOTLOADER)"
log "- Services enabled"

log "Please REBOOT your system to apply changes."
