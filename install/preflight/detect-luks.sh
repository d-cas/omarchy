#!/usr/bin/env bash

# This script runs BEFORE chroot to detect LUKS encryption and save the UUID
# for use by setup-dracut.sh and limine-snapper.sh which run INSIDE chroot.

echo "Pre-chroot: Detecting LUKS encryption..."

luks_uuid=""
luks_dev=""

# Method 1: Check if root is currently on a LUKS device (running from live environment)
root_source=$(findmnt -n -o SOURCE / 2>/dev/null)
echo "DEBUG: Current root source: $root_source"

if [[ "$root_source" == /dev/mapper/* ]]; then
  echo "DEBUG: Live environment root is on mapper device, checking for LUKS..."
  luks_dev=$(cryptsetup status "$root_source" 2>/dev/null | grep "device:" | awk '{print $2}')
  if [ -n "$luks_dev" ] && [ -b "$luks_dev" ]; then
    luks_uuid=$(cryptsetup luksUUID "$luks_dev" 2>/dev/null)
    echo "DEBUG: Found LUKS via current root: $luks_dev -> $luks_uuid"
  fi
fi

# Method 2: Scan all block devices for LUKS containers
if [ -z "$luks_uuid" ]; then
  echo "DEBUG: Scanning all block devices for LUKS containers..."
  for blockdev in /sys/class/block/*; do
    devname="/dev/$(basename "$blockdev")"

    # Skip loop devices, ram, and devices without partition numbers
    [[ "$devname" == /dev/loop* ]] && continue
    [[ "$devname" == /dev/ram* ]] && continue
    [[ ! "$devname" =~ [0-9]$ ]] && continue

    # Check if it's a LUKS device
    if [ -b "$devname" ] && cryptsetup isLuks "$devname" 2>/dev/null; then
      luks_uuid=$(cryptsetup luksUUID "$devname" 2>/dev/null)
      if [ -n "$luks_uuid" ]; then
        luks_dev="$devname"
        echo "DEBUG: Found LUKS device: $luks_dev with UUID: $luks_uuid"
        break
      fi
    fi
  done
fi

# Method 3: Check /mnt for mounted encrypted root (if installation already mounted it)
if [ -z "$luks_uuid" ]; then
  echo "DEBUG: Checking /mnt for encrypted root..."
  mnt_root=$(findmnt -n -o SOURCE /mnt 2>/dev/null)
  if [[ "$mnt_root" == /dev/mapper/* ]]; then
    luks_dev=$(cryptsetup status "$mnt_root" 2>/dev/null | grep "device:" | awk '{print $2}')
    if [ -n "$luks_dev" ] && [ -b "$luks_dev" ]; then
      luks_uuid=$(cryptsetup luksUUID "$luks_dev" 2>/dev/null)
      echo "DEBUG: Found LUKS via /mnt root: $luks_dev -> $luks_uuid"
    fi
  fi
fi

# Save results
if [ -n "$luks_uuid" ]; then
  echo "✓ LUKS encryption detected"
  echo "  Device: $luks_dev"
  echo "  UUID: $luks_uuid"

  # Save to file that will be accessible in chroot
  echo "$luks_uuid" > /mnt/.luks_uuid
  echo "$luks_dev" > /mnt/.luks_device
  chmod 644 /mnt/.luks_uuid /mnt/.luks_device

  echo "✓ Saved LUKS info to /mnt/.luks_uuid for use by setup-dracut.sh"
else
  echo "ℹ No LUKS encryption detected - unencrypted installation"
  # Remove any old files to be sure
  rm -f /mnt/.luks_uuid /mnt/.luks_device 2>/dev/null
fi

echo "Pre-chroot LUKS detection complete"
