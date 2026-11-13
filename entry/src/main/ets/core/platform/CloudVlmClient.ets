import { rcp } from '@kit.RemoteCommunicationKit';
import { connection } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AgentContext, AgentObservation, AgentResponse, agentObservationTimeoutMs } from '../domain/AgentAction';
import { makeDeepSeekBody, parseDeepSeekResponse, SubjectSelectionProtocolError } from '../domain/DeepSeekPayload';
import { needsSelfReference } from '../domain/SelfReference';
import { CloudVlmKeyStore } from './CloudVlmKeyStore';
import { SelfReferencePhotoProvider } from './SelfReferencePhotoStore';

const ENDPOINT: string = 'https://api.deepseek.com/chat/completions';

export class CloudVlmClient {
  private readonly keys: CloudVlmKeyStore;
  private readonly referencePhotos?: SelfReferencePhotoProvider;
  private session?: rcp.Session;
  private networkId?: number;
  private busy: boolean = false;
  private activeRequest?: rcp.Request;
  constructor(keys: CloudVlmKeyStore, referencePhotos?: SelfReferencePhotoProvider) {
    this.keys = keys; this.referencePhotos = referencePhotos;
  }

  close(): void {
    try { this.session?.close(); } catch (_) {}
    this.session = undefined; this.activeRequest = undefined; this.networkId = undefined;
  }
  cancelPending(): void {
    if (this.activeRequest !== undefined) {
      try { this.session?.cancel(this.activeRequest); } catch (_) {}
    }
  }

  async request(observation: AgentObservation, description: string, isCurrent: () => boolean, deadlineMs?: number): Promise<AgentResponse> {
    if (this.busy) throw new Error('已有云端请求处理中，请稍候');
    this.busy = true;
    const deadline = Math.min(observation.requestedAtMs + agentObservationTimeoutMs(observation), deadlineMs ?? Infinity);
    const started = Date.now();
    try {
      if (!isCurrent()) throw new Error('云端请求已取消或飞机会话发生变化');
      const key = await this.keys.read();
      if (key === undefined || key.length === 0) throw new Error('尚未配置云端API Key，请长按标题打开设置');
      const netId = await internetNetwork();
      if (!isCurrent()) throw new Error('云端请求已取消或飞机会话发生变化');
      if (deadline <= Date.now()) throw new Error('云端请求已过期，请重新说');
      let referenceJpeg: string | undefined;
      if (needsSelfReference(observation, description)) {
        try { referenceJpeg = await this.referencePhotos?.read(); }
        catch (_) { throw new Error('“我”的参考照片不可用，请检查本机参考照片'); }
        if (!isCurrent()) throw new Error('云端请求已取消或飞机会话发生变化');
        if (deadline <= Date.now()) throw new Error('云端请求已过期，请重新说');
        if (referenceJpeg === undefined || referenceJpeg.length === 0) {
          throw new Error('缺少“我”的参考照片，请先配置本机参考照片');
        }
      }
      if (this.session === undefined || this.networkId !== netId) {
        this.close(); this.session = rcp.createSession(); this.networkId = netId;
      }
      const session = this.session;
      const frame = observation.frame;
      const jpeg = frame === undefined ? undefined :
        `data:image/jpeg;base64,${new util.Base64Helper().encodeToStringSync(new Uint8Array(frame.jpeg))}`;
      for (let attempt = 1; attempt <= 2; attempt++) {
        if (!isCurrent()) throw new Error('云端请求已取消或飞机会话发生变化');
        if (deadline <= Date.now()) throw new Error('云端请求已过期，请重新说');
        const body = makeDeepSeekBody(observation, description, jpeg, referenceJpeg, attempt === 2);
        if (!isCurrent()) throw new Error('云端请求已取消或飞机会话发生变化');
        const remaining = deadline - Date.now();
        if (remaining <= 0) throw new Error('云端请求已过期，请重新说');
        const request = new rcp.Request(ENDPOINT, 'POST', {
          'Authorization': `Bearer ${key}`, 'Content-Type': 'application/json'
        }, body, undefined, undefined, { transfer: { autoRedirect: false,
          timeout: { connectMs: Math.min(3500, remaining), transferMs: remaining } } });
        const chunks: Uint8Array[] = [];
        let size = 0;
        let abortReason = '';
        let watchdog: number | undefined;
        request.destination = (incoming: ArrayBuffer): void => {
          size += incoming.byteLength;
          if (size > 65536) { abortReason = '云端响应超过大小限制'; try { session.cancel(request); } catch (_) {} return; }
          chunks.push(new Uint8Array(incoming.slice(0)));
        };
        try {
          this.activeRequest = request;
          watchdog = setInterval(() => {
            if (!isCurrent() || Date.now() >= deadline) {
              abortReason = !isCurrent() ? '云端请求已取消或飞机会话发生变化' : '云端动作识别超时，请重试';
              try { session.cancel(request); } catch (_) {}
            }
          }, 100);
          let response: rcp.Response;
          try {
            if (!isCurrent()) throw new Error('云端请求已取消或飞机会话发生变化');
            if (deadline <= Date.now()) { abortReason = '云端请求已过期，请重新说'; throw new Error(abortReason); }
            response = await session.fetch(request);
          }
          catch (error) {
            throw new Error(abortReason || (!isCurrent() ? '云端请求已取消或飞机会话发生变化' :
              deadline <= Date.now() ? '云端请求已过期，请重新说' :
                `云端网络请求失败，请检查热点上网（${(error as BusinessError).code ?? '网络错误'}）`));
          }
          if (!isCurrent()) throw new Error('云端请求已取消或飞机会话发生变化');
          if (deadline <= Date.now()) throw new Error('云端请求已过期，请重新说');
          if (abortReason.length > 0) throw new Error(abortReason);
          if (response.statusCode === 401 || response.statusCode === 403) throw new Error('云端密钥未获授权，请检查API Key');
          if (response.statusCode === 429) throw new Error('云端请求过于频繁或额度不足，请稍后重试');
          if (response.statusCode >= 300 && response.statusCode < 400) throw new Error('云端返回跳转，已拒绝转发密钥');
          if (response.statusCode !== 200) throw new Error(`云端服务暂不可用（HTTP ${response.statusCode}）`);
          const bytes = new Uint8Array(size); let offset = 0;
          chunks.forEach((chunk: Uint8Array) => { bytes.set(chunk, offset); offset += chunk.length; });
          const text = util.TextDecoder.create('utf-8').decodeToString(bytes);
          if (!isCurrent()) throw new Error('云端请求已取消或飞机会话发生变化');
          if (deadline <= Date.now()) throw new Error('云端请求已过期，请重新说');
          let result: AgentResponse;
          try {
            result = parseDeepSeekResponse(text, observation, Date.now());
          } catch (error) {
            if (!isCurrent()) throw new Error('云端请求已取消或飞机会话发生变化');
            if (deadline <= Date.now()) throw new Error('云端请求已过期，请重新说');
            if (observation.purpose === 'subject_selection' && error instanceof SubjectSelectionProtocolError) {
              hilog.warn(0, 'NeoVlm', '云端响应拒绝 phase=%{public}s action=%{public}s attempt=%{public}d reason=%{public}s',
                'subject_selection', error.action, attempt, 'selection_protocol');
              if (attempt === 1) continue;
            }
            throw error as Error;
          }
          if (!isCurrent()) throw new Error('云端请求已取消或飞机会话发生变化');
          if (deadline <= Date.now()) throw new Error('云端请求已过期，请重新说');
          hilog.info(0, 'NeoVlm', '手机直连返回 action=%{public}s 耗时=%{public}dms', result.command?.action ?? '无', Date.now() - started);
          return result;
        } finally {
          if (watchdog !== undefined) clearInterval(watchdog);
          if (this.activeRequest === request) this.activeRequest = undefined;
        }
      }
      throw new Error('云端选人响应无效，请重试');
    } finally {
      this.activeRequest = undefined; this.busy = false;
    }
  }

  async testConnection(): Promise<void> {
    const now = Date.now();
    const context: AgentContext = { phase: 'testing', airborne: false, flightStateFresh: false, tracking: false,
      taskKind: '', taskPrepared: false, taskActive: false, cameraIdle: true, recording: false,
      radiusMeters: 2, framing: '半身', zoom: 2, retreat: true, movementSeconds: 0.5 };
    const observation: AgentObservation = { requestId: `cloud-test-${now}`, sessionId: 0, flightGeneration: 0,
      controlGeneration: 0, requestedAtMs: now, context: context };
    await this.request(observation, '这是云端连接测试，请返回none，不执行任何飞行动作', () => true);
  }
}

async function internetNetwork(): Promise<number> {
  try {
    const handle = await connection.getDefaultNet();
    const caps = await connection.getNetCapabilities(handle);
    const props = await connection.getConnectionProperties(handle);
    if (!caps.networkCap?.includes(connection.NetCap.NET_CAPABILITY_INTERNET) ||
      props.linkAddresses.some(address => address.address.address.startsWith('192.168.2.'))) {
      throw new Error('unavailable');
    }
    hilog.info(0, 'NeoVlm', '云端默认上网网络 netId=%{public}d 接口=%{public}s', handle.netId, props.interfaceName);
    return handle.netId;
  } catch (_) { throw new Error('手机默认网络尚不可上网，请确认热点互联网链路已启用'); }
}
