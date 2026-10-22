use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::VecDeque,
    fs,
    io::{BufRead, BufReader, Read, Write},
    mem::{size_of, zeroed},
    net::TcpStream,
    os::windows::{io::AsRawHandle, process::CommandExt},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    ptr::null,
    sync::{mpsc, Arc, Mutex},
    thread,
    time::{Duration, Instant},
};
use windows_sys::Win32::{
    Foundation::{CloseHandle, HANDLE},
    System::{JobObjects::*, Threading::CREATE_NO_WINDOW},
};

pub fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(Some(0)).collect()
}

#[derive(Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Settings {
    pub workspace: String,
    pub public_origin: String,
    pub no_tunnel: bool,
    pub port: u16,
}

impl Settings {
    pub fn load(root: &Path) -> Self {
        let mut settings: Self = fs::read(root.join(".data/desktop.json"))
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default();
        if settings.port == 0 {
            settings.port = 8787;
        }
        if let Ok(port) = std::env::var("PORT") {
            if let Ok(port) = port.parse::<u16>() {
                if port != 0 {
                    settings.port = port;
                }
            }
        }
        if settings.public_origin.is_empty() {
            settings.public_origin = std::env::var("PUBLIC_ORIGIN").unwrap_or_default();
        }
        settings
    }

    fn save(&self, root: &Path) -> Result<(), String> {
        let dir = root.join(".data");
        fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
        let temp = dir.join("desktop.json.tmp");
        fs::write(
            &temp,
            serde_json::to_vec_pretty(self).map_err(|e| e.to_string())?,
        )
        .map_err(|e| e.to_string())?;
        fs::rename(temp, dir.join("desktop.json")).map_err(|e| e.to_string())
    }
}

#[derive(Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Status {
    #[serde(default)]
    pub paired: bool,
    #[serde(default)]
    pub running: bool,
    #[serde(default)]
    pub connected_clients: usize,
    #[serde(default)]
    pub auth_generation: u64,
    #[serde(default)]
    pub process_id: u32,
    #[serde(default)]
    pub workspace_dir: String,
    #[serde(default)]
    pub public_origin: String,
    pub pairing: Option<Value>,
    #[serde(skip)]
    pub owned: bool,
}

pub enum Request {
    Start(Settings),
    Pair,
    Stop { force: bool, exit: bool },
}

pub enum Event {
    Progress(String),
    Status(Status),
    Pair(Value),
    Error(String),
    Stopped,
    Exit,
}

pub type Logs = Arc<Mutex<VecDeque<String>>>;

pub struct Job(pub(crate) HANDLE);

impl Job {
    pub fn new() -> Result<Self, String> {
        unsafe {
            let job = Self(CreateJobObjectW(null(), null()));
            if job.0.is_null() {
                return Err(std::io::Error::last_os_error().to_string());
            }
            let mut info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = zeroed();
            info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            if SetInformationJobObject(
                job.0,
                JobObjectExtendedLimitInformation,
                &info as *const _ as _,
                size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
            ) == 0
            {
                return Err(std::io::Error::last_os_error().to_string());
            }
            Ok(job)
        }
    }

    pub fn attach(&self, child: &mut Child) -> Result<(), String> {
        unsafe {
            if AssignProcessToJobObject(self.0, child.as_raw_handle() as HANDLE) == 0 {
                let error = std::io::Error::last_os_error().to_string();
                let _ = child.kill();
                let _ = child.wait();
                return Err(error);
            }
        }
        Ok(())
    }
}

impl Drop for Job {
    fn drop(&mut self) {
        unsafe {
            CloseHandle(self.0);
        }
    }
}

pub const BACKOFF_SECS: &[u64] = &[1, 2, 4, 8, 15, 30];
pub const STABLE_DURATION: Duration = Duration::from_secs(60);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TunnelMode {
    None,
    Quick,
    Fixed,
}

pub struct TunnelRecovery {
    pub mode: TunnelMode,
    pub fixed_config: Option<PathBuf>,
    pub backoff_index: usize,
    pub next_retry: Option<Instant>,
    pub started_at: Option<Instant>,
    pub exit_notified: bool,
    pub recovering: bool,
    pub stop_requested: bool,
}

impl TunnelRecovery {
    pub fn new(mode: TunnelMode, fixed_config: Option<PathBuf>) -> Self {
        Self {
            mode,
            fixed_config,
            backoff_index: 0,
            next_retry: None,
            started_at: None,
            exit_notified: false,
            recovering: false,
            stop_requested: false,
        }
    }
}

pub trait Clock: Send + Sync {
    fn now(&self) -> Instant;
}

#[derive(Clone, Copy, Default)]
pub struct SystemClock;

impl Clock for SystemClock {
    fn now(&self) -> Instant {
        Instant::now()
    }
}

pub trait TunnelSpawner: Send + Sync {
    fn spawn_fixed(
        &self,
        root: &Path,
        job: &Job,
        config: &Path,
        logs: &Logs,
    ) -> Result<Child, String>;
}

pub struct DefaultTunnelSpawner;

impl TunnelSpawner for DefaultTunnelSpawner {
    fn spawn_fixed(
        &self,
        root: &Path,
        job: &Job,
        config: &Path,
        logs: &Logs,
    ) -> Result<Child, String> {
        let mut command = Command::new("cloudflared");
        command.arg("tunnel").arg("--config").arg(config).arg("run");
        spawn_child(&mut command, root, job, logs, None)
    }
}

pub trait ApiClient: Send + Sync {
    fn request(
        &self,
        port: u16,
        method: &str,
        path: &str,
        token: Option<&str>,
        body: Value,
    ) -> Result<Value, String>;
}

pub struct DefaultApiClient;

impl ApiClient for DefaultApiClient {
    fn request(
        &self,
        port: u16,
        method: &str,
        path: &str,
        token: Option<&str>,
        body: Value,
    ) -> Result<Value, String> {
        http(port, method, path, token, body)
    }
}

pub struct Owned {
    pub job: Job,
    pub daemon: Option<Child>,
    pub tunnel: Option<Child>,
    pub recovery: TunnelRecovery,
}

pub struct Service {
    pub root: PathBuf,
    pub port: u16,
    pub owned: Option<Owned>,
    pub logs: Logs,
    pub clock: Arc<dyn Clock>,
    pub spawner: Arc<dyn TunnelSpawner>,
    pub client: Arc<dyn ApiClient>,
}

impl Service {
    pub fn new_with(
        root: PathBuf,
        port: u16,
        logs: Logs,
        clock: Arc<dyn Clock>,
        spawner: Arc<dyn TunnelSpawner>,
        client: Arc<dyn ApiClient>,
    ) -> Self {
        Self {
            root,
            port,
            owned: None,
            logs,
            clock,
            spawner,
            client,
        }
    }

    fn token(&self) -> Result<String, String> {
        let raw = fs::read(self.root.join(".data/local-control.json"))
            .map_err(|_| "本机控制凭据缺失，请先启动服务。".to_string())?;
        let state: Value = serde_json::from_slice(&raw).map_err(|e| e.to_string())?;
        let token = state["token"].as_str().unwrap_or_default();
        if token.len() < 32
            || !token
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_')
        {
            return Err("本机控制凭据无效。".into());
        }
        Ok(token.into())
    }

    fn api(&self, method: &str, path: &str, body: Value) -> Result<Value, String> {
        let token = self.token()?;
        self.client
            .request(self.port, method, path, Some(&token), body)
    }

    fn status(&self) -> Result<Status, String> {
        let mut status: Status =
            serde_json::from_value(self.api("GET", "/api/local/status", Value::Null)?)
                .map_err(|e| e.to_string())?;
        status.owned = self.owned.is_some();
        if let Some(owned) = &self.owned {
            if owned
                .daemon
                .as_ref()
                .is_some_and(|child| child.id() != status.process_id)
            {
                return Err("端口上的服务进程已变化，启动器未接管该服务。".into());
            }
        }
        Ok(status)
    }

    fn start(&mut self, settings: &Settings, emit: &impl Fn(Event)) -> Result<Status, String> {
        if !Path::new(&settings.workspace).is_dir() {
            return Err("请选择一个存在的项目文件夹。".into());
        }
        if settings.port == 0 {
            return Err("端口不能为 0。".into());
        }
        self.port = settings.port;
        if let Ok(health) = self
            .client
            .request(self.port, "GET", "/api/health", None, Value::Null)
        {
            if health["service"] != "cc-remote" {
                return Err("端口已被其他程序占用。".into());
            }
            self.api(
                "POST",
                "/api/local/projects/register",
                json!({"path": settings.workspace}),
            )?;
            settings.save(&self.root)?;
            let status = self.status()?;
            if let Some(owned) = &mut self.owned {
                if owned.recovery.stop_requested {
                    owned.recovery.stop_requested = false;
                    if owned.recovery.mode == TunnelMode::Fixed && owned.tunnel.is_none() {
                        owned.recovery.recovering = true;
                        owned.recovery.next_retry = Some(self.clock.now());
                    }
                }
            }
            return Ok(status);
        }
        if self.owned.is_some() {
            return Err("已有服务进程，请先停止后重试。".into());
        }
        let daemon_path = self.root.join("dist/src/daemon.js");
        if !daemon_path.is_file() {
            return Err("服务尚未构建，请先运行 npm run build:desktop。".into());
        }
        let config = self.root.join(".run/cloudflared-cc-remote.yml");
        let (tunnel_mode, fixed_config) = if settings.no_tunnel {
            (TunnelMode::None, None)
        } else if config.is_file() {
            (TunnelMode::Fixed, Some(config.clone()))
        } else {
            (TunnelMode::Quick, None)
        };
        let mut owned = Owned {
            job: Job::new()?,
            daemon: None,
            tunnel: None,
            recovery: TunnelRecovery::new(tunnel_mode, fixed_config),
        };
        let mut origin = settings.public_origin.trim().to_string();
        if !settings.no_tunnel {
            emit(Event::Progress("正在启动隧道…".into()));
            if origin.is_empty() && config.is_file() {
                origin = named_origin(&fs::read_to_string(&config).map_err(|e| e.to_string())?)
                    .ok_or("隧道配置中没有 hostname，请填写服务地址。")?;
            }
            if config.is_file() {
                owned.tunnel = Some(
                    self.spawner
                        .spawn_fixed(&self.root, &owned.job, &config, &self.logs)?,
                );
            } else {
                let mut command = Command::new("cloudflared");
                command
                    .arg("tunnel")
                    .arg("--url")
                    .arg(format!("http://127.0.0.1:{}", self.port));
                let (origin_tx, origin_rx) = mpsc::channel();
                owned.tunnel = Some(self.spawn(&mut command, &owned.job, Some(origin_tx))?);
                let deadline = self.clock.now() + Duration::from_secs(30);
                loop {
                    if let Ok(found) = origin_rx.recv_timeout(Duration::from_millis(100)) {
                        if origin.is_empty() {
                            origin = found;
                        }
                        break;
                    }
                    if owned
                        .tunnel
                        .as_mut()
                        .unwrap()
                        .try_wait()
                        .map_err(|e| e.to_string())?
                        .is_some()
                    {
                        return Err("隧道启动失败，请查看日志。".into());
                    }
                    if self.clock.now() > deadline {
                        return Err("等待隧道地址超时，请查看日志。".into());
                    }
                }
            }
            owned.recovery.started_at = Some(self.clock.now());
        }
        if origin.is_empty() {
            origin = format!("http://127.0.0.1:{}", self.port);
        }
        validate_origin(&origin)?;
        emit(Event::Progress("正在启动本机服务…".into()));
        let mut command = Command::new("node");
        command
            .arg(daemon_path)
            .env("HOST", "127.0.0.1")
            .env("PORT", self.port.to_string())
            .env("PUBLIC_ORIGIN", origin.trim_end_matches('/'))
            .env("WORKSPACE_DIR", &settings.workspace)
            .env("CC_REMOTE_DESKTOP", "1");
        owned.daemon = Some(self.spawn(&mut command, &owned.job, None)?);
        self.owned = Some(owned);
        let deadline = self.clock.now() + Duration::from_secs(15);
        loop {
            if let Ok(status) = self.status() {
                if let Err(error) = settings.save(&self.root) {
                    self.owned.take();
                    return Err(error);
                }
                return Ok(status);
            }
            let exited = self
                .owned
                .as_mut()
                .unwrap()
                .daemon
                .as_mut()
                .unwrap()
                .try_wait()
                .map_err(|e| e.to_string())?
                .is_some();
            if exited || self.clock.now() > deadline {
                self.owned.take();
                return Err("本机服务启动失败，请查看日志。".into());
            }
            thread::sleep(Duration::from_millis(100));
        }
    }

    fn spawn(
        &self,
        command: &mut Command,
        job: &Job,
        origin_tx: Option<mpsc::Sender<String>>,
    ) -> Result<Child, String> {
        spawn_child(command, &self.root, job, &self.logs, origin_tx)
    }

    fn stop(&mut self, force: bool) -> Result<(), String> {
        if self.owned.is_none() {
            return Ok(());
        }
        let recovery = &mut self.owned.as_mut().unwrap().recovery;
        recovery.stop_requested = true;
        recovery.next_retry = None;
        let alive = self
            .owned
            .as_mut()
            .unwrap()
            .daemon
            .as_mut()
            .unwrap()
            .try_wait()
            .map_err(|e| e.to_string())?
            .is_none();
        if alive {
            self.status()?;
            self.api("POST", "/api/local/shutdown", json!({"force": force}))?;
            let deadline = Instant::now() + Duration::from_secs(5);
            while self
                .owned
                .as_mut()
                .unwrap()
                .daemon
                .as_mut()
                .unwrap()
                .try_wait()
                .map_err(|e| e.to_string())?
                .is_none()
            {
                if Instant::now() > deadline {
                    return Err("服务仍在退出，请稍后重试。".into());
                }
                thread::sleep(Duration::from_millis(50));
            }
        }
        self.owned.take();
        Ok(())
    }

    pub fn next_poll_timeout(&self) -> Duration {
        if let Some(owned) = &self.owned {
            if owned.recovery.stop_requested {
                return Duration::from_secs(3);
            }
            if let Some(deadline) = owned.recovery.next_retry {
                let now = self.clock.now();
                if deadline <= now {
                    return Duration::ZERO;
                } else {
                    return (deadline - now).min(Duration::from_secs(3));
                }
            }
        }
        Duration::from_secs(3)
    }

    pub fn handle_supervision_tick(&mut self, emit: &impl Fn(Event)) {
        let Some(owned) = &mut self.owned else {
            if let Ok(status) = self.status() {
                emit(Event::Status(status));
            }
            return;
        };

        if let Some(daemon) = &mut owned.daemon {
            match daemon.try_wait() {
                Ok(Some(_)) => {
                    let expected = owned.recovery.stop_requested;
                    self.owned.take();
                    emit(Event::Stopped);
                    if !expected {
                        emit(Event::Error(
                            "本机服务已退出，请查看日志后重新启动。".into(),
                        ));
                    }
                    return;
                }
                Ok(None) => {}
                Err(e) => {
                    emit(Event::Error(format!("检测本机服务状态失败：{e}")));
                }
            }
        }
        if owned.recovery.stop_requested {
            return;
        }

        let now = self.clock.now();

        let mut tunnel_exited = false;
        if let Some(tunnel) = &mut owned.tunnel {
            match tunnel.try_wait() {
                Ok(Some(_)) => {
                    tunnel_exited = true;
                }
                Ok(None) => {
                    if owned.recovery.started_at.is_some_and(|started_at| {
                        now.saturating_duration_since(started_at) >= STABLE_DURATION
                    }) {
                        owned.recovery.backoff_index = 0;
                    }
                }
                Err(e) => {
                    emit(Event::Error(format!("检测隧道状态失败：{e}")));
                }
            }
        }

        if tunnel_exited {
            owned.tunnel = None;
            owned.recovery.started_at = None;
            match owned.recovery.mode {
                TunnelMode::Fixed => {
                    owned.recovery.recovering = true;
                    let delay_secs =
                        BACKOFF_SECS[owned.recovery.backoff_index.min(BACKOFF_SECS.len() - 1)];
                    owned.recovery.backoff_index += 1;
                    owned.recovery.next_retry = Some(now + Duration::from_secs(delay_secs));
                    owned.recovery.exit_notified = true;
                    emit(Event::Error(format!(
                        "固定隧道已退出，将在 {delay_secs} 秒后重试。"
                    )));
                }
                TunnelMode::Quick => {
                    if !owned.recovery.exit_notified {
                        owned.recovery.exit_notified = true;
                        emit(Event::Error(
                            "临时隧道已退出。恢复连接需要更新入口地址并重新配对。".into(),
                        ));
                    }
                }
                TunnelMode::None => {}
            }
        }

        if let Some(deadline) = owned.recovery.next_retry {
            if now >= deadline {
                owned.recovery.next_retry = None;
                if owned.recovery.mode == TunnelMode::Fixed {
                    if let Some(config) = &owned.recovery.fixed_config {
                        let config_path = config.clone();
                        match self.spawner.spawn_fixed(
                            &self.root,
                            &owned.job,
                            &config_path,
                            &self.logs,
                        ) {
                            Ok(child) => {
                                owned.tunnel = Some(child);
                                owned.recovery.started_at = Some(now);
                                owned.recovery.exit_notified = false;
                                emit(Event::Error("固定隧道进程已启动，等待连接。".into()));
                            }
                            Err(e) => {
                                let delay_secs = BACKOFF_SECS
                                    [owned.recovery.backoff_index.min(BACKOFF_SECS.len() - 1)];
                                owned.recovery.backoff_index += 1;
                                owned.recovery.next_retry =
                                    Some(now + Duration::from_secs(delay_secs));
                                emit(Event::Error(format!(
                                    "固定隧道重启失败：{e}，将在 {delay_secs} 秒后重试。"
                                )));
                            }
                        }
                    }
                }
            }
        }

        let (tunnel_abnormal, is_recovering_fixed) = match &self.owned {
            Some(owned) => match owned.recovery.mode {
                TunnelMode::Fixed => (
                    owned.recovery.recovering,
                    owned.tunnel.is_some()
                        && owned.recovery.started_at.is_some_and(|started_at| {
                            now.saturating_duration_since(started_at) >= Duration::from_secs(3)
                        }),
                ),
                TunnelMode::Quick => (owned.recovery.exit_notified, false),
                TunnelMode::None => (false, false),
            },
            None => (false, false),
        };

        if tunnel_abnormal {
            if is_recovering_fixed {
                if let Ok(status) = self.status() {
                    if status.connected_clients > 0 {
                        if let Some(owned) = &mut self.owned {
                            owned.recovery.recovering = false;
                        }
                        emit(Event::Status(status));
                    }
                }
            }
        } else {
            match self.status() {
                Ok(status) => emit(Event::Status(status)),
                Err(_) if self.owned.is_some() => {
                    emit(Event::Error("无法读取服务状态，请查看日志。".into()))
                }
                Err(_) => {}
            }
        }
    }
}

fn spawn_child(
    command: &mut Command,
    root: &Path,
    job: &Job,
    logs: &Logs,
    origin_tx: Option<mpsc::Sender<String>>,
) -> Result<Child, String> {
    let mut child = command
        .current_dir(root)
        .creation_flags(CREATE_NO_WINDOW)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("无法启动 {}：{e}", command.get_program().to_string_lossy()))?;
    job.attach(&mut child)?;
    let mut streams: Vec<Box<dyn std::io::Read + Send>> = Vec::new();
    if let Some(stdout) = child.stdout.take() {
        streams.push(Box::new(stdout));
    }
    if let Some(stderr) = child.stderr.take() {
        streams.push(Box::new(stderr));
    }
    for stream in streams {
        let logs = logs.clone();
        let origin_tx = origin_tx.clone();
        thread::spawn(move || {
            for line in BufReader::new(stream).lines().map_while(Result::ok) {
                if let Some(tx) = &origin_tx {
                    if let Some(origin) = quick_origin(&line) {
                        let _ = tx.send(origin);
                    }
                }
                if line.starts_with("{\"type\":\"cc-remote-pair\"")
                    || line.contains(['▀', '▄', '█'])
                {
                    continue;
                }
                if let Ok(mut logs) = logs.lock() {
                    if logs.len() == 80 {
                        logs.pop_front();
                    }
                    logs.push_back(line.chars().take(500).collect());
                }
            }
        });
    }
    Ok(child)
}

pub fn run(
    root: PathBuf,
    port: u16,
    logs: Logs,
    requests: mpsc::Receiver<Request>,
    emit: impl Fn(Event),
) {
    run_with(
        root,
        port,
        logs,
        requests,
        emit,
        Arc::new(SystemClock),
        Arc::new(DefaultTunnelSpawner),
        Arc::new(DefaultApiClient),
    )
}

pub fn run_with(
    root: PathBuf,
    port: u16,
    logs: Logs,
    requests: mpsc::Receiver<Request>,
    emit: impl Fn(Event),
    clock: Arc<dyn Clock>,
    spawner: Arc<dyn TunnelSpawner>,
    client: Arc<dyn ApiClient>,
) {
    let mut service = Service::new_with(root, port, logs, clock, spawner, client);
    if let Ok(status) = service.status() {
        emit(Event::Status(status));
    }
    loop {
        let timeout = service.next_poll_timeout();
        match requests.recv_timeout(timeout) {
            Ok(Request::Start(settings)) => {
                emit(Event::Progress("正在检查服务…".into()));
                match service.start(&settings, &emit) {
                    Ok(status) => emit(Event::Status(status)),
                    Err(error) => emit(Event::Error(error)),
                }
            }
            Ok(Request::Pair) => match service.api("POST", "/api/local/pairing", Value::Null) {
                Ok(pair) => emit(Event::Pair(pair)),
                Err(error) => emit(Event::Error(error)),
            },
            Ok(Request::Stop { force, exit }) => {
                emit(Event::Progress("正在退出…".into()));
                match service.stop(force) {
                    Ok(()) if exit => {
                        emit(Event::Exit);
                        return;
                    }
                    Ok(()) => emit(Event::Stopped),
                    Err(error) => emit(Event::Error(error)),
                }
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => return,
            Err(mpsc::RecvTimeoutError::Timeout) => {
                service.handle_supervision_tick(&emit);
            }
        }
    }
}

fn named_origin(config: &str) -> Option<String> {
    config.lines().find_map(|line| {
        let host = line
            .trim()
            .strip_prefix("- hostname:")?
            .split_whitespace()
            .next()?;
        Some(format!("https://{}", host.trim_matches(['\'', '"'])))
    })
}

fn quick_origin(line: &str) -> Option<String> {
    line.split_whitespace().find_map(|word| {
        let candidate = word.trim_matches('|');
        let host = candidate.strip_prefix("https://")?;
        if host.ends_with(".trycloudflare.com")
            && host
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'.')
        {
            Some(candidate.into())
        } else {
            None
        }
    })
}

fn validate_origin(origin: &str) -> Result<(), String> {
    let host = origin
        .trim_end_matches('/')
        .strip_prefix("https://")
        .or_else(|| origin.trim_end_matches('/').strip_prefix("http://"));
    if host.is_some_and(|host| {
        !host.is_empty()
            && host
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || b".-:[]".contains(&c))
    }) {
        Ok(())
    } else {
        Err("服务地址应为 http:// 或 https:// 开头的主机地址，不含路径。".into())
    }
}

fn http(
    port: u16,
    method: &str,
    path: &str,
    token: Option<&str>,
    body: Value,
) -> Result<Value, String> {
    let payload = if body.is_null() {
        Vec::new()
    } else {
        serde_json::to_vec(&body).map_err(|e| e.to_string())?
    };
    let mut headers = format!("{method} {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: {}\r\n", payload.len());
    if let Some(token) = token {
        headers.push_str(&format!("X-CC-Remote-Local-Token: {token}\r\n"));
    }
    headers.push_str("\r\n");
    let mut stream = TcpStream::connect_timeout(
        &std::net::SocketAddr::from(([127, 0, 0, 1], port)),
        Duration::from_secs(1),
    )
    .map_err(|e| format!("{path}: {e}"))?;
    stream
        .set_read_timeout(Some(Duration::from_secs(3)))
        .map_err(|e| e.to_string())?;
    stream
        .set_write_timeout(Some(Duration::from_secs(3)))
        .map_err(|e| e.to_string())?;
    stream
        .write_all(headers.as_bytes())
        .and_then(|_| stream.write_all(&payload))
        .map_err(|e| e.to_string())?;
    let mut response = Vec::new();
    stream
        .take(65537)
        .read_to_end(&mut response)
        .map_err(|e| e.to_string())?;
    if response.len() > 65536 {
        return Err("服务响应过大。".into());
    }
    parse_response(path, &response)
}

fn parse_response(path: &str, response: &[u8]) -> Result<Value, String> {
    let end = response
        .windows(4)
        .position(|bytes| bytes == b"\r\n\r\n")
        .filter(|end| *end < 8192)
        .ok_or("服务返回了无效的 HTTP 响应。")?;
    let headers = std::str::from_utf8(&response[..end]).map_err(|e| e.to_string())?;
    let mut lines = headers.split("\r\n");
    let status = lines
        .next()
        .and_then(|line| line.split_whitespace().nth(1))
        .and_then(|code| code.parse::<u16>().ok())
        .ok_or("HTTP 状态码无效。")?;
    let length = lines
        .find_map(|line| {
            let (name, value) = line.split_once(':')?;
            name.eq_ignore_ascii_case("content-length")
                .then(|| value.trim().parse::<usize>().ok())
                .flatten()
        })
        .ok_or("服务响应缺少长度，请重新构建服务。")?;
    let body = &response[end + 4..];
    if length != body.len() {
        return Err("服务响应不完整。".into());
    }
    let value: Value =
        serde_json::from_slice(body).map_err(|_| "服务返回了无效数据。".to_string())?;
    if status != 200 {
        return Err(match value["error"].as_str().unwrap_or("request_failed") {
            "claude_is_busy" => "任务正在运行，请先停止任务或确认强制退出。".into(),
            "invalid_local_control_token" => {
                "服务的控制凭据不匹配，请检查是否从另一个仓库启动。".into()
            }
            error => format!("{path}: {error} (HTTP {status})"),
        });
    }
    Ok(value)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn local_http_rejects_truncated_responses() {
        assert_eq!(
            parse_response(
                "/api/health",
                b"HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\n{\"ok\":true}"
            )
            .unwrap(),
            json!({"ok":true})
        );
        assert!(parse_response(
            "/api/health",
            b"HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\n{}"
        )
        .is_err());
        assert!(parse_response("/api/health", b"HTTP/1.1 200 OK\r\n\r\n{}").is_err());
    }

    #[test]
    fn origins_reject_paths_credentials_and_unrelated_tunnel_text() {
        assert_eq!(
            quick_origin("INF | https://sample-name.trycloudflare.com |"),
            Some("https://sample-name.trycloudflare.com".into())
        );
        assert_eq!(
            quick_origin("https://example.com.trycloudflare.com.evil.test"),
            None
        );
        assert_eq!(
            named_origin("ingress:\n  - hostname: 'remote.example.com'\n"),
            Some("https://remote.example.com".into())
        );
        assert!(validate_origin("https://remote.example.com").is_ok());
        assert!(validate_origin("http://127.0.0.1:8787/").is_ok());
        assert!(validate_origin("https://user:secret@example.com").is_err());
        assert!(validate_origin("https://example.com/api").is_err());
    }
    #[derive(Clone)]
    struct MockClock {
        now: Arc<Mutex<Instant>>,
    }

    impl MockClock {
        fn new(start: Instant) -> Self {
            Self {
                now: Arc::new(Mutex::new(start)),
            }
        }
        fn advance(&self, duration: Duration) {
            let mut lock = self.now.lock().unwrap();
            *lock += duration;
        }
    }

    impl Clock for MockClock {
        fn now(&self) -> Instant {
            *self.now.lock().unwrap()
        }
    }

    struct MockTunnelSpawner {
        calls: Arc<Mutex<usize>>,
        fail: Arc<Mutex<bool>>,
        long_running: bool,
    }

    impl MockTunnelSpawner {
        fn new(fail: bool, long_running: bool) -> Self {
            Self {
                calls: Arc::new(Mutex::new(0)),
                fail: Arc::new(Mutex::new(fail)),
                long_running,
            }
        }
    }

    impl TunnelSpawner for MockTunnelSpawner {
        fn spawn_fixed(
            &self,
            _root: &Path,
            job: &Job,
            _config: &Path,
            _logs: &Logs,
        ) -> Result<Child, String> {
            let mut count = self.calls.lock().unwrap();
            *count += 1;
            if *self.fail.lock().unwrap() {
                return Err("mock spawn failed".into());
            }
            let mut child = if self.long_running {
                Command::new("cmd")
                    .args(["/c", "ping -n 100 127.0.0.1 >nul"])
                    .creation_flags(CREATE_NO_WINDOW)
                    .stdin(Stdio::null())
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .spawn()
                    .map_err(|e| e.to_string())?
            } else {
                Command::new("cmd")
                    .args(["/c", "exit 0"])
                    .creation_flags(CREATE_NO_WINDOW)
                    .stdin(Stdio::null())
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .spawn()
                    .map_err(|e| e.to_string())?
            };
            job.attach(&mut child)?;
            Ok(child)
        }
    }

    struct MockApiClient {
        process_id: Arc<Mutex<u32>>,
        connected_clients: Arc<Mutex<usize>>,
    }

    impl MockApiClient {
        fn new(pid: u32) -> Self {
            Self {
                process_id: Arc::new(Mutex::new(pid)),
                connected_clients: Arc::new(Mutex::new(0)),
            }
        }
    }

    impl ApiClient for MockApiClient {
        fn request(
            &self,
            _port: u16,
            _method: &str,
            path: &str,
            _token: Option<&str>,
            _body: Value,
        ) -> Result<Value, String> {
            match path {
                "/api/health" => Ok(json!({"service": "cc-remote"})),
                "/api/local/status" => Ok(json!({
                    "paired": true,
                    "running": false,
                    "connectedClients": *self.connected_clients.lock().unwrap(),
                    "authGeneration": 1,
                    "processId": *self.process_id.lock().unwrap(),
                    "workspaceDir": "",
                    "publicOrigin": "https://test.example.com",
                })),
                "/api/local/shutdown" => Ok(json!({"ok": true})),
                _ => Ok(json!({"ok": true})),
            }
        }
    }

    struct TestRoot(PathBuf);

    impl TestRoot {
        fn new() -> Self {
            let parent = std::env::var_os("PI_SCRATCH_DIR")
                .map(PathBuf::from)
                .unwrap_or_else(std::env::temp_dir);
            let suffix = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            let root = parent.join(format!(
                "cc-remote-supervision-{}-{suffix}",
                std::process::id()
            ));
            fs::create_dir(&root).unwrap();
            fs::create_dir(root.join(".data")).unwrap();
            fs::write(
                root.join(".data/local-control.json"),
                r#"{"token":"0123456789abcdef0123456789abcdef"}"#,
            )
            .unwrap();
            Self(root)
        }
    }

    impl Drop for TestRoot {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn attached_service_keeps_polling_without_managing_processes() {
        let root = TestRoot::new();
        let clock = Arc::new(MockClock::new(Instant::now()));
        let spawner = Arc::new(MockTunnelSpawner::new(false, true));
        let client = Arc::new(MockApiClient::new(42));
        let mut service = Service::new_with(
            root.0.clone(),
            8787,
            Arc::new(Mutex::new(VecDeque::new())),
            clock.clone(),
            spawner.clone(),
            client.clone(),
        );
        let events = Mutex::new(Vec::new());
        let emit = |event| events.lock().unwrap().push(event);
        service.handle_supervision_tick(&emit);
        *client.connected_clients.lock().unwrap() = 2;
        clock.advance(Duration::from_secs(3));
        service.handle_supervision_tick(&emit);
        let events = events.lock().unwrap();
        assert_eq!(events.len(), 2);
        assert!(
            matches!(&events[1], Event::Status(status) if !status.owned && status.connected_clients == 2)
        );
        assert!(service.owned.is_none());
        assert_eq!(*spawner.calls.lock().unwrap(), 0);
    }

    #[test]
    fn local_control_requires_credentials_even_with_an_injected_client() {
        let root = TestRoot::new();
        fs::remove_file(root.0.join(".data/local-control.json")).unwrap();
        let service = Service::new_with(
            root.0.clone(),
            8787,
            Arc::new(Mutex::new(VecDeque::new())),
            Arc::new(SystemClock),
            Arc::new(MockTunnelSpawner::new(false, true)),
            Arc::new(MockApiClient::new(42)),
        );
        assert!(service.status().is_err());
    }

    fn spawn_dummy_daemon(job: &Job) -> Child {
        let mut child = Command::new("cmd")
            .args(["/c", "ping -n 100 127.0.0.1 >nul"])
            .creation_flags(CREATE_NO_WINDOW)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("failed to spawn dummy daemon");
        job.attach(&mut child)
            .expect("failed to attach dummy daemon to job");
        child
    }

    fn spawn_dummy_exited(job: &Job) -> Child {
        let mut child = Command::new("cmd")
            .args(["/c", "exit 0"])
            .creation_flags(CREATE_NO_WINDOW)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("failed to spawn dummy exited process");
        job.attach(&mut child)
            .expect("failed to attach dummy process to job");
        while child.try_wait().ok().flatten().is_none() {
            thread::sleep(Duration::from_millis(5));
        }
        child
    }

    #[test]
    fn test_fixed_tunnel_restarts_once_at_deadline_and_retains_daemon() {
        let root = TestRoot::new();
        let job = Job::new().unwrap();
        let daemon = spawn_dummy_daemon(&job);
        let daemon_pid = daemon.id();
        let tunnel = spawn_dummy_exited(&job);

        let t0 = Instant::now();
        let clock = Arc::new(MockClock::new(t0));
        let spawner = Arc::new(MockTunnelSpawner::new(false, true));
        let client = Arc::new(MockApiClient::new(daemon_pid));
        let logs: Logs = Arc::new(Mutex::new(VecDeque::new()));

        let mut service = Service::new_with(
            root.0.clone(),
            8787,
            logs,
            clock.clone(),
            spawner.clone(),
            client.clone(),
        );

        let recovery = TunnelRecovery::new(
            TunnelMode::Fixed,
            Some(PathBuf::from(".run/cloudflared-cc-remote.yml")),
        );
        service.owned = Some(Owned {
            job,
            daemon: Some(daemon),
            tunnel: Some(tunnel),
            recovery,
        });

        let events = Arc::new(Mutex::new(Vec::new()));
        let emit = {
            let events = events.clone();
            move |e: Event| events.lock().unwrap().push(e)
        };

        service.handle_supervision_tick(&emit);
        assert_eq!(*spawner.calls.lock().unwrap(), 0);
        assert_eq!(
            service
                .owned
                .as_ref()
                .unwrap()
                .daemon
                .as_ref()
                .unwrap()
                .id(),
            daemon_pid
        );
        {
            let ev = events.lock().unwrap();
            assert_eq!(ev.len(), 1);
            match &ev[0] {
                Event::Error(msg) => assert!(msg.contains("固定隧道已退出，将在 1 秒后重试。")),
                _ => panic!("unexpected event"),
            }
        }

        clock.advance(Duration::from_millis(500));
        service.handle_supervision_tick(&emit);
        assert_eq!(*spawner.calls.lock().unwrap(), 0);
        assert_eq!(
            service
                .owned
                .as_ref()
                .unwrap()
                .daemon
                .as_ref()
                .unwrap()
                .id(),
            daemon_pid
        );

        *client.connected_clients.lock().unwrap() = 1;
        clock.advance(Duration::from_millis(600));
        service.handle_supervision_tick(&emit);
        assert_eq!(*spawner.calls.lock().unwrap(), 1);
        assert_eq!(
            service
                .owned
                .as_ref()
                .unwrap()
                .daemon
                .as_ref()
                .unwrap()
                .id(),
            daemon_pid
        );
        {
            let ev = events.lock().unwrap();
            assert_eq!(ev.len(), 2);
            match &ev[1] {
                Event::Error(msg) => assert_eq!(msg, "固定隧道进程已启动，等待连接。"),
                _ => panic!("unexpected event"),
            }
        }

        service.handle_supervision_tick(&emit);
        assert_eq!(*spawner.calls.lock().unwrap(), 1);
        assert_eq!(
            service
                .owned
                .as_ref()
                .unwrap()
                .daemon
                .as_ref()
                .unwrap()
                .id(),
            daemon_pid
        );
        assert!(!events
            .lock()
            .unwrap()
            .iter()
            .any(|event| matches!(event, Event::Status(_))));
        clock.advance(Duration::from_secs(3));
        service.handle_supervision_tick(&emit);
        assert!(matches!(
            events.lock().unwrap().last(),
            Some(Event::Status(_))
        ));
    }

    #[test]
    fn test_restart_spawn_failure_increments_backoff() {
        let root = TestRoot::new();
        let job = Job::new().unwrap();
        let daemon = spawn_dummy_daemon(&job);
        let daemon_pid = daemon.id();
        let tunnel = spawn_dummy_exited(&job);

        let t0 = Instant::now();
        let clock = Arc::new(MockClock::new(t0));
        let spawner = Arc::new(MockTunnelSpawner::new(true, false));
        let client = Arc::new(MockApiClient::new(daemon_pid));
        let logs: Logs = Arc::new(Mutex::new(VecDeque::new()));

        let mut service = Service::new_with(
            root.0.clone(),
            8787,
            logs,
            clock.clone(),
            spawner.clone(),
            client,
        );

        service.owned = Some(Owned {
            job,
            daemon: Some(daemon),
            tunnel: Some(tunnel),
            recovery: TunnelRecovery::new(
                TunnelMode::Fixed,
                Some(PathBuf::from(".run/cloudflared-cc-remote.yml")),
            ),
        });

        let events = Arc::new(Mutex::new(Vec::new()));
        let emit = {
            let events = events.clone();
            move |e: Event| events.lock().unwrap().push(e)
        };

        service.handle_supervision_tick(&emit);
        assert_eq!(service.owned.as_ref().unwrap().recovery.backoff_index, 1);

        clock.advance(Duration::from_secs(1));
        service.handle_supervision_tick(&emit);
        assert_eq!(*spawner.calls.lock().unwrap(), 1);
        assert_eq!(service.owned.as_ref().unwrap().recovery.backoff_index, 2);
        {
            let ev = events.lock().unwrap();
            let last = ev.last().unwrap();
            match last {
                Event::Error(msg) => {
                    assert!(msg.contains("固定隧道重启失败：mock spawn failed，将在 2 秒后重试。"))
                }
                _ => panic!("unexpected event"),
            }
        }

        clock.advance(Duration::from_secs(1));
        service.handle_supervision_tick(&emit);
        assert_eq!(*spawner.calls.lock().unwrap(), 1);

        clock.advance(Duration::from_millis(1100));
        service.handle_supervision_tick(&emit);
        assert_eq!(*spawner.calls.lock().unwrap(), 2);
        assert_eq!(service.owned.as_ref().unwrap().recovery.backoff_index, 3);
        {
            let ev = events.lock().unwrap();
            let last = ev.last().unwrap();
            match last {
                Event::Error(msg) => {
                    assert!(msg.contains("固定隧道重启失败：mock spawn failed，将在 4 秒后重试。"))
                }
                _ => panic!("unexpected event"),
            }
        }
    }

    #[test]
    fn test_stable_run_resets_backoff() {
        let root = TestRoot::new();
        let job = Job::new().unwrap();
        let daemon = spawn_dummy_daemon(&job);
        let daemon_pid = daemon.id();
        let tunnel = spawn_dummy_daemon(&job);

        let t0 = Instant::now();
        let clock = Arc::new(MockClock::new(t0));
        let spawner = Arc::new(MockTunnelSpawner::new(false, true));
        let client = Arc::new(MockApiClient::new(daemon_pid));
        let logs: Logs = Arc::new(Mutex::new(VecDeque::new()));

        let mut service = Service::new_with(
            root.0.clone(),
            8787,
            logs,
            clock.clone(),
            spawner.clone(),
            client,
        );

        let mut recovery = TunnelRecovery::new(
            TunnelMode::Fixed,
            Some(PathBuf::from(".run/cloudflared-cc-remote.yml")),
        );
        recovery.backoff_index = 3;
        recovery.started_at = Some(t0);
        recovery.recovering = true;

        service.owned = Some(Owned {
            job,
            daemon: Some(daemon),
            tunnel: Some(tunnel),
            recovery,
        });

        let events = Arc::new(Mutex::new(Vec::new()));
        let emit = {
            let events = events.clone();
            move |e: Event| events.lock().unwrap().push(e)
        };

        clock.advance(Duration::from_secs(30));
        service.handle_supervision_tick(&emit);
        assert_eq!(service.owned.as_ref().unwrap().recovery.backoff_index, 3);

        clock.advance(Duration::from_secs(35));
        service.handle_supervision_tick(&emit);
        assert_eq!(service.owned.as_ref().unwrap().recovery.backoff_index, 0);
        assert!(service.owned.as_ref().unwrap().recovery.recovering);

        let _ = service
            .owned
            .as_mut()
            .unwrap()
            .tunnel
            .as_mut()
            .unwrap()
            .kill();
        while service
            .owned
            .as_mut()
            .unwrap()
            .tunnel
            .as_mut()
            .unwrap()
            .try_wait()
            .ok()
            .flatten()
            .is_none()
        {
            thread::sleep(Duration::from_millis(5));
        }

        clock.advance(Duration::from_secs(1));
        service.handle_supervision_tick(&emit);
        {
            let ev = events.lock().unwrap();
            let last = ev.last().unwrap();
            match last {
                Event::Error(msg) => assert!(msg.contains("固定隧道已退出，将在 1 秒后重试。")),
                _ => panic!("unexpected event"),
            }
        }

        {
            let owned = service.owned.as_mut().unwrap();
            owned.tunnel = Some(spawn_dummy_exited(&owned.job));
            owned.recovery.started_at = Some(clock.now());
            owned.recovery.backoff_index = 3;
            owned.recovery.next_retry = None;
        }
        clock.advance(Duration::from_secs(65));
        service.handle_supervision_tick(&emit);
        let recovery = &service.owned.as_ref().unwrap().recovery;
        assert_eq!(recovery.backoff_index, 4);
        assert_eq!(
            recovery.next_retry,
            Some(clock.now() + Duration::from_secs(8))
        );
    }

    #[test]
    fn failed_stop_suspends_recovery_until_an_explicit_start() {
        let root = TestRoot::new();
        let job = Job::new().unwrap();
        let daemon = spawn_dummy_daemon(&job);
        let clock = Arc::new(MockClock::new(Instant::now()));
        let spawner = Arc::new(MockTunnelSpawner::new(false, true));
        let client = Arc::new(MockApiClient::new(daemon.id()));
        let mut service = Service::new_with(
            root.0.clone(),
            8787,
            Arc::new(Mutex::new(VecDeque::new())),
            clock.clone(),
            spawner.clone(),
            client,
        );
        let mut recovery = TunnelRecovery::new(TunnelMode::Fixed, Some(root.0.join("fixed.yml")));
        recovery.next_retry = Some(clock.now() + Duration::from_secs(1));
        recovery.recovering = true;
        service.owned = Some(Owned {
            job,
            daemon: Some(daemon),
            tunnel: None,
            recovery,
        });
        fs::remove_file(root.0.join(".data/local-control.json")).unwrap();
        assert!(service.stop(false).is_err());
        clock.advance(Duration::from_secs(10));
        service.handle_supervision_tick(&|_| {});
        assert_eq!(*spawner.calls.lock().unwrap(), 0);
        assert!(service
            .owned
            .as_ref()
            .unwrap()
            .recovery
            .next_retry
            .is_none());

        fs::write(
            root.0.join(".data/local-control.json"),
            r#"{"token":"0123456789abcdef0123456789abcdef"}"#,
        )
        .unwrap();
        let settings = Settings {
            workspace: root.0.to_string_lossy().into_owned(),
            port: 8787,
            ..Settings::default()
        };
        assert!(service.start(&settings, &|_| {}).is_ok());
        clock.advance(Duration::from_secs(1));
        service.handle_supervision_tick(&|_| {});
        assert_eq!(*spawner.calls.lock().unwrap(), 1);
    }

    #[test]
    fn test_user_stop_cancels_pending_retry() {
        let root = TestRoot::new();
        let job = Job::new().unwrap();
        let daemon = spawn_dummy_daemon(&job);
        let daemon_pid = daemon.id();
        let tunnel = spawn_dummy_exited(&job);

        let t0 = Instant::now();
        let clock = Arc::new(MockClock::new(t0));
        let spawner = Arc::new(MockTunnelSpawner::new(false, true));
        let client = Arc::new(MockApiClient::new(daemon_pid));
        let logs: Logs = Arc::new(Mutex::new(VecDeque::new()));

        let mut service = Service::new_with(
            root.0.clone(),
            8787,
            logs,
            clock.clone(),
            spawner.clone(),
            client,
        );

        service.owned = Some(Owned {
            job,
            daemon: Some(daemon),
            tunnel: Some(tunnel),
            recovery: TunnelRecovery::new(
                TunnelMode::Fixed,
                Some(PathBuf::from(".run/cloudflared-cc-remote.yml")),
            ),
        });

        let events = Arc::new(Mutex::new(Vec::new()));
        let emit = {
            let events = events.clone();
            move |e: Event| events.lock().unwrap().push(e)
        };

        service.handle_supervision_tick(&emit);
        assert!(service
            .owned
            .as_ref()
            .unwrap()
            .recovery
            .next_retry
            .is_some());

        let _ = service
            .owned
            .as_mut()
            .unwrap()
            .daemon
            .as_mut()
            .unwrap()
            .kill();
        while service
            .owned
            .as_mut()
            .unwrap()
            .daemon
            .as_mut()
            .unwrap()
            .try_wait()
            .ok()
            .flatten()
            .is_none()
        {
            thread::sleep(Duration::from_millis(5));
        }
        assert!(service.stop(false).is_ok());
        assert!(service.owned.is_none());

        clock.advance(Duration::from_secs(10));
        service.handle_supervision_tick(&emit);

        assert_eq!(*spawner.calls.lock().unwrap(), 0);
    }

    #[test]
    fn test_quick_tunnel_and_no_tunnel_do_not_restart() {
        let root = TestRoot::new();
        let job = Job::new().unwrap();
        let daemon = spawn_dummy_daemon(&job);
        let daemon_pid = daemon.id();
        let tunnel = spawn_dummy_exited(&job);

        let t0 = Instant::now();
        let clock = Arc::new(MockClock::new(t0));
        let spawner = Arc::new(MockTunnelSpawner::new(false, true));
        let client = Arc::new(MockApiClient::new(daemon_pid));
        let logs: Logs = Arc::new(Mutex::new(VecDeque::new()));

        let mut service = Service::new_with(
            root.0.clone(),
            8787,
            logs,
            clock.clone(),
            spawner.clone(),
            client,
        );

        service.owned = Some(Owned {
            job,
            daemon: Some(daemon),
            tunnel: Some(tunnel),
            recovery: TunnelRecovery::new(TunnelMode::Quick, None),
        });

        let events = Arc::new(Mutex::new(Vec::new()));
        let emit = {
            let events = events.clone();
            move |e: Event| events.lock().unwrap().push(e)
        };

        service.handle_supervision_tick(&emit);
        assert!(service
            .owned
            .as_ref()
            .unwrap()
            .recovery
            .next_retry
            .is_none());
        assert_eq!(*spawner.calls.lock().unwrap(), 0);
        assert_eq!(
            service
                .owned
                .as_ref()
                .unwrap()
                .daemon
                .as_ref()
                .unwrap()
                .id(),
            daemon_pid
        );
        {
            let ev = events.lock().unwrap();
            assert_eq!(ev.len(), 1);
            match &ev[0] {
                Event::Error(msg) => {
                    assert_eq!(msg, "临时隧道已退出。恢复连接需要更新入口地址并重新配对。");
                }
                _ => panic!("unexpected event"),
            }
        }

        clock.advance(Duration::from_secs(10));
        service.handle_supervision_tick(&emit);
        assert_eq!(*spawner.calls.lock().unwrap(), 0);
        assert_eq!(events.lock().unwrap().len(), 1);

        let mut service_no_tunnel = Service::new_with(
            root.0.clone(),
            8787,
            Arc::new(Mutex::new(VecDeque::new())),
            clock.clone(),
            spawner.clone(),
            Arc::new(MockApiClient::new(123)),
        );
        let job_no_tunnel = Job::new().unwrap();
        let daemon_no_tunnel = spawn_dummy_daemon(&job_no_tunnel);
        service_no_tunnel.owned = Some(Owned {
            job: job_no_tunnel,
            daemon: Some(daemon_no_tunnel),
            tunnel: None,
            recovery: TunnelRecovery::new(TunnelMode::None, None),
        });
        service_no_tunnel.handle_supervision_tick(&emit);
        assert_eq!(*spawner.calls.lock().unwrap(), 0);
        assert!(service_no_tunnel
            .owned
            .as_ref()
            .unwrap()
            .recovery
            .next_retry
            .is_none());
    }
}
