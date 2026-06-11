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
        err "Can't write to $GITPATH"
        exit 1
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
    checkPackageManager 'xbps-install pacman'
    checkCurrentDirectoryWritable
    checkSuperUser
    detectTargetUser
}

install_lemurs_pkg() {
    info "Installing Lemurs package..."
    case "$PACKAGER" in
        xbps-install)
            "$ESCALATION_TOOL" "$PACKAGER" -S -y lemurs xinit || {
                err "Failed to install lemurs/xinit packages"
                exit 1
            }
            ;;
        pacman)
            "$ESCALATION_TOOL" "$PACKAGER" -S --needed --noconfirm lemurs xorg-xinit || {
                err "Lemurs not found in official repos. Install it from AUR."
                exit 1
            }
            ;;
        *)
            err "Unsupported package manager: $PACKAGER"
            exit 1
            ;;
    esac
    ok "Lemurs and xinit packages installed"
}

setup_lemurs_service() {
    info "Setting up Lemurs as a system service..."

    # ── PAM configuration ────────────────────────────────
    # Use explicit PAM modules instead of "include login" for reliable
    # credential dropping on both Arch and Void.
    "$ESCALATION_TOOL" mkdir -p /etc/pam.d
    cat <<EOF > /tmp/lemurs_pam
#%PAM-1.0
auth        required      pam_unix.so
account     required      pam_unix.so
account     required      pam_nologin.so
password    required      pam_unix.so
session     required      pam_unix.so
session     optional      pam_loginuid.so
session     optional      pam_limits.so
EOF
    "$ESCALATION_TOOL" mv /tmp/lemurs_pam /etc/pam.d/lemurs

    # ── Lemurs config ────────────────────────────────────
    # command = "startx" ensures X is started after login;
    # without this Lemurs defaults to running the user's shell.
    "$ESCALATION_TOOL" mkdir -p /etc/lemurs
    cat <<EOF > /tmp/lemurs_conf
tty = 7
command = "startx"
EOF
    "$ESCALATION_TOOL" mv /tmp/lemurs_conf /etc/lemurs/config.toml

    # ── Service file ─────────────────────────────────────
    if [ "$PACKAGER" = "xbps-install" ]; then
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
        # ── Wrapper script ───────────────────────────────
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

        # ── systemd service ──────────────────────────────
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
        "$ESCALATION_TOOL" systemctl mask getty@tty7.service
    fi

    ok "Lemurs service configured"
}

activate_lemurs_service() {
    info "Activating Lemurs service..."
    case "$PACKAGER" in
        xbps-install)
            if [ -d "/etc/sv/lemurs" ]; then
                "$ESCALATION_TOOL" ln -sf "/etc/sv/lemurs" "/var/service/"
                ok "Lemurs service enabled (runit)"
            else
                err "Service directory /etc/sv/lemurs not found"
                exit 1
            fi
            ;;
        pacman)
            "$ESCALATION_TOOL" systemctl daemon-reload
            "$ESCALATION_TOOL" systemctl enable --now lemurs.service
            ok "Lemurs service enabled (systemd)"
            ;;
    esac
}

configure_user() {
    local groups="wheel,video,audio"
    getent group bluetooth &>/dev/null && groups="$groups,bluetooth"
    getent group input &>/dev/null && groups="$groups,input"

    info "Adding $TARGET_USER to groups: $groups"
    if [ "$ESCALATION_TOOL" = "eval" ]; then
        usermod -aG "$groups" "$TARGET_USER" 2>/dev/null || warn "Failed to modify groups"
    else
        "$ESCALATION_TOOL" usermod -aG "$groups" "$TARGET_USER" 2>/dev/null || warn "Failed to modify groups"
    fi

    if [ ! -f "$TARGET_HOME/.xinitrc" ]; then
        info "Creating ~/.xinitrc fallback..."
        echo 'exec dwm' > "$TARGET_HOME/.xinitrc"
        ok "Created ~/.xinitrc (fallback: dwm)"
    fi
}

main() {
    checkEnv
    install_lemurs_pkg
    setup_lemurs_service
    activate_lemurs_service
    configure_user
    echo ""
    ok "Lemurs installation complete!"
    echo ""
    info "Reboot or switch to tty7 to see the login prompt."
    echo ""
}

main "$@"
