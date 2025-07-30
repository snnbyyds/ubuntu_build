#!/bin/bash

# Ubuntu Minimal Desktop ISO Builder Script
# Based on debootstrap + xorriso with full manual construction
# Features: ubuntu-desktop-minimal, ubiquity installer, custom cleanup

set -e  # Exit immediately on error

# Configuration variables
UBUNTU_VERSION="plucky"
ARCH="amd64"           # Architecture, UEFI only
ISO_NAME="ubuntu-minimal-desktop-${UBUNTU_VERSION}-${ARCH}.iso"
WORK_DIR="/tmp/ubuntu-build"
CHROOT_DIR="${WORK_DIR}/chroot"
ISO_DIR="${WORK_DIR}/iso"
UBUNTU_MIRROR="http://mirror.nju.edu.cn/ubuntu"
LIVE_USER="ubuntu"
LIVE_PASSWORD="123456"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
    fi
}

# Check required dependencies
check_dependencies() {
    local deps=("debootstrap" "xorriso" "squashfs-tools" "grub-efi-amd64-bin")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! dpkg -l | grep -q "^ii  $dep "; then
            missing+=("$dep")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        warn "Missing dependencies: ${missing[*]}"
        log "Installing missing dependencies..."
        apt update
        DEBIAN_FRONTEND=noninteractive apt install -y "${missing[@]}"
    fi
}

# Clean up and create working directory
setup_workspace() {
    log "Setting up workspace..."
    
    if [[ -d "$WORK_DIR" ]]; then
        warn "Work directory already exists, cleaning up..."
        umount -l "$CHROOT_DIR/proc" 2>/dev/null || true
        umount -l "$CHROOT_DIR/sys" 2>/dev/null || true
        umount -l "$CHROOT_DIR/dev/pts" 2>/dev/null || true
        umount -l "$CHROOT_DIR/dev" 2>/dev/null || true
        rm -rf "$WORK_DIR"
    fi
    
    mkdir -p "$CHROOT_DIR" "$ISO_DIR"
}

# Create base system using debootstrap
create_base_system() {
    log "Creating base system with debootstrap..."
    
    debootstrap \
        --arch="$ARCH" \
        --variant=minbase \
        --components=main,restricted,universe,multiverse \
        "$UBUNTU_VERSION" \
        "$CHROOT_DIR" \
        "$UBUNTU_MIRROR"
}

# Mount necessary filesystems
mount_filesystems() {
    log "Mounting virtual filesystems..."
    
    mount -t proc proc "$CHROOT_DIR/proc"
    mount -t sysfs sysfs "$CHROOT_DIR/sys"
    mount -t devtmpfs devtmpfs "$CHROOT_DIR/dev"
    mount -t devpts devpts "$CHROOT_DIR/dev/pts"
}

# Unmount filesystems
umount_filesystems() {
    log "Unmounting virtual filesystems..."
    
    umount -l "$CHROOT_DIR/proc" 2>/dev/null || true
    umount -l "$CHROOT_DIR/sys" 2>/dev/null || true
    umount -l "$CHROOT_DIR/dev/pts" 2>/dev/null || true
    umount -l "$CHROOT_DIR/dev" 2>/dev/null || true
}

# Install local deb packages from script directory
install_local_debs() {
    log "Installing local deb packages from script directory..."
    local script_dir=$(dirname "$0")
    local deb_files=("$script_dir"/*.deb)
    
    if [[ -n "$(ls "$script_dir"/*.deb 2>/dev/null)" ]]; then
        for deb in "${deb_files[@]}"; do
            log "Installing $deb"
            cp "$deb" "$CHROOT_DIR/tmp/"
            deb_name=$(basename "$deb")
            chroot "$CHROOT_DIR" dpkg -i "/tmp/$deb_name"
            rm "$CHROOT_DIR/tmp/$deb_name"
        done
        DEBIAN_FRONTEND=noninteractive chroot "$CHROOT_DIR" apt-get install -f -y
    else
        log "No local deb packages found in $script_dir"
    fi
}

# Configure base system
configure_system() {
    log "Configuring base system..."
    
    # Configure DNS
    echo "nameserver 8.8.8.8" > "$CHROOT_DIR/etc/resolv.conf"
    
    # Configure sources.list
    cat > "$CHROOT_DIR/etc/apt/sources.list" << EOF
deb $UBUNTU_MIRROR $UBUNTU_VERSION main restricted universe multiverse
deb $UBUNTU_MIRROR $UBUNTU_VERSION-updates main restricted universe multiverse
deb $UBUNTU_MIRROR $UBUNTU_VERSION-security main restricted universe multiverse
deb $UBUNTU_MIRROR $UBUNTU_VERSION-backports main restricted universe multiverse
EOF

    # Update package lists
    DEBIAN_FRONTEND=noninteractive chroot "$CHROOT_DIR" apt update
    
    # Install kernel and essential packages
    log "Installing kernel and essential packages..."
    DEBIAN_FRONTEND=noninteractive chroot "$CHROOT_DIR" apt install -y \
        linux-image-generic \
        linux-headers-generic \
        grub-efi-amd64 \
        systemd \
        networkd-dispatcher \
        systemd-resolved \
        sudo \
        openssh-server \
        nano \
        curl \
        wget \
        ca-certificates \
        locales \
        tzdata \
        casper \
        discover \
        laptop-detect \
        os-prober
    
    # Install desktop environment
    log "Installing ubuntu-desktop-minimal..."
    DEBIAN_FRONTEND=noninteractive chroot "$CHROOT_DIR" apt install -y ubuntu-desktop-minimal
    
    # Install ubiquity installer
    log "Installing ubiquity installer..."
    DEBIAN_FRONTEND=noninteractive chroot "$CHROOT_DIR" apt install -y \
        ubiquity \
        ubiquity-casper \
        ubiquity-frontend-gtk \
        ubiquity-slideshow-ubuntu \
        ubiquity-ubuntu-artwork
    
    # Configure locale and timezone
    chroot "$CHROOT_DIR" locale-gen en_US.UTF-8
    echo 'LANG=en_US.UTF-8' > "$CHROOT_DIR/etc/default/locale"
    ln -sf /usr/share/zoneinfo/UTC "$CHROOT_DIR/etc/localtime"
    
    # Configure hostname
    echo "ubuntu-minimal" > "$CHROOT_DIR/etc/hostname"
    
    # Configure network with netplan
    mkdir -p "$CHROOT_DIR/etc/netplan"
    cat > "$CHROOT_DIR/etc/netplan/01-netcfg.yaml" << EOF
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: true
  renderer: NetworkManager
EOF

    # Create live user
    log "Creating live user: $LIVE_USER"
    chroot "$CHROOT_DIR" useradd -m -s /bin/bash -G sudo,adm,dialout,cdrom,floppy,audio,dip,video,plugdev,netdev "$LIVE_USER"
    echo "$LIVE_USER:$LIVE_PASSWORD" | chroot "$CHROOT_DIR" chpasswd
    echo "root:$LIVE_PASSWORD" | chroot "$CHROOT_DIR" chpasswd
    
    # Configure sudo without password for live user
    echo "$LIVE_USER ALL=(ALL) NOPASSWD:ALL" > "$CHROOT_DIR/etc/sudoers.d/$LIVE_USER"
    
    # Enable autologin for live session
    mkdir -p "$CHROOT_DIR/etc/systemd/system/getty@tty1.service.d"
    cat > "$CHROOT_DIR/etc/systemd/system/getty@tty1.service.d/autologin.conf" << EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $LIVE_USER --noclear %I \$TERM
EOF

    # Configure GDM for autologin
    cat > "$CHROOT_DIR/etc/gdm3/custom.conf" << EOF
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=$LIVE_USER

[security]

[xdmcp]

[chooser]

[debug]
EOF
}

# Install Google Chrome
install_google_chrome() {
    log "Installing Google Chrome..."
    
    # Add Google Chrome repository
    chroot "$CHROOT_DIR" sh -c 'curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor -o /usr/share/keyrings/google-chrome-keyring.gpg'
    
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome-keyring.gpg] http://dl.google.com/linux/chrome/deb/ stable main" > "$CHROOT_DIR/etc/apt/sources.list.d/google-chrome.list"
    
    # Update and install Chrome
    DEBIAN_FRONTEND=noninteractive chroot "$CHROOT_DIR" apt update
    DEBIAN_FRONTEND=noninteractive chroot "$CHROOT_DIR" apt install -y google-chrome-stable
}

# Remove unwanted software (bloatware cleanup)
cleanup_bloatware() {
    log "Starting bloatware cleanup module..."
    
    # List of packages to remove
    local unwanted_packages=(
        "libreoffice*"
        "thunderbird*"
        "rhythmbox*"
        "totem*"
        "cheese*"
        "remmina*"
        "transmission-gtk"
        "shotwell*"
        "simple-scan"
        "gnome-mahjongg"
        "gnome-mines"
        "gnome-sudoku"
        "aisleriot"
        "gnome-todo"
        "evolution*"
        "gnome-contacts"
        "gnome-maps"
        "gnome-weather"
        "ubuntu-web-launchers"
        "ubuntu-advantage-tools"
        "ubuntu-pro-client"
        "snapd"
        "gnome-bluetooth-sendto"
        "gnome-initial-setup"
        "gnome-font-viewer"
        "gnome-clocks"
        "gnome-logs"
        "gnome-remote-desktop"
        "gnome-system-monitor"
        "gnome-text-editor"
        "printer-driver-*"
        "papers"
        "orca"
        "packagekit"
        "avahi-daemon"
        "whoopsie"
        "firefox"
        "cloud-init"
    )
    
    log "Removing unwanted packages..."
    for package in "${unwanted_packages[@]}"; do
        DEBIAN_FRONTEND=noninteractive chroot "$CHROOT_DIR" apt purge -y "$package" 2>/dev/null || true
    done
    
    # Remove orphaned packages
    DEBIAN_FRONTEND=noninteractive chroot "$CHROOT_DIR" apt autoremove -y
    
    # Clean package cache
    chroot "$CHROOT_DIR" apt autoclean
    
    log "Bloatware cleanup completed"
}

# Configure live system for consistency with installed system
configure_live_system() {
    log "Configuring live system for consistency..."
    
    # Create casper configuration
    mkdir -p "$CHROOT_DIR/etc/casper"
    cat > "$CHROOT_DIR/etc/casper/casper.conf" << EOF
export USERNAME="$LIVE_USER"
export USERFULLNAME="Ubuntu Live User"
export HOST="ubuntu-minimal"
export BUILD_SYSTEM="Ubuntu"
export FLAVOUR="Ubuntu"
EOF

    # Create desktop entry for installer
    mkdir -p "$CHROOT_DIR/home/$LIVE_USER/Desktop"
    cat > "$CHROOT_DIR/home/$LIVE_USER/Desktop/ubiquity.desktop" << EOF
[Desktop Entry]
Name=Install Ubuntu
Comment=Install Ubuntu to your computer
Exec=ubiquity gtk_ui
Icon=ubiquity
Terminal=false
Type=Application
Categories=System;Settings;
StartupNotify=true
EOF

    chmod +x "$CHROOT_DIR/home/$LIVE_USER/Desktop/ubiquity.desktop"
    chroot "$CHROOT_DIR" chown -R "$LIVE_USER:$LIVE_USER" "/home/$LIVE_USER"
    
    # Configure ubiquity for consistent installation
    mkdir -p "$CHROOT_DIR/etc/ubiquity"
    cat > "$CHROOT_DIR/etc/ubiquity/ubiquity.conf" << EOF
[ubiquity]
default_keyboard_layout=us
default_keyboard_variant=
migrate=true
EOF

    # Create script to ensure consistency between live and installed system
    cat > "$CHROOT_DIR/usr/local/bin/post-install-cleanup.sh" << 'EOF'
#!/bin/bash
# Post-installation cleanup to match live system

# Remove the same bloatware packages
UNWANTED_PACKAGES=(
    "libreoffice*"
    "thunderbird*"
    "rhythmbox*"
    "totem*"
    "cheese*"
    "remmina*"
    "transmission-gtk"
    "shotwell*"
    "simple-scan"
    "gnome-mahjongg"
    "gnome-mines"
    "gnome-sudoku"
    "aisleriot"
    "gnome-todo"
    "evolution*"
    "gnome-contacts"
    "gnome-maps"
    "gnome-weather"
    "ubuntu-web-launchers"
    "ubuntu-advantage-tools"
    "ubuntu-pro-client"
    "snapd"
    "gnome-bluetooth-sendto"
    "gnome-initial-setup"
    "gnome-font-viewer"
    "gnome-clocks"
    "gnome-logs"
    "gnome-remote-desktop"
    "gnome-system-monitor"
    "gnome-text-editor"
    "printer-driver-*"
    "papers"
    "orca"
    "packagekit"
    "avahi-daemon"
    "whoopsie"
    "firefox"
    "cloud-init"
)

for package in "${UNWANTED_PACKAGES[@]}"; do
    apt purge -y "$package" 2>/dev/null || true
done

apt autoremove -y
apt autoclean

# Ensure Google Chrome is installed
if ! command -v google-chrome &> /dev/null; then
    curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor -o /usr/share/keyrings/google-chrome-keyring.gpg
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome-keyring.gpg] http://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list
    apt update
    apt install -y google-chrome-stable
fi
EOF

    chmod +x "$CHROOT_DIR/usr/local/bin/post-install-cleanup.sh"
    
    # Configure ubiquity to run post-install script
    cat > "$CHROOT_DIR/usr/share/ubiquity/plugininstall.py" << 'EOF'
#!/usr/bin/python3

import subprocess
import sys
import os

def run_post_install_cleanup():
    """Run post-installation cleanup script"""
    try
        subprocess.run(['/usr/local/bin/post-install-cleanup.sh'], check=True)
        print("Post-installation cleanup completed successfully")
    except subprocess.CalledProcessError as e:
        print(f"Post-installation cleanup failed: {e}")

if __name__ == "__main__":
    run_post_install_cleanup()
EOF

    chmod +x "$CHROOT_DIR/usr/share/ubiquity/plugininstall.py"
    
    # Update initramfs with casper
    chroot "$CHROOT_DIR" update-initramfs -u
    
    log "Live system configuration completed"
}

# Create ISO directory structure
create_iso_structure() {
    log "Creating ISO directory structure..."
    
    mkdir -p "$ISO_DIR"/{boot/grub,casper,.disk,dists}
    
    # Copy kernel and initrd
    cp "$CHROOT_DIR"/boot/vmlinuz-* "$ISO_DIR/casper/vmlinuz"
    cp "$CHROOT_DIR"/boot/initrd.img-* "$ISO_DIR/casper/initrd"
    
    # Create filesystem.squashfs
    log "Creating squashfs filesystem (this may take a while)..."
    mksquashfs "$CHROOT_DIR" "$ISO_DIR/casper/filesystem.squashfs" \
        -e boot \
        -comp xz \
        -Xbcj x86 \
        -b 1048576
    
    # Create filesystem.size
    echo -n $(du -sx --block-size=1 "$CHROOT_DIR" | cut -f1) > "$ISO_DIR/casper/filesystem.size"
    
    # Create manifest
    chroot "$CHROOT_DIR" dpkg-query -W --showformat='${Package} ${Version}\n' > "$ISO_DIR/casper/filesystem.manifest"
    cp "$ISO_DIR/casper/filesystem.manifest" "$ISO_DIR/casper/filesystem.manifest-desktop"
    
    # Create disk information
    cat > "$ISO_DIR/.disk/info" << EOF
Ubuntu Minimal Desktop $UBUNTU_VERSION $ARCH
EOF

    echo "$UBUNTU_VERSION" > "$ISO_DIR/.disk/release"
    echo "Ubuntu Minimal Desktop" > "$ISO_DIR/.disk/casper-uuid-generic"
    echo "Ubuntu" > "$ISO_DIR/.disk/base_installable"
    
    # Create README for the ISO
    cat > "$ISO_DIR/README.diskdefines" << EOF
#define DISKNAME  Ubuntu Minimal Desktop $UBUNTU_VERSION
#define TYPE  binary
#define TYPEbinary  1
#define ARCH  $ARCH
#define ARCHamd64  1
#define DISKNUM  1
#define DISKNUM1  1
#define TOTALNUM  0
#define TOTALNUM0  1
EOF
}

# Create GRUB configuration (UEFI only)
create_grub_config() {
    log "Creating GRUB configuration for UEFI..."
    
    cat > "$ISO_DIR/boot/grub/grub.cfg" << 'EOF'
set default="0"
set timeout=10

insmod efi_gop
insmod efi_uga
insmod video_bochs
insmod video_cirrus
insmod gzio
insmod part_gpt
insmod fat
insmod iso9660

set gfxpayload=keep
insmod gfxterm
set gfxmode=auto

terminal_output gfxterm

menuentry "Try Ubuntu Minimal Desktop without installing" {
    linux /casper/vmlinuz boot=casper quiet splash ---
    initrd /casper/initrd
}

menuentry "Install Ubuntu Minimal Desktop" {
    linux /casper/vmlinuz boot=casper only-ubiquity quiet splash ---
    initrd /casper/initrd
}

menuentry "Try Ubuntu Minimal Desktop (safe graphics)" {
    linux /casper/vmlinuz boot=casper quiet splash nomodeset ---
    initrd /casper/initrd
}

menuentry "Check disc for defects" {
    linux /casper/vmlinuz boot=casper integrity-check quiet splash ---
    initrd /casper/initrd
}
EOF

    # Create loopback.cfg for ISO booting
    cat > "$ISO_DIR/boot/grub/loopback.cfg" << 'EOF'
menuentry "Try Ubuntu Minimal Desktop without installing" {
    linux /casper/vmlinuz boot=casper iso-scan/filename=${iso_path} quiet splash ---
    initrd /casper/initrd
}
EOF
}

# Generate ISO file (UEFI only)
generate_iso() {
    log "Generating ISO file for UEFI..."
    
    # Create EFI boot image
    dd if=/dev/zero of="$ISO_DIR/boot/grub/efiboot.img" bs=1M count=20
    mkfs.fat -F 16 "$ISO_DIR/boot/grub/efiboot.img"
    
    # Mount EFI image and copy GRUB
    mkdir -p /tmp/efi-mount
    mount -o loop "$ISO_DIR/boot/grub/efiboot.img" /tmp/efi-mount
    mkdir -p /tmp/efi-mount/EFI/BOOT
    
    # Check for GRUB EFI bootloader files
    if [[ "$ARCH" == "amd64" ]]; then
        if [[ -f /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed ]]; then
            log "Using signed GRUB EFI bootloader"
            cp /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed /tmp/efi-mount/EFI/BOOT/bootx64.efi
        elif [[ -f /usr/lib/grub/x86_64-efi/grubx64.efi ]]; then
            log "Using standard GRUB EFI bootloader"
            cp /usr/lib/grub/x86_64-efi/grubx64.efi /tmp/efi-mount/EFI/BOOT/bootx64.efi
        else
            error "No GRUB EFI bootloader found. Please ensure grub-efi-amd64-bin or grub-efi-amd64-signed is installed."
        fi
    fi
    
    cp "$ISO_DIR/boot/grub/grub.cfg" /tmp/efi-mount/EFI/BOOT/grub.cfg
    
    umount /tmp/efi-mount
    rmdir /tmp/efi-mount
    echo 114514
    
    # Create ISO using xorriso (UEFI only)
    xorriso -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -volid "Ubuntu-Minimal-Desktop" \
        -eltorito-alt-boot \
        -e boot/grub/efiboot.img \
        -no-emul-boot \
        -append_partition 2 0xef "$ISO_DIR/boot/grub/efiboot.img" \
        -output "$ISO_NAME" \
        -graft-points \
            "$ISO_DIR"
}

# Final system cleanup
final_cleanup() {
    log "Performing final system cleanup..."
    
    # Clean package cache
    chroot "$CHROOT_DIR" apt clean
    DEBIAN_FRONTEND=noninteractive chroot "$CHROOT_DIR" apt autoremove -y
    
    # Remove temporary files
    rm -f "$CHROOT_DIR/etc/resolv.conf"
    rm -rf "$CHROOT_DIR/tmp/*"
    rm -rf "$CHROOT_DIR/var/tmp/*"
    rm -rf "$CHROOT_DIR/var/cache/apt/archives/*.deb"
    rm -rf "$CHROOT_DIR/var/lib/apt/lists/*"
    
    # Clear bash history
    rm -f "$CHROOT_DIR/root/.bash_history"
    rm -f "$CHROOT_DIR/home/$LIVE_USER/.bash_history"
    
    log "Final cleanup completed"
}

# Cleanup function
cleanup() {
    log "Cleaning up temporary files..."
    umount_filesystems
    rm -rf "$WORK_DIR"
}

# Main function
main() {
    log "Starting Ubuntu Minimal Desktop ISO build..."
    
    check_root
    check_dependencies
    setup_workspace
    
    # Set cleanup trap
    trap cleanup EXIT
    
    create_base_system
    mount_filesystems
    configure_system
    install_local_debs
    install_google_chrome
    cleanup_bloatware
    configure_live_system
    final_cleanup
    umount_filesystems
    
    create_iso_structure
    create_grub_config
    generate_iso
    
    log "ISO build completed: $ISO_NAME"
    log "ISO size: $(du -h "$ISO_NAME" | cut -f1)"
    
    # Output usage information
    cat << EOF

${GREEN}Build completed successfully!${NC}

ISO file location: $ISO_NAME

Usage:
1. Write to USB: dd if=$ISO_NAME of=/dev/sdX bs=1M status=progress
2. Test in VM: qemu-system-x86_64 -cdrom $ISO_NAME -m 4G -enable-kvm
3. Live user: $LIVE_USER/$LIVE_PASSWORD (with sudo privileges)
4. Root password: $LIVE_PASSWORD

Features:
- Minimal desktop system with ubuntu-desktop-minimal
- Ubiquity installer for consistent installation experience
- Pre-installed Google Chrome
- Local .deb packages installed from script directory
- Cleaned of bloatware (LibreOffice, games, etc.)
- UEFI boot only (no Legacy BIOS support)
- SSH server included
- Automatic network configuration (DHCP)
- Based on Ubuntu $UBUNTU_VERSION ($ARCH)

Installation:
- Boot the ISO and select "Install Ubuntu Minimal Desktop"
- The installed system will match the live environment
- Post-installation cleanup ensures consistency

EOF
}

# Execute main function
main "$@"