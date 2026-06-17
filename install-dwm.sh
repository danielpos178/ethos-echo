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
        warn "Can't write to $GITPATH — proceeding anyway"
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
    checkPackageManager 'pacman xbps-install'
    checkCurrentDirectoryWritable
    checkSuperUser
    detectTargetUser
}

install_packages() {
    local missing=0
    case "$PACKAGER" in
        pacman)
            "$ESCALATION_TOOL" "$PACKAGER" -S --needed --noconfirm "$@" 2>/dev/null || {
                warn "Batch install failed, trying individually..."
                for pkg in "$@"; do
                    if ! "$ESCALATION_TOOL" "$PACKAGER" -S --needed --noconfirm "$pkg" 2>/dev/null; then
                        warn "Package not found (skipping): $pkg"
                        missing=1
                    fi
                done
            }
            ;;
        xbps-install)
            "$ESCALATION_TOOL" "$PACKAGER" -S -y "$@" 2>/dev/null || {
                warn "Batch install failed, trying individually..."
                for pkg in "$@"; do
                    if ! "$ESCALATION_TOOL" "$PACKAGER" -S -y "$pkg" 2>/dev/null; then
                        warn "Package not found in repos (skipping): $pkg"
                        missing=1
                    fi
                done
            }
            ;;
    esac
    return $missing
}

# Local package install helper removed — upstream dwm-gossamer installer is used instead.
# The installer repo (dwm-gossamer) contains distro-aware package installation logic.


makeDWM() {
    local share_dir="$TARGET_HOME/.local/share"
    local repo_dir="$share_dir/dwm-gossamer"

    mkdir -p "$share_dir"

    if [ ! -d "$repo_dir" ]; then
        info "Cloning dwm-gossamer repository..."
        git clone https://github.com/danielpos178/dwm-gossamer.git "$repo_dir" || {
            err "Failed to clone repository"
            exit 1
        }
    else
        info "dwm-gossamer directory exists, pulling latest..."
        git -C "$repo_dir" pull || warn "git pull failed, continuing with existing code"
    fi

    # Run upstream repo installer (let dwm-gossamer handle distro-specific installs).
    # For ARM systems prefer install-arm.sh if present.
    if [ "$ARCH" = "aarch64" ] || [[ "$ARCH" == arm* ]]; then
        if [ -x "$repo_dir/install-arm.sh" ] || [ -f "$repo_dir/install-arm.sh" ]; then
            info "Running dwm-gossamer/install-arm.sh (upstream installer)..."
            # Run using escalation tool so the upstream installer can perform privileged actions
            if ! "$ESCALATION_TOOL" bash "$repo_dir/install-arm.sh"; then
                            warn "Upstream ARM installer failed or was skipped"
                        fi
        else
            warn "No install-arm.sh found in upstream repository — skipping upstream installer"
        fi
    else
        if [ -x "$repo_dir/install.sh" ] || [ -f "$repo_dir/install.sh" ]; then
            info "Running dwm-gossamer/install.sh (upstream installer)..."
            if ! "$ESCALATION_TOOL" bash "$repo_dir/install.sh"; then
                            warn "Upstream installer failed or was skipped"
                        fi
        else
            warn "No install.sh found in upstream repository — skipping upstream installer"
        fi
    fi

    # Upstream installer builds dwm; build slstatus here in case upstream didn't.
    info "Building slstatus..."
    "$ESCALATION_TOOL" make -C "$repo_dir/slstatus" clean install || {
        err "Failed to build slstatus"
    }

    mkdir -p "$TARGET_HOME/Pictures/backgrounds/"
    if [ -f "$repo_dir/background.jpg" ]; then
        cp "$repo_dir/background.jpg" "$TARGET_HOME/Pictures/backgrounds/"
    fi
}

setup_flatpak() {
    if ! command_exists flatpak; then
        warn "flatpak not found, skipping Flatpak setup"
        return 1
    fi

    info "Configuring Flathub remote..."
    "$ESCALATION_TOOL" flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo 2>/dev/null
    ok "Flathub remote configured"
}

install_flatpak_apps() {
    if ! command_exists flatpak; then
        warn "flatpak not found, skipping Flatpak app installations"
        return 1
    fi

    info "Installing Zen Browser via Flatpak..."
    "$ESCALATION_TOOL" flatpak install -y flathub io.github.zen_browser.zen 2>/dev/null && ok "Zen Browser installed" || warn "Failed to install Zen Browser"

    info "Installing Zed Editor via Flatpak..."
    "$ESCALATION_TOOL" flatpak install -y flathub dev.zed.Zed 2>/dev/null && ok "Zed Editor installed" || warn "Failed to install Zed Editor"
}

install_nerd_font() {
    FONT_NAME="MesloLGS Nerd Font Mono"
    FONT_DIR="$TARGET_HOME/.local/share/fonts"
    FONT_URL="https://github.com/ryanoasis/nerd-fonts/releases/latest/download/Meslo.zip"

    if fc-list 2>/dev/null | grep -qi "Meslo"; then
        ok "Meslo Nerd-fonts already installed"
        return 0
    fi

    info "Installing Meslo Nerd-fonts..."
    mkdir -p "$FONT_DIR"
    TEMP_DIR=$(mktemp -d)
    curl -sSLo "$TEMP_DIR/Meslo.zip" "$FONT_URL"
    unzip -q "$TEMP_DIR/Meslo.zip" -d "$TEMP_DIR"
    mkdir -p "$FONT_DIR/$FONT_NAME"
    mv "$TEMP_DIR"/*.ttf "$FONT_DIR/$FONT_NAME/"
    fc-cache -fv
    rm -rf "$TEMP_DIR"
    ok "Meslo Nerd-fonts installed"
}

clone_config_folders() {
    local repo_dir="$TARGET_HOME/.local/share/dwm-gossamer"
    local local_gitpath="${GITPATH:-$(dirname "$(realpath "$0")")}"

    mkdir -p "$TARGET_HOME/.config"
    mkdir -p "$TARGET_HOME/.local/bin"

    # --- Copy dwm-gossamer runtime scripts (non-dot files) ---
    if [ -d "$repo_dir/scripts" ]; then
        mkdir -p "$TARGET_HOME/.local/bin"
        # Copy non-dot files only (avoid copying the repository's .xinitrc)
        for f in "$repo_dir/scripts/"*; do
            [ -e "$f" ] || continue
            cp -rf "$f" "$TARGET_HOME/.local/bin/" || warn "Failed to copy $f"
        done
        ok "Scripts copied to ~/.local/bin"
    fi

    # --- Deploy ethos-echo configs (do not overwrite existing user files) ---
    if [ -d "$local_gitpath/configs" ]; then
        for cfg in "$local_gitpath/configs/"*/; do
            [ -d "$cfg" ] || continue
            cfg_name=$(basename "$cfg")
            dst="$TARGET_HOME/.config/$cfg_name"
            mkdir -p "$dst"
            # Copy non-destructively: do not overwrite existing files
            cp -r -n "$cfg"* "$dst/" 2>/dev/null || true
            # Ensure ownership
            chown -R "$TARGET_USER:$TARGET_USER" "$dst" 2>/dev/null || true
            ok "Installed config: $cfg_name -> $dst"
        done
    else
        warn "No ethos-echo configs directory found at $local_gitpath/configs"
    fi

    # Install session entry (dwm.desktop) from ethos-echo configs if available
    if [ -f "$local_gitpath/configs/dwm/dwm.desktop" ]; then
        $ESCALATION_TOOL install -Dm644 "$local_gitpath/configs/dwm/dwm.desktop" /usr/share/xsessions/dwm.desktop 2>/dev/null && ok "Installed session entry: /usr/share/xsessions/dwm.desktop" || warn "Failed to install /usr/share/xsessions/dwm.desktop"
    fi

    # Setup user's .xinitrc from ethos-echo template (if missing)
    if [ -f "$local_gitpath/configs/dwm/xinitrc" ]; then
        if [ -f "$TARGET_HOME/.xinitrc" ]; then
            ok "~/.xinitrc already exists — skipping"
        else
            if [ "$ESCALATION_TOOL" = "eval" ]; then
                cp "$local_gitpath/configs/dwm/xinitrc" "$TARGET_HOME/.xinitrc" || warn "Failed to copy xinitrc template"
            else
                $ESCALATION_TOOL install -Dm644 "$local_gitpath/configs/dwm/xinitrc" "$TARGET_HOME/.xinitrc" 2>/dev/null || warn "Failed to install xinitrc template"
            fi
            $ESCALATION_TOOL chown "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.xinitrc" 2>/dev/null || true
            ok "Installed ~/.xinitrc from ethos-echo template"
        fi
    fi

    # --- Polybar fonts from dwm-gossamer repo (if present) ---
    mkdir -p "$TARGET_HOME/.local/share/fonts"
    if [ -d "$repo_dir/polybar/fonts" ]; then
        cp -r "$repo_dir/polybar/fonts/"* "$TARGET_HOME/.local/share/fonts/"
        fc-cache -fv
        ok "Polybar icon fonts installed"
    fi

    # --- Deploy dwm-gossamer config directory (legacy) ---
    if [ -d "$repo_dir/config" ]; then
        for dir in "$repo_dir/config/"*/; do
            [ -d "$dir" ] || continue
            dir_name=$(basename "$dir")
            # Only copy if target doesn't already exist to avoid overwriting user's configs
            if [ ! -d "$TARGET_HOME/.config/$dir_name" ]; then
                cp -r "$dir" "$TARGET_HOME/.config/"
                chown -R "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.config/$dir_name" 2>/dev/null || true
                ok "Cloned $dir_name to ~/.config/"
            else
                ok "Config $dir_name already exists in ~/.config/ — skipping"
            fi
        done
    else
        warn "Config directory not found in cloned dwm-gossamer repository"
    fi

    # --- Lemurs templates / installer (ethos-echo owns lemurs) ---
    if [ -d "$local_gitpath/lemurs" ]; then
        # If we have a procedural installer, prefer it
        if [ -f "$local_gitpath/install-lemurs.sh" ]; then
            info "Found local install-lemurs.sh — running to install lemurs and deploy templates"
            bash "$local_gitpath/install-lemurs.sh" || warn "install-lemurs.sh failed or was skipped"
        else
            # If lemurs binary exists, deploy templates to system paths
            if command -v lemurs &>/dev/null; then
                info "Deploying Lemurs templates from $local_gitpath/lemurs"
                $ESCALATION_TOOL make -C "$local_gitpath/lemurs" install 2>/dev/null && ok "Lemurs templates installed" || warn "Failed to install Lemurs templates via make"
            else
                warn "Lemurs templates present but 'lemurs' not installed — run install-lemurs.sh or install lemurs package first"
            fi
        fi
    fi
}

activate_services() {
    info "Activating core services..."

    case "$PACKAGER" in
        pacman)
            install_packages dbus networkmanager bluez
            for svc in dbus NetworkManager bluetooth; do
                "$ESCALATION_TOOL" systemctl enable --now "$svc" 2>/dev/null && ok "Enabled $svc" || warn "Failed to enable $svc"
            done
            ;;
        xbps-install)
            install_packages dbus NetworkManager bluez
            for svc in dbus NetworkManager bluetoothd; do
                if [ -d "/etc/sv/$svc" ]; then
                    if [ ! -L "/var/service/$svc" ]; then
                        "$ESCALATION_TOOL" ln -sf "/etc/sv/$svc" "/var/service/"
                        ok "Enabled $svc"
                    else
                        ok "$svc already enabled"
                    fi
                else
                    warn "Service $svc not found in /etc/sv/"
                fi
            done
            ;;
    esac
}

configure_user() {
    local groups="wheel,video,audio"
    getent group bluetooth &>/dev/null && groups="$groups,bluetooth"
    getent group input &>/dev/null && groups="$groups,input"

    info "Adding $TARGET_USER to groups: $groups"
    if [ "$ESCALATION_TOOL" = "eval" ]; then
        usermod -aG "$groups" "$TARGET_USER" 2>/dev/null || warn "Failed to modify groups (running as root directly)"
    else
        "$ESCALATION_TOOL" usermod -aG "$groups" "$TARGET_USER" 2>/dev/null || warn "Failed to modify groups"
    fi

    if command_exists xdg-user-dirs-update; then
        if [ "$ESCALATION_TOOL" = "eval" ]; then
            su - "$TARGET_USER" -c "xdg-user-dirs-update" 2>/dev/null || true
        else
            "$ESCALATION_TOOL" -u "$TARGET_USER" xdg-user-dirs-update 2>/dev/null || true
        fi
    fi

    info "Setting up ~/.xinitrc for DWM..."
    # Do not overwrite an existing .xinitrc
    if [ -f "$TARGET_HOME/.xinitrc" ]; then
        ok "~/.xinitrc already exists — skipping"
    else
        # Prefer ethos-echo template
        if [ -f "$GITPATH/configs/dwm/xinitrc" ]; then
            if [ "$ESCALATION_TOOL" = "eval" ]; then
                cp "$GITPATH/configs/dwm/xinitrc" "$TARGET_HOME/.xinitrc" || warn "Failed to copy xinitrc template"
            else
                $ESCALATION_TOOL install -Dm644 "$GITPATH/configs/dwm/xinitrc" "$TARGET_HOME/.xinitrc" 2>/dev/null || warn "Failed to install xinitrc template"
            fi
        else
            # Fallback to repository's .xinitrc if present
            repo_dir="$TARGET_HOME/.local/share/dwm-gossamer"
            if [ -f "$repo_dir/scripts/.xinitrc" ]; then
                if [ "$ESCALATION_TOOL" = "eval" ]; then
                    cp "$repo_dir/scripts/.xinitrc" "$TARGET_HOME/.xinitrc" || warn "Failed to copy xinitrc from repo"
                else
                    $ESCALATION_TOOL install -Dm644 "$repo_dir/scripts/.xinitrc" "$TARGET_HOME/.xinitrc" 2>/dev/null || warn "Failed to install xinitrc from repo"
                fi
            else
                # Last-resort: create minimal xinitrc
                if [ "$ESCALATION_TOOL" = "eval" ]; then
                    printf '%s\n' '#!/bin/sh' '' '[ -f "$HOME/Pictures/backgrounds/background.jpg" ] && feh --bg-fill "$HOME/Pictures/backgrounds/background.jpg" 2>/dev/null &' '' 'exec dwm' > "$TARGET_HOME/.xinitrc"
                else
                    tmp=$(mktemp)
                    printf '%s\n' '#!/bin/sh' '' '[ -f "$HOME/Pictures/backgrounds/background.jpg" ] && feh --bg-fill "$HOME/Pictures/backgrounds/background.jpg" 2>/dev/null &' '' 'exec dwm' > "$tmp"
                    $ESCALATION_TOOL install -Dm644 "$tmp" "$TARGET_HOME/.xinitrc" 2>/dev/null || warn "Failed to create .xinitrc"
                    rm -f "$tmp"
                fi
            fi
        fi

        # Ensure ownership belongs to target user
        if [ "$ESCALATION_TOOL" = "eval" ]; then
            chown "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.xinitrc" 2>/dev/null || true
        else
            $ESCALATION_TOOL chown "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.xinitrc" 2>/dev/null || true
        fi

        ok "Created ~/.xinitrc"
    fi
}

main() {
    checkEnv
    # Prefer running the upstream repo installer which handles distro-specific installs (including Void via xbps-install).
    # We'll clone the repo inside makeDWM which will run the upstream installer; call makeDWM which includes that.
    makeDWM

    install_nerd_font
    setup_flatpak
    install_flatpak_apps
    clone_config_folders

    # ── Display manager / Lemurs handling ─────────────────────────
    currentdm=""
    for dm in lemurs sddm gdm; do command -v "$dm" &>/dev/null && { currentdm="$dm"; break; }; done

    if [ -n "$currentdm" ]; then
        ok "Display manager already installed: $currentdm"
    else
        info "No display manager found — attempting to install Lemurs login manager..."
        GITPATH="$(dirname "$(realpath "$0")")"

        # Prefer the local install-lemurs.sh (ethos-echo) if present
        if [ -f "$GITPATH/install-lemurs.sh" ]; then
            info "Running $GITPATH/install-lemurs.sh to install and configure Lemurs"
            # Run as a separate process so the lemurs installer can detect the system and escalate privileges itself
            bash "$GITPATH/install-lemurs.sh" || warn "install-lemurs.sh failed or was skipped"
        elif [ -d "$GITPATH/lemurs" ]; then
            info "Deploying Lemurs templates from $GITPATH/lemurs (make install)"
            "$ESCALATION_TOOL" make -C "$GITPATH/lemurs" install 2>/dev/null && ok "Lemurs templates installed" || warn "Failed to install Lemurs templates via make"

            # Try to enable Lemurs service for systemd or runit
            if command -v systemctl &>/dev/null; then
                "$ESCALATION_TOOL" systemctl daemon-reload
                "$ESCALATION_TOOL" systemctl enable --now lemurs.service 2>/dev/null && ok "Lemurs service enabled (systemd)" || warn "Failed to enable Lemurs systemd service"
            elif [ -d "/etc/sv" ]; then
                if [ -d "/etc/sv/lemurs" ]; then
                    "$ESCALATION_TOOL" ln -sf "/etc/sv/lemurs" "/var/service/" 2>/dev/null && ok "Lemurs service enabled (runit)" || warn "Failed to enable Lemurs runit service"
                else
                    warn "Runit service directory /etc/sv/lemurs not found"
                fi
            fi
        else
            warn "No Lemurs installer or templates found in ethos-echo — skipping Lemurs setup"
        fi
    fi

    activate_services
    configure_user
    echo ""
    ok "DWM installation process complete!"
    echo ""
    info "Log out and select DWM from your display manager, or run: startx"
    echo ""
}

main "$@"
