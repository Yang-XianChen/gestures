#!/usr/bin/env bash
set -euo pipefail

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

REPO="ferstar/gestures"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL_BIN="$SCRIPT_DIR/gestures"
BIN_PATH="/usr/local/bin/gestures"
SERVICE_NAME="gestures.service"
SERVICE_DIR="$HOME/.config/systemd/user"
SERVICE_FILE="$SERVICE_DIR/$SERVICE_NAME"
SERVICE_DROPIN="$SERVICE_DIR/gestures.service.d/50-installer.conf"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
CONFIG_FILE="$CONFIG_HOME/gestures.kdl"

confirm() {
    local prompt="$1"; local default="${2:-y}"; local yn
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

# ── Mode: check ──
if [ "${1:-}" = "check" ] || [ "${1:-}" = "--check" ] || [ "${1:-}" = "diagnose" ]; then
    run_diagnostics
    exit 0
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
    read -r ACTION; ACTION="${ACTION:-1}"
    case "$ACTION" in
        1) ok "Proceeding with reinstall..." ;;
        2)
            # ── UNINSTALL ──
            echo
            warn "This will remove all gestures files from your system."
            confirm "Proceed with uninstall?" n || { skip "Cancelled"; exit 0; }

            if systemctl --user is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
                systemctl --user stop "$SERVICE_NAME" 2>/dev/null || true
                ok "Service stopped"
            fi
            if systemctl --user is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
                systemctl --user disable "$SERVICE_NAME" 2>/dev/null || true
                ok "Service disabled"
            fi
            systemctl --user daemon-reload 2>/dev/null || true

            rm -f "$SERVICE_FILE"
            rm -rf "$SERVICE_DIR/gestures.service.d"
            ok "Service files removed"

            if [ -f "$BIN_PATH" ]; then
                sudo rm -f "$BIN_PATH"
                ok "Removed $BIN_PATH"
            fi

            if [ -f "$CONFIG_FILE" ] && confirm "Remove config file $CONFIG_FILE?" n; then
                rm -f "$CONFIG_FILE"
                ok "Config removed"
            else
                skip "Config kept: $CONFIG_FILE"
            fi

            [ -f "$LOCAL_BIN" ] && rm -f "$LOCAL_BIN"
            [ -f "$SCRIPT_DIR/target" ] && rm -rf "$SCRIPT_DIR/target" 2>/dev/null || true

            echo
            echo -e "  ${GREEN}Uninstall complete.${NC}"
            exit 0
            ;;
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
    read -r CHOICE
    CHOICE="${CHOICE:-1}"

    case "$CHOICE" in
        1)
            # --- Download pre-built ---
            RELEASE_URL="https://github.com/$REPO/releases/latest/download/gestures-linux-${ASSET_ARCH}.tar.gz"
            TMP_DIR=$(mktemp -d)
            info "Downloading $RELEASE_URL..."
            curl -fsSL "$RELEASE_URL" -o "$TMP_DIR/gestures.tar.gz" || {
                err "Download failed. Check network or GitHub availability."
                info "Fallback: https://github.com/$REPO/releases/latest"
                rm -rf "$TMP_DIR"; exit 1
            }
            tar xzf "$TMP_DIR/gestures.tar.gz" -C "$TMP_DIR"
            cp "$TMP_DIR/gestures" "$LOCAL_BIN"
            chmod +x "$LOCAL_BIN"
            rm -rf "$TMP_DIR"
            ok "Downloaded → $LOCAL_BIN"
            SRC_BIN="$LOCAL_BIN"
            ;;

        2)
            # --- Compile from source ---
            step "2a. Install Build Dependencies"
            if confirm "Install build dependencies? (build-essential, libudev-dev, libinput-dev, libxdo-dev)"; then
                sudo apt-get update -qq
                sudo apt-get install -y curl build-essential pkg-config \
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
            cargo build --release
            cp "$SCRIPT_DIR/target/release/gestures" "$LOCAL_BIN"
            chmod +x "$LOCAL_BIN"
            ok "Compiled → $LOCAL_BIN"
            SRC_BIN="$LOCAL_BIN"
            ;;

        *)  err "Invalid choice"; exit 1 ;;
    esac
fi

info "Binary: $($SRC_BIN --version 2>/dev/null || file "$SRC_BIN")"

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
    read -r DS; DS="${DS:-1}"
    case "$DS" in 1) IS_WAYLAND=true ;; 2) IS_X11=true ;; *) IS_WAYLAND=true ;; esac
fi

if $IS_WAYLAND; then
    ok "Display server: Wayland"
    echo
    info "Wayland runtime needs: ydotool + ydotoold daemon"
    if confirm "Install ydotool and register ydotoold as a user service?"; then
        if ! command -v ydotool &>/dev/null; then
            sudo apt-get install -y ydotool
            ok "ydotool installed"
        else
            ok "ydotool already installed: $(which ydotool)"
        fi
        # Set up ydotoold user service
        YD_SERVICE="$SERVICE_DIR/ydotoold.service"
        if [ ! -f "$YD_SERVICE" ]; then
            YD_SOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/.ydotool_socket"
            YD_OWN="$(id -u):$(id -g)"
            cat > "$YD_SERVICE" << YDUNIT
[Unit]
Description=ydotoold - virtual input daemon for Wayland

[Service]
Type=simple
ExecStart=/usr/bin/ydotoold --socket-path="${YD_SOCK}" --socket-own="${YD_OWN}"

[Install]
WantedBy=default.target
YDUNIT
            ok "Created $YD_SERVICE"
        fi
        systemctl --user daemon-reload
        systemctl --user enable --now ydotoold.service 2>/dev/null || true
        if systemctl --user is-active --quiet ydotoold.service 2>/dev/null; then
            ok "ydotoold service running"
        else
            warn "ydotoold failed to start — check: systemctl --user status ydotoold"
        fi
    else
        warn "ydotool is required for 3-finger drag on Wayland"
    fi
else
    ok "Display server: X11"
    info "X11 runtime needs: libxdo3 (for direct mouse control)"
    if confirm "Install X11 runtime dependencies?"; then
        sudo apt-get install -y libxdo3 xdotool
        ok "X11 runtime deps installed"
    fi
fi

# ═══════════════════════════════════════════
step "4. Install Binary to System"
# ═══════════════════════════════════════════

if [ "$SRC_BIN" != "$BIN_PATH" ]; then
    sudo cp "$SRC_BIN" "$BIN_PATH"
    sudo chmod +x "$BIN_PATH"
    ok "Installed $BIN_PATH"
else
    ok "Already at $BIN_PATH"
fi

# ═══════════════════════════════════════════
step "5. Configuration"
# ═══════════════════════════════════════════

if [ -f "$CONFIG_FILE" ] && ! confirm "Config exists at $CONFIG_FILE. Overwrite?" n; then
    skip "Keeping existing config"
else
    "$BIN_PATH" generate-config --force 2>/dev/null || {
        warn "generate-config failed, creating minimal config"
        mkdir -p "$CONFIG_HOME"
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

mkdir -p "$SERVICE_DIR"

if [ -f "$SERVICE_FILE" ] && ! confirm "Service file exists. Overwrite?" n; then
    skip "Keeping existing service file"
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
mkdir -p "$SERVICE_DIR/gestures.service.d"
cat > "$SERVICE_DIR/gestures.service.d/50-installer.conf" << CONF
[Service]
Environment=RUST_LOG=error,gestures=info
Restart=on-failure
RestartSec=3s
CONF

systemctl --user daemon-reload
systemctl --user enable --now "$SERVICE_NAME" 2>/dev/null
sleep 1

if systemctl --user is-active --quiet "$SERVICE_NAME"; then
    ok "Service running"
else
    warn "Service not active — check: journalctl --user -u $SERVICE_NAME -n 20"
fi

# ═══════════════════════════════════════════
step "7. Done"
# ═══════════════════════════════════════════

echo
echo -e "  ${GREEN}Gestures installed successfully!${NC}"
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
