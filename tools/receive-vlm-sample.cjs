const net = require('node:net');
const fs = require('node:fs');
const path = require('node:path');
const { performance } = require('node:perf_hooks');
const { selectWithDeepSeek, planWithDeepSeek } = require('./deepseek-selection.cjs');

const root = path.resolve(__dirname, '../diagnostics/vlm-samples');
const apiKey = process.env.DEEPSEEK_API_KEY?.trim();
if (apiKey && typeof fetch !== 'function') {
  throw new Error('DeepSeek mode requires Node.js 18 or later');
}

function sendAgentResponse(socket, requestId, command, error) {
  const payload = Buffer.from(JSON.stringify({ version: 2, requestId, command, error }));
  const header = Buffer.alloc(4);
  header.writeUInt32LE(payload.length);
  socket.end(Buffer.concat([header, payload]));
}

async function replyFromDeepSeek(socket, directory, metadata, jpeg) {
  const controller = new AbortController();
  const started = performance.now();
  const timer = setTimeout(() => controller.abort(), 12000);
  socket.setTimeout(0);
  socket.once('close', () => controller.abort());
  try {
    if (metadata.protocolVersion === 2) {
      const command = await planWithDeepSeek(apiKey, metadata, jpeg, controller.signal);
      if (socket.destroyed || controller.signal.aborted) return;
      sendAgentResponse(socket, metadata.requestId, command);
      console.log(JSON.stringify({ directory, requestId: metadata.requestId, command, provider: 'deepseek',
        inferenceMs: Math.round(performance.now() - started) }));
      return;
    }
    const id = await selectWithDeepSeek(apiKey, metadata, jpeg, controller.signal);
    if (socket.destroyed || controller.signal.aborted) return;
    socket.end(id === null ? Buffer.from([0, 0]) : Buffer.from([1, id]));
    console.log(JSON.stringify({ directory, selectedId: id, provider: 'deepseek',
      inferenceMs: Math.round(performance.now() - started) }));
  } catch (error) {
    console.error(controller.signal.aborted ? 'DeepSeek inference timed out or the socket closed' : error.message);
    if (!socket.destroyed) {
      if (metadata.protocolVersion === 2) sendAgentResponse(socket, metadata.requestId, undefined, 'INFERENCE_FAILED');
      else socket.end(Buffer.from([2, 0]));
    }
  } finally {
    clearTimeout(timer);
  }
}

// The active Codex conversation writes a decision beside this specific sample.
// A missing or malformed decision never selects a candidate.
function waitForSelection(socket, directory, candidates) {
  const decisionPath = path.join(directory, 'selection.json');
  const deadline = performance.now() + 19500;
  socket.setTimeout(0);
  const timer = setInterval(() => {
    if (performance.now() >= deadline) {
      socket.destroy();
      return;
    }
    if (!fs.existsSync(decisionPath)) return;
    try {
      const { id } = JSON.parse(fs.readFileSync(decisionPath, 'utf8'));
      if (id === null) {
        socket.end(Buffer.from([0, 0]));
      } else if (Number.isInteger(id) && id >= 0 && id <= 255 && candidates.some(candidate => candidate.id === id)) {
        socket.end(Buffer.from([1, id]));
      } else {
        throw new Error('Selection is outside the submitted candidates');
      }
      clearInterval(timer);
      console.log(JSON.stringify({ directory, selectedId: id }));
    } catch (error) {
      clearInterval(timer);
      console.error(error.message);
      socket.end(Buffer.from([2, 0]));
    }
  }, 40);
  socket.once('close', () => clearInterval(timer));
}

const server = net.createServer(socket => {
  let started;
  let length = 0;
  let expected;
  let chunks = [];
  socket.setTimeout(2000, () => socket.destroy());
  socket.on('error', error => console.error(error.message));
  socket.on('data', chunk => {
    started ??= performance.now();
    length += chunk.length;
    if (length > 1048584) return socket.destroy();
    chunks.push(chunk);
    if (expected === undefined && length >= 8) {
      const header = Buffer.concat(chunks, length);
      const metaSize = header.readUInt32LE(0);
      const imageSize = header.readUInt32LE(4);
      if (metaSize < 2 || metaSize > 16384 || (imageSize !== 0 && imageSize < 4) || imageSize > 1032192) return socket.destroy();
      expected = 8 + metaSize + imageSize;
    }
    if (expected === undefined || length < expected) return;
    if (length !== expected) return socket.destroy();
    socket.pause();
    try {
      const payload = Buffer.concat(chunks, length);
      chunks = [];
      const offset = 8 + payload.readUInt32LE(0);
      const metadata = JSON.parse(payload.toString('utf8', 8, offset));
      const jpeg = payload.subarray(offset);
      const validImage = jpeg.length >= 4 && jpeg.readUInt16BE(0) === 0xffd8 &&
        jpeg.readUInt16BE(jpeg.length - 2) === 0xffd9;
      if (!Array.isArray(metadata.candidates) || !Number.isFinite(metadata.captureMs) ||
          (!validImage && !(metadata.protocolVersion === 2 && jpeg.length === 0)) ||
          (metadata.protocolVersion === 2 && (typeof metadata.requestId !== 'string' ||
            metadata.requestId.length > 128 || typeof metadata.context !== 'object' || !metadata.context))) {
        throw new Error('Invalid sample metadata or JPEG');
      }
      const receiveMs = Math.round(performance.now() - started);
      fs.mkdirSync(root, { recursive: true });
      const directory = fs.mkdtempSync(path.join(root, 'sample-'));
      if (jpeg.length > 0) fs.writeFileSync(path.join(directory, 'frame.jpg'), jpeg);
      fs.writeFileSync(path.join(directory, 'metadata.json'), JSON.stringify({ ...metadata, receiveMs }, null, 2));
      console.log(JSON.stringify({ directory, captureMs: metadata.captureMs, receiveMs,
        candidates: metadata.candidates.map(candidate => candidate.id), jpegBytes: jpeg.length,
        selectionPrompt: metadata.selectionPrompt }));
      if (typeof metadata.selectionPrompt === 'string' && metadata.selectionPrompt.trim().length > 0) {
        if (apiKey) void replyFromDeepSeek(socket, directory, metadata, jpeg);
        else if (metadata.protocolVersion === 2) sendAgentResponse(socket, metadata.requestId, undefined, 'API_KEY_REQUIRED');
        else waitForSelection(socket, directory, metadata.candidates);
      } else {
        socket.end(Buffer.from([6]));
      }
    } catch (error) {
      console.error(error.message);
      socket.destroy();
    }
  });
});
server.on('error', error => { console.error(error.message); process.exitCode = 1; });
server.listen(18732, '127.0.0.1', () => console.log(
  `Listening on 127.0.0.1:18732 (${apiKey ? 'DeepSeek' : 'manual'} selection)`));
