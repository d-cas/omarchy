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

# Get kernel version
kernel_version=$(ls /boot/vmlinuz-* 2>/dev/null | head -1 | sed 's/.*vmlinuz-//')
if [ -z "$kernel_version" ]; then
  echo "Warning: No kernel found in /boot"
else
  # Get initramfs path
  initramfs_path="/boot/initramfs-${kernel_version}.img"

  # Get kernel cmdline from /etc/default/limine if it exists
  if [ -f /etc/default/limine ]; then
    cmdline=$(grep '^KERNEL_CMDLINE\[default\]=' /etc/default/limine | head -1 | sed 's/^KERNEL_CMDLINE\[default\]="\(.*\)"$/\1/')
    if [ -z "$cmdline" ]; then
      # Fallback: detect LUKS
      if cryptsetup status root &>/dev/null; then
        luks_dev=$(cryptsetup status root | grep "device:" | awk '{print $2}')
        luks_uuid=$(blkid -s UUID -o value "$luks_dev")
        cmdline="root=/dev/mapper/root rd.luks.uuid=$luks_uuid rd.luks.name=${luks_uuid}=root rw quiet splash"
      else
        root_uuid=$(findmnt -n -o UUID /)
        cmdline="root=UUID=$root_uuid rw quiet splash"
      fi
    fi
  fi

  # Append to limine.conf
  echo "Adding boot entry for kernel ${kernel_version}..."
  sudo tee -a /boot/limine.conf <<EOF >/dev/null

# Default Omarchy Boot Entry
/Omarchy
  protocol: linux
  kernel_path: boot():/vmlinuz-${kernel_version}
  module_path: boot():/initramfs-${kernel_version}.img
  cmdline: ${cmdline}
EOF

  echo "Boot entry created successfully"
  echo "limine-snapper-sync.service will manage entries on subsequent boots"
fi
