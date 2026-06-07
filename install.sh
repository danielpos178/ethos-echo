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
        ESCALATOR="eval"
    elif command -v sudo >/dev/null 2>&1; then
        ESCALATOR="sudo"
    elif command -v doas >/dev/null 2>&1; then
        ESCALATOR="doas"
    else
        log_error "Neither sudo nor doas found. Please install one to run system installations."
        exit 1
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

# Helper to run scripts with a distro check
run_install_script() {
    local script=$1
    local is_void_specific=$2
    local description=$3

    if [ ! -f "$script" ]; then
        log_error "Installation script $script not found!"
        return 1
    fi

    if [ ! -x "$script" ]; then
        chmod +x "$script"
    fi

    if [ "$is_void_specific" = true ] && [ "$DISTRO" != "Void" ]; then
        printf "${YELLOW}WARNING: %s is designed for Void Linux.${RC}\n" "$description"
        printf "You are running on %s. This installation will likely fail.${RC}\n" "$DISTRO"
        printf "Do you want to proceed anyway? (y/N): "
        read -r confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            log_info "Installation cancelled."
            return 1
        fi
    fi

    log_info "Starting $description..."
    $ESCALATOR ./"$script"
}

show_menu() {
    clear
    printf "${BOLD}${CYAN}==================================================${RC}\n"
    printf "${BOLD}${CYAN}           Ethos Echo Installation Menu          ${RC}\n"
    printf "${BOLD}${CYAN}==================================================${RC}\n"
    printf "System Detected: ${BOLD}%s${RC}\n" "$DISTRO"
    printf "--------------------------------------------------\n"
    printf "1) ${BOLD}Install Mango WM${RC} (Setup: Core, Noctalia)\n"
    printf "2) ${BOLD}Install DWM${RC} (Gossamer setup: Core, DWM, Configs)\n"
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
                run_install_script "install-mango.sh" true "Mango WM"
                printf "\nPress Enter to return to menu..."
                read -r
                ;;
            2)
                # DWM script handles its own escalation and is distro-agnostic (mostly)
                run_install_script "install-dwm.sh" false "DWM"
                printf "\nPress Enter to return to menu..."
                read -r
                ;;
            3)
                run_install_script "install-lemurs.sh" true "Lemurs"
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
