#!/usr/bin/env bash

RC='\033[0m'
RED='\033[31m'
YELLOW='\033[33m'
CYAN='\033[36m'
GREEN='\033[32m'

info()  { printf "${CYAN}[INFO]${RC} %s\n" "$1"; }
ok()    { printf "${GREEN}[OK]${RC} %s\n" "$1"; }
warn()  { printf "${YELLOW}[WARN]${RC} %s\n" "$1"; }
err()   { printf "${RED}[ERROR]${RC} %s\n" "$1"; }

command_exists() {
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || return 1
    done
    return 0
}

checkArch() {
    case "$(uname -m)" in
        x86_64 | amd64) ARCH="x86_64" ;;
        aarch64 | arm64) ARCH="aarch64" ;;
        *) err "Unsupported architecture: $(uname -m)" && exit 1 ;;
    esac
    info "System architecture: ${ARCH}"
}

checkEscalationTool() {
    if [ -z "${ESCALATION_TOOL_CHECKED:-}" ]; then
        if [ "$(id -u)" = "0" ]; then
            ESCALATION_TOOL="eval"
            ESCALATION_TOOL_CHECKED=true
            info "Running as root, no escalation needed"
            return 0
        fi

        for tool in sudo doas; do
            if command_exists "${tool}"; then
                ESCALATION_TOOL=${tool}
                info "Using ${tool} for privilege escalation"
                ESCALATION_TOOL_CHECKED=true
                return 0
            fi
        done

        err "Can't find a supported escalation tool (sudo/doas)"
        exit 1
    fi
}

checkCommandRequirements() {
    for req in $1; do
        if ! command_exists "${req}"; then
            err "To run me, you need: ${req}"
            exit 1
        fi
    done
}

checkPackageManager() {
    for pgm in $1; do
        if command_exists "${pgm}"; then
            PACKAGER=${pgm}
            info "Using ${pgm} as package manager"
            break
        fi
    done

    if [ "$PACKAGER" = "xbps-install" ] && [ ! -f /etc/xbps.d/00-repository-main.conf ]; then
        info "Configuring default Void Linux repository..."
        "$ESCALATION_TOOL" mkdir -p /etc/xbps.d
        "$ESCALATION_TOOL" sh -c 'echo "repository=https://repo-default.voidlinux.org/current" > /etc/xbps.d/00-repository-main.conf'
        ok "Default Void Linux repository configured"
    fi

    if [ -z "$PACKAGER" ]; then
        err "Can't find a supported package manager (pacman/xbps-install)"
        exit 1
    fi
}

checkSuperUser() {
    for sug in wheel sudo root; do
        if id -nG 2>/dev/null | grep -qw "${sug}"; then
            SUGROUP=${sug}
            info "Super user group: ${SUGROUP}"
            return 0
        fi
    done
    err "You need to be a member of the sudo/wheel group to run me"
    exit 1
}

checkCurrentDirectoryWritable() {
    GITPATH="$(dirname "$(realpath "$0")")"
    if [ ! -w "$GITPATH" ]; then
        warn "Can't write to $GITPATH — proceeding anyway"
    fi
}

detectTargetUser() {
    if [ -n "${SUDO_USER:-}" ]; then
        TARGET_USER="$SUDO_USER"
    else
        TARGET_USER="$(whoami)"
    fi
    TARGET_HOME="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6)"
    [ -z "$TARGET_HOME" ] && TARGET_HOME="$HOME"
    info "Target user: $TARGET_USER  Home: $TARGET_HOME"
}

checkEnv() {
    checkArch
    checkEscalationTool
    checkCommandRequirements "curl groups $ESCALATION_TOOL"
    checkPackageManager 'pacman xbps-install'
    checkCurrentDirectoryWritable
    checkSuperUser
    detectTargetUser
}

# ── Resilient package installation ────────────────────────
install_packages() {
    local missing=0
    case "$PACKAGER" in
        pacman)
            "$ESCALATION_TOOL" "$PACKAGER" -S --needed --noconfirm "$@" 2>/dev/null || {
                warn "Batch install failed, trying individually..."
                for pkg in "$@"; do
                    if ! "$ESCALATION_TOOL" "$PACKAGER" -S --needed --noconfirm "$pkg" 2>/dev/null; then
                        warn "Package not found (skipping): $pkg"
                        missing=1
                    fi
                done
            }
            ;;
        xbps-install)
            "$ESCALATION_TOOL" "$PACKAGER" -S -y "$@" 2>/dev/null || {
                warn "Batch install failed, trying individually..."
                for pkg in "$@"; do
                    if ! "$ESCALATION_TOOL" "$PACKAGER" -S -y "$pkg" 2>/dev/null; then
                        warn "Package not found in repos (skipping): $pkg"
                        missing=1
                    fi
                done
            }
            ;;
    esac
    return $missing
}

# ── Core: install build & runtime dependencies ────────────
setupDWM() {
    info "Installing dwm-gossamer dependencies..."

    case "$PACKAGER" in
        pacman)
            "$ESCALATION_TOOL" "$PACKAGER" -S --needed --noconfirm \
                base-devel git linux-headers unzip curl wget \
                xorg-server xorg-xinit xorg-xrandr xorg-xsetroot xorg-xprop xorg-xset xorg-xhost xf86-input-libinput \
                libx11 libxinerama libxft libxcb imlib2 fontconfig freetype2 \
                polybar picom dunst rofi dmenu slock alacritty xdo xdotool \
                feh flameshot imagemagick ffmpeg playerctl \
                btop htop arandr xclip xsel xarchiver thunar tumbler gvfs thunar-archive-plugin \
                tldr dex nwg-look xscreensaver brightnessctl acpi \
                xdg-user-dirs xdg-desktop-portal-gtk xdg-utils \
                firefox polkit-gnome alsa-utils pavucontrol pipewire gnome-keyring flatpak \
                networkmanager network-manager-applet openssh neovim \
                fzf bat fd \
                ttf-liberation ttf-dejavu noto-fonts noto-fonts-emoji terminus-font \
                fastfetch starship zoxide man-db
            ;;
        xbps-install)
            install_packages \
                base-devel git linux-headers unzip curl wget \
                xorg-server xinit xrandr xsetroot xprop xset xhost xf86-input-libinput \
                libX11-devel libXinerama-devel libXft-devel libxcb-devel imlib2-devel fontconfig-devel freetype-devel \
                polybar picom dunst rofi dmenu alacritty xdotool \
                feh htop arandr xclip xsel xarchiver thunar tumbler gvfs thunar-archive-plugin \
                ImageMagick ffmpeg playerctl \
                tldr dex xscreensaver brightnessctl acpi bluez \
                xdg-user-dirs xdg-desktop-portal-gtk xdg-utils \
                firefox polkit-gnome alsa-utils pavucontrol pipewire gnome-keyring flatpak \
                NetworkManager network-manager-applet openssh neovim \
                fzf bat fd \
                liberation-fonts-ttf dejavu-fonts-ttf noto-fonts-ttf noto-fonts-emoji terminus-font \
                starship zoxide man-pages mandoc
            ;;
        *)
            err "Unsupported package manager: $PACKAGER"
            exit 1
            ;;
    esac

    ok "Dependencies installed"
}

makeDWM() {
    local share_dir="$TARGET_HOME/.local/share"
    local repo_dir="$share_dir/dwm-gossamer"

    mkdir -p "$share_dir"

    if [ ! -d "$repo_dir" ]; then
        info "Cloning dwm-gossamer repository..."
        git clone https://github.com/Daniel1788/dwm-gossamer.git "$repo_dir" || {
            err "Failed to clone repository"
            exit 1
        }
    else
        info "dwm-gossamer directory exists, pulling latest..."
        git -C "$repo_dir" pull || warn "git pull failed, continuing with existing code"
    fi

    info "Building dwm..."
    "$ESCALATION_TOOL" make -C "$repo_dir" clean install || {
        err "Failed to build dwm"
        exit 1
    }

    info "Building slstatus..."
    "$ESCALATION_TOOL" make -C "$repo_dir/slstatus" clean install || {
        warn "Failed to build slstatus"
    }

    mkdir -p "$TARGET_HOME/Pictures/backgrounds/"
    if [ -f "$repo_dir/background.jpg" ]; then
        cp "$repo_dir/background.jpg" "$TARGET_HOME/Pictures/backgrounds/"
    fi
}

install_nerd_font() {
    FONT_NAME="MesloLGS Nerd Font Mono"
    FONT_DIR="$TARGET_HOME/.local/share/fonts"
    FONT_URL="https://github.com/ryanoasis/nerd-fonts/releases/latest/download/Meslo.zip"

    if fc-list 2>/dev/null | grep -qi "Meslo"; then
        ok "Meslo Nerd-fonts already installed"
        return 0
    fi

    info "Installing Meslo Nerd-fonts..."
    mkdir -p "$FONT_DIR"
    TEMP_DIR=$(mktemp -d)
    curl -sSLo "$TEMP_DIR/Meslo.zip" "$FONT_URL"
    unzip -q "$TEMP_DIR/Meslo.zip" -d "$TEMP_DIR"
    mkdir -p "$FONT_DIR/$FONT_NAME"
    mv "$TEMP_DIR"/*.ttf "$FONT_DIR/$FONT_NAME/"
    fc-cache -fv
    rm -rf "$TEMP_DIR"
    ok "Meslo Nerd-fonts installed"
}

clone_config_folders() {
    local repo_dir="$TARGET_HOME/.local/share/dwm-gossamer"

    mkdir -p "$TARGET_HOME/.config"
    mkdir -p "$TARGET_HOME/.local/bin"

    if [ -d "$repo_dir/scripts" ]; then
        cp -rf "$repo_dir/scripts/." "$TARGET_HOME/.local/bin/"
        ok "Scripts copied to ~/.local/bin"
    fi

    mkdir -p "$TARGET_HOME/.local/share/fonts"
    if [ -d "$repo_dir/polybar/fonts" ]; then
        cp -r "$repo_dir/polybar/fonts/"* "$TARGET_HOME/.local/share/fonts/"
        fc-cache -fv
        ok "Polybar icon fonts installed"
    fi

    if [ -d "$repo_dir/config" ]; then
        for dir in "$repo_dir/config/"*/; do
            [ -d "$dir" ] || continue
            dir_name=$(basename "$dir")
            cp -r "$dir" "$TARGET_HOME/.config/"
            ok "Cloned $dir_name to ~/.config/"
        done
    else
        warn "Config directory not found in repository"
    fi
}

activate_services() {
    info "Activating core services..."

    case "$PACKAGER" in
        pacman)
            install_packages dbus networkmanager bluez
            for svc in dbus NetworkManager bluetooth; do
                "$ESCALATION_TOOL" systemctl enable --now "$svc" 2>/dev/null && ok "Enabled $svc" || warn "Failed to enable $svc"
            done
            ;;
        xbps-install)
            install_packages dbus NetworkManager bluez
            for svc in dbus NetworkManager bluetoothd; do
                if [ -d "/etc/sv/$svc" ]; then
                    if [ ! -L "/var/service/$svc" ]; then
                        "$ESCALATION_TOOL" ln -sf "/etc/sv/$svc" "/var/service/"
                        ok "Enabled $svc"
                    else
                        ok "$svc already enabled"
                    fi
                else
                    warn "Service $svc not found in /etc/sv/ — is the package installed?"
                fi
            done
            ;;
    esac
}

configure_user() {
    local groups="wheel,video,audio"
    getent group bluetooth &>/dev/null && groups="$groups,bluetooth"

    info "Adding $TARGET_USER to groups: $groups"
    if [ "$ESCALATION_TOOL" = "eval" ]; then
        usermod -aG "$groups" "$TARGET_USER" 2>/dev/null || warn "Failed to modify groups (running as root directly)"
    else
        "$ESCALATION_TOOL" usermod -aG "$groups" "$TARGET_USER" 2>/dev/null || warn "Failed to modify groups"
    fi

    if command_exists xdg-user-dirs-update; then
        if [ "$ESCALATION_TOOL" = "eval" ]; then
            su - "$TARGET_USER" -c "xdg-user-dirs-update" 2>/dev/null || true
        else
            "$ESCALATION_TOOL" -u "$TARGET_USER" xdg-user-dirs-update 2>/dev/null || true
        fi
    fi

    if [ ! -f "$TARGET_HOME/.xinitrc" ]; then
        info "Creating ~/.xinitrc for DWM..."
        echo "exec dwm" > "$TARGET_HOME/.xinitrc"
        ok "Created ~/.xinitrc"
    fi
}

main() {
    checkEnv
    setupDWM
    makeDWM
    install_nerd_font
    clone_config_folders
    activate_services
    configure_user
    echo ""
    ok "DWM installation process complete!"
    echo ""
    info "Log out and select DWM from your display manager, or run: startx"
    echo ""
}

main "$@"
