#!/bin/sh


set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { printf "${BLUE}[INFO]${NC} %s\n" "$1"; }
log_success() { printf "${GREEN}[SUCCESS]${NC} %s\n" "$1"; }
log_error() { printf "${RED}[ERROR]${NC} %s\n" "$1"; exit 1; }


if [ "$(id -u)" -ne 0 ]; then
    log_error "This script must be run as root."
fi

TARGET_USER=${SUDO_USER:-$(whoami)}
if [ "$TARGET_USER" = "root" ]; then
    log_error "Please run this script as a normal user with sudo (e.g., sudo ./install-mango.sh)."
fi


prepare_system() {
    log_info "Updating xbps repositories and system..."
    xbps-install -Syu -y || log_error "System update failed."
}


install_graphics() {
    log_info "Detecting GPU and installing drivers..."

    xbps-install -y linux-firmware mesa-dri vulkan-loader

    log_info "Attempting to install XWayland for X11 compatibility..."
    xbps-install -y xorg-server-xwayland || log_info "xorg-server-xwayland not found; skipping."

    if lspci | grep -qi "nvidia"; then
        log_info "Nvidia GPU detected."
        xbps-install -y nvidia
        # Warn about KMS for Nvidia
        log_info "Nvidia KMS not enabled by default. For optimal Wayland performance, add 'nvidia-drm.modeset=1' to your kernel parameters (e.g., in GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub).
        This script cannot automatically configure your bootloader."
    elif lspci | grep -qi "amd"; then
        log_info "AMD GPU detected."
        xbps-install -y mesa-vulkan-radeon
    elif lspci | grep -qi "intel"; then
        log_info "Intel GPU detected."
        xbps-install -y mesa-vulkan-intel
    else
        log_info "Unknown GPU. Installing generic Mesa drivers."
    fi
}

install_core() {
    log_info "Installing core system components..."


    xbps-install -y dbus elogind NetworkManager

    xbps-install -y pipewire wireplumber alsa-pipewire bluez libspa-bluetooth

    xbps-install -y xdg-desktop-portal-wlr polkit lxqt-policykit xdg-user-dirs qt6-wayland qt5-wayland
}


install_desktop() {
    log_info "Installing Session Manager and Window Manager..."
    xbps-install -y lemurs mangowc foot nerd-fonts

    log_info "Configuring Noctalia Shell repository..."
    echo "repository=https://universalrepository.pages.dev/void" > /etc/xbps.d/10-noctalia.conf
    chmod 644 /etc/xbps.d/10-noctalia.conf

    # Use XBPS_YES=1 to automatically accept third-party repository keys
    XBPS_YES=1 xbps-install -S

    log_info "Installing Noctalia Shell..."
    XBPS_YES=1 xbps-install -y noctalia || log_error "Failed to install noctalia."
}

setup_lemurs_service() {
    log_info "Setting up Lemurs as a system service..."

    mkdir -p /etc/sv/lemurs
    cat <<EOF > /etc/sv/lemurs/run
#!/bin/sh
# Start Lemurs on tty7 (via agetty) and, best-effort, switch to tty7 during boot.

if command -v fgconsole >/dev/null 2>&1 && command -v chvt >/dev/null 2>&1; then
  cur="\$(fgconsole 2>/dev/null || echo "")"
  if [ -n "\$cur" ] && [ "\$cur" != "serial" ] && [ "\$cur" != "7" ]; then
    chvt 7 2>/dev/null || true
  fi
fi

TERM=linux setterm --msg off </dev/tty7 >/dev/tty7 2>/dev/null || true
TERM=linux setterm --clear=all </dev/tty7 >/dev/tty7 2>/dev/null || true

exec agetty --noissue --skip-login --login-program /usr/bin/lemurs tty7 linux
EOF
    chmod +x /etc/sv/lemurs/run


    cat <<EOF > /etc/pam.d/lemurs
#%PAM-1.0
auth        include    login
account     include    login
session     include    login
password    include    login
EOF

    mkdir -p /etc/lemurs
    cat <<EOF > /etc/lemurs/config.toml
tty = 7
EOF
}

activate_services() {
    log_info "Activating runit services..."



    SERVICES="dbus elogind NetworkManager bluetoothd polkitd lemurs"

    for svc in $SERVICES;
 do
        if [ -d "/etc/sv/$svc" ]; then
            ln -sf "/etc/sv/$svc" "/var/service/"
            log_info "Enabled $svc"
        else
            log_error "Service $svc not found in /etc/sv/"
        fi
    done
}


configure_user() {
    log_info "Configuring user permissions for $TARGET_USER..."


    usermod -aG wheel,video,audio,bluetooth "$TARGET_USER"

    log_info "Initializing XDG user directories..."
    sudo -u "$TARGET_USER" -H xdg-user-dirs-update
}

configure_wm() {
    log_info "Configuring Mango WM native autostart for $TARGET_USER..."

    mkdir -p "/home/$TARGET_USER/.config/mango"

    cat <<EOF > "/home/$TARGET_USER/.config/mango/config.conf"
# MangoWM Configuration

# Audio & Session
exec-once pipewire
exec-once wireplumber

# Auth Agent
exec-once lxqt-policykit

# Shell
exec-once qs -c noctalia-shell
EOF


    chown -R "$TARGET_USER:$TARGET_USER" "/home/$TARGET_USER/.config"
}

main() {
    printf "${BLUE}==================================================${NC}\n"
    printf "${BLUE}   Mango WM + Noctalia Installation for Void    ${NC}\n"
    printf "${BLUE}==================================================${NC}\n"

    prepare_system
    install_graphics
    install_core
    install_desktop
    setup_lemurs_service
    configure_wm
    activate_services
    configure_user

    printf "\n${GREEN}==================================================${NC}\n"
    log_success "Installation complete!"
    printf "${BLUE}Next steps:${NC}\n"
    printf "1. Reboot your system: ${RED}sudo reboot${NC}\n"
    printf "2. The system will boot directly into the Lemurs TUI on TTY7\n"
    printf "3. Launch Mango WM and enjoy Noctalia Shell\n"
    printf "${GREEN}==================================================${NC}\n"
}

main "$@"
