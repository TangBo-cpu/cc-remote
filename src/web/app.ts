type ServerMessage =
  | { type: 'status'; running: boolean; hasClaudeSessionId: boolean }
  | { type: 'text'; text: string }
  | { type: 'done'; exitCode: number | null; claudeSessionId?: string }
  | { type: 'stopped' }
  | { type: 'error'; message: string }
  | { type: 'claude_event'; event: unknown };

const statusEl = mustGet('status');
const transcriptEl = mustGet('transcript');
const form = mustGet('prompt-form') as HTMLFormElement;
const promptEl = mustGet('prompt') as HTMLTextAreaElement;
const sendButton = mustGet('send') as HTMLButtonElement;
const stopButton = mustGet('stop') as HTMLButtonElement;
const logoutButton = mustGet('logout') as HTMLButtonElement;

let ws: WebSocket | undefined;
let running = false;
let assistantBubble: HTMLElement | undefined;

void boot();

form.addEventListener('submit', event => {
  event.preventDefault();
  const text = promptEl.value.trim();
  if (!text || !ws || ws.readyState !== WebSocket.OPEN || running) return;
  appendBubble('user', text);
  promptEl.value = '';
  assistantBubble = undefined;
  ws.send(JSON.stringify({ type: 'prompt', text }));
});

stopButton.addEventListener('click', () => {
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify({ type: 'stop' }));
  } else {
    void fetch('/api/stop', { method: 'POST', credentials: 'same-origin' });
  }
});

logoutButton.addEventListener('click', async () => {
  await fetch('/api/logout', { method: 'POST', credentials: 'same-origin' });
  location.reload();
});

promptEl.addEventListener('keydown', event => {
  if ((event.metaKey || event.ctrlKey) && event.key === 'Enter') form.requestSubmit();
});

async function boot(): Promise<void> {
  if ('serviceWorker' in navigator) void navigator.serviceWorker.register('/sw.js');

  if (location.pathname === '/pair') {
    await pairFromHash();
    return;
  }

  const ok = await refreshStatus();
  if (ok) connect();
}

async function pairFromHash(): Promise<void> {
  const code = location.hash.slice(1);
  if (!code) {
    setStatus('配对链接缺少验证码');
    return;
  }

  setStatus('正在配对…');
  const res = await fetch('/api/pair', {
    method: 'POST',
    credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ code }),
  });

  if (!res.ok) {
    setStatus('配对失败，二维码可能已过期');
    return;
  }

  history.replaceState(null, '', '/');
  appendBubble('system', '配对成功');
  connect();
}

async function refreshStatus(): Promise<boolean> {
  const res = await fetch('/api/status', { credentials: 'same-origin', cache: 'no-store' });
  if (res.status === 401) {
    setStatus('未配对：请扫描 daemon 终端里的二维码');
    setControls(false);
    return false;
  }
  if (!res.ok) {
    setStatus('状态读取失败');
    setControls(false);
    return false;
  }
  const data = await res.json() as { running: boolean; hasClaudeSessionId: boolean };
  applyStatus(data.running, data.hasClaudeSessionId);
  return true;
}

function connect(): void {
  const scheme = location.protocol === 'https:' ? 'wss:' : 'ws:';
  ws = new WebSocket(`${scheme}//${location.host}/ws`);
  setStatus('正在连接…');

  ws.addEventListener('open', () => setStatus('已连接'));
  ws.addEventListener('close', () => {
    setStatus('连接已断开，3 秒后重连');
    setControls(false);
    setTimeout(connect, 3_000);
  });
  ws.addEventListener('message', event => handleServerMessage(JSON.parse(event.data) as ServerMessage));
}

function handleServerMessage(message: ServerMessage): void {
  if (message.type === 'status') {
    applyStatus(message.running, message.hasClaudeSessionId);
    return;
  }
  if (message.type === 'text') {
    appendAssistantText(message.text);
    return;
  }
  if (message.type === 'done') {
    running = false;
    assistantBubble = undefined;
    appendBubble('system', `完成，退出码 ${message.exitCode ?? 'unknown'}`);
    setControls(true);
    return;
  }
  if (message.type === 'stopped') {
    running = false;
    assistantBubble = undefined;
    appendBubble('system', '已停止');
    setControls(true);
    return;
  }
  if (message.type === 'error') {
    appendBubble('system', `错误：${message.message}`);
  }
}

function applyStatus(isRunning: boolean, hasSession: boolean): void {
  running = isRunning;
  setStatus(`${isRunning ? 'Claude 正在运行' : '已连接'} · ${hasSession ? '已续接会话' : '新会话'}`);
  setControls(true);
}

function setControls(connected: boolean): void {
  promptEl.disabled = !connected || running;
  sendButton.disabled = !connected || running;
  stopButton.disabled = !connected || !running;
}

function appendAssistantText(text: string): void {
  if (!assistantBubble) assistantBubble = appendBubble('assistant', '');
  assistantBubble.textContent = (assistantBubble.textContent || '') + text;
  scrollToBottom();
}

function appendBubble(kind: 'user' | 'assistant' | 'system', text: string): HTMLElement {
  const el = document.createElement('div');
  el.className = `bubble ${kind}`;
  el.textContent = text;
  transcriptEl.append(el);
  scrollToBottom();
  return el;
}

function setStatus(text: string): void {
  statusEl.textContent = text;
}

function scrollToBottom(): void {
  transcriptEl.scrollTop = transcriptEl.scrollHeight;
}

function mustGet(id: string): HTMLElement {
  const el = document.getElementById(id);
  if (!el) throw new Error(`Missing #${id}`);
  return el;
}
