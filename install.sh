#!/usr/bin/env bash

# Colors
RC='\033[0m'
RED='\033[31m'
YELLOW='\033[33m'
CYAN='\033[36m'
GREEN='\033[32m'
BOLD='\033[1m'

# Utility functions
log_info() { printf "%b\n" "${CYAN}%s${RC}" "$1"; }
log_success() { printf "%b\n" "${GREEN}%s${RC}" "$1"; }
log_warn() { printf "%b\n" "${YELLOW}%s${RC}" "$1"; }
log_error() { printf "%b\n" "${RED}%s${RC}" "$1"; }

# Distro Detection
detect_distro() {
    if [ -f /etc/arch-release ]; then
        DISTRO="Arch"
    elif [ -f /etc/void-release ]; then
        DISTRO="Void"
    else
        DISTRO="Unknown"
    fi
}

# Privilege Escalation Detection
check_escalation() {
    if [ "$(id -u)" = "0" ]; then
        log_warn "You are running this menu as root. It is recommended to run as a normal user with sudo/doas privileges."
    fi
}

update_bashrc() {
    if [ -f .bashrc ]; then
        [ -f ~/.bashrc ] && cp ~/.bashrc ~/.bashrc.backup.$(date +%s)
        cp .bashrc ~/.bashrc
        log_success "Updated ~/.bashrc from repository"
    else
        log_error ".bashrc not found in the current directory."
    fi
}

# Helper to run scripts
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
    # We run the script as the current user because the scripts
    # handle their own escalation for system-level tasks.
    ./"$script"
}

show_menu() {
    clear
    printf "${BOLD}${CYAN}==================================================${RC}\n"
    printf "${BOLD}${CYAN}           Ethos Echo Installation Menu          ${RC}\n"
    printf "${BOLD}${CYAN}==================================================${RC}\n"
    printf "System Detected: ${BOLD}%s${RC}\n" "$DISTRO"
    printf "--------------------------------------------------\n"
    printf "1) ${BOLD}Full Mango WM Setup${RC} (Core, Lemurs, Noctalia)\n"
    printf "2) ${BOLD}Full DWM Setup${RC} (Core, Lemurs, Gossamer)\n"
    printf "3) ${BOLD}Install Lemurs Only${RC} (Session manager setup)\n"
    printf "4) ${BOLD}Update .bashrc${RC} (Copy from repository)\n"
    printf "5) ${BOLD}Exit${RC}\n"
    printf "${BOLD}${CYAN}--------------------------------------------------${RC}\n"
    printf "Select an option: "
}

main() {
    detect_distro
    check_escalation
    update_bashrc

    while true; do
        show_menu
        read -r choice
        case $choice in
            1)
                # Full Mango Experience
                run_install_script "install-lemurs.sh" "Lemurs Session Manager"
                run_install_script "install-mango.sh" "Mango WM & Noctalia Shell"
                printf "\nPress Enter to return to menu..."
                read -r
                ;;
            2)
                # Full DWM Experience
                run_install_script "install-lemurs.sh" "Lemurs Session Manager"
                run_install_script "install-dwm.sh" "DWM Gossamer"
                printf "\nPress Enter to return to menu..."
                read -r
                ;;
            3)
                run_install_script "install-lemurs.sh" "Lemurs"
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
