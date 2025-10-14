if command -v limine &>/dev/null; then
  # Detect EFI vs BIOS
  [[ -d /sys/firmware/efi ]] && EFI=true

  # Determine config location
  if [[ -n "$EFI" ]]; then
    # Check USB location first, then regular EFI location
    if [[ -f /boot/EFI/BOOT/limine.conf ]]; then
      limine_config="/boot/EFI/BOOT/limine.conf"
    else
      limine_config="/boot/EFI/limine/limine.conf"
    fi
  else
    limine_config="/boot/limine/limine.conf"
  fi

  # If config doesn't exist, create initial Limine setup
  if [[ ! -f $limine_config ]]; then
    echo "Limine config not found at $limine_config, creating initial setup..."

    # Install Limine bootloader
    if [[ -n "$EFI" ]]; then
      # EFI installation
      sudo mkdir -p /boot/EFI/BOOT
      sudo cp /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/
      limine_config="/boot/EFI/BOOT/limine.conf"
    else
      # BIOS installation
      boot_disk=$(findmnt -n -o SOURCE /boot | sed 's/p\?[0-9]*$//')
      sudo limine bios-install "$boot_disk"
      sudo mkdir -p /boot/limine
      sudo cp /usr/share/limine/limine-bios.sys /boot/limine/
      limine_config="/boot/limine/limine.conf"
    fi

    # Get root device and kernel parameters
    root_dev=$(findmnt -n -o SOURCE /)
    root_uuid=$(findmnt -n -o UUID /)

    # Build initial cmdline with dracut syntax
    if cryptsetup status root &>/dev/null; then
      # Encrypted root - get the actual LUKS UUID (not PARTUUID!)
      luks_dev=$(cryptsetup status root | grep "device:" | awk '{print $2}')
      luks_uuid=$(cryptsetup luksUUID "$luks_dev" 2>/dev/null)

      if [ -n "$luks_uuid" ]; then
        # Use dracut syntax with LUKS UUID
        CMDLINE="rd.luks.uuid=$luks_uuid rd.luks.name=${luks_uuid}=root root=/dev/mapper/root"
      else
        # Fallback if luksUUID fails
        echo "Warning: Could not get LUKS UUID, using fallback"
        CMDLINE="root=/dev/mapper/root"
      fi
    else
      # Unencrypted root
      CMDLINE="root=UUID=$root_uuid"
    fi
    CMDLINE="$CMDLINE rw"

    # Create initial limine.conf
    sudo tee "$limine_config" <<EOF >/dev/null
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

EOF
  else
    # Config exists, extract existing cmdline
    CMDLINE=$(grep "^[[:space:]]*cmdline:" "$limine_config" | head -1 | sed 's/^[[:space:]]*cmdline:[[:space:]]*//')
  fi

  sudo tee /etc/default/limine <<EOF >/dev/null
TARGET_OS_NAME="Omarchy"

ESP_PATH="/boot"

KERNEL_CMDLINE[default]="$CMDLINE"
# Temporarily disabled for LUKS debugging - re-enable once password unlock works
# KERNEL_CMDLINE[default]+="quiet splash"

# Enable dracut btrfs snapshot overlayfs support
KERNEL_CMDLINE[Snapshots]="$CMDLINE"
KERNEL_CMDLINE[Snapshots]+="quiet splash rd.live.overlay.overlayfs=1"

ENABLE_UKI=yes

ENABLE_LIMINE_FALLBACK=yes

# Find and add other bootloaders
FIND_BOOTLOADERS=yes

BOOT_ORDER="*, *fallback, Snapshots"

MAX_SNAPSHOT_ENTRIES=5

SNAPSHOT_FORMAT_CHOICE=5
EOF

  # UKI and EFI fallback are EFI only
  if [[ -z $EFI ]]; then
    sudo sed -i '/^ENABLE_UKI=/d; /^ENABLE_LIMINE_FALLBACK=/d' /etc/default/limine
  fi

  # We overwrite the whole thing knowing the limine-update will add the entries for us
  sudo tee /boot/limine.conf <<EOF >/dev/null
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
 
EOF

  sudo pacman -S --noconfirm --needed limine-snapper-sync

  # Match Snapper configs if not installing from the ISO
  if [[ -z ${OMARCHY_CHROOT_INSTALL:-} ]]; then
    if ! sudo snapper list-configs 2>/dev/null | grep -q "root"; then
      sudo snapper -c root create-config /
    fi

    if ! sudo snapper list-configs 2>/dev/null | grep -q "home"; then
      sudo snapper -c home create-config /home
    fi
  fi

  # Tweak default Snapper configs
  sudo sed -i 's/^TIMELINE_CREATE="yes"/TIMELINE_CREATE="no"/' /etc/snapper/configs/{root,home}
  sudo sed -i 's/^NUMBER_LIMIT="50"/NUMBER_LIMIT="5"/' /etc/snapper/configs/{root,home}
  sudo sed -i 's/^NUMBER_LIMIT_IMPORTANT="10"/NUMBER_LIMIT_IMPORTANT="5"/' /etc/snapper/configs/{root,home}

  chrootable_systemctl_enable limine-snapper-sync.service
fi

# Add UKI entry to UEFI machines to skip bootloader showing on normal boot
if [[ -n $EFI ]] && efibootmgr &>/dev/null && ! efibootmgr | grep -q Omarchy &&
  ! cat /sys/class/dmi/id/bios_vendor 2>/dev/null | grep -qi "American Megatrends" &&
  ! cat /sys/class/dmi/id/bios_vendor 2>/dev/null | grep -qi "Apple"; then
  sudo efibootmgr --create \
    --disk "$(findmnt -n -o SOURCE /boot | sed 's/p\?[0-9]*$//')" \
    --part "$(findmnt -n -o SOURCE /boot | grep -o 'p\?[0-9]*$' | sed 's/^p//')" \
    --label "Omarchy" \
    --loader "\\EFI\\Linux\\$(cat /etc/machine-id)_linux.efi"
fi
