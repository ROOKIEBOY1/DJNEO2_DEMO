import { AgentAction, AgentContext, AgentObservation, AgentResponse, agentObservationTimeoutMs, validateAgentResponse } from './AgentAction';
import { SubjectBox } from './SubjectObservation';
import { AGENT_SYSTEM_PROMPT } from './AgentPrompt';
import { isSelfSubjectRequest, needsSelfReference } from './SelfReference';

interface ImageUrl { url: string; }
interface ContentPart { type: string; text?: string; image_url?: ImageUrl; }
interface ChatMessage { role: string; content: string | ContentPart[]; }
interface Thinking { type: string; }
interface ResponseFormat { type: string; }
interface ChatBody { model: string; thinking: Thinking; max_tokens: number; response_format: ResponseFormat; messages: ChatMessage[]; }
interface ObservationText {
  description: string; context: AgentContext; candidates: SubjectBox[]; currentSubjectId?: number; hasImage: boolean;
  selfReference?: SelfReferenceText;
}
interface SelfReferenceText { referenceImage: string; currentImage: string; target: string; }
interface ChoiceMessage { content?: string; }
interface ChatChoice { finish_reason?: string; message?: ChoiceMessage; }
interface ChatResponse { choices?: ChatChoice[]; }

const GROUND_DOLLY_INTENT: string = ' Phase ground_dolly_intent: The aircraft is grounded. If the user explicitly asks to SHOOT a Hitchcock/dolly zoom video or the fixed closeup video recipe, return dolly_zoom with requested framing/zoom/retreat and recipe only when the fixed closeup was requested; omit subjectId even when a person is described, because the App will take off, scan, and ask you again with a fresh image. For 特写镜头/特写视频 use recipe="dolly_circle", default framing=半身, zoom=3, retreat=true. This fixed recipe is supported; it is not an arbitrary multi-action sequence. Ordinary dolly/Hitchcock keeps recipe omitted. Do not return takeoff alone. Preserve the described person for the next stage through the original user text. Never activate this workflow for negated, hypothetical, quoted, question-only requests or settings/preparation-only changes. If 不要起飞 or 不要环绕 conflicts with this recipe, return none with a concise Chinese clarification, never start a component silently. For an unclear camera-movement request, return none asking the user to clarify the movement, rather than reporting missing visible candidates; visual choice for a dolly shoot happens after takeoff. Explicit affirmative 跟随/跟拍 means follow and 主体环绕 means circle, retaining requested radiusMeters, even without an image or candidates; omit subjectId and let the App take off, scan, select and ask for user confirmation. These are subject flight tasks, not takeoff alone. For specifically requested subject photos return photo; for selecting/locking/switching return select_subject. For photo/select_subject with no usable image or matching candidate return subjectRequired=true and omit subjectId, never invent an ID. photo and select_subject never authorize takeoff; when no scan conditions exist tell the user to take off to a stable hover first, rather than adding takeoff. A bare photo stays direct and omits subjectRequired. For recording a specifically requested subject return record_start with subjectRequired=true and omit subjectId until a unique supplied candidate is visible; then use its exact subjectId. record_start requests never authorize takeoff; when no scan conditions exist require a stable hover first. A bare record_start stays direct and omits subjectRequired. All deferred intentions preserve the original description for common visual selection. For all other requests use the normal action rules.';
const SHOOT_INTENT: string = ' Phase shoot_intent: This is the initial airborne voice request, before subject scan preparation, with an optional ready image. For an explicit affirmative request to SHOOT a Hitchcock/希区柯克/滑动变焦 video or fixed closeup video, return dolly_zoom with the requested framing/zoom/retreat even without an image or visible candidates. Do not return none merely because the image, candidates or matching subject are not yet available. Ordinary Hitchcock/滑动变焦 keeps recipe omitted. Only an explicit 特写镜头/特写视频/拍一段特写 request adds recipe="dolly_circle", default framing=半身, zoom=3, retreat=true unless supported parameters were requested. A closeup photograph remains photo. With an image and a unique matching visible candidate, include its exact supplied subjectId so the App can reuse this visual decision. If a person is explicitly described but there is no image or no unique matching visible candidate, omit subjectId and retain the dolly parameters/recipe: the App will scan and resolve the described person with a fresh image, then ask for confirmation or clarification. Never guess a numbered ID or choose the first candidate. Without a specified person, retain currentSubjectId only if it is a supplied visible candidate; when no visible currentSubjectId exists and exactly one visible candidate is available, propose that ID for user confirmation. With no visible currentSubjectId, multiple candidates and no specified person or other unique visual description, return none asking for clarification. With no usable image or no candidates, omit subjectId and let the App scan before selecting. Only for explicit relative requests asking for another person exclude currentSubjectId and omit subjectId when there is no unique visible alternative. These deferred-selection rules also apply to follow and circle: classify the requested task and retain its parameters even without an image or candidates, then let the App scan and confirm the target. For specifically requested subject photos use photo; selecting/locking/switching a person uses select_subject. For photo/select_subject without a unique supplied candidate use subjectRequired=true and omit subjectId; with a uniquely matching supplied visible candidate use its exact subjectId. A bare photo stays direct and omits subjectRequired. photo and select_subject never authorize takeoff; when no scan conditions exist tell the user to take off to a stable hover first. For recording a specifically requested subject return record_start with subjectRequired=true and omit subjectId until a unique supplied candidate is visible; then use its exact subjectId. record_start requests never authorize takeoff; when no scan conditions exist require a stable hover first. A bare record_start stays direct and omits subjectRequired. Every proposal, including current or sole candidates, still requires user confirmation. Never activate shooting for negated, hypothetical, quoted, question-only requests or settings/preparation-only changes; retain set_dolly and prepare_dolly for those affirmative changes. If 不要起飞 or 不要环绕 conflicts with the requested fixed recipe, return none with a concise Chinese clarification. For an unclear movement return none asking which movement is requested. For all other requests use the normal action rules immediately; stop, record_stop and other independent actions do not wait for subject scanning.';
const DOLLY_SUBJECT: string = ' Phase dolly_subject: This is the airborne visual selection stage of an already authorized dolly shoot or fixed closeup recipe. Return only {"action":"dolly_zoom","subjectId":matchingVisibleId}, or none with a concise Chinese explanation if missing/ambiguous. Do not guess or choose the first candidate. A specified person must uniquely match the visible description; otherwise return none. Without a specified person, retain currentSubjectId only if it is a supplied visible candidate; when no visible currentSubjectId exists and exactly one visible candidate is available, propose that ID for user confirmation. With no visible currentSubjectId, multiple candidates and no specified person or other unique visual description, return none asking for clarification. For relative switches exclude currentSubjectId and return none if there is no unique visible alternative. Omit framing, zoom, retreat and recipe: the App retains the intent parameters and fixed recipe. Never return takeoff or any other action.';

const SUBJECT_SELECTION: string = ' Phase subject_selection: This is only the common visual selection stage of an already authorized subject task. Return only {"action":"select_subject","subjectId":matchingVisibleId}, or {"action":"none","selectionStatus":"not_found","message":"当前候选中未找到目标"} when the target is clearly absent, or {"action":"none","selectionStatus":"ambiguous","message":"请明确要选择的主体"} when unclear. Use not_found only when the target is clearly absent from the current supplied candidates. For an uncertain description, multiple plausible matches or insufficient reference-photo appearance evidence, use ambiguous; never treat uncertainty as absence. When no person is specified and there are no candidates, use not_found; when multiple candidates cannot be distinguished, use ambiguous. Use only the real supplied image candidates; never invent an ID, choose the first candidate or infer identity from an earlier frame. Never change the authorized action or parameters. Do not emit framing, zoom, retreat, recipe, radiusMeters or subjectRequired, or add a task, recipe or takeoff. The App retains the original action and all frozen parameters. A specified person must uniquely match the visible description; otherwise return none. Without a specified person, retain currentSubjectId only if it is a supplied visible candidate; when no visible currentSubjectId exists and exactly one visible candidate is available, propose that ID for user confirmation. With no visible currentSubjectId, multiple candidates and no specified person or other unique visual description, return none asking for clarification. Only for explicit relative switches asking for another person exclude currentSubjectId and return none if there is no unique visible alternative. An explicitly described person may already be the current subject; keep that ID when it uniquely matches. Every proposal, including a current or sole candidate, requires user confirmation. Never act on a negated, hypothetical, quoted or question-only selection request.';
const SUBJECT_SELECTOR_ROLE: string = 'You are a visual subject selector. Treat the original utterance in description as visual target data only; never use it to plan or execute the requested task. The task and all its parameters are already frozen by the App. Return one JSON object with only action and subjectId for a selection, or action, selectionStatus and an optional concise Chinese message for none. Candidate IDs are drawn above the green boxes; use only the supplied current-image candidates. For example, if supplied candidate 13 is the unique match, return {"action":"select_subject","subjectId":13}; if the target is unclear, return {"action":"none","selectionStatus":"ambiguous","message":"请明确要选择的主体"}. Example IDs never replace the actual supplied candidates.';
const SUBJECT_SELECTION_RETRY: string = ' Selection protocol retry: Return only {"action":"select_subject","subjectId":matchingVisibleId}, {"action":"none","selectionStatus":"not_found","message":"当前候选中未找到目标"} or {"action":"none","selectionStatus":"ambiguous","message":"请明确目标"}. Use not_found only when the target is clearly absent; uncertain descriptions, multiple plausible matches and insufficient reference-photo evidence require ambiguous. Select only supplied current-image candidate IDs. Do not return the original task, parameters, arrays or extra fields.';

const SELF_REFERENCE_SELECTION: string = ' Self reference override: The user supplied the reference photo for the first-person target 我. This override replaces the ordinary subject-selection fallback rules. Compare its visible appearance against the current image, and return only {"action":"select_subject","subjectId":matchingVisibleId} for a unique clear match. If the match is uncertain, absent or ambiguous, return none with a concise Chinese explanation and selectionStatus. For insufficient appearance evidence or an uncertain match use ambiguous, even if no candidate can be confidently matched. Use not_found only when the reference target is clearly absent from the current candidates; lack of a reliable identity match alone is not evidence of absence. Never use currentSubjectId, a sole candidate or the first candidate as a fallback. Use only the current image supplied candidate IDs; never take an ID or number from the reference photo, invent a candidate or reuse an earlier frame. The reference photo is not the current scene. Preserve the authorized task and frozen parameters and require user confirmation. Do not claim reliable identity from a photo.';
const SELF_REFERENCE_INITIAL: string = ' Self reference initial intent: The first-person target 我 has a reference photo available later in subject_selection. For an affirmative request, classify the original requested task and retain its parameters, but omit subjectId even if candidates are currently visible. Never use currentSubjectId, a sole candidate or the first candidate to resolve this reference target at this stage. Never return none merely because of a missing or unavailable reference photo, current image or uniquely matching candidate at this initial stage; the App will scan and resolve the target with the reference later. For subject photo, record_start and select_subject use subjectRequired=true and omit subjectId. photo, select_subject and record_start never authorize takeoff; preserve the existing stable-hover requirement. Preserve normal negation, hypothetical, quoted, question-only and conflicting-request rules and all user confirmation requirements.' +
  ' subjectRequired must never be emitted for follow, circle or dolly_zoom; it is reserved for photo, record_start and select_subject. Valid initial examples: 跟随我 => {"action":"follow"}; 围着我两米环绕 => {"action":"circle","radiusMeters":2}; 给我拍个三倍半身希区柯克 => {"action":"dolly_zoom","zoom":3,"framing":"半身"}; 拍我 => {"action":"photo","subjectRequired":true}.';

const REFERENCE_JPEG_PREFIX: string = 'data:image/jpeg;base64,';
const BASE64_ALPHABET: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

function base64Byte(encoded: string, byteIndex: number): number {
  const bit = byteIndex * 8;
  const index = Math.floor(bit / 6);
  const pair = (BASE64_ALPHABET.indexOf(encoded.charAt(index)) << 6) |
    BASE64_ALPHABET.indexOf(encoded.charAt(index + 1));
  return (pair >> (4 - bit % 6)) & 255;
}

function isValidReferenceJpeg(value?: string): boolean {
  if (value === undefined || !value.startsWith(REFERENCE_JPEG_PREFIX) || value.length > 1000023) return false;
  const encoded = value.substring(REFERENCE_JPEG_PREFIX.length);
  if (encoded.length < 8 || encoded.length % 4 !== 0 || !/^[A-Za-z0-9+/]+={0,2}$/.test(encoded)) return false;
  const padding = encoded.endsWith('==') ? 2 : encoded.endsWith('=') ? 1 : 0;
  if ((padding === 2 && BASE64_ALPHABET.indexOf(encoded.charAt(encoded.length - 3)) % 16 !== 0) ||
    (padding === 1 && BASE64_ALPHABET.indexOf(encoded.charAt(encoded.length - 2)) % 4 !== 0)) return false;
  const bytes = encoded.length / 4 * 3 - padding;
  return bytes >= 4 && bytes <= 750000 && base64Byte(encoded, 0) === 255 &&
    base64Byte(encoded, 1) === 216 && base64Byte(encoded, 2) === 255 &&
    base64Byte(encoded, bytes - 2) === 255 && base64Byte(encoded, bytes - 1) === 217;
}

export function makeDeepSeekBody(observation: AgentObservation, description: string, jpegDataUrl?: string,
  referenceJpegDataUrl?: string, selectionRetry: boolean = false): string {
  if (description.trim().length === 0 || description.length > 1000) throw new Error('语音描述为空或过长，请重新说');
  const frame = observation.frame;
  const selfSubject = isSelfSubjectRequest(description);
  if (observation.purpose === 'subject_selection' && selfSubject && frame === undefined) {
    throw new Error('参考照片选人需要当前画面，请重新取帧');
  }
  if (frame !== undefined && (jpegDataUrl === undefined || !jpegDataUrl.startsWith('data:image/jpeg;base64,') ||
    jpegDataUrl.length > 1500000)) throw new Error('云端画面无效或过大，请重新取帧');
  const useReference = needsSelfReference(observation, description);
  if (useReference && !isValidReferenceJpeg(referenceJpegDataUrl)) {
    throw new Error('参考照片缺失、无效或过大，请检查参考照片');
  }
  const context: ObservationText = { description: description, context: observation.context,
    candidates: frame?.candidates ?? [], currentSubjectId: frame?.currentSubjectId, hasImage: frame !== undefined };
  if (useReference) context.selfReference = { referenceImage: 'reference_photo', currentImage: 'current_image', target: '我' };
  const content: ContentPart[] = [{ type: 'text', text: JSON.stringify(context) }];
  if (useReference && referenceJpegDataUrl !== undefined) {
    content.push({ type: 'text', text: 'Reference photo: appearance reference for the requested first-person target; not the current scene.' });
    content.push({ type: 'image_url', image_url: { url: referenceJpegDataUrl } });
    content.push({ type: 'text', text: 'Current image: fresh marked camera frame; only its supplied candidate IDs may be selected.' });
  }
  if (frame !== undefined && jpegDataUrl !== undefined) content.push({ type: 'image_url', image_url: { url: jpegDataUrl } });
  const selfPrompt = useReference ? SELF_REFERENCE_SELECTION : selfSubject &&
    (observation.purpose === 'shoot_intent' || observation.purpose === 'ground_dolly_intent') ? SELF_REFERENCE_INITIAL : '';
  const systemPrompt = observation.purpose === 'subject_selection' ? SUBJECT_SELECTOR_ROLE + SUBJECT_SELECTION :
    AGENT_SYSTEM_PROMPT + (observation.purpose === 'ground_dolly_intent' ? GROUND_DOLLY_INTENT :
      observation.purpose === 'shoot_intent' ? SHOOT_INTENT : observation.purpose === 'dolly_subject' ? DOLLY_SUBJECT : '');
  const retryPrompt = observation.purpose === 'subject_selection' && selectionRetry ? SUBJECT_SELECTION_RETRY : '';
  const body: ChatBody = { model: 'deepseek-flash', thinking: { type: 'disabled' }, max_tokens: 4096,
    response_format: { type: 'json_object' }, messages: [
      { role: 'system', content: systemPrompt + selfPrompt + retryPrompt }, { role: 'user', content: content }
    ] };
  return JSON.stringify(body);
}

const KNOWN_ACTION_LABELS: string[] = ['select_subject', 'cancel_subject', 'set_dolly', 'prepare_dolly', 'dolly_zoom',
  'circle', 'follow', 'photo', 'record_start', 'record_stop', 'download_photo', 'download_video', 'move', 'move_sequence', 'stop',
  'takeoff', 'land', 'none'];

export class SubjectSelectionProtocolError extends Error {
  readonly action: string;

  constructor(message: string, action: string) {
    super(message);
    this.name = 'SubjectSelectionProtocolError';
    this.action = KNOWN_ACTION_LABELS.includes(action) || ['missing', 'unknown', 'invalid_json'].includes(action) ?
      action : 'unknown';
  }
}

function selectionActionLabel(command: AgentAction): string {
  if (command === null || typeof command !== 'object' || Array.isArray(command)) return 'missing';
  if (command.action === undefined || command.action === null) return 'missing';
  return KNOWN_ACTION_LABELS.includes(command.action) ? command.action : 'unknown';
}

function responseProtocolError(observation: AgentObservation, message: string, action: string): Error {
  return observation.purpose === 'subject_selection' ? new SubjectSelectionProtocolError(message, action) : new Error(message);
}

export function parseDeepSeekResponse(text: string, observation: AgentObservation, now: number): AgentResponse {
  const selection = observation.purpose === 'subject_selection';
  const age = now - observation.requestedAtMs;
  if (selection && (age < 0 || age > agentObservationTimeoutMs(observation))) {
    throw new Error('动作响应已过期或飞机会话发生变化');
  }
  if (text.length > 65536) throw responseProtocolError(observation, '云端响应超过大小限制', 'invalid_json');
  let command: AgentAction;
  try {
    const parsed = JSON.parse(text) as ChatResponse;
    const choice = parsed.choices?.[0];
    const content = choice?.message?.content;
    if (choice?.finish_reason !== 'stop' || typeof content !== 'string' || content.length > 8192) {
      throw new Error('incomplete');
    }
    command = JSON.parse(content) as AgentAction;
  } catch (_) { throw responseProtocolError(observation, '云端未返回完整有效的动作，请重试', 'invalid_json'); }
  const response: AgentResponse = { version: 2, requestId: observation.requestId, command: command };
  try {
    validateAgentResponse(response, observation, observation.sessionId, observation.flightGeneration, now);
  } catch (error) {
    if (selection) throw new SubjectSelectionProtocolError((error as Error).message, selectionActionLabel(command));
    throw error as Error;
  }
  if (observation.purpose === 'ground_dolly_intent' && command.action === 'dolly_zoom' && command.subjectId !== undefined) {
    throw new Error('地面拍摄意图不能指定尚未扫描的主体编号');
  }
  if (observation.purpose === 'dolly_subject' && (command.action !== 'none' &&
    (command.action !== 'dolly_zoom' || command.subjectId === undefined))) {
    throw new Error('选人阶段未返回明确的滑动变焦目标');
  }
  if (observation.purpose === 'dolly_subject' && (command.recipe !== undefined || command.framing !== undefined ||
    command.zoom !== undefined || command.retreat !== undefined)) {
    throw new Error('选人阶段不能修改已确认的拍摄参数或组合');
  }
  return response;
}
