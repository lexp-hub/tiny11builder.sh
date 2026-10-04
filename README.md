# tiny11builder.sh

> **Note:** This repository is a **fork** of the original [ntdevlabs/tiny11builder](https://github.com/ntdevlabs/tiny11builder).
>
> It adds native **Linux** (and macOS) support with **`tiny11maker.sh`**, enabling you to build streamlined, debloated Tiny11 images without requiring a Windows host or Microsoft DISM.

---

## 🐧 Linux / macOS Instructions (`tiny11maker.sh`)

`tiny11maker.sh` is a native Bash port of `tiny11maker.ps1`. It performs the same image modifications and bloatware removals using open-source utilities:

* **`wimlib-imagex`**: Mounts, applies, compresses (`LZMS`), and updates WIM archives (`install.wim`, `boot.wim`).
* **`tiny11_hive.py` / `libhivex`**: Surgically applies offline registry edits and hardware bypasses (TPM, CPU, RAM, Secure Boot, OOBE local accounts).
* **`7z` / `7zz`**: Extracts the source Windows 11 ISO in user-space without needing root/loop mounts.
* **`xorriso`**: Repacks the final dual-bootable ISO (Legacy BIOS and UEFI).
* **Split WIM handling**: Automatically splits `install.wim` into `install.swm` files if it exceeds the 4 GiB ISO 9660 limit, ensuring FAT32 USB compatibility.

### Prerequisites

Install the required tools for your distribution:

* **Fedora / RHEL**:
  ```bash
  sudo dnf install wimlib-utils hivex 7zip xorriso python3
  ```

* **Ubuntu / Debian**:
  ```bash
  sudo apt update && sudo apt install wimtools libhivex-bin 7zip xorriso python3
  ```

* **Arch Linux**:
  ```bash
  sudo pacman -S wimlib hivex 7zip xorriso python
  ```

* **macOS (Homebrew)**:
  ```bash
  brew install wimlib hivex 7zip xorriso python3
  ```

### Usage

Make sure the script is executable:
```bash
chmod +x tiny11maker.sh tiny11_hive.py
```

#### Interactive Mode:
Simply run the script. It will prompt you for the ISO path and the Windows edition to keep:
```bash
./tiny11maker.sh
```

#### Non-Interactive / CLI Options:
```bash
./tiny11maker.sh -s /path/to/Win11_English_x64.iso -o ./tiny11.iso
```

Available flags:
* `-s <source>`: Path to Windows 11 ISO or extracted directory.
* `-o <output>`: Output ISO destination (default: `./tiny11.iso`).
* `-i <index>`: Image SKU index from `install.wim` (e.g., `1` for Home, `6` for Pro).
* `-w <work_dir>`: Temporary scratch folder (needs ~25-30 GB free space; default: `./tiny11-work`).
* `-y`: Assume Yes to all confirmation prompts.
* `-h`: Display help.

---

## 🪟 Windows Instructions (`tiny11maker.ps1`)

If you are running on Windows, you can use the original PowerShell scripts:

1. Download Windows 11 from the [Microsoft website](https://www.microsoft.com/software-download/windows11) or [Rufus](https://github.com/pbatard/rufus).
2. Mount the downloaded ISO image using Windows Explorer.
3. Open **PowerShell 5.1** as Administrator.
4. Set execution policy:
   ```powershell
   Set-ExecutionPolicy Bypass -Scope Process
   ```
5. Run the script:
   ```powershell
   .\tiny11maker.ps1 -ISO <letter> -SCRATCH <letter>
   ```

---

## ⚠️ Script versions:
- **tiny11maker.sh** : Native Linux/macOS bash script for building tiny11 without Windows.
- **tiny11maker.ps1** : Standard Windows PowerShell script for regular use (serviceable image).
- **tiny11coremaker.ps1** : Windows PowerShell core builder for ultra-stripped testing images (non-serviceable).

---

## What is removed:
<table>
  <tbody>
    <tr>
      <th>Tiny11maker</th>
      <th>Tiny11coremaker</th>
    </tr>
    <tr>
      <td>
        <ul>
          <li>Clipchamp</li>
          <li>News</li>
          <li>Weather</li>
          <li>Xbox</li>
          <li>GetHelp</li>
          <li>GetStarted</li>
          <li>Office Hub</li>
          <li>Solitaire</li>
          <li>PeopleApp</li>
          <li>PowerAutomate</li>
          <li>ToDo</li>
          <li>Alarms</li>
          <li>Mail and Calendar</li>
          <li>Feedback Hub</li>
          <li>Maps</li>
          <li>Sound Recorder</li>
          <li>Your Phone</li>
          <li>Media Player</li>
          <li>QuickAssist</li>
          <li>Internet Explorer</li>
          <li>Tablet PC Math</li>
          <li>Edge</li>
          <li>OneDrive</li>
        </ul>
      </td>
      <td>
        <ul>
          <li>all from regular tiny +</li>
          <li>Windows Component Store (WinSxS)</li>
          <li>Windows Defender (only disabled, can be enabled back if needed)</li>
          <li>Windows Update (wouldn't work without WinSxS, enabling it would put the system in a state of failure)</li>
          <li>WinRE</li>
        </ul>
      </td>
    </tr>
  </tbody>
</table>

---

## Credits & Upstream
* Original creator and project: [ntdevlabs/tiny11builder](https://github.com/ntdevlabs/tiny11builder)
* Original author: **ntdev** ([Patreon](http://patreon.com/ntdev) | [PayPal](http://paypal.me/ntdev2) | [Ko-fi](http://ko-fi.com/ntdev))
