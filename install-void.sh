#!/usr/bin/env bash
# ==============================================================================
# Ethos Echo - Independent Umbriel, Noctalia & Noctalia Greeter Installer
# Architecture: Void Linux (runit, xbps, Wayland, Gruvbox Dark, Alacritty)
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

SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"

command_exists() {
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || return 1
    done
    return 0
}

# ------------------------------------------------------------------------------
# Preflight & Environment Checks
# ------------------------------------------------------------------------------
check_void_distro() {
    local IS_VOID=0

    if [ -f /etc/os-release ]; then
        if grep -q -E '^ID="?void"?' /etc/os-release; then
            IS_VOID=1
        fi
    elif [ -f /usr/lib/os-release ]; then
        if grep -q -E '^ID="?void"?' /usr/lib/os-release; then
            IS_VOID=1
        fi
    fi

    # Fallback to checking package manager or xbps database
    if [ "$IS_VOID" -eq 0 ] && (command_exists xbps-install || [ -d /var/db/xbps ]); then
        IS_VOID=1
    fi

    if [ "$IS_VOID" -eq 0 ]; then
        log_error "This script is tailored specifically for Void Linux. Void Linux identification was not found."
        log_info "Expected ID=void in /etc/os-release or xbps package manager."
        exit 1
    fi
    log_success "Void Linux detected."
}

check_cpu_arch() {
    local MACHINE
    MACHINE="$(uname -m)"
    case "$MACHINE" in
        x86_64 | amd64)
            ARCH="x86_64"
            ;;
        *)
            log_error "Unsupported architecture: ${MACHINE}. Prebuilt packages require x86_64."
            exit 1
            ;;
    esac
    log_info "System architecture: ${ARCH}"
}

check_libc() {
    # Check glibc vs musl
    if ldd --version 2>&1 | grep -qi "musl" || [ -f /lib/ld-musl-x86_64.so.1 ]; then
        log_warn "Void Linux musl detected. Universal Repository binary packages and jemalloc target glibc."
        log_warn "The installer will attempt builds, but a glibc-based Void installation is recommended."
    else
        log_info "C Library: GNU C Library (glibc)"
    fi
}

check_user_and_sudo() {
    if [ "$(id -u)" -eq 0 ]; then
        log_error "Do not run this script as root or with sudo directly!"
        log_info "User-space configurations and builds must be executed as a normal user."
        log_info "Please run as your regular user: ./${0##*/}"
        log_info "The script will prompt for sudo only when system privileges are required."
        exit 1
    fi

    if ! command_exists sudo; then
        log_error "sudo is required for system configuration but not found."
        log_info "Please install sudo (xbps-install -S sudo) and ensure your user is in the wheel group."
        exit 1
    fi

    log_info "Validating sudo access for $USER..."
    if ! sudo -v; then
        log_error "Failed to authenticate with sudo."
        exit 1
    fi

    # Keep sudo timestamp alive in background while the script runs without modifying sudoers
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
    if [ ! -w "$SCRIPT_DIR" ]; then
        log_error "Cannot write to directory: $SCRIPT_DIR"
        exit 1
    fi
}

check_env() {
    check_void_distro
    check_cpu_arch
    check_libc
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

    # Disable conflicting display managers from runit
    for dm in lemurs sddm gdm lightdm lxdm; do
        if [ -L "/var/service/$dm" ]; then
            log_warn "Disabling conflicting display manager in runit: $dm"
            sudo rm -f "/var/service/$dm" 2>/dev/null || true
        fi
    done

    # Remove stale temporary build directories
    rm -rf /tmp/umbriel-build.* /tmp/umbriel-portal-build.* 2>/dev/null || true

    log_success "Clean-slate system purge complete."
}

# ------------------------------------------------------------------------------
# Swap & Memory Safety (for C++23 compilation)
# ------------------------------------------------------------------------------
ensure_swap() {
    local SWAP_TOTAL_MB
    SWAP_TOTAL_MB="$(free -m 2>/dev/null | awk '/^Swap:/ {print $2}')"
    local MEM_TOTAL_MB
    MEM_TOTAL_MB="$(free -m 2>/dev/null | awk '/^Mem:/ {print $2}')"

    # If swap is under 2GB and physical RAM is under 6GB, configure swap
    if [ "${SWAP_TOTAL_MB:-0}" -lt 2048 ] && [ "${MEM_TOTAL_MB:-0}" -lt 6144 ]; then
        log_info "Low memory detected (RAM: ${MEM_TOTAL_MB:-0}MB, Swap: ${SWAP_TOTAL_MB:-0}MB)."
        log_info "Configuring swap to prevent Out-Of-Memory (OOM) compiler crashes..."

        local SWAP_FILE="/swapfile_ethos"
        if [ ! -f "$SWAP_FILE" ]; then
            local ROOT_AVAIL_MB
            ROOT_AVAIL_MB="$(df -m / | awk 'NR==2 {print $4}')"

            local SWAP_SIZE_GB=4
            if [ "${ROOT_AVAIL_MB:-0}" -lt 6000 ]; then
                SWAP_SIZE_GB=2
            fi

            if [ "${ROOT_AVAIL_MB:-0}" -gt 2500 ]; then
                log_info "Creating ${SWAP_SIZE_GB}GB swap file at ${SWAP_FILE}..."
                local ROOT_FSTYPE
                ROOT_FSTYPE="$(findmnt -n -o FSTYPE / 2>/dev/null || echo "")"

                if [ "$ROOT_FSTYPE" = "btrfs" ] && command_exists btrfs; then
                    sudo btrfs filesystem mkswapfile --size "${SWAP_SIZE_GB}g" "$SWAP_FILE" 2>/dev/null || true
                else
                    sudo dd if=/dev/zero of="$SWAP_FILE" bs=1M count=$(( SWAP_SIZE_GB * 1024 )) status=none 2>/dev/null || true
                    sudo chmod 600 "$SWAP_FILE"
                    sudo mkswap "$SWAP_FILE" 2>/dev/null || true
                fi
            else
                log_warn "Insufficient free disk space to create swapfile. Proceeding with RAM only."
            fi
        fi

        if [ -f "$SWAP_FILE" ]; then
            sudo swapon "$SWAP_FILE" 2>/dev/null || true
            log_success "Swap activated successfully."
        fi
    fi
}

# ------------------------------------------------------------------------------
# Repository Configuration & Synchronization
# ------------------------------------------------------------------------------
configure_repositories() {
    log_info "Configuring package repositories..."

    # Ensure /etc/xbps.d exists
    sudo mkdir -p /etc/xbps.d

    # Add Universal Repository for Noctalia and Noctalia Greeter prebuilt packages
    local NOCTALIA_REPO_CONF="/etc/xbps.d/10-noctalia.conf"
    if [ ! -f "$NOCTALIA_REPO_CONF" ] || ! grep -q "universalrepository.pages.dev/void" "$NOCTALIA_REPO_CONF" 2>/dev/null; then
        log_info "Registering Universal Repository (https://universalrepository.pages.dev/void)..."
        cat <<EOF | sudo tee "$NOCTALIA_REPO_CONF" >/dev/null
# Universal Repository - Noctalia & Noctalia Greeter for Void Linux
repository=https://universalrepository.pages.dev/void
EOF
    fi

    log_info "Synchronizing package databases with XBPS..."
    # Feed yes to automatically import repo RSA key if prompted on first sync
    yes | sudo xbps-install -S || sudo xbps-install -S

    log_info "Updating base system packages..."
    sudo xbps-install -uy xbps 2>/dev/null || true
    sudo xbps-install -uy
    log_success "Package databases synchronized and system updated."
}

# ------------------------------------------------------------------------------
# Core Build Tools & Dependencies
# ------------------------------------------------------------------------------
install_build_tools() {
    log_info "Installing core build tools and utilities..."
    sudo xbps-install -y \
        base-devel git curl wget pciutils jq tar xz \
        meson ninja pkg-config
}

# ------------------------------------------------------------------------------
# Graphics & Hardware Acceleration
# ------------------------------------------------------------------------------
install_graphics() {
    log_info "Detecting GPU and installing display drivers..."
    sudo xbps-install -y \
        mesa-dri vulkan-loader xorg-server-xwayland

    if lspci 2>/dev/null | grep -qi "nvidia"; then
        log_info "NVIDIA GPU detected."
        # Enable nonfree repo if available for proprietary drivers
        if sudo xbps-install -y void-repo-nonfree 2>/dev/null; then
            sudo xbps-install -S 2>/dev/null || true
            sudo xbps-install -y nvidia nvidia-vaapi-driver 2>/dev/null || {
                log_warn "Proprietary nvidia package unavailable. Falling back to Mesa Nouveau driver."
                sudo xbps-install -y mesa-vulkan-nouveau
            }
        else
            sudo xbps-install -y mesa-vulkan-nouveau
        fi
        log_warn "NVIDIA Note: Ensure 'nvidia-drm.modeset=1' and 'nvidia-drm.fbdev=1' are set in kernel boot parameters."
    elif lspci 2>/dev/null | grep -qi "amd"; then
        log_info "AMD GPU detected. Installing AMD Vulkan and VA-API drivers..."
        sudo xbps-install -y mesa-vulkan-radeon mesa-vaapi
    elif lspci 2>/dev/null | grep -qi "intel"; then
        log_info "Intel GPU detected. Installing Intel Vulkan and Media drivers..."
        sudo xbps-install -y mesa-vulkan-intel mesa-vaapi 2>/dev/null || sudo xbps-install -y mesa-vulkan-intel
    else
        log_info "Generic or Virtual display adapter detected. Mesa lavapipe installed."
        sudo xbps-install -y mesa-vulkan-lavapipe 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# Core Desktop Plumbing, Audio & Fonts
# ------------------------------------------------------------------------------
install_core_services() {
    log_info "Installing system plumbing, audio, session management, and fonts..."
    sudo xbps-install -y \
        dbus elogind NetworkManager \
        pipewire wireplumber wireplumber-elogind alsa-pipewire \
        bluez \
        polkit lxqt-policykit \
        xdg-desktop-portal xdg-desktop-portal-wlr xdg-desktop-portal-gtk xdg-user-dirs \
        brightnessctl \
        alacritty \
        nerd-fonts noto-fonts-ttf noto-fonts-emoji noto-fonts-cjk
}

# ------------------------------------------------------------------------------
# Noctalia & Noctalia Greeter (Universal Repository)
# ------------------------------------------------------------------------------
install_noctalia_packages() {
    log_info "Installing Noctalia shell, Noctalia Greeter, and greetd..."
    sudo xbps-install -y noctalia noctalia-greeter greetd
    log_success "Noctalia desktop packages installed successfully."
}

# ------------------------------------------------------------------------------
# Umbriel Compositor & Portal Compilation
# ------------------------------------------------------------------------------
build_and_install_umbriel() {
    log_info "Installing build dependencies for Umbriel..."
    sudo xbps-install -y \
        wayland-devel wayland-protocols \
        wlroots0.20-devel \
        libxkbcommon-devel libinput-devel \
        pixman-devel libdrm-devel libgbm-devel libglvnd-devel \
        eudev-libudev-devel \
        cairo-devel pango-devel \
        tomlplusplus-devel json-c++ \
        libxcb-devel xcb-util-wm-devel jemalloc-devel \
        xwayland-satellite 2>/dev/null || true

    # Ensure nlohmann_json.pc exists for Meson pkg-config lookup
    if ! pkg-config --exists nlohmann_json 2>/dev/null; then
        log_info "Creating nlohmann_json.pc pkg-config shim..."
        sudo mkdir -p /usr/share/pkgconfig
        cat <<EOF | sudo tee /usr/share/pkgconfig/nlohmann_json.pc >/dev/null
Name: nlohmann_json
Description: JSON for Modern C++
Version: 3.12.0
Cflags: -I/usr/include
EOF
    fi

    log_info "Fetching and compiling Umbriel Wayland Compositor (C++23)..."
    local UMBRIEL_BUILD_DIR
    UMBRIEL_BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/umbriel-build.XXXXXX")"

    git clone --depth 1 https://github.com/noctalia-dev/umbriel.git "$UMBRIEL_BUILD_DIR"

    local CORES
    CORES="$(nproc 2>/dev/null || echo 2)"
    local MEM_MB
    MEM_MB="$(free -m 2>/dev/null | awk '/^Mem:/ {print $2}')"
    local BUILD_JOBS="$CORES"
    if [ "${MEM_MB:-0}" -lt 3072 ] && [ "$CORES" -gt 2 ]; then
        BUILD_JOBS=2
    fi

    (
        cd "$UMBRIEL_BUILD_DIR"
        log_info "Running Meson setup (prefix=/usr, buildtype=release, jobs=$BUILD_JOBS)..."
        meson setup build \
            --prefix=/usr \
            --buildtype=release \
            -Dtests=disabled \
            -Dtest_ipc=disabled

        log_info "Compiling Umbriel binary..."
        ninja -C build -j"$BUILD_JOBS"

        log_info "Installing Umbriel to /usr..."
        sudo ninja -C build install
    )

    rm -rf "$UMBRIEL_BUILD_DIR"

    if command_exists umbriel; then
        log_success "Umbriel compositor compiled and installed successfully: $(command -v umbriel)"
    else
        log_error "Umbriel installation failed. Binary not found in PATH."
        exit 1
    fi
}

build_and_install_portal() {
    log_info "Checking xdg-desktop-portal-umbriel backend..."
    sudo xbps-install -y sdbus-c++-devel pipewire-devel gtk4-devel 2>/dev/null || true

    local PORTAL_BUILD_DIR
    PORTAL_BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/umbriel-portal-build.XXXXXX")"

    if git clone --depth 1 https://github.com/noctalia-dev/xdg-desktop-portal-umbriel.git "$PORTAL_BUILD_DIR" 2>/dev/null; then
        (
            cd "$PORTAL_BUILD_DIR"
            log_info "Compiling xdg-desktop-portal-umbriel..."
            if meson setup build --prefix=/usr --buildtype=release 2>/dev/null; then
                ninja -C build -j"$(nproc 2>/dev/null || echo 2)" 2>/dev/null || true
                sudo ninja -C build install 2>/dev/null || true
                log_success "Installed xdg-desktop-portal-umbriel."
            else
                log_warn "Optional portal build skipped; xdg-desktop-portal-wlr will serve as fallback."
            fi
        )
    fi

    rm -rf "$PORTAL_BUILD_DIR"
}

# ------------------------------------------------------------------------------
# Greetd & Noctalia Greeter Configuration (runit & PAM)
# ------------------------------------------------------------------------------
configure_greeter() {
    log_info "Configuring greetd and Noctalia Greeter for Void Linux..."

    # Ensure dedicated 'greeter' system user exists with hardware access
    if ! id -u greeter >/dev/null 2>&1; then
        log_info "Creating 'greeter' system user..."
        sudo useradd -M -G video,input -s /usr/bin/nologin -d /var/lib/noctalia-greeter greeter 2>/dev/null || true
    fi

    # Ensure both greeter and _greeter (Void package default) have necessary hardware groups
    for guser in greeter _greeter; do
        if id -u "$guser" >/dev/null 2>&1; then
            for grp in video input seat _seatd audio; do
                if getent group "$grp" >/dev/null 2>&1; then
                    sudo usermod -aG "$grp" "$guser" 2>/dev/null || true
                fi
            done
        fi
    done

    # Ensure /etc/pam.d/greetd exists with standard Void PAM configuration
    if [ ! -f /etc/pam.d/greetd ]; then
        log_info "Configuring /etc/pam.d/greetd..."
        sudo mkdir -p /etc/pam.d
        cat <<EOF | sudo tee /etc/pam.d/greetd >/dev/null
#%PAM-1.0
auth       required     pam_securetty.so
auth       requisite    pam_nologin.so
auth       include      system-local-login
-auth      optional     pam_gnome_keyring.so
account    include      system-local-login
session    include      system-local-login
session    optional     pam_elogind.so
-session   optional     pam_gnome_keyring.so auto_start
EOF
    fi

    # Run upstream greeter setup script if available
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

    # Create robust runit service for greetd (verifies D-Bus and locale before starting)
    log_info "Setting up greetd runit service (/etc/sv/greetd)..."
    sudo mkdir -p /etc/sv/greetd
    cat <<'EOF' | sudo tee /etc/sv/greetd/run >/dev/null
#!/bin/sh
exec 2>&1
set -e

# Wait for D-Bus system bus to be running
sv check dbus >/dev/null 2>&1 || exit 1

# Wake up elogind / login1 session manager if present
if [ -x /usr/bin/elogind-inhibit ]; then
    dbus-send --system --print-reply --dest=org.freedesktop.DBus \
        /org/freedesktop/DBus \
        org.freedesktop.DBus.StartServiceByName \
        string:org.freedesktop.login1 uint32:0 >/dev/null 2>&1 || true
fi

# Respect system locale from /etc/locale.conf
[ -r /etc/locale.conf ] && . /etc/locale.conf && export LANG

exec greetd
EOF
    sudo chmod +x /etc/sv/greetd/run

    log_success "Greetd and Noctalia Greeter configured."
}

# ------------------------------------------------------------------------------
# Wayland Session Entry & Autostart Helpers
# ------------------------------------------------------------------------------
configure_session_and_helpers() {
    log_info "Configuring Wayland session wrapper and autostart helpers..."

    # 1. System-wide umbriel-session wrapper (ensures D-Bus session bus on non-systemd)
    cat <<'EOF' | sudo tee /usr/local/bin/umbriel-session >/dev/null
#!/bin/sh
# Ethos Echo - Umbriel Session Wrapper (Void Linux)
if [ -z "$DBUS_SESSION_BUS_ADDRESS" ]; then
    exec dbus-run-session umbriel "$@"
else
    exec umbriel "$@"
fi
EOF
    sudo chmod 755 /usr/local/bin/umbriel-session

    # 2. Desktop session file
    sudo mkdir -p /usr/share/wayland-sessions
    cat <<EOF | sudo tee /usr/share/wayland-sessions/umbriel.desktop >/dev/null
[Desktop Entry]
Name=Umbriel
Comment=Umbriel Wayland Compositor
Exec=/usr/local/bin/umbriel-session
Type=Application
DesktopNames=umbriel
Keywords=wayland;compositor;tiling;noctalia;
EOF
    sudo chmod 644 /usr/share/wayland-sessions/umbriel.desktop

    # 3. Dedicated autostart helper (manages PipeWire, Polkit, and Noctalia cleanly)
    cat <<'EOF' | sudo tee /usr/local/bin/umbriel-autostart >/dev/null
#!/bin/sh
# Ethos Echo - Umbriel Session Autostart Helper (Void Linux)

# Propagate environment to D-Bus activation
if command -v dbus-update-activation-environment >/dev/null 2>&1; then
    dbus-update-activation-environment --all 2>/dev/null || true
fi

# Launch PipeWire audio stack if not already active
if command -v pipewire >/dev/null 2>&1; then
    pgrep -x pipewire >/dev/null 2>&1 || pipewire &
    sleep 0.3
    pgrep -x wireplumber >/dev/null 2>&1 || wireplumber &
    pgrep -x pipewire-pulse >/dev/null 2>&1 || pipewire-pulse &
fi

# Launch Polkit graphical authentication agent
if command -v lxqt-policykit-agent >/dev/null 2>&1; then
    pgrep -x lxqt-policykit-agent >/dev/null 2>&1 || lxqt-policykit-agent &
elif [ -x /usr/libexec/polkit-gnome-authentication-agent-1 ]; then
    pgrep -x polkit-gnome-authentication-agent-1 >/dev/null 2>&1 || /usr/libexec/polkit-gnome-authentication-agent-1 &
fi

# Launch Noctalia Desktop Shell
if command -v noctalia >/dev/null 2>&1; then
    pgrep -x noctalia >/dev/null 2>&1 || exec noctalia
fi
EOF
    sudo chmod 755 /usr/local/bin/umbriel-autostart

    log_success "Session entry and autostart helpers configured."
}

# ------------------------------------------------------------------------------
# User Dotfiles & Configurations (Gruvbox Dark)
# ------------------------------------------------------------------------------
configure_user_environment() {
    log_info "Deploying configurations for $USER (Gruvbox Dark)..."

    # Add user to required hardware and privilege groups
    local TARGET_GROUPS="wheel video audio input storage network kvm seat _seatd"
    for grp in $TARGET_GROUPS; do
        if getent group "$grp" >/dev/null 2>&1; then
            sudo usermod -aG "$grp" "$USER" 2>/dev/null || true
        fi
    done

    # Initialize XDG directories
    xdg-user-dirs-update 2>/dev/null || true

    # 1. Deploy Umbriel config
    mkdir -p "${HOME}/.config/umbriel"
    if [ -f "$SCRIPT_DIR/configs/umbriel/config.toml" ]; then
        cp "$SCRIPT_DIR/configs/umbriel/config.toml" "${HOME}/.config/umbriel/config.toml"
        # Update autostart to use our autostart helper
        sed -i 's|autostart = \["noctalia"\]|autostart = \["/usr/local/bin/umbriel-autostart"\]|' \
            "${HOME}/.config/umbriel/config.toml"
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

    # Also append to ~/.profile to guarantee availability on console / greetd sessions
    touch "${HOME}/.profile"
    if ! grep -q "XDG_CURRENT_DESKTOP=umbriel:GNOME" "${HOME}/.profile"; then
        cat <<'EOF' >> "${HOME}/.profile"

# Ethos Echo - Wayland Environment Variables
export MOZ_ENABLE_WAYLAND=1
export QT_QPA_PLATFORM="wayland;xcb"
export XDG_CURRENT_DESKTOP="umbriel:GNOME"
export XDG_SESSION_TYPE="wayland"
export XDG_SESSION_DESKTOP="umbriel"
EOF
    fi

    log_success "User dotfiles and configurations deployed."
}

# ------------------------------------------------------------------------------
# Runit Service Activation
# ------------------------------------------------------------------------------
activate_services() {
    log_info "Enabling essential system services in runit..."

    # 1. Core system daemons (dbus, elogind, NetworkManager)
    local CORE_SERVICES="dbus elogind NetworkManager"
    for svc in $CORE_SERVICES; do
        if [ -d "/etc/sv/$svc" ]; then
            sudo ln -sf "/etc/sv/$svc" /var/service/
            log_info "Enabled runit service: $svc"
        else
            log_warn "Service template /etc/sv/$svc not found, skipping."
        fi
    done

    # 2. Bluetooth daemon if present
    if [ -d /etc/sv/bluetoothd ]; then
        sudo ln -sf /etc/sv/bluetoothd /var/service/
        log_info "Enabled runit service: bluetoothd"
    fi

    # 3. Greetd Display Manager (activated after D-Bus and elogind are in place)
    if [ -d /etc/sv/greetd ]; then
        # Disable conflicting agetty on tty1 so greetd owns vt1 without blocking current TTY
        if [ -L /var/service/agetty-tty1 ] || [ -d /var/service/agetty-tty1 ]; then
            log_info "Disabling agetty-tty1 to prevent TTY conflicts with greetd..."
            sudo touch /etc/sv/agetty-tty1/down 2>/dev/null || true
            sudo rm -f /var/service/agetty-tty1 2>/dev/null || true
        fi

        sudo ln -sf /etc/sv/greetd /var/service/
        log_info "Enabled runit service: greetd"
    fi
}

# ------------------------------------------------------------------------------
# Main Flow
# ------------------------------------------------------------------------------
main() {
    clear 2>/dev/null || true
    printf "${BOLD}${GREEN}===================================================================${RC}\n"
    printf "${BOLD}${GREEN}   Ethos Echo: Independent Umbriel & Noctalia Suite Installer     ${RC}\n"
    printf "${BOLD}${GREEN}   Platform: Void Linux (runit, xbps, Wayland)                    ${RC}\n"
    printf "${BOLD}${GREEN}   Compositor: Umbriel | Shell: Noctalia | Terminal: Alacritty    ${RC}\n"
    printf "${BOLD}${GREEN}   Theme: Gruvbox Dark | Greeter: Noctalia Greeter (greetd)       ${RC}\n"
    printf "${BOLD}${GREEN}===================================================================${RC}\n\n"

    check_env
    clean_existing_system
    ensure_swap
    configure_repositories
    install_build_tools
    install_graphics
    install_core_services
    install_noctalia_packages
    build_and_install_umbriel
    build_and_install_portal
    configure_greeter
    configure_session_and_helpers
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
    printf "${YELLOW}Next Step: Reboot your Void Linux system to enter Noctalia Greeter:${RC}\n"
    printf "  ${BOLD}sudo reboot${RC}\n"
    printf "${BOLD}${GREEN}===================================================================${RC}\n"
}

main "$@"
