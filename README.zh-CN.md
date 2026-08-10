# Gestures

> 高性能三指拖拽，针对 X11 和 Wayland 做了优化。
>
> 技术细节参见：https://github.com/riley-martin/gestures/discussions/6
>
> 发布版本：https://github.com/ferstar/gestures/releases

## 项目简介

这是一个基于 libinput 的触控板手势处理器，可以按手势执行命令。与同类方案不同，它直接使用 libinput API，因此性能和可靠性更好。

## 功能特性

- **平台支持**：X11 和 Wayland
- **高性能**：
  - X11：直接调用 libxdo API，延迟最低
  - Wayland：优化 ydotool 集成，支持可配置的帧率节流（默认 144 FPS）
  - 命令执行使用线程池（4 个工作线程，避免 PID 耗尽）
- **手势类型**：滑动（8 个方向 + any）、捏合、长按
- **进阶功能**：
  - 三指拖拽的鼠标加速与延迟释放
  - 拖拽延迟期间智能识别手指数（三指重新放下继续拖拽，其他手指数则释放）
  - 实时滑动手势（`live=true`）：方向确定后中途立即触发命令，无需抬手
  - 键盘打断与卡死超时安全兜底
  - 崩溃后自动重启
  - 通过 IPC 实时重载配置
  - 优雅退出（SIGTERM/SIGINT）

## 快速部署

### 一键安装

从仓库拉取 `install.sh` 并直接执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Yang-XianChen/gestures/main/install.sh)
```

非交互安装（接受默认选项），在末尾加 `--yes`：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Yang-XianChen/gestures/main/install.sh) --yes
```

### 一键卸载

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Yang-XianChen/gestures/main/install.sh) --uninstall --yes
```

`--yes` 会保留你的配置文件；去掉它可按提示交互选择。

### 克隆后运行

```bash
git clone https://github.com/Yang-XianChen/gestures.git
cd gestures
chmod +x install.sh
./install.sh
```

脚本会交互式地安装运行时依赖、下载预编译二进制、生成配置、安装 GNOME 辅助扩展并注册 systemd 服务——全程不需要 Rust 工具链。

## 安装

### 前置依赖

**构建期系统包：**
- `libudev-dev` / `libudev-devel`
- `libinput-dev` / `libinput-devel`
- `libxdo-dev` / `libxdo-devel`

**运行时依赖：**
- X11：拖拽无需额外运行时依赖（直接使用 `libxdo`）
- Wayland：需要 `ydotool` + `ydotoold` 守护进程（用于三指拖拽）
  - 如果你的发行版软件包有问题，可以试试官方 [ydotool 预编译二进制](https://github.com/ReimuNotMoe/ydotool/releases)

### 通过 Cargo 安装

```bash
cargo install --git https://github.com/ferstar/gestures.git
```

### 手动构建

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

  # 然后添加到 packages：
  # inputs.gestures.packages.${system}.gestures
}
```

## 运行

### systemd（推荐）

```bash
# 1. 首次使用先生成配置文件
gestures generate-config

# 2. 安装服务文件
gestures install-service

# 3. 启用并启动服务
systemctl --user enable --now gestures.service
```

### 手动运行

```bash
# 自动检测显示服务器（X11 或 Wayland）
gestures start

# 需要时强制使用 Wayland
gestures --wayland start

# 需要时强制使用 X11
gestures --x11 start

# 重载配置
gestures reload

# 预览服务文件（不实际安装）
gestures install-service --print
```

**注意**：显示服务器（X11/Wayland）会自动通过 `WAYLAND_DISPLAY` 和 `XDG_SESSION_TYPE` 环境变量检测，一般不需要手动指定。

## 配置

### 配置文件位置

配置文件按以下顺序查找：
1. `$XDG_CONFIG_HOME/gestures.kdl`
2. `$XDG_CONFIG_HOME/gestures/gestures.kdl`
3. `~/.config/gestures.kdl`（当 XDG_CONFIG_HOME 未设置时）

### 生成与重载

```bash
# 生成默认配置文件
gestures generate-config

# 预览配置内容（不实际生成）
gestures generate-config --print

# 强制覆盖已有配置
gestures generate-config --force

# 不重启服务，直接重载配置
gestures reload
```

### 格式

使用 [KDL](https://kdl.dev) 配置语言（自 v0.5.0 起）。

### 全局设置

```kdl
throttle-fps 144
```

- `throttle-fps`：Wayland 鼠标更新节流帧率（默认 144）。数值越高越流畅，但 CPU 占用也越高。设为 `0` 可完全关闭节流。仅影响通过 ydotool 发送鼠标命令的 Wayland 模式。

### 滑动手势

#### 基本语法

```kdl
swipe direction="<dir>" fingers=<n> [start="<cmd>"] [update="<cmd>"] [end="<cmd>"] [live=<bool>]
```

**参数说明：**
- `direction`：`n`、`s`、`e`、`w`、`ne`、`nw`、`se`、`sw` 或 `any`
- `fingers`：手指数（通常为 3 或 4）
- `start`：手势开始时要执行的命令（可选）
- `update`：每次移动更新时执行的命令（可选）
- `end`：手势结束时要执行的命令（可选）
- `live`：设为 `true` 时，一旦确定主方向就立即提交并触发 `end` 命令，无需抬手；手势中途改变方向会重新触发（可选，默认 `false`）

**变量替换：**
命令中以下变量会被替换为实际值：
- `$delta_x`：水平移动增量
- `$delta_y`：垂直移动增量
- `$scale`：捏合缩放比例（用于捏合手势）
- `$delta_angle`：旋转角度（用于捏合手势）

#### 三指拖拽（类 macOS）

**X11 和 Wayland 均可用：**

```kdl
swipe direction="any" fingers=3 mouse-up-delay=500 acceleration=20
```

**参数说明：**
- `mouse-up-delay`：释放鼠标按钮前的延迟毫秒数（允许手指暂时离开触控板）
- `acceleration`：鼠标速度倍率（20 = 2 倍速，10 = 1 倍速）

**要求：**
- X11：拖拽无需额外运行时依赖（直接使用 `libxdo`）
- Wayland：需要安装 `ydotool` 并运行 `ydotoold` 守护进程

**工作原理：**
- X11：直接使用 libxdo API（延迟最低）
- Wayland：使用定时器调度的 ydotool 命令（配合帧率节流优化）

**拖拽状态机：**
- `Idle` → 滑动开始且匹配直接鼠标手势 → `Active`
- `Active` → 滑动结束且延迟 > 0 → `PendingRelease`
- `PendingRelease` + 三指滑动开始 → `Active`（继续拖拽）
- `PendingRelease` + 非三指滑动开始 → `Idle`（释放并开始新手势）
- `PendingRelease` + 捏合/长按开始 → `Idle`（释放并开始新手势）
- `PendingRelease` + 指针事件（单指点击/移动）→ `Idle`（立即释放）
- `PendingRelease` + 定时器到期 → `Idle`（正常 mouse_up）

#### 手动 Wayland 控制

如果你想完全手动控制 Wayland 命令：

```kdl
swipe direction="any" fingers=3 \
  start="ydotool click -- 0x40" \
  update="ydotool mousemove -x $delta_x -y $delta_y" \
  end="ydotool click -- 0x80"
```

#### 工作区切换示例

**Hyprland：**

```kdl
swipe direction="w" fingers=4 end="hyprctl dispatch workspace e-1"
swipe direction="e" fingers=4 end="hyprctl dispatch workspace e+1"
swipe direction="n" fingers=4 end="hyprctl dispatch fullscreen"
swipe direction="s" fingers=4 end="hyprctl dispatch killactive"
```

**i3/Sway：**

```kdl
swipe direction="w" fingers=4 end="i3-msg workspace prev"
swipe direction="e" fingers=4 end="i3-msg workspace next"
```

**GNOME：**

```kdl
swipe direction="n" fingers=4 end="gdbus call --session --dest org.gnome.Shell --object-path /org/gnome/Shell --method org.gnome.Shell.Eval global.workspace_manager.get_active_workspace().get_neighbor(Meta.MotionDirection.UP).activate(global.get_current_time())"
```

### 捏合手势

```kdl
pinch direction="<in|out>" fingers=<n> [start="<cmd>"] [update="<cmd>"] [end="<cmd>"]
```

**示例：**

```kdl
// 浏览器缩放
pinch direction="out" fingers=2 end="xdotool key ctrl+plus"
pinch direction="in" fingers=2 end="xdotool key ctrl+minus"

// 持续更新
pinch direction="out" fingers=2 \
  update="notify-send 'Scaling: $scale'"
```

### 长按手势

```kdl
hold fingers=<n> action="<cmd>"
```

**示例：**

```kdl
// 显示启动器
hold fingers=4 action="rofi -show drun"

// 截图
hold fingers=3 action="flameshot gui"
```

### 完整示例配置

```kdl
// 3 指拖拽（X11 + Wayland）
swipe direction="any" fingers=3 mouse-up-delay=500 acceleration=20

// 工作区导航
swipe direction="w" fingers=4 end="hyprctl dispatch workspace e-1"
swipe direction="e" fingers=4 end="hyprctl dispatch workspace e+1"

// 应用启动器
swipe direction="n" fingers=4 end="rofi -show drun"

// 关闭窗口
swipe direction="s" fingers=4 end="hyprctl dispatch killactive"

// 浏览器缩放
pinch direction="in" fingers=2 end="xdotool key ctrl+minus"
pinch direction="out" fingers=2 end="xdotool key ctrl+plus"

// 长按打开应用启动器
hold fingers=4 action="rofi -show drun"
```

### 提示

1. **先测试命令**：把命令手动跑一遍，确认没问题再加进配置
2. **重载配置**：`gestures reload`（无需重启服务）
3. **Wayland 的 ydotool**：确保 `ydotoold` 守护进程正在运行
4. **关闭桌面环境自带手势**：避免与内置手势冲突
5. **查看日志**：运行 `journalctl --user -u gestures -f` 排查问题

## 性能优化

本分支（fork）包含以下性能改进：

1. **正则缓存**：使用 `once_cell::Lazy` 只编译一次
2. **线程池**：4 个工作线程，避免快速连续手势导致 PID 耗尽
3. **帧率节流**：Wayland 下可配置更新频率（默认 144 FPS，考虑到 ydotool 约 100ms 延迟）
4. **定时器延迟**：非阻塞的鼠标释放延迟，拖拽更顺滑
5. **事件缓存**：手势配置查询使用 1 秒缓存

## 故障排查

### Wayland 下 CPU 占用高
- 默认 144 FPS 节流应该能把 CPU 占用控制在较低水平；如果仍偏高，可在配置中调低 `throttle-fps`
- 设为 `throttle-fps 0` 可完全关闭节流

### 三指拖拽不生效

**X11：**
- 确认 X11 会话环境变量正确（`DISPLAY` / `XAUTHORITY`）

**Wayland：**
- 如果你的发行版软件包有问题，可以试试官方 [ydotool 预编译二进制](https://github.com/ReimuNotMoe/ydotool/releases)
- 确认 `ydotoold` 守护进程正在运行：`systemctl --user status ydotoold`
- 配置 uinput 权限（参见 [issue #4](https://github.com/ferstar/gestures/issues/4)）

### Wayland 权限被拒绝（触控板或 ydotool socket）

症状：
- 手势无法读取触控板事件
- 或日志中出现 ydotool socket 权限/路径错误

检查与修复：

```bash
# 1) 确认当前用户已加入 input 相关用户组（因发行版而异）
id -nG
sudo usermod -aG input $USER

# 2) 重新登录，让新的用户组成员关系生效

# 3) 以用户服务方式运行 ydotoold（不要用系统/root 服务）
systemctl --user enable --now ydotoold.service
systemctl --user status ydotoold.service

# 4) 确认 socket 存在于用户运行时目录
ls -la "$XDG_RUNTIME_DIR/.ydotool_socket"
```

注意：
- 不要把 `chmod 777` 当作长期解决方案
- 让 `gestures` 和 `ydotoold` 运行在同一个用户会话中，避免权限不匹配

### X11 下 libxdo 动态库错误

症状：
- `journalctl --user -u gestures` 显示：
  - `error while loading shared libraries: libxdo.so.3: cannot open shared object file`

原因：
- 系统的 `xdotool/libxdo` 升级过（例如升级到 `libxdo.so.4`），但现有 `gestures` 二进制是针对旧 SONAME（`libxdo.so.3`）构建的。

修复：

```bash
# 重新构建并安装 gestures 二进制
cargo install --path . --force

# 重启用户服务
systemctl --user restart gestures

# 验证运行时链接和日志
ldd ~/.cargo/bin/gestures | grep libxdo
journalctl --user -u gestures -n 50 --no-pager
```

### 与桌面环境手势冲突

请在桌面环境中关闭自带手势（GNOME、KDE 等）。

## 开发者指南

### 构建与测试

```bash
# 构建 release 版本
cargo build --release

# 运行测试
cargo test

# 运行指定测试
cargo test <test_name>

# 带详细日志运行
cargo run -- -vv start

# Lint 与格式检查
cargo fmt --all -- --check          # 检查代码格式
cargo fmt --all                     # 自动格式化代码
cargo clippy --all-targets --all-features -- -D warnings  # 运行 clippy，警告视为错误

# 使用 Nix（如果可用）
nix build

# Nix 开发环境
nix develop
```

### 代码架构

```
src/
├── main.rs              # 入口：CLI 解析、信号处理、显示服务器检测
├── event_handler.rs     # 核心事件处理：libinput 事件循环、手势识别
├── mouse_handler.rs     # 鼠标控制抽象：X11（libxdo）vs Wayland（ydotool）
├── config.rs            # 配置解析（KDL 格式）
├── ipc.rs               # IPC 服务端（Unix socket），用于重载配置
├── ipc_client.rs        # IPC 客户端
├── utils.rs             # 命令执行、变量替换工具
└── gestures/
    ├── mod.rs           # 手势类型定义
    ├── swipe.rs         # 滑动手势（8 方向 + any）
    ├── pinch.rs         # 捏合手势（in/out）
    └── hold.rs          # 长按手势
```

### 关键设计模式

1. **显示服务器自动检测**（`main.rs`）
   - 优先检查 `WAYLAND_DISPLAY` 环境变量（最可靠）
   - 其次回退到 `XDG_SESSION_TYPE`
   - 无法检测时默认使用 X11
   - 可通过 `--wayland` 或 `--x11` 参数强制指定

2. **MouseHandler 抽象**（`mouse_handler.rs`）
   - X11 模式：创建专用线程运行 libxdo，通过 mpsc 通道通信
   - Wayland 模式：直接调用 ydotool 命令，关键点击/释放命令带重试
   - X11 初始化失败只记日志、不 panic（允许回退到 Wayland 模式）
   - 使用 Timer 实现非阻塞鼠标释放延迟（用于三指拖拽）
   - 若拖拽对象销毁时仍有未执行的定时释放，会立即补发一次释放作为安全兜底

3. **性能优化**（`event_handler.rs`）
   - **手势缓存**（`GestureCache`）：按手指数分组缓存手势配置，每秒刷新
   - **帧率节流**（`ThrottleState`）：Wayland 下可配置更新频率（默认 144 FPS）
   - **正则缓存**：使用 `once_cell::Lazy` 只编译一次（`utils.rs`）
   - **线程池**：4 个工作线程执行命令（避免快速手势导致 PID 耗尽）

4. **IPC 配置重载**（`ipc.rs`）
   - 在 `$XDG_RUNTIME_DIR/gestures.sock` 创建 Unix socket
   - 非阻塞模式，周期检查 SHUTDOWN 标志
   - 收到 "reload" 命令时用 RwLock 更新共享配置

5. **直接鼠标控制检测**（`event_handler.rs`）
   ```rust
   fn is_direct_mouse_gesture(gesture: &Gesture) -> bool {
       if let Gesture::Swipe(j) = gesture {
           j.acceleration.is_some() && j.mouse_up_delay.is_some() && j.direction == SwipeDir::Any
       } else {
           false
       }
   }
   ```
   该函数用于识别三指拖拽手势（`direction="any"` + `mouse-up-delay` + `acceleration`），走直接鼠标控制而不是命令执行。

### 配置系统

- 使用 KDL 格式（通过 knuffel crate 解析）
- 配置查找顺序：
  1. `$XDG_CONFIG_HOME/gestures.kdl`
  2. `$XDG_CONFIG_HOME/gestures/gestures.kdl`
  3. `~/.config/gestures.kdl`
- 支持变量替换：`$delta_x`、`$delta_y`、`$scale`、`$delta_angle`

### 常见开发任务

**修改手势处理逻辑**

`event_handler.rs` 中的主要处理函数：
- `handle_swipe_event()` - 滑动手势
- `handle_pinch_event()` - 捏合手势
- `handle_hold_event()` - 长按手势

**新增手势类型**

1. 在 `src/gestures/mod.rs` 的 `Gesture` 枚举中添加新变体
2. 在 `src/gestures/` 中创建新模块文件
3. 在 `event_handler.rs` 的 `handle_event()` 中添加处理分支
4. 在 `config.rs` 中更新 KDL 解析（通过 Decode trait）

**调整性能参数**

- **帧率节流**：在配置文件中设置 `throttle-fps`（默认 144）
- **缓存刷新间隔**：修改 `event_handler.rs` 中的 `Duration::from_secs(1)`
- **线程池大小**：修改 `utils.rs` 中的线程池配置

### 重要约束

1. **X11 环境检测**（`mouse_handler.rs`）：
   - 自动尝试设置 `DISPLAY` 和 `XAUTHORITY`
   - 搜索常见位置：`~/.Xauthority`、`/tmp/xauth_*`
   - libxdo 初始化失败时优雅降级（记警告但不 panic）

2. **优雅退出**：
   - 使用全局 `SHUTDOWN` 原子布尔标志
   - 注册 SIGTERM 和 SIGINT 信号处理器
   - 事件循环和 IPC 监听器都会检查该标志

3. **三指拖拽要求**：
   - 必须同时设置 `mouse-up-delay` 和 `acceleration`
   - `direction` 必须为 "any"
   - X11：需要成功初始化 libxdo
   - Wayland：需要 ydotoold 守护进程在运行

4. **线程安全**：
   - 配置通过 `Arc<RwLock<Config>>` 在线程间共享
   - MouseHandler 通过 mpsc 通道与专用线程通信
   - 使用 `parking_lot::RwLock`（比 std 更快）

### 测试策略

- 单元测试位于 `src/tests/mod.rs` 和 `event_handler.rs` 末尾的测试模块中
- 集成测试需要触控板设备，通常需要手动测试
- 修改手势逻辑后的推荐手动测试流程：
  1. 生成配置：`gestures generate-config`
  2. 启动服务：`gestures start`
  3. 测试各种手势
  4. 修改配置：编辑 `~/.config/gestures.kdl`
  5. 重载：`gestures reload`

### 调试

```bash
# 查看详细日志
RUST_LOG=debug gestures start

# 或使用命令行参数
gestures -vv start     # 非常详细
gestures -v start      # Info 级别
gestures -d start      # Debug 级别

# systemd 下查看日志
journalctl --user -u gestures -f
```

### CI/CD

- GitHub Actions 工作流位于 `.github/workflows/`
- **CI 流水线**（`ci.yml`）：
  1. Lint：运行 `cargo fmt --check` 和 `cargo clippy`（警告视为错误）
  2. 测试：Lint 通过后运行 `cargo test`
  3. 构建 Release：测试通过后构建 release 二进制
- 支持 Nix 构建（flake.nix）
- 发布时自动构建二进制并上传到 GitHub Releases

### 提交前检查

提交代码前，请确保：

```bash
cargo fmt --all
cargo clippy --all-targets --all-features -- -D warnings
cargo test
```

## 参与贡献

如果你发现 bug，欢迎提交 issue；如果有解决方案，提交 PR 就更好了！
如果你有功能需求，建议使用 Discussions 而不是 issue。

## 替代方案

- [libinput-gestures](https://github.com/bulletmark/libinput-gestures) - 解析调试输出
- [gebaar](https://github.com/Coffee2CodeNL/gebaar-libinput) - 仅支持滑动
- [fusuma](https://github.com/iberianpig/fusuma) - 基于 Ruby
