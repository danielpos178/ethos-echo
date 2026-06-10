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

    ## Ensure Void Linux repositories are configured
    if [ "$PACKAGER" = "xbps-install" ] && [ ! -f /etc/xbps.d/00-repository-main.conf ]; then
        printf "%b\n" "${YELLOW}No xbps repositories found. Configuring default Void Linux repos...${RC}"
        "$ESCALATION_TOOL" mkdir -p /etc/xbps.d
        "$ESCALATION_TOOL" sh -c 'echo "repository=https://repo-default.voidlinux.org/current" > /etc/xbps.d/00-repository-main.conf'
        printf "%b\n" "${GREEN}Default Void Linux repository configured.${RC}"
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

install_lemurs_pkg() {
    printf "%b\n" "${YELLOW}Installing Lemurs package...${RC}"
    case "$PACKAGER" in
        xbps-install)
            "$ESCALATION_TOOL" "$PACKAGER" -S -y lemurs || exit 1
            ;;
        pacman)
            "$ESCALATION_TOOL" "$PACKAGER" -S --needed --noconfirm lemurs || {
                printf "%b\n" "${RED}Lemurs not found in official repos. Please install it from AUR.${RC}"
                exit 1
            }
            ;;
        *)
            printf "%b\n" "${RED}Unsupported package manager: $PACKAGER${RC}"
            exit 1
            ;;
    esac
}

setup_lemurs_service() {
    printf "%b\n" "${YELLOW}Setting up Lemurs as a system service...${RC}"

    # Common PAM configuration
    cat <<EOF > /tmp/lemurs_pam
#%PAM-1.0
auth        include    login
account     include    login
session     include    login
password    include    login
EOF
    "$ESCALATION_TOOL" mv /tmp/lemurs_pam /etc/pam.d/lemurs

    # Common Config
    "$ESCALATION_TOOL" mkdir -p /etc/lemurs
    echo "tty = 7" > /tmp/lemurs_conf
    "$ESCALATION_TOOL" mv /tmp/lemurs_conf /etc/lemurs/config.toml

    if [ "$PACKAGER" = "xbps-install" ]; then
        # Void Linux / runit
        "$ESCALATION_TOOL" mkdir -p /etc/sv/lemurs
        cat <<EOF > /tmp/lemurs_run
#!/bin/sh
if command -v fgconsole >/dev/null 2>&1 && command -v chvt >/dev/null 2>&1; then
  cur="\$(fgconsole 2>/dev/null || echo "")"
  if [ -n "\$cur" ] && [ "\$cur" != "serial" ] && [ "\$cur" != "7" ]; then
    chvt 7 2>/dev/null || true
  fi
fi
TERM=linux setterm --msg off </dev/tty7 >/dev/tty7 2>/dev/null || true
TERM=linux setterm --clear=all </dev/tty7 >/dev/tty7 2>/dev/null || true
exec agetty --noissue --skip-login --login-program /usr/bin/lemurs tty7 linux
EOF
        "$ESCALATION_TOOL" mv /tmp/lemurs_run /etc/sv/lemurs/run
        "$ESCALATION_TOOL" chmod +x /etc/sv/lemurs/run
    elif [ "$PACKAGER" = "pacman" ]; then
        # Arch Linux / systemd

        # 1. Create a wrapper script for the TTY7 switch logic
        cat <<EOF > /tmp/lemurs-wrapper
#!/bin/sh
if command -v fgconsole >/dev/null 2>&1 && command -v chvt >/dev/null 2>&1; then
  cur="\$(fgconsole 2>/dev/null || echo "")"
  if [ -n "\$cur" ] && [ "\$cur" != "serial" ] && [ "\$cur" != "7" ]; then
    chvt 7 2>/dev/null || true
  fi
fi
TERM=linux setterm --msg off </dev/tty7 >/dev/tty7 2>/dev/null || true
TERM=linux setterm --clear=all </dev/tty7 >/dev/tty7 2>/dev/null || true
exec /usr/bin/agetty --noissue --skip-login --login-program /usr/bin/lemurs tty7 linux
EOF
        "$ESCALATION_TOOL" mkdir -p /usr/local/bin
        "$ESCALATION_TOOL" mv /tmp/lemurs-wrapper /usr/local/bin/lemurs-wrapper
        "$ESCALATION_TOOL" chmod +x /usr/local/bin/lemurs-wrapper

        # 2. Create systemd service
        cat <<EOF > /tmp/lemurs.service
[Unit]
Description=Lemurs Login Manager
After=network.target

[Service]
ExecStart=/usr/local/bin/lemurs-wrapper
StandardInput=tty
StandardOutput=tty
TTYPath=/dev/tty7
Restart=always

[Install]
WantedBy=multi-user.target
EOF
        "$ESCALATION_TOOL" mv /tmp/lemurs.service /etc/systemd/system/lemurs.service

        # 3. Mask the default getty@tty7 to avoid conflict
        "$ESCALATION_TOOL" systemctl mask getty@tty7.service
    fi
}

activate_lemurs_service() {
    printf "%b\n" "${YELLOW}Activating Lemurs service...${RC}"
    if [ "$PACKAGER" = "xbps-install" ]; then
        if [ -d "/etc/sv/lemurs" ]; then
            "$ESCALATION_TOOL" ln -sf "/etc/sv/lemurs" "/var/service/"
            printf "%b\n" "${GREEN}Lemurs service enabled.${RC}"
        else
            printf "%b\n" "${RED}Service lemurs not found in /etc/sv/${RC}"
            exit 1
        fi
    elif [ "$PACKAGER" = "pacman" ]; then
        "$ESCALATION_TOOL" systemctl daemon-reload
        "$ESCALATION_TOOL" systemctl enable --now lemurs.service
        printf "%b\n" "${GREEN}Lemurs systemd service enabled and started.${RC}"
    fi
}

main() {
    checkEnv
    install_lemurs_pkg
    setup_lemurs_service
    activate_lemurs_service
    printf "%b\n" "${GREEN}Lemurs installation complete!${RC}"
}

main "$@"
