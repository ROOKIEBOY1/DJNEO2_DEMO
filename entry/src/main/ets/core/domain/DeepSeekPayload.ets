import { AgentAction, AgentContext, AgentObservation, AgentResponse, validateAgentResponse } from './AgentAction';
import { SubjectBox } from './SubjectObservation';
import { AGENT_SYSTEM_PROMPT } from './AgentPrompt';

interface ImageUrl { url: string; }
interface ContentPart { type: string; text?: string; image_url?: ImageUrl; }
interface ChatMessage { role: string; content: string | ContentPart[]; }
interface Thinking { type: string; }
interface ResponseFormat { type: string; }
interface ChatBody { model: string; thinking: Thinking; max_tokens: number; response_format: ResponseFormat; messages: ChatMessage[]; }
interface ObservationText {
  description: string; context: AgentContext; candidates: SubjectBox[]; currentSubjectId?: number; hasImage: boolean;
}
interface ChoiceMessage { content?: string; }
interface ChatChoice { finish_reason?: string; message?: ChoiceMessage; }
interface ChatResponse { choices?: ChatChoice[]; }

const GROUND_DOLLY_INTENT: string = ' Phase ground_dolly_intent: The aircraft is grounded. If the user explicitly asks to SHOOT a Hitchcock/dolly zoom video or the fixed closeup video recipe, return dolly_zoom with requested framing/zoom/retreat and recipe only when the fixed closeup was requested; omit subjectId even when a person is described, because the App will take off, scan, and ask you again with a fresh image. For 特写镜头/特写视频 use recipe="dolly_circle", default framing=半身, zoom=3, retreat=true. This fixed recipe is supported; it is not an arbitrary multi-action sequence. Ordinary dolly/Hitchcock keeps recipe omitted. Do not return takeoff alone. Preserve the described person for the next stage through the original user text. Never activate this workflow for negated, hypothetical, quoted, question-only requests or settings/preparation-only changes. If 不要起飞 or 不要环绕 conflicts with this recipe, return none with a concise Chinese clarification, never start a component silently. For an unclear camera-movement request, return none asking the user to clarify the movement, rather than reporting missing visible candidates; visual choice for a dolly shoot happens after takeoff. For all other requests use the normal action rules.';
const SHOOT_INTENT: string = ' Phase shoot_intent: This is the initial airborne voice request, before subject scan preparation, with an optional ready image. For an explicit affirmative request to SHOOT a Hitchcock/希区柯克/滑动变焦 video or fixed closeup video, return dolly_zoom with the requested framing/zoom/retreat even without an image or visible candidates. Do not return none merely because the image, candidates or matching subject are not yet available. Ordinary Hitchcock/滑动变焦 keeps recipe omitted. Only an explicit 特写镜头/特写视频/拍一段特写 request adds recipe="dolly_circle", default framing=半身, zoom=3, retreat=true unless supported parameters were requested. A closeup photograph remains photo. With an image and a unique matching visible candidate, include its exact supplied subjectId so the App can reuse this visual decision. If a person is explicitly described but there is no image or no unique matching visible candidate, omit subjectId and retain the dolly parameters/recipe: the App will scan and resolve the described person with a fresh image, then ask for confirmation or clarification. Never guess a numbered ID or choose the first candidate. Without a specified person, retain currentSubjectId only if it is a supplied visible candidate; when no visible currentSubjectId exists and exactly one visible candidate is available, propose that ID for user confirmation. With no visible currentSubjectId, multiple candidates and no specified person or other unique visual description, return none asking for clarification. With no usable image or no candidates, omit subjectId and let the App scan before selecting. For relative requests exclude currentSubjectId and omit subjectId when there is no unique visible alternative. These deferred-selection rules apply only to dolly shooting. Never activate shooting for negated, hypothetical, quoted, question-only requests or settings/preparation-only changes; retain set_dolly and prepare_dolly for those affirmative changes. If 不要起飞 or 不要环绕 conflicts with the requested fixed recipe, return none with a concise Chinese clarification. For an unclear movement return none asking which movement is requested. For all other requests use the normal action rules immediately; stop, record_stop and other independent actions do not wait for subject scanning.';
const DOLLY_SUBJECT: string = ' Phase dolly_subject: This is the airborne visual selection stage of an already authorized dolly shoot or fixed closeup recipe. Return only {"action":"dolly_zoom","subjectId":matchingVisibleId}, or none with a concise Chinese explanation if missing/ambiguous. Do not guess or choose the first candidate. A specified person must uniquely match the visible description; otherwise return none. Without a specified person, retain currentSubjectId only if it is a supplied visible candidate; when no visible currentSubjectId exists and exactly one visible candidate is available, propose that ID for user confirmation. With no visible currentSubjectId, multiple candidates and no specified person or other unique visual description, return none asking for clarification. For relative switches exclude currentSubjectId and return none if there is no unique visible alternative. Omit framing, zoom, retreat and recipe: the App retains the intent parameters and fixed recipe. Never return takeoff or any other action.';

export function makeDeepSeekBody(observation: AgentObservation, description: string, jpegDataUrl?: string): string {
  if (description.trim().length === 0 || description.length > 1000) throw new Error('语音描述为空或过长，请重新说');
  const frame = observation.frame;
  if (frame !== undefined && (jpegDataUrl === undefined || !jpegDataUrl.startsWith('data:image/jpeg;base64,') ||
    jpegDataUrl.length > 1500000)) throw new Error('云端画面无效或过大，请重新取帧');
  const context: ObservationText = { description: description, context: observation.context,
    candidates: frame?.candidates ?? [], currentSubjectId: frame?.currentSubjectId, hasImage: frame !== undefined };
  const content: ContentPart[] = [{ type: 'text', text: JSON.stringify(context) }];
  if (frame !== undefined && jpegDataUrl !== undefined) content.push({ type: 'image_url', image_url: { url: jpegDataUrl } });
  const body: ChatBody = { model: 'deepseek-flash', thinking: { type: 'disabled' }, max_tokens: 4096,
    response_format: { type: 'json_object' }, messages: [
      { role: 'system', content: AGENT_SYSTEM_PROMPT + (observation.purpose === 'ground_dolly_intent' ?
        GROUND_DOLLY_INTENT : observation.purpose === 'shoot_intent' ? SHOOT_INTENT :
          observation.purpose === 'dolly_subject' ? DOLLY_SUBJECT : '') }, { role: 'user', content: content }
    ] };
  return JSON.stringify(body);
}

export function parseDeepSeekResponse(text: string, observation: AgentObservation, now: number): AgentResponse {
  if (text.length > 65536) throw new Error('云端响应超过大小限制');
  let command: AgentAction;
  try {
    const parsed = JSON.parse(text) as ChatResponse;
    const choice = parsed.choices?.[0];
    const content = choice?.message?.content;
    if (choice?.finish_reason !== 'stop' || typeof content !== 'string' || content.length > 8192) {
      throw new Error('incomplete');
    }
    command = JSON.parse(content) as AgentAction;
  } catch (_) { throw new Error('云端未返回完整有效的动作，请重试'); }
  const response: AgentResponse = { version: 2, requestId: observation.requestId, command: command };
  validateAgentResponse(response, observation, observation.sessionId, observation.flightGeneration, now);
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
