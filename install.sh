#!/bin/bash
set -e

# ------------------------!!GUM SETUP!!----------------------------------
pacman-key --init
pacman-key --populate archlinux
pacman -Sy archlinux-keyring
if ! command -v gum &>/dev/null; then
  pacman -Sy --noconfirm gum || {
    exit 1
  }
fi

gum style --foreground 39 --align center --padding "1 2" --border double --border-foreground 33 <<'EOF'
 

 █████╗ ██████╗  ██████╗██╗  ██╗██╗     ███████╗████████╗
██╔══██╗██╔══██╗██╔════╝██║  ██║██║     ██╔════╝╚══██╔══╝
███████║██████╔╝██║     ███████║██║     █████╗     ██║   
██╔══██║██╔══██╗██║     ██╔══██║██║     ██╔══╝     ██║   
██║  ██║██║  ██║╚██████╗██║  ██║███████╗███████╗   ██║   
╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝╚══════╝╚══════╝   ╚═╝   
                                                         
           ARCHLET — The minimal Arch Installer

Built by Sathiya 😌
EOF
# ------------------------!!ROOT & NETWORK CHECK!!-----------------------
if [[ $EUID -ne 0 ]]; then
  gum style --foreground 1 --bold "Requires root access"
  exit 1
fi

ping -c 5 archlinux.org > /dev/null
if [[ $? -ne 0 ]]; then
  gum style --foreground 1 --bold "No active internet connection"
  exit 1
fi

timedatectl set-ntp true
gum style --foreground 10 --bold "Enabled Time Sync"

#-------------------------!!USER CHOICE!!--------------------------------
USERNAME=$(gum input --header "Username" --prompt "> ")
if [[ -z "$USERNAME" ]]; then
  gum style --foreground 1 --bold "Username cannot be empty"
  exit 1
fi

DESKTOP=$(gum choose --header "Choose a desktop environment:" "GNOME" "KDE" "Headless")
SHELL=$(gum choose --header "Choose your preferred shell:" "bash" "fish")

gum confirm "You sure want to nuke /dev/sda and install Arch?" || exit 0

gum style --border double --padding "1 2" --margin "1 1" --border-foreground 245 <<EOF

Installation Summary

- User      : $USERNAME
- Desktop   : $DESKTOP
- Shell     : $SHELL
- Target    : /dev/sda

EOF

gum confirm "Proceed?" || exit 0

#-------------------------!!PARTITIONING!!------------------------------
gum style --border rounded --padding "1 2" --foreground 3 "Launching cfdisk..."
cfdisk /dev/sda

gum style --foreground 3 "Mounting partitions..."

EFI_PART=$(gum input --header "Enter EFI partition (e.g. /dev/sda1)" --prompt "> ")
mkfs.fat -F32 "$EFI_PART"

ROOT_PART=$(gum input --header "Enter root partition (e.g. /dev/sda2)" --prompt "> ")
mkfs.ext4 "$ROOT_PART"

mount "$ROOT_PART" /mnt
mkdir -p /mnt/boot
mount "$EFI_PART" /mnt/boot

gum style --foreground 10 "EFI and ROOT mounted!"

while gum confirm "Want to mount another partition?"; do
  EXTRA_PART=$(gum input --header "Enter partition (e.g. /dev/sda3)" --prompt "> ")
  MOUNT_POINT=$(gum input --header "Mount point (e.g. /mnt/home)" --prompt "> ")
  FORMAT=$(gum choose --header "Choose format type:" "ext4" "xfs" "btrfs" "Dont format")

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
gum style --foreground 14 --border double --padding "1 2" "Installing base system..."
pacstrap -K /mnt base base-devel linux linux-firmware vim sudo networkmanager git

gum style --foreground 14 "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

echo "$USERNAME" > /mnt/.installer_username
echo "$DESKTOP" > /mnt/.installer_desktop
echo "$SHELL" > /mnt/.installer_shell

#-------------------------!!CHROOT HANDOFF!!----------------------------------------
cat << 'EOF' > /mnt/postinstall.sh
#!/bin/bash
set -e

echo "Installing gum inside chroot..."
pacman -Sy --noconfirm gum

#-------------------------!!BASIC CONFIG!!----------------------------------------
USERNAME=$(cat /.installer_username)
DESKTOP=$(cat /.installer_desktop)
SHELL=$(cat /.installer_shell)

ls /usr/share/zoneinfo/
TIMEZONE=$(gum input --header "Enter your timezone (e.g. Asia/Kolkata)" --prompt "> ")
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
gum style --foreground 8 "Set Root Password"
passwd
#------------------------------!!SHELL SETUP!!------------------------------------
if [[ "$SHELL" == "fish" ]]; then
  gum style --foreground 8 "Installing Friendly Interactive SHell..."
  pacman -S fish --noconfirm

  SHELL_PATH="/usr/bin/fish"
  if ! grep -q "$SHELL_PATH" /etc/shells; then
    echo "$SHELL_PATH" >> /etc/shells
  fi
else
  SHELL_PATH="/bin/bash"
fi

useradd -m -G wheel -s "$SHELL_PATH" "$USERNAME"
passwd "$USERNAME"
chsh -s "$SHELL_PATH" "$USERNAME"
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

gum style --foreground 10 "Cleaning up..."

pacman -Rns --noconfirm gum
rm /.installer_*
rm /postinstall.sh
EOF

chmod +x /mnt/postinstall.sh
arch-chroot /mnt /postinstall.sh

#-------------------------------!!REBOOT!!--------------------------------------------
umount -R /mnt
gum style --foreground 14 --border double --padding "1 2" "Installation complete. Rebooting..."
reboot
