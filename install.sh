#!/bin/sh

RC='\033[0m'
RED='\033[31m'
YELLOW='\033[33m'
CYAN='\033[36m'
GREEN='\033[32m'

LOG_ENABLED=false
LOG_FILE=""

setup_logging() {
    if [ -n "${INSTALL_DEBUG}" ] && [ "${INSTALL_DEBUG}" != "0" ]; then
        LOG_ENABLED=true
        LOG_FILE="${INSTALL_LOG_FILE:-/tmp/ethos-echo-install-$(date +%s).log}"
        printf "%b\n" "${CYAN}Debug logging enabled. Log file: ${LOG_FILE}${RC}"
        {
            echo "=== Ethos-Echo Installer Debug Log ==="
            echo "Started: $(date)"
            echo "System: $(uname -a)"
            echo "Command: $0 $*"
            echo ""
        } >> "$LOG_FILE"
    fi
}

log() {
    if [ "$LOG_ENABLED" = true ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
    fi
}

command_exists() {
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || return 1
    done
    return 0
}

backup_config() {
    local dest="$1"
    if [ -e "$dest" ]; then
        local backup="${dest}.backup.$(date +%s)"
        cp -r "$dest" "$backup"
        printf "%b\n" "${YELLOW}Backed up %s -> %s${RC}" "$dest" "$backup"
    fi
}

checkArch() {
    case "$(uname -m)" in
        x86_64 | amd64) ARCH="x86_64" ;;
        aarch64 | arm64) ARCH="aarch64" ;;
        *) printf "%b\n" "${RED}Unsupported architecture: $(uname -m)${RC}" && log "ERROR: Unsupported architecture: $(uname -m)" && exit 1 ;;
    esac

    printf "%b\n" "${CYAN}System architecture: ${ARCH}${RC}"
    log "Architecture: ${ARCH}"
}

checkEscalationTool() {
    ## Check for escalation tools.
    if [ -z "$ESCALATION_TOOL_CHECKED" ]; then
        if [ "$(id -u)" = "0" ]; then
            ESCALATION_TOOL=""
            ESCALATION_TOOL_CHECKED=true
            printf "%b\n" "${CYAN}Running as root, no escalation needed${RC}"
            log "Running as root"
            return 0
        fi

        ESCALATION_TOOLS='sudo doas'
        for tool in ${ESCALATION_TOOLS}; do
            if command_exists "${tool}"; then
                ESCALATION_TOOL=${tool}
                printf "%b\n" "${CYAN}Using ${tool} for privilege escalation${RC}"
                ESCALATION_TOOL_CHECKED=true
                log "Escalation tool: ${tool}"
                return 0
            fi
        done

        printf "%b\n" "${RED}Can't find a supported escalation tool${RC}"
        log "ERROR: No escalation tool found"
        exit 1
    fi
}

checkCommandRequirements() {
    ## Check for requirements.
    REQUIREMENTS=$1
    for req in ${REQUIREMENTS}; do
        if ! command_exists "${req}"; then
            printf "%b\n" "${RED}Missing required command: ${req}${RC}"
            exit 1
        fi
    done
}

checkPackageManager() {
    ## Check Package Manager
    PACKAGEMANAGER=$1
    for pgm in ${PACKAGEMANAGER}; do
        if command -v "${pgm}" >/dev/null 2>&1; then
            PACKAGER=${pgm}
            printf "%b\n" "${CYAN}Using ${pgm} as package manager${RC}"
            log "Package manager: ${pgm}"
            break
        fi
    done

    ## Enable apk community packages
    if [ "$PACKAGER" = "apk" ] && grep -qE '^#.*community' /etc/apk/repositories 2>/dev/null; then
        $ESCALATION_TOOL sed -i '/community/s/^#//' /etc/apk/repositories
        $ESCALATION_TOOL "$PACKAGER" update
        log "Enabled Alpine community repository"
    fi

    ## Enable apk testing packages
    if [ "$PACKAGER" = "apk" ]; then
        if grep -qE '^#.*testing' /etc/apk/repositories 2>/dev/null; then
            $ESCALATION_TOOL sed -i '/testing/s/^#//' /etc/apk/repositories
            $ESCALATION_TOOL "$PACKAGER" update
            printf "%b\n" "${CYAN}Enabled Alpine testing repository${RC}"
            log "Enabled Alpine testing repository"
        elif ! grep -qE '^[^#].*testing' /etc/apk/repositories 2>/dev/null; then
            local apk_version
            apk_version=$(sed -n 's|^https\?://.*alpine/\([^/]*\)/main.*|\1|p' /etc/apk/repositories 2>/dev/null | head -1)
            if [ -n "$apk_version" ]; then
                echo "https://dl-cdn.alpinelinux.org/alpine/$apk_version/testing" | $ESCALATION_TOOL tee -a /etc/apk/repositories > /dev/null
                $ESCALATION_TOOL "$PACKAGER" update
                printf "%b\n" "${CYAN}Added Alpine testing repository (branch: $apk_version)${RC}"
                log "Added Alpine testing repository (branch: ${apk_version})"
            fi
        fi
    fi

    ## Sync xbps repository indexes
    if [ "$PACKAGER" = "xbps-install" ]; then
        $ESCALATION_TOOL "$PACKAGER" -S
        log "Synced xbps repository indexes"
    fi

    if [ -z "$PACKAGER" ]; then
        printf "%b\n" "${RED}Can't find a supported package manager${RC}"
        log "ERROR: No supported package manager found"
        exit 1
    fi
}

checkAURHelper() {
    case "$PACKAGER" in
        pacman)
            if ! command_exists yay; then
                printf "%b\n" "${YELLOW}Installing yay as AUR helper...${RC}"
                $ESCALATION_TOOL "$PACKAGER" -S --needed --noconfirm base-devel git

                TEMP_BUILD_DIR=$(mktemp -d) || exit 1
                cd "$TEMP_BUILD_DIR" || exit 1
                git clone https://aur.archlinux.org/yay-bin.git || exit 1
                cd yay-bin || exit 1
                makepkg --noconfirm -si || exit 1
                cd "$HOME" || exit 1
                rm -rf "$TEMP_BUILD_DIR"

                printf "%b\n" "${GREEN}Yay installed${RC}"
            else
                printf "%b\n" "${GREEN}Aur helper already installed${RC}"
            fi
            AUR_HELPER="yay"
            ;;
        *)
            AUR_HELPER=""
            ;;
    esac
}

checkSuperUser() {
    ## Check SuperUser Group
    SUPERUSERGROUP='wheel sudo root'
    SUGROUP=""
    for sug in ${SUPERUSERGROUP}; do
        if id -nG "$USER" 2>/dev/null | grep -qw "${sug}"; then
            SUGROUP=${sug}
            printf "%b\n" "${CYAN}Super user group ${SUGROUP}${RC}"
            break
        fi
    done

    if [ -z "$SUGROUP" ] && [ "$(id -u)" != "0" ]; then
        printf "%b\n" "${RED}You need to be a member of the wheel, sudo, or root group to run me!${RC}"
        exit 1
    fi
}

checkCurrentDirectoryWritable() {
    ## Check if the current directory is writable.
    GITPATH="$(dirname "$(realpath "$0")")"
    if [ ! -w "$GITPATH" ]; then
        printf "%b\n" "${RED}Can't write to $GITPATH${RC}"
        exit 1
    fi
}

checkEnv() {
    checkArch
    checkEscalationTool
    checkPackageManager 'pacman xbps-install apk'
    if ! command_exists curl; then
        printf "%b\n" "${YELLOW}Installing curl...${RC}"
        log "Installing curl"
        case "$PACKAGER" in
            pacman) $ESCALATION_TOOL "$PACKAGER" -S --noconfirm curl ;;
            xbps-install) $ESCALATION_TOOL "$PACKAGER" -y curl ;;
            apk) $ESCALATION_TOOL "$PACKAGER" add curl ;;
        esac
        if ! command_exists curl; then
            printf "%b\n" "${RED}Failed to install curl${RC}"
            log "ERROR: Failed to install curl"
            exit 1
        fi
        log "curl installed"
    fi
    checkCommandRequirements "git"
    checkCurrentDirectoryWritable
    checkSuperUser
    checkAURHelper
    log "Environment check complete"
}

setupChaoticAUR() {
    [ "$PACKAGER" != "pacman" ] && return

    # Check if Chaotic AUR is already configured
    if grep -q '^\[chaotic-aur\]' /etc/pacman.conf 2>/dev/null; then
        printf "%b\n" "${GREEN}Chaotic AUR already configured. Skipping.${RC}"
        log "Chaotic AUR already configured"
        return
    fi

    printf "%b\n" "${CYAN}Chaotic AUR provides pre-built binaries for many AUR packages,${RC}"
    printf "%b\n" "${CYAN}saving you from having to build them locally.${RC}"
    printf "%b\n" "${YELLOW}Would you like to enable Chaotic AUR? (y/N): ${RC}"
    read -r choice
    case "$choice" in
        y|Y|yes|YES)
            printf "%b\n" "${YELLOW}Setting up Chaotic AUR...${RC}"
            $ESCALATION_TOOL pacman-key --recv-key 3056513887B78AEB --keyserver keyserver.ubuntu.com
            $ESCALATION_TOOL pacman-key --lsign-key 3056513887B78AEB
            $ESCALATION_TOOL pacman -U --noconfirm 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst'
            $ESCALATION_TOOL pacman -U --noconfirm 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst'
            if ! grep -q '^\[chaotic-aur\]' /etc/pacman.conf; then
                {
                    printf '%s\n' '[chaotic-aur]'
                    printf '%s\n' 'Include = /etc/pacman.d/chaotic-mirrorlist'
                } | $ESCALATION_TOOL tee -a /etc/pacman.conf > /dev/null
            fi
            $ESCALATION_TOOL "$PACKAGER" -Sy
            printf "%b\n" "${GREEN}Chaotic AUR enabled. yay will prefer binary packages.${RC}"
            log "Chaotic AUR enabled"
            ;;
        *)
            printf "%b\n" "${CYAN}Skipping Chaotic AUR setup${RC}"
            ;;
    esac
}

setupLemurs() {
    printf "%b\n" "${YELLOW}Setting up Lemurs Display Manager...${RC}"

    case "$PACKAGER" in
        pacman)
            if $ESCALATION_TOOL "$PACKAGER" -S --needed --noconfirm lemurs 2>/dev/null; then
                $ESCALATION_TOOL systemctl disable display-manager.service 2>/dev/null || true
                $ESCALATION_TOOL systemctl enable lemurs.service 2>/dev/null || true
            else
                printf "%b\n" "${YELLOW}Lemurs not available on this system, skipping...${RC}"
                return
            fi
            ;;
        xbps-install)
            if $ESCALATION_TOOL "$PACKAGER" -y lemurs 2>/dev/null; then
                $ESCALATION_TOOL ln -sf /etc/sv/lemurs /var/service/ 2>/dev/null || true
                $ESCALATION_TOOL rm -f /var/service/agetty-tty2 2>/dev/null || true
            else
                printf "%b\n" "${YELLOW}Lemurs not available on this system, skipping...${RC}"
                return
            fi
            ;;
        apk)
            if $ESCALATION_TOOL "$PACKAGER" add lemurs 2>/dev/null; then
                $ESCALATION_TOOL rc-update add lemurs default 2>/dev/null || true
            else
                printf "%b\n" "${YELLOW}lemurs not available in Alpine repos. Skipping display manager.${RC}"
                printf "%b\n" "${YELLOW}Consider using: $ESCALATION_TOOL rc-service agetty-tty1 start${RC}"
                return
            fi
            ;;
    esac

    # Create session scripts
    $ESCALATION_TOOL mkdir -p /etc/lemurs/wms /etc/lemurs/wayland

    if [ "$SETUP_TYPE" = "dwm" ]; then
        {
            printf '#!/bin/sh\n'
            printf 'exec dbus-launch --exit-with-session dwm\n'
        } | $ESCALATION_TOOL tee /etc/lemurs/wms/dwm > /dev/null
        $ESCALATION_TOOL chmod +x /etc/lemurs/wms/dwm
        printf "%b\n" "${GREEN}DWM session script created at /etc/lemurs/wms/dwm${RC}"
        log "DWM session script created"
    elif [ "$SETUP_TYPE" = "mango" ]; then
        {
            printf '#!/bin/sh\n'
            printf 'exec dbus-launch --exit-with-session mango\n'
        } | $ESCALATION_TOOL tee /etc/lemurs/wayland/mango > /dev/null
        $ESCALATION_TOOL chmod +x /etc/lemurs/wayland/mango
        printf "%b\n" "${GREEN}Mango session script created at /etc/lemurs/wayland/mango${RC}"
    fi

    printf "%b\n" "${GREEN}Lemurs Display Manager installed and enabled${RC}"
}

# Function to display setup menu and get user choice
choose_setup() {
    printf "%b\n" "${CYAN}Please choose your setup:${RC}"
    printf "%b\n" "${GREEN}1) DWM Xorg Setup (Traditional X11 window manager)${RC}"
    printf "%b\n" "${GREEN}2) Mango WM Noctalia Wayland Setup (Modern Wayland compositor)${RC}"
    printf "%b\n" "${YELLOW}Enter your choice (1 or 2): ${RC}"

    while true; do
        read -r choice
        case "$choice" in
            1)
                SETUP_TYPE="dwm"
                printf "%b\n" "${CYAN}Selected: DWM Xorg Setup${RC}"
                break
                ;;
            2)
                SETUP_TYPE="mango"
                printf "%b\n" "${CYAN}Selected: Mango WM Noctalia Wayland Setup${RC}"
                break
                ;;
            *)
                printf "%b\n" "${RED}Invalid choice. Please enter 1 or 2.${RC}"
                printf "%b\n" "${YELLOW}Enter your choice (1 or 2): ${RC}"
                ;;
        esac
    done
}

setupFlatpak() {
    printf "%b\n" "${YELLOW}Setting up Flatpak...${RC}"

    # Check if flatpak is already installed
    if ! command_exists flatpak; then
        case "$PACKAGER" in
            pacman)
                $ESCALATION_TOOL "$PACKAGER" -S --needed --noconfirm flatpak
                printf "%b\n" "${GREEN}Flatpak installed${RC}"
                ;;
            xbps-install)
                $ESCALATION_TOOL "$PACKAGER" -y flatpak
                printf "%b\n" "${GREEN}Flatpak installed${RC}"
                ;;
            apk)
                $ESCALATION_TOOL "$PACKAGER" add flatpak
                printf "%b\n" "${GREEN}Flatpak installed${RC}"
                ;;
        esac
    else
        printf "%b\n" "${GREEN}Flatpak already installed${RC}"
    fi

    # Check if Flathub remote is already added
    if ! flatpak remote-list 2>/dev/null | grep -q flathub; then
        $ESCALATION_TOOL flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
        printf "%b\n" "${GREEN}Flathub repository added${RC}"
        log "Flathub repository added"
    else
        printf "%b\n" "${GREEN}Flathub repository already configured${RC}"
    fi

    printf "%b\n" "${GREEN}Flatpak configured${RC}"
    log "Flatpak configured"
}

installGhostty() {
    printf "%b\n" "${YELLOW}Setting up Ghostty terminal...${RC}"

    # Check if Ghostty is already installed
    if command_exists ghostty; then
        printf "%b\n" "${GREEN}Ghostty already installed${RC}"
        log "Ghostty already installed"
        return
    fi

    if flatpak list 2>/dev/null | grep -q ghostty; then
        printf "%b\n" "${GREEN}Ghostty already installed via Flatpak${RC}"
        log "Ghostty already installed"
        return
    fi

    printf "%b\n" "${YELLOW}Installing Ghostty...${RC}"
    case "$PACKAGER" in
        pacman)
            if [ -n "$AUR_HELPER" ]; then
                if $ESCALATION_TOOL "$AUR_HELPER" -S --needed --noconfirm ghostty 2>/dev/null; then
                    printf "%b\n" "${GREEN}Ghostty installed${RC}"
                    log "Ghostty installed"
                else
                    printf "%b\n" "${YELLOW}Ghostty not in AUR, installing via Flatpak...${RC}"
                    $ESCALATION_TOOL flatpak install -y flathub com.mitchellh.ghostty
                fi
            else
                printf "%b\n" "${YELLOW}Installing Ghostty via Flatpak...${RC}"
                $ESCALATION_TOOL flatpak install -y flathub com.mitchellh.ghostty
            fi
            ;;
        xbps-install)
            printf "%b\n" "${YELLOW}Installing Ghostty via Flatpak...${RC}"
            $ESCALATION_TOOL flatpak install -y flathub com.mitchellh.ghostty
            ;;
        apk)
            printf "%b\n" "${YELLOW}Installing Ghostty via Flatpak...${RC}"
            $ESCALATION_TOOL flatpak install -y flathub com.mitchellh.ghostty
            ;;
    esac
    printf "%b\n" "${GREEN}Ghostty configured${RC}"
    log "Ghostty configured"
}

setupDWM() {
    printf "%b\n" "${YELLOW}Installing dwm-gossamer...${RC}"
    log "Setting up DWM dependencies"
    case "$PACKAGER" in
        pacman)
            $ESCALATION_TOOL "$PACKAGER" -S --needed --noconfirm \
              base-devel git linux-headers unzip curl wget \
              xorg-server xorg-xinit xorg-xrandr xorg-xsetroot xorg-xprop xorg-xset xorg-xhost xf86-input-libinput \
              libx11 libxinerama libxft libxcb imlib2 fontconfig freetype2 \
              polybar picom dunst rofi dmenu slock alacritty xdo xdotool \
              feh flameshot imagemagick ffmpeg playerctl \
              btop htop arandr xclip xsel xarchiver thunar tumbler gvfs thunar-archive-plugin \
              tldr dex nwg-look xscreensaver brightnessctl acpi \
              xdg-user-dirs xdg-desktop-portal-gtk xdg-utils \
              firefox mate-polkit alsa-utils pavucontrol pipewire gnome-keyring \
              networkmanager network-manager-applet openssh nvim \
              fzf bat fd eza ripgrep \
              ttf-liberation ttf-dejavu noto-fonts noto-fonts-emoji terminus-font \
              fastfetch starship zoxide keychain man-db \
              dbus xauth topgrade
            ;;
        xbps-install)
            $ESCALATION_TOOL "$PACKAGER" -y \
              base-devel make gcc git linux-headers unzip curl wget \
              xorg-server xinit xrandr xsetroot xprop xset xhost xf86-input-libinput \
              libX11 libX11-devel libXinerama libXinerama-devel libXft libXft-devel \
              libxcb libxcb-devel imlib2 imlib2-devel fontconfig fontconfig-devel \
              freetype freetype-devel \
              polybar picom dunst rofi dmenu slock alacritty xdo xdotool \
              feh flameshot imagemagick ffmpeg playerctl \
              btop htop arandr xclip xsel xarchiver thunar tumbler gvfs thunar-archive-plugin \
              tldr dex nwg-look xscreensaver brightnessctl acpi \
              xdg-user-dirs xdg-desktop-portal-gtk xdg-utils \
              firefox polkit xfce-polkit alsa-utils pavucontrol pipewire gnome-keyring \
              NetworkManager network-manager-applet openssh neovim \
              fzf bat fd eza ripgrep \
              ttf-liberation ttf-dejavu noto-fonts noto-fonts-emoji terminus-font \
              fastfetch starship zoxide keychain man-db \
              dbus xauth topgrade
            ;;
        apk)
            $ESCALATION_TOOL "$PACKAGER" add \
              build-base make gcc git linux-headers unzip curl wget \
              xorg-server xinit xrandr xsetroot xprop xset xhost xf86-input-libinput \
              libX11 libXinerama libXft libxcb imlib2 fontconfig freetype \
              polybar picom dunst rofi dmenu slock alacritty xdo xdotool \
              feh flameshot imagemagick ffmpeg playerctl \
              btop htop arandr xclip xsel xarchiver thunar tumbler gvfs thunar-archive-plugin \
              tldr dex nwg-look xscreensaver brightnessctl acpi \
              xdg-user-dirs xdg-desktop-portal-gtk xdg-utils \
              firefox polkit alsa-utils pavucontrol pipewire gnome-keyring \
              networkmanager network-manager-applet openssh neovim \
              fzf bat fd eza ripgrep \
              ttf-liberation ttf-dejavu noto-fonts noto-fonts-emoji terminus-font \
              fastfetch starship zoxide keychain man-db \
              dbus xauth topgrade
            ;;
        *)
            printf "%b\n" "${RED}Unsupported package manager: $PACKAGER${RC}"
            exit 1
            ;;
    esac
}

makeDWM() {
    log "Building DWM"
    mkdir -p "$HOME/.local/share" || exit 1

    if [ ! -d "$HOME/.local/share/dwm-gossamer" ]; then
        printf "%b\n" "${YELLOW}dwm-gossamer not found, cloning repository...${RC}"
        cd "$HOME/.local/share" || exit 1
        git clone https://github.com/Daniel1788/dwm-gossamer.git || exit 1
        log "Cloned dwm-gossamer repository"
        cd dwm-gossamer || exit 1
    else
        printf "%b\n" "${GREEN}dwm-gossamer directory already exists, updating...${RC}"
        cd "$HOME/.local/share/dwm-gossamer" || exit 1
        git pull || exit 1
        log "Updated dwm-gossamer repository"
    fi

    $ESCALATION_TOOL make clean install || exit 1
    log "DWM built and installed"

    cd "$HOME/.local/share/dwm-gossamer/slstatus" || exit 1
    $ESCALATION_TOOL make clean install || exit 1
    log "slstatus built and installed"

    cd "$HOME/.local/share/dwm-gossamer" || exit 1
    mkdir -p "$HOME/Pictures/backgrounds/" || exit 1
    backup_config "$HOME/Pictures/backgrounds/background.jpg"
    cp background.jpg "$HOME/Pictures/backgrounds/"
    log "DWM background copied"

    # Setup .xinitrc for startx
    if [ ! -f "$HOME/.xinitrc" ]; then
        {
            printf '#!/bin/sh\n'
            printf 'exec dbus-launch --exit-with-session dwm\n'
        } > "$HOME/.xinitrc"
        chmod +x "$HOME/.xinitrc"
        printf "%b\n" "${GREEN}.xinitrc created for DWM${RC}"
        log ".xinitrc created"
    fi
}

install_nerd_font() {
    FONT_NAME="MesloLGS Nerd Font Mono"
    FONT_DIR="$HOME/.local/share/fonts"
    FONT_URL="https://github.com/ryanoasis/nerd-fonts/releases/latest/download/Meslo.zip"

    # Check if Meslo fonts are already installed
    if command_exists fc-list && fc-list 2>/dev/null | grep -qi "Meslo"; then
        printf "%b\n" "${GREEN}Meslo Nerd-fonts already installed. Skipping.${RC}"
        log "Meslo fonts already installed"
        return 0
    fi

    printf "%b\n" "${YELLOW}Installing Meslo Nerd-fonts...${RC}"

    # Check if unzip is installed
    if ! command_exists unzip; then
        printf "%b\n" "${YELLOW}Installing unzip...${RC}"
        case "$PACKAGER" in
            pacman) $ESCALATION_TOOL "$PACKAGER" -S --needed --noconfirm unzip ;;
            xbps-install) $ESCALATION_TOOL "$PACKAGER" -y unzip ;;
            apk) $ESCALATION_TOOL "$PACKAGER" add unzip ;;
        esac
        if ! command_exists unzip; then
            printf "%b\n" "${RED}Failed to install unzip${RC}"
            return 1
        fi
    fi

    mkdir -p "$FONT_DIR" || return 1

    TEMP_DIR=$(mktemp -d) || return 1
    curl -sSLo "$TEMP_DIR/Meslo.zip" "$FONT_URL" || { rm -rf "$TEMP_DIR"; return 1; }
    unzip -q "$TEMP_DIR/Meslo.zip" -d "$TEMP_DIR" || { rm -rf "$TEMP_DIR"; return 1; }
    mkdir -p "$FONT_DIR/$FONT_NAME"
    mv "$TEMP_DIR"/*.ttf "$FONT_DIR/$FONT_NAME/" 2>/dev/null || true
    fc-cache -fv
    rm -rf "$TEMP_DIR"
    printf "%b\n" "${GREEN}Meslo Nerd-fonts installed successfully.${RC}"
    log "Meslo fonts installed"
}

clone_config_folders() {
    [ ! -d ~/.config ] && mkdir -p ~/.config
    [ ! -d ~/.local/bin ] && mkdir -p ~/.local/bin

    REPO_DIR="$HOME/.local/share/dwm-gossamer"

    [ ! -d "$REPO_DIR/scripts" ] || cp -rf "$REPO_DIR/scripts/." "$HOME/.local/bin/"

    FONT_DIR="$HOME/.local/share/fonts"
    mkdir -p "$FONT_DIR"
    if [ -d "$REPO_DIR/polybar/fonts" ]; then
        cp -r "$REPO_DIR/polybar/fonts/"* "$FONT_DIR/"
        fc-cache -fv
        printf "%b\n" "${GREEN}Polybar icon fonts installed${RC}"
    fi

    if [ -d "$REPO_DIR/config" ]; then
        for dir in "$REPO_DIR/config/"*/; do
            dir_name=$(basename "$dir")
            backup_config "$HOME/.config/$dir_name"
            cp -r "$dir" ~/.config/
            printf "%b\n" "${GREEN}Cloned $dir_name to ~/.config/${RC}"
        done
    else
        printf "%b\n" "${RED}Config directory not found in repository${RC}"
    fi

    # Make scripts executable
    if [ -d "$HOME/.local/bin" ]; then
        chmod +x "$HOME/.local/bin"/* 2>/dev/null || true
        printf "%b\n" "${GREEN}Scripts made executable${RC}"
    fi
}

setupMango() {
    printf "%b\n" "${YELLOW}Installing Mango WM Noctalia Wayland setup...${RC}"
    log "Setting up Mango WM"
    case "$PACKAGER" in
        pacman)
            if [ -n "$AUR_HELPER" ]; then
                $ESCALATION_TOOL "$AUR_HELPER" -S --needed --noconfirm mangowm-git
            fi

            $ESCALATION_TOOL "$PACKAGER" -S --needed --noconfirm \
              foot rofi waybar swaybg wl-clip-persist cliphist wl-clipboard \
              wlsunset xfce-polkit swaync pamixer brightnessctl grim slurp satty \
              qt6-wayland xdg-desktop-portal-wlr \
              firefox btop htop fzf bat fd eza ripgrep \
              fastfetch starship zoxide keychain man-db \
              dbus xauth libxdg-basedir pipewire-pulse wireplumber topgrade
            ;;
        xbps-install)
            $ESCALATION_TOOL "$PACKAGER" -y \
              base-devel git meson ninja pkg-config cmake \
              wayland-devel wayland-protocols libinput-devel libdrm-devel \
              libxkbcommon-devel pixman-devel seatd-devel pcre2-devel \
              libdisplay-info-devel libliftoff-devel hwdata \
              xorg-server-xwayland libxcb-devel mesa-dri mesa-devel

            # Build wlroots 0.19.x
            printf "%b\n" "${YELLOW}Building wlroots...${RC}"
            log "Building wlroots 0.19.x"
            TEMP_BUILD_DIR=$(mktemp -d) || exit 1
            cd "$TEMP_BUILD_DIR" || exit 1
            git clone -b 0.19.2 https://gitlab.freedesktop.org/wlroots/wlroots.git || exit 1
            cd wlroots || exit 1
            meson build -Dprefix=/usr || exit 1
            $ESCALATION_TOOL ninja -C build install || exit 1
            cd "$HOME" || exit 1
            rm -rf "$TEMP_BUILD_DIR"
            log "wlroots built and installed"

            # Build scenefx
            printf "%b\n" "${YELLOW}Building scenefx...${RC}"
            log "Building scenefx"
            TEMP_BUILD_DIR=$(mktemp -d) || exit 1
            cd "$TEMP_BUILD_DIR" || exit 1
            git clone -b 0.4.1 https://github.com/wlrfx/scenefx.git || exit 1
            cd scenefx || exit 1
            meson build -Dprefix=/usr || exit 1
            $ESCALATION_TOOL ninja -C build install || exit 1
            cd "$HOME" || exit 1
            rm -rf "$TEMP_BUILD_DIR"
            log "scenefx built and installed"

            # Build mangowm
            printf "%b\n" "${YELLOW}Building mangowm...${RC}"
            log "Building mangowm"
            TEMP_BUILD_DIR=$(mktemp -d) || exit 1
            cd "$TEMP_BUILD_DIR" || exit 1
            git clone https://github.com/mangowm/mango.git || exit 1
            cd mango || exit 1
            meson build -Dprefix=/usr || exit 1
            $ESCALATION_TOOL ninja -C build install || exit 1
            cd "$HOME" || exit 1
            rm -rf "$TEMP_BUILD_DIR"
            log "mangowm built and installed"

            $ESCALATION_TOOL "$PACKAGER" -y \
              foot rofi waybar swaybg wl-clip-persist wl-clipboard cliphist \
              wlsunset pamixer brightnessctl grim slurp \
              qt6-wayland xdg-desktop-portal-wlr \
              firefox btop htop fzf bat fd eza ripgrep \
              fastfetch starship zoxide keychain man-db \
              dbus xauth libxdg-basedir pipewire-pulse wireplumber topgrade
            log "Wayland utilities installed"
            ;;
        apk)
            $ESCALATION_TOOL "$PACKAGER" add \
              build-base git meson ninja pkg-config cmake \
              wayland-dev wayland-protocols libinput-dev libdrm-dev \
              libxkbcommon-dev pixman-dev seatd-dev pcre2-dev \
              libdisplay-info-dev libliftoff-dev hwdata \
              xorg-server-xwayland libxcb-dev mesa-dri mesa-dev

            # Build wlroots 0.19.x
            printf "%b\n" "${YELLOW}Building wlroots...${RC}"
            log "Building wlroots 0.19.x"
            TEMP_BUILD_DIR=$(mktemp -d) || exit 1
            cd "$TEMP_BUILD_DIR" || exit 1
            git clone -b 0.19.2 https://gitlab.freedesktop.org/wlroots/wlroots.git || exit 1
            cd wlroots || exit 1
            meson build -Dprefix=/usr || exit 1
            $ESCALATION_TOOL ninja -C build install || exit 1
            cd "$HOME" || exit 1
            rm -rf "$TEMP_BUILD_DIR"
            log "wlroots built and installed"

            # Build scenefx
            printf "%b\n" "${YELLOW}Building scenefx...${RC}"
            log "Building scenefx"
            TEMP_BUILD_DIR=$(mktemp -d) || exit 1
            cd "$TEMP_BUILD_DIR" || exit 1
            git clone -b 0.4.1 https://github.com/wlrfx/scenefx.git || exit 1
            cd scenefx || exit 1
            meson build -Dprefix=/usr || exit 1
            $ESCALATION_TOOL ninja -C build install || exit 1
            cd "$HOME" || exit 1
            rm -rf "$TEMP_BUILD_DIR"
            log "scenefx built and installed"

            # Build mangowm
            printf "%b\n" "${YELLOW}Building mangowm...${RC}"
            log "Building mangowm"
            TEMP_BUILD_DIR=$(mktemp -d) || exit 1
            cd "$TEMP_BUILD_DIR" || exit 1
            git clone https://github.com/mangowm/mango.git || exit 1
            cd mango || exit 1
            meson build -Dprefix=/usr || exit 1
            $ESCALATION_TOOL ninja -C build install || exit 1
            cd "$HOME" || exit 1
            rm -rf "$TEMP_BUILD_DIR"
            log "mangowm built and installed"

            $ESCALATION_TOOL "$PACKAGER" add \
              foot rofi waybar swaybg wl-clip-persist wl-clipboard \
              wlsunset pamixer brightnessctl grim slurp \
              qt6-wayland \
              firefox btop htop fzf bat fd eza ripgrep \
              fastfetch starship zoxide keychain man-db \
              dbus xauth libxdg-basedir pipewire-pulse wireplumber topgrade
            ;;
    esac
}

makeMango() {
    printf "%b\n" "${YELLOW}Configuring Mango WM...${RC}"

    mkdir -p ~/.config/mango

    if [ ! -f ~/.config/mango/config.conf ]; then
        if [ -f /etc/mango/config.conf ]; then
            cp /etc/mango/config.conf ~/.config/mango/config.conf
            printf "%b\n" "${GREEN}Copied default Mango config${RC}"
        else
            # Create minimal Mango config
            {
                printf 'general {\n'
                printf '  gaps_in = 5\n'
                printf '  gaps_out = 5\n'
                printf '}\n'
            } > ~/.config/mango/config.conf
            printf "%b\n" "${GREEN}Created default Mango config${RC}"
        fi
    fi

    if ! grep -qs 'noctalia-shell' ~/.config/mango/config.conf 2>/dev/null; then
        {
            printf '\n# Autostart Noctalia Shell\n'
            printf 'exec-once=qs -d -c noctalia-shell\n'
        } >> ~/.config/mango/config.conf
        printf "%b\n" "${GREEN}Noctalia Shell configured to autostart with Mango${RC}"
    fi

    # Setup .bashrc for wayland session
    if [ -f ~/.bashrc ]; then
        if ! grep -q 'export WAYLAND_DISPLAY' ~/.bashrc; then
            {
                printf '\n# Wayland settings\n'
                printf 'export WAYLAND_DISPLAY=wayland-1\n'
            } >> ~/.bashrc
        fi
    fi
}

setupNoctalia() {
    printf "%b\n" "${YELLOW}Installing Noctalia Shell...${RC}"
    log "Setting up Noctalia Shell"
    case "$PACKAGER" in
        pacman)
            if [ -n "$AUR_HELPER" ]; then
                $ESCALATION_TOOL "$AUR_HELPER" -S --needed --noconfirm noctalia-shell
            fi
            log "Noctalia Shell installed from AUR"

            $ESCALATION_TOOL "$PACKAGER" -S --needed --noconfirm \
              brightnessctl imagemagick python git \
              cliphist wlsunset xdg-desktop-portal
            log "Noctalia dependencies installed"
            ;;
        xbps-install)
            $ESCALATION_TOOL "$PACKAGER" -y \
              brightnessctl imagemagick python3 git cmake ninja \
              qt6-base qt6-base-devel qt6-declarative qt6-declarative-devel \
              qt6-svg qt6-svg-devel qt6-wayland qt6-wayland-devel \
              polkit glib glib-devel xdg-desktop-portal
            log "Noctalia dependencies installed"

            printf "%b\n" "${YELLOW}Building noctalia-qs...${RC}"
            log "Building noctalia-qs"
            TEMP_BUILD_DIR=$(mktemp -d) || exit 1
            cd "$TEMP_BUILD_DIR" || exit 1
            git clone https://github.com/noctalia-dev/noctalia-qs.git || exit 1
            cd noctalia-qs || exit 1
            cmake -GNinja -B build -DCMAKE_BUILD_TYPE=Release \
              -DCMAKE_INSTALL_PREFIX=/usr || exit 1
            ninja -C build || exit 1
            $ESCALATION_TOOL ninja -C build install || exit 1
            cd "$HOME" || exit 1
            rm -rf "$TEMP_BUILD_DIR"
            log "noctalia-qs built and installed"

            mkdir -p ~/.config/quickshell/noctalia-shell
            curl -sL https://github.com/noctalia-dev/noctalia-shell/releases/latest/download/noctalia-latest.tar.gz \
              | tar -xz --strip-components=1 -C ~/.config/quickshell/noctalia-shell 2>/dev/null || true
            log "Noctalia Shell config installed"
            ;;
        apk)
            $ESCALATION_TOOL "$PACKAGER" add \
              brightnessctl imagemagick python3 git cmake ninja \
              qt6-base qt6-base-dev qt6-declarative qt6-declarative-dev \
              qt6-svg qt6-svg-dev qt6-wayland qt6-wayland-dev \
              polkit glib glib-dev xdg-desktop-portal
            log "Noctalia dependencies installed"

            printf "%b\n" "${YELLOW}Building noctalia-qs...${RC}"
            log "Building noctalia-qs"
            TEMP_BUILD_DIR=$(mktemp -d) || exit 1
            cd "$TEMP_BUILD_DIR" || exit 1
            git clone https://github.com/noctalia-dev/noctalia-qs.git || exit 1
            cd noctalia-qs || exit 1
            cmake -GNinja -B build -DCMAKE_BUILD_TYPE=Release \
              -DCMAKE_INSTALL_PREFIX=/usr || exit 1
            ninja -C build || exit 1
            $ESCALATION_TOOL ninja -C build install || exit 1
            cd "$HOME" || exit 1
            rm -rf "$TEMP_BUILD_DIR"
            log "noctalia-qs built and installed"

            mkdir -p ~/.config/quickshell/noctalia-shell
            curl -sL https://github.com/noctalia-dev/noctalia-shell/releases/latest/download/noctalia-latest.tar.gz \
              | tar -xz --strip-components=1 -C ~/.config/quickshell/noctalia-shell 2>/dev/null || true
            log "Noctalia Shell config installed"
            ;;
    esac
}

cloneMangoConfig() {
    [ ! -d ~/.config ] && mkdir -p ~/.config
    [ ! -d ~/.local/bin ] && mkdir -p ~/.local/bin

    MANGO_DIR="$HOME/.local/share/mango-config"
    if [ -d "$MANGO_DIR" ]; then
        if [ -d "$MANGO_DIR/config" ]; then
            backup_config "$HOME/.config/mango"
            cp -rf "$MANGO_DIR/config/." ~/.config/mango/
            printf "%b\n" "${GREEN}Mango config cloned to ~/.config/mango/${RC}"
        fi
        if [ -d "$MANGO_DIR/scripts" ]; then
            cp -rf "$MANGO_DIR/scripts/." ~/.local/bin/
            printf "%b\n" "${GREEN}Mango scripts cloned to ~/.local/bin/${RC}"
        fi
    fi
}

print_summary() {
    printf "%b\n" ""
    printf "%b\n" "${GREEN}========================================${RC}"
    printf "%b\n" "${GREEN}  Installation Complete!${RC}"
    printf "%b\n" "${GREEN}========================================${RC}"
    printf "%b\n" ""
    if [ "$SETUP_TYPE" = "dwm" ]; then
        printf "%b\n" "${CYAN}DWM Xorg Setup installed:${RC}"
        printf "%b\n" "  - Xorg, DWM, Polybar, Picom, Dunst, Rofi, Alacritty"
        printf "%b\n" "  - Nerd Fonts + configuration files"
        printf "%b\n" ""
        printf "%b\n" "${YELLOW}Next steps:${RC}"
        printf "%b\n" "  1. ${CYAN}Reboot${RC} or run: ${GREEN}startx${RC}"
        printf "%b\n" "  2. Select ${GREEN}DWM${RC} from Lemurs login screen"
        printf "%b\n" "  3. Use ${GREEN}Mod+Shift+Enter${RC} to open a terminal"
    elif [ "$SETUP_TYPE" = "mango" ]; then
        printf "%b\n" "${CYAN}Mango WM Noctalia Wayland Setup installed:${RC}"
        printf "%b\n" "  - Mango WM (Wayland compositor)"
        printf "%b\n" "  - Noctalia Shell (desktop shell)"
        printf "%b\n" "  - Wayland utilities (foot, waybar, swaybg, etc.)"
        printf "%b\n" "  - Nerd Fonts"
        printf "%b\n" ""
        printf "%b\n" "${YELLOW}Next steps:${RC}"
        printf "%b\n" "  1. ${CYAN}Reboot${RC} or run: ${GREEN}mango${RC}"
        printf "%b\n" "  2. Select ${GREEN}Mango${RC} from Lemurs login screen"
        printf "%b\n" "  3. Noctalia auto-starts with Mango (exec-once in config)"
    fi
    printf "%b\n" ""
    printf "%b\n" "${YELLOW}Shared components:${RC}"
    printf "%b\n" "  - Flatpak + Flathub configured"
    printf "%b\n" "  - Ghostty terminal installed"
    printf "%b\n" "  - Lemurs Display Manager"
    printf "%b\n" ""
    printf "%b\n" "${YELLOW}Config backups saved as: ~/.config/*.backup.<timestamp>${RC}"
    printf "%b\n" "${YELLOW}Flatpak apps: flatpak install flathub <app>${RC}"
    printf "%b\n" ""
}

setup_logging

log "Starting installer"
log "Setup type: ${SETUP_TYPE:-not selected yet}"

checkEnv
log "Environment checks passed"
choose_setup
log "User selected setup type: ${SETUP_TYPE}"
setupChaoticAUR
setupLemurs
log "Lemurs display manager configured"

if [ "$SETUP_TYPE" = "dwm" ]; then
    log "Starting DWM setup"
    setupFlatpak
    installGhostty
    setupDWM
    makeDWM
    install_nerd_font
    clone_config_folders
    log "DWM setup complete"
elif [ "$SETUP_TYPE" = "mango" ]; then
    log "Starting Mango WM setup"
    setupFlatpak
    installGhostty
    setupMango
    makeMango
    setupNoctalia
    install_nerd_font
    cloneMangoConfig
    log "Mango WM setup complete"
else
    printf "%b\n" "${RED}Error: No setup type selected${RC}"
    log "ERROR: No setup type selected"
    exit 1
fi

# Verify all bashrc dependencies are installed
printf "%b\n" "${YELLOW}Verifying bashrc dependencies...${RC}"
MISSING_DEPS=""
for dep in fzf bat fd eza starship zoxide keychain git curl nvim fastfetch topgrade; do
    if ! command_exists "$dep"; then
        MISSING_DEPS="$MISSING_DEPS $dep"
    fi
done

if [ -n "$MISSING_DEPS" ]; then
    printf "%b\n" "${RED}Warning: Missing bashrc dependencies:$MISSING_DEPS${RC}"
    printf "%b\n" "${YELLOW}Installing missing dependencies...${RC}"
    case "$PACKAGER" in
        pacman)
            $ESCALATION_TOOL "$PACKAGER" -S --needed --noconfirm $MISSING_DEPS
            ;;
        xbps-install)
            $ESCALATION_TOOL "$PACKAGER" -y $MISSING_DEPS
            ;;
        apk)
            $ESCALATION_TOOL "$PACKAGER" add $MISSING_DEPS
            ;;
    esac
else
    printf "%b\n" "${GREEN}All bashrc dependencies verified ✓${RC}"
    log "All bashrc dependencies verified"
fi

# Setup shell configuration with bashrc from repo if available
if [ -f .bashrc ]; then
    # Copy bashrc from repo (it has bash-specific syntax)
    backup_config "$HOME/.bashrc"

    # For non-bash shells, create a compatible version
    if [ -z "$BASH_VERSION" ]; then
        printf "%b\n" "${CYAN}Creating POSIX-compatible bashrc...${RC}"
        {
            printf '# Shell configuration - POSIX compatible\n'
            printf '[ -z "$BASH_VERSION" ] && [ -n "$ZSH_VERSION" ] && emulate sh\n'
            printf 'export PATH="$HOME/.local/bin:$PATH"\n'
            printf 'export XDG_DATA_HOME="$HOME/.local/share"\n'
            printf 'export XDG_CONFIG_HOME="$HOME/.config"\n'
            printf 'export EDITOR=nvim\n'
            printf 'alias ls="ls --color=auto"\n'
            printf 'alias ll="ls -lh"\n'
            printf '[ -z "$BASH_VERSION" ] || eval "$(fzf --bash)" 2>/dev/null\n'
            printf '[ -z "$BASH_VERSION" ] || eval "$(starship init bash)" 2>/dev/null\n'
            printf '[ -z "$BASH_VERSION" ] || eval "$(zoxide init bash)" 2>/dev/null\n'
        } > ~/.bashrc
        printf "%b\n" "${CYAN}Created POSIX-compatible ~/.bashrc${RC}"
    else
        # Copy full bashrc for bash shell
        cp .bashrc ~/.bashrc
        printf "%b\n" "${CYAN}Copied full-featured ~/.bashrc from repository${RC}"
    fi
    log "Setup ~/.bashrc from repository"
else
    # Create minimal bashrc if repo version not available
    if [ ! -f ~/.bashrc ]; then
        {
            printf '# Shell configuration\n'
            printf 'export PATH="$HOME/.local/bin:$PATH"\n'
            printf 'export XDG_DATA_HOME="$HOME/.local/share"\n'
            printf 'export XDG_CONFIG_HOME="$HOME/.config"\n'
            printf 'export EDITOR=nvim\n'
            printf 'alias ls="ls --color=auto"\n'
            printf 'alias ll="ls -lh"\n'
            printf '[ -z "$BASH_VERSION" ] || eval "$(fzf --bash)" 2>/dev/null\n'
            printf '[ -z "$BASH_VERSION" ] || eval "$(starship init bash)" 2>/dev/null\n'
            printf '[ -z "$BASH_VERSION" ] || eval "$(zoxide init bash)" 2>/dev/null\n'
        } > ~/.bashrc
        printf "%b\n" "${CYAN}Created ~/.bashrc with essential configuration${RC}"
        log "Created ~/.bashrc"
    fi
fi

if [ ! -f ~/.profile ]; then
    {
        printf '# ~/.profile - login shell configuration\n'
        printf 'export PATH="$HOME/.local/bin:$PATH"\n'
        printf '[ -f ~/.bashrc ] && . ~/.bashrc\n'
    } > ~/.profile
    printf "%b\n" "${CYAN}Created ~/.profile for login shells${RC}"
    log "Created ~/.profile"
fi

print_summary
log "Installer finished"
