#!/usr/bin/env bash
#
# tiny11maker.sh — Linux / macOS bash script to build a tiny11 Windows image
#
# Based on ntdevlabs tiny11builder. Trims down a Windows 11 ISO by removing
# bloatware apps, Edge, OneDrive, disabling telemetry/sponsored apps, and
# applying hardware requirement bypasses (TPM, SecureBoot, RAM, CPU).
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/tiny11_$(date +%Y%m%d_%H%M%S).log"

# ---------- Colors & Formatting ----------
BOLD=$'\033[1m'
GREEN=$'\033[0;32m'
BLUE=$'\033[0;34m'
YELLOW=$'\033[1;33m'
RED=$'\033[0;31m'
NC=$'\033[0m' # No Color

# ---------- Logging Helpers ----------
log()  { printf "${GREEN}[+]${NC} %s %s\n" "$(date +%H:%M:%S)" "$*"; }
info() { printf "${BLUE}[*]${NC} %s %s\n" "$(date +%H:%M:%S)" "$*"; }
warn() { printf "${YELLOW}[!]${NC} %s WARN: %s\n" "$(date +%H:%M:%S)" "$*" >&2; }
die()  { printf "${RED}[x]${NC} %s ERR:  %s\n" "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
${BOLD}tiny11maker.sh — Build a debloated Windows 11 image on Linux / macOS${NC}

Usage:
  ./tiny11maker.sh [options]

Options:
  -s SOURCE       Path to Windows 11 ISO file, OR an extracted directory
                  containing sources/, boot/, efi/, etc.
                  (If omitted, you will be prompted interactively)
  -o OUTPUT_ISO   Destination path for the generated ISO.
                  Default: ./tiny11.iso
  -i INDEX        Image index inside install.wim to keep (e.g., 1, 6).
                  (If omitted, available SKUs will be listed for selection)
  -w WORK_DIR     Scratch/work directory (needs ~25-30 GB of free space).
                  Default: ./tiny11-work
  -y              Non-interactive mode (assume Yes to all confirmation prompts).
  -h              Show this help message.

Examples:
  ./tiny11maker.sh -s Win11_x64.iso
  ./tiny11maker.sh -s Win11_x64.iso -i 6 -o ~/Desktop/tiny11.iso -y

EOF
}

SOURCE=""
OUTPUT_ISO="$SCRIPT_DIR/tiny11.iso"
INDEX=""
WORK_DIR="$SCRIPT_DIR/tiny11-work"
ASSUME_YES=0

while getopts "s:o:i:w:yh" opt; do
  case "$opt" in
    s) SOURCE="$OPTARG" ;;
    o) OUTPUT_ISO="$OPTARG" ;;
    i) INDEX="$OPTARG" ;;
    w) WORK_DIR="$OPTARG" ;;
    y) ASSUME_YES=1 ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

confirm() {
  if (( ASSUME_YES )); then return 0; fi
  read -r -p "$1 [y/N] " ans
  [[ "$ans" =~ ^[yY]([eE][sS])?$ ]]
}

find_file_ci() {
  local dir="$1"
  local target="$2"
  if [[ -d "$dir" ]]; then
    find "$dir" -maxdepth 1 -iname "$target" 2>/dev/null | head -n 1
  fi
}

apply_hive() {
  local hive_file="$1" json_file="$2"
  if [[ -z "$hive_file" || ! -f "$hive_file" ]]; then
    warn "Hive file not found, skipping: ${hive_file:-<empty>}"
    return 0
  fi
  python3 "$SCRIPT_DIR/tiny11_hive.py" "$hive_file" < "$json_file"
}

# ---------- Detect Distro and Package Manager ----------
detect_pkg_mgr_install_cmd() {
  local os_id=""
  if [[ -f /run/host/os-release ]]; then
    os_id="$(grep -E '^ID=' /run/host/os-release | cut -d= -f2 | tr -d '"' || true)"
  elif [[ -f /etc/os-release ]]; then
    os_id="$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"' || true)"
  fi

  if [[ "$os_id" =~ ^(fedora|rhel|centos|rocky|almalinux)$ ]] || command -v dnf >/dev/null 2>&1; then
    echo "sudo dnf install wimlib-utils hivex 7zip xorriso python3"
  elif [[ "$os_id" =~ ^(ubuntu|debian|linuxmint|pop)$ ]] || command -v apt-get >/dev/null 2>&1; then
    echo "sudo apt update && sudo apt install wimtools libhivex-bin 7zip xorriso python3"
  elif [[ "$os_id" =~ ^(arch|manjaro|endeavouros)$ ]] || command -v pacman >/dev/null 2>&1; then
    echo "sudo pacman -S wimlib hivex 7zip xorriso python"
  elif [[ "$os_id" =~ ^(opensuse|sles)$ ]] || command -v zypper >/dev/null 2>&1; then
    echo "sudo zypper install wimtools hivex 7zip xorriso python3"
  elif command -v brew >/dev/null 2>&1; then
    echo "brew install wimlib hivex 7zip xorriso python3"
  else
    echo "Fedora:  sudo dnf install wimlib-utils hivex 7zip xorriso
  Ubuntu:  sudo apt install wimtools libhivex-bin 7zip xorriso
  Arch:    sudo pacman -S wimlib hivex 7zip xorriso"
  fi
}

# ---------- Check Dependencies ----------
MISSING_TOOLS=()

# Check wimlib-imagex
if ! command -v wimlib-imagex >/dev/null 2>&1; then
  MISSING_TOOLS+=("wimlib-imagex (wimlib/wimtools)")
fi

# Check xorriso
if ! command -v xorriso >/dev/null 2>&1; then
  MISSING_TOOLS+=("xorriso")
fi

# Check 7z / 7zz / 7za
SEVENZ=""
for cmd in 7z 7zz 7za; do
  if command -v "$cmd" >/dev/null 2>&1; then
    SEVENZ="$cmd"
    break
  fi
done

if [[ -z "$SEVENZ" ]]; then
  MISSING_TOOLS+=("7z or 7zz (7zip / p7zip)")
fi

# Check python3
if ! command -v python3 >/dev/null 2>&1; then
  MISSING_TOOLS+=("python3")
fi

# Check tiny11_hive.py
if [[ ! -f "$SCRIPT_DIR/tiny11_hive.py" ]]; then
  die "Helper script 'tiny11_hive.py' not found in $SCRIPT_DIR."
fi

# Check if libhivex is discoverable by python
if command -v python3 >/dev/null 2>&1; then
  if ! python3 -c "
import sys
sys.path.insert(0, '$SCRIPT_DIR')
from tiny11_hive import find_libhivex
if not find_libhivex():
    sys.exit(1)
" >/dev/null 2>&1; then
    MISSING_TOOLS+=("libhivex (package: hivex / libhivex-bin)")
  fi
fi

if (( ${#MISSING_TOOLS[@]} > 0 )); then
  printf "${RED}Missing required dependencies:${NC}\n" >&2
  for t in "${MISSING_TOOLS[@]}"; do
    printf "  - %s\n" "$t" >&2
  done
  printf "\nYou can install the required tools with:\n" >&2
  printf "  ${BOLD}%s${NC}\n\n" "$(detect_pkg_mgr_install_cmd)" >&2
  exit 1
fi

# ---------- Interactive Source Prompt ----------
if [[ -z "$SOURCE" ]]; then
  printf "${BOLD}Please enter the path to the Windows 11 ISO or extracted directory:${NC}\n> "
  read -r SOURCE
fi

# Expand tilde or relative path
SOURCE="${SOURCE/#\~/$HOME}"
if [[ ! -e "$SOURCE" ]]; then
  die "Source path does not exist: $SOURCE"
fi

# Normalize paths
case "$WORK_DIR" in
  /*) : ;;
  *)  WORK_DIR="$(pwd)/$WORK_DIR" ;;
esac

case "$OUTPUT_ISO" in
  /*) : ;;
  *)  OUTPUT_ISO="$(pwd)/$OUTPUT_ISO" ;;
esac

TINY_DIR="$WORK_DIR/tiny11"
SCRATCH_DIR="$WORK_DIR/scratchdir"
APPLY_DIR="$SCRATCH_DIR/install"
BOOT_APPLY_DIR="$SCRATCH_DIR/boot"

# Check available disk space in work directory parent
WORK_PARENT="$(dirname "$WORK_DIR")"
mkdir -p "$WORK_PARENT"
AVAIL_KB=$(df -k "$WORK_PARENT" | awk 'NR==2 {print $4}')
AVAIL_GB=$(( AVAIL_KB / 1024 / 1024 ))
if (( AVAIL_GB < 15 )); then
  warn "Free disk space in $(dirname "$WORK_DIR") is only ~${AVAIL_GB} GB. Recommended is at least 25-30 GB."
fi

INSTALL_WIM="$TINY_DIR/sources/install.wim"
INSTALL_ESD="$TINY_DIR/sources/install.esd"
BOOT_WIM="$TINY_DIR/sources/boot.wim"

# Check if previous processed install image exists
SKIP_INSTALL_WIM=0
if [[ -f "$TINY_DIR/sources/install.swm" || -f "$TINY_DIR/sources/install.wim" ]]; then
  if [[ -f "$WORK_DIR/sw.json" ]]; then
    if confirm "Previous debloated install image found in work directory. Resume from boot.wim / ISO creation?"; then
      SKIP_INSTALL_WIM=1
    fi
  fi
fi

# Prepare work directory
if (( ! SKIP_INSTALL_WIM )); then
  if [[ -d "$TINY_DIR" || -d "$SCRATCH_DIR" ]]; then
    if confirm "Work directory already has previous files. Clean and start fresh?"; then
      rm -rf "$TINY_DIR" "$SCRATCH_DIR"
    else
      die "Please choose another work directory with -w <dir> or clean $WORK_DIR."
    fi
  fi
  mkdir -p "$TINY_DIR" "$SCRATCH_DIR"
fi

# Tee output to log
exec > >(tee -a "$LOG_FILE") 2>&1

log "=========================================================="
log "   tiny11 builder for Linux / macOS"
log "=========================================================="
info "Source      : $SOURCE"
info "Output ISO  : $OUTPUT_ISO"
info "Work Dir    : $WORK_DIR"
info "7z Tool     : $SEVENZ"
info "Log File    : $LOG_FILE"
log "=========================================================="

# Ensure autounattend.xml is present
if [[ ! -f "$SCRIPT_DIR/autounattend.xml" ]]; then
  info "Downloading autounattend.xml from repository..."
  curl -fsSL -o "$SCRIPT_DIR/autounattend.xml" \
    https://raw.githubusercontent.com/ntdevlabs/tiny11builder/refs/heads/main/autounattend.xml
fi

if (( ! SKIP_INSTALL_WIM )); then
  # ---------- Extract / Copy Source ----------
  if [[ -f "$SOURCE" ]]; then
    log "Extracting ISO to working directory using $SEVENZ (this might take a couple minutes)..."
    "$SEVENZ" x -y -o"$TINY_DIR" "$SOURCE" >/dev/null
  elif [[ -d "$SOURCE" ]]; then
    log "Copying source directory to working directory..."
    if command -v rsync >/dev/null 2>&1; then
      rsync -a "$SOURCE"/ "$TINY_DIR"/
    else
      cp -R "$SOURCE"/ "$TINY_DIR"/
    fi
  fi

  # Ensure files are writable
  chmod -R u+w "$TINY_DIR" 2>/dev/null || true

  if [[ ! -f "$BOOT_WIM" ]]; then
    die "sources/boot.wim not found in source image."
  fi

  if [[ ! -f "$INSTALL_WIM" && ! -f "$INSTALL_ESD" ]]; then
    die "Neither install.wim nor install.esd found in sources/."
  fi

# Handle ESD -> WIM conversion if necessary
if [[ ! -f "$INSTALL_WIM" && -f "$INSTALL_ESD" ]]; then
  log "Found install.esd, converting to install.wim..."
  wimlib-imagex info "$INSTALL_ESD"
  while [[ -z "$INDEX" ]] || ! wimlib-imagex info "$INSTALL_ESD" "$INDEX" >/dev/null 2>&1; do
    read -r -p "Enter the image index to convert: " INDEX
  done
  log "Exporting index $INDEX from install.esd to install.wim (this will take some time)..."
  wimlib-imagex export "$INSTALL_ESD" "$INDEX" "$INSTALL_WIM" --compress=LZX --check
  rm -f "$INSTALL_ESD"
fi

# List available images in install.wim
log "Available Windows editions in install.wim:"
wimlib-imagex info "$INSTALL_WIM"

while [[ -z "$INDEX" ]] || ! wimlib-imagex info "$INSTALL_WIM" "$INDEX" >/dev/null 2>&1; do
  read -r -p "Please enter the image index you want to build (e.g. 1, 6): " INDEX
done
info "Selected image index: $INDEX"

# ---------- Extract install.wim Image ----------
mkdir -p "$APPLY_DIR"
log "Extracting Windows image (index $INDEX) to scratchdir..."
wimlib-imagex apply "$INSTALL_WIM" "$INDEX" "$APPLY_DIR"

ARCH="$(wimlib-imagex info "$INSTALL_WIM" "$INDEX" | awk -F': *' '/^Architecture/ {print $2; exit}')"
info "Detected architecture: ${ARCH:-unknown}"

# ---------- Remove Provisioned AppX Packages ----------
log "Removing provisioned AppX bloatware packages..."

APP_PREFIXES=(
  AppUp.IntelManagementandSecurityStatus
  Clipchamp.Clipchamp
  DolbyLaboratories.DolbyAccess
  DolbyLaboratories.DolbyDigitalPlusDecoderOEM
  Microsoft.BingNews
  Microsoft.BingSearch
  Microsoft.BingWeather
  Microsoft.Copilot
  Microsoft.Windows.CrossDevice
  Microsoft.GamingApp
  Microsoft.GetHelp
  Microsoft.Getstarted
  Microsoft.Microsoft3DViewer
  Microsoft.MicrosoftOfficeHub
  Microsoft.MicrosoftSolitaireCollection
  Microsoft.MicrosoftStickyNotes
  Microsoft.MixedReality.Portal
  Microsoft.MSPaint
  Microsoft.Office.OneNote
  Microsoft.OfficePushNotificationUtility
  Microsoft.OutlookForWindows
  Microsoft.Paint
  Microsoft.People
  Microsoft.PowerAutomateDesktop
  Microsoft.SkypeApp
  Microsoft.StartExperiencesApp
  Microsoft.Todos
  Microsoft.Wallet
  Microsoft.Windows.DevHome
  Microsoft.Windows.Copilot
  Microsoft.Windows.Teams
  Microsoft.WindowsAlarms
  Microsoft.WindowsCamera
  microsoft.windowscommunicationsapps
  Microsoft.WindowsFeedbackHub
  Microsoft.WindowsMaps
  Microsoft.WindowsSoundRecorder
  Microsoft.WindowsTerminal
  Microsoft.Xbox.TCUI
  Microsoft.XboxApp
  Microsoft.XboxGameOverlay
  Microsoft.XboxGamingOverlay
  Microsoft.XboxIdentityProvider
  Microsoft.XboxSpeechToTextOverlay
  Microsoft.YourPhone
  Microsoft.ZuneMusic
  Microsoft.ZuneVideo
  MicrosoftCorporationII.MicrosoftFamily
  MicrosoftCorporationII.QuickAssist
  MSTeams
  MicrosoftTeams
  Microsoft.549981C3F5F10
)

pkg_matches() {
  local name="$1"
  local lc_name
  lc_name="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
  for p in "${APP_PREFIXES[@]}"; do
    local lc_p
    lc_p="$(printf '%s' "$p" | tr '[:upper:]' '[:lower:]')"
    if [[ "$lc_name" == "${lc_p}_"* || "$lc_name" == *"${lc_p}"* ]]; then
      return 0
    fi
  done
  return 1
}

APPX_DIR="$APPLY_DIR/Program Files/WindowsApps"
if [[ -d "$APPX_DIR" ]]; then
  while IFS= read -r -d '' pkg_dir; do
    pkg_name="$(basename "$pkg_dir")"
    if pkg_matches "$pkg_name"; then
      info "  Removing AppX package: $pkg_name"
      rm -rf "$pkg_dir"
    fi
  done < <(find "$APPX_DIR" -mindepth 1 -maxdepth 1 -type d -print0)
fi

# ---------- Remove Microsoft Edge & OneDrive ----------
log "Removing Microsoft Edge..."
rm -rf "$APPLY_DIR/Program Files (x86)/Microsoft/Edge" \
       "$APPLY_DIR/Program Files (x86)/Microsoft/EdgeUpdate" \
       "$APPLY_DIR/Program Files (x86)/Microsoft/EdgeCore" \
       "$APPLY_DIR/Windows/System32/Microsoft-Edge-Webview" 2>/dev/null || true

log "Removing OneDrive setup..."
rm -f "$APPLY_DIR/Windows/System32/OneDriveSetup.exe" 2>/dev/null || true

# ---------- Remove Scheduled Telemetry Tasks ----------
log "Removing telemetry & CEIP scheduled task definitions..."
TASKS_DIR="$APPLY_DIR/Windows/System32/Tasks"
rm -f "$TASKS_DIR/Microsoft/Windows/Application Experience/Microsoft Compatibility Appraiser" 2>/dev/null || true
rm -rf "$TASKS_DIR/Microsoft/Windows/Customer Experience Improvement Program" 2>/dev/null || true
rm -f "$TASKS_DIR/Microsoft/Windows/Application Experience/ProgramDataUpdater" 2>/dev/null || true
rm -f "$TASKS_DIR/Microsoft/Windows/Chkdsk/Proxy" 2>/dev/null || true
rm -f "$TASKS_DIR/Microsoft/Windows/Windows Error Reporting/QueueReporting" 2>/dev/null || true

# ---------- Copy Autounattend to Sysprep ----------
mkdir -p "$APPLY_DIR/Windows/System32/Sysprep"
cp -f "$SCRIPT_DIR/autounattend.xml" "$APPLY_DIR/Windows/System32/Sysprep/autounattend.xml"

# ---------- Registry Tweaks on install.wim ----------
log "Applying registry tweaks and bypasses to install.wim..."


CONFIG_DIR="$APPLY_DIR/Windows/System32/config"
USER_DEFAULT_DIR="$APPLY_DIR/Users/Default"

SW_HIVE="$(find_file_ci "$CONFIG_DIR" "SOFTWARE")"
SYS_HIVE="$(find_file_ci "$CONFIG_DIR" "SYSTEM")"
DEFAULT_HIVE="$(find_file_ci "$CONFIG_DIR" "DEFAULT")"
NTUSER_HIVE="$(find_file_ci "$USER_DEFAULT_DIR" "NTUSER.DAT")"

# SOFTWARE hive tweaks
cat > "$WORK_DIR/sw.json" <<'EOF'
[
  {"action":"set_dword","path":"Policies\\Microsoft\\Windows\\CloudContent","name":"DisableWindowsConsumerFeatures","value":1},
  {"action":"set_dword","path":"Policies\\Microsoft\\Windows\\CloudContent","name":"DisableConsumerAccountStateContent","value":1},
  {"action":"set_dword","path":"Policies\\Microsoft\\Windows\\CloudContent","name":"DisableCloudOptimizedContent","value":1},
  {"action":"set_sz","path":"Microsoft\\PolicyManager\\current\\device\\Start","name":"ConfigureStartPins","value":"{\"pinnedList\": [{}]}"},
  {"action":"set_dword","path":"Policies\\Microsoft\\PushToInstall","name":"DisablePushToInstall","value":1},
  {"action":"set_dword","path":"Policies\\Microsoft\\MRT","name":"DontOfferThroughWUAU","value":1},
  {"action":"set_dword","path":"Microsoft\\Windows\\CurrentVersion\\OOBE","name":"BypassNRO","value":1},
  {"action":"set_dword","path":"Microsoft\\Windows\\CurrentVersion\\ReserveManager","name":"ShippedWithReserves","value":0},
  {"action":"set_dword","path":"Policies\\Microsoft\\Windows\\Windows Chat","name":"ChatIcon","value":3},
  {"action":"set_dword","path":"Policies\\Microsoft\\Windows\\OneDrive","name":"DisableFileSyncNGSC","value":1},
  {"action":"set_dword","path":"Policies\\Microsoft\\Windows\\DataCollection","name":"AllowTelemetry","value":0},
  {"action":"set_dword","path":"Microsoft\\Windows\\CurrentVersion\\WindowsUpdate\\Orchestrator\\UScheduler_Oobe\\OutlookUpdate","name":"workCompleted","value":1},
  {"action":"set_dword","path":"Microsoft\\Windows\\CurrentVersion\\WindowsUpdate\\Orchestrator\\UScheduler\\OutlookUpdate","name":"workCompleted","value":1},
  {"action":"set_dword","path":"Microsoft\\Windows\\CurrentVersion\\WindowsUpdate\\Orchestrator\\UScheduler\\DevHomeUpdate","name":"workCompleted","value":1},
  {"action":"del_key","path":"Microsoft\\WindowsUpdate\\Orchestrator\\UScheduler_Oobe\\OutlookUpdate"},
  {"action":"del_key","path":"Microsoft\\WindowsUpdate\\Orchestrator\\UScheduler_Oobe\\DevHomeUpdate"},
  {"action":"set_dword","path":"Policies\\Microsoft\\Windows\\WindowsCopilot","name":"TurnOffWindowsCopilot","value":1},
  {"action":"set_dword","path":"Policies\\Microsoft\\Edge","name":"HubsSidebarEnabled","value":0},
  {"action":"set_dword","path":"Policies\\Microsoft\\Windows\\Explorer","name":"DisableSearchBoxSuggestions","value":1},
  {"action":"set_dword","path":"Policies\\Microsoft\\Teams","name":"DisableInstallation","value":1},
  {"action":"set_dword","path":"Policies\\Microsoft\\Windows\\Windows Mail","name":"PreventRun","value":1},
  {"action":"del_key","path":"WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Microsoft Edge"},
  {"action":"del_key","path":"WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Microsoft Edge Update"}
]
EOF
apply_hive "$SW_HIVE" "$WORK_DIR/sw.json"

# SYSTEM hive tweaks
cat > "$WORK_DIR/sys.json" <<'EOF'
[
  {"action":"set_dword","path":"Setup\\LabConfig","name":"BypassCPUCheck","value":1},
  {"action":"set_dword","path":"Setup\\LabConfig","name":"BypassRAMCheck","value":1},
  {"action":"set_dword","path":"Setup\\LabConfig","name":"BypassSecureBootCheck","value":1},
  {"action":"set_dword","path":"Setup\\LabConfig","name":"BypassStorageCheck","value":1},
  {"action":"set_dword","path":"Setup\\LabConfig","name":"BypassTPMCheck","value":1},
  {"action":"set_dword","path":"Setup\\MoSetup","name":"AllowUpgradesWithUnsupportedTPMOrCPU","value":1},
  {"action":"set_dword","path":"ControlSet001\\Control\\BitLocker","name":"PreventDeviceEncryption","value":1},
  {"action":"set_dword","path":"ControlSet001\\Services\\dmwappushservice","name":"Start","value":4}
]
EOF
apply_hive "$SYS_HIVE" "$WORK_DIR/sys.json"

# DEFAULT hive tweaks
cat > "$WORK_DIR/default.json" <<'EOF'
[
  {"action":"set_dword","path":"Control Panel\\UnsupportedHardwareNotificationCache","name":"SV1","value":0},
  {"action":"set_dword","path":"Control Panel\\UnsupportedHardwareNotificationCache","name":"SV2","value":0}
]
EOF
apply_hive "$DEFAULT_HIVE" "$WORK_DIR/default.json"

# NTUSER hive tweaks
cat > "$WORK_DIR/ntuser.json" <<'EOF'
[
  {"action":"set_dword","path":"Control Panel\\UnsupportedHardwareNotificationCache","name":"SV1","value":0},
  {"action":"set_dword","path":"Control Panel\\UnsupportedHardwareNotificationCache","name":"SV2","value":0},
  {"action":"set_dword","path":"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\ContentDeliveryManager","name":"OemPreInstalledAppsEnabled","value":0},
  {"action":"set_dword","path":"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\ContentDeliveryManager","name":"PreInstalledAppsEnabled","value":0},
  {"action":"set_dword","path":"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\ContentDeliveryManager","name":"SilentInstalledAppsEnabled","value":0},
  {"action":"set_dword","path":"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\ContentDeliveryManager","name":"ContentDeliveryAllowed","value":0},
  {"action":"set_dword","path":"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\ContentDeliveryManager","name":"FeatureManagementEnabled","value":0},
  {"action":"set_dword","path":"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\ContentDeliveryManager","name":"PreInstalledAppsEverEnabled","value":0},
  {"action":"set_dword","path":"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\ContentDeliveryManager","name":"SoftLandingEnabled","value":0},
  {"action":"set_dword","path":"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\ContentDeliveryManager","name":"SubscribedContentEnabled","value":0},
  {"action":"set_dword","path":"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\ContentDeliveryManager","name":"SubscribedContent-310093Enabled","value":0},
  {"action":"set_dword","path":"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\ContentDeliveryManager","name":"SubscribedContent-338388Enabled","value":0},
  {"action":"set_dword","path":"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\ContentDeliveryManager","name":"SubscribedContent-338389Enabled","value":0},
  {"action":"set_dword","path":"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\ContentDeliveryManager","name":"SubscribedContent-338393Enabled","value":0},
  {"action":"set_dword","path":"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\ContentDeliveryManager","name":"SubscribedContent-353694Enabled","value":0},
  {"action":"set_dword","path":"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\ContentDeliveryManager","name":"SubscribedContent-353696Enabled","value":0},
  {"action":"set_dword","path":"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\ContentDeliveryManager","name":"SystemPaneSuggestionsEnabled","value":0},
  {"action":"del_key","path":"Software\\Microsoft\\Windows\\CurrentVersion\\ContentDeliveryManager\\Subscriptions"},
  {"action":"del_key","path":"Software\\Microsoft\\Windows\\CurrentVersion\\ContentDeliveryManager\\SuggestedApps"},
  {"action":"set_dword","path":"Software\\Microsoft\\Windows\\CurrentVersion\\AdvertisingInfo","name":"Enabled","value":0},
  {"action":"set_dword","path":"Software\\Microsoft\\Windows\\CurrentVersion\\Privacy","name":"TailoredExperiencesWithDiagnosticDataEnabled","value":0},
  {"action":"set_dword","path":"Software\\Microsoft\\Speech_OneCore\\Settings\\OnlineSpeechPrivacy","name":"HasAccepted","value":0},
  {"action":"set_dword","path":"Software\\Microsoft\\Input\\TIPC","name":"Enabled","value":0},
  {"action":"set_dword","path":"Software\\Microsoft\\InputPersonalization","name":"RestrictImplicitInkCollection","value":1},
  {"action":"set_dword","path":"Software\\Microsoft\\InputPersonalization","name":"RestrictImplicitTextCollection","value":1},
  {"action":"set_dword","path":"Software\\Microsoft\\InputPersonalization\\TrainedDataStore","name":"HarvestContacts","value":0},
  {"action":"set_dword","path":"Software\\Microsoft\\Personalization\\Settings","name":"AcceptedPrivacyPolicy","value":0},
  {"action":"set_dword","path":"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced","name":"TaskbarMn","value":0}
]
EOF
apply_hive "$NTUSER_HIVE" "$WORK_DIR/ntuser.json"

# ---------- Re-capture install.wim ----------
NEW_INSTALL_WIM="$TINY_DIR/sources/install_new.wim"
log "Capturing trimmed image to new install.wim (LZMS compression)..."
wimlib-imagex capture "$APPLY_DIR" "$NEW_INSTALL_WIM" \
  "tiny11" "tiny11 streamlined Windows 11 image" \
  --compress=LZMS

rm -f "$INSTALL_WIM"
mv "$NEW_INSTALL_WIM" "$INSTALL_WIM"
rm -rf "$APPLY_DIR"

# Check if install.wim exceeds 4 GiB (ISO 9660 limit) and split if necessary
INSTALL_WIM_SIZE=$(stat -c%s "$INSTALL_WIM" 2>/dev/null || stat -f%z "$INSTALL_WIM")
ISO_FILE_LIMIT=$((4 * 1024 * 1024 * 1024 - 1))
  if (( INSTALL_WIM_SIZE > ISO_FILE_LIMIT )); then
    info "install.wim is $((INSTALL_WIM_SIZE / 1024 / 1024)) MiB (> 4 GiB)."
    log "Splitting install.wim into install.swm parts for standard compatibility..."
    wimlib-imagex split "$INSTALL_WIM" "$TINY_DIR/sources/install.swm" 3800
    rm -f "$INSTALL_WIM"
    info "Split files created in sources/:"
    ls -lh "$TINY_DIR/sources/"install*.swm
  fi
fi

# ---------- Modify boot.wim (Setup Image) ----------
log "Applying hardware bypasses to boot.wim (index 2)..."
if [[ ! -d "$BOOT_APPLY_DIR/Windows/System32" ]]; then
  mkdir -p "$BOOT_APPLY_DIR"
  wimlib-imagex apply "$BOOT_WIM" 2 "$BOOT_APPLY_DIR"
fi

BOOT_CONFIG_DIR="$BOOT_APPLY_DIR/Windows/System32/config"
BOOT_USER_DIR="$BOOT_APPLY_DIR/Users/Default"

BOOT_SYS_HIVE="$(find_file_ci "$BOOT_CONFIG_DIR" "SYSTEM")"
BOOT_DEFAULT_HIVE="$(find_file_ci "$BOOT_CONFIG_DIR" "DEFAULT")"
BOOT_NTUSER_HIVE="$(find_file_ci "$BOOT_USER_DIR" "NTUSER.DAT")"

cat > "$WORK_DIR/boot_sys.json" <<'EOF'
[
  {"action":"set_dword","path":"Setup\\LabConfig","name":"BypassCPUCheck","value":1},
  {"action":"set_dword","path":"Setup\\LabConfig","name":"BypassRAMCheck","value":1},
  {"action":"set_dword","path":"Setup\\LabConfig","name":"BypassSecureBootCheck","value":1},
  {"action":"set_dword","path":"Setup\\LabConfig","name":"BypassStorageCheck","value":1},
  {"action":"set_dword","path":"Setup\\LabConfig","name":"BypassTPMCheck","value":1},
  {"action":"set_dword","path":"Setup\\MoSetup","name":"AllowUpgradesWithUnsupportedTPMOrCPU","value":1}
]
EOF

cat > "$WORK_DIR/boot_default.json" <<'EOF'
[
  {"action":"set_dword","path":"Control Panel\\UnsupportedHardwareNotificationCache","name":"SV1","value":0},
  {"action":"set_dword","path":"Control Panel\\UnsupportedHardwareNotificationCache","name":"SV2","value":0}
]
EOF

[[ -n "$BOOT_DEFAULT_HIVE" ]] && apply_hive "$BOOT_DEFAULT_HIVE" "$WORK_DIR/boot_default.json"
[[ -n "$BOOT_NTUSER_HIVE" ]]  && apply_hive "$BOOT_NTUSER_HIVE"  "$WORK_DIR/boot_default.json"
[[ -n "$BOOT_SYS_HIVE" ]]     && apply_hive "$BOOT_SYS_HIVE"     "$WORK_DIR/boot_sys.json"

log "Updating boot.wim with modified registry hives..."
update_cmds="$WORK_DIR/boot_update.txt"
: > "$update_cmds"
if [[ -n "$BOOT_DEFAULT_HIVE" && -f "$BOOT_DEFAULT_HIVE" ]]; then
  echo "add \"$BOOT_DEFAULT_HIVE\" \"Windows/System32/config/$(basename "$BOOT_DEFAULT_HIVE")\"" >> "$update_cmds"
fi
if [[ -n "$BOOT_SYS_HIVE" && -f "$BOOT_SYS_HIVE" ]]; then
  echo "add \"$BOOT_SYS_HIVE\" \"Windows/System32/config/$(basename "$BOOT_SYS_HIVE")\"" >> "$update_cmds"
fi
if [[ -n "$BOOT_NTUSER_HIVE" && -f "$BOOT_NTUSER_HIVE" ]]; then
  echo "add \"$BOOT_NTUSER_HIVE\" \"Users/Default/$(basename "$BOOT_NTUSER_HIVE")\"" >> "$update_cmds"
fi

if [[ -s "$update_cmds" ]]; then
  wimlib-imagex update "$BOOT_WIM" 2 < "$update_cmds"
fi
rm -rf "$BOOT_APPLY_DIR"

# Copy autounattend.xml to root of ISO
cp -f "$SCRIPT_DIR/autounattend.xml" "$TINY_DIR/autounattend.xml"

# ---------- Create Bootable ISO with xorriso ----------
log "Creating bootable Windows 11 ISO with xorriso..."

ETFSBOOT="$TINY_DIR/boot/etfsboot.com"
EFISYS="$TINY_DIR/efi/microsoft/boot/efisys.bin"

if [[ ! -f "$ETFSBOOT" ]]; then
  die "BIOS boot file missing: $ETFSBOOT"
fi
if [[ ! -f "$EFISYS" ]]; then
  die "UEFI boot file missing: $EFISYS"
fi

ETFSBOOT_REL="${ETFSBOOT#"$TINY_DIR/"}"
EFISYS_REL="${EFISYS#"$TINY_DIR/"}"

xorriso -as mkisofs \
  -iso-level 3 \
  -full-iso9660-filenames \
  -J -joliet-long \
  -volid "TINY11" \
  -eltorito-boot "$ETFSBOOT_REL" \
  -no-emul-boot \
  -boot-load-size 8 \
  -boot-info-table \
  -eltorito-alt-boot \
  -eltorito-platform efi \
  -no-emul-boot \
  -eltorito-boot "$EFISYS_REL" \
  -isohybrid-gpt-basdat \
  -o "$OUTPUT_ISO" \
  "$TINY_DIR"

log "=========================================================="
log "${BOLD}${GREEN}tiny11 ISO creation successfully completed!${NC}"
info "Resulting ISO : $OUTPUT_ISO"
info "Size          : $(ls -lh "$OUTPUT_ISO" | awk '{print $5}')"
log "=========================================================="

# ---------- Cleanup ----------
if confirm "Clean up temporary work directory ($WORK_DIR)?"; then
  rm -rf "$WORK_DIR"
  log "Temporary work directory removed."
else
  info "Temporary work directory preserved at $WORK_DIR."
fi

log "Done!"
