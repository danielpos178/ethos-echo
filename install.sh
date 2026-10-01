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
log_info()    { printf "%b\n" "${CYAN}%s${RC}" "$1"; }
log_success() { printf "%b\n" "${GREEN}%s${RC}" "$1"; }
log_warn()    { printf "%b\n" "${YELLOW}%s${RC}" "$1"; }
log_error()   { printf "%b\n" "${RED}%s${RC}" "$1"; }

# Distro Detection
detect_distro() {
    if [ -f /etc/arch-release ]; then
        DISTRO="Arch Linux"
    else
        DISTRO="Unknown"
    fi
}

check_escalation() {
    if [ "$(id -u)" = "0" ]; then
        log_warn "You are running this launcher as root. It is recommended to run as a normal user with sudo/doas privileges."
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

    log_info "Starting $description..."
    ./"$script"
}

show_menu() {
    clear
    printf "${BOLD}${GREEN}====================================================${RC}\n"
    printf "${BOLD}${GREEN}            Ethos Echo Installation Menu            ${RC}\n"
    printf "${BOLD}${GREEN}====================================================${RC}\n"
    printf "System Detected: ${BOLD}%s${RC}\n" "$DISTRO"
    printf "----------------------------------------------------\n"
    printf "1) ${BOLD}Full Umbriel Setup${RC} (Umbriel, Noctalia, Greeter, Alacritty)\n"
    printf "2) ${BOLD}Update .bashrc${RC} (Copy from repository)\n"
    printf "3) ${BOLD}Exit${RC}\n"
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
                run_install_script "install-umbriel.sh" "Umbriel & Noctalia Suite Installer"
                printf "\nPress Enter to return to menu..."
                read -r
                ;;
            2)
                update_bashrc
                printf "\nPress Enter to return to menu..."
                read -r
                ;;
            3)
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
