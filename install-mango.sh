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

    xbps-install -y dbus seatd NetworkManager

    xbps-install -y pipewire wireplumber alsa-pipewire bluez libspa-bluetooth

    xbps-install -y xdg-desktop-portal-wlr polkit lxqt-policykit xdg-user-dirs qt6-wayland qt5-wayland
}


install_desktop() {
    log_info "Installing Session Manager and Window Manager..."
    xbps-install -y lemurs mangowc foot nerd-fonts deffont

    log_info "Configuring Noctalia Shell repository..."
    echo "repository=https://universalrepository.pages.dev/void" > /etc/xbps.d/10-noctalia.conf
    chmod 644 /etc/xbps.d/10-noctalia.conf

    # Use XBPS_YES=1 to automatically accept third-party repository keys
    XBPS_YES=1 xbps-install -S

    log_info "Installing Noctalia Shell..."
    XBPS_YES=1 xbps-install -y noctalia || log_error "Failed to install noctalia."
}

activate_services() {
    log_info "Activating runit services..."


    SERVICES="dbus seatd NetworkManager bluetoothd polkitd lemurs"

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

    usermod -aG wheel,video,audio,bluetooth,_seatd "$TARGET_USER"

    log_info "Setting up Lemurs system entry with D-Bus and Wayland environment..."
    mkdir -p /etc/lemurs/wayland

    cat <<EOF > /etc/lemurs/wayland/mangowc
#!/bin/sh
# XDG Environment
export XDG_CURRENT_DESKTOP=mango
export XDG_SESSION_TYPE=wayland
export XDG_SESSION_DESKTOP=mango

# Toolkit Wayland Backends
export QT_QPA_PLATFORM=wayland
export SDL_VIDEODRIVER=wayland
export ELM_DISPLAY=wl

# Start the session with a D-Bus user bus
exec dbus-run-session mangowc
EOF

    chmod +x /etc/lemurs/wayland/mangowc
    chown root:root /etc/lemurs/wayland/mangowc

    log_info "Initializing XDG user directories..."
    sudo -u "$TARGET_USER" xdg-user-dirs-update
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
exec-once noctalia
EOF

    chown -R "$TARGET_USER:$TARGET_USER" "/home/$TARGET_USER/.config/mango"
}

main() {
    printf "${BLUE}==================================================${NC}\n"
    printf "${BLUE}   Mango WM + Noctalia Installation for Void    ${NC}\n"
    printf "${BLUE}==================================================${NC}\n"

    prepare_system
    install_graphics
    install_core
    install_desktop
    configure_wm
    activate_services
    configure_user

    printf "\n${GREEN}==================================================${NC}\n"
    log_success "Installation complete!"
    printf "${BLUE}Next steps:${NC}\n"
    printf "1. Reboot your system: ${RED}sudo reboot${NC}\n"
    printf "2. Login via Lemurs TUI: \n"
    printf "3. Launch Mango WM and enjoy Noctalia Shell\n"
    printf "${GREEN}==================================================${NC}\n"
}

main "$@"
