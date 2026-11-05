import { abilityAccessCtrl, Context, Permissions } from '@kit.AbilityKit';
import { speechRecognizer } from '@kit.CoreSpeechKit';
import { VoiceCommandAdapter } from '../domain/VoiceCommandAdapter';
export type SpeechStatusListener = (message: string) => void;
interface SpeechRequest {
  resolve: (text: string) => void;
  reject: (error: Error) => void;
  timer: number;
  ready?: () => void;
  followUp: boolean;
}
export class LocalSpeechRecognizer {
  private readonly context: Context;
  private readonly adapter: VoiceCommandAdapter;
  private engine?: speechRecognizer.SpeechRecognitionEngine;
  private sessionId: string = '';
  private wanted: boolean = false;
  private generation: number = 0;
  private restartTimer?: number;
  private statusListener?: SpeechStatusListener;
  private request?: SpeechRequest;
  constructor(context: Context, adapter: VoiceCommandAdapter) { this.context = context; this.adapter = adapter; }
  setStatusListener(listener?: SpeechStatusListener): void { this.statusListener = listener; }
  async start(): Promise<void> {
    if (this.wanted || !this.adapter.snapshot().enabled) return;
    this.wanted = true; const generation = ++this.generation;
    this.adapter.setListening(true); this.emit('正在启动离线中文连续聆听');
    try {
      await this.begin(generation);
    } catch (error) {
      if (this.current(generation)) { await this.stop(false); throw error instanceof Error ? error : new Error(String(error)); }
    }
  }
  listenOnce(ready?: () => void, followUp: boolean = false): Promise<string> {
    if (this.wanted) return Promise.reject(new Error('请先停止当前的语音聆听'));
    this.wanted = true;
    const generation = ++this.generation;
    return new Promise<string>((resolve: (text: string) => void, reject: (error: Error) => void) => {
      const timer = setTimeout(() => this.fail(generation, '语音输入超时，请重试'), 15000);
      this.request = { resolve: resolve, reject: reject, timer: timer, ready: ready, followUp: followUp };
      this.begin(generation).catch((error: Error) => this.fail(generation, error.message));
    });
  }
  async cancelOnce(): Promise<void> {
    if (this.request !== undefined) await this.stop(false);
  }
  isListeningOnce(): boolean { return this.request !== undefined; }
  private async begin(generation: number): Promise<void> {
    const permission = 'ohos.permission.MICROPHONE' as Permissions;
    const result = await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(this.context, [permission]);
    if (!this.current(generation)) return;
    if (result.authResults.length < 1 || result.authResults[0] !== 0) throw new Error('麦克风权限未允许');
    await this.startSession(generation);
  }
  private current(generation: number): boolean {
    return this.wanted && generation === this.generation && (this.request !== undefined || this.adapter.snapshot().enabled);
  }
  private async startSession(generation: number): Promise<void> {
    if (!this.current(generation)) return;
    const engine = await speechRecognizer.createEngine({ language: 'zh-CN', online: 1,
      extraParams: { 'locate': 'CN', 'recognizerMode': 'short' } });
    if (!this.current(generation)) { engine.shutdown(); return; }
    const sessionId = `neo-${generation}-${Date.now()}`;
    this.sessionId = sessionId; this.engine = engine;
    let acceptedFinal: boolean = false;
    const valid = (id: string): boolean => this.current(generation) && this.engine === engine && id === sessionId;
    engine.setListener({
      onStart: (id: string, _event: string): void => {
        if (!valid(id)) return;
        if (this.request === undefined) this.adapter.setListening(true);
        this.request?.ready?.();
        this.emit(this.request === undefined ? '离线聆听中；每次说一个口令' : '请说你想选哪个人');
      },
      onEvent: (_id: string, _code: number, _message: string): void => {},
      onResult: (id: string, recognition: speechRecognizer.SpeechRecognitionResult): void => {
        if (!valid(id) || acceptedFinal || !recognition.isFinal || recognition.result.trim().length === 0) return;
        acceptedFinal = true;
        const request = this.request;
        if (request !== undefined) {
          this.request = undefined;
          clearTimeout(request.timer);
          this.stop(false).then(() => request.resolve(recognition.result.trim()),
            (error: Error) => request.reject(error));
          return;
        }
        this.adapter.acceptTranscript(recognition.result); this.emit(`识别：${recognition.result}`);
      },
      onComplete: (id: string, _message: string): void => {
        if (!valid(id)) return;
        if (this.request !== undefined) {
          this.fail(generation, '没有听清选人描述，请重试');
          return;
        }
        this.engine = undefined;
        try { engine.shutdown(); } catch (_) {}
        if (!this.current(generation)) return;
        this.restartTimer = setTimeout(() => {
          this.restartTimer = undefined;
          this.startSession(generation).catch((error: Error) => this.fail(generation, error.message));
        }, 200);
      },
      onError: (id: string, code: number, message: string): void => {
        if (valid(id)) this.fail(generation, `离线识别错误 ${code}：${message}；请重新开始聆听`);
      }
    });
    try {
      engine.startListening({ sessionId: sessionId,
        audioInfo: { audioType: 'pcm', sampleRate: 16000, soundChannel: 1, sampleBit: 16 },
        extraParams: { 'recognitionMode': 0, 'vadBegin': this.request?.followUp ? 8000 : 2000,
          'vadEnd': 1000, 'maxAudioDuration': 20000,
          'srcType': 1, 'recognizerOption': { 'enablePartialResult': false } } });
    } catch (error) {
      if (this.engine === engine) this.engine = undefined;
      try { engine.shutdown(); } catch (_) {}
      throw error instanceof Error ? error : new Error(String(error));
    }
  }
  async stop(finish: boolean = false): Promise<void> {
    await this.stopWithMessage(finish, '语音输入已取消');
  }
  private async stopWithMessage(finish: boolean, message: string): Promise<void> {
    this.wanted = false; this.generation++;
    const request = this.request;
    this.request = undefined;
    if (request !== undefined) {
      clearTimeout(request.timer);
      request.reject(new Error(message));
    }
    if (this.restartTimer !== undefined) { clearTimeout(this.restartTimer); this.restartTimer = undefined; }
    const engine = this.engine; const id = this.sessionId; this.engine = undefined;
    this.adapter.setListening(false); this.adapter.cancelPending();
    if (engine !== undefined) {
      try { if (finish) engine.finish(id); else engine.cancel(id); }
      finally { engine.shutdown(); }
    }
    this.emit('离线聆听已停止');
  }
  private fail(generation: number, message: string): void {
    if (!this.current(generation)) return;
    this.stopWithMessage(false, message).catch((error: Error) => this.emit(`识别清理：${error.message}`));
    this.emit(message);
  }
  private emit(message: string): void { this.statusListener?.(message); }
}
