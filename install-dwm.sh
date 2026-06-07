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
            printf "%b\n" "${RED}To run me, you need: ${REQUIREMENTS}${RC}"
            exit 1
        fi
    done
}

checkPackageManager() {
    ## Check Package Manager
    PACKAGEMANAGER=$1
    for pgm in ${PACKAGEMANAGER}; do
        if command_exists "${pgm}"; then
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


    if [ -z "$PACKAGER" ]; then
        printf "%b\n" "${RED}Can't find a supported package manager${RC}"
        exit 1
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
        printf "%b\n" "${RED}You need to be a member of the sudo group to run me!${RC}"
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
    checkCommandRequirements "curl groups $ESCALATION_TOOL"
    checkPackageManager 'pacman xbps-install'
    checkCurrentDirectoryWritable
    checkSuperUser
}

setupDWM() {
    printf "%b\n" "${YELLOW}Installing dwm-gossamer dependencies...${RC}"
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
              firefox polkit-gnome alsa-utils pavucontrol pipewire gnome-keyring flatpak \
              networkmanager network-manager-applet openssh nvim \
              fzf bat fd \
              ttf-liberation ttf-dejavu noto-fonts noto-fonts-emoji terminus-font \
              fastfetch starship zoxide man-db
            ;;
        xbps-install)
            "$ESCALATION_TOOL" "$PACKAGER" -S \
              base-devel git linux-headers unzip curl wget \
              xorg-server xorg-xinit xorg-xrandr xorg-xsetroot xorg-xprop xorg-xset xorg-xhost xf86-input-libinput \
              libX11-devel libXinerama-devel libXft-devel libxcb-devel imlib2-devel fontconfig-devel freetype-devel \
              polybar picom dunst rofi dmenu slock alacritty xdo xdotool \
              feh flameshot imagemagick ffmpeg playerctl \
              btop htop arandr xclip xsel xarchiver thunar tumbler gvfs thunar-archive-plugin \
              tldr dex nwg-look xscreensaver brightnessctl acpi \
              xdg-user-dirs xdg-desktop-portal-gtk xdg-utils \
              firefox polkit-gnome alsa-utils pavucontrol pipewire gnome-keyring flatpak \
              NetworkManager network-manager-applet openssh neovim \
              fzf bat fd \
              font-liberation font-dejavu font-noto font-noto-emoji font-terminus \
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
	cd "$HOME/.local/share/" && git clone https://github.com/Daniel1788/dwm-gossamer.git || exit 1
	cd dwm-gossamer/ || exit 1
    else
	printf "%b\n" "${GREEN}dwm-gossamer directory already exists, replacing..${RC}"
	cd "$HOME/.local/share/dwm-gossamer" && git pull || exit 1
    fi
    "$ESCALATION_TOOL" make clean install
    cd "$HOME/.local/share/dwm-gossamer/slstatus"
    "$ESCALATION_TOOL" make clean install
    cd "$HOME/.local/share/dwm-gossamer"
    mkdir -p "$HOME/Pictures/backgrounds/"
    cp background.jpg "$HOME/Pictures/backgrounds/"
}

install_nerd_font() {
    # Check to see if the MesloLGS Nerd Font is installed (Change this to whatever font you would like)
    FONT_NAME="MesloLGS Nerd Font Mono"
    FONT_DIR="$HOME/.local/share/fonts"
    FONT_URL="https://github.com/ryanoasis/nerd-fonts/releases/latest/download/Meslo.zip"
    FONT_INSTALLED=$(fc-list | grep -i "Meslo")

    if [ -n "$FONT_INSTALLED" ]; then
        printf "%b\n" "${GREEN}Meslo Nerd-fonts are already installed.${RC}"
        return 0
    fi

    printf "%b\n" "${YELLOW}Installing Meslo Nerd-fonts${RC}"

    # Create the fonts directory if it doesn't exist
    if [ ! -d "$FONT_DIR" ]; then
        mkdir -p "$FONT_DIR" || {
            printf "%b\n" "${RED}Failed to create directory: $FONT_DIR${RC}"
            return 1
        }
    fi
        printf "%b\n" "${YELLOW}Installing font '$FONT_NAME'${RC}"
        # Change this URL to correspond with the correct font
        FONT_URL="https://github.com/ryanoasis/nerd-fonts/releases/latest/download/Meslo.zip"
        FONT_DIR="$HOME/.local/share/fonts"
        TEMP_DIR=$(mktemp -d)
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
        for dir in "$REPO_DIR/config/"*/; do
            dir_name=$(basename "$dir")
            cp -r "$dir" ~/.config/
            printf "%b\n" "${GREEN}Cloned $dir_name to ~/.config/${RC}"
        done
    else
        printf "%b\n" "${RED}Config directory not found in repository${RC}"
    fi
}

checkEnv
setupDWM
makeDWM
install_nerd_font
clone_config_folders
