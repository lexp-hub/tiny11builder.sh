# tiny11builder.sh

> **Note:** This repository is a native **Linux and macOS fork** of [ntdevlabs/tiny11builder](https://github.com/ntdevlabs/tiny11builder).
>
> While upstream Tiny11Builder requires Windows, Microsoft DISM, and WinUI 3, this fork provides a **native Linux GUI (GTK4 + Libadwaita)** and an automated **Bash CLI tool (`tiny11maker.sh`)** to build stripped-down, debloated Tiny11 images directly on Linux without Windows or virtual machines.

---

## Features

- **Native Linux GUI**: Modern GTK4 + Libadwaita interface designed for GNOME and Linux desktop environments.
- **No Windows Host Required**: Built entirely with open-source tools (`wimlib-imagex`, `libhivex`, `xorriso`, `7z`).
- **Deep Bloatware Removal**: Strips out Cortana, Copilot, Teams, Xbox, Solitaire, News, Weather, Clipchamp, Edge, OneDrive, and sponsored UWP apps.
- **Hardware Checks Bypass**: Injects registry bypasses for TPM 2.0, SecureBoot, RAM (4 GB requirement), and unsupported CPU checks.
- **Local Account Support**: Applies `BypassNRO` so you can install Windows 11 with an offline local account without forced Microsoft Account sign-in.
- **Recipe and Preset System**: Compatible with upstream JSON recipes (`recipes/`) and provides quick presets (Standard, Minimal / Core, Conservative).
- **UEFI and BIOS Dual-Boot ISO**: Produces standard ISO 9660 images with automated FAT32 split handling (`install.swm`) if the WIM exceeds 4 GiB.

---

## Getting Started

### 1. Install Prerequisites

Install the required utilities for your distribution:

* **Fedora / RHEL / CentOS**:
  ```bash
  sudo dnf install wimlib-utils hivex 7zip xorriso python3 python3-gobject libadwaita gtk4
  ```

* **Ubuntu / Debian / Linux Mint / Pop!_OS**:
  ```bash
  sudo apt update && sudo apt install wimtools libhivex-bin 7zip xorriso python3 python3-gi gir1.2-adw-1 gir1.2-gtk-4.0
  ```

* **Arch Linux / Manjaro / EndeavourOS**:
  ```bash
  sudo pacman -S wimlib hivex 7zip xorriso python python-gobject libadwaita gtk4
  ```

---

## Graphical User Interface (GUI)

Launch the native Libadwaita application:

```bash
chmod +x tiny11gui.py tiny11maker.sh tiny11_hive.py
./tiny11gui.py
```

### Desktop Menu Integration
To launch Tiny11 Builder directly from your desktop application launcher (GNOME Dash, KDE Kickoff, etc.):

```bash
mkdir -p ~/.local/share/applications ~/.local/share/icons/hicolor/scalable/apps
cp data/io.github.lexp_hub.tiny11builder.svg ~/.local/share/icons/hicolor/scalable/apps/
cp data/io.github.lexp_hub.tiny11builder.desktop ~/.local/share/applications/
update-desktop-database ~/.local/share/applications/
```

---

## Command Line Usage (`tiny11maker.sh`)

You can also run the builder directly from the terminal or in headless CI/CD scripts.

### Basic Interactive Mode:
```bash
./tiny11maker.sh
```

### Non-Interactive / Batch Mode:
```bash
./tiny11maker.sh -s /path/to/Win11_English_x64.iso -i 6 -o ~/Desktop/tiny11.iso -y
```

### Options and Flags:

| Option | Description |
|---|---|
| `-s, --source <path>` | Path to source Windows 11 ISO or extracted directory |
| `-o, --output <path>` | Destination path for output ISO (default: `./tiny11.iso`) |
| `-i, --index <number>` | Windows SKU edition index in `install.wim` (e.g., `1` for Home, `6` for Pro) |
| `-w, --work-dir <path>` | Temporary scratch directory (needs ~25-30 GB free space) |
| `-r, --recipe <path>` | Load configuration options from a JSON recipe file |
| `-y, --assume-yes` | Assume Yes to all confirmation prompts (headless mode) |
| `--keep-bloat` | Keep provisioned AppX bloatware packages |
| `--keep-edge` | Keep Microsoft Edge browser |
| `--keep-onedrive` | Keep OneDrive setup |
| `--keep-copilot` | Keep Microsoft Copilot |
| `--keep-telemetry` | Keep CEIP diagnostic telemetry tasks |
| `--no-bypass-hw` | Do not apply TPM 2.0 / CPU / RAM / SecureBoot bypasses |
| `--no-bypass-nro` | Do not enable offline local account creation |
| `--no-autounattend` | Do not inject `autounattend.xml` answer file |

### Using Recipes:
```bash
# Standard Tiny11 configuration
./tiny11maker.sh -s Win11_x64.iso -r recipes/tiny11-standard.json -y

# Conservative (keeps Edge and OneDrive, removes promotional bloatware)
./tiny11maker.sh -s Win11_x64.iso -r recipes/tiny11-conservative.json -y

# Minimal Core
./tiny11maker.sh -s Win11_x64.iso -r recipes/tiny11-core-minimal.json -y
```

---

## What is Removed:

<table>
  <thead>
    <tr>
      <th>Removed Applications (AppX)</th>
      <th>System Services and Tweaks</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td>
        <ul>
          <li>Clipchamp</li>
          <li>Bing News and Weather</li>
          <li>Xbox Game Bar and Gaming App</li>
          <li>GetHelp and GetStarted</li>
          <li>Microsoft Solitaire Collection</li>
          <li>Microsoft Teams / Chat</li>
          <li>OneDrive Setup</li>
          <li>Microsoft Edge and EdgeUpdate</li>
          <li>Microsoft Copilot</li>
          <li>Outlook and Mail Integrations</li>
          <li>Feedback Hub and Suggestions</li>
          <li>PowerAutomate Desktop</li>
          <li>Cortana and Voice Data Collection</li>
        </ul>
      </td>
      <td>
        <ul>
          <li>Hardware requirements checks (TPM, CPU, RAM, SecureBoot)</li>
          <li>OOBE mandatory Microsoft Account sign-in (BypassNRO)</li>
          <li>Telemetry and Customer Experience Improvement (CEIP) tasks</li>
          <li>Start Menu sponsored recommendations and advertisements</li>
          <li>Cloud content delivery manager suggestions</li>
          <li>Automatic BitLocker device encryption on fresh install</li>
        </ul>
      </td>
    </tr>
  </tbody>
</table>

---

## Credits and License

- Upstream Windows Project: [ntdevlabs/tiny11builder](https://github.com/ntdevlabs/tiny11builder) by **ntdev** ([Patreon](http://patreon.com/ntdev) | [PayPal](http://paypal.me/ntdev2))
- Linux Port and GTK4 / Libadwaita GUI: [lexp-hub/tiny11builder.sh](https://github.com/lexp-hub/tiny11builder.sh)
- License: MIT
