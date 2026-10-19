import { createHash } from 'node:crypto';
import type { TranscriptMessage } from './transcriptState.js';

export type NativeMessage = {
  id: string;
  role: 'user' | 'assistant';
  text: string;
};

export type NativeHistory = {
  sessionId: string;
  messages: NativeMessage[];
  running: boolean;
};

export type NativeBinding = { ids: string[]; hash: string };

type Turn<T> = { messages: T[] };

function turns<T extends { role: string }>(messages: T[]): { leading: T[]; turns: Turn<T>[] } {
  const leading: T[] = [];
  const result: Turn<T>[] = [];
  for (const message of messages) {
    if (message.role === 'user') result.push({ messages: [] });
    (result.at(-1)?.messages ?? leading).push(message);
  }
  return { leading, turns: result };
}

function normalize(text: string): string {
  return text.replace(/\r\n/g, '\n').trim();
}

function assistantText(turn: Turn<{ role: string; text: string }>): string {
  return normalize(turn.messages.filter(message => message.role === 'assistant')
    .map(message => message.text).join(''));
}

function turnKey(prompt: string, turn: Turn<{ role: string; text: string }>): string {
  return JSON.stringify([normalize(prompt), assistantText(turn)]);
}

function binding(turn: Turn<NativeMessage>): NativeBinding {
  return {
    ids: turn.messages.map(message => message.id),
    hash: createHash('sha256').update(JSON.stringify(turn.messages)).digest('hex'),
  };
}

function matches(local: Turn<TranscriptMessage>, native: Turn<NativeMessage>): boolean {
  const user = local.messages[0];
  let prompt = normalize(user.nativePrompt ?? user.text);
  const nativePrompt = normalize(native.messages[0].text);
  if (!user.nativePrompt && user.attachments?.length) {
    prompt ||= '请查看附件并根据内容处理。';
    const marker = '\n\n以下附件由用户通过 CC Remote 上传。请先读取需要的文件。\n';
    if (nativePrompt.startsWith(prompt + marker)) {
      return assistantText(local) === assistantText(native);
    }
  }
  return prompt === nativePrompt && assistantText(local) === assistantText(native);
}

export function mergeNativeMessages(
  messages: TranscriptMessage[],
  incoming: NativeMessage[],
  start = 0,
): { messages: TranscriptMessage[]; external: boolean } {
  const local = turns(messages.slice(start));
  const native = turns(incoming).turns;
  if (native.length === 0) {
    if (local.turns.some(turn => turn.messages[0].native)) throw new Error('native_history_conflict');
    return { messages, external: false };
  }
  const ids = new Set<string>();
  for (const message of incoming) {
    if (!message.id || ids.has(message.id)) throw new Error('native_history_invalid');
    ids.add(message.id);
  }
  const byId = new Map<string, number>();
  const byText = new Map<string, number[]>();
  native.forEach((turn, index) => {
    byId.set(turn.messages[0].id, index);
    const key = turnKey(turn.messages[0].text, turn);
    const indexes = byText.get(key) ?? [];
    indexes.push(index);
    byText.set(key, indexes);
  });

  const candidates = local.turns.map(turn => {
    if (turn.messages[0].nativeLocalOnly) return null;
    const user = turn.messages[0];
    const previous = user.native;
    const known = previous ? byId.get(previous.ids[0]) : undefined;
    const indexes = previous ? known === undefined ? [] : [known]
      : user.attachments?.length && !user.nativePrompt
        ? native.flatMap((source, index) => matches(turn, source) ? [index] : [])
        : byText.get(turnKey(user.nativePrompt ?? user.text, turn)) ?? [];
    // Failed requests may never have reached the engine; retain their diagnostics.
    if (indexes.length === 0 && !previous && !assistantText(turn)
        && turn.messages.some(message => message.role === 'system')) return null;
    if (indexes.length === 0) throw new Error('native_history_conflict');
    return indexes;
  });
  const earliest: number[] = [];
  let previousIndex = -1;
  for (const indexes of candidates) {
    if (!indexes) { earliest.push(-1); continue; }
    const index = indexes.find(candidate => candidate > previousIndex);
    if (index === undefined) throw new Error('native_history_conflict');
    earliest.push(index);
    previousIndex = index;
  }
  let nextIndex = native.length;
  for (let index = candidates.length - 1; index >= 0; index--) {
    const indexes = candidates[index];
    if (!indexes) continue;
    const match = [...indexes].reverse().find(candidate => candidate < nextIndex);
    if (match !== earliest[index]) throw new Error('native_history_conflict');
    nextIndex = match;
  }

  const matched = new Map<number, number>();
  earliest.forEach((index, localIndex) => { if (index >= 0) matched.set(index, localIndex); });
  const result: TranscriptMessage[] = [...messages.slice(0, start), ...local.leading];
  let external = false;
  let localIndex = 0;
  const appendDiagnostics = () => {
    while (localIndex < local.turns.length && candidates[localIndex] === null) {
      result.push(...local.turns[localIndex++].messages);
    }
  };
  appendDiagnostics();
  native.forEach((turn, index) => {
    const nextBinding = binding(turn);
    const existingIndex = matched.get(index);
    if (existingIndex === undefined) {
      external = true;
      result.push(...turn.messages.map((message, messageIndex): TranscriptMessage => ({
        role: message.role,
        text: message.text,
        ...(messageIndex === 0 ? { native: nextBinding } : {}),
      })));
      return;
    }
    const existing = local.turns[existingIndex].messages;
    const previous = existing[0].native;
    if (previous && previous.ids.some(id => !nextBinding.ids.includes(id))) {
      throw new Error('native_history_conflict');
    }
    if (previous && previous.hash !== nextBinding.hash) {
      external = true;
      result.push({ ...existing[0], native: nextBinding });
      const replies = turn.messages.slice(1);
      for (const message of existing.slice(1)) {
        if (message.role !== 'assistant') result.push(message);
        else {
          const reply = replies.shift();
          if (reply) result.push({ ...message, text: reply.text });
        }
      }
      result.push(...replies.map(message => ({ role: message.role, text: message.text })));
    } else {
      result.push({ ...existing[0], native: nextBinding }, ...existing.slice(1));
    }
    localIndex = existingIndex + 1;
    appendDiagnostics();
  });
  return { messages: result, external };
}
