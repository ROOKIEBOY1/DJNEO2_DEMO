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

export function makeDeepSeekBody(observation: AgentObservation, description: string, jpegDataUrl?: string): string {
  if (description.trim().length === 0 || description.length > 1000) throw new Error('语音描述为空或过长，请重新说');
  const frame = observation.frame;
  if (frame !== undefined && (jpegDataUrl === undefined || !jpegDataUrl.startsWith('data:image/jpeg;base64,') ||
    jpegDataUrl.length > 1500000)) throw new Error('云端画面无效或过大，请重新取帧');
  const context: ObservationText = { description: description, context: observation.context,
    candidates: frame?.candidates ?? [], currentSubjectId: frame?.currentSubjectId, hasImage: frame !== undefined };
  const content: ContentPart[] = [{ type: 'text', text: JSON.stringify(context) }];
  if (frame !== undefined && jpegDataUrl !== undefined) content.push({ type: 'image_url', image_url: { url: jpegDataUrl } });
  const body: ChatBody = { model: 'deepseek-flash', thinking: { type: 'disabled' }, max_tokens: 256,
    response_format: { type: 'json_object' }, messages: [
      { role: 'system', content: AGENT_SYSTEM_PROMPT }, { role: 'user', content: content }
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
  return response;
}
