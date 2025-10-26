#!/usr/bin/env bash

echo "Setting up dracut initramfs generation..."

# Install base dracut configuration
if [ -f "$OMARCHY_INSTALL/config/dracut/10-omarchy.conf" ]; then
  echo "Installing base dracut configuration..."
  sudo install -Dm644 "$OMARCHY_INSTALL/config/dracut/10-omarchy.conf" /etc/dracut.conf.d/10-omarchy.conf
  echo "Base configuration installed: /etc/dracut.conf.d/10-omarchy.conf"
else
  echo "Warning: Base dracut config not found at $OMARCHY_INSTALL/config/dracut/10-omarchy.conf"
fi

# Install hardware-specific configurations if they exist
if [ -f "$OMARCHY_INSTALL/config/dracut/20-apple-t2.conf" ]; then
  echo "Installing Apple T2 configuration..."
  sudo install -Dm644 "$OMARCHY_INSTALL/config/dracut/20-apple-t2.conf" /etc/dracut.conf.d/20-apple-t2.conf
fi

if [ -f "$OMARCHY_INSTALL/config/dracut/21-apple-spi.conf" ]; then
  echo "Installing Apple SPI configuration..."
  sudo install -Dm644 "$OMARCHY_INSTALL/config/dracut/21-apple-spi.conf" /etc/dracut.conf.d/21-apple-spi.conf
fi

if [ -f "$OMARCHY_INSTALL/config/dracut/30-nvidia.conf" ]; then
  echo "Installing NVIDIA configuration..."
  sudo install -Dm644 "$OMARCHY_INSTALL/config/dracut/30-nvidia.conf" /etc/dracut.conf.d/30-nvidia.conf
fi

# Install Limine integration pacman hook
#if [ -f "$OMARCHY_INSTALL/config/hooks/95-limine-dracut.hook" ]; then
#  echo "Installing Limine dracut integration hook..."
#  sudo install -Dm644 "$OMARCHY_INSTALL/config/hooks/95-limine-dracut.hook" /usr/share/libalpm/hooks/95-limine-dracut.hook
#  echo "Limine hook installed: /usr/share/libalpm/hooks/95-limine-dracut.hook"
#else
#  echo "Warning: Limine hook not found at $OMARCHY_INSTALL/config/hooks/95-limine-dracut.hook"
#fi

# Re-enable dracut hooks (reverse what disable-dracut-hooks.sh did)
echo "Re-enabling dracut pacman hooks..."

if [ -f /usr/share/libalpm/hooks/90-dracut-install.hook.disabled ]; then
  sudo mv /usr/share/libalpm/hooks/90-dracut-install.hook.disabled /usr/share/libalpm/hooks/90-dracut-install.hook
  echo "Re-enabled: 90-dracut-install.hook"
fi

if [ -f /usr/share/libalpm/hooks/60-dracut-remove.hook.disabled ]; then
  sudo mv /usr/share/libalpm/hooks/60-dracut-remove.hook.disabled /usr/share/libalpm/hooks/60-dracut-remove.hook
  echo "Re-enabled: 60-dracut-remove.hook"
fi

echo "dracut hooks re-enabled"

# Generate initial dracut images for all installed kernels
echo "Generating initramfs images for all installed kernels..."
if command -v dracut &>/dev/null; then
  sudo dracut --force --hostonly --regenerate-all
  echo "Initramfs generation complete"
else
  echo "Warning: dracut command not found - skipping initramfs generation"
fi

echo "dracut setup complete"

# Create initial boot entry manually (limine-snapper-sync will update on first boot)
echo "Creating initial boot entry..."

# Determine correct limine.conf location
if [[ -d /sys/firmware/efi ]]; then
  # EFI system
  if [[ -f /boot/EFI/BOOT/limine.conf ]]; then
    limine_config="/boot/EFI/BOOT/limine.conf"
  else
    limine_config="/boot/EFI/limine/limine.conf"
  fi
else
  # BIOS system
  limine_config="/boot/limine/limine.conf"
fi

# Get kernel version
kernel_version=$(ls /boot/vmlinuz-* 2>/dev/null | head -1 | sed 's/.*vmlinuz-//')
if [ -z "$kernel_version" ]; then
  echo "Warning: No kernel found in /boot"
else
  # Get initramfs path
  initramfs_path="/boot/initramfs-${kernel_version}.img"

  # IMPORTANT: Do NOT use /etc/default/limine - it has mkinitcpio syntax
  # We must detect LUKS ourselves and use dracut syntax

  echo "========================================="
  echo "BREADCRUMB: Reading LUKS info from pre-chroot detection"
  echo "========================================="

  # Read LUKS UUID from file created by preflight/detect-luks.sh (runs BEFORE chroot)
  # This is more reliable than trying to detect LUKS from inside chroot
  luks_uuid=""
  luks_dev=""

  if [ -f "/.luks_uuid" ]; then
    luks_uuid=$(cat /.luks_uuid 2>/dev/null | tr -d '[:space:]')
    luks_dev=$(cat /.luks_device 2>/dev/null | tr -d '[:space:]')
    echo "BREADCRUMB: Found pre-detected LUKS info:"
    echo "BREADCRUMB:   UUID: $luks_uuid"
    echo "BREADCRUMB:   Device: $luks_dev"
  else
    echo "BREADCRUMB: No /.luks_uuid file found - assuming unencrypted installation"
  fi

  # Build cmdline based on LUKS detection
  if [ -n "$luks_uuid" ]; then
    echo "BREADCRUMB: *** ENCRYPTED ROOT PATH ***"

    # Get root filesystem info for additional parameters
    root_fstype=$(findmnt -n -o FSTYPE / 2>/dev/null)
    root_opts=""
    echo "BREADCRUMB: Root fstype: $root_fstype"

    if [ "$root_fstype" = "btrfs" ]; then
      root_subvol=$(findmnt -n -o OPTIONS / 2>/dev/null | grep -oP 'subvol=\K[^,]+' || echo "@")
      root_opts="rootflags=subvol=$root_subvol rootfstype=btrfs"
      echo "BREADCRUMB: Btrfs subvol: $root_subvol"
    fi

    # Build dracut-compatible cmdline with LUKS parameters
    cmdline="rd.luks.uuid=$luks_uuid rd.luks.name=${luks_uuid}=root root=/dev/mapper/root $root_opts rw"
    echo "BREADCRUMB: Generated LUKS cmdline: $cmdline"
  else
    # No LUKS - unencrypted root
    echo "BREADCRUMB: *** UNENCRYPTED ROOT PATH ***"

    root_uuid=$(findmnt -n -o UUID / 2>/dev/null)
    echo "BREADCRUMB: Root UUID: $root_uuid"

    if [ -n "$root_uuid" ]; then
      cmdline="root=UUID=$root_uuid rw"
    else
      echo "BREADCRUMB: ERROR - Could not determine root device"
      cmdline="root=/dev/mapper/root rw"
    fi
  fi

  echo "BREADCRUMB: FINAL cmdline = $cmdline"
  echo "========================================="

  # HOSTILE TAKEOVER: Completely overwrite limine.conf to ensure dracut boot entry exists
  # limine-snapper.sh creates the header, but we need to add the actual boot entry
  # limine-snapper-sync.service will manage entries on subsequent boots
  echo "BREADCRUMB: Writing boot entry to ${limine_config}..."
  sudo tee "${limine_config}" <<EOF >/dev/null
### Read more at config document: https://github.com/limine-bootloader/limine/blob/trunk/CONFIG.md
#timeout: 3
default_entry: 2
interface_branding: Omarchy Bootloader
interface_branding_color: 2
hash_mismatch_panic: no

term_background: 1a1b26
backdrop: 1a1b26

# Terminal colors (Tokyo Night palette)
term_palette: 15161e;f7768e;9ece6a;e0af68;7aa2f7;bb9af7;7dcfff;a9b1d6
term_palette_bright: 414868;f7768e;9ece6a;e0af68;7aa2f7;bb9af7;7dcfff;c0caf5

# Text colors
term_foreground: c0caf5
term_foreground_bright: c0caf5
term_background_bright: 24283b

# Omarchy Boot Entry (dracut-compatible)
/Omarchy
  protocol: linux
  kernel_path: boot():/vmlinuz-${kernel_version}
  module_path: boot():/initramfs-${kernel_version}.img
  cmdline: ${cmdline}
EOF

  echo "BREADCRUMB: ✓ ${limine_config} written successfully"
  echo "BREADCRUMB: Boot entry created for kernel ${kernel_version}"
  echo "BREADCRUMB: limine-snapper-sync.service will manage entries on subsequent boots"
fi
