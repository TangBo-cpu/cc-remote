import { createHmac, randomBytes } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { request, type ClientRequest } from 'node:http';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import wrtc from '@roamhq/wrtc';

const CHUNK_BYTES = 16 * 1024;
const MAX_BODY_BYTES = 128 * 1024 * 1024;
const MAX_MESSAGE_BYTES = 32 * 1024 * 1024;
const MAX_PENDING_BYTES = 40 * 1024 * 1024;

export type PeerSettings = {
  stunUrls: string[];
  turnUrls: string[];
  turnSecret: string;
};

export async function readPeerSettings(): Promise<PeerSettings | undefined> {
  try {
    const value = JSON.parse(await readFile(
      process.env.CC_REMOTE_PEER_CONFIG || join(process.cwd(), '.data', 'peer.json'),
      'utf8',
    ));
    if (value.enabled !== true) return undefined;
    const urls = (input: unknown, pattern: RegExp): string[] => {
      if (!Array.isArray(input) || input.length > 8
        || input.some(url => typeof url !== 'string' || !pattern.test(url) || url.length > 512)) {
        throw new Error('invalid_peer_settings');
      }
      return input;
    };
    const stunUrls = urls(value.stunUrls ?? [], /^stuns?:[^\s]+$/);
    const turnUrls = urls(value.turnUrls ?? [], /^turns?:[^\s]+$/);
    const turnSecret = value.turnSecret ?? '';
    if (typeof turnSecret !== 'string' || (turnUrls.length > 0 && turnSecret.length < 32)) {
      throw new Error('invalid_peer_settings');
    }
    return { stunUrls, turnUrls, turnSecret };
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'ENOENT') {
      console.warn('[peer] Invalid peer configuration; using WebSocket only.');
    }
    return undefined;
  }
}

export function peerIceServers(settings: PeerSettings): RTCIceServer[] {
  const servers: RTCIceServer[] = [];
  if (settings.stunUrls.length) servers.push({ urls: settings.stunUrls });
  if (settings.turnUrls.length) {
    const username = `${Math.floor(Date.now() / 1000) + 3600}:${randomBytes(12).toString('hex')}`;
    servers.push({
      urls: settings.turnUrls,
      username,
      credential: createHmac('sha1', settings.turnSecret).update(username).digest('base64'),
    });
  }
  return servers;
}

type Upload = { request: ClientRequest; received: number; expected?: number; ended: boolean };
type Message = { chunks: Buffer[]; length: number; expected: number; timer: NodeJS.Timeout };

export class PeerTransport {
  private readonly peer: RTCPeerConnection;
  private channel?: RTCDataChannel;
  private ready = false;
  private channelReady = false;
  private closed = false;
  private accepting?: Promise<void>;
  private messageId = 0x80000000;
  private pendingBytes = 0;
  private sending = Promise.resolve();
  private readonly uploads = new Map<number, Upload>();
  private readonly messages = new Map<number, Message>();
  private readonly setupTimer: NodeJS.Timeout;

  constructor(private readonly options: {
    settings: PeerSettings;
    port: number;
    token: string;
    authorized(): boolean;
    signal(message: unknown): void;
    message(raw: string): void;
    failed(): void;
  }) {
    this.peer = new wrtc.RTCPeerConnection({ iceServers: peerIceServers(options.settings) });
    this.peer.onicecandidate = event => {
      if (event.candidate && !this.closed) {
        options.signal({ type: 'peer_ice', candidate: event.candidate.toJSON() });
      }
    };
    this.peer.onconnectionstatechange = () => {
      if (this.peer.connectionState === 'failed' || this.peer.connectionState === 'closed') this.fail();
    };
    this.peer.ondatachannel = event => this.attach(event.channel);
    this.setupTimer = setTimeout(() => this.fail(), 20_000);
    this.setupTimer.unref();
  }

  async signal(value: Record<string, unknown>): Promise<void> {
    if (this.closed || !this.options.authorized()) return;
    if (value.type === 'peer_switch') {
      if (!this.channelReady || this.ready) throw new Error('invalid_peer_switch');
      // Ordered WebSocket markers drain old messages before the new path is used.
      this.options.signal({ type: 'peer_switched' });
      this.ready = true;
      clearTimeout(this.setupTimer);
    } else if (value.type === 'peer_offer') {
      if (this.accepting || typeof value.sdp !== 'string' || value.sdp.length > 32 * 1024) return;
      this.accepting = (async () => {
        await this.peer.setRemoteDescription({ type: 'offer', sdp: value.sdp as string });
        const answer = await this.peer.createAnswer();
        await this.peer.setLocalDescription(answer);
        if (!this.closed) this.options.signal({ type: 'peer_answer', sdp: answer.sdp });
      })();
      await this.accepting;
    } else if (value.type === 'peer_ice') {
      if (!this.accepting || typeof value.candidate !== 'object' || value.candidate === null) return;
      if (JSON.stringify(value.candidate).length > 4096) throw new Error('invalid_peer_candidate');
      await this.accepting;
      if (!this.closed) await this.peer.addIceCandidate(value.candidate as RTCIceCandidateInit);
    }
  }

  sendMessage(raw: string): boolean {
    if (!this.ready || this.closed) return false;
    const bytes = Buffer.from(raw);
    if (bytes.length > MAX_MESSAGE_BYTES || this.pendingBytes + bytes.length > MAX_PENDING_BYTES) {
      this.fail();
      return true;
    }
    this.pendingBytes += bytes.length;
    this.sending = this.sending.then(async () => {
      const id = this.messageId++;
      if (this.messageId > 0xffffffff) this.messageId = 0x80000000;
      await this.control({ type: 'message', id, length: bytes.length });
      await this.binary(id, bytes);
      await this.control({ type: 'end', id });
    }).catch(() => this.fail()).finally(() => { this.pendingBytes -= bytes.length; });
    return true;
  }

  close(): void {
    if (this.closed) return;
    this.closed = true;
    this.ready = false;
    clearTimeout(this.setupTimer);
    for (const message of this.messages.values()) clearTimeout(message.timer);
    this.messages.clear();
    for (const upload of this.uploads.values()) upload.request.destroy();
    this.uploads.clear();
    this.channel?.close();
    this.peer.close();
  }

  private fail(): void {
    if (this.closed) return;
    const wasReady = this.ready;
    this.close();
    this.options.signal({ type: 'peer_unavailable' });
    // After a live channel fails, resync instead of replaying an unknown HTTP mutation.
    if (wasReady) this.options.failed();
  }

  private attach(channel: RTCDataChannel): void {
    if (this.closed || this.channel || channel.label !== 'cc-remote-v1' || !channel.ordered
      || channel.maxRetransmits !== null || channel.maxPacketLifeTime !== null) {
      channel.close();
      return;
    }
    this.channel = channel;
    channel.binaryType = 'arraybuffer';
    channel.onclose = () => this.fail();
    channel.onerror = () => this.fail();
    channel.onmessage = event => {
      try {
        if (!this.options.authorized()) { this.fail(); return; }
        if (typeof event.data === 'string') {
          if (event.data.length > 32 * 1024) throw new Error('peer_frame_too_large');
          this.receiveControl(JSON.parse(event.data));
        } else {
          this.receiveBinary(Buffer.from(event.data));
        }
      } catch { this.fail(); }
    };
  }

  private receiveControl(value: Record<string, unknown>): void {
    if (!value || typeof value !== 'object') throw new Error('invalid_peer_frame');
    if (value.type === 'ready') {
      if (this.channelReady) throw new Error('peer_already_ready');
      this.channelReady = true;
      void this.control({ type: 'ready' }).catch(() => this.fail());
      return;
    }
    if (!this.ready) throw new Error('peer_not_ready');
    const id = value.id;
    if (!Number.isSafeInteger(id) || (id as number) < 1 || (id as number) > 0xffffffff) {
      throw new Error('invalid_peer_id');
    }
    const key = id as number;
    if (value.type === 'message') {
      if (key < 0x80000000 || this.messages.size > 0 || this.messages.has(key)
        || !Number.isSafeInteger(value.length) || (value.length as number) < 0
        || (value.length as number) > 64 * 1024) throw new Error('invalid_peer_message');
      const timer = setTimeout(() => this.fail(), 15_000);
      timer.unref();
      this.messages.set(key, { chunks: [], length: 0, expected: value.length as number, timer });
    } else if (value.type === 'request') {
      this.openRequest(key, value);
    } else if (value.type === 'end') {
      const message = this.messages.get(key);
      if (message) {
        clearTimeout(message.timer);
        this.messages.delete(key);
        if (message.length !== message.expected) throw new Error('peer_message_truncated');
        this.options.message(Buffer.concat(message.chunks).toString('utf8'));
      } else {
        const upload = this.uploads.get(key);
        if (!upload || upload.ended) throw new Error('unknown_peer_request');
        if (upload.expected !== undefined && upload.expected !== upload.received) throw new Error('peer_body_truncated');
        upload.ended = true;
        upload.request.end();
      }
    } else if (value.type === 'cancel') {
      const upload = this.uploads.get(key);
      this.uploads.delete(key);
      upload?.request.destroy();
    } else {
      throw new Error('invalid_peer_frame');
    }
  }

  private receiveBinary(frame: Buffer): void {
    if (!this.ready || frame.length < 5 || frame.length > CHUNK_BYTES + 4) throw new Error('invalid_peer_chunk');
    const id = frame.readUInt32BE(0);
    const data = frame.subarray(4);
    const message = this.messages.get(id);
    if (message) {
      message.length += data.length;
      if (message.length > message.expected) throw new Error('peer_message_too_large');
      message.chunks.push(data);
      return;
    }
    const upload = this.uploads.get(id);
    if (!upload || upload.ended) throw new Error('unknown_peer_request');
    upload.received += data.length;
    if (upload.received > MAX_BODY_BYTES || upload.request.writableLength > 2 * 1024 * 1024) {
      throw new Error('peer_upload_too_large');
    }
    upload.request.write(data);
  }

  private openRequest(id: number, value: Record<string, unknown>): void {
    if (id >= 0x80000000 || this.uploads.has(id) || this.uploads.size >= 8
      || !['GET', 'POST', 'DELETE'].includes(String(value.method)) || typeof value.path !== 'string'
      || value.path.length > 8192 || !value.path.startsWith('/api/')) throw new Error('invalid_peer_request');
    const url = new URL(value.path, `http://127.0.0.1:${this.options.port}`);
    if (url.origin !== `http://127.0.0.1:${this.options.port}`
      || !url.pathname.startsWith('/api/') || url.pathname.startsWith('/api/local')) {
      throw new Error('peer_local_api_forbidden');
    }
    const headers: Record<string, string> = { authorization: `Bearer ${this.options.token}` };
    const input = value.headers;
    if (input && typeof input === 'object') {
      for (const name of ['content-type', 'content-length']) {
        const header = (input as Record<string, unknown>)[name];
        if (header !== undefined) {
          if (typeof header !== 'string' || header.length > 1024 || /[\r\n]/.test(header)) throw new Error('invalid_peer_headers');
          headers[name] = header;
        }
      }
    }
    const expected = headers['content-length'] === undefined ? undefined : Number(headers['content-length']);
    if (expected !== undefined && (!Number.isSafeInteger(expected) || expected < 0 || expected > MAX_BODY_BYTES)) {
      throw new Error('invalid_peer_body_length');
    }
    const req = request(url, { method: value.method as string, headers, timeout: 30_000 }, response => {
      void (async () => {
        const responseHeaders: Record<string, string> = {};
        for (const name of ['content-type', 'content-length', 'content-disposition', 'cache-control', 'x-content-type-options']) {
          const header = response.headers[name];
          if (typeof header === 'string') responseHeaders[name] = header;
        }
        await this.control({ type: 'response', id, status: response.statusCode, headers: responseHeaders });
        let bytes = 0;
        for await (const chunk of response) {
          if (!this.options.authorized()) throw new Error('authorization_expired');
          bytes += chunk.length;
          if (bytes > MAX_BODY_BYTES) throw new Error('peer_response_too_large');
          await this.binary(id, chunk);
        }
        await this.control({ type: 'end', id });
      })().catch(() => this.control({ type: 'error', id }).catch(() => this.fail()))
        .finally(() => { this.uploads.delete(id); response.destroy(); });
    });
    req.on('timeout', () => req.destroy(new Error('peer_request_timeout')));
    req.on('error', () => {
      this.uploads.delete(id);
      if (!this.closed) void this.control({ type: 'error', id }).catch(() => this.fail());
    });
    this.uploads.set(id, { request: req, received: 0, expected, ended: false });
  }

  private async control(value: unknown): Promise<void> {
    await this.writable();
    this.channel!.send(JSON.stringify(value));
  }

  private async binary(id: number, data: Buffer): Promise<void> {
    for (let offset = 0; offset < data.length; offset += CHUNK_BYTES) {
      await this.writable();
      const frame = Buffer.allocUnsafe(4 + Math.min(CHUNK_BYTES, data.length - offset));
      frame.writeUInt32BE(id, 0);
      data.copy(frame, 4, offset, offset + CHUNK_BYTES);
      this.channel!.send(frame);
    }
  }

  private async writable(): Promise<void> {
    const deadline = Date.now() + 15_000;
    while (!this.closed && this.channel?.readyState === 'open') {
      if (!this.options.authorized()) break;
      if (this.channel.bufferedAmount < 512 * 1024) return;
      if (Date.now() >= deadline) break;
      await delay(10);
    }
    throw new Error('peer_channel_unavailable');
  }
}
