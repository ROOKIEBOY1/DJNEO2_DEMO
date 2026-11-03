import { abilityAccessCtrl, Context, Permissions } from '@kit.AbilityKit';
import { speechRecognizer } from '@kit.CoreSpeechKit';
import { VoiceCommandAdapter } from '../domain/VoiceCommandAdapter';

export type SpeechStatusListener = (message: string) => void;

export class LocalSpeechRecognizer {
  private readonly context: Context;
  private readonly adapter: VoiceCommandAdapter;
  private engine?: speechRecognizer.SpeechRecognitionEngine;
  private sessionId: string = '';
  private active: boolean = false;
  private statusListener?: SpeechStatusListener;

  constructor(context: Context, adapter: VoiceCommandAdapter) {
    this.context = context;
    this.adapter = adapter;
  }

  setStatusListener(listener?: SpeechStatusListener): void {
    this.statusListener = listener;
  }

  async start(): Promise<void> {
    if (this.active) return;
    const permission = 'ohos.permission.MICROPHONE' as Permissions;
    const result = await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(this.context, [permission]);
    if (result.authResults.length < 1 || result.authResults[0] !== 0) {
      throw new Error('Microphone permission was denied');
    }
    const engine = await speechRecognizer.createEngine({
      language: 'zh-CN',
      online: 1,
      extraParams: { 'locate': 'CN', 'recognizerMode': 'short' }
    });
    engine.setListener({
      onStart: (_sessionId: string, _eventMessage: string): void => {
        this.adapter.setListening(true);
        this.emit('本地识别已开始');
      },
      onEvent: (_sessionId: string, _eventCode: number, _eventMessage: string): void => {},
      onResult: (_sessionId: string, recognition: speechRecognizer.SpeechRecognitionResult): void => {
        if (recognition.isFinal && recognition.result.trim().length > 0) {
          this.adapter.acceptTranscript(recognition.result);
          this.emit(`识别: ${recognition.result}`);
        }
      },
      onComplete: (_sessionId: string, _eventMessage: string): void => {
        this.active = false;
        this.adapter.setListening(false);
        if (this.engine === engine) {
          this.engine = undefined;
          engine.shutdown();
        }
        this.emit('本地识别已完成');
      },
      onError: (_sessionId: string, errorCode: number, errorMessage: string): void => {
        this.active = false;
        this.adapter.setListening(false);
        if (this.engine === engine) {
          this.engine = undefined;
          engine.shutdown();
        }
        this.emit(`识别错误 ${errorCode}: ${errorMessage}`);
      }
    });
    this.sessionId = `neo-${Date.now()}`;
    this.engine = engine;
    this.active = true;
    try {
      engine.startListening({
        sessionId: this.sessionId,
        audioInfo: { audioType: 'pcm', sampleRate: 16000, soundChannel: 1, sampleBit: 16 },
        extraParams: {
          'recognitionMode': 0,
          'vadBegin': 2000,
          'vadEnd': 3000,
          'maxAudioDuration': 20000,
          'srcType': 1,
          'recognizerOption': { 'enablePartialResult': false }
        }
      });
      this.emit('正在启动本地语音识别');
    } catch (error) {
      this.active = false;
      this.engine = undefined;
      engine.shutdown();
      throw error instanceof Error ? error : new Error(String(error));
    }
  }

  async stop(finish: boolean = true): Promise<void> {
    if (!this.active) return;
    this.active = false;
    const engine = this.engine;
    const sessionId = this.sessionId;
    this.engine = undefined;
    this.adapter.setListening(false);
    if (engine !== undefined) {
      if (finish) engine.finish(sessionId); else engine.cancel(sessionId);
      engine.shutdown();
    }
    this.emit('本地语音识别已停止');
  }

  private emit(message: string): void {
    const listener = this.statusListener;
    if (listener !== undefined) listener(message);
  }
}
