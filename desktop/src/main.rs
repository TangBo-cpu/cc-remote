#![cfg_attr(not(test), windows_subsystem = "windows")]

mod service;

use service::{wide, Event, Logs, Request, Settings, Status};
use std::{
    collections::VecDeque,
    mem::{size_of, zeroed},
    path::PathBuf,
    ptr::{null, null_mut},
    sync::{mpsc, Arc, Mutex},
    thread,
    time::{SystemTime, UNIX_EPOCH},
};
use windows_sys::Win32::{
    Foundation::*,
    Graphics::Gdi::*,
    System::{
        Com::*,
        LibraryLoader::GetModuleHandleW,
        SystemServices::{SS_CENTER, SS_ENDELLIPSIS, SS_NOPREFIX},
        Threading::CreateMutexW,
    },
    UI::{
        Accessibility::*, Controls::*, HiDpi::*, Input::KeyboardAndMouse::*, Shell::*,
        WindowsAndMessaging::*,
    },
};

const CLASS: &str = "CCRemoteNativeLauncher";
const EVENTS: u32 = WM_APP + 1;
const TRAY: u32 = WM_APP + 2;
const OPEN: u32 = WM_APP + 3;
const START: usize = 101;
const STOP: usize = 102;
const PAIR: usize = 103;
const BROWSE: usize = 104;
const LOGS: usize = 105;
const EXIT: usize = 106;
const QR_AREA: [i32; 4] = [590, 188, 248, 248];

const fn rgb(value: u32) -> COLORREF {
    ((value & 0xff) << 16) | (value & 0xff00) | ((value >> 16) & 0xff)
}

const CANVAS: COLORREF = rgb(0xF1F5F9);
const SURFACE: COLORREF = rgb(0xFFFFFF);
const INK: COLORREF = rgb(0x1C1C1E);
const MUTED: COLORREF = rgb(0x636B74);
const BORDER: COLORREF = rgb(0x8793A0);
const ACCENT: COLORREF = rgb(0x3877A7);
const DANGER: COLORREF = rgb(0xB54747);

struct LauncherIcons {
    large: HICON,
    small: HICON,
}

impl LauncherIcons {
    unsafe fn load() -> Option<Self> {
        let load = |metric| {
            let size = GetSystemMetrics(metric);
            LoadImageW(
                GetModuleHandleW(null()),
                1usize as _,
                IMAGE_ICON,
                size,
                size,
                0,
            ) as HICON
        };
        let icons = Self {
            large: load(SM_CXICON),
            small: load(SM_CXSMICON),
        };
        if icons.large.is_null() || icons.small.is_null() {
            None
        } else {
            Some(icons)
        }
    }
}

impl Drop for LauncherIcons {
    fn drop(&mut self) {
        unsafe {
            if !self.large.is_null() {
                DestroyIcon(self.large);
            }
            if !self.small.is_null() {
                DestroyIcon(self.small);
            }
        }
    }
}

struct App {
    host: HWND,
    window: HWND,
    fonts: [HFONT; 4],
    dpi: i32,
    high_contrast: bool,
    settings: Settings,
    status: Option<Status>,
    pairing: Option<serde_json::Value>,
    manual_pair: bool,
    qr: Option<Vec<Vec<bool>>>,
    note: String,
    error_note: bool,
    busy: bool,
    workspace: HWND,
    origin: HWND,
    local: HWND,
    status_label: HWND,
    connection_label: HWND,
    note_label: HWND,
    note_detail: HWND,
    pair_label: HWND,
    start: HWND,
    stop: HWND,
    pair: HWND,
    logs: Logs,
    requests: mpsc::Sender<Request>,
    events: mpsc::Receiver<Event>,
}

impl App {
    fn new(
        settings: Settings,
        requests: mpsc::Sender<Request>,
        events: mpsc::Receiver<Event>,
        logs: Logs,
    ) -> Self {
        Self {
            host: null_mut(),
            window: null_mut(),
            fonts: [null_mut(); 4],
            dpi: 96,
            high_contrast: false,
            settings,
            status: None,
            pairing: None,
            manual_pair: false,
            qr: None,
            note: "选择项目文件夹，然后启动服务。".into(),
            error_note: false,
            busy: false,
            workspace: null_mut(),
            origin: null_mut(),
            local: null_mut(),
            status_label: null_mut(),
            connection_label: null_mut(),
            note_label: null_mut(),
            note_detail: null_mut(),
            pair_label: null_mut(),
            start: null_mut(),
            stop: null_mut(),
            pair: null_mut(),
            logs,
            requests,
            events,
        }
    }

    fn px(&self, value: i32) -> i32 {
        value * self.dpi / 96
    }

    fn rect(&self, [x, y, width, height]: [i32; 4]) -> RECT {
        RECT {
            left: self.px(x),
            top: self.px(y),
            right: self.px(x + width),
            bottom: self.px(y + height),
        }
    }

    unsafe fn color(&self, value: COLORREF, system: SYS_COLOR_INDEX) -> COLORREF {
        if self.high_contrast {
            GetSysColor(system)
        } else {
            value
        }
    }

    unsafe fn read_contrast(&mut self) {
        let mut contrast: HIGHCONTRASTW = zeroed();
        contrast.cbSize = size_of::<HIGHCONTRASTW>() as u32;
        self.high_contrast = SystemParametersInfoW(
            SPI_GETHIGHCONTRAST,
            contrast.cbSize,
            &mut contrast as *mut _ as _,
            0,
        ) != 0
            && contrast.dwFlags & HCF_HIGHCONTRASTON != 0;
    }

    unsafe fn text(
        &self,
        text: &str,
        bounds: [i32; 4],
        font: usize,
        style: u32,
        id: usize,
    ) -> HWND {
        let [x, y, width, height] = bounds;
        let label = self.control("STATIC", text, style | SS_NOPREFIX, id, x, y, width, height);
        SendMessageW(label, WM_SETFONT, self.fonts[font] as usize, 0);
        label
    }

    #[allow(clippy::too_many_arguments)]
    unsafe fn control(
        &self,
        class: &str,
        text: &str,
        style: u32,
        id: usize,
        x: i32,
        y: i32,
        width: i32,
        height: i32,
    ) -> HWND {
        let control = CreateWindowExW(
            0,
            wide(class).as_ptr(),
            wide(text).as_ptr(),
            WS_CHILD | WS_VISIBLE | style,
            self.px(x),
            self.px(y),
            self.px(width),
            self.px(height),
            self.window,
            id as HMENU,
            GetModuleHandleW(null()),
            null(),
        );
        SendMessageW(control, WM_SETFONT, self.fonts[0] as usize, 1);
        control
    }

    unsafe fn open(&mut self) {
        if !self.window.is_null() {
            ShowWindow(self.window, SW_RESTORE);
            SetForegroundWindow(self.window);
            return;
        }
        self.dpi = GetDpiForSystem() as i32;
        if self.dpi == 0 {
            self.dpi = 96;
        }
        self.read_contrast();
        for (font, (size, weight)) in self.fonts.iter_mut().zip([
            (14, FW_NORMAL),
            (24, FW_SEMIBOLD),
            (18, FW_SEMIBOLD),
            (13, FW_NORMAL),
        ]) {
            *font = CreateFontW(
                -size * self.dpi / 96,
                0,
                0,
                0,
                weight as i32,
                0,
                0,
                0,
                DEFAULT_CHARSET as u32,
                0,
                0,
                CLEARTYPE_QUALITY as u32,
                0,
                wide("Microsoft YaHei UI").as_ptr(),
            );
        }
        let style = (WS_OVERLAPPEDWINDOW & !WS_THICKFRAME & !WS_MAXIMIZEBOX) | WS_CLIPCHILDREN;
        let mut rect = RECT {
            left: 0,
            top: 0,
            right: self.px(900),
            bottom: self.px(620),
        };
        AdjustWindowRectEx(&mut rect, style, 0, WS_EX_CONTROLPARENT);
        self.window = CreateWindowExW(
            WS_EX_CONTROLPARENT,
            wide(CLASS).as_ptr(),
            wide("CC Remote").as_ptr(),
            style,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            rect.right - rect.left,
            rect.bottom - rect.top,
            null_mut(),
            null_mut(),
            GetModuleHandleW(null()),
            self as *mut _ as _,
        );
        if self.window.is_null() {
            error("无法创建启动器窗口。");
            for font in &mut self.fonts {
                DeleteObject(*font);
                *font = null_mut();
            }
            return;
        }
        self.text("CC Remote", [84, 28, 440, 32], 1, 0, 209);
        self.text("启动服务，连接手机", [84, 64, 440, 22], 3, 0, 210);
        self.status_label = self.text("服务未启动", [604, 32, 264, 24], 0, 0, 205);
        self.connection_label = self.text("", [604, 60, 264, 22], 3, 0, 206);
        self.text("项目与连接", [56, 148, 454, 28], 2, 0, 0);
        self.text("项目文件夹", [56, 196, 354, 22], 0, 0, 0);
        self.workspace = self.control(
            "EDIT",
            &self.settings.workspace,
            WS_TABSTOP | ES_AUTOHSCROLL as u32,
            201,
            68,
            235,
            330,
            22,
        );
        self.control("BUTTON", "浏览…", WS_TABSTOP, BROWSE, 422, 224, 88, 40);
        self.text("服务地址", [56, 296, 454, 22], 0, 0, 0);
        self.origin = self.control(
            "EDIT",
            &self.settings.public_origin,
            WS_TABSTOP | ES_AUTOHSCROLL as u32,
            202,
            68,
            335,
            430,
            22,
        );
        self.text("留空时自动读取隧道配置", [56, 372, 454, 22], 3, 0, 0);
        self.local = self.control(
            "BUTTON",
            "本机模式（不启动隧道）",
            WS_TABSTOP | BS_AUTOCHECKBOX as u32,
            203,
            56,
            416,
            454,
            28,
        );
        SendMessageW(
            self.local,
            BM_SETCHECK,
            if self.settings.no_tunnel {
                BST_CHECKED
            } else {
                BST_UNCHECKED
            } as usize,
            0,
        );
        self.start = self.control(
            "BUTTON",
            "启动服务",
            WS_TABSTOP | BS_DEFPUSHBUTTON as u32,
            START,
            56,
            480,
            208,
            40,
        );
        self.stop = self.control("BUTTON", "停止服务", WS_TABSTOP, STOP, 276, 480, 110, 40);
        self.control("BUTTON", "查看日志", WS_TABSTOP, LOGS, 398, 480, 112, 40);
        self.text("手机配对", [584, 148, 260, 28], 2, SS_CENTER, 0);
        self.pair_label = self.text("", [584, 444, 260, 44], 3, SS_CENTER, 0);
        self.pair = self.control("BUTTON", "刷新二维码", WS_TABSTOP, PAIR, 584, 496, 260, 36);
        self.note_label = self.text("", [32, 564, 708, 44], 3, 0, 207);
        self.note_detail = self.text("", [32, 588, 708, 22], 3, 0, 208);
        self.control("BUTTON", "退出", WS_TABSTOP, EXIT, 780, 568, 88, 36);
        SendMessageW(self.workspace, EM_SETLIMITTEXT, 32767, 0);
        SendMessageW(self.origin, EM_SETLIMITTEXT, 2048, 0);
        SetTimer(self.window, 1, 1000, None);
        self.update();
        ShowWindow(self.window, SW_SHOW);
        SetForegroundWindow(self.window);
        SetFocus(self.workspace);
    }

    unsafe fn update(&mut self) {
        if self.window.is_null() {
            return;
        }
        let online = self.status.is_some();
        let running = self.status.as_ref().is_some_and(|s| s.running);
        let owned = self.status.as_ref().is_some_and(|s| s.owned);
        let text = match &self.status {
            Some(s) => format!(
                "服务运行中 · {}",
                if s.paired { "已配对" } else { "未配对" }
            ),
            None => {
                if self.busy {
                    "正在启动…".into()
                } else {
                    "服务未启动".into()
                }
            }
        };
        SetWindowTextW(self.status_label, wide(&text).as_ptr());
        let connection = match &self.status {
            Some(s) => format!(
                "{}{}",
                if s.connected_clients > 0 {
                    "客户端已连接"
                } else {
                    "客户端未连接"
                },
                if running { " · 任务运行中" } else { "" }
            ),
            None => "关闭窗口后继续在托盘运行".into(),
        };
        SetWindowTextW(self.connection_label, wide(&connection).as_ptr());
        let (note, detail) = self
            .note
            .split_once('\n')
            .map_or((self.note.as_str(), None), |(note, detail)| {
                (note, Some(detail))
            });
        let style = GetWindowLongW(self.note_label, GWL_STYLE) as u32 & !SS_ENDELLIPSIS;
        SetWindowLongW(
            self.note_label,
            GWL_STYLE,
            (style | if detail.is_some() { SS_ENDELLIPSIS } else { 0 }) as i32,
        );
        SetWindowPos(
            self.note_label,
            null_mut(),
            0,
            0,
            self.px(708),
            self.px(if detail.is_some() { 22 } else { 44 }),
            SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE,
        );
        SetWindowTextW(self.note_label, wide(note).as_ptr());
        SetWindowTextW(self.note_detail, wide(detail.unwrap_or("")).as_ptr());
        ShowWindow(
            self.note_detail,
            if detail.is_some() { SW_SHOW } else { SW_HIDE },
        );
        SetWindowTextW(
            self.start,
            wide(if online {
                "应用项目"
            } else {
                "启动服务"
            })
            .as_ptr(),
        );
        EnableWindow(self.start, (!self.busy && !running) as i32);
        EnableWindow(self.stop, (online && owned && !self.busy) as i32);
        EnableWindow(self.pair, (online && !self.busy) as i32);
        EnableWindow(self.origin, (!online && !self.busy) as i32);
        EnableWindow(self.local, (!online && !self.busy) as i32);
        let paired = self.status.as_ref().is_some_and(|s| s.paired);
        SetWindowTextW(
            self.pair,
            wide(if paired && self.pairing.is_none() {
                "添加设备"
            } else {
                "刷新二维码"
            })
            .as_ptr(),
        );
        let hint = if let Some(pair) = &self.pairing {
            let left = pair["payload"]["expiresAt"]
                .as_u64()
                .unwrap_or_default()
                .saturating_sub(now_ms())
                / 1000;
            if left == 0 {
                "二维码已过期，请刷新。".into()
            } else {
                format!(
                    "使用手机 App 扫码添加设备\n有效期 {:02}:{:02}",
                    left / 60,
                    left % 60
                )
            }
        } else if paired {
            "点击“添加设备”显示二维码。\n已配对设备可继续使用。".into()
        } else if online {
            "点击“刷新二维码”生成配对二维码。".into()
        } else {
            "启动服务后，用手机 App 扫码。".into()
        };
        SetWindowTextW(self.pair_label, wide(&hint).as_ptr());
    }

    fn set_pairing(&mut self, pair: Option<serde_json::Value>) {
        if self.pairing == pair {
            return;
        }
        self.qr = pair
            .as_ref()
            .and_then(|value| {
                serde_json::from_value::<Vec<Vec<bool>>>(value["modules"].clone()).ok()
            })
            .filter(|rows| {
                (21..=177).contains(&rows.len()) && rows.iter().all(|row| row.len() == rows.len())
            });
        self.pairing = pair;
        if !self.window.is_null() {
            let rect = self.rect(QR_AREA);
            unsafe {
                InvalidateRect(self.window, &rect, 1);
            }
        }
    }

    unsafe fn receive(&mut self) {
        while let Ok(event) = self.events.try_recv() {
            match event {
                Event::Progress(note) => {
                    self.busy = true;
                    self.error_note = false;
                    self.note = note;
                }
                Event::Status(status) => {
                    self.busy = false;
                    self.error_note = false;
                    if self.status.is_none() && !self.workspace.is_null() {
                        SetWindowTextW(self.workspace, wide(&status.workspace_dir).as_ptr());
                    }
                    if self.manual_pair
                        && self
                            .status
                            .as_ref()
                            .is_some_and(|old| old.auth_generation != status.auth_generation)
                    {
                        self.manual_pair = false;
                    }
                    if !self.manual_pair {
                        self.set_pairing(status.pairing.clone());
                    }
                    self.note = format!(
                        "{}\n{}",
                        status.public_origin,
                        if status.owned {
                            "关闭窗口后继续在托盘运行。"
                        } else {
                            "已连接现有服务；退出启动器不会停止该服务。"
                        }
                    );
                    self.settings.workspace = status.workspace_dir.clone();
                    self.status = Some(status);
                }
                Event::Pair(pair) => {
                    self.busy = false;
                    self.manual_pair = true;
                    self.set_pairing(Some(pair));
                }
                Event::Error(note) => {
                    self.busy = false;
                    self.error_note = true;
                    self.note = note;
                }
                Event::Stopped => {
                    self.busy = false;
                    self.error_note = false;
                    self.status = None;
                    self.manual_pair = false;
                    self.set_pairing(None);
                    self.note = "服务已停止，配对凭据仍保留。".into();
                }
                Event::Exit => {
                    DestroyWindow(self.host);
                    return;
                }
            }
        }
        if !self.window.is_null() {
            InvalidateRect(self.window, null(), 0);
        }
        self.update();
    }

    unsafe fn stop(&mut self, exit: bool) {
        if !exit && !self.status.as_ref().is_some_and(|s| s.owned) {
            return;
        }
        let running = self.status.as_ref().is_some_and(|s| s.running && s.owned);
        if running
            && MessageBoxW(
                self.window,
                wide("任务正在运行。退出服务会停止当前任务，是否继续？").as_ptr(),
                wide("CC Remote").as_ptr(),
                MB_YESNO | MB_ICONWARNING | MB_DEFBUTTON2,
            ) != IDYES
        {
            return;
        }
        self.busy = true;
        self.note = "正在停止服务…".into();
        let _ = self.requests.send(Request::Stop {
            force: running,
            exit,
        });
        self.update();
    }

    unsafe fn command(&mut self, id: usize) {
        if self.busy && id != LOGS && id != EXIT {
            return;
        }
        match id {
            START => {
                self.settings.workspace = window_text(self.workspace).trim().to_string();
                self.settings.public_origin = window_text(self.origin).trim().to_string();
                self.settings.no_tunnel =
                    SendMessageW(self.local, BM_GETCHECK, 0, 0) == BST_CHECKED as isize;
                self.busy = true;
                let _ = self.requests.send(Request::Start(self.settings.clone()));
            }
            BROWSE => {
                let title = wide("选择要交给 Claude / Codex 的项目文件夹");
                let mut info: BROWSEINFOW = zeroed();
                info.hwndOwner = self.window;
                info.lpszTitle = title.as_ptr();
                info.ulFlags = BIF_RETURNONLYFSDIRS | BIF_NEWDIALOGSTYLE;
                let pidl = SHBrowseForFolderW(&info);
                if !pidl.is_null() {
                    let mut path = vec![0u16; 32768];
                    if SHGetPathFromIDListEx(pidl, path.as_mut_ptr(), path.len() as u32, 0) != 0 {
                        SetWindowTextW(self.workspace, path.as_ptr());
                    }
                    CoTaskMemFree(pidl as _);
                }
            }
            PAIR => {
                self.busy = true;
                let _ = self.requests.send(Request::Pair);
            }
            STOP => self.stop(false),
            EXIT => self.stop(true),
            LOGS => {
                let text = self
                    .logs
                    .lock()
                    .map(|lines| lines.iter().cloned().collect::<Vec<_>>().join("\r\n"))
                    .unwrap_or_default();
                MessageBoxW(
                    self.window,
                    wide(if text.is_empty() {
                        "暂无启动日志。"
                    } else {
                        &text
                    })
                    .as_ptr(),
                    wide("CC Remote · 启动日志").as_ptr(),
                    MB_OK,
                );
            }
            _ => {}
        }
        self.update();
    }

    unsafe fn rounded(&self, dc: HDC, rect: &RECT, radius: i32, fill: COLORREF, border: COLORREF) {
        SelectObject(dc, GetStockObject(DC_BRUSH));
        SelectObject(dc, GetStockObject(DC_PEN));
        SetDCBrushColor(dc, fill);
        SetDCPenColor(dc, border);
        RoundRect(
            dc,
            rect.left,
            rect.top,
            rect.right,
            rect.bottom,
            self.px(radius * 2),
            self.px(radius * 2),
        );
    }

    unsafe fn draw_button(&self, draw: &NMCUSTOMDRAW) -> LRESULT {
        if draw.dwDrawStage != CDDS_PREPAINT {
            return CDRF_DODEFAULT as isize;
        }
        let dc = draw.hdc;
        let saved = SaveDC(dc);
        let primary = draw.hdr.hwndFrom == self.start;
        let disabled = IsWindowEnabled(draw.hdr.hwndFrom) == 0;
        let pressed = draw.uItemState & CDIS_SELECTED != 0;
        let hover = draw.uItemState & CDIS_HOT != 0;
        let fill = if disabled {
            CANVAS
        } else if primary {
            if pressed {
                rgb(0x28587D)
            } else if hover {
                rgb(0x2E6793)
            } else {
                ACCENT
            }
        } else if pressed {
            rgb(0xE4EFF7)
        } else if hover {
            rgb(0xF1F5F9)
        } else {
            SURFACE
        };
        let fill = self.color(
            fill,
            if primary && !disabled {
                COLOR_HIGHLIGHT
            } else {
                COLOR_BTNFACE
            },
        );
        let ink = self.color(
            if disabled {
                MUTED
            } else if primary {
                SURFACE
            } else {
                INK
            },
            if disabled {
                COLOR_GRAYTEXT
            } else if primary {
                COLOR_HIGHLIGHTTEXT
            } else {
                COLOR_BTNTEXT
            },
        );
        let border = if primary && !disabled {
            fill
        } else {
            self.color(BORDER, COLOR_BTNTEXT)
        };
        self.rounded(dc, &draw.rc, 6, fill, border);
        SetBkMode(dc, TRANSPARENT as i32);
        SetTextColor(dc, ink);
        SelectObject(dc, self.fonts[0]);
        let mut bounds = draw.rc;
        if pressed {
            OffsetRect(&mut bounds, 0, self.px(1));
        }
        let text = wide(&window_text(draw.hdr.hwndFrom));
        DrawTextW(
            dc,
            text.as_ptr(),
            (text.len() - 1) as i32,
            &mut bounds,
            DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX,
        );
        if draw.uItemState & CDIS_FOCUS != 0 {
            let mut focus = draw.rc;
            InflateRect(&mut focus, -self.px(6), -self.px(6));
            SetTextColor(dc, ink);
            DrawFocusRect(dc, &focus);
        }
        RestoreDC(dc, saved);
        CDRF_SKIPDEFAULT as isize
    }

    unsafe fn paint(&self, hwnd: HWND) {
        let mut paint: PAINTSTRUCT = zeroed();
        let dc = BeginPaint(hwnd, &mut paint);
        let saved = SaveDC(dc);
        let mut client: RECT = zeroed();
        GetClientRect(hwnd, &mut client);
        SetDCBrushColor(dc, self.color(CANVAS, COLOR_BTNFACE));
        FillRect(dc, &client, GetStockObject(DC_BRUSH) as HBRUSH);
        let surface = self.color(SURFACE, COLOR_WINDOW);
        self.rounded(
            dc,
            &self.rect([32, 120, 836, 424]),
            12,
            surface,
            self.color(SURFACE, COLOR_WINDOWTEXT),
        );
        SelectObject(dc, GetStockObject(DC_PEN));
        SetDCPenColor(dc, self.color(rgb(0xE3E9EE), COLOR_WINDOWTEXT));
        MoveToEx(dc, self.px(550), self.px(148), null_mut());
        LineTo(dc, self.px(550), self.px(516));
        let icon = GetClassLongPtrW(hwnd, GCLP_HICON) as HICON;
        DrawIconEx(
            dc,
            self.px(36),
            self.px(36),
            icon,
            self.px(32),
            self.px(32),
            0,
            null_mut(),
            DI_NORMAL,
        );
        let state = if self.busy {
            rgb(0x94662D)
        } else if self.status.is_some() {
            rgb(0x24715C)
        } else {
            MUTED
        };
        SetDCBrushColor(dc, self.color(state, COLOR_BTNTEXT));
        SelectObject(dc, GetStockObject(NULL_PEN));
        Ellipse(dc, self.px(586), self.px(40), self.px(594), self.px(48));
        for (bounds, edit) in [
            ([56, 224, 354, 40], self.workspace),
            ([56, 324, 454, 40], self.origin),
        ] {
            let border = if GetFocus() == edit {
                self.color(ACCENT, COLOR_HIGHLIGHT)
            } else {
                self.color(BORDER, COLOR_WINDOWTEXT)
            };
            self.rounded(dc, &self.rect(bounds), 6, surface, border);
        }
        let rect = self.rect(QR_AREA);
        let left = rect.left;
        let top = rect.top;
        let area = rect.right - rect.left;
        if let Some(qr) = &self.qr {
            FillRect(dc, &rect, GetStockObject(WHITE_BRUSH) as HBRUSH);
            let width = qr.len() as i32;
            let module = area / (width + 8);
            let offset = (area - module * width) / 2;
            for y in 0..width {
                for x in 0..width {
                    if qr[y as usize][x as usize] {
                        let rect = RECT {
                            left: left + offset + x * module,
                            top: top + offset + y * module,
                            right: left + offset + (x + 1) * module,
                            bottom: top + offset + (y + 1) * module,
                        };
                        FillRect(dc, &rect, GetStockObject(BLACK_BRUSH) as HBRUSH);
                    }
                }
            }
        } else {
            let paired = self.status.as_ref().is_some_and(|status| status.paired);
            let ink = self.color(if paired { ACCENT } else { MUTED }, COLOR_WINDOWTEXT);
            self.rounded(dc, &self.rect([688, 238, 52, 82]), 8, surface, ink);
            SelectObject(dc, GetStockObject(DC_PEN));
            SetDCPenColor(dc, ink);
            MoveToEx(dc, self.px(708), self.px(308), null_mut());
            LineTo(dc, self.px(720), self.px(308));
            if paired {
                MoveToEx(dc, self.px(701), self.px(277), null_mut());
                LineTo(dc, self.px(711), self.px(287));
                LineTo(dc, self.px(727), self.px(266));
            }
            SetBkMode(dc, TRANSPARENT as i32);
            SetTextColor(dc, self.color(INK, COLOR_WINDOWTEXT));
            SelectObject(dc, self.fonts[0]);
            let text = wide(if paired {
                "配对已保存"
            } else if self.busy {
                "正在准备配对…"
            } else if self.status.is_some() {
                "等待扫码配对"
            } else {
                "等待服务启动"
            });
            let mut bounds = self.rect([584, 344, 260, 28]);
            DrawTextW(
                dc,
                text.as_ptr(),
                (text.len() - 1) as i32,
                &mut bounds,
                DT_CENTER | DT_SINGLELINE | DT_NOPREFIX,
            );
        }
        RestoreDC(dc, saved);
        EndPaint(hwnd, &paint);
    }
}

unsafe extern "system" fn window_proc(
    hwnd: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    if message == WM_NCCREATE {
        let create = &*(lparam as *const CREATESTRUCTW);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, create.lpCreateParams as isize);
    }
    if ![
        OPEN,
        EVENTS,
        TRAY,
        WM_COMMAND,
        WM_CLOSE,
        WM_DESTROY,
        WM_TIMER,
        WM_PAINT,
        WM_QUERYENDSESSION,
        WM_CTLCOLORSTATIC,
        WM_CTLCOLOREDIT,
        WM_CTLCOLORBTN,
        WM_NOTIFY,
        WM_SETTINGCHANGE,
        WM_ERASEBKGND,
    ]
    .contains(&message)
    {
        return DefWindowProcW(hwnd, message, wparam, lparam);
    }
    let pointer = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *mut App;
    if pointer.is_null() {
        return DefWindowProcW(hwnd, message, wparam, lparam);
    }
    let app = &mut *pointer;
    match message {
        WM_CTLCOLORSTATIC | WM_CTLCOLOREDIT | WM_CTLCOLORBTN => {
            let control = lparam as HWND;
            let id = GetDlgCtrlID(control);
            let canvas = matches!(id, 205..=210);
            let background = app.color(
                if canvas { CANVAS } else { SURFACE },
                if canvas { COLOR_BTNFACE } else { COLOR_WINDOW },
            );
            let caption = SendMessageW(control, WM_GETFONT, 0, 0) as HFONT == app.fonts[3];
            let ink = if id == 207 && app.error_note {
                DANGER
            } else if caption || IsWindowEnabled(control) == 0 {
                MUTED
            } else {
                INK
            };
            SetBkColor(wparam as HDC, background);
            SetTextColor(
                wparam as HDC,
                app.color(
                    ink,
                    if caption {
                        COLOR_GRAYTEXT
                    } else {
                        COLOR_WINDOWTEXT
                    },
                ),
            );
            SetDCBrushColor(wparam as HDC, background);
            return GetStockObject(DC_BRUSH) as isize;
        }
        WM_NOTIFY => {
            let header = &*(lparam as *const NMHDR);
            if header.code == NM_CUSTOMDRAW && header.hwndFrom != app.local {
                return app.draw_button(&*(lparam as *const NMCUSTOMDRAW));
            }
            return DefWindowProcW(hwnd, message, wparam, lparam);
        }
        WM_ERASEBKGND => return 1,
        WM_SETTINGCHANGE => {
            app.read_contrast();
            if !app.window.is_null() {
                RedrawWindow(
                    app.window,
                    null(),
                    null_mut(),
                    RDW_INVALIDATE | RDW_ALLCHILDREN,
                );
            }
        }
        OPEN => app.open(),
        EVENTS => app.receive(),
        WM_TIMER => app.update(),
        WM_PAINT if hwnd != app.host => app.paint(hwnd),
        WM_CLOSE if hwnd != app.host => {
            DestroyWindow(hwnd);
        }
        WM_DESTROY if hwnd != app.host => {
            app.window = null_mut();
            for font in &mut app.fonts {
                DeleteObject(*font);
                *font = null_mut();
            }
        }
        WM_QUERYENDSESSION => {
            let _ = app.requests.send(Request::Stop {
                force: true,
                exit: true,
            });
            return 1;
        }
        WM_DESTROY => {
            let mut icon: NOTIFYICONDATAW = zeroed();
            icon.cbSize = size_of::<NOTIFYICONDATAW>() as u32;
            icon.hWnd = app.host;
            icon.uID = 1;
            Shell_NotifyIconW(NIM_DELETE, &icon);
            if !app.window.is_null() {
                DestroyWindow(app.window);
            }
            PostQuitMessage(0);
        }
        WM_COMMAND
            if wparam >> 16 == EN_SETFOCUS as usize || wparam >> 16 == EN_KILLFOCUS as usize =>
        {
            InvalidateRect(app.window, null(), 0);
        }
        WM_COMMAND if wparam >> 16 == 0 => app.command(wparam & 0xffff),
        TRAY if lparam as u32 == WM_LBUTTONUP || lparam as u32 == WM_LBUTTONDBLCLK => app.open(),
        TRAY if lparam as u32 == WM_RBUTTONUP => {
            let menu = CreatePopupMenu();
            AppendMenuW(menu, MF_STRING, 1, wide("打开 CC Remote").as_ptr());
            AppendMenuW(menu, MF_STRING, STOP, wide("停止服务").as_ptr());
            AppendMenuW(menu, MF_STRING, EXIT, wide("退出").as_ptr());
            let mut point: POINT = zeroed();
            GetCursorPos(&mut point);
            SetForegroundWindow(app.host);
            let selected = TrackPopupMenu(
                menu,
                TPM_RETURNCMD | TPM_RIGHTBUTTON,
                point.x,
                point.y,
                0,
                app.host,
                null(),
            );
            DestroyMenu(menu);
            if selected == 1 {
                app.open();
            } else if selected != 0 {
                app.command(selected as usize);
            }
            PostMessageW(app.host, WM_NULL, 0, 0);
        }
        _ => return DefWindowProcW(hwnd, message, wparam, lparam),
    }
    0
}

unsafe fn window_text(hwnd: HWND) -> String {
    let mut buffer = vec![0u16; GetWindowTextLengthW(hwnd) as usize + 1];
    let length = GetWindowTextW(hwnd, buffer.as_mut_ptr(), buffer.len() as i32);
    String::from_utf16_lossy(&buffer[..length as usize])
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

unsafe fn error(text: &str) {
    MessageBoxW(
        null_mut(),
        wide(text).as_ptr(),
        wide("CC Remote").as_ptr(),
        MB_OK | MB_ICONERROR,
    );
}

fn repository() -> Result<PathBuf, String> {
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    exe.ancestors()
        .skip(1)
        .find(|path| path.join("package.json").is_file() && path.join("src/daemon.ts").is_file())
        .map(PathBuf::from)
        .ok_or("请把启动器放在 CC Remote 仓库目录内。".into())
}

unsafe fn register_class(icons: &LauncherIcons) -> bool {
    let mut class: WNDCLASSEXW = zeroed();
    class.cbSize = size_of::<WNDCLASSEXW>() as u32;
    class.lpfnWndProc = Some(window_proc);
    class.hInstance = GetModuleHandleW(null());
    class.hCursor = LoadCursorW(null_mut(), IDC_ARROW);
    class.hIcon = icons.large;
    class.hIconSm = icons.small;
    class.hbrBackground = GetSysColorBrush(COLOR_WINDOW);
    let name = wide(CLASS);
    class.lpszClassName = name.as_ptr();
    RegisterClassExW(&class) != 0
}

fn main() {
    unsafe {
        SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        let initialized = CoInitializeEx(null(), COINIT_APARTMENTTHREADED as u32) >= 0;
        let root = match repository() {
            Ok(root) => root,
            Err(note) => {
                error(&note);
                return;
            }
        };
        let settings = Settings::load(&root);
        let mutex = CreateMutexW(
            null(),
            0,
            wide(&format!("Local\\CCRemoteNativeLauncher-{}", settings.port)).as_ptr(),
        );
        if mutex.is_null() {
            error("无法创建启动器实例锁。");
            return;
        }
        let host_title = wide(&format!("CCRemoteNativeLauncher-{}", settings.port));
        if GetLastError() == ERROR_ALREADY_EXISTS {
            for _ in 0..20 {
                let host = FindWindowW(wide(CLASS).as_ptr(), host_title.as_ptr());
                if !host.is_null() {
                    PostMessageW(host, OPEN, 0, 0);
                    break;
                }
                thread::sleep(std::time::Duration::from_millis(50));
            }
            CloseHandle(mutex);
            return;
        }
        let icons = match LauncherIcons::load() {
            Some(icons) => icons,
            None => {
                error("无法加载启动器图标。");
                CloseHandle(mutex);
                return;
            }
        };
        if !register_class(&icons) {
            error("无法注册启动器窗口。");
            CloseHandle(mutex);
            return;
        }
        let (requests, request_rx) = mpsc::channel();
        let (event_tx, events) = mpsc::channel();
        let logs = Arc::new(Mutex::new(VecDeque::new()));
        let mut app = Box::new(App::new(settings.clone(), requests, events, logs.clone()));
        app.host = CreateWindowExW(
            0,
            wide(CLASS).as_ptr(),
            host_title.as_ptr(),
            0,
            0,
            0,
            0,
            0,
            null_mut(),
            null_mut(),
            GetModuleHandleW(null()),
            &mut *app as *mut App as _,
        );
        if app.host.is_null() {
            error("无法创建托盘窗口。");
            UnregisterClassW(wide(CLASS).as_ptr(), GetModuleHandleW(null()));
            CloseHandle(mutex);
            return;
        }
        let mut icon: NOTIFYICONDATAW = zeroed();
        icon.cbSize = size_of::<NOTIFYICONDATAW>() as u32;
        icon.hWnd = app.host;
        icon.uID = 1;
        icon.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
        icon.uCallbackMessage = TRAY;
        icon.hIcon = icons.small;
        let tip = wide("CC Remote");
        icon.szTip[..tip.len()].copy_from_slice(&tip);
        if Shell_NotifyIconW(NIM_ADD, &icon) == 0 {
            error("无法添加托盘图标。");
            DestroyWindow(app.host);
            UnregisterClassW(wide(CLASS).as_ptr(), GetModuleHandleW(null()));
            CloseHandle(mutex);
            return;
        }
        let host = app.host as usize;
        let worker = thread::spawn(move || {
            service::run(root, settings.port, logs, request_rx, |event| {
                if let Event::Error(note) = &event {
                    eprintln!("{note}");
                }
                if event_tx.send(event).is_ok() {
                    PostMessageW(host as HWND, EVENTS, 0, 0);
                }
            })
        });
        app.open();
        if !app.settings.workspace.is_empty() && PathBuf::from(&app.settings.workspace).is_dir() {
            let _ = app.requests.send(Request::Start(app.settings.clone()));
        }
        let mut message: MSG = zeroed();
        while GetMessageW(&mut message, null_mut(), 0, 0) > 0 {
            if app.window.is_null() || IsDialogMessageW(app.window, &message) == 0 {
                TranslateMessage(&message);
                DispatchMessageW(&message);
            }
        }
        drop(app);
        let _ = worker.join();
        UnregisterClassW(wide(CLASS).as_ptr(), GetModuleHandleW(null()));
        CloseHandle(mutex);
        if initialized {
            CoUninitialize();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn native_controls_keep_unicode_paths_and_draw_qr_modules() {
        unsafe {
            let icons = LauncherIcons::load().expect("Embedded launcher icons are missing");
            for (icon, metric) in [(icons.large, SM_CXICON), (icons.small, SM_CXSMICON)] {
                let mut info: ICONINFO = zeroed();
                assert_ne!(GetIconInfo(icon, &mut info), 0);
                let mut bitmap: BITMAP = zeroed();
                assert_ne!(
                    GetObjectW(
                        info.hbmColor,
                        size_of::<BITMAP>() as i32,
                        &mut bitmap as *mut _ as _
                    ),
                    0
                );
                assert_eq!(bitmap.bmWidth, GetSystemMetrics(metric));
                assert_eq!(bitmap.bmHeight, GetSystemMetrics(metric));
                DeleteObject(info.hbmColor);
                DeleteObject(info.hbmMask);
            }
            assert!(register_class(&icons));
            let (requests, receiver) = mpsc::channel();
            let (event_tx, events) = mpsc::channel();
            let logs = Arc::new(Mutex::new(VecDeque::new()));
            let mut app = Box::new(App::new(
                Settings {
                    workspace: "C:\\项目\\示例".into(),
                    port: 8787,
                    ..Default::default()
                },
                requests,
                events,
                logs,
            ));
            app.open();
            assert!(!app.window.is_null());
            assert_eq!(
                GetClassLongPtrW(app.window, GCLP_HICON) as HICON,
                icons.large
            );
            assert_eq!(
                GetClassLongPtrW(app.window, GCLP_HICONSM) as HICON,
                icons.small
            );
            assert_eq!(window_text(app.workspace), "C:\\项目\\示例");
            assert_ne!(GetWindowLongW(app.start, GWL_STYLE) as u32 & WS_TABSTOP, 0);
            event_tx
                .send(Event::Progress("正在启动本机服务…".into()))
                .unwrap();
            app.receive();
            assert_eq!(IsWindowEnabled(app.start), 0);
            event_tx
                .send(Event::Error("请选择一个存在的项目文件夹。".into()))
                .unwrap();
            app.receive();
            assert!(app.error_note);
            assert_eq!(window_text(app.note_label), "请选择一个存在的项目文件夹。");
            event_tx
                .send(Event::Status(Status {
                    paired: true,
                    owned: true,
                    workspace_dir: "C:\\项目\\示例".into(),
                    public_origin: format!("https://{}.example.com", "long-address-".repeat(12)),
                    ..Default::default()
                }))
                .unwrap();
            app.receive();
            assert_eq!(window_text(app.status_label), "服务运行中 · 已配对");
            assert_eq!(window_text(app.pair), "添加设备");
            assert_eq!(window_text(app.note_detail), "关闭窗口后继续在托盘运行。");
            assert_ne!(
                GetWindowLongW(app.note_label, GWL_STYLE) as u32 & SS_ENDELLIPSIS,
                0
            );
            app.command(PAIR);
            assert!(matches!(receiver.try_recv(), Ok(Request::Pair)));
            let pair = serde_json::json!({"payload": {"type": "cc-remote-pair", "version": 1,
                "origin": "https://remote.example.com", "nonce": "test-nonce", "deviceName": "Test PC", "expiresAt": now_ms() + 300000},
                "modules": vec![vec![true; 21]; 21]});
            event_tx.send(Event::Pair(pair.clone())).unwrap();
            app.receive();
            assert!(app.qr.is_some());
            assert_eq!(window_text(app.pair), "刷新二维码");
            assert!(window_text(app.pair_label).contains("扫码添加设备"));
            let mut next_pair = pair.clone();
            next_pair["payload"]["nonce"] = "next-nonce".into();
            event_tx
                .send(Event::Status(Status {
                    auth_generation: 1,
                    pairing: Some(next_pair.clone()),
                    ..app.status.clone().unwrap()
                }))
                .unwrap();
            app.receive();
            assert_eq!(app.pairing, Some(next_pair));
            assert!(!app.manual_pair);
            assert!(app.qr.is_some());
            event_tx.send(Event::Stopped).unwrap();
            app.receive();
            assert!(app.qr.is_none());
            assert_eq!(IsWindowVisible(app.note_detail), 0);
            app.set_pairing(Some(pair));
            assert!(app.qr.is_some());
            SetFocus(app.start);
            SendMessageW(app.start, WM_KEYDOWN, VK_SPACE as usize, 0);
            SendMessageW(app.start, WM_KEYUP, VK_SPACE as usize, 0);
            assert!(
                matches!(receiver.try_recv(), Ok(Request::Start(settings)) if settings.workspace == "C:\\项目\\示例")
            );
            app.command(EXIT);
            assert!(matches!(
                receiver.try_recv(),
                Ok(Request::Stop {
                    force: false,
                    exit: true
                })
            ));
            UpdateWindow(app.window);
            DestroyWindow(app.window);
            assert!(app.window.is_null());
            assert!(app.fonts.iter().all(|font| font.is_null()));
            assert_ne!(
                UnregisterClassW(wide(CLASS).as_ptr(), GetModuleHandleW(null())),
                0
            );
        }
    }
}
