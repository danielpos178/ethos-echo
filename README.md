# Ethos Echo

> **Ethos Echo** is a modern, modular, and aesthetic **Wayland desktop suite** built for **Arch Linux** and **Void Linux**. It pairs the high-performance **Umbriel** Wayland compositor with the native **Noctalia** desktop shell, the **Noctalia Greeter** (`greetd`), and the fast GPU-accelerated **Alacritty** terminal emulator—all harmonized around an authentic **Gruvbox Dark** color scheme.

---

## 📖 Table of Contents

- [Overview](#overview)
- [Components](#components)
- [Installation](#installation)
  - [Prerequisites](#prerequisites)
  - [Quick Start](#quick-start)
- [Keybindings](#keybindings)
- [Configuration](#configuration)
- [License](#license)
- [Contact](#contact)

---

## Overview

Ethos Echo provides dedicated, turnkey installation scripts (`install-umbriel.sh` for Arch Linux and `install-void.sh` for Void Linux) and cohesive configuration templates to set up a complete Wayland environment on fresh installations from the ground up:

- **Umbriel Compositor** – Built on C++23 and `wlroots`, featuring scrolling, dwindle, and master tiling layouts, independent workspaces per monitor, blur, shadows, and smooth window animations.
- **Noctalia Desktop Shell** – Native Wayland shell delivering a top status bar, dock, application launcher, quick-settings control center, notifications, and lock screen.
- **Noctalia Greeter & greetd** – Modern graphical login screen integrated with `greetd`, sharing the same visual language and color scheme.
- **Alacritty Terminal** – Fast, GPU-accelerated terminal pre-configured with the **Gruvbox Dark** palette and Meslo Nerd Fonts.
- **Full System Plumbing** – Automated GPU detection (AMD, Intel, NVIDIA), PipeWire audio stack, Bluetooth, NetworkManager, Polkit authentication agent, XDG portals, and Wayland session files.
- **Service Management** – Seamless integration with `systemd` (Arch) and `runit` (Void).

---

## Components

| Component | Role | Arch Linux (pacman/AUR) | Void Linux (xbps/Universal Repo) |
| :--- | :--- | :--- | :--- |
| **Umbriel** | Wayland Compositor | `umbriel-git` (AUR) | Compiled from source (Meson/Ninja) |
| **Noctalia** | Desktop Shell (Bar, Launcher, Control Center) | `noctalia` / `noctalia-git` | `noctalia` (Universal Repo) |
| **Noctalia Greeter** | Login Manager Greeter | `noctalia-greeter` + `greetd` | `noctalia-greeter` + `greetd` |
| **Alacritty** | Terminal Emulator | `alacritty` (Arch Extra) | `alacritty` (Void official) |
| **PipeWire Stack** | Audio & Media Routing | `pipewire`, `wireplumber` | `pipewire`, `wireplumber` |
| **Service Manager** | Init & Daemon Supervisor | `systemd` | `runit` (`/var/service/`) |
| **Theme** | Color Palette | Gruvbox Dark | Gruvbox Dark |

---

## Installation

### Prerequisites

- A fresh or existing **Arch Linux** or **Void Linux** installation (x86_64).
- A regular user account with `sudo` privileges (running as root is strictly prevented).
- An internet connection for downloading packages and source trees.

### Quick Start

1. **Clone the repository:**
   ```bash
   git clone https://github.com/Daniel1788/ethos-echo.git
   cd ethos-echo
   ```

2. **Run the installer:**
   You can run either the interactive auto-detecting launcher or the distro-specific script directly:

   - **Interactive Launcher (Auto-detects distribution):**
     ```bash
     chmod +x install.sh
     ./install.sh
     ```

   - **Arch Linux standalone:**
     ```bash
     chmod +x install-umbriel.sh
     ./install-umbriel.sh
     ```

   - **Void Linux standalone:**
     ```bash
     chmod +x install-void.sh
     ./install-void.sh
     ```

3. **Reboot:**
   Once the installer finishes, reboot your system:
   ```bash
   sudo reboot
   ```
   You will be greeted by the **Noctalia Greeter** login screen. Log in to start your Umbriel session!

---

## Keybindings

Default shortcuts configured in `~/.config/umbriel/config.toml`:

| Keybinding | Action |
| :--- | :--- |
| `Mod + Return` | Open Alacritty Terminal (Gruvbox Dark) |
| `Mod + Shift + Return` | Open Alacritty Terminal |
| `Mod + d` | Toggle Noctalia App Launcher |
| `Mod + s` | Toggle Noctalia Control Center |
| `Mod + n` | Toggle Noctalia Notifications |
| `Mod + Escape` | Toggle Power / Session Menu |
| `Mod + q` | Close Focused Window |
| `Mod + Space` / `Mod + t` | Toggle Floating Window |
| `Mod + f` | Toggle Fullscreen |
| `Mod + o` | Toggle Overview |
| `Mod + h / j / k / l` | Focus Left / Down / Up / Right |
| `Mod + Shift + h / j / k / l` | Move Window Left / Down / Up / Right |
| `Mod + r` | Cycle Layout (scrolling, dwindle, master) |
| `Mod + 1 .. 9` | Switch to Workspace 1–9 |
| `Mod + Shift + 1 .. 9` | Move Window to Workspace 1–9 |
| `XF86AudioRaiseVolume` | Volume Up +5% |
| `XF86AudioLowerVolume` | Volume Down -5% |
| `XF86AudioMute` | Toggle Audio Mute |
| `XF86MonBrightnessUp` | Brightness Up +5% |
| `XF86MonBrightnessDown` | Brightness Down -5% |

*(Note: `Mod` is `Super` / `Windows` key).*

---

## Configuration

Customizable configuration templates are organized in the `configs/` directory:

- `configs/umbriel/config.toml` – Umbriel compositor settings, keybinds, and layout rules.
- `configs/umbriel/umbriel.desktop` – Wayland session entry installed to `/usr/share/wayland-sessions/`.
- `configs/alacritty/` – Alacritty configuration (`alacritty.toml`, `gruvbox-dark.toml`, `keybinds.toml`).
- `configs/noctalia/palettes/` – Gruvbox Dark palette specification for Noctalia.

---

## License

This project is licensed under the **MIT License** – see the [LICENSE](LICENSE) file for details.

---

## Contact

- **Author**: Daniel (GitHub: [Daniel1788](https://github.com/Daniel1788))
- **Issues**: Open an issue on GitHub for bugs or feature requests.
