# Gestures

> High-performance three-finger dragging with optimizations for both X11 and Wayland.
>
> For technical details, see: https://github.com/riley-martin/gestures/discussions/6
>
> Releases: https://github.com/ferstar/gestures/releases

## About

A libinput-based touchpad gesture handler that executes commands based on gestures.
Unlike alternatives, it uses the libinput API directly for better performance and reliability.

## Features

- **Platform Support**: Both X11 and Wayland
- **High Performance**:
  - X11: Direct libxdo API for minimal latency
  - Wayland: Optimized ydotool integration with configurable FPS throttling (default 144)
  - Thread pool for command execution (4 workers, prevents PID exhaustion)
- **Gesture Types**: Swipe (8 directions + any), Pinch, Hold
- **Advanced Features**:
  - Mouse acceleration and delay for smooth 3-finger dragging
  - Smart finger-count recognition during drag delay (3-finger re-touch continues, others release)
  - Live swipe gestures (`live=true`): direction is committed mid-gesture without lifting fingers
  - Keyboard-interrupt and stuck-timeout safety nets
  - Auto-restart on crash
  - Real-time config reload via IPC
  - Graceful shutdown (SIGTERM/SIGINT)

## Quick Deploy

```bash
git clone https://github.com/ferstar/gestures.git
cd gestures
chmod +x install.sh
./install.sh
```

The script interactively installs runtime dependencies, downloads the pre-built binary, configures gestures, and registers the systemd service — no Rust toolchain required.

## Installation

### Prerequisites

**Build-time system packages:**
- `libudev-dev` / `libudev-devel`
- `libinput-dev` / `libinput-devel`
- `libxdo-dev` / `libxdo-devel`

**Runtime dependencies:**
- X11: No extra runtime dependency for drag (uses `libxdo` directly)
- Wayland: `ydotool` + `ydotoold` daemon (for 3-finger drag)
  - If your distribution package has issues, try the official [ydotool binaries from GitHub releases](https://github.com/ReimuNotMoe/ydotool/releases)

### With Cargo

```bash
cargo install --git https://github.com/ferstar/gestures.git
```

### Manual Build

```bash
git clone https://github.com/ferstar/gestures
cd gestures
cargo build --release
sudo cp target/release/gestures /usr/local/bin/
```

### Nix Flakes

```nix
# flake.nix
{
  inputs.gestures.url = "github:ferstar/gestures";

  # Then add to packages:
  # inputs.gestures.packages.${system}.gestures
}
```

## Running

### Systemd (Recommended)

```bash
# 1. Generate config file (first time only)
gestures generate-config

# 2. Install service file
gestures install-service

# 3. Enable and start the service
systemctl --user enable --now gestures.service
```

### Manual

```bash
# Auto-detect display server (X11 or Wayland)
gestures start

# Force Wayland mode (if needed)
gestures --wayland start

# Force X11 mode (if needed)
gestures --x11 start

# Reload config
gestures reload

# Preview service file (without installing)
gestures install-service --print
```

**Note**: The display server (X11/Wayland) is automatically detected via `WAYLAND_DISPLAY` and `XDG_SESSION_TYPE` environment variables. Manual override is rarely needed.

## Configuration

### Location

The configuration file is searched in order:
1. `$XDG_CONFIG_HOME/gestures.kdl`
2. `$XDG_CONFIG_HOME/gestures/gestures.kdl`
3. `~/.config/gestures.kdl` (if XDG_CONFIG_HOME is unset)

### Generate / Reload

```bash
# Generate default config file
gestures generate-config

# Preview config without installing
gestures generate-config --print

# Force overwrite existing config
gestures generate-config --force

# Reload config without restarting the service
gestures reload
```

### Format

Uses [KDL](https://kdl.dev) configuration language (since v0.5.0).

### Global Settings

```kdl
throttle-fps 144
```

- `throttle-fps`: Throttle rate for Wayland mouse updates (default: 144). Higher = smoother but more CPU. Set to `0` to disable throttling entirely. This only affects Wayland mode where mouse commands are sent via ydotool.

### Swipe Gestures

#### Basic Syntax

```kdl
swipe direction="<dir>" fingers=<n> [start="<cmd>"] [update="<cmd>"] [end="<cmd>"] [live=<bool>]
```

**Parameters:**
- `direction`: `n`, `s`, `e`, `w`, `ne`, `nw`, `se`, `sw`, or `any`
- `fingers`: Number of fingers (typically 3 or 4)
- `start`: Command executed when gesture begins (optional)
- `update`: Command executed on each movement update (optional)
- `end`: Command executed when gesture ends (optional)
- `live`: When `true`, the direction is committed as soon as the primary direction is determined, and the `end` command fires immediately without waiting for finger lift; direction changes mid-gesture re-trigger the command (optional, default `false`)

**Variable Substitution:**
In commands, these variables are replaced with actual values:
- `$delta_x`: Horizontal movement delta
- `$delta_y`: Vertical movement delta
- `$scale`: Pinch scale (for pinch gestures)
- `$delta_angle`: Rotation angle (for pinch gestures)

#### 3-Finger Drag (macOS-like)

**Works on both X11 and Wayland:**

```kdl
swipe direction="any" fingers=3 mouse-up-delay=500 acceleration=20
```

**Parameters:**
- `mouse-up-delay`: Delay in milliseconds before releasing mouse button (allows finger to leave trackpad temporarily)
- `acceleration`: Mouse speed multiplier (20 = 2x speed, 10 = 1x speed)

**Requirements:**
- X11: No extra runtime dependency for drag (uses `libxdo` directly)
- Wayland: Install `ydotool` and run `ydotoold` daemon

**How it works:**
- X11: Uses libxdo API directly (minimal latency)
- Wayland: Uses timer-scheduled ydotool commands (optimized with FPS throttling)

**Drag state machine:**
- `Idle` → swipe begin with a direct mouse gesture → `Active`
- `Active` → swipe end with delay > 0 → `PendingRelease`
- `PendingRelease` + 3-finger swipe begin → `Active` (continue drag)
- `PendingRelease` + non-3-finger swipe begin → `Idle` (release + new gesture)
- `PendingRelease` + pinch/hold begin → `Idle` (release + new gesture)
- `PendingRelease` + pointer event (1-finger click/motion) → `Idle` (immediate release)
- `PendingRelease` + timer expires → `Idle` (normal mouse_up)

#### Manual Wayland Control

If you prefer full control over Wayland commands:

```kdl
swipe direction="any" fingers=3 \
  start="ydotool click -- 0x40" \
  update="ydotool mousemove -x $delta_x -y $delta_y" \
  end="ydotool click -- 0x80"
```

#### Workspace Switching Examples

**Hyprland:**

```kdl
swipe direction="w" fingers=4 end="hyprctl dispatch workspace e-1"
swipe direction="e" fingers=4 end="hyprctl dispatch workspace e+1"
swipe direction="n" fingers=4 end="hyprctl dispatch fullscreen"
swipe direction="s" fingers=4 end="hyprctl dispatch killactive"
```

**i3/Sway:**

```kdl
swipe direction="w" fingers=4 end="i3-msg workspace prev"
swipe direction="e" fingers=4 end="i3-msg workspace next"
```

**GNOME:**

```kdl
swipe direction="n" fingers=4 end="gdbus call --session --dest org.gnome.Shell --object-path /org/gnome/Shell --method org.gnome.Shell.Eval global.workspace_manager.get_active_workspace().get_neighbor(Meta.MotionDirection.UP).activate(global.get_current_time())"
```

### Pinch Gestures

```kdl
pinch direction="<in|out>" fingers=<n> [start="<cmd>"] [update="<cmd>"] [end="<cmd>"]
```

**Examples:**

```kdl
// Zoom in browser
pinch direction="out" fingers=2 end="xdotool key ctrl+plus"
pinch direction="in" fingers=2 end="xdotool key ctrl+minus"

// With continuous updates
pinch direction="out" fingers=2 \
  update="notify-send 'Scaling: $scale'"
```

### Hold Gestures

```kdl
hold fingers=<n> action="<cmd>"
```

**Examples:**

```kdl
// Show launcher
hold fingers=4 action="rofi -show drun"

// Screenshot
hold fingers=3 action="flameshot gui"
```

### Complete Example Configuration

```kdl
// 3-finger drag (X11 + Wayland)
swipe direction="any" fingers=3 mouse-up-delay=500 acceleration=20

// Workspace navigation
swipe direction="w" fingers=4 end="hyprctl dispatch workspace e-1"
swipe direction="e" fingers=4 end="hyprctl dispatch workspace e+1"

// Application launcher
swipe direction="n" fingers=4 end="rofi -show drun"

// Close window
swipe direction="s" fingers=4 end="hyprctl dispatch killactive"

// Browser zoom
pinch direction="in" fingers=2 end="xdotool key ctrl+minus"
pinch direction="out" fingers=2 end="xdotool key ctrl+plus"

// App launcher on hold
hold fingers=4 action="rofi -show drun"
```

### Tips

1. **Test commands first**: Run commands manually before adding to config
2. **Reload config**: `gestures reload` (no restart needed)
3. **Wayland ydotool**: Ensure `ydotoold` daemon is running
4. **Disable DE gestures**: Prevent conflicts with built-in gestures
5. **Check logs**: Run `journalctl --user -u gestures -f` for debugging

## Performance Optimizations

This fork includes several performance improvements:

1. **Regex Caching**: One-time compilation using `once_cell::Lazy`
2. **Thread Pool**: 4-worker pool prevents PID exhaustion during fast gestures
3. **FPS Throttling**: Configurable throttle for Wayland (default 144 FPS, considering ydotool ~100ms latency)
4. **Timer-based Delays**: Non-blocking mouse-up delays for smooth dragging
5. **Event Caching**: 1-second cache for gesture configuration lookups

## Troubleshooting

### High CPU on Wayland
- Default 144 FPS throttle should keep CPU low; lower `throttle-fps` in the config if needed
- Set `throttle-fps 0` to disable throttling entirely

### 3-Finger Drag Not Working

**X11:**
- Ensure X11 session env is correct (`DISPLAY` / `XAUTHORITY`)

**Wayland:**
- If your distribution package has issues, try the official [ydotool binaries from GitHub releases](https://github.com/ReimuNotMoe/ydotool/releases)
- Ensure `ydotoold` daemon is running: `systemctl --user status ydotoold`
- Configure uinput permissions (see [issue #4](https://github.com/ferstar/gestures/issues/4))

### Wayland Permission Denied (trackpad or ydotool socket)

Symptoms:
- Gestures cannot read touchpad events
- Or logs contain ydotool socket permission/path errors

Checks and fixes:

```bash
# 1) Ensure current user is in input-related group (distro-dependent)
id -nG
sudo usermod -aG input $USER

# 2) Re-login so new group membership takes effect

# 3) Run ydotoold as user service (not system/root service)
systemctl --user enable --now ydotoold.service
systemctl --user status ydotoold.service

# 4) Verify socket exists in user runtime dir
ls -la "$XDG_RUNTIME_DIR/.ydotool_socket"
```

Notes:
- Avoid `chmod 777` on the socket as a long-term fix.
- Keep `gestures` and `ydotoold` in the same user session to avoid permission mismatch.

### `libxdo` Shared Library Error on X11

Symptom:
- `journalctl --user -u gestures` shows:
  - `error while loading shared libraries: libxdo.so.3: cannot open shared object file`

Cause:
- System `xdotool/libxdo` was upgraded (for example to `libxdo.so.4`), but your existing `gestures` binary was built against an older SONAME (`libxdo.so.3`).

Fix:

```bash
# Rebuild and reinstall gestures binary
cargo install --path . --force

# Restart user service
systemctl --user restart gestures

# Verify runtime link and logs
ldd ~/.cargo/bin/gestures | grep libxdo
journalctl --user -u gestures -n 50 --no-pager
```

### Conflicts with DE Gestures

Disable built-in gestures in your desktop environment (GNOME, KDE, etc.)

## Developer Guide

### Build and Test

```bash
# Build project (release version)
cargo build --release

# Run tests
cargo test

# Run a specific test
cargo test <test_name>

# Run with verbose logging
cargo run -- -vv start

# Lint and format checking
cargo fmt --all -- --check          # Check code formatting
cargo fmt --all                     # Auto-format code
cargo clippy --all-targets --all-features -- -D warnings  # Run clippy with warnings as errors

# Using Nix (if available)
nix build

# Development environment (Nix)
nix develop
```

### Code Architecture

```
src/
├── main.rs              # Entry point: CLI parsing, signal handling, display server detection
├── event_handler.rs     # Core event handler: libinput event loop, gesture recognition
├── mouse_handler.rs     # Mouse control abstraction: X11 (libxdo) vs Wayland (ydotool)
├── config.rs            # Configuration parsing (KDL format)
├── ipc.rs               # IPC server (Unix socket) for config reload
├── ipc_client.rs        # IPC client
├── utils.rs             # Command execution, variable substitution utilities
└── gestures/
    ├── mod.rs           # Gesture type definitions
    ├── swipe.rs         # Swipe gestures (8 directions + any)
    ├── pinch.rs         # Pinch gestures (in/out)
    └── hold.rs          # Hold gestures
```

### Key Design Patterns

1. **Display Server Auto-detection** (`main.rs`)
   - Checks `WAYLAND_DISPLAY` environment variable (most reliable)
   - Falls back to `XDG_SESSION_TYPE`
   - Defaults to X11 if unable to detect
   - Can be forced via `--wayland` or `--x11` flags

2. **MouseHandler Abstraction** (`mouse_handler.rs`)
   - X11 mode: Creates dedicated thread running libxdo, communicates via mpsc channel
   - Wayland mode: Directly invokes ydotool commands, with retries for critical click/release commands
   - X11 initialization failure logs error but doesn't panic (allows fallback to Wayland mode)
   - Uses Timer for non-blocking mouse-up delays (for 3-finger drag)
   - Drops a pending timer guard by immediately releasing the mouse as a safety net

3. **Performance Optimizations** (`event_handler.rs`)
   - **Gesture Cache** (`GestureCache`): Groups gesture configs by finger count, refreshes every second
   - **FPS Throttling** (`ThrottleState`): Configurable update limit for Wayland (default 144 FPS)
   - **Regex Caching**: One-time compilation using `once_cell::Lazy` (`utils.rs`)
   - **Thread Pool**: 4 worker threads for command execution (prevents PID exhaustion during fast gestures)

4. **IPC Config Reload** (`ipc.rs`)
   - Creates Unix socket at `$XDG_RUNTIME_DIR/gestures.sock`
   - Non-blocking mode, periodically checks SHUTDOWN flag
   - Updates shared config using RwLock when "reload" command received

5. **Direct Mouse Control Detection** (`event_handler.rs`)
   ```rust
   fn is_direct_mouse_gesture(gesture: &Gesture) -> bool {
       if let Gesture::Swipe(j) = gesture {
           j.acceleration.is_some() && j.mouse_up_delay.is_some() && j.direction == SwipeDir::Any
       } else {
           false
       }
   }
   ```
   This function identifies 3-finger drag gestures (direction="any" + mouse-up-delay + acceleration) to use direct mouse control instead of command execution.

### Configuration System

- Uses KDL format (via knuffel crate)
- Config search order:
  1. `$XDG_CONFIG_HOME/gestures.kdl`
  2. `$XDG_CONFIG_HOME/gestures/gestures.kdl`
  3. `~/.config/gestures.kdl`
- Supports variable substitution: `$delta_x`, `$delta_y`, `$scale`, `$delta_angle`

### Common Development Tasks

**Modifying Gesture Handling Logic**

Main handler functions in `event_handler.rs`:
- `handle_swipe_event()` - Swipe gestures
- `handle_pinch_event()` - Pinch gestures
- `handle_hold_event()` - Hold gestures

**Adding New Gesture Types**

1. Add new variant to `Gesture` enum in `src/gestures/mod.rs`
2. Create new module file in `src/gestures/`
3. Add handling branch in `handle_event()` in `event_handler.rs`
4. Update KDL parsing in `config.rs` (via Decode trait)

**Adjusting Performance Parameters**

- **FPS Throttling**: Configure via `throttle-fps` in the config file (default 144)
- **Cache Refresh Interval**: Modify `Duration::from_secs(1)` in `event_handler.rs`
- **Thread Pool Size**: Modify thread pool configuration in `utils.rs`

### Important Constraints

1. **X11 Environment Detection** (`mouse_handler.rs`):
   - Automatically attempts to set `DISPLAY` and `XAUTHORITY`
   - Searches common locations: `~/.Xauthority`, `/tmp/xauth_*`
   - Gracefully degrades if libxdo initialization fails (logs warning but doesn't panic)

2. **Graceful Shutdown**:
   - Uses global `SHUTDOWN` atomic boolean flag
   - Registers SIGTERM and SIGINT signal handlers
   - Both event loop and IPC listener check shutdown flag

3. **3-Finger Drag Requirements**:
   - Must set both `mouse-up-delay` and `acceleration`
   - `direction` must be "any"
   - X11: Requires successful libxdo initialization
   - Wayland: Requires ydotoold daemon running

4. **Thread Safety**:
   - Config shared between threads using `Arc<RwLock<Config>>`
   - MouseHandler communicates with dedicated thread via mpsc channel
   - Uses `parking_lot::RwLock` (faster than std)

### Testing Strategy

- Unit tests located in `src/tests/mod.rs` and the test module at the end of `event_handler.rs`
- Integration tests require touchpad device, typically manual testing
- Recommended manual testing workflow after modifying gesture logic:
  1. Generate config: `gestures generate-config`
  2. Start service: `gestures start`
  3. Test various gestures
  4. Modify config: Edit `~/.config/gestures.kdl`
  5. Reload: `gestures reload`

### Debugging

```bash
# View verbose logs
RUST_LOG=debug gestures start

# Or use command-line flags
gestures -vv start     # Very verbose
gestures -v start      # Info level
gestures -d start      # Debug level

# With systemd
journalctl --user -u gestures -f
```

### CI/CD

- GitHub Actions workflows in `.github/workflows/`
- **CI Pipeline** (`ci.yml`):
  1. Lint: Runs `cargo fmt --check` and `cargo clippy` (warnings treated as errors)
  2. Test: Runs `cargo test` after lint passes
  3. Build Release: Builds release binary after tests pass
- Supports Nix builds (flake.nix)
- Automatically builds binaries and uploads to GitHub Releases on release

### Pre-commit Checks

Before committing code, ensure:

```bash
cargo fmt --all
cargo clippy --all-targets --all-features -- -D warnings
cargo test
```

## Contributing

Feel free to open an issue if you find a bug, and if you have a solution, a PR would be great!
If you have a feature request, prefer to use discussions rather than an issue.

## Alternatives

- [libinput-gestures](https://github.com/bulletmark/libinput-gestures) - Parses debug output
- [gebaar](https://github.com/Coffee2CodeNL/gebaar-libinput) - Swipe only
- [fusuma](https://github.com/iberianpig/fusuma) - Ruby-based
