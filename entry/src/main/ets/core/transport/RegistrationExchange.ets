import { hilog } from '@kit.PerformanceAnalysisKit';
import { concatBytes, fromHex, readU16LE, toHex, writeU16LE, writeU32LE } from '../protocol/Bytes';
import { OBSERVED_TRAILER_PREFIX, TRAILER_SUFFIX } from '../protocol/CommandCodec';
import { encodeDumlFrame } from '../protocol/DumlCodec';
import { sha256Hex } from '../protocol/Sha256';

const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'NeoReg';

export interface RegistrationTemplateDefinition {
  name: string;
  sender: number;
  receiver: number;
  flags: number;
  commandSet: number;
  commandId: number;
  tunneled: boolean;
  payloadHex: string;
}

export interface RegistrationResponseRuleDefinition {
  key: string;
  template: string;
}

export interface RegistrationProfileDocument {
  version: number;
  profileId: string;
  routingIdentity: string;
  templates: RegistrationTemplateDefinition[];
  responseRules: RegistrationResponseRuleDefinition[];
}

export interface RegistrationProfile {
  profileId: string;
  routingIdentity: string;
  templates: Map<string, RegistrationTemplateDefinition>;
  responseRules: Map<string, string>;
}

interface ScheduledTemplate {
  delayMs: number;
  name: string;
}

interface PendingResponse {
  template: RegistrationTemplateDefinition;
  sequence: number;
  payload?: Uint8Array;
}

export interface RegistrationSnapshot {
  sent: number;
  requestsSeen: number;
  responses: number;
  remoteState: string;
  schemaResponses: number;
  unknownRequests: number;
}

export class RegistrationExchange {
  private readonly templates: Map<string, RegistrationTemplateDefinition>;
  private readonly responseRules: Map<string, string>;
  private readonly startedAt: number;
  private readonly responsesQueue: PendingResponse[] = [];
  private readonly schedule: ScheduledTemplate[] = [
    { delayMs: 0, name: 'register' },
    { delayMs: 50, name: 'info_direct' },
    { delayMs: 150, name: 'open' },
    { delayMs: 300, name: 'identity' },
    { delayMs: 450, name: 'capabilities' },
    { delayMs: 650, name: 'info_tunnel' },
    { delayMs: 1800, name: 'info_tunnel' }
  ];
  private heartbeatAt: number;
  private heartbeatCounter: number = 0;
  private remoteState: Uint8Array = new Uint8Array([1, 1, 1]);
  private remoteTail: Uint8Array = new Uint8Array(3);
  private sentCount: number = 0;
  private responseCount: number = 0;
  private requestCount: number = 0;
  private schemaResponseCount: number = 0;
  private unknownRequestCount: number = 0;

  constructor(startedAtMs: number, profile: RegistrationProfile) {
    this.startedAt = startedAtMs;
    this.heartbeatAt = startedAtMs;
    this.templates = profile.templates;
    this.responseRules = profile.responseRules;
  }

  observe(frame: Uint8Array): void {
    if (frame.length < 13 || frame[4] !== 0xe9 || frame[5] !== 0xee || frame[9] !== 0x51) {
      return;
    }
    const payload = new Uint8Array(frame.slice(11, frame.length - 2));
    if (frame[10] === 0x13 && payload.length === 55) {
      this.remoteState = new Uint8Array(payload.slice(24, 27));
      this.remoteTail = new Uint8Array(payload.slice(52, 55));
      return;
    }
    if (frame[8] !== 0x40) {
      return;
    }

    let template: RegistrationTemplateDefinition | undefined;
    let responsePayload: Uint8Array | undefined;
    try {
      if (frame[10] === 0x41) {
        const candidate = this.requiredTemplate('response_41:65:0002');
        responsePayload = channelAcknowledgement(payload, fromHex(candidate.payloadHex));
        template = candidate;
      } else if (frame[10] === 6) {
        const candidate = this.requiredTemplate('response_06:51:0000');
        responsePayload = identityAcknowledgement(payload, fromHex(candidate.payloadHex));
        template = candidate;
      }
    } catch (_) {
      responsePayload = undefined;
      template = undefined;
    }
    if (template === undefined) {
      const key = `${frame[10].toString(16).padStart(2, '0')}:${sha256Hex(payload)}`;
      const rule = this.responseRules.get(key);
      if (rule !== undefined) {
        template = this.templates.get(rule);
        hilog.info(LOG_DOMAIN, LOG_TAG, 'response rule matched id=0x%{public}d hash=%{public}s template=%{public}s',
          frame[10], key.slice(3, 19), rule);
      } else {
        hilog.info(LOG_DOMAIN, LOG_TAG, 'no response rule for id=0x%{public}d hash=%{public}s payload=%{public}s',
          frame[10], key.slice(3, 19), toHex(payload));
      }
    }
    if (template === undefined) {
      this.unknownRequestCount++;
      return;
    }
    this.requestCount++;
    if (responsePayload !== undefined) {
      this.schemaResponseCount++;
    }
    if (this.responsesQueue.length < 32) {
      this.responsesQueue.push({ template: template, sequence: readU16LE(frame, 6), payload: responsePayload });
    }
  }

  poll(nowMs: number, nextSequence: () => number, nextOuterSequence: () => number): Uint8Array[] {
    const result: Uint8Array[] = [];
    while (this.responsesQueue.length > 0) {
      const pending = this.responsesQueue.shift();
      if (pending !== undefined) {
        result.push(encodeRegistrationMessage(pending.template, pending.sequence,
          nextOuterSequence(), pending.payload));
        this.responseCount++;
      }
    }
    while (this.schedule.length > 0 && nowMs - this.startedAt >= this.schedule[0].delayMs) {
      const scheduled = this.schedule.shift();
      if (scheduled !== undefined) {
        result.push(encodeRegistrationMessage(this.requiredTemplate(scheduled.name), nextSequence(),
          nextOuterSequence()));
      }
    }
    if (nowMs >= this.heartbeatAt) {
      const heartbeat = this.requiredTemplate('heartbeat');
      const payload = fromHex(heartbeat.payloadHex);
      // Original PC fix: aircraft 04/04/04 corresponds to local 05/04/04 in Fly captures.
      payload.set(toHex(this.remoteState) === '040404' ? new Uint8Array([5, 4, 4]) : this.remoteState, 24);
      writeU32LE(payload, 39, this.heartbeatCounter >>> 0);
      writeU32LE(payload, 43, Math.floor(nowMs - this.startedAt) >>> 0);
      payload.set(this.remoteTail, 52);
      result.push(encodeRegistrationMessage(heartbeat, nextSequence(), nextOuterSequence(), payload));
      this.heartbeatCounter = (this.heartbeatCounter + 1) >>> 0;
      this.heartbeatAt = nowMs + 200;
    }
    this.sentCount += result.length;
    return result;
  }

  snapshot(): RegistrationSnapshot {
    return {
      sent: this.sentCount,
      requestsSeen: this.requestCount,
      responses: this.responseCount,
      remoteState: toHex(this.remoteState),
      schemaResponses: this.schemaResponseCount,
      unknownRequests: this.unknownRequestCount
    };
  }

  private requiredTemplate(name: string): RegistrationTemplateDefinition {
    const template = this.templates.get(name);
    if (template === undefined) {
      throw new Error(`Missing registration template: ${name}`);
    }
    return template;
  }
}

export function encodeRegistrationMessage(template: RegistrationTemplateDefinition, sequence: number,
  outerSequence: number, payload?: Uint8Array): Uint8Array {
  let frame = encodeDumlFrame(template.sender, template.receiver, sequence, template.flags,
    template.commandSet, template.commandId, payload === undefined ? fromHex(template.payloadHex) : payload);
  if (template.tunneled) {
    const outerBytes = new Uint8Array(2);
    writeU16LE(outerBytes, 0, outerSequence);
    const trailer = concatBytes(OBSERVED_TRAILER_PREFIX, outerBytes, TRAILER_SUFFIX);
    frame = encodeDumlFrame(0x3b, 0xe9, outerSequence, 0, 0x51, 1, concatBytes(frame, trailer));
  }
  return frame;
}

function channelAcknowledgement(payload: Uint8Array, template: Uint8Array): Uint8Array {
  if (payload.length < 9 || payload[0] !== 0 || payload[1] !== 2 || payload[2] !== 0 ||
    readU16LE(payload, 7) !== payload.length - 9) {
    throw new Error('Not a complete channel offer');
  }
  if (template.length < 13 || template[0] !== 0 || template[1] !== 0 || template[2] !== 0 ||
    template[3] !== 2 || template[4] !== 0 || readU16LE(template, 9) !== template.length - 11 ||
    (template.length - 11) % 2 !== 0) {
    throw new Error('Invalid local channel acknowledgement template');
  }
  const offered: Set<number> = new Set();
  let offset = 9;
  while (offset < payload.length) {
    if (offset + 2 > payload.length) {
      throw new Error('Truncated channel record');
    }
    const channel = payload[offset];
    const size = payload[offset + 1];
    if (size === 0 || offset + 2 + size > payload.length) {
      throw new Error('Invalid channel record length');
    }
    offered.add(channel);
    offset += 2 + size;
  }
  const accepted: number[] = [];
  for (let templateOffset = 11; templateOffset < template.length; templateOffset += 2) {
    const channel = readU16LE(template, templateOffset);
    if (channel !== 0 && offered.has(channel)) {
      accepted.push(channel);
    }
  }
  const body = new Uint8Array((accepted.length + 1) * 2);
  accepted.forEach((channel: number, index: number) => writeU16LE(body, index * 2, channel));
  const result = concatBytes(template.slice(0, 9), new Uint8Array(2), body);
  writeU16LE(result, 9, body.length);
  return result;
}

function identityAcknowledgement(payload: Uint8Array, template: Uint8Array): Uint8Array {
  if (payload.length !== 51 || template.length !== 24 || payload[0] !== 0 || payload[1] !== 0) {
    throw new Error('Identity request does not match this aircraft');
  }
  for (let index = 0; index < 23; index++) {
    if (payload[index] !== template[index]) {
      throw new Error('Identity request does not match this aircraft');
    }
  }
  return concatBytes(payload.slice(0, 23), new Uint8Array([0]));
}

function createTemplates(): Map<string, RegistrationTemplateDefinition> {
  const templates: Map<string, RegistrationTemplateDefinition> = new Map();
  templates.set('heartbeat', template(238, 233, 0, 81, 19, true,
    '0504020037303038454533442d353939372d343039372d00010101000000000000010000010101020000001ce42100000080a654000000'));
  templates.set('info_direct', template(238, 233, 64, 81, 52, false,
    '000402000037303038454533442d353939372d343039372d0000000000000000000000000000'));
  templates.set('register', template(2, 7, 64, 7, 147, false,
    '012b230037303038454533442d353939372d343039372d00'));
  templates.set('capabilities', template(238, 233, 64, 81, 65, true,
    '1001008e338dbb260006112000000000000000001f000100000000000a112000000000000000007d07000000000000'));
  templates.set('open', template(238, 233, 64, 81, 2, true, '0504040000000200020000'));
  templates.set('identity', template(238, 233, 64, 81, 6, true,
    '04020037303038454533442d353939372d343039372d00000024313538314641365143323542533031434a4747370000000000'));
  templates.set('info_tunnel', template(238, 233, 64, 81, 52, true,
    '000402000037303038454533442d353939372d343039372d0000000000000014000000000000'));
  templates.set('response_41:13:2001', template(238, 233, 192, 81, 65, true,
    '00200001008e338dbb260006112000000000000000001f000100000000000a112000000000000000007d07000000000000'));
  templates.set('response_41:65:0002', template(238, 233, 192, 81, 65, true,
    '00000002008e338dbb08000b0006000a000000'));
  templates.set('response_08:49:0000', template(238, 233, 192, 81, 8, true,
    '000024313538314641365143323542533031434a47473700'));
  templates.set('response_06:51:0000', template(238, 233, 192, 81, 6, true,
    '000024313538314641365143323542533031434a47473700'));
  templates.set('response_41:65:2101ab63daaa', template(238, 233, 192, 81, 65, true,
    '00000002008e338dbb08000b0006000a000000'));
  return templates;
}

function createResponseRules(): Map<string, string> {
  const rules: Map<string, string> = new Map();
  rules.set('41:b7ffb27be6444be05d4e765d9b56db4588476c1d50e4649e25150c3aac094888', 'response_41:13:2001');
  rules.set('41:5ee41e4d4b36019a20a63ef7b8f3c253d59b6f3a695a5ae2ba4334634698af20', 'response_41:65:0002');
  rules.set('08:4a3f8fc6de59228d1040df889a6e8dd8dbe76edbf31362b08c477520ca940622', 'response_08:49:0000');
  rules.set('06:d3d56114c0e8a19ca625dc586aebfee5d53d209adaf6166c438c00dfbd9beb10', 'response_06:51:0000');
  rules.set('41:2101ab63daaa66203fc61cc539448cdc6090803539126786f047cd355633cfda', 'response_41:65:2101ab63daaa');
  return rules;
}

function template(sender: number, receiver: number, flags: number, commandSet: number, commandId: number,
  tunneled: boolean, payloadHex: string): RegistrationTemplateDefinition {
  return {
    name: '',
    sender: sender,
    receiver: receiver,
    flags: flags,
    commandSet: commandSet,
    commandId: commandId,
    tunneled: tunneled,
    payloadHex: payloadHex
  };
}

const REQUIRED_TEMPLATES: string[] = ['heartbeat', 'info_direct', 'register', 'capabilities', 'open',
  'identity', 'info_tunnel', 'response_41:65:0002', 'response_06:51:0000'];

export function builtInRegistrationProfile(): RegistrationProfile {
  const templates = createTemplates();
  templates.forEach((value: RegistrationTemplateDefinition, name: string) => value.name = name);
  return {
    profileId: 'neo2-research-verified-v1',
    routingIdentity: '8e338dbb',
    templates: templates,
    responseRules: createResponseRules()
  };
}

export function parseRegistrationProfile(jsonText: string): RegistrationProfile {
  const document = JSON.parse(jsonText) as RegistrationProfileDocument;
  if (document.version !== 1 || !/^[A-Za-z0-9._-]{1,64}$/.test(document.profileId) ||
    !/^[0-9a-f]{8}$/.test(document.routingIdentity) || !Array.isArray(document.templates) ||
    !Array.isArray(document.responseRules)) {
    throw new Error('Invalid registration profile header');
  }
  const templates: Map<string, RegistrationTemplateDefinition> = new Map();
  document.templates.forEach((item: RegistrationTemplateDefinition) => {
    if (!/^[A-Za-z0-9_:\-]{1,80}$/.test(item.name) || templates.has(item.name) ||
      !isByte(item.sender) || !isByte(item.receiver) || !isByte(item.flags) ||
      !isByte(item.commandSet) || !isByte(item.commandId) ||
      typeof item.tunneled !== 'boolean' || !/^(?:[0-9a-f]{2})*$/.test(item.payloadHex)) {
      throw new Error('Invalid or duplicate registration template');
    }
    templates.set(item.name, item);
  });
  REQUIRED_TEMPLATES.forEach((name: string) => {
    if (!templates.has(name)) throw new Error(`Missing registration template: ${name}`);
  });
  const rules: Map<string, string> = new Map();
  document.responseRules.forEach((rule: RegistrationResponseRuleDefinition) => {
    if (!/^[0-9a-f]{2}:[0-9a-f]{64}$/.test(rule.key) || rules.has(rule.key) ||
      !templates.has(rule.template)) {
      throw new Error('Invalid registration response rule');
    }
    rules.set(rule.key, rule.template);
  });
  return { profileId: document.profileId, routingIdentity: document.routingIdentity,
    templates: templates, responseRules: rules };
}

function isByte(value: number): boolean {
  return Number.isInteger(value) && value >= 0 && value <= 0xff;
}
