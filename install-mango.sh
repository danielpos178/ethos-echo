#!/usr/bin/env bash

RC='\033[0m'
RED='\033[31m'
YELLOW='\033[33m'
CYAN='\033[36m'
GREEN='\033[32m'

# Utility functions
log_info() { printf "%b\n" "${CYAN}[INFO] %s${RC}" "$1"; }
log_success() { printf "%b\n" "${GREEN}[SUCCESS] %s${RC}" "$1"; }
log_error() { printf "%b\n" "${RED}[ERROR] %s${RC}" "$1"; exit 1; }

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
    REQUIREMENTS=$1
    for req in ${REQUIREMENTS}; do
        if ! command_exists "${req}"; then
            printf "%b\n" "${RED}To run me, you need: ${REQUIREMENTS}${RC}"
            exit 1
        fi
    done
}

checkPackageManager() {
    PACKAGEMANAGER=$1
    for pgm in ${PACKAGEMANAGER}; do
        if command_exists "${pgm}"; then
            PACKAGER=${pgm}
            printf "%b\n" "${CYAN}Using ${pgm} as package manager${RC}"
            break
        fi
    done

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
    checkPackageManager 'xbps-install pacman'
    checkCurrentDirectoryWritable
    checkSuperUser
}

prepare_system() {
    printf "%b\n" "${YELLOW}Updating system repositories...${RC}"
    case "$PACKAGER" in
        xbps-install) "$ESCALATION_TOOL" "$PACKAGER" -Syu -y ;;
        pacman) "$ESCALATION_TOOL" "$PACKAGER" -Syu --noconfirm ;;
    esac
}

install_graphics() {
    printf "%b\n" "${YELLOW}Detecting GPU and installing drivers...${RC}"
    case "$PACKAGER" in
        xbps-install)
            "$ESCALATION_TOOL" "$PACKAGER" -y linux-firmware mesa-dri vulkan-loader xorg-server-xwayland
            if lspci | grep -qi "nvidia"; then
                "$ESCALATION_TOOL" "$PACKAGER" -y nvidia
                printf "%b\n" "${YELLOW}Nvidia KMS not enabled by default. Add 'nvidia-drm.modeset=1' to kernel parameters.${RC}"
            elif lspci | grep -qi "amd"; then
                "$ESCALATION_TOOL" "$PACKAGER" -y mesa-vulkan-radeon
            elif lspci | grep -qi "intel"; then
                "$ESCALATION_TOOL" "$PACKAGER" -y mesa-vulkan-intel
            fi
            ;;
        pacman)
            "$ESCALATION_TOOL" "$PACKAGER" -S --needed --noconfirm linux-firmware mesa vulkan-icd-loader xorg-xwayland
            if lspci | grep -qi "nvidia"; then
                "$ESCALATION_TOOL" "$PACKAGER" -S --needed --noconfirm nvidia
                printf "%b\n" "${YELLOW}Nvidia KMS not enabled by default. Add 'nvidia-drm.modeset=1' to kernel parameters.${RC}"
            elif lspci | grep -qi "amd"; then
                "$ESCALATION_TOOL" "$PACKAGER" -S --needed --noconfirm vulkan-radeon
            elif lspci | grep -qi "intel"; then
                "$ESCALATION_TOOL" "$PACKAGER" -S --needed --noconfirm vulkan-intel
            fi
            ;;
    esac
}

install_core() {
    printf "%b\n" "${YELLOW}Installing core system components...${RC}"
    case "$PACKAGER" in
        xbps-install)
            "$ESCALATION_TOOL" "$PACKAGER" -y dbus elogind NetworkManager \
              pipewire wireplumber alsa-pipewire bluez libspa-bluetooth \
              xdg-desktop-portal-wlr polkit lxqt-policykit xdg-user-dirs qt6-wayland qt5-wayland
            ;;
        pacman)
            "$ESCALATION_TOOL" "$PACKAGER" -S --needed --noconfirm dbus NetworkManager \
              pipewire wireplumber pipewire-alsa bluez pipewire-bluetooth \
              xdg-desktop-portal-wlr polkit lxqt-policykit xdg-user-dirs qt6-wayland qt5-wayland
            ;;
    esac
}

install_desktop() {
    printf "%b\n" "${YELLOW}Installing Mango WM and Noctalia Shell...${RC}"
    case "$PACKAGER" in
        xbps-install)
            "$ESCALATION_TOOL" "$PACKAGER" -y mangowc foot nerd-fonts

            log_info "Configuring Noctalia Shell repository..."
            "$ESCALATION_TOOL" sh -c 'echo "repository=https://universalrepository.pages.dev/void" > /etc/xbps.d/10-noctalia.conf'
            "$ESCALATION_TOOL" chmod 644 /etc/xbps.d/10-noctalia.conf

            XBPS_YES=1 "$ESCALATION_TOOL" "$PACKAGER" -S
            XBPS_YES=1 "$ESCALATION_TOOL" "$PACKAGER" -y noctalia
            ;;
        pacman)
            "$ESCALATION_TOOL" "$PACKAGER" -S --needed --noconfirm foot ttf-nerd-fonts-symbols

            # Try to find an AUR helper
            if command -v yay >/dev/null 2>&1; then
                AUR_HELPER="yay"
            elif command -v paru >/dev/null 2>&1; then
                AUR_HELPER="paru"
            fi

            if [ -n "$AUR_HELPER" ]; then
                log_info "AUR helper $AUR_HELPER found. Installing mangowc and noctalia..."
                $AUR_HELPER -S --noconfirm mangowc noctalia
            else
                printf "%b\n" "${YELLOW}No AUR helper (yay/paru) found. Please install 'mangowc' and 'noctalia' manually from the AUR.${RC}"
            fi
            ;;
    esac
}

activate_services() {
    printf "%b\n" "${YELLOW}Activating services...${RC}"
    SERVICES="dbus NetworkManager bluetooth"

    if [ "$PACKAGER" = "xbps-install" ]; then
        # Void Linux / runit
        for svc in $SERVICES; do
            # Map names if necessary
            svc_name=$svc
            [ "$svc" = "bluetooth" ] && svc_name="bluetoothd"
            if [ -d "/etc/sv/$svc_name" ]; then
                "$ESCALATION_TOOL" ln -sf "/etc/sv/$svc_name" "/var/service/"
                printf "%b\n" "${GREEN}Enabled $svc_name${RC}"
            fi
        done
    elif [ "$PACKAGER" = "pacman" ]; then
        # Arch Linux / systemd
        for svc in $SERVICES; do
            svc_name=$svc
            [ "$svc" = "bluetooth" ] && svc_name="bluetooth"
            "$ESCALATION_TOOL" systemctl enable --now "$svc_name"
            printf "%b\n" "${GREEN}Enabled $svc_name${RC}"
        done
    fi
}

configure_user() {
    printf "%b\n" "${YELLOW}Configuring user permissions for $TARGET_USER...${RC}"
    if [ "$ESCALATION_TOOL" = "eval" ]; then
        usermod -aG wheel,video,audio,bluetooth "$TARGET_USER"
        su - "$TARGET_USER" -c "xdg-user-dirs-update"
    else
        "$ESCALATION_TOOL" usermod -aG wheel,video,audio,bluetooth "$TARGET_USER"
        "$ESCALATION_TOOL" -u "$TARGET_USER" xdg-user-dirs-update
    fi
}

configure_wm() {
    printf "%b\n" "${YELLOW}Configuring Mango WM autostart...${RC}"
    mkdir -p "/home/$TARGET_USER/.config/mango"
    cat <<EOF > "/home/$TARGET_USER/.config/mango/config.conf"
# MangoWM Configuration
exec-once = pipewire
exec-once = wireplumber
exec-once = lxqt-policykit
exec-once = qs -c noctalia-shell
EOF
    chown -R "$TARGET_USER:$TARGET_USER" "/home/$TARGET_USER/.config/mango"
}

main() {
    # Determine target user
    TARGET_USER=${SUDO_USER:-$(whoami)}
    if [ "$TARGET_USER" = "root" ]; then
        printf "%b\n" "${RED}Please run this script as a normal user with sudo.${RC}"
        exit 1
    fi

    checkEnv
    prepare_system
    install_graphics
    install_core
    install_desktop
    configure_wm
    activate_services
    configure_user

    printf "\n${GREEN}==================================================${RC}\n"
    printf "${GREEN}Installation complete!${RC}\n"
    printf "${CYAN}Next steps:${RC}\n"
    printf "1. Reboot your system: ${RED}sudo reboot${RC}\n"
    printf "2. Launch Mango WM and enjoy Noctalia Shell\n"
    printf "${GREEN}==================================================${RC}\n"
}

main "$@"
