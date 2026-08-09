use std::{
    fs::OpenOptions,
    os::{
        fd::{AsFd, OwnedFd},
        unix::prelude::OpenOptionsExt,
    },
    path::Path,
    sync::Arc,
};

use input::{
    event::{
        gesture::{
            GestureEndEvent, GestureEventCoordinates, GestureEventTrait, GestureHoldEvent,
            GesturePinchEvent, GesturePinchEventTrait, GestureSwipeEvent,
        },
        pointer::PointerEvent,
        Event, EventTrait, GestureEvent,
    },
    DeviceCapability, Libinput, LibinputInterface,
};
use miette::{miette, Result};
use nix::{
    fcntl::OFlag,
    poll::{poll, PollFd, PollFlags, PollTimeout},
};

use crate::config::Config;
use crate::gestures::{hold::*, pinch::*, swipe::*, *};
use crate::mouse_handler::MouseHandler;
use crate::utils::{exec_command_from_string, exec_update_command_from_string};

use parking_lot::RwLock;
use std::collections::HashMap;

#[derive(Debug)]
struct GestureCache {
    swipe_gestures: HashMap<i32, Vec<Gesture>>,
    pinch_gestures: HashMap<i32, Vec<Gesture>>,
    hold_gestures: HashMap<i32, Vec<Gesture>>,
    last_update: std::time::Instant,
}

impl GestureCache {
    fn new() -> Self {
        Self {
            swipe_gestures: HashMap::new(),
            pinch_gestures: HashMap::new(),
            hold_gestures: HashMap::new(),
            last_update: std::time::Instant::now() - std::time::Duration::from_secs(2),
        }
    }
}

#[derive(Debug)]
struct ThrottleState {
    last_update: std::time::Instant,
    min_interval: std::time::Duration,
}

impl ThrottleState {
    fn new(fps: u32) -> Self {
        // fps=0 disables throttling entirely (min_interval=0 = always update)
        let min_interval = if fps > 0 {
            std::time::Duration::from_micros(1_000_000 / fps as u64)
        } else {
            std::time::Duration::ZERO
        };
        Self {
            last_update: std::time::Instant::now(),
            min_interval,
        }
    }

    fn should_update(&mut self) -> bool {
        let now = std::time::Instant::now();
        if now.duration_since(self.last_update) >= self.min_interval {
            self.last_update = now;
            true
        } else {
            false
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum DragState {
    Idle,
    Active,
    PendingRelease,
}

/// live 手势的主方向（垂直/水平），确定后锁定，避免轻微抖动误判
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum LiveOrientation {
    Vertical,
    Horizontal,
}

/// live 手势：确定初始方向所需的最小累计位移
const LIVE_START_THRESHOLD: f64 = 9.0;
/// live 手势：锁定方向后，换向/反向需要的最小轴向位移
const LIVE_REVERSE_THRESHOLD: f64 = 4.0;

/// 超过该时长没有任何输入事件时，任何未结束的拖拽状态都视为已过期
/// （例如长时间熄屏/休眠后唤醒），必须先释放左键并复位，
/// 避免把唤醒后的触摸误当成“续拖”再次按下左键。
const STALE_DRAG_GAP: std::time::Duration = std::time::Duration::from_secs(10);

#[derive(Debug)]
pub struct EventHandler {
    config: Arc<RwLock<Config>>,
    event: Gesture,
    cache: GestureCache,
    throttle: ThrottleState,
    drag_state: DragState,
    last_drag_activity: Option<std::time::Instant>,
    drag_started: Option<std::time::Instant>,
    /// 最近一次收到输入事件的墙钟时间，用于检测熄屏/休眠造成的事件断层
    last_input_wall: Option<std::time::SystemTime>,
    /// 进入 PendingRelease 后的释放截止时间（延迟释放 + 少量宽限），
    /// 到期后强制复位，避免状态一直停留在 PendingRelease
    pending_release_deadline: Option<std::time::Instant>,
    // live 手势状态：方向提交后立即触发，方向变化时重新触发
    live_direction: Option<SwipeDir>,
    live_hold_dir: Option<SwipeDir>,
    live_hold_count: u32,
    live_cum_dx: f64,
    live_cum_dy: f64,
    live_axis_delta: f64,
    live_orientation: Option<LiveOrientation>,
}

trait MouseActions {
    fn mouse_down(&mut self, button: i32);
    fn mouse_up_delay(&mut self, button: i32, delay_ms: i64);
    fn mouse_up_immediate(&mut self, button: i32);
    fn move_mouse_relative(&mut self, x_val: i32, y_val: i32);
}

impl MouseActions for MouseHandler {
    fn mouse_down(&mut self, button: i32) {
        MouseHandler::mouse_down(self, button);
    }

    fn mouse_up_delay(&mut self, button: i32, delay_ms: i64) {
        MouseHandler::mouse_up_delay(self, button, delay_ms);
    }

    fn mouse_up_immediate(&mut self, button: i32) {
        MouseHandler::mouse_up_immediate(self, button);
    }

    fn move_mouse_relative(&mut self, x_val: i32, y_val: i32) {
        MouseHandler::move_mouse_relative(self, x_val, y_val);
    }
}

impl EventHandler {
    pub fn new(config: Arc<RwLock<Config>>) -> Self {
        let fps = config.read().throttle_fps.unwrap_or(144);
        log::debug!("Throttle FPS: {}", fps);
        let mut handler = Self {
            config,
            event: Gesture::None,
            cache: GestureCache::new(),
            throttle: ThrottleState::new(fps),
            drag_state: DragState::Idle,
            last_drag_activity: None,
            drag_started: None,
            last_input_wall: None,
            pending_release_deadline: None,
            live_direction: None,
            live_hold_dir: None,
            live_hold_count: 0,
            live_cum_dx: 0.0,
            live_cum_dy: 0.0,
            live_axis_delta: 0.0,
            live_orientation: None,
        };
        handler.update_cache();
        handler
    }

    pub fn init(&mut self, input: &mut Libinput) -> Result<()> {
        log::debug!("{:?}  {:?}", &self, &input);
        self.init_ctx(input)
            .map_err(|_| miette!("Could not initialize libinput"))?;
        if self.has_gesture_device(input) {
            Ok(())
        } else {
            Err(miette!("Could not find gesture device"))
        }
    }

    fn init_ctx(&mut self, input: &mut Libinput) -> Result<(), ()> {
        input.udev_assign_seat("seat0")?;
        Ok(())
    }

    fn has_gesture_device(&mut self, input: &mut Libinput) -> bool {
        log::debug!("Looking for gesture device");
        if let Err(e) = input.dispatch() {
            log::error!("Failed to dispatch input events: {}", e);
            return false;
        }

        for event in &mut *input {
            if let Event::Device(e) = event {
                log::debug!("Device: {:?}", &e);
                if e.device().has_capability(DeviceCapability::Gesture) {
                    log::debug!("Found gesture device");
                    return true;
                }
            }
        }

        log::debug!("No gesture device found");
        false
    }

    pub fn main_loop(&mut self, input: &mut Libinput, mh: &mut MouseHandler) -> Result<()> {
        loop {
            if crate::SHUTDOWN.load(std::sync::atomic::Ordering::Relaxed) {
                log::info!("Received shutdown signal, exiting event loop");
                break;
            }

            let mut fds = [PollFd::new(input.as_fd(), PollFlags::POLLIN)];
            match poll(&mut fds, PollTimeout::from(100u16)) {
                Ok(_) => {
                    self.check_stale_drag(mh);
                    self.handle_event(input, mh)?;
                }
                Err(e) => {
                    if e != nix::errno::Errno::EINTR {
                        return Err(miette!("Poll error: {}", e));
                    }
                }
            }
            self.check_drag_stuck(mh)?;
        }
        Ok(())
    }

    pub fn handle_event(&mut self, input: &mut Libinput, mh: &mut MouseHandler) -> Result<()> {
        input
            .dispatch()
            .map_err(|e| miette!("Failed to dispatch input events: {}", e))?;
        for event in input {
            self.note_input();
            match event {
                Event::Gesture(e) => {
                    // In PendingRelease, non-swipe gestures (pinch/hold) cancel the drag
                    if self.drag_state == DragState::PendingRelease
                        && !matches!(e, GestureEvent::Swipe(_))
                    {
                        self.cancel_pending_release(mh);
                    }
                    match e {
                        GestureEvent::Pinch(e) => self.handle_pinch_event(e)?,
                        GestureEvent::Swipe(e) => self.handle_swipe_event(e, mh)?,
                        GestureEvent::Hold(e) => self.handle_hold_event(e)?,
                        _ => (),
                    }
                }
                Event::Pointer(pe) => self.handle_pointer_event(pe, mh)?,
                Event::Keyboard(ke) => {
                    // ydotool 虚拟设备会回灌我们自己通过 ydotool 发送的按键事件，
                    // 这些不是真实用户输入，必须忽略，否则 4 指 live 手势会打断拖拽。
                    if ke.device().name() == "ydotoold virtual device" {
                        continue;
                    }
                    if self.drag_state != DragState::Idle {
                        log::error!("Keyboard input during drag, releasing immediately");
                        mh.mouse_up_immediate(1);
                        self.reset_drag();
                    }
                }
                Event::Device(_) if self.drag_state != DragState::Idle => {
                    // 设备热插拔（含休眠唤醒后的设备重建）时，未结束的拖拽状态
                    // 已经不可信，立即释放左键，避免锁键。
                    log::error!("Device change during drag, releasing held button");
                    mh.mouse_up_immediate(1);
                    self.reset_drag();
                }
                _ => {}
            }
        }
        Ok(())
    }

    fn handle_hold_event(&mut self, event: GestureHoldEvent) -> Result<()> {
        self.refresh_cache_if_needed();
        match event {
            GestureHoldEvent::Begin(e) => {
                self.event = Gesture::Hold(Hold {
                    fingers: e.finger_count(),
                    action: None,
                })
            }
            GestureHoldEvent::End(_e) => {
                if let Gesture::Hold(s) = &self.event {
                    log::debug!("Hold: {:?}", &s.fingers);
                    if let Some(gestures) = self.cache.hold_gestures.get(&s.fingers) {
                        for gesture in gestures {
                            if let Gesture::Hold(j) = gesture {
                                exec_command_from_string(
                                    j.action.as_deref().unwrap_or(""),
                                    0.0,
                                    0.0,
                                    0.0,
                                    0.0,
                                )?;
                            }
                        }
                    }
                }
            }
            _ => (),
        }
        Ok(())
    }

    fn handle_pinch_event(&mut self, event: GesturePinchEvent) -> Result<()> {
        self.refresh_cache_if_needed();
        match event {
            GesturePinchEvent::Begin(e) => {
                self.event = Gesture::Pinch(Pinch {
                    fingers: e.finger_count(),
                    direction: PinchDir::Any,
                    update: None,
                    start: None,
                    end: None,
                });
                if let Gesture::Pinch(s) = &self.event {
                    if let Some(gestures) = self.cache.pinch_gestures.get(&s.fingers) {
                        for gesture in gestures {
                            if let Gesture::Pinch(j) = gesture {
                                if (j.direction == s.direction || j.direction == PinchDir::Any)
                                    && j.fingers == s.fingers
                                {
                                    exec_command_from_string(
                                        j.start.as_deref().unwrap_or(""),
                                        0.0,
                                        0.0,
                                        0.0,
                                        0.0,
                                    )?;
                                }
                            }
                        }
                    }
                }
            }
            GesturePinchEvent::Update(e) => {
                let scale = e.scale();
                let delta_angle = e.angle_delta();
                if let Gesture::Pinch(s) = &self.event {
                    let dir = PinchDir::dir(scale, delta_angle);
                    let fingers = s.fingers;
                    log::debug!(
                        "Pinch: scale={:?} angle={:?} direction={:?} fingers={:?}",
                        &scale,
                        &delta_angle,
                        &dir,
                        &s.fingers
                    );
                    if let Some(gestures) = self.cache.pinch_gestures.get(&fingers) {
                        for gesture in gestures {
                            if let Gesture::Pinch(j) = gesture {
                                if j.direction == dir || j.direction == PinchDir::Any {
                                    exec_update_command_from_string(
                                        j.update.as_deref().unwrap_or(""),
                                        0.0,
                                        0.0,
                                        delta_angle,
                                        scale,
                                    )?;
                                }
                            }
                        }
                    }
                    self.event = Gesture::Pinch(Pinch {
                        fingers,
                        direction: dir,
                        update: None,
                        start: None,
                        end: None,
                    })
                }
            }
            GesturePinchEvent::End(_e) => {
                if let Gesture::Pinch(s) = &self.event {
                    if let Some(gestures) = self.cache.pinch_gestures.get(&s.fingers) {
                        for gesture in gestures {
                            if let Gesture::Pinch(j) = gesture {
                                if (j.direction == s.direction || j.direction == PinchDir::Any)
                                    && j.fingers == s.fingers
                                {
                                    exec_command_from_string(
                                        j.end.as_deref().unwrap_or(""),
                                        0.0,
                                        0.0,
                                        0.0,
                                        0.0,
                                    )?;
                                }
                            }
                        }
                    }
                }
            }
            _ => (),
        }
        Ok(())
    }

    fn handle_swipe_event(
        &mut self,
        event: GestureSwipeEvent,
        mh: &mut impl MouseActions,
    ) -> Result<()> {
        match event {
            GestureSwipeEvent::Begin(e) => self.handle_swipe_begin(e.finger_count(), mh),
            GestureSwipeEvent::Update(e) => self.handle_swipe_update(e.dx(), e.dy(), mh),
            GestureSwipeEvent::End(e) => {
                if e.cancelled() {
                    self.handle_swipe_cancel(mh)
                } else {
                    self.handle_swipe_end(mh)
                }
            }
            _ => Ok(()),
        }
    }

    fn update_cache(&mut self) {
        let config = self.config.read();
        let mut swipe_map: HashMap<i32, Vec<Gesture>> = HashMap::new();
        let mut pinch_map: HashMap<i32, Vec<Gesture>> = HashMap::new();
        let mut hold_map: HashMap<i32, Vec<Gesture>> = HashMap::new();

        for gesture in &config.gestures {
            match gesture {
                Gesture::Swipe(swipe) => {
                    swipe_map
                        .entry(swipe.fingers)
                        .or_default()
                        .push(gesture.clone());
                }
                Gesture::Pinch(pinch) => {
                    pinch_map
                        .entry(pinch.fingers)
                        .or_default()
                        .push(gesture.clone());
                }
                Gesture::Hold(hold) => {
                    hold_map
                        .entry(hold.fingers)
                        .or_default()
                        .push(gesture.clone());
                }
                Gesture::None => {}
            }
        }

        self.cache.swipe_gestures = swipe_map;
        self.cache.pinch_gestures = pinch_map;
        self.cache.hold_gestures = hold_map;
        self.cache.last_update = std::time::Instant::now();
    }

    fn refresh_cache_if_needed(&mut self) {
        if self.cache.last_update.elapsed() > std::time::Duration::from_secs(1) {
            self.update_cache();
        }
    }

    fn handle_matching_gesture<F>(
        &mut self,
        fingers: i32,
        mh: &mut impl MouseActions,
        handler: F,
    ) -> Result<()>
    where
        F: Fn(&Gesture, &mut dyn MouseActions) -> Result<()>,
    {
        self.refresh_cache_if_needed();

        if let Gesture::Swipe(_) = &self.event {
            if let Some(gestures) = self.cache.swipe_gestures.get(&fingers) {
                for gesture in gestures {
                    handler(gesture, mh)?;
                }
            }
        }
        Ok(())
    }

    fn is_direct_mouse_gesture(gesture: &Gesture) -> bool {
        if let Gesture::Swipe(j) = gesture {
            j.acceleration.is_some() && j.mouse_up_delay.is_some() && j.direction == SwipeDir::Any
        } else {
            false
        }
    }

    fn note_input(&mut self) {
        self.last_input_wall = Some(std::time::SystemTime::now());
    }

    /// 复位所有拖拽/live 手势状态（不发送鼠标事件）
    fn reset_drag(&mut self) {
        self.drag_state = DragState::Idle;
        self.event = Gesture::None;
        self.last_drag_activity = None;
        self.drag_started = None;
        self.pending_release_deadline = None;
        self.live_direction = None;
        self.live_hold_dir = None;
        self.live_hold_count = 0;
        self.live_cum_dx = 0.0;
        self.live_cum_dy = 0.0;
        self.live_axis_delta = 0.0;
        self.live_orientation = None;
    }

    /// 长时间没有输入（熄屏/休眠）后，任何残留的拖拽状态都已失效：
    /// 先释放左键再复位，避免唤醒后的第一个触摸被当成“续拖”按下左键。
    fn check_stale_drag(&mut self, mh: &mut impl MouseActions) {
        if self.drag_state == DragState::Idle {
            return;
        }
        let Some(last) = self.last_input_wall else {
            return;
        };
        let gap = std::time::SystemTime::now()
            .duration_since(last)
            .unwrap_or_default();
        if gap >= STALE_DRAG_GAP {
            log::error!(
                "No input for {:?} while drag state is {:?}, releasing stale button",
                gap,
                self.drag_state
            );
            mh.mouse_up_immediate(1);
            self.reset_drag();
        }
    }

    /// Release a held drag button and reset drag state to Idle
    fn release_drag(&mut self, mh: &mut impl MouseActions, reason: &str) {
        log::error!("{}", reason);
        mh.mouse_up_immediate(1);
        self.drag_state = DragState::Idle;
        self.last_drag_activity = None;
        self.drag_started = None;
        self.pending_release_deadline = None;
    }

    fn handle_swipe_begin(&mut self, fingers: i32, mh: &mut impl MouseActions) -> Result<()> {
        // 新手势开始，重置 live 方向状态
        self.live_direction = None;
        self.live_hold_dir = None;
        self.live_hold_count = 0;
        self.live_cum_dx = 0.0;
        self.live_cum_dy = 0.0;
        self.live_axis_delta = 0.0;
        self.live_orientation = None;

        // ── PENDING_RELEASE: 延迟窗口内手指重新放回触控板 ──
        if self.drag_state == DragState::PendingRelease {
            if fingers == 3 {
                // 三指回来 → 取消定时器，继续拖拽
                log::debug!("3-finger re-touch during drag delay, continuing drag");
                self.pending_release_deadline = None;
                self.drag_state = DragState::Active;
                self.last_drag_activity = Some(std::time::Instant::now());
                self.drag_started = Some(std::time::Instant::now());
                self.event = Gesture::Swipe(Swipe::new(fingers));
                mh.mouse_down(1); // mouse_down 会取消 timer
                return Ok(());
            } else {
                // 非三指 → 立即释放，然后作为新手势正常处理
                log::debug!("{}-finger swipe during drag delay, releasing", fingers);
                self.pending_release_deadline = None;
                self.drag_state = DragState::Idle;
                self.drag_started = None;
                mh.mouse_up_immediate(1);
                // fall through 到下面的正常 begin 处理
            }
        }

        // 确保缓存是最新的，再判断是否有 direct mouse 手势匹配
        self.refresh_cache_if_needed();

        let is_direct = self
            .cache
            .swipe_gestures
            .get(&fingers)
            .map(|gestures| gestures.iter().any(Self::is_direct_mouse_gesture))
            .unwrap_or(false);

        // ── ACTIVE 状态下手指数变化（如 3 指拖拽 → 4 指滑动）──
        // 新手势不匹配 direct mouse 手势时必须先释放按住的左键，
        // 否则虚拟左键会一直按住，后续所有点击都会失效。
        if self.drag_state == DragState::Active && !is_direct {
            self.release_drag(
                mh,
                "Gesture finger count changed during active drag, releasing held button",
            );
        }

        self.event = Gesture::Swipe(Swipe::new(fingers));

        // 已经处于 Active 时（例如唤醒时 libinput 重复发送 Begin），
        // 不要重复按下左键，避免 down/down/up 序列让状态机混乱。
        let should_press = self.drag_state != DragState::Active;
        self.handle_matching_gesture(fingers, mh, |gesture, mh| {
            if Self::is_direct_mouse_gesture(gesture) {
                if should_press {
                    log::debug!("Using direct mouse control");
                    mh.mouse_down(1);
                } else {
                    log::debug!(
                        "Swipe begin while drag already active, skipping duplicate mouse_down"
                    );
                }
            } else if let Gesture::Swipe(j) = gesture {
                if j.direction == SwipeDir::Any {
                    exec_command_from_string(j.start.as_deref().unwrap_or(""), 0.0, 0.0, 0.0, 0.0)?;
                }
            }
            Ok(())
        })?;

        if is_direct {
            self.drag_state = DragState::Active;
            self.last_drag_activity = Some(std::time::Instant::now());
            self.drag_started = Some(std::time::Instant::now());
        }

        Ok(())
    }

    /// live 手势：累计位移确定主方向并锁定；换向需要足够位移，
    /// 避免轻微抖动导致误触发或打断。
    fn update_live_direction(&mut self, dx: f64, dy: f64, fingers: i32) -> Result<()> {
        self.refresh_cache_if_needed();

        let has_live = self
            .cache
            .swipe_gestures
            .get(&fingers)
            .map(|gestures| {
                gestures
                    .iter()
                    .any(|g| matches!(g, Gesture::Swipe(j) if j.live.unwrap_or(false)))
            })
            .unwrap_or(false);
        if !has_live {
            return Ok(());
        }

        self.live_cum_dx += dx;
        self.live_cum_dy += dy;

        match self.live_orientation {
            // 尚未确定主方向：累计位移达到阈值后，按主导轴确定并锁定
            None => {
                let dist_x = self.live_cum_dx.abs();
                let dist_y = self.live_cum_dy.abs();
                if dist_x.max(dist_y) < LIVE_START_THRESHOLD {
                    return Ok(());
                }

                let orientation = if dist_x > dist_y {
                    LiveOrientation::Horizontal
                } else {
                    LiveOrientation::Vertical
                };
                let dir = match orientation {
                    LiveOrientation::Horizontal => {
                        if self.live_cum_dx > 0.0 {
                            SwipeDir::E
                        } else {
                            SwipeDir::W
                        }
                    }
                    LiveOrientation::Vertical => {
                        if self.live_cum_dy > 0.0 {
                            SwipeDir::S
                        } else {
                            SwipeDir::N
                        }
                    }
                };

                self.live_orientation = Some(orientation);
                self.live_direction = Some(dir.clone());
                self.live_axis_delta = 0.0;
                self.live_hold_dir = None;
                self.live_hold_count = 0;
                self.fire_live_command(dir.clone(), fingers)?;
                log::info!("Live gesture started: {:?}", dir);
            }
            // 主方向已锁定：只接受同方向轴的事件，反向需要足够位移
            Some(orientation) => {
                let candidate = if dx.abs() >= dy.abs() {
                    if dx > 0.0 {
                        SwipeDir::E
                    } else {
                        SwipeDir::W
                    }
                } else if dy > 0.0 {
                    SwipeDir::S
                } else {
                    SwipeDir::N
                };

                let candidate_orientation = match candidate {
                    SwipeDir::E | SwipeDir::W => LiveOrientation::Horizontal,
                    SwipeDir::N | SwipeDir::S => LiveOrientation::Vertical,
                    _ => return Ok(()),
                };
                // 另一方向轴的分量视为抖动，忽略且不打断当前方向
                if candidate_orientation != orientation {
                    return Ok(());
                }

                if self.live_hold_dir == Some(candidate.clone()) {
                    self.live_hold_count = self.live_hold_count.saturating_add(1);
                } else {
                    self.live_hold_dir = Some(candidate.clone());
                    self.live_hold_count = 1;
                    // 换向从零开始累计，打断灵敏度只取决于反向划了多少
                    self.live_axis_delta = 0.0;
                }

                // 沿锁定轴累计位移（带符号），用于换向判定
                self.live_axis_delta += match orientation {
                    LiveOrientation::Vertical => dy,
                    LiveOrientation::Horizontal => dx,
                };

                let enough_movement = match candidate {
                    SwipeDir::N => self.live_axis_delta <= -LIVE_REVERSE_THRESHOLD,
                    SwipeDir::S => self.live_axis_delta >= LIVE_REVERSE_THRESHOLD,
                    SwipeDir::W => self.live_axis_delta <= -LIVE_REVERSE_THRESHOLD,
                    SwipeDir::E => self.live_axis_delta >= LIVE_REVERSE_THRESHOLD,
                    _ => false,
                };

                if self.live_hold_count >= 2
                    && self.live_direction != Some(candidate.clone())
                    && enough_movement
                {
                    self.live_direction = Some(candidate.clone());
                    self.live_axis_delta = 0.0;
                    self.live_hold_dir = None;
                    self.live_hold_count = 0;
                    self.fire_live_command(candidate.clone(), fingers)?;
                    log::info!("Live gesture direction changed: {:?}", candidate);
                }
            }
        }

        Ok(())
    }

    /// 触发与 direction 匹配的所有 live 手势的 end 命令
    fn fire_live_command(&self, direction: SwipeDir, fingers: i32) -> Result<()> {
        if let Some(gestures) = self.cache.swipe_gestures.get(&fingers) {
            for gesture in gestures {
                if let Gesture::Swipe(j) = gesture {
                    if j.live.unwrap_or(false)
                        && (j.direction == direction || j.direction == SwipeDir::Any)
                    {
                        exec_command_from_string(
                            j.end.as_deref().unwrap_or(""),
                            0.0,
                            0.0,
                            0.0,
                            0.0,
                        )?;
                    }
                }
            }
        }
        Ok(())
    }

    fn handle_swipe_update(&mut self, dx: f64, dy: f64, mh: &mut impl MouseActions) -> Result<()> {
        let swipe_dir = SwipeDir::dir(dx, dy);
        let (fingers, current_dir) = if let Gesture::Swipe(s) = &self.event {
            (s.fingers, swipe_dir.clone())
        } else {
            return Ok(());
        };

        log::debug!("{:?} {:?}", &current_dir, &fingers);

        // live 手势：方向确定或中途改变方向时立即触发，不需要抬手
        self.update_live_direction(dx, dy, fingers)?;

        let is_throttled = !self.throttle.should_update();

        let current_dir = current_dir.clone();
        self.handle_matching_gesture(fingers, mh, move |gesture, mh| {
            if let Gesture::Swipe(j) = gesture {
                if Self::is_direct_mouse_gesture(gesture) {
                    if !is_throttled {
                        let acceleration = j.acceleration.unwrap_or_default() as f64 / 10.0;
                        mh.move_mouse_relative(
                            (dx * acceleration) as i32,
                            (dy * acceleration) as i32,
                        );
                    }
                } else if (j.direction == current_dir || j.direction == SwipeDir::Any)
                    && !is_throttled
                {
                    exec_update_command_from_string(
                        j.update.as_deref().unwrap_or(""),
                        dx,
                        dy,
                        0.0,
                        0.0,
                    )?;
                }
            }
            Ok(())
        })?;

        // Refresh activity timestamp on any non-zero movement
        if (dx != 0.0 || dy != 0.0) && self.drag_state == DragState::Active {
            self.last_drag_activity = Some(std::time::Instant::now());
        }

        self.event = Gesture::Swipe(Swipe::with_direction(fingers, swipe_dir));
        Ok(())
    }

    fn handle_swipe_end(&mut self, mh: &mut impl MouseActions) -> Result<()> {
        let (fingers, direction) = if let Gesture::Swipe(s) = &self.event {
            (s.fingers, s.direction.clone())
        } else {
            return Ok(());
        };

        // 预先获取 direct mouse gesture 的 delay 值（闭包是 Fn，不能捕获 &mut）
        self.refresh_cache_if_needed();

        let delay = self
            .cache
            .swipe_gestures
            .get(&fingers)
            .and_then(|gestures| {
                gestures.iter().find_map(|g| {
                    if let Gesture::Swipe(j) = g {
                        if Self::is_direct_mouse_gesture(g) {
                            return j.mouse_up_delay;
                        }
                    }
                    None
                })
            })
            .unwrap_or(0);

        let is_direct = self
            .cache
            .swipe_gestures
            .get(&fingers)
            .map(|gestures| gestures.iter().any(Self::is_direct_mouse_gesture))
            .unwrap_or(false);

        // 兜底：非 direct 手势结束时若拖拽仍处于 Active，强制释放左键
        if self.drag_state == DragState::Active && !is_direct {
            self.release_drag(
                mh,
                "Non-direct gesture ended during active drag, releasing held button",
            );
        }

        self.handle_matching_gesture(fingers, mh, |gesture, mh| {
            if let Gesture::Swipe(j) = gesture {
                if Self::is_direct_mouse_gesture(gesture) {
                    mh.mouse_up_delay(1, delay);
                } else if !j.live.unwrap_or(false)
                    && (j.direction == direction || j.direction == SwipeDir::Any)
                {
                    exec_command_from_string(j.end.as_deref().unwrap_or(""), 0.0, 0.0, 0.0, 0.0)?;
                }
            }
            Ok(())
        })?;

        // live 兜底：手势过程中从未提交过方向（例如很短的快速滑动），
        // 抬手时按最终方向补触发一次；已触发的方向不再重复触发。
        if self.live_direction.is_none() {
            if let Some(gestures) = self.cache.swipe_gestures.get(&fingers) {
                for gesture in gestures {
                    if let Gesture::Swipe(j) = gesture {
                        if j.live.unwrap_or(false)
                            && (j.direction == direction || j.direction == SwipeDir::Any)
                        {
                            exec_command_from_string(
                                j.end.as_deref().unwrap_or(""),
                                0.0,
                                0.0,
                                0.0,
                                0.0,
                            )?;
                        }
                    }
                }
            }
        }

        if delay > 0 {
            log::debug!("Entering PendingRelease state, waiting for timer or re-touch");
            // 延迟释放定时器 + 少量宽限；到期后无论定时器是否成功发送，
            // 状态机都强制回到 Idle 并再补一次释放，避免一直停留在 PendingRelease。
            self.pending_release_deadline = Some(
                std::time::Instant::now()
                    + std::time::Duration::from_millis(delay.max(0) as u64)
                    + std::time::Duration::from_millis(250),
            );
            self.drag_state = DragState::PendingRelease;
        } else {
            self.drag_state = DragState::Idle;
            self.last_drag_activity = None;
            self.drag_started = None;
            self.pending_release_deadline = None;
        }
        // 保留 live 字段复位（event 已在上面/后面统一复位）
        self.event = Gesture::None;
        self.live_direction = None;
        self.live_hold_dir = None;
        self.live_hold_count = 0;
        self.live_cum_dx = 0.0;
        self.live_cum_dy = 0.0;
        self.live_axis_delta = 0.0;
        self.live_orientation = None;
        Ok(())
    }

    fn handle_swipe_cancel(&mut self, mh: &mut impl MouseActions) -> Result<()> {
        let fingers = if let Gesture::Swipe(s) = &self.event {
            s.fingers
        } else {
            return Ok(());
        };

        let is_direct = self
            .cache
            .swipe_gestures
            .get(&fingers)
            .map(|gestures| gestures.iter().any(Self::is_direct_mouse_gesture))
            .unwrap_or(false);

        // 兜底：非 direct 手势取消时若拖拽仍处于 Active，强制释放左键
        if self.drag_state == DragState::Active && !is_direct {
            self.release_drag(
                mh,
                "Non-direct gesture cancelled during active drag, releasing held button",
            );
        }

        self.handle_matching_gesture(fingers, mh, |gesture, mh| {
            if Self::is_direct_mouse_gesture(gesture) {
                mh.mouse_up_immediate(1);
            }
            Ok(())
        })?;
        self.drag_state = DragState::Idle;
        self.last_drag_activity = None;
        self.drag_started = None;
        self.pending_release_deadline = None;
        self.event = Gesture::None;
        self.live_direction = None;
        self.live_hold_dir = None;
        self.live_hold_count = 0;
        self.live_cum_dx = 0.0;
        self.live_cum_dy = 0.0;
        self.live_axis_delta = 0.0;
        self.live_orientation = None;
        Ok(())
    }

    /// Handle pointer events (single-finger clicks and motion) during a drag
    fn handle_pointer_event(
        &mut self,
        event: PointerEvent,
        mh: &mut impl MouseActions,
    ) -> Result<()> {
        if self.drag_state == DragState::Idle {
            return Ok(());
        }

        // ydotool 虚拟设备会回灌我们自己发送的鼠标按下/释放/移动事件，
        // 这些不是真实用户输入，必须忽略，否则会立刻打断自己的拖拽。
        if event.device().name() == "ydotoold virtual device" {
            return Ok(());
        }

        log::error!(
            "Single-finger pointer input while drag {:?}, releasing immediately",
            self.drag_state
        );
        mh.mouse_up_immediate(1);
        self.reset_drag();
        Ok(())
    }

    /// Cancel pending release: release mouse and reset to Idle
    fn cancel_pending_release(&mut self, mh: &mut impl MouseActions) {
        if self.drag_state == DragState::PendingRelease {
            log::error!("New non-swipe gesture during drag delay, releasing immediately");
            mh.mouse_up_immediate(1);
            self.reset_drag();
        }
    }

    /// Check if drag is stuck or exceeded hard timeout, auto-release
    fn check_drag_stuck(&mut self, mh: &mut impl MouseActions) -> Result<()> {
        // Hard timeout: any drag exceeding 10s is force-released regardless of state
        if let Some(start) = self.drag_started {
            if start.elapsed() > std::time::Duration::from_secs(10) {
                log::error!("HARD TIMEOUT: drag exceeded 10s, forcing release");
                mh.mouse_up_immediate(1);
                self.reset_drag();
                return Ok(());
            }
        }

        // PendingRelease 过期：延迟释放定时器已经（或应该已经）发送 mouse_up。
        // 不管反馈事件是否到达，都强制回到 Idle，并补一次释放作为兜底。
        if self.drag_state == DragState::PendingRelease {
            if let Some(deadline) = self.pending_release_deadline {
                if std::time::Instant::now() >= deadline {
                    log::error!("PendingRelease deadline exceeded, retrying mouse release");
                    mh.mouse_up_immediate(1);
                    self.reset_drag();
                }
            }
            return Ok(());
        }

        // Soft timeout: no movement for 2s while Active
        if self.drag_state != DragState::Active {
            return Ok(());
        }
        if let Some(last) = self.last_drag_activity {
            if last.elapsed() > std::time::Duration::from_secs(2) {
                log::error!("Drag stuck (no movement for 2s), auto-releasing");
                mh.mouse_up_immediate(1);
                self.reset_drag();
            }
        }
        Ok(())
    }
}

// Add this helper impl
impl Swipe {
    fn new(fingers: i32) -> Self {
        Self {
            direction: SwipeDir::Any,
            fingers,
            update: None,
            start: None,
            end: None,
            acceleration: None,
            mouse_up_delay: None,
            live: None,
        }
    }

    fn with_direction(fingers: i32, direction: SwipeDir) -> Self {
        Self {
            direction,
            fingers,
            update: None,
            start: None,
            end: None,
            acceleration: None,
            mouse_up_delay: None,
            live: None,
        }
    }
}

pub struct Interface;

impl LibinputInterface for Interface {
    #[inline]
    fn open_restricted(&mut self, path: &Path, flags: i32) -> Result<OwnedFd, i32> {
        OpenOptions::new()
            .custom_flags(flags)
            .read(flags & OFlag::O_RDWR.bits() != 0)
            .write((flags & OFlag::O_WRONLY.bits() != 0) | (flags & OFlag::O_RDWR.bits() != 0))
            .open(path)
            .map(Into::into)
            .map_err(|err| err.raw_os_error().unwrap_or(-1))
    }

    #[inline]
    fn close_restricted(&mut self, fd: OwnedFd) {
        drop(fd);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    struct MockMouseHandler {
        mouse_down_calls: Vec<i32>,
        mouse_up_calls: Vec<(i32, i64)>,
    }

    impl MockMouseHandler {
        fn new() -> Self {
            Self {
                mouse_down_calls: Vec::new(),
                mouse_up_calls: Vec::new(),
            }
        }
    }

    impl MouseActions for MockMouseHandler {
        fn mouse_down(&mut self, button: i32) {
            self.mouse_down_calls.push(button);
        }

        fn mouse_up_delay(&mut self, button: i32, delay_ms: i64) {
            self.mouse_up_calls.push((button, delay_ms));
        }

        fn mouse_up_immediate(&mut self, button: i32) {
            self.mouse_up_calls.push((button, 0));
        }

        fn move_mouse_relative(&mut self, _x_val: i32, _y_val: i32) {}
    }

    #[test]
    fn cancelled_swipe_releases_direct_mouse_drag() {
        let config = Config {
            throttle_fps: None,
            gestures: vec![Gesture::Swipe(Swipe {
                direction: SwipeDir::Any,
                fingers: 3,
                update: None,
                start: None,
                end: None,
                acceleration: Some(20),
                mouse_up_delay: Some(500),
                live: None,
            })],
        };
        let mut handler = EventHandler::new(Arc::new(RwLock::new(config)));
        handler.event = Gesture::Swipe(Swipe::new(3));

        let mut mock_mouse = MockMouseHandler::new();
        handler
            .handle_swipe_cancel(&mut mock_mouse)
            .expect("cancelled swipe should be handled");

        assert_eq!(mock_mouse.mouse_up_calls, vec![(1, 0)]);
        assert_eq!(handler.event, Gesture::None);
    }

    #[test]
    fn pending_release_three_finger_swipe_begin_continues_drag() {
        let config = Config {
            throttle_fps: None,
            gestures: vec![Gesture::Swipe(Swipe {
                direction: SwipeDir::Any,
                fingers: 3,
                update: None,
                start: None,
                end: None,
                acceleration: Some(20),
                mouse_up_delay: Some(500),
                live: None,
            })],
        };
        let mut handler = EventHandler::new(Arc::new(RwLock::new(config)));
        // Simulate PendingRelease state
        handler.drag_state = DragState::PendingRelease;

        let mut mock_mouse = MockMouseHandler::new();
        handler
            .handle_swipe_begin(3, &mut mock_mouse)
            .expect("3-finger begin during pending release should continue drag");

        // Should have called mouse_down to re-engage drag
        // (mouse_down_calls not tracked in mock, but should not be mouse_up)
        assert_eq!(mock_mouse.mouse_up_calls, vec![]);
        assert_eq!(handler.drag_state, DragState::Active);
        assert_eq!(
            handler.event,
            Gesture::Swipe(Swipe {
                direction: SwipeDir::Any,
                fingers: 3,
                update: None,
                start: None,
                end: None,
                acceleration: None,
                mouse_up_delay: None,
                live: None,
            })
        );
    }

    #[test]
    fn pending_release_two_finger_swipe_begin_releases() {
        let config = Config {
            throttle_fps: None,
            gestures: vec![Gesture::Swipe(Swipe {
                direction: SwipeDir::Any,
                fingers: 3,
                update: None,
                start: None,
                end: None,
                acceleration: Some(20),
                mouse_up_delay: Some(500),
                live: None,
            })],
        };
        let mut handler = EventHandler::new(Arc::new(RwLock::new(config)));
        handler.drag_state = DragState::PendingRelease;

        let mut mock_mouse = MockMouseHandler::new();
        handler
            .handle_swipe_begin(2, &mut mock_mouse)
            .expect("2-finger begin during pending release should release");

        // Should have called mouse_up_immediate
        assert_eq!(mock_mouse.mouse_up_calls, vec![(1, 0)]);
        assert_eq!(handler.drag_state, DragState::Idle);
    }

    #[test]
    fn pending_release_cancel_pending_release_releases() {
        let mut handler = EventHandler::new(Arc::new(RwLock::new(Config::default())));
        handler.drag_state = DragState::PendingRelease;

        let mut mock_mouse = MockMouseHandler::new();
        handler.cancel_pending_release(&mut mock_mouse);

        assert_eq!(mock_mouse.mouse_up_calls, vec![(1, 0)]);
        assert_eq!(handler.drag_state, DragState::Idle);
        assert_eq!(handler.event, Gesture::None);
    }

    #[test]
    fn pending_release_has_no_effect_in_active_state() {
        let config = Config {
            throttle_fps: None,
            gestures: vec![Gesture::Swipe(Swipe {
                direction: SwipeDir::Any,
                fingers: 3,
                update: None,
                start: None,
                end: None,
                acceleration: Some(20),
                mouse_up_delay: Some(500),
                live: None,
            })],
        };
        let mut handler = EventHandler::new(Arc::new(RwLock::new(config)));
        handler.drag_state = DragState::Active;
        handler.event = Gesture::Swipe(Swipe::new(3));

        let mut mock_mouse = MockMouseHandler::new();
        handler
            .handle_swipe_begin(3, &mut mock_mouse)
            .expect("normal begin should work in Active state");

        // Should go through normal path (no mouse_up)
        assert_eq!(mock_mouse.mouse_up_calls, vec![]);
        assert_eq!(handler.drag_state, DragState::Active);
    }

    #[test]
    fn duplicate_begin_in_active_does_not_press_again() {
        let mut handler = EventHandler::new(Arc::new(RwLock::new(direct_drag_config())));
        handler.drag_state = DragState::Active;
        handler.event = Gesture::Swipe(Swipe::new(3));

        let mut mock_mouse = MockMouseHandler::new();
        handler
            .handle_swipe_begin(3, &mut mock_mouse)
            .expect("duplicate begin should be handled");

        // 已经 Active 时重复 Begin 不应再次按下左键
        assert_eq!(mock_mouse.mouse_down_calls, vec![]);
        assert_eq!(mock_mouse.mouse_up_calls, vec![]);
        assert_eq!(handler.drag_state, DragState::Active);
    }

    #[test]
    fn stale_drag_gap_releases_and_resets() {
        let mut handler = EventHandler::new(Arc::new(RwLock::new(direct_drag_config())));
        handler.drag_state = DragState::PendingRelease;
        handler.last_input_wall =
            Some(std::time::SystemTime::now() - std::time::Duration::from_secs(11));

        let mut mock_mouse = MockMouseHandler::new();
        handler.check_stale_drag(&mut mock_mouse);

        assert_eq!(mock_mouse.mouse_up_calls, vec![(1, 0)]);
        assert_eq!(handler.drag_state, DragState::Idle);
        assert_eq!(handler.event, Gesture::None);
        assert!(handler.pending_release_deadline.is_none());
    }

    #[test]
    fn pending_release_deadline_expires() {
        let mut handler = EventHandler::new(Arc::new(RwLock::new(direct_drag_config())));
        handler.drag_state = DragState::PendingRelease;
        handler.pending_release_deadline =
            Some(std::time::Instant::now() - std::time::Duration::from_millis(1));

        let mut mock_mouse = MockMouseHandler::new();
        handler
            .check_drag_stuck(&mut mock_mouse)
            .expect("stuck check should succeed");

        assert_eq!(mock_mouse.mouse_up_calls, vec![(1, 0)]);
        assert_eq!(handler.drag_state, DragState::Idle);
        assert!(handler.pending_release_deadline.is_none());
    }

    #[test]
    fn drag_stuck_timeout_releases() {
        let config = Config {
            throttle_fps: None,
            gestures: vec![Gesture::Swipe(Swipe {
                direction: SwipeDir::Any,
                fingers: 3,
                update: None,
                start: None,
                end: None,
                acceleration: Some(20),
                mouse_up_delay: Some(500),
                live: None,
            })],
        };
        let mut handler = EventHandler::new(Arc::new(RwLock::new(config)));
        handler.drag_state = DragState::Active;
        handler.last_drag_activity =
            Some(std::time::Instant::now() - std::time::Duration::from_secs(3));

        let mut mock_mouse = MockMouseHandler::new();
        handler
            .check_drag_stuck(&mut mock_mouse)
            .expect("stuck check should succeed");

        assert_eq!(mock_mouse.mouse_up_calls, vec![(1, 0)]);
        assert_eq!(handler.drag_state, DragState::Idle);
        assert_eq!(handler.event, Gesture::None);
        assert!(handler.last_drag_activity.is_none());
    }

    #[test]
    fn drag_stuck_not_active_noop() {
        let mut handler = EventHandler::new(Arc::new(RwLock::new(Config::default())));
        handler.drag_state = DragState::PendingRelease;
        handler.last_drag_activity =
            Some(std::time::Instant::now() - std::time::Duration::from_secs(3));

        let mut mock_mouse = MockMouseHandler::new();
        handler
            .check_drag_stuck(&mut mock_mouse)
            .expect("stuck check should succeed in PendingRelease");

        // Should be no-op in non-Active state
        assert_eq!(mock_mouse.mouse_up_calls, vec![]);
        assert_eq!(handler.drag_state, DragState::PendingRelease);
    }

    fn direct_drag_config() -> Config {
        Config {
            throttle_fps: None,
            gestures: vec![Gesture::Swipe(Swipe {
                direction: SwipeDir::Any,
                fingers: 3,
                update: None,
                start: None,
                end: None,
                acceleration: Some(20),
                mouse_up_delay: Some(500),
                live: None,
            })],
        }
    }

    #[test]
    fn active_drag_begin_with_different_finger_count_releases() {
        let mut handler = EventHandler::new(Arc::new(RwLock::new(direct_drag_config())));
        handler.drag_state = DragState::Active;
        handler.event = Gesture::Swipe(Swipe::new(3));

        let mut mock_mouse = MockMouseHandler::new();
        handler
            .handle_swipe_begin(4, &mut mock_mouse)
            .expect("4-finger begin should be handled");

        // The held button must be released immediately, otherwise all clicks
        // after a 3->4 finger transition stay dead.
        assert_eq!(mock_mouse.mouse_up_calls, vec![(1, 0)]);
        assert_eq!(handler.drag_state, DragState::Idle);
        assert!(handler.last_drag_activity.is_none());
        assert!(handler.drag_started.is_none());
        assert_eq!(handler.event, Gesture::Swipe(Swipe::new(4)));
    }

    #[test]
    fn active_drag_non_direct_swipe_end_releases() {
        let mut handler = EventHandler::new(Arc::new(RwLock::new(direct_drag_config())));
        handler.drag_state = DragState::Active;
        handler.event = Gesture::Swipe(Swipe::new(4));

        let mut mock_mouse = MockMouseHandler::new();
        handler
            .handle_swipe_end(&mut mock_mouse)
            .expect("non-direct swipe end should be handled");

        assert_eq!(mock_mouse.mouse_up_calls, vec![(1, 0)]);
        assert_eq!(handler.drag_state, DragState::Idle);
    }

    #[test]
    fn active_drag_non_direct_swipe_cancel_releases() {
        let mut handler = EventHandler::new(Arc::new(RwLock::new(direct_drag_config())));
        handler.drag_state = DragState::Active;
        handler.event = Gesture::Swipe(Swipe::new(4));

        let mut mock_mouse = MockMouseHandler::new();
        handler
            .handle_swipe_cancel(&mut mock_mouse)
            .expect("non-direct swipe cancel should be handled");

        assert_eq!(mock_mouse.mouse_up_calls, vec![(1, 0)]);
        assert_eq!(handler.drag_state, DragState::Idle);
    }

    fn live_swipe_config() -> Config {
        Config {
            throttle_fps: None,
            gestures: vec![
                Gesture::Swipe(Swipe {
                    direction: SwipeDir::N,
                    fingers: 4,
                    update: None,
                    start: None,
                    end: None,
                    acceleration: None,
                    mouse_up_delay: None,
                    live: Some(true),
                }),
                Gesture::Swipe(Swipe {
                    direction: SwipeDir::S,
                    fingers: 4,
                    update: None,
                    start: None,
                    end: None,
                    acceleration: None,
                    mouse_up_delay: None,
                    live: Some(true),
                }),
            ],
        }
    }

    #[test]
    fn live_direction_commits_mid_gesture_without_release() {
        let mut handler = EventHandler::new(Arc::new(RwLock::new(live_swipe_config())));
        handler.event = Gesture::Swipe(Swipe::new(4));

        let mut mock_mouse = MockMouseHandler::new();

        // 第一次向上更新：位移尚未到确认阈值
        handler
            .handle_swipe_update(0.0, -8.0, &mut mock_mouse)
            .expect("swipe update should be handled");
        assert_eq!(handler.live_direction, None);

        // 连续第二次向上：累计位移达到阈值，方向提交（无需抬手）
        handler
            .handle_swipe_update(0.0, -12.0, &mut mock_mouse)
            .expect("swipe update should be handled");
        assert_eq!(handler.live_direction, Some(SwipeDir::N));

        // 继续向上：不重复触发
        handler
            .handle_swipe_update(0.0, -5.0, &mut mock_mouse)
            .expect("swipe update should be handled");
        assert_eq!(handler.live_direction, Some(SwipeDir::N));

        // 中途转向向下：确认后立即提交新方向（无需抬手打断）
        handler
            .handle_swipe_update(0.0, 10.0, &mut mock_mouse)
            .expect("swipe update should be handled");
        assert_eq!(handler.live_direction, Some(SwipeDir::N));
        handler
            .handle_swipe_update(0.0, 8.0, &mut mock_mouse)
            .expect("swipe update should be handled");
        assert_eq!(handler.live_direction, Some(SwipeDir::S));
    }

    #[test]
    fn live_orientation_lock_suppresses_jitter_and_requires_real_reversal() {
        let mut handler = EventHandler::new(Arc::new(RwLock::new(live_swipe_config())));
        handler.event = Gesture::Swipe(Swipe::new(4));

        let mut mock_mouse = MockMouseHandler::new();

        // 上滑确认方向
        handler
            .handle_swipe_update(0.0, -10.0, &mut mock_mouse)
            .expect("swipe update should be handled");
        handler
            .handle_swipe_update(0.0, -12.0, &mut mock_mouse)
            .expect("swipe update should be handled");
        assert_eq!(handler.live_direction, Some(SwipeDir::N));

        // 横向抖动：方向锁定后不触发左右、不打断
        handler
            .handle_swipe_update(3.0, -1.0, &mut mock_mouse)
            .expect("swipe update should be handled");
        handler
            .handle_swipe_update(2.0, -1.0, &mut mock_mouse)
            .expect("swipe update should be handled");
        assert_eq!(handler.live_direction, Some(SwipeDir::N));

        // 继续上滑不重复触发
        handler
            .handle_swipe_update(0.0, -6.0, &mut mock_mouse)
            .expect("swipe update should be handled");
        handler
            .handle_swipe_update(0.0, -5.0, &mut mock_mouse)
            .expect("swipe update should be handled");
        assert_eq!(handler.live_direction, Some(SwipeDir::N));

        // 轻微反向抖动：位移不足（<4），不换向
        handler
            .handle_swipe_update(0.0, 1.0, &mut mock_mouse)
            .expect("swipe update should be handled");
        handler
            .handle_swipe_update(0.0, 2.0, &mut mock_mouse)
            .expect("swipe update should be handled");
        assert_eq!(handler.live_direction, Some(SwipeDir::N));

        // 真正反向：累计位移足够后才切换
        handler
            .handle_swipe_update(0.0, 8.0, &mut mock_mouse)
            .expect("swipe update should be handled");
        assert_eq!(handler.live_direction, Some(SwipeDir::S));
    }
}
