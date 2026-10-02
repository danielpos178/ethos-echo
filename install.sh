#!/usr/bin/env bash
# ==============================================================================
# Ethos Echo - Installation Launcher
# ==============================================================================

set -eo pipefail

# Colors
RC='\033[0m'
RED='\033[31m'
YELLOW='\033[33m'
CYAN='\033[36m'
GREEN='\033[32m'
BOLD='\033[1m'

# Utility functions
log_info()    { printf "%b%s%b\n" "${CYAN}" "$1" "${RC}"; }
log_success() { printf "%b%s%b\n" "${GREEN}" "$1" "${RC}"; }
log_warn()    { printf "%b%s%b\n" "${YELLOW}" "$1" "${RC}"; }
log_error()   { printf "%b%s%b\n" "${RED}" "$1" "${RC}"; }

# Distro Detection
detect_distro() {
    if [ -f /etc/os-release ]; then
        if grep -q -E '^ID="?arch"?' /etc/os-release || grep -q -E '^ID_LIKE=.*arch.*' /etc/os-release || [ -f /etc/arch-release ]; then
            DISTRO="Arch Linux"
            DEFAULT_INSTALLER="install-umbriel.sh"
        elif grep -q -E '^ID="?void"?' /etc/os-release || command -v xbps-install >/dev/null 2>&1 || [ -d /var/db/xbps ]; then
            DISTRO="Void Linux"
            DEFAULT_INSTALLER="install-void.sh"
        else
            DISTRO="Unknown"
            DEFAULT_INSTALLER="install-umbriel.sh"
        fi
    elif [ -f /etc/arch-release ]; then
        DISTRO="Arch Linux"
        DEFAULT_INSTALLER="install-umbriel.sh"
    elif command -v xbps-install >/dev/null 2>&1 || [ -d /var/db/xbps ]; then
        DISTRO="Void Linux"
        DEFAULT_INSTALLER="install-void.sh"
    else
        DISTRO="Unknown"
        DEFAULT_INSTALLER="install-umbriel.sh"
    fi
}

check_escalation() {
    if [ "$(id -u)" -eq 0 ]; then
        log_error "Do not run this installer as root or with sudo!"
        log_info "Package helpers, builds, and user configurations require running as a regular user."
        log_info "Please run as your regular user: ./install.sh"
        exit 1
    fi
}

update_bashrc() {
    if [ -f .bashrc ]; then
        [ -f ~/.bashrc ] && cp ~/.bashrc ~/.bashrc.backup."$(date +%s)"
        cp .bashrc ~/.bashrc
        log_success "Updated ~/.bashrc from repository"
    else
        log_error ".bashrc not found in the current directory."
    fi
}

run_install_script() {
    local script=$1
    local description=$2

    if [ ! -f "$script" ]; then
        log_error "Installation script $script not found!"
        return 1
    fi

    if [ ! -x "$script" ]; then
        chmod +x "$script"
    fi

    log_info "Starting $description ($script)..."
    ./"$script"
}

show_menu() {
    clear 2>/dev/null || true
    printf "${BOLD}${GREEN}====================================================${RC}\n"
    printf "${BOLD}${GREEN}            Ethos Echo Installation Menu            ${RC}\n"
    printf "${BOLD}${GREEN}====================================================${RC}\n"
    printf "System Detected: ${BOLD}%s${RC}\n" "$DISTRO"
    printf "%s\n" "----------------------------------------------------"
    printf "1) ${BOLD}Full Setup for %s${RC} (Auto-detected: %s)\n" "$DISTRO" "$DEFAULT_INSTALLER"
    printf "2) ${BOLD}Arch Linux Installer${RC} (install-umbriel.sh - pacman/AUR)\n"
    printf "3) ${BOLD}Void Linux Installer${RC} (install-void.sh - xbps/runit)\n"
    printf "4) ${BOLD}Update .bashrc${RC} (Copy from repository)\n"
    printf "5) ${BOLD}Exit${RC}\n"
    printf "${BOLD}${GREEN}----------------------------------------------------${RC}\n"
    printf "Select an option: "
}

main() {
    detect_distro
    check_escalation

    while true; do
        show_menu
        read -r choice
        case $choice in
            1)
                run_install_script "$DEFAULT_INSTALLER" "Umbriel & Noctalia Suite ($DISTRO)"
                printf "\nPress Enter to return to menu..."
                read -r
                ;;
            2)
                run_install_script "install-umbriel.sh" "Arch Linux Installer"
                printf "\nPress Enter to return to menu..."
                read -r
                ;;
            3)
                run_install_script "install-void.sh" "Void Linux Installer"
                printf "\nPress Enter to return to menu..."
                read -r
                ;;
            4)
                update_bashrc
                printf "\nPress Enter to return to menu..."
                read -r
                ;;
            5)
                log_info "Exiting installer. Goodbye!"
                exit 0
                ;;
            *)
                log_error "Invalid option. Please try again."
                sleep 1
                ;;
        esac
    done
}

main "$@"
