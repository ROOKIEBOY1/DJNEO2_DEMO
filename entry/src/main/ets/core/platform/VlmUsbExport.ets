import { util } from '@kit.ArkTS';
import { socket } from '@kit.NetworkKit';
import { VLM_SELECTION_TIMEOUT_MS, VlmFrame } from '../media/VlmFrame';
import { AgentObservation, AgentResponse } from '../domain/AgentAction';

export async function requestAgentAction(observation: AgentObservation, description: string): Promise<AgentResponse> {
  const frame = observation.frame;
  const meta = util.TextEncoder.create().encodeInto(JSON.stringify({
    protocolVersion: 2, requestId: observation.requestId, sessionId: observation.sessionId,
    requestedAtMs: observation.requestedAtMs, selectionPrompt: description, context: observation.context,
    candidates: frame?.candidates ?? [], currentSubjectId: frame?.currentSubjectId,
    width: frame?.width, height: frame?.height, capturedAtMs: frame?.capturedAtMs,
    candidatesObservedAtMs: frame?.candidatesObservedAtMs, captureMs: 0
  }));
  const jpeg = frame === undefined ? new Uint8Array(0) : new Uint8Array(frame.jpeg);
  const packet = new Uint8Array(8 + meta.length + jpeg.length);
  const header = new DataView(packet.buffer);
  header.setUint32(0, meta.length, true);
  header.setUint32(4, jpeg.length, true);
  packet.set(meta, 8);
  packet.set(jpeg, 8 + meta.length);
  const tcp = socket.constructTCPSocketInstance();
  const reply = new Uint8Array(8196);
  let received = 0;
  let expected = 0;
  let failed = false;
  tcp.on('message', (event: socket.SocketMessageInfo) => {
    const bytes = new Uint8Array(event.message);
    if (received + bytes.length > reply.length) { failed = true; return; }
    reply.set(bytes, received);
    received += bytes.length;
    if (received >= 4 && expected === 0) {
      const size = new DataView(reply.buffer).getUint32(0, true);
      if (size < 2 || size > 8192) { failed = true; return; }
      expected = size + 4;
    }
    if (expected > 0 && received > expected) failed = true;
  });
  tcp.on('error', () => { failed = true; });
  try {
    await tcp.connect({ address: { address: '127.0.0.1', family: 1, port: 18732 }, timeout: 1200 });
    await tcp.send({ data: packet.buffer as ArrayBuffer });
    const deadline = observation.requestedAtMs + VLM_SELECTION_TIMEOUT_MS;
    while (!failed && (expected === 0 || received < expected) && Date.now() < deadline) {
      await new Promise<void>((resolve: () => void) => setTimeout(resolve, 8));
    }
    if (failed) throw new Error('动作响应传输失败');
    if (expected === 0 || received !== expected) throw new Error('云端动作识别超时，请重试');
    const text = util.TextDecoder.create('utf-8').decodeToString(reply.slice(4, expected));
    return JSON.parse(text) as AgentResponse;
  } finally {
    await tcp.close().catch(() => {});
  }
}

export async function sendVlmSample(frame: VlmFrame, captureMs: number, description: string): Promise<number | undefined> {
  const meta = util.TextEncoder.create().encodeInto(JSON.stringify({
    width: frame.width, height: frame.height, sessionId: frame.sessionId, capturedAtMs: frame.capturedAtMs,
    candidatesObservedAtMs: frame.candidatesObservedAtMs, candidates: frame.candidates, captureMs: captureMs,
    selectionPrompt: description, currentSubjectId: frame.currentSubjectId
  }));
  const packet = new Uint8Array(8 + meta.length + frame.jpeg.byteLength);
  const header = new DataView(packet.buffer);
  header.setUint32(0, meta.length, true);
  header.setUint32(4, frame.jpeg.byteLength, true);
  packet.set(meta, 8);
  packet.set(new Uint8Array(frame.jpeg), 8 + meta.length);
  const tcp = socket.constructTCPSocketInstance();
  const reply: number[] = [];
  tcp.on('message', (event: socket.SocketMessageInfo) => {
    const data = new Uint8Array(event.message);
    for (let i = 0; i < data.length && reply.length < 2; i++) reply.push(data[i]);
  });
  try {
    await tcp.connect({ address: { address: '127.0.0.1', family: 1, port: 18732 }, timeout: 1200 });
    await tcp.send({ data: packet.buffer as ArrayBuffer });
    const deadline = frame.capturedAtMs + VLM_SELECTION_TIMEOUT_MS;
    while (reply.length < 2 && Date.now() < deadline) {
      await new Promise<void>((resolve: () => void) => setTimeout(resolve, 8));
    }
    if (reply.length < 2) throw new Error('等待视觉选择超时，请重新取样');
    if (reply[0] === 0) return undefined;
    if (reply[0] !== 1) throw new Error('电脑返回了无效的视觉选择');
    return reply[1];
  } finally {
    await tcp.close().catch(() => {});
  }
}
