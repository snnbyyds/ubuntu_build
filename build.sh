#!/bin/bash

# Ubuntu Minimal Desktop ISO Builder Script
# Based on mvallim/live-custom-ubuntu-from-scratch best practices
# Features: ubuntu-desktop-minimal, ubiquity installer, custom cleanup, UEFI-only, auto deb installation

set -e  # Exit immediately on error

# Configuration variables
UBUNTU_VERSION="plucky"  # Ubuntu 25.04 LTS, can be changed to focal, jammy, lunar, etc.
ARCH="amd64"           # Architecture, can be changed to i386, arm64, etc.
ISO_NAME="ubuntu-minimal-desktop-${UBUNTU_VERSION}-${ARCH}.iso"
WORK_DIR="/tmp/ubuntu-build"
CHROOT_DIR="${WORK_DIR}/chroot"
ISO_DIR="${WORK_DIR}/iso"
UBUNTU_MIRROR="http://mirrors.aliyun.com/ubuntu"
LIVE_USER="ubuntu"
LIVE_PASSWORD="123456"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Set non-interactive mode for all apt operations
export DEBIAN_FRONTEND=noninteractive
export DEBCONF_NONINTERACTIVE_SEEN=true
export DEBCONF_PRIORITY=critical

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
    local deps=("debootstrap" "xorriso" "squashfs-tools" "grub-efi-amd64-bin" "grub-common")
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

# Check for custom deb packages in script directory
check_custom_debs() {
    local deb_files=("$SCRIPT_DIR"/*.deb)
    if [[ -e "${deb_files[0]}" ]]; then
        log "Found custom deb packages in script directory:"
        for deb in "${deb_files[@]}"; do
            log "  - $(basename "$deb")"
        done
        return 0
    else
        log "No custom deb packages found in script directory"
        return 1
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

# Configure debconf for non-interactive mode (following mvallim approach)
configure_debconf() {
    log "Configuring debconf for non-interactive mode..."
    
    # Set debconf to non-interactive mode inside chroot
    cat > "$CHROOT_DIR/etc/apt/apt.conf.d/99noninteractive" << EOF
APT::Get::Assume-Yes "true";
APT::Get::force-yes "true";
Dpkg::Options "--force-confdef";
Dpkg::Options "--force-confold";
EOF

    # Create policy file to prevent service starts during package installation
    cat > "$CHROOT_DIR/usr/sbin/policy-rc.d" << EOF
#!/bin/sh
exit 101
EOF
    chmod +x "$CHROOT_DIR/usr/sbin/policy-rc.d"

    # Configure debconf selections before package installation
    chroot "$CHROOT_DIR" debconf-set-selections << EOF
# Locales
locales locales/locales_to_be_generated multiselect en_US.UTF-8 UTF-8
locales locales/default_environment_locale select en_US.UTF-8

# Keyboard configuration
keyboard-configuration keyboard-configuration/layout select English (US)
keyboard-configuration keyboard-configuration/layoutcode string us
keyboard-configuration keyboard-configuration/model select Generic 105-key PC (intl.)
keyboard-configuration keyboard-configuration/modelcode string pc105
keyboard-configuration keyboard-configuration/variant select English (US)
keyboard-configuration keyboard-configuration/variantcode string

# Console setup
console-setup console-setup/charmap47 select UTF-8
console-setup console-setup/codeset47 select # Latin1 and Latin5 - western Europe and Turkic languages
console-setup console-setup/codesetcode string Lat15
console-setup console-setup/fontface47 select Fixed
console-setup console-setup/fontsize-fb47 select 16
console-setup console-setup/fontsize-text47 select 16

# Timezone
tzdata tzdata/Areas select Etc
tzdata tzdata/Zones/Etc select UTC

# GRUB - don't install to MBR, we handle this manually
grub-pc grub-pc/install_devices_empty boolean true
grub-pc grub-pc/install_devices_disks_changed multiselect

# GDM3
gdm3 shared/default-x-display-manager select gdm3
gdm3 gdm3/daemon_name string /usr/sbin/gdm3

# Postfix
postfix postfix/main_mailer_type select No configuration
postfix postfix/mailname string ubuntu-minimal.local

# Ubiquity
ubiquity ubiquity/summary note
ubiquity ubiquity/reboot boolean true

# resolvconf
resolvconf resolvconf/linkify-resolvconf boolean false
EOF
}

# Configure base system
configure_system() {
    log "Configuring base system..."
    
    # Configure DNS
    echo "nameserver 8.8.8.8" > "$CHROOT_DIR/etc/resolv.conf"
    echo "nameserver 1.1.1.1" >> "$CHROOT_DIR/etc/resolv.conf"
    
    # Configure sources.list
    cat > "$CHROOT_DIR/etc/apt/sources.list" << EOF
deb $UBUNTU_MIRROR $UBUNTU_VERSION main restricted universe multiverse
deb $UBUNTU_MIRROR $UBUNTU_VERSION-updates main restricted universe multiverse
deb $UBUNTU_MIRROR $UBUNTU_VERSION-security main restricted universe multiverse
deb $UBUNTU_MIRROR $UBUNTU_VERSION-backports main restricted universe multiverse
EOF

    # Configure debconf for non-interactive mode
    configure_debconf
    
    # Update package lists
    log "Updating package lists..."
    chroot "$CHROOT_DIR" /bin/bash -c "
        export DEBIAN_FRONTEND=noninteractive
        export DEBCONF_NONINTERACTIVE_SEEN=true
        export DEBCONF_PRIORITY=critical
        apt update
    "
    
    # Install kernel and essential packages (without grub-pc to avoid conflicts)
    log "Installing kernel and essential packages..."
    chroot "$CHROOT_DIR" /bin/bash -c "
        export DEBIAN_FRONTEND=noninteractive
        export DEBCONF_NONINTERACTIVE_SEEN=true
        export DEBCONF_PRIORITY=critical
        apt install -y \
            linux-image-generic \
            linux-headers-generic \
            systemd \
            systemd-sysv \
            networkd-dispatcher \
            sudo \
            ssh \
            nano \
            curl \
            wget \
            ca-certificates \
            locales \
            tzdata \
            casper \
            discover \
            laptop-detect \
            os-prober \
            keyboard-configuration \
            console-setup \
            htop \
            tree \
            laptop-detect \
            ubuntu-standard
    "

    chroot "$CHROOT_DIR" /bin/bash -c "
        wget https://mirrors.tuna.tsinghua.edu.cn/armbian/pool/main/f/fake-ubuntu-advantage-tools/fake-ubuntu-advantage-tools_25.5.2_all__1-B34ac-R448a.deb -O /tmp/fake.deb
        apt install /tmp/fake.deb
        rm /tmp/fake.deb
    "
    
    # Install desktop environment
    log "Installing ubuntu-desktop-minimal..."
    chroot "$CHROOT_DIR" /bin/bash -c "
        export DEBIAN_FRONTEND=noninteractive
        export DEBCONF_NONINTERACTIVE_SEEN=true
        export DEBCONF_PRIORITY=critical
        apt install -y \
            ubuntu-desktop-minimal \
            gdm3 \
            gnome-shell \
            gnome-shell-extension-appindicator \
            gnome-shell-extension-desktop-icons-ng \
            gnome-shell-extension-ubuntu-dock \
            gnome-shell-extension-ubuntu-tiling-assistant \
            gnome-terminal \
            ibus-libpinyin \
            ibus-pinyin
    "
    
    # Install ubiquity installer (this will install grub-pc as dependency)
    log "Installing ubiquity installer..."
    chroot "$CHROOT_DIR" /bin/bash -c "
        export DEBIAN_FRONTEND=noninteractive
        export DEBCONF_NONINTERACTIVE_SEEN=true
        export DEBCONF_PRIORITY=critical
        apt install -y \
            ubiquity \
            ubiquity-casper \
            ubiquity-frontend-gtk \
            ubiquity-slideshow-ubuntu \
            ubiquity-ubuntu-artwork
    "
    
    # Configure locale and timezone
    log "Configuring locale and timezone..."
    chroot "$CHROOT_DIR" /bin/bash -c "
        export DEBIAN_FRONTEND=noninteractive
        locale-gen en_US.UTF-8
        update-locale LANG=en_US.UTF-8
        dpkg-reconfigure -f noninteractive locales
        dpkg-reconfigure -f noninteractive tzdata
    "
    
    echo 'LANG=en_US.UTF-8' > "$CHROOT_DIR/etc/default/locale"
    ln -sf /usr/share/zoneinfo/UTC "$CHROOT_DIR/etc/localtime"
    
    # Configure hostname
    echo "ubuntu-minimal" > "$CHROOT_DIR/etc/hostname"
    cat > "$CHROOT_DIR/etc/hosts" << EOF
127.0.0.1       localhost
127.0.1.1       ubuntu-minimal

# The following lines are desirable for IPv6 capable hosts
::1     ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF
    
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
    chmod 440 "$CHROOT_DIR/etc/sudoers.d/$LIVE_USER"
    
    # Configure GDM for autologin
    mkdir -p "$CHROOT_DIR/etc/gdm3"
    cat > "$CHROOT_DIR/etc/gdm3/custom.conf" << EOF
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=$LIVE_USER
TimedLoginEnable=true
TimedLogin=$LIVE_USER
TimedLoginDelay=0

[security]

[xdmcp]

[chooser]

[debug]
EOF

    cat >> /etc/sysctl.conf << 'EOF'
vm.swappiness=1
vm.vfs_cache_pressure=50
vm.dirty_background_ratio=1
vm.dirty_ratio=50
kernel.nmi_watchdog=0
net.ipv4.tcp_congestion_control=bbr
EOF

    chroot "$CHROOT_DIR" systemctl disable casper-md5check.service

    # Enable necessary services
    chroot "$CHROOT_DIR" systemctl enable systemd-networkd
    chroot "$CHROOT_DIR" systemctl enable systemd-resolved
    chroot "$CHROOT_DIR" systemctl enable NetworkManager
    chroot "$CHROOT_DIR" systemctl enable gdm3

    log "Configuring display manager..."
    chroot "$CHROOT_DIR" /bin/bash -c "
        export DEBIAN_FRONTEND=noninteractive
        systemctl enable gdm3 2>/dev/null || true
        systemctl set-default graphical.target 2>/dev/null || true
    "
    
    # Remove policy-rc.d to allow services to start normally after installation
    rm -f "$CHROOT_DIR/usr/sbin/policy-rc.d"
}

# Install custom deb packages from script directory
install_custom_debs() {
    if check_custom_debs; then
        log "Installing custom deb packages..."
        
        # Create temporary directory for debs
        mkdir -p "$CHROOT_DIR/tmp/custom-debs"
        
        # Copy all deb files to chroot
        cp "$SCRIPT_DIR"/*.deb "$CHROOT_DIR/tmp/custom-debs/" 2>/dev/null || true
        
        # Install each deb package
        for deb in "$CHROOT_DIR/tmp/custom-debs"/*.deb; do
            if [[ -f "$deb" ]]; then
                local deb_name=$(basename "$deb")
                log "Installing custom package: $deb_name"
                
                chroot "$CHROOT_DIR" /bin/bash -c "
                    export DEBIAN_FRONTEND=noninteractive
                    export DEBCONF_NONINTERACTIVE_SEEN=true
                    export DEBCONF_PRIORITY=critical
                    dpkg -i /tmp/custom-debs/$deb_name || true
                    apt-get install -f -y
                "
            fi
        done
        
        # Clean up temporary directory
        rm -rf "$CHROOT_DIR/tmp/custom-debs"
        
        log "Custom deb packages installation completed"
    fi
}

# Install Google Chrome
install_google_chrome() {
    log "Installing Google Chrome..."
    
    # Add Google Chrome repository
    chroot "$CHROOT_DIR" /bin/bash -c "
        export DEBIAN_FRONTEND=noninteractive
        curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor -o /usr/share/keyrings/google-chrome-keyring.gpg
    "
    
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome-keyring.gpg] http://dl.google.com/linux/chrome/deb/ stable main" > "$CHROOT_DIR/etc/apt/sources.list.d/google-chrome.list"
    
    # Update and install Chrome
    chroot "$CHROOT_DIR" /bin/bash -c "
        export DEBIAN_FRONTEND=noninteractive
        export DEBCONF_NONINTERACTIVE_SEEN=true
        export DEBCONF_PRIORITY=critical
        apt update
        apt install -y google-chrome-stable
    "
}

# Remove unwanted software (bloatware cleanup)
cleanup_bloatware() {
    log "Starting bloatware cleanup module..."
    
    # List of packages to remove
    local unwanted_packages=(
        "gnome-accessibility-themes"
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
        "ubuntu-pro-client"
        "ubuntu-advantage-tools"
    )
    
    log "Removing unwanted packages..."
    for package in "${unwanted_packages[@]}"; do
        chroot "$CHROOT_DIR" /bin/bash -c "
            export DEBIAN_FRONTEND=noninteractive
            apt purge -y $package 2>/dev/null || true
        "
    done
    
    # Remove orphaned packages
    chroot "$CHROOT_DIR" /bin/bash -c "
        export DEBIAN_FRONTEND=noninteractive
        apt autoremove -y
    "
    
    # Clean package cache
    chroot "$CHROOT_DIR" /bin/bash -c "
        export DEBIAN_FRONTEND=noninteractive
        apt autoclean
    "
    
    log "Bloatware cleanup completed"
}

# Configure live system
configure_live_system() {
    # Make sure ubiquity is installed
    log "Installing ubiquity installer..."
    chroot "$CHROOT_DIR" /bin/bash -c "
        export DEBIAN_FRONTEND=noninteractive
        export DEBCONF_NONINTERACTIVE_SEEN=true
        export DEBCONF_PRIORITY=critical
        apt install -y \
            ubiquity \
            ubiquity-casper \
            ubiquity-frontend-gtk \
            ubiquity-slideshow-ubuntu \
            ubiquity-ubuntu-artwork
    "

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
    
    # Set proper permissions for user directory
    chroot "$CHROOT_DIR" chown -R "$LIVE_USER:$LIVE_USER" "/home/$LIVE_USER"
    
    # Configure ubiquity for consistent installation
    mkdir -p "$CHROOT_DIR/etc/ubiquity"
    cat > "$CHROOT_DIR/etc/ubiquity/ubiquity.conf" << EOF
[ubiquity]
default_keyboard_layout=us
default_keyboard_variant=
migrate=true
automatic=false
EOF

    # Update initramfs with casper
    chroot "$CHROOT_DIR" update-initramfs -u
    
    log "Live system configuration completed"
}

# Create ISO directory structure (following mvallim approach)
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
        -b 1048576 \
        -processors $(nproc)
    
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
    touch "$ISO_DIR/.disk/casper-uuid-generic"
    
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

# Create GRUB configuration (following mvallim approach)
create_grub_config() {
    log "Creating GRUB configuration..."
    
    # Create grub.cfg with proper UEFI configuration
    cat > "$ISO_DIR/boot/grub/grub.cfg" << EOF
search --no-floppy --set=root -l 'Ubuntu Minimal Desktop'

insmod all_video

set default="0"
set timeout=30

menuentry "Try Ubuntu without installing" {
   linux /casper/vmlinuz boot=casper maybe-ubiquity quiet splash ---
   initrd /casper/initrd
}

menuentry "Install Ubuntu" {
   linux /casper/vmlinuz boot=casper only-ubiquity quiet splash ---
   initrd /casper/initrd
}

menuentry "OEM install (for manufacturers)" {
   linux /casper/vmlinuz boot=casper only-ubiquity quiet splash oem-config/enable=true ---
   initrd /casper/initrd
}

menuentry "Check disc for defects" {
   linux /casper/vmlinuz boot=casper integrity-check quiet splash ---
   initrd /casper/initrd
}
EOF

    # Create font for GRUB
    if [[ -f /usr/share/grub/unicode.pf2 ]]; then
        cp /usr/share/grub/unicode.pf2 "$ISO_DIR/boot/grub/font.pf2"
    fi
    
    # Create loopback.cfg for ISO booting from grub menu
    cat > "$ISO_DIR/boot/grub/loopback.cfg" << 'EOF'
menuentry "Try Ubuntu without installing" {
    linux /casper/vmlinuz boot=casper iso-scan/filename=${iso_path} maybe-ubiquity quiet splash ---
    initrd /casper/initrd
}
EOF
}

# Generate ISO file (UEFI-only approach following mvallim)
generate_iso() {
    log "Generating UEFI-only ISO file..."
    
    # Create El Torito boot catalog
    # Create grubx64.efi bootloader
    grub-mkstandalone \
        --format=x86_64-efi \
        --output="$ISO_DIR/boot/grub/grubx64.efi" \
        --locales="" \
        --fonts="" \
        "boot/grub/grub.cfg=$ISO_DIR/boot/grub/grub.cfg"
    
    # Create bootable EFI image
    dd if=/dev/zero of="$ISO_DIR/boot/grub/efiboot.img" bs=1M count=20
    mkfs.fat -F 16 "$ISO_DIR/boot/grub/efiboot.img"
    
    # Mount EFI image and setup boot structure
    mkdir -p /tmp/efi-mount
    mount -o loop "$ISO_DIR/boot/grub/efiboot.img" /tmp/efi-mount
    mkdir -p /tmp/efi-mount/EFI/BOOT
    
    # Copy grub bootloader to EFI partition
    cp "$ISO_DIR/boot/grub/grubx64.efi" /tmp/efi-mount/EFI/BOOT/bootx64.efi
    
    # Copy grub config to EFI partition
    mkdir -p /tmp/efi-mount/boot/grub
    cp "$ISO_DIR/boot/grub/grub.cfg" /tmp/efi-mount/boot/grub/
    
    umount /tmp/efi-mount
    rmdir /tmp/efi-mount
    
    # Create ISO using xorriso with proper UEFI support
    xorriso -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -volid "Ubuntu Minimal Desktop" \
        -output "$ISO_NAME" \
        -eltorito-alt-boot \
        -e boot/grub/efiboot.img \
        -no-emul-boot \
        -append_partition 2 0xef "$ISO_DIR/boot/grub/efiboot.img" \
        -m "boot/grub/efiboot.img" \
        "$ISO_DIR"
}

# Final system cleanup
final_cleanup() {
    log "Performing final system cleanup..."
    
    # Clean package cache
    chroot "$CHROOT_DIR" /bin/bash -c "
        export DEBIAN_FRONTEND=noninteractive
        apt clean
        apt autoremove -y
    "
    
    # Remove temporary files
    rm -f "$CHROOT_DIR/etc/resolv.conf"
    rm -rf "$CHROOT_DIR/tmp/*"
    rm -rf "$CHROOT_DIR/var/tmp/*"
    rm -rf "$CHROOT_DIR/var/cache/apt/archives/*.deb"
    rm -rf "$CHROOT_DIR/var/lib/apt/lists/*"
    
    # Clear bash history
    rm -f "$CHROOT_DIR/root/.bash_history"
    rm -f "$CHROOT_DIR/home/$LIVE_USER/.bash_history"
    
    # Remove machine-id (will be regenerated on first boot)
    truncate -s 0 "$CHROOT_DIR/etc/machine-id"
    
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
    log "Starting Ubuntu Minimal Desktop ISO build (UEFI-only)..."
    
    check_root
    check_dependencies
    setup_workspace
    
    # Set cleanup trap
    trap cleanup EXIT
    
    create_base_system
    mount_filesystems
    configure_system
    install_google_chrome
    install_custom_debs
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