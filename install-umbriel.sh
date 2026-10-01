#!/usr/bin/env bash
# ==============================================================================
# Ethos Echo - Independent Umbriel, Noctalia & Noctalia Greeter Installer
# Architecture: Arch Linux (Wayland, Gruvbox Dark, Alacritty)
# ==============================================================================

set -eo pipefail

# Colors & Formatting
RC='\033[0m'
RED='\033[31m'
YELLOW='\033[33m'
CYAN='\033[36m'
GREEN='\033[32m'
BOLD='\033[1m'

# Logging Utilities
log_info()    { printf "%b[INFO] %s%b\n" "${CYAN}" "$1" "${RC}"; }
log_success() { printf "%b[SUCCESS] %s%b\n" "${GREEN}" "$1" "${RC}"; }
log_warn()    { printf "%b[WARN] %s%b\n" "${YELLOW}" "$1" "${RC}"; }
log_error()   { printf "%b[ERROR] %s%b\n" "${RED}" "$1" "${RC}"; }

command_exists() {
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || return 1
    done
    return 0
}

# ------------------------------------------------------------------------------
# Preflight & Environment Checks
# ------------------------------------------------------------------------------
check_arch_distro() {
    if [ ! -f /etc/arch-release ]; then
        log_error "This script is tailored specifically for Arch Linux. /etc/arch-release was not found."
        exit 1
    fi
    log_success "Arch Linux detected."
}

check_cpu_arch() {
    case "$(uname -m)" in
        x86_64 | amd64) ARCH="x86_64" ;;
        aarch64 | arm64) ARCH="aarch64" ;;
        *) log_error "Unsupported architecture: $(uname -m)" && exit 1 ;;
    esac
    log_info "System architecture: ${ARCH}"
}

check_user_and_sudo() {
    if [ "$(id -u)" -eq 0 ]; then
        log_error "Do not run this script as root or with sudo directly!"
        log_info "makepkg and AUR helpers strictly prohibit running as root."
        log_info "Please run as your regular user: ./${0##*/}"
        log_info "The script will invoke sudo only for system-level operations."
        exit 1
    fi

    if ! command_exists sudo; then
        log_error "sudo is required for system configuration but not found."
        log_info "Please install and configure sudo, then add your user to the wheel group."
        exit 1
    fi

    log_info "Validating sudo access for $USER..."
    if ! sudo -v; then
        log_error "Failed to authenticate with sudo."
        exit 1
    fi

    # Keep sudo timestamp alive in background while the script runs
    (while true; do
        sudo -n true 2>/dev/null
        sleep 50
        kill -0 "$$" 2>/dev/null || exit 0
    done) 2>/dev/null &
    SUDO_KEEPALIVE_PID=$!
    trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT INT TERM

    log_success "Sudo privileges validated (keepalive active)."
}

check_writable_dir() {
    SCRIPT_DIR="$(cd "$(dirname "$(realpath "$0")")" && pwd)"
    if [ ! -w "$SCRIPT_DIR" ]; then
        log_error "Cannot write to directory: $SCRIPT_DIR"
        exit 1
    fi
}

check_env() {
    check_arch_distro
    check_cpu_arch
    check_user_and_sudo
    check_writable_dir
}

# ------------------------------------------------------------------------------
# Clean-Slate System Purge
# ------------------------------------------------------------------------------
clean_existing_system() {
    log_info "Performing clean-slate purge of existing desktop configurations..."

    # User configs
    rm -rf "${HOME}/.config/umbriel"
    rm -rf "${HOME}/.config/noctalia"
    rm -rf "${HOME}/.config/alacritty"

    # Greetd & Greeter system configs
    sudo rm -rf /var/lib/noctalia-greeter 2>/dev/null || true
    sudo rm -f /etc/greetd/config.toml 2>/dev/null || true

    # Disable conflicting display managers
    for dm in lemurs sddm gdm lightdm lxdm; do
        if systemctl is-enabled "$dm" >/dev/null 2>&1; then
            log_warn "Disabling conflicting display manager: $dm"
            sudo systemctl disable --now "$dm" 2>/dev/null || true
        fi
    done

    log_success "Clean-slate system purge complete."
}

# ------------------------------------------------------------------------------
# System Preparation & AUR Bootstrapping
# ------------------------------------------------------------------------------
prepare_system() {
    log_info "Synchronizing package databases and updating system..."
    sudo pacman -Syu --noconfirm

    log_info "Installing core build tools and dependencies..."
    sudo pacman -S --needed --noconfirm \
        base-devel git curl wget pciutils jq
}

bootstrap_aur_helper() {
    if command_exists yay; then
        AUR_HELPER="yay"
        log_info "Found existing AUR helper: yay"
        return 0
    elif command_exists paru; then
        AUR_HELPER="paru"
        log_info "Found existing AUR helper: paru"
        return 0
    fi

    log_info "No AUR helper found. Bootstrapping yay-bin from AUR..."
    local BUILD_DIR
    BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/yay-bin.XXXXXX")"

    log_info "Cloning yay-bin into $BUILD_DIR..."
    git clone https://aur.archlinux.org/yay-bin.git "$BUILD_DIR"

    log_info "Building and installing yay-bin..."
    (
        cd "$BUILD_DIR"
        makepkg -si --noconfirm
    )

    rm -rf "$BUILD_DIR"

    if command_exists yay; then
        AUR_HELPER="yay"
        log_success "Successfully installed yay!"
    else
        log_error "Failed to install yay. Please install an AUR helper manually."
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# Graphics & Hardware Acceleration
# ------------------------------------------------------------------------------
install_graphics() {
    log_info "Detecting GPU and installing display drivers..."
    sudo pacman -S --needed --noconfirm \
        linux-firmware mesa vulkan-icd-loader xorg-xwayland

    if lspci | grep -qi "nvidia"; then
        log_info "NVIDIA GPU detected. Installing nvidia driver stack..."
        local NVIDIA_PKG="nvidia-open"
        if pacman -Q linux-lts >/dev/null 2>&1; then
            NVIDIA_PKG="nvidia-open-lts"
        fi
        sudo pacman -S --needed --noconfirm "$NVIDIA_PKG" nvidia-utils libva-nvidia-driver
        log_warn "NVIDIA Note: Make sure 'nvidia-drm.modeset=1' and 'nvidia-drm.fbdev=1' are added to kernel parameters."
    elif lspci | grep -qi "amd"; then
        log_info "AMD GPU detected. Installing AMD Vulkan and VA-API drivers..."
        sudo pacman -S --needed --noconfirm vulkan-radeon libva-mesa-driver
    elif lspci | grep -qi "intel"; then
        log_info "Intel GPU detected. Installing Intel Vulkan and Media drivers..."
        sudo pacman -S --needed --noconfirm vulkan-intel intel-media-driver
    else
        log_info "Generic/Virtual display adapter detected. Mesa defaults applied."
    fi
}

# ------------------------------------------------------------------------------
# Core Desktop Plumbing & Utilities
# ------------------------------------------------------------------------------
install_core_services() {
    log_info "Installing core system, audio, networking, and font packages..."
    sudo pacman -S --needed --noconfirm \
        dbus networkmanager \
        pipewire wireplumber pipewire-pulse pipewire-alsa pipewire-jack \
        bluez bluez-utils \
        polkit lxqt-policykit \
        xdg-desktop-portal xdg-user-dirs \
        brightnessctl \
        alacritty \
        ttf-meslo-nerd ttf-jetbrains-mono-nerd ttf-nerd-fonts-symbols \
        noto-fonts noto-fonts-emoji noto-fonts-cjk
}

# ------------------------------------------------------------------------------
# Umbriel, Noctalia & Noctalia Greeter (AUR)
# ------------------------------------------------------------------------------
install_aur_desktop_packages() {
    log_info "Installing Umbriel compositor, Noctalia shell, and Noctalia Greeter via $AUR_HELPER..."

    # Ensure greetd is installed from official repositories
    sudo pacman -S --needed --noconfirm greetd

    # Install Noctalia Greeter
    log_info "Installing noctalia-greeter..."
    $AUR_HELPER -S --needed --noconfirm noctalia-greeter || $AUR_HELPER -S --needed --noconfirm noctalia-greeter-git

    # Install Noctalia Desktop Shell
    log_info "Installing noctalia desktop shell..."
    $AUR_HELPER -S --needed --noconfirm noctalia-git

    # Install Umbriel & Portal
    log_info "Installing umbriel-git & xdg-desktop-portal-umbriel-git..."
    $AUR_HELPER -S --needed --noconfirm xdg-desktop-portal-umbriel-git umbriel-git

    log_success "AUR desktop packages installed successfully."
}

# ------------------------------------------------------------------------------
# Greetd & Noctalia Greeter Configuration
# ------------------------------------------------------------------------------
configure_greeter() {
    log_info "Configuring greetd and Noctalia Greeter..."

    # Ensure greeter user exists
    if ! id -u greeter >/dev/null 2>&1; then
        log_info "Creating dedicated 'greeter' system user..."
        sudo useradd -M -G video,input -s /usr/bin/nologin greeter 2>/dev/null || true
    else
        sudo usermod -aG video,input greeter 2>/dev/null || true
    fi

    # Run upstream greeter system setup helper if available
    if [ -x /usr/share/noctalia-greeter/setup_greeter_system.sh ]; then
        log_info "Executing noctalia-greeter system setup script..."
        sudo /usr/share/noctalia-greeter/setup_greeter_system.sh || true
    fi

    # Ensure greeter state directory permissions
    sudo mkdir -p /var/lib/noctalia-greeter
    sudo chown -R greeter:greeter /var/lib/noctalia-greeter
    sudo chmod 755 /var/lib/noctalia-greeter

    # Write /etc/greetd/config.toml
    log_info "Writing /etc/greetd/config.toml..."
    sudo mkdir -p /etc/greetd
    cat <<EOF | sudo tee /etc/greetd/config.toml >/dev/null
[terminal]
vt = 1

[default_session]
command = "/usr/bin/noctalia-greeter-session"
user = "greeter"
EOF

    # Enable greetd systemd service
    log_info "Enabling greetd service..."
    sudo systemctl daemon-reload
    sudo systemctl enable greetd.service
    log_success "Greetd and Noctalia Greeter configured."
}

# ------------------------------------------------------------------------------
# Wayland Session Entry
# ------------------------------------------------------------------------------
configure_wayland_session() {
    log_info "Creating Umbriel Wayland session entry..."
    sudo mkdir -p /usr/share/wayland-sessions
    if [ -f "$SCRIPT_DIR/configs/umbriel/umbriel.desktop" ]; then
        sudo cp "$SCRIPT_DIR/configs/umbriel/umbriel.desktop" /usr/share/wayland-sessions/umbriel.desktop
    else
        cat <<EOF | sudo tee /usr/share/wayland-sessions/umbriel.desktop >/dev/null
[Desktop Entry]
Name=Umbriel
Comment=Umbriel Wayland Compositor
Exec=umbriel
Type=Application
DesktopNames=umbriel
Keywords=wayland;compositor;tiling;noctalia;
EOF
    fi
    sudo chmod 644 /usr/share/wayland-sessions/umbriel.desktop
    log_success "Umbriel session entry registered in /usr/share/wayland-sessions/umbriel.desktop."
}

# ------------------------------------------------------------------------------
# User Dotfiles & Configurations
# ------------------------------------------------------------------------------
configure_user_environment() {
    log_info "Deploying configurations for $USER (Gruvbox Dark)..."

    # Add user to hardware groups
    local GROUPS="wheel,video,audio,input,storage"
    getent group seat >/dev/null 2>&1 && GROUPS="$GROUPS,seat"
    sudo usermod -aG "$GROUPS" "$USER"

    # Initialize XDG user directories
    xdg-user-dirs-update 2>/dev/null || true

    # 1. Deploy Umbriel config
    mkdir -p "${HOME}/.config/umbriel"
    if [ -f "$SCRIPT_DIR/configs/umbriel/config.toml" ]; then
        cp "$SCRIPT_DIR/configs/umbriel/config.toml" "${HOME}/.config/umbriel/config.toml"
    fi

    # 2. Deploy Alacritty config (Gruvbox Dark)
    mkdir -p "${HOME}/.config/alacritty"
    if [ -d "$SCRIPT_DIR/configs/alacritty" ]; then
        cp -r "$SCRIPT_DIR/configs/alacritty/"* "${HOME}/.config/alacritty/"
    fi

    # 3. Deploy Noctalia Gruvbox Dark Palette
    mkdir -p "${HOME}/.config/noctalia/palettes/Gruvbox Dark"
    if [ -f "$SCRIPT_DIR/configs/noctalia/palettes/Gruvbox Dark/Gruvbox Dark.json" ]; then
        cp "$SCRIPT_DIR/configs/noctalia/palettes/Gruvbox Dark/Gruvbox Dark.json" \
           "${HOME}/.config/noctalia/palettes/Gruvbox Dark/Gruvbox Dark.json"
    fi

    # 4. Wayland environment variables
    mkdir -p "${HOME}/.config/environment.d"
    cat <<EOF > "${HOME}/.config/environment.d/10-wayland.conf"
MOZ_ENABLE_WAYLAND=1
QT_QPA_PLATFORM=wayland;xcb
XDG_CURRENT_DESKTOP=umbriel:GNOME
XDG_SESSION_TYPE=wayland
XDG_SESSION_DESKTOP=umbriel
EOF

    log_success "User dotfiles and configurations deployed."
}

# ------------------------------------------------------------------------------
# Service Activation
# ------------------------------------------------------------------------------
activate_services() {
    log_info "Enabling essential system services..."
    local SERVICES="dbus NetworkManager bluetooth"
    for svc in $SERVICES; do
        if systemctl list-unit-files "${svc}.service" >/dev/null 2>&1; then
            sudo systemctl enable --now "$svc" 2>/dev/null || true
            log_info "Enabled and started $svc"
        fi
    done
}

# ------------------------------------------------------------------------------
# Main Flow
# ------------------------------------------------------------------------------
main() {
    clear 2>/dev/null || true
    printf "${BOLD}${GREEN}===================================================================${RC}\n"
    printf "${BOLD}${GREEN}   Ethos Echo: Independent Umbriel & Noctalia Suite Installer     ${RC}\n"
    printf "${BOLD}${GREEN}   Compositor: Umbriel | Shell: Noctalia | Terminal: Alacritty    ${RC}\n"
    printf "${BOLD}${GREEN}   Theme: Gruvbox Dark | Greeter: Noctalia Greeter (greetd)       ${RC}\n"
    printf "${BOLD}${GREEN}===================================================================${RC}\n\n"

    check_env
    clean_existing_system
    prepare_system
    bootstrap_aur_helper
    install_graphics
    install_core_services
    install_aur_desktop_packages
    configure_greeter
    configure_wayland_session
    configure_user_environment
    activate_services

    printf "\n${BOLD}${GREEN}===================================================================${RC}\n"
    printf "${BOLD}${GREEN}                  INSTALLATION COMPLETED!                          ${RC}\n"
    printf "${BOLD}${GREEN}===================================================================${RC}\n"
    printf "${BOLD}Keybindings Cheat Sheet:${RC}\n"
    printf "  ${CYAN}Mod + Return${RC}        : Launch Alacritty Terminal (Gruvbox Dark)\n"
    printf "  ${CYAN}Mod + d${RC}             : Toggle Noctalia App Launcher\n"
    printf "  ${CYAN}Mod + s${RC}             : Toggle Noctalia Control Center\n"
    printf "  ${CYAN}Mod + n${RC}             : Toggle Noctalia Notifications\n"
    printf "  ${CYAN}Mod + Escape${RC}        : Toggle Power / Session Menu\n"
    printf "  ${CYAN}Mod + q${RC}             : Close Active Window\n"
    printf "  ${CYAN}Mod + Space${RC}         : Toggle Floating Window\n"
    printf "  ${CYAN}Mod + f${RC}             : Toggle Fullscreen\n"
    printf "  ${CYAN}Mod + o${RC}             : Toggle Overview\n"
    printf "  ${CYAN}Mod + 1..9${RC}          : Switch Workspaces\n"
    printf "%s\n" "-------------------------------------------------------------------"
    printf "${YELLOW}Next Step: Reboot your machine to enter Noctalia Greeter:${RC}\n"
    printf "  ${BOLD}sudo reboot${RC}\n"
    printf "${BOLD}${GREEN}===================================================================${RC}\n"
}

main "$@"
