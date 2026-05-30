#!/usr/bin/env bash

RC='\033[0m'
RED='\033[31m'
YELLOW='\033[33m'
CYAN='\033[36m'
GREEN='\033[32m'

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
        *) printf "%b\n" "${RED}Unsupported architecture: $(uname -m)${RC}" && exit 1 ;;
    esac

    printf "%b\n" "${CYAN}System architecture: ${ARCH}${RC}"
}

checkEscalationTool() {
    ## Check for escalation tools.
    if [ -z "$ESCALATION_TOOL_CHECKED" ]; then
        if [ "$(id -u)" = "0" ]; then
            ESCALATION_TOOL="eval"
            ESCALATION_TOOL_CHECKED=true
            printf "%b\n" "${CYAN}Running as root, no escalation needed${RC}"
            return 0
        fi

        ESCALATION_TOOLS='sudo doas'
        for tool in ${ESCALATION_TOOLS}; do
            if command_exists "${tool}"; then
                ESCALATION_TOOL=${tool}
                printf "%b\n" "${CYAN}Using ${tool} for privilege escalation${RC}"
                ESCALATION_TOOL_CHECKED=true
                return 0
            fi
        done

        printf "%b\n" "${RED}Can't find a supported escalation tool${RC}"
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
            break
        fi
    done

    ## Enable apk community packages
    if [ "$PACKAGER" = "apk" ] && grep -qE '^#.*community' /etc/apk/repositories; then
        "$ESCALATION_TOOL" sed -i '/community/s/^#//' /etc/apk/repositories
        "$ESCALATION_TOOL" "$PACKAGER" update
    fi

    ## Enable apk testing packages
    if [ "$PACKAGER" = "apk" ]; then
        if grep -qE '^#.*testing' /etc/apk/repositories; then
            "$ESCALATION_TOOL" sed -i '/testing/s/^#//' /etc/apk/repositories
            "$ESCALATION_TOOL" "$PACKAGER" update
            printf "%b\n" "${CYAN}Enabled Alpine testing repository${RC}"
        elif ! grep -qE '^[^#].*testing' /etc/apk/repositories; then
            local apk_version
            apk_version=$(sed -n 's|^https\?://.*alpine/\([^/]*\)/main.*|\1|p' /etc/apk/repositories | head -1)
            if [ -n "$apk_version" ]; then
                "$ESCALATION_TOOL" tee -a /etc/apk/repositories > /dev/null <<< "https://dl-cdn.alpinelinux.org/alpine/$apk_version/testing"
                "$ESCALATION_TOOL" "$PACKAGER" update
                printf "%b\n" "${CYAN}Added Alpine testing repository (branch: $apk_version)${RC}"
            fi
        fi
    fi

    ## Sync xbps repository indexes
    if [ "$PACKAGER" = "xbps-install" ]; then
        "$ESCALATION_TOOL" "$PACKAGER" -S
    fi

    if [ -z "$PACKAGER" ]; then
        printf "%b\n" "${RED}Can't find a supported package manager${RC}"
        exit 1
    fi
}

checkAURHelper() {
    if [ "$PACKAGER" = "pacman" ]; then
        if command_exists paru && paru --version >/dev/null 2>&1; then
            AUR_HELPER="paru"
        else
            if command_exists paru; then
                printf "%b\n" "${YELLOW}Existing paru is broken (likely a libalpm soname mismatch after pacman update). Reinstalling...${RC}"
            else
                printf "%b\n" "${YELLOW}No AUR helper found. Installing paru...${RC}"
            fi

            "$ESCALATION_TOOL" "$PACKAGER" -S --needed --noconfirm base-devel git
            local install_dir="/tmp/paru-bin"
            rm -rf "$install_dir"
            "$ESCALATION_TOOL" git clone https://aur.archlinux.org/paru-bin.git "$install_dir" && "$ESCALATION_TOOL" chown -R "$USER": "$install_dir"
            cd "$install_dir" && makepkg --noconfirm -si || exit 1
            cd /tmp
            AUR_HELPER="paru"
            printf "%b\n" "${GREEN}Paru installed${RC}"
        fi
        printf "%b\n" "${CYAN}Using ${AUR_HELPER} for AUR packages${RC}"
    fi
}

checkSuperUser() {
    ## Check SuperUser Group
    SUPERUSERGROUP='wheel sudo root'
    SUGROUP=""
    for sug in ${SUPERUSERGROUP}; do
        if id -nG | grep -qw "${sug}"; then
            SUGROUP=${sug}
            printf "%b\n" "${CYAN}Super user group ${SUGROUP}${RC}"
            break
        fi
    done

    if [ -z "$SUGROUP" ]; then
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
    checkPackageManager 'apk xbps-install pacman'
    if ! command_exists curl; then
        printf "%b\n" "${YELLOW}Installing curl...${RC}"
        case "$PACKAGER" in
            pacman) "$ESCALATION_TOOL" "$PACKAGER" -S --noconfirm curl ;;
            xbps-install) "$ESCALATION_TOOL" "$PACKAGER" -y curl ;;
            apk) "$ESCALATION_TOOL" "$PACKAGER" add curl ;;
        esac
        if ! command_exists curl; then
            printf "%b\n" "${RED}Failed to install curl${RC}"
            exit 1
        fi
    fi
    checkCommandRequirements "groups $ESCALATION_TOOL"
    checkCurrentDirectoryWritable
    checkSuperUser
    checkAURHelper
}

setupChaoticAUR() {
    [ "$PACKAGER" != "pacman" ] && return
    printf "%b\n" "${CYAN}Chaotic AUR provides pre-built binaries for many AUR packages,${RC}"
    printf "%b\n" "${CYAN}saving you from having to build them locally.${RC}"
    printf "%b\n" "${YELLOW}Would you like to enable Chaotic AUR? (y/N): ${RC}"
    read -r choice
    case "$choice" in
        y|Y|yes|YES)
            printf "%b\n" "${YELLOW}Setting up Chaotic AUR...${RC}"
            "$ESCALATION_TOOL" pacman-key --recv-key 3056513887B78AEB --keyserver keyserver.ubuntu.com
            "$ESCALATION_TOOL" pacman-key --lsign-key 3056513887B78AEB
            "$ESCALATION_TOOL" pacman -U --noconfirm 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst'
            "$ESCALATION_TOOL" pacman -U --noconfirm 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst'
            if ! grep -q '^\[chaotic-aur\]' /etc/pacman.conf; then
                {
                    printf '%s\n' '[chaotic-aur]'
                    printf '%s\n' 'Include = /etc/pacman.d/chaotic-mirrorlist'
                } | "$ESCALATION_TOOL" tee -a /etc/pacman.conf > /dev/null
            fi
            "$ESCALATION_TOOL" "$PACKAGER" -Sy
            printf "%b\n" "${GREEN}Chaotic AUR enabled. paru will prefer binary packages.${RC}"
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
            "$ESCALATION_TOOL" "$PACKAGER" -S --needed --noconfirm lemurs
            "$ESCALATION_TOOL" systemctl disable display-manager.service 2>/dev/null || true
            "$ESCALATION_TOOL" systemctl enable lemurs.service
            ;;
        xbps-install)
            "$ESCALATION_TOOL" "$PACKAGER" -y lemurs
            "$ESCALATION_TOOL" ln -sf /etc/sv/lemurs /var/service/
            "$ESCALATION_TOOL" rm -f /var/service/agetty-tty2
            ;;
        apk)
            if "$ESCALATION_TOOL" "$PACKAGER" add lemurs; then
                "$ESCALATION_TOOL" rc-update add lemurs default
            else
                printf "%b\n" "${YELLOW}lemurs not available in Alpine repos. Skipping display manager.${RC}"
                return
            fi
            ;;
    esac

    # Create session scripts
    "$ESCALATION_TOOL" mkdir -p /etc/lemurs/wms /etc/lemurs/wayland

    if [ "$SETUP_TYPE" = "dwm" ]; then
        "$ESCALATION_TOOL" tee /etc/lemurs/wms/dwm > /dev/null <<'EOF'
#!/bin/sh
exec dbus-launch --exit-with-session dwm
EOF
        "$ESCALATION_TOOL" chmod +x /etc/lemurs/wms/dwm
        printf "%b\n" "${GREEN}DWM session script created at /etc/lemurs/wms/dwm${RC}"
    elif [ "$SETUP_TYPE" = "mango" ]; then
        "$ESCALATION_TOOL" tee /etc/lemurs/wayland/mango > /dev/null <<'EOF'
#!/bin/sh
exec dbus-launch --exit-with-session mango
EOF
        "$ESCALATION_TOOL" chmod +x /etc/lemurs/wayland/mango
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
    case "$PACKAGER" in
        pacman)
            # Install Flatpak
            "$ESCALATION_TOOL" "$PACKAGER" -S --needed --noconfirm flatpak

            # Add Flathub repository
            "$ESCALATION_TOOL" flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
            ;;
        xbps-install)
            # Install Flatpak
            "$ESCALATION_TOOL" "$PACKAGER" -y flatpak

            # Add Flathub repository
            "$ESCALATION_TOOL" flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
            ;;
        apk)
            # Install Flatpak
            "$ESCALATION_TOOL" "$PACKAGER" add flatpak

            # Add Flathub repository
            "$ESCALATION_TOOL" flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
            ;;
    esac
    printf "%b\n" "${GREEN}Flatpak configured with Flathub repository${RC}"
}

installGhostty() {
    printf "%b\n" "${YELLOW}Installing Ghostty terminal...${RC}"
    case "$PACKAGER" in
        pacman)
            # Install Ghostty from AUR
            "$AUR_HELPER" -S --needed --noconfirm ghostty
            ;;
        xbps-install)
            # Ghostty not in Void repos, install via Flatpak
            if command_exists flatpak && flatpak list 2>/dev/null | grep -q ghostty; then
                printf "%b\n" "${GREEN}Ghostty already installed via Flatpak${RC}"
            else
                printf "%b\n" "${YELLOW}Installing Ghostty via Flatpak...${RC}"
                "$ESCALATION_TOOL" flatpak install -y flathub com.mitchellh.ghostty
            fi
            ;;
        apk)
            # Ghostty not in Alpine repos, install via Flatpak
            if command_exists flatpak && flatpak list 2>/dev/null | grep -q ghostty; then
                printf "%b\n" "${GREEN}Ghostty already installed via Flatpak${RC}"
            else
                printf "%b\n" "${YELLOW}Installing Ghostty via Flatpak...${RC}"
                "$ESCALATION_TOOL" flatpak install -y flathub com.mitchellh.ghostty
            fi
            ;;
    esac
}

setupDWM() {
    printf "%b\n" "${YELLOW}Installing dwm-gossamer...${RC}"
    case "$PACKAGER" in # Install pre-Requisites
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
              firefox mate-polkit alsa-utils pavucontrol pipewire gnome-keyring \
              networkmanager network-manager-applet openssh nvim \
              fzf bat fd \
              ttf-liberation ttf-dejavu noto-fonts noto-fonts-emoji terminus-font \
              fastfetch starship zoxide man-db
            ;;
        xbps-install)
            "$ESCALATION_TOOL" "$PACKAGER" -y \
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
              fzf bat fd \
              ttf-liberation ttf-dejavu noto-fonts noto-fonts-emoji terminus-font \
              fastfetch starship zoxide man-db
            ;;
        apk)
            "$ESCALATION_TOOL" "$PACKAGER" add \
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
              fzf bat fd \
              ttf-liberation ttf-dejavu noto-fonts noto-fonts-emoji terminus-font \
              fastfetch starship zoxide man-db
            ;;
        *)
            printf "%b\n" "${RED}Unsupported package manager: ""$PACKAGER""${RC}"
            exit 1
            ;;
    esac
}

makeDWM() {
    [ ! -d "$HOME/.local/share" ] && mkdir -p "$HOME/.local/share/"
    if [ ! -d "$HOME/.local/share/dwm-gossamer" ]; then
	printf "%b\n" "${YELLOW}dwm-gossamer not found, cloning repository...${RC}"
	cd "$HOME/.local/share/" || exit 1
	git clone https://github.com/Daniel1788/dwm-gossamer.git || exit 1
	cd dwm-gossamer/ || exit 1
    else
	printf "%b\n" "${GREEN}dwm-gossamer directory already exists, updating...${RC}"
	cd "$HOME/.local/share/dwm-gossamer" || exit 1
	git pull || exit 1
    fi
    "$ESCALATION_TOOL" make clean install || exit 1
    cd "$HOME/.local/share/dwm-gossamer/slstatus" || exit 1
    "$ESCALATION_TOOL" make clean install || exit 1
    cd "$HOME/.local/share/dwm-gossamer" || exit 1
    mkdir -p "$HOME/Pictures/backgrounds/"
    backup_config "$HOME/Pictures/backgrounds/background.jpg"
    cp background.jpg "$HOME/Pictures/backgrounds/"
}

install_nerd_font() {
    FONT_NAME="MesloLGS Nerd Font Mono"
    FONT_DIR="$HOME/.local/share/fonts"
    FONT_URL="https://github.com/ryanoasis/nerd-fonts/releases/latest/download/Meslo.zip"

    if command_exists fc-list && fc-list | grep -qi "Meslo"; then
        printf "%b\n" "${GREEN}Meslo Nerd-fonts are already installed.${RC}"
        return 0
    fi

    printf "%b\n" "${YELLOW}Installing Meslo Nerd-fonts${RC}"

    if ! command_exists unzip; then
        printf "%b\n" "${YELLOW}Installing unzip...${RC}"
        case "$PACKAGER" in
            pacman) "$ESCALATION_TOOL" "$PACKAGER" -S --needed --noconfirm unzip ;;
            xbps-install) "$ESCALATION_TOOL" "$PACKAGER" -y unzip ;;
            apk) "$ESCALATION_TOOL" "$PACKAGER" add unzip ;;
        esac
        if ! command_exists unzip; then
            printf "%b\n" "${RED}Failed to install unzip${RC}"
            return 1
        fi
    fi

    mkdir -p "$FONT_DIR" || return 1

    TEMP_DIR=$(mktemp -d) || return 1
    curl -sSLo "$TEMP_DIR"/"${FONT_NAME}".zip "$FONT_URL"
    unzip "$TEMP_DIR"/"${FONT_NAME}".zip -d "$TEMP_DIR"
    mkdir -p "$FONT_DIR"/"$FONT_NAME"
    mv "${TEMP_DIR}"/*.ttf "$FONT_DIR"/"$FONT_NAME"
    fc-cache -fv
    rm -rf "${TEMP_DIR}"
    printf "%b\n" "${GREEN}'$FONT_NAME' installed successfully.${RC}"
}

clone_config_folders() {
    # Ensure the target directories exist
    [ ! -d ~/.config ] && mkdir -p ~/.config
    [ ! -d ~/.local/bin ] && mkdir -p ~/.local/bin

    # Store the repo path in a variable for safety
    REPO_DIR="$HOME/.local/share/dwm-gossamer"

    # Copy scripts to local bin
    cp -rf "$REPO_DIR/scripts/." "$HOME/.local/bin/"

    # Install Polybar icon fonts
    FONT_DIR="$HOME/.local/share/fonts"
    mkdir -p "$FONT_DIR"
    if [ -d "$REPO_DIR/polybar/fonts" ]; then
        cp -r "$REPO_DIR/polybar/fonts/"* "$FONT_DIR/"
        fc-cache -fv
        printf "%b\n" "${GREEN}Polybar icon fonts installed${RC}"
    fi

    # Iterate over all directories in the repo's config folder
    if [ -d "$REPO_DIR/config" ]; then
        shopt -s nullglob
        for dir in "$REPO_DIR/config/"*/; do
            dir_name=$(basename "$dir")
            backup_config "$HOME/.config/$dir_name"
            cp -r "$dir" ~/.config/
            printf "%b\n" "${GREEN}Cloned $dir_name to ~/.config/${RC}"
        done
        shopt -u nullglob
    else
        printf "%b\n" "${RED}Config directory not found in repository${RC}"
    fi
}

setupMango() {
    printf "%b\n" "${YELLOW}Installing Mango WM Noctalia Wayland setup...${RC}"
    case "$PACKAGER" in
        pacman)
            # Install Mango WM from AUR
            "$AUR_HELPER" -S --needed --noconfirm mangowm-git

            # Install Wayland utilities
            "$ESCALATION_TOOL" "$PACKAGER" -S --needed --noconfirm \
              foot rofi waybar swaybg wl-clip-persist cliphist wl-clipboard \
              wlsunset xfce-polkit swaync pamixer brightnessctl grim slurp satty \
              qt6-wayland xdg-desktop-portal-wlr \
              firefox btop htop fzf bat fd \
              fastfetch starship zoxide man-db
            ;;
        xbps-install)
            # Install build dependencies
            "$ESCALATION_TOOL" "$PACKAGER" -y \
              base-devel git meson ninja pkg-config cmake \
              wayland-devel wayland-protocols libinput-devel libdrm-devel \
              libxkbcommon-devel pixman-devel seatd-devel pcre2-devel \
              libdisplay-info-devel libliftoff-devel hwdata \
              xorg-server-xwayland libxcb-devel mesa-dri mesa-devel

            # Build wlroots 0.19.x
            printf "%b\n" "${YELLOW}Building wlroots...${RC}"
            cd /tmp || exit 1
            git clone -b 0.19.2 https://gitlab.freedesktop.org/wlroots/wlroots.git || exit 1
            cd wlroots || exit 1
            meson build -Dprefix=/usr || exit 1
            "$ESCALATION_TOOL" ninja -C build install || exit 1
            cd /tmp || exit 1
            rm -rf wlroots

            # Build scenefx
            printf "%b\n" "${YELLOW}Building scenefx...${RC}"
            git clone -b 0.4.1 https://github.com/wlrfx/scenefx.git || exit 1
            cd scenefx || exit 1
            meson build -Dprefix=/usr || exit 1
            "$ESCALATION_TOOL" ninja -C build install || exit 1
            cd /tmp || exit 1
            rm -rf scenefx

            # Build mangowm
            printf "%b\n" "${YELLOW}Building mangowm...${RC}"
            git clone https://github.com/mangowm/mango.git || exit 1
            cd mango || exit 1
            meson build -Dprefix=/usr || exit 1
            "$ESCALATION_TOOL" ninja -C build install || exit 1
            cd /tmp || exit 1
            rm -rf mango

            # Install Wayland utilities
            "$ESCALATION_TOOL" "$PACKAGER" -y \
              foot rofi Waybar swaybg wl-clip-persist wl-clipboard cliphist \
              wlsunset pamixer brightnessctl grim slurp satty \
              xfce-polkit qt6-wayland xdg-desktop-portal-wlr \
              firefox btop htop fzf bat fd \
              fastfetch starship zoxide man-db
            ;;
        apk)
            # Install build dependencies
            "$ESCALATION_TOOL" "$PACKAGER" add \
              build-base git meson ninja pkg-config cmake \
              wayland-dev wayland-protocols libinput-dev libdrm-dev \
              libxkbcommon-dev pixman-dev seatd-dev pcre2-dev \
              libdisplay-info-dev libliftoff-dev hwdata \
              xorg-server-xwayland libxcb-dev mesa-dri

            # Build wlroots 0.19.x
            printf "%b\n" "${YELLOW}Building wlroots...${RC}"
            cd /tmp || exit 1
            git clone -b 0.19.2 https://gitlab.freedesktop.org/wlroots/wlroots.git || exit 1
            cd wlroots || exit 1
            meson build -Dprefix=/usr || exit 1
            "$ESCALATION_TOOL" ninja -C build install || exit 1
            cd /tmp || exit 1
            rm -rf wlroots

            # Build scenefx
            printf "%b\n" "${YELLOW}Building scenefx...${RC}"
            git clone -b 0.4.1 https://github.com/wlrfx/scenefx.git || exit 1
            cd scenefx || exit 1
            meson build -Dprefix=/usr || exit 1
            "$ESCALATION_TOOL" ninja -C build install || exit 1
            cd /tmp || exit 1
            rm -rf scenefx

            # Build mangowm
            printf "%b\n" "${YELLOW}Building mangowm...${RC}"
            git clone https://github.com/mangowm/mango.git || exit 1
            cd mango || exit 1
            meson build -Dprefix=/usr || exit 1
            "$ESCALATION_TOOL" ninja -C build install || exit 1
            cd /tmp || exit 1
            rm -rf mango

            # Install Wayland utilities
            "$ESCALATION_TOOL" "$PACKAGER" add \
              foot rofi Waybar swaybg wl-clip-persist wl-clipboard \
              wlsunset pamixer brightnessctl grim slurp \
              qt6-wayland \
              firefox btop htop fzf bat fd \
              fastfetch starship zoxide man-db
            ;;
        *)
            printf "%b\n" "${RED}Mango WM not supported on this package manager${RC}"
            exit 1
            ;;
    esac
}

makeMango() {
    printf "%b\n" "${YELLOW}Configuring Mango WM...${RC}"

    # Create config directory
    mkdir -p ~/.config/mango

    # Copy default config if not exists
    if [ ! -f ~/.config/mango/config.conf ]; then
        if [ -f /etc/mango/config.conf ]; then
            cp /etc/mango/config.conf ~/.config/mango/config.conf
            printf "%b\n" "${GREEN}Copied default Mango config${RC}"
        fi
    fi
}

setupNoctalia() {
    printf "%b\n" "${YELLOW}Installing Noctalia Shell...${RC}"
    case "$PACKAGER" in
        pacman)
            # Install Noctalia Shell from AUR
            "$AUR_HELPER" -S --needed --noconfirm noctalia-shell

            # Install Noctalia dependencies
            "$ESCALATION_TOOL" "$PACKAGER" -S --needed --noconfirm \
              brightnessctl imagemagick python git \
              cliphist wlsunset xdg-desktop-portal
            ;;
        xbps-install)
            # Install dependencies
            "$ESCALATION_TOOL" "$PACKAGER" -y \
              brightnessctl imagemagick python3 git cmake ninja \
              qt6-base qt6-base-devel qt6-declarative qt6-declarative-devel \
              qt6-svg qt6-svg-devel qt6-wayland qt6-wayland-devel \
              polkit glib glib-devel xdg-desktop-portal

            # Build noctalia-qs from source
            printf "%b\n" "${YELLOW}Building noctalia-qs...${RC}"
            cd /tmp || exit 1
            git clone https://github.com/noctalia-dev/noctalia-qs.git || exit 1
            cd noctalia-qs || exit 1
            cmake -GNinja -B build -DCMAKE_BUILD_TYPE=Release \
              -DCMAKE_INSTALL_PREFIX=/usr || exit 1
            ninja -C build || exit 1
            "$ESCALATION_TOOL" ninja -C build install || exit 1
            cd "$HOME" || exit 1
            rm -rf /tmp/noctalia-qs

            # Install Noctalia Shell config
            mkdir -p ~/.config/quickshell/noctalia-shell
            curl -sL https://github.com/noctalia-dev/noctalia-shell/releases/latest/download/noctalia-latest.tar.gz \
              | tar -xz --strip-components=1 -C ~/.config/quickshell/noctalia-shell
            ;;
        apk)
            # Install dependencies
            "$ESCALATION_TOOL" "$PACKAGER" add \
              brightnessctl imagemagick python3 git cmake ninja \
              qt6-base qt6-declarative qt6-svg qt6-wayland \
              polkit glib

            # Build noctalia-qs from source
            printf "%b\n" "${YELLOW}Building noctalia-qs...${RC}"
            cd /tmp || exit 1
            git clone https://github.com/noctalia-dev/noctalia-qs.git || exit 1
            cd noctalia-qs || exit 1
            cmake -GNinja -B build -DCMAKE_BUILD_TYPE=Release \
              -DCMAKE_INSTALL_PREFIX=/usr || exit 1
            ninja -C build || exit 1
            "$ESCALATION_TOOL" ninja -C build install || exit 1
            cd "$HOME" || exit 1
            rm -rf /tmp/noctalia-qs

            # Install Noctalia Shell config
            mkdir -p ~/.config/quickshell/noctalia-shell
            curl -sL https://github.com/noctalia-dev/noctalia-shell/releases/latest/download/noctalia-latest.tar.gz \
              | tar -xz --strip-components=1 -C ~/.config/quickshell/noctalia-shell
            ;;
    esac
}

cloneMangoConfig() {
    # Ensure target directories exist
    [ ! -d ~/.config ] && mkdir -p ~/.config
    [ ! -d ~/.local/bin ] && mkdir -p ~/.local/bin

    # Copy Mango config if repo exists
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
        printf "%b\n" "  3. Noctalia should auto-start with Mango"
        printf "%b\n" "     (if not: ${GREEN}exec noctalia-qs -c noctalia-shell${RC})"
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

if [ -f .bashrc ]; then
    backup_config "$HOME/.bashrc"
    cp .bashrc ~/.bashrc
    printf "%b\n" "${CYAN}Updated ~/.bashrc from repository${RC}"
fi

checkEnv
choose_setup
setupChaoticAUR
setupLemurs

if [ "$SETUP_TYPE" = "dwm" ]; then
    setupFlatpak
    installGhostty
    setupDWM
    makeDWM
    install_nerd_font
    clone_config_folders
elif [ "$SETUP_TYPE" = "mango" ]; then
    setupFlatpak
    installGhostty
    setupMango
    makeMango
    setupNoctalia
    install_nerd_font
    cloneMangoConfig
else
    printf "%b\n" "${RED}Error: No setup type selected${RC}"
    exit 1
fi

print_summary
