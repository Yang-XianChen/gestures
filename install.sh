#!/usr/bin/env bash
set -euo pipefail

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

REPO="Yang-XianChen/gestures"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -d "$SCRIPT_DIR" ] && [ -w "$SCRIPT_DIR" ]; then
    LOCAL_BIN_DIR="$SCRIPT_DIR"
else
    LOCAL_BIN_DIR="${TMPDIR:-/tmp}/gestures-installer-$$"
    mkdir -p "$LOCAL_BIN_DIR"
fi
LOCAL_BIN="$LOCAL_BIN_DIR/gestures"
BIN_PATH="/usr/local/bin/gestures"
SERVICE_NAME="gestures.service"
SERVICE_DIR="$HOME/.config/systemd/user"
SERVICE_FILE="$SERVICE_DIR/$SERVICE_NAME"
SERVICE_DROPIN="$SERVICE_DIR/gestures.service.d/50-installer.conf"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
CONFIG_FILE="$CONFIG_HOME/gestures.kdl"
GNOME_EXT_UUID="disable-touchpad-swipe@local"
GNOME_EXT_SRC="$SCRIPT_DIR/extensions/$GNOME_EXT_UUID"

ASSUME_YES=false
DRY_RUN=false
UNINSTALL=false

usage() {
    cat <<'EOF'
Usage: ./install.sh [options]

Interactive installer for gestures.

Options:
  -y, --yes    Accept default answers (non-interactive where possible)
  -n, --dry-run, --simulate
               Show what would be done without changing the system
  -u, --uninstall
               Uninstall gestures and exit
  -h, --help   Show this help

Commands:
  check        Run diagnostics and exit
EOF
}

for arg in "$@"; do
    case "$arg" in
        -y|--yes) ASSUME_YES=true ;;
        -n|--dry-run|--simulate) DRY_RUN=true ;;
        -u|--uninstall) UNINSTALL=true ;;
        -h|--help) usage; exit 0 ;;
    esac
done

if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
else
    SUDO="sudo"
fi

CLEANUP_DIRS=""
cleanup() {
    for d in $CLEANUP_DIRS; do
        rm -rf "$d" 2>/dev/null || true
    done
}
trap cleanup EXIT

confirm() {
    local prompt="$1"; local default="${2:-y}"; local yn
    if $ASSUME_YES; then
        [ "$default" = "y" ] && return 0 || return 1
    fi
    local hint; hint="[Y/n]"; [ "$default" = "n" ] && hint="[y/N]"
    printf "${CYAN}${prompt} ${hint} ${NC}"
    read -r yn; yn="${yn:-$default}"
    case "$yn" in [Yy]*|yes|YES) return 0 ;; *) return 1 ;; esac
}

step()   { echo -e "\n${BOLD}${GREEN}==>${NC} ${BOLD}$*${NC}"; }
info()   { echo -e "${CYAN}  •${NC} $*"; }
warn()   { echo -e "${YELLOW}  ⚠${NC} $*"; }
err()    { echo -e "${RED}  ✗${NC} $*"; }
ok()     { echo -e "  ${GREEN}✓${NC} $*"; }
skip()   { echo -e "  ${YELLOW}○${NC} $*"; }

run() {
    if $DRY_RUN; then
        echo -e "${YELLOW}  [DRY-RUN]${NC} $*"
        return 0
    fi
    "$@"
}

download_file() {
    local url="$1" out="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fSL --retry 3 --retry-delay 2 "$url" -o "$out"
    elif command -v wget >/dev/null 2>&1; then
        wget -q --tries=3 "$url" -O "$out"
    else
        err "curl or wget is required to download the binary"
        return 1
    fi
}

install_gnome_extension() {
    if ! command -v gnome-shell >/dev/null 2>&1 || ! command -v gnome-extensions >/dev/null 2>&1; then
        skip "GNOME Shell not detected — skipping GNOME extension install"
        return 0
    fi

    info "GNOME Shell detected — installing helper extension $GNOME_EXT_UUID"

    local ext_src="$GNOME_EXT_SRC"
    local tmp_ext=""
    if [ ! -f "$ext_src/extension.js" ] || [ ! -f "$ext_src/metadata.json" ]; then
        info "Extension not bundled locally, downloading from repository..."
        tmp_ext=$(mktemp -d)
        CLEANUP_DIRS="$CLEANUP_DIRS $tmp_ext"
        if ! download_file "https://raw.githubusercontent.com/$REPO/main/extensions/$GNOME_EXT_UUID/extension.js" "$tmp_ext/extension.js" ||
           ! download_file "https://raw.githubusercontent.com/$REPO/main/extensions/$GNOME_EXT_UUID/metadata.json" "$tmp_ext/metadata.json"; then
            err "Failed to download GNOME extension"
            return 1
        fi
        ext_src="$tmp_ext"
    fi

    local ext_dir="${XDG_DATA_HOME:-$HOME/.local/share}/gnome-shell/extensions/$GNOME_EXT_UUID"
    run mkdir -p "$ext_dir"
    run install -m644 "$ext_src/extension.js" "$ext_dir/extension.js"
    run install -m644 "$ext_src/metadata.json" "$ext_dir/metadata.json"
    run gnome-extensions enable "$GNOME_EXT_UUID"

    if $DRY_RUN; then
        ok "(dry-run) GNOME extension would be installed and enabled"
    elif gnome-extensions info "$GNOME_EXT_UUID" 2>/dev/null | grep -q 'State: ACTIVE'; then
        ok "GNOME extension active: $GNOME_EXT_UUID"
    else
        warn "Extension installed but not active — log out/in or restart GNOME Shell"
    fi
}

echo -e "${BOLD}${GREEN}"
echo "  ╔══════════════════════════════════════════╗"
echo "  ║     Gestures - Touchpad Gesture Tool     ║"
echo "  ║         Interactive Installer            ║"
echo "  ╚══════════════════════════════════════════╝"
echo -e "${NC}"

# ── Diagnostic function ──
run_diagnostics() {
    local issues=0
    local indent="    "
    echo -e "\n${BOLD}${GREEN}=== Gestures Diagnostic Report ===${NC}\n"

    # Architecture
    echo -e "${BOLD}[Architecture]${NC}"
    echo "${indent}$(uname -m) / $(uname -s)"
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "${indent}$PRETTY_NAME"
    fi
    echo

    # Display server
    echo -e "${BOLD}[Display Server]${NC}"
    local ds="unknown"
    if [ -n "${WAYLAND_DISPLAY:-}" ]; then
        ds="Wayland (WAYLAND_DISPLAY=$WAYLAND_DISPLAY)"
    elif [ -n "${DISPLAY:-}" ]; then
        ds="X11 (DISPLAY=$DISPLAY)"
    elif [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; then
        ds="Wayland (XDG_SESSION_TYPE)"
    elif [ "${XDG_SESSION_TYPE:-}" = "x11" ]; then
        ds="X11 (XDG_SESSION_TYPE)"
    fi
    echo "${indent}$ds"
    echo

    # Runtime libraries
    echo -e "${BOLD}[Runtime Libraries]${NC}"
    for pkg in libudev1 libinput10 libxdo3; do
        if dpkg -s "$pkg" &>/dev/null; then
            echo -e "${indent}${GREEN}✓${NC} $pkg"
        else
            echo -e "${indent}${RED}✗${NC} $pkg  ${RED}NOT INSTALLED${NC}"
            ((issues++)) || true
        fi
    done

    # Key binaries
    echo
    echo -e "${BOLD}[Runtime Binaries]${NC}"
    for bin in ydotool ydotoold xdotool; do
        if command -v "$bin" &>/dev/null; then
            echo -e "${indent}${GREEN}✓${NC} $bin: $(command -v "$bin")"
        else
            echo -e "${indent}${YELLOW}○${NC} $bin: not found"
        fi
    done

    # ydotool socket
    local sock="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/.ydotool_socket"
    echo
    echo -e "${BOLD}[ydotool Socket]${NC}"
    if [ -S "$sock" ]; then
        local sock_perm; sock_perm=$(stat -c '%a %U' "$sock" 2>/dev/null || echo "?")
        echo -e "${indent}${GREEN}✓${NC} $sock ($sock_perm)"
    else
        echo -e "${indent}${RED}✗${NC} $sock ${RED}NOT FOUND${NC}"
        ((issues++)) || true
    fi

    # Input device access
    echo
    echo -e "${BOLD}[Input Devices]${NC}"
    if [ -r /dev/input ]; then
        local dev_count; dev_count=$(ls /dev/input/event* 2>/dev/null | wc -l)
        echo -e "${indent}${GREEN}✓${NC} /dev/input accessible ($dev_count event devices)"
    else
        echo -e "${indent}${RED}✗${NC} /dev/input ${RED}NOT READABLE${RC} (check group: input)"
        ((issues++)) || true
    fi
    # Check if user is in 'input' group
    if groups | grep -q '\binput\b'; then
        echo -e "${indent}${GREEN}✓${NC} user in 'input' group"
    else
        echo -e "${indent}${YELLOW}○${NC} user NOT in 'input' group (may need: sudo usermod -aG input \$USER)"
    fi

    # Rust toolchain
    echo
    echo -e "${BOLD}[Rust Toolchain]${NC}"
    if command -v rustc &>/dev/null; then
        echo -e "${indent}${GREEN}✓${NC} rustc $(rustc --version 2>/dev/null)"
        echo -e "${indent}${GREEN}✓${NC} cargo $(cargo --version 2>/dev/null)"
    else
        echo -e "${indent}${YELLOW}○${NC} Rust not installed (only needed for source builds)"
    fi

    # Build dependencies
    echo
    echo -e "${BOLD}[Build Dependencies]${NC}"
    for dep in build-essential pkg-config libudev-dev libinput-dev libxdo-dev; do
        if dpkg -s "$dep" &>/dev/null; then
            echo -e "${indent}${GREEN}✓${NC} $dep"
        else
            echo -e "${indent}${YELLOW}○${NC} $dep: not installed"
        fi
    done

    # Installation
    echo
    echo -e "${BOLD}[Installation]${NC}"
    if [ -f "$BIN_PATH" ]; then
        echo -e "${indent}${GREEN}✓${NC} binary: $BIN_PATH ($(du -h "$BIN_PATH" | cut -f1), $(file -b "$BIN_PATH" 2>/dev/null | head -c60))"
    else
        echo -e "${indent}${YELLOW}○${NC} binary not installed"
    fi
    if [ -f "$CONFIG_FILE" ]; then
        echo -e "${indent}${GREEN}✓${NC} config: $CONFIG_FILE"
    else
        echo -e "${indent}${YELLOW}○${NC} config not found"
    fi
    if [ -f "$SERVICE_FILE" ]; then
        echo -e "${indent}${GREEN}✓${NC} service file: $SERVICE_FILE"
    else
        echo -e "${indent}${YELLOW}○${NC} service file not found"
    fi

    # Services
    echo
    echo -e "${BOLD}[Systemd Services]${NC}"
    for svc in gestures ydotoold; do
        local state; state=$(systemctl --user is-active "${svc}.service" 2>/dev/null | tr -d '\n' || echo "inactive")
        local enabled; enabled=$(systemctl --user is-enabled "${svc}.service" 2>/dev/null | tr -d '\n' || echo "disabled")
        case "$state" in
            active)   echo -e "${indent}${GREEN}✓${NC} ${svc}.service: active (enabled=$enabled)" ;;
            inactive) echo -e "${indent}${YELLOW}○${NC} ${svc}.service: inactive (enabled=$enabled)" ;;
            failed)   echo -e "${indent}${RED}✗${NC} ${svc}.service: ${RED}FAILED${NC} (enabled=$enabled)"; ((issues++)) || true ;;
            *)        echo -e "${indent}${YELLOW}○${NC} ${svc}.service: $state" ;;
        esac
    done

    # Gestures process
    echo
    echo -e "${BOLD}[Process]${NC}"
    if pidof gestures &>/dev/null; then
        local pid; pid=$(pidof gestures)
        echo -e "${indent}${GREEN}✓${NC} gestures running (PID: $pid)"
        echo "${indent}  binary: $(readlink -f /proc/$pid/exe 2>/dev/null || echo '?')"
    else
        echo -e "${indent}${YELLOW}○${NC} gestures not running"
    fi

    # Recent log tail
    echo
    echo -e "${BOLD}[Recent Logs (last 10)]${NC}"
    if journalctl --user -u gestures -n 10 --no-pager 2>/dev/null | grep -q .; then
        journalctl --user -u gestures -n 10 --no-pager 2>/dev/null | while IFS= read -r line; do
            echo "${indent}$line"
        done
    else
        echo "${indent}(no logs found)"
    fi

    # Summary
    echo
    echo -e "${BOLD}[Summary]${NC}"
    if [ "$issues" -eq 0 ]; then
        echo -e "  ${GREEN}All checks passed.${NC}"
    else
        echo -e "  ${RED}$issues issue(s) found.${NC} Review items marked with ✗ above."
    fi
    echo
}

do_uninstall() {
    echo
    warn "This will remove all gestures files from your system."
    confirm "Proceed with uninstall?" y || { skip "Cancelled"; exit 0; }

    if systemctl --user is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        run systemctl --user stop "$SERVICE_NAME" 2>/dev/null || true
        ok "Service stopped"
    fi
    if systemctl --user is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
        run systemctl --user disable "$SERVICE_NAME" 2>/dev/null || true
        ok "Service disabled"
    fi
    run systemctl --user daemon-reload 2>/dev/null || true

    run rm -f "$SERVICE_FILE"
    run rm -rf "$SERVICE_DIR/gestures.service.d"
    ok "Service files removed"

    if [ -f "$BIN_PATH" ]; then
        run $SUDO rm -f "$BIN_PATH"
        ok "Removed $BIN_PATH"
    fi

    if [ -f "$CONFIG_FILE" ] && confirm "Remove config file $CONFIG_FILE?" n; then
        run rm -f "$CONFIG_FILE"
        ok "Config removed"
    else
        skip "Config kept: $CONFIG_FILE"
    fi

    [ -f "$LOCAL_BIN" ] && run rm -f "$LOCAL_BIN"
    [ -d "$SCRIPT_DIR/target" ] && run rm -rf "$SCRIPT_DIR/target" 2>/dev/null || true

    local ext_dir="${XDG_DATA_HOME:-$HOME/.local/share}/gnome-shell/extensions/$GNOME_EXT_UUID"
    if command -v gnome-extensions >/dev/null 2>&1 && [ -d "$ext_dir" ]; then
        run gnome-extensions disable "$GNOME_EXT_UUID" 2>/dev/null || true
        run rm -rf "$ext_dir"
        ok "GNOME extension removed"
    else
        skip "GNOME extension not installed — nothing to remove"
    fi

    echo
    echo -e "  ${GREEN}Uninstall complete.${NC}"
    exit 0
}

# ── Mode: check ──
if [ "${1:-}" = "check" ] || [ "${1:-}" = "--check" ] || [ "${1:-}" = "diagnose" ]; then
    run_diagnostics
    exit 0
fi

# ── Mode: uninstall ──
if $UNINSTALL; then
    do_uninstall
fi

# ── Detect existing installation ──
detect_existing() {
    local found=()
    [ -f "$BIN_PATH" ]       && found+=("binary")
    [ -f "$SERVICE_FILE" ]   && found+=("service")
    [ -f "$CONFIG_FILE" ]    && found+=("config")
    if systemctl --user is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        found+=("running")
    fi
    echo "${found[@]}"
}
EXISTING=$(detect_existing)

if [ -n "$EXISTING" ]; then
    echo
    warn "Gestures is already installed:"
    for item in $EXISTING; do
        case "$item" in
            binary)  echo "        binary : $BIN_PATH" ;;
            service) echo "        service: $SERVICE_FILE" ;;
            config)  echo "        config : $CONFIG_FILE" ;;
            running) echo "        status : service is running" ;;
        esac
    done
    echo
    echo "  What would you like to do?"
    echo "    [1] Reinstall / Upgrade"
    echo "    [2] Uninstall completely"
    echo "    [3] Run diagnostics"
    echo "    [4] Exit (do nothing)"
    printf "${CYAN}  Enter 1-4:${NC} "
    if $ASSUME_YES; then
        echo "1"
        ACTION=1
    else
        read -r ACTION; ACTION="${ACTION:-1}"
    fi
    case "$ACTION" in
        1) ok "Proceeding with reinstall..." ;;
        2) do_uninstall ;;
        3) run_diagnostics; echo; printf "${CYAN}  Press Enter to return to menu...${NC}"; read -r _ ;;
        4) skip "Exiting"; exit 0 ;;
        *) skip "Unknown option, exiting"; exit 1 ;;
    esac
fi

# ═══════════════════════════════════════════
step "1. Environment Check"
# ═══════════════════════════════════════════

ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  ASSET_ARCH="x86_64" ;;
    aarch64) ASSET_ARCH="aarch64" ;;
    *) err "Unsupported architecture: $ARCH"; exit 1 ;;
esac

if [ -f /etc/os-release ]; then
    . /etc/os-release
    case "$ID" in
        debian|ubuntu|linuxmint|pop|elementary|zorin|kali|parrot|deepin|uos)
            ok "OS: $PRETTY_NAME ($ARCH)" ;;
        *)  warn "Unrecognized distribution: $ID. Continuing anyway..." ;;
    esac
fi

info "--- Available Tools ---"
for tool in git curl tar cargo rustup rustc gcc pkg-config; do
    if command -v "$tool" &>/dev/null; then
        ok "$tool: $(command -v "$tool")"
    else
        skip "$tool: not found"
    fi
done

# ═══════════════════════════════════════════
step "2. Binary Source"
# ═══════════════════════════════════════════

SRC_BIN=""

# Check for pre-built binary in project directory
if [ -f "$LOCAL_BIN" ] && [ -x "$LOCAL_BIN" ]; then
    ok "Found local binary: $LOCAL_BIN"
    if confirm "Use this existing binary?"; then
        SRC_BIN="$LOCAL_BIN"
    fi
fi

if [ -z "$SRC_BIN" ]; then
    echo
    echo "  Choose how to obtain the binary:"
    echo "    [1] Download pre-built from GitHub Releases  (fast, no Rust needed)"
    echo "    [2] Compile from source via Rust             (slow, builds latest code)"
    printf "${CYAN}  Enter 1 or 2:${NC} "
    if $ASSUME_YES; then
        echo "1"
        CHOICE=1
    else
        read -r CHOICE
        CHOICE="${CHOICE:-1}"
    fi

    case "$CHOICE" in
        1)
            # --- Download pre-built ---
            RELEASE_URL="https://github.com/$REPO/releases/latest/download/gestures-linux-${ASSET_ARCH}.tar.gz"
            TMP_DIR=$(mktemp -d)
            CLEANUP_DIRS="$CLEANUP_DIRS $TMP_DIR"
            info "Downloading $RELEASE_URL..."
            download_file "$RELEASE_URL" "$TMP_DIR/gestures.tar.gz" || {
                err "Download failed. Check network or GitHub availability."
                info "Fallback: https://github.com/$REPO/releases/latest"
                rm -rf "$TMP_DIR"; exit 1
            }
            tar xzf "$TMP_DIR/gestures.tar.gz" -C "$TMP_DIR"
            if [ ! -x "$TMP_DIR/gestures" ]; then
                err "Downloaded archive does not contain a valid gestures binary"
                rm -rf "$TMP_DIR"; exit 1
            fi
            if $DRY_RUN; then
                SRC_BIN="$TMP_DIR/gestures"
            else
                install -m755 "$TMP_DIR/gestures" "$LOCAL_BIN"
                ok "Downloaded → $LOCAL_BIN"
                SRC_BIN="$LOCAL_BIN"
            fi
            ;;

        2)
            # --- Compile from source ---
            step "2a. Install Build Dependencies"
            if confirm "Install build dependencies? (build-essential, libudev-dev, libinput-dev, libxdo-dev)"; then
                $SUDO apt-get update -qq
                $SUDO apt-get install -y curl build-essential pkg-config \
                    libudev-dev libinput-dev libxdo-dev
                ok "Build dependencies installed"
            else
                skip "Skipping build dependencies"
            fi

            step "2b. Rust Toolchain"
            if command -v cargo &>/dev/null && command -v rustc &>/dev/null; then
                ok "Rust: $(rustc --version)"
            else
                info "Installing Rust via rustup..."
                curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
                . "$HOME/.cargo/env"
                ok "Rust installed: $(rustc --version)"
            fi

            step "2c. Build"
            info "Compiling gestures (release mode)..."
            . "$HOME/.cargo/env"
            run cargo build --release
            if $DRY_RUN; then
                SRC_BIN="$SCRIPT_DIR/target/release/gestures"
                info "Would install: $SRC_BIN"
            else
                install -m755 "$SCRIPT_DIR/target/release/gestures" "$LOCAL_BIN"
                ok "Compiled → $LOCAL_BIN"
                SRC_BIN="$LOCAL_BIN"
            fi
            ;;

        *)  err "Invalid choice"; exit 1 ;;
    esac
fi

if [ -x "$SRC_BIN" ]; then
    info "Binary: $($SRC_BIN --version 2>/dev/null || file "$SRC_BIN")"
else
    info "Binary source: $SRC_BIN (not written in dry-run)"
fi

# ═══════════════════════════════════════════
step "3. Runtime Dependencies"
# ═══════════════════════════════════════════

# Detect display server
IS_WAYLAND=false
IS_X11=false
if [ -n "${WAYLAND_DISPLAY:-}" ]; then
    IS_WAYLAND=true
elif [ -n "${DISPLAY:-}" ]; then
    IS_X11=true
elif [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; then
    IS_WAYLAND=true
elif [ "${XDG_SESSION_TYPE:-}" = "x11" ]; then
    IS_X11=true
else
    # Ask user
    echo
    echo "  Cannot detect display server automatically."
    echo "    [1] Wayland"
    echo "    [2] X11"
    printf "${CYAN}  Enter 1 or 2:${NC} "
    if $ASSUME_YES; then
        echo "1"
        DS=1
    else
        read -r DS; DS="${DS:-1}"
    fi
    case "$DS" in 1) IS_WAYLAND=true ;; 2) IS_X11=true ;; *) IS_WAYLAND=true ;; esac
fi

if $IS_WAYLAND; then
    ok "Display server: Wayland"
    echo
            info "Wayland runtime needs: ydotool + ydotoold daemon"
            if confirm "Install ydotool and register ydotoold as a user service?"; then
                if ! command -v ydotool &>/dev/null; then
                    run $SUDO apt-get install -y ydotool
                    ok "ydotool installed"
                else
                    ok "ydotool already installed: $(which ydotool)"
        fi
        # Set up ydotoold user service
        YD_SERVICE="$SERVICE_DIR/ydotoold.service"
        YD_SOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/.ydotool_socket"
        if [ -S "$YD_SOCK" ] && pgrep -x ydotoold >/dev/null 2>&1; then
            ok "ydotoold already running with socket $YD_SOCK — skipping user service"
        elif [ ! -f "$YD_SERVICE" ]; then
            YD_OWN="$(id -u):$(id -g)"
            if $DRY_RUN; then
                echo -e "${YELLOW}  [DRY-RUN]${NC} write $YD_SERVICE"
            else
                cat > "$YD_SERVICE" << YDUNIT
[Unit]
Description=ydotoold - virtual input daemon for Wayland

[Service]
Type=simple
ExecStart=/usr/bin/ydotoold --socket-path="${YD_SOCK}" --socket-own="${YD_OWN}"

[Install]
WantedBy=default.target
YDUNIT
            fi
            if $DRY_RUN; then
                ok "Would create $YD_SERVICE"
            else
                ok "Created $YD_SERVICE"
            fi
            run systemctl --user daemon-reload
            run systemctl --user enable --now ydotoold.service 2>/dev/null || true
            if $DRY_RUN; then
                ok "(dry-run) ydotoold would be running"
            elif systemctl --user is-active --quiet ydotoold.service 2>/dev/null; then
                ok "ydotoold service running"
            else
                warn "ydotoold failed to start — check: systemctl --user status ydotoold"
            fi
        else
            run systemctl --user daemon-reload
            run systemctl --user enable --now ydotoold.service 2>/dev/null || true
            if $DRY_RUN; then
                ok "(dry-run) ydotoold would be running"
            elif systemctl --user is-active --quiet ydotoold.service 2>/dev/null; then
                ok "ydotoold service running"
            else
                warn "ydotoold failed to start — check: systemctl --user status ydotoold"
            fi
        fi
    else
        warn "ydotool is required for 3-finger drag on Wayland"
    fi
else
    ok "Display server: X11"
    info "X11 runtime needs: libxdo3 (for direct mouse control)"
    if confirm "Install X11 runtime dependencies?"; then
        run $SUDO apt-get install -y libxdo3 xdotool
        ok "X11 runtime deps installed"
    fi
fi

# ── GNOME Shell extension ──
install_gnome_extension

# ═══════════════════════════════════════════
step "4. Install Binary to System"
# ═══════════════════════════════════════════

if [ "$SRC_BIN" != "$BIN_PATH" ]; then
    run $SUDO install -m755 "$SRC_BIN" "$BIN_PATH"
    if $DRY_RUN; then
        ok "Would install $BIN_PATH"
    else
        ok "Installed $BIN_PATH"
    fi
else
    ok "Already at $BIN_PATH"
fi

# ═══════════════════════════════════════════
step "5. Configuration"
# ═══════════════════════════════════════════

if [ -f "$CONFIG_FILE" ] && ! confirm "Config exists at $CONFIG_FILE. Overwrite?" n; then
    skip "Keeping existing config"
elif $DRY_RUN; then
    echo -e "${YELLOW}  [DRY-RUN]${NC} $BIN_PATH generate-config --force"
    echo -e "${YELLOW}  [DRY-RUN]${NC} write $CONFIG_FILE"
    ok "Config would be written to: $CONFIG_FILE"
else
    "$BIN_PATH" generate-config --force 2>/dev/null || {
        warn "generate-config failed, creating minimal config"
        run mkdir -p "$CONFIG_HOME"
        cat > "$CONFIG_FILE" << 'KDL'
// 3-finger drag (X11 + Wayland)
swipe direction="any" fingers=3 mouse-up-delay=300 acceleration=20
KDL
    }
    ok "Config: $CONFIG_FILE"
fi

# ═══════════════════════════════════════════
step "6. Systemd Service"
# ═══════════════════════════════════════════

run mkdir -p "$SERVICE_DIR"

if [ -f "$SERVICE_FILE" ] && ! confirm "Service file exists. Overwrite?" n; then
    skip "Keeping existing service file"
elif $DRY_RUN; then
    echo -e "${YELLOW}  [DRY-RUN]${NC} $BIN_PATH install-service"
    echo -e "${YELLOW}  [DRY-RUN]${NC} write $SERVICE_FILE"
    ok "Service file would be: $SERVICE_FILE"
else
    "$BIN_PATH" install-service 2>/dev/null || {
        info "Writing service file manually..."
        cat > "$SERVICE_FILE" << UNIT
[Unit]
Description=Touchpad Gestures
Documentation=https://github.com/$REPO

[Service]
Environment=PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/bin
Environment=RUST_LOG=error,gestures=info
Type=simple
ExecStart=$BIN_PATH start
ExecReload=$BIN_PATH reload
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=default.target
UNIT
    }
    ok "Service file: $SERVICE_FILE"
fi

# Add drop-in for RUST_LOG + auto-restart (non-destructive)
run mkdir -p "$SERVICE_DIR/gestures.service.d"
if $DRY_RUN; then
    echo -e "${YELLOW}  [DRY-RUN]${NC} write $SERVICE_DROPIN"
else
    cat > "$SERVICE_DROPIN" << CONF
[Service]
Environment=RUST_LOG=error,gestures=info
Restart=on-failure
RestartSec=3s
CONF
fi

run systemctl --user daemon-reload
run systemctl --user enable --now "$SERVICE_NAME" 2>/dev/null

if $DRY_RUN; then
    ok "(dry-run) service would be enabled and started"
else
    sleep 1
    if systemctl --user is-active --quiet "$SERVICE_NAME"; then
        ok "Service running"
    else
        warn "Service not active — check: journalctl --user -u $SERVICE_NAME -n 20"
    fi
fi

# ═══════════════════════════════════════════
step "7. Done"
# ═══════════════════════════════════════════

echo
if $DRY_RUN; then
    echo -e "  ${YELLOW}Dry-run complete — no system changes were made.${NC}"
else
    echo -e "  ${GREEN}Gestures installed successfully!${NC}"
fi
echo
echo -e "  ${BOLD}Quick commands:${NC}"
echo "    status:  systemctl --user status gestures"
echo "    logs:    journalctl --user -u gestures -f"
echo "    config:  vim $CONFIG_FILE"
echo "    reload:  $BIN_PATH reload"
echo
echo -e "  ${YELLOW}Wayland:${NC} ensure ydotoold is running."
echo "    systemctl --user enable --now ydotoold.service"
echo
