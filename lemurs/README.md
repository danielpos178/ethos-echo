# Lemurs — dwm-gossamer

A modern TUI (Terminal User Interface) login manager using `lemurs` with a Nord colour palette, custom theme, and the MesloLGS NF font.

No extra dependencies beyond what `install.sh` installs
(`lemurs`, `ttf-meslo-nerd`, `pam`).

## Files

| File | Destination |
|------|-------------|
| `config.toml` | `/etc/lemurs/config.toml` |
| `xsetup.sh` | `/etc/lemurs/xsetup.sh` |
| `lemurs.service` | `/etc/systemd/system/lemurs.service` |
| `lemurs.pam` | `/etc/pam.d/lemurs` |
| `dwm-logo-bordered.png` | `/usr/share/pixmaps/dwm-gossamer-logo.png` |

## Install

The main `install.sh` handles this automatically. To apply manually:

```sh
sudo make -C "$REPO_DIR/lemurs" install
```

## Customisation

Edit `config.toml` before running `sudo make install`:

- **theme** — TUI theme (e.g., `default`, `dark`, `nord`)
- **font** — font family and size for the login screen
- **session** — default session (e.g., `dwm`)
- **background** — path to a wallpaper image
- **show_hostname** — toggle showing hostname on login screen
- **show_clock** — toggle showing time on login screen

## Usage

After installation:

1. Log out and select `lemurs` from the session menu
2. Or start with: `lemurs`

## Keybindings

Inside lemurs:
- **Up/Down arrows** — Navigate users
- **Tab** — Focus password field
- **Enter** — Authenticate and start session
- **q** — Quit lemurs

## Notes

- Requires PAM for authentication
- Session scripts must be executable
- Works with or without systemd
- Supports X11/Wayland sessions
