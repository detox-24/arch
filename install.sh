#!/bin/bash
set -e

# ------------------------!!GUM SETUP!!----------------------------------
if ! command -v gum &>/dev/null; then
  pacman -Sy --noconfirm gum || {
    exit 1
  }
fi

# ------------------------!!ROOT & NETWORK CHECK!!-----------------------
gum style --foreground 20 "Heya! You're going to use Arch btw"

if [[ $EUID -ne 0 ]]; then
  gum style --foreground 1 "Requires root access"
  exit 1
fi

ping -c 5 archlinux.org > /dev/null
if [[ $? -ne 0 ]]; then
  gum style --foreground 1 "No active internet connection"
  exit 1
fi

timedatectl set-ntp true

gum style --foreground 10 "Enabled Time Sync"

#-------------------------!!USER CHOICE!!--------------------------------
USERNAME=$(gum input --placeholder "Enter username: ")
if [[ -z "$USERNAME" ]]; then
  gum style --foreground 1 "Username cannot be empty"
  exit 1
fi

DESKTOP=$(gum choose "GNOME" "KDE" "Headless")
SHELL=$(gum choose "bash" "fish")

gum confirm "You sure want to nuke /dev/sda and install Arch?" || exit 0

gum style --border normal --margin "1 0" --padding "1 2" --border-foreground 245 <<EOF

Summary:

- User      : $USERNAME
- Desktop   : $DESKTOP
- Shell     : $SHELL
- Target    : /dev/sda
EOF

gum confirm "Proceed?" || exit 0

#-------------------------!!PARTITIONING!!------------------------------
gum style --foreground 3 "Launching cfdisk..."
cfdisk /dev/sda

gum style --foreground 3 "Mounting partitions..."

EFI_PART=$(gum input --placeholder "Enter EFI partition (e.g. /dev/sda1)")
mkfs.fat -F32 "$EFI_PART"

ROOT_PART=$(gum input --placeholder "Enter root partition (e.g. /dev/sda2)")
mkfs.ext4 "$ROOT_PART"

mount "$ROOT_PART" /mnt
mkdir -p /mnt/boot
mount "$EFI_PART" /mnt/boot

gum style --foreground 10 "EFI and ROOT mounted!"

while gum confirm "Want to mount another partition?"; do
  EXTRA_PART=$(gum input --placeholder "Enter partition (e.g. /dev/sda3)")
  MOUNT_POINT=$(gum input --placeholder "Mount point (e.g. /mnt/home)")
  FORMAT=$(gum choose "ext4" "xfs" "btrfs" "Dont format")

  case "$FORMAT" in
    ext4) mkfs.ext4 "$EXTRA_PART";;
    xfs) mkfs.xfs "$EXTRA_PART";;
    btrfs) mkfs.btrfs "$EXTRA_PART";;
    "Dont format") gum style --foreground 3 "Skipping format for $EXTRA_PART";;
  esac

  mkdir -p "$MOUNT_POINT"
  mount "$EXTRA_PART" "$MOUNT_POINT"
  gum style --foreground 10 "Mounted $EXTRA_PART to $MOUNT_POINT"
done

#-------------------------!!BASE SYSTEM!!-------------------------------------------------
gum style --foreground 14 "Installing base system..."
pacstrap -K /mnt base base-devel linux linux-firmware vim sudo networkmanager git

echo "$USERNAME" > /mnt/.installer_username
echo "$DESKTOP" > /mnt/.installer_desktop
echo "$SHELL" > /mnt/.installer_shell

#-------------------------!!CHROOT HANDOFF!!----------------------------------------
cat << 'EOF' > /mnt/postinstall.sh
$(cat <<'CHROOT'
#!/bin/bash
set -e

#-------------------------!!BASIC CONFIG!!----------------------------------------
USERNAME=$(cat /.installer_username)
DESKTOP=$(cat /.installer_desktop)
SHELL=$(cat /.installer_shell)

ls /usr/share/zoneinfo/
TIMEZONE=$(gum input --placeholder "Enter your timezone (e.g. Asia/Kolkata)")
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc

sed -i 's/^#\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

#-------------------------!!HOSTNAME & USERS!!------------------------------------
gum style --foreground 8 "Adding user..."
echo "$USERNAME-pc" > /etc/hostname
cat <<EOT > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   $USERNAME-pc.localdomain $USERNAME-pc
EOT

passwd

useradd -m -G wheel -s /bin/$SHELL "$USERNAME"
passwd "$USERNAME"
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

#-------------------------!!BOOTLOADER!!------------------------------------------
systemctl enable NetworkManager

pacman -S grub efibootmgr --noconfirm
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

#------------------------------!!DESKTOP SETUP!!------------------------------------
gum style --foreground 8 "Setting up preferred desktop...."
if [[ "$DESKTOP" == "GNOME" ]]; then
  pacman -S gnome gnome-tweaks gdm --noconfirm
  systemctl enable gdm
elif [[ "$DESKTOP" == "KDE" ]]; then
  pacman -S plasma kde-applications sddm --noconfirm
  systemctl enable sddm
fi

#------------------------------!!SHELL SETUP!!------------------------------------
if [[ "$SHELL" == "fish" ]]; then
  gum style --foreground 8 "Installing Friendly Interactive SHell..."
  pacman -S fish --noconfirm
fi
rm /.installer_*
rm /postinstall.sh
CHROOT
)
EOF

chmod +x /mnt/postinstall.sh
arch-chroot /mnt /postinstall.sh

#-------------------------------!!REBOOT!!--------------------------------------------
umount -R /mnt
gum style --foreground 14 "Installation complete. Rebooting..."
reboot
