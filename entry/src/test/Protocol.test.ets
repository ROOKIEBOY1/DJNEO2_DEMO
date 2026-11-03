import { describe, expect, it } from '@ohos/hypium';
import { fromHex, toHex } from '../main/ets/core/protocol/Bytes';
import { buildCircleSelectionFrame, buildCircleStartFrame, buildCircleStopFrame,
  buildRadiusFrame } from '../main/ets/core/protocol/CircleCodec';
import { buildFlyPacket, buildFlyTunnel } from '../main/ets/core/protocol/CommandCodec';
import { encodeDumlFrame } from '../main/ets/core/protocol/DumlCodec';
import { buildHandshake } from '../main/ets/core/protocol/HandshakeCodec';
import { parseOuterPacket } from '../main/ets/core/protocol/OuterCodec';
import { buildStickPayload, INITIAL_PAYLOAD } from '../main/ets/core/protocol/StickCodec';
import { sha256Hex } from '../main/ets/core/protocol/Sha256';
import { ReliableTransport, sequenceReached } from '../main/ets/core/transport/ReliableTransport';
import { VideoAssembler } from '../main/ets/core/media/VideoAssembler';
import { parseVoiceCommand, VoiceCommandAdapter } from '../main/ets/core/domain/VoiceCommandAdapter';
import { builtInRegistrationProfile, parseRegistrationProfile } from
  '../main/ets/core/transport/RegistrationExchange';

interface StickVector {
  name: string;
  channels: number[];
  expected: string;
}

function assertHex(actual: Uint8Array, expected: string): void {
  expect(toHex(actual)).assertEqual(expected);
}

export default function protocolTest(): void {
  describe('Neo protocol golden vectors', () => {
    it('encodes handshake', 0, () => {
      assertHex(buildHandshake(60383, 24312),
        '3080dfeb00000084f85e64006400c005140000640000019001c005140000640014006400c00514000064000101040102');
    });

    it('encodes flight command frames', 0, () => {
      assertHex(encodeDumlFrame(2, 3, 38783, 64, 3, 42, fromHex('01')),
        '550e046602037f9740032a01dd32');
      assertHex(encodeDumlFrame(2, 3, 38784, 64, 3, 42, fromHex('02')),
        '550e04660203809740032a026cfd');
      assertHex(buildFlyTunnel(1, 38783, 22089),
        '553104533be94956005101550e046602037f9740032a01dd328e338dbb0249560000ffffffff018200000000000000aeb9');
      assertHex(buildFlyPacket(60383, 24312, 46496, 24312, 51327, 49574, 1),
        '5380dfeb000004e3a0b5a0b500000000f85ef85e00000000f85ef85e000000003100553104533be97fc8005101550e04660203a6c140032a01971c8e338dbb027fc80000ffffffff018200000000000000d502');
    });

    it('encodes all stick vectors without wide integer shifts', 0, () => {
      const vectors: StickVector[] = [
        { name: 'neutral', channels: [1024, 1024, 1024, 1024], expected: '010d0000042000010840000200000655010456083322110000000000' },
        { name: 'forward', channels: [1024, 1359, 1024, 1024], expected: '010d00007c2a00010840000200000655010456083322110000000000' },
        { name: 'backward', channels: [1024, 689, 1024, 1024], expected: '010d00008c1500010840000200000655010456083322110000000000' },
        { name: 'up', channels: [1024, 1024, 1359, 1024], expected: '010d000004e053010840000200000655010456083322110000000000' },
        { name: 'down', channels: [1024, 1024, 689, 1024], expected: '010d00000460ac000840000200000655010456083322110000000000' },
        { name: 'left', channels: [689, 1024, 1024, 1024], expected: '010d00b1022000010840000200000655010456083322110000000000' },
        { name: 'right', channels: [1359, 1024, 1024, 1024], expected: '010d004f052000010840000200000655010456083322110000000000' },
        { name: 'turnLeft', channels: [1024, 1024, 1024, 689], expected: '010d0000042000630540000200000655010456083322110000000000' },
        { name: 'turnRight', channels: [1024, 1024, 1024, 1359], expected: '010d00000420009f0a40000200000655010456083322110000000000' }
      ];
      vectors.forEach((vector: StickVector) => {
        const value = buildStickPayload(vector.channels[0], vector.channels[1], vector.channels[2],
          vector.channels[3], 1122867);
        expect(toHex(value)).assertEqual(vector.expected);
      });
    });

    it('encodes the short initial 010a frame from the capture', 0, () => {
      // initial_010a test vector: session 0x4a8c, seed 0x5460, sequence 0xbbb5
      assertHex(encodeDumlFrame(2, 0xa9, 0xbbb5, 0, 1, 0x0a, INITIAL_PAYLOAD),
        '551f044e02a9b5bb00010a010d000004200001084000020000065501049208');
    });

    it('encodes circle commands', 0, () => {
      assertHex(buildCircleSelectionFrame(1), '551504a9021701004003f9878867a305000000806a');
      assertHex(buildRadiusFrame(2, 2), '551504a9029202004003f946932703000000405b47');
      assertHex(buildRadiusFrame(5, 3), '551504a9029203004003f9469327030000a04009ed');
      assertHex(buildCircleStartFrame(4), '55100456029204004023130105009402');
      assertHex(buildCircleStopFrame(5), '550d04330292050040231548d2');
    });

    it('rejects a corrupt outer packet', 0, () => {
      const packet = buildHandshake(60383, 24312);
      packet[7] ^= 1;
      let rejected = false;
      try {
        parseOuterPacket(packet);
      } catch (_) {
        rejected = true;
      }
      expect(rejected).assertTrue();
    });

    it('computes registration SHA-256 keys', 0, () => {
      assertHex(fromHex(sha256Hex(fromHex('616263'))),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
    });
  });

  describe('Reliable transport', () => {
    it('handles sequence wraparound', 0, () => {
      expect(sequenceReached(0x0000, 0xfff8)).assertTrue();
      expect(sequenceReached(0xfff8, 0x0000)).assertFalse();
    });

    it('retransmits the exact original bytes', 0, () => {
      const transport = new ReliableTransport(2, 0xfff8);
      const original = transport.encode(fromHex('550d04330292050040231548d2'), 0);
      const retry = transport.retries(151)[0];
      expect(toHex(retry)).assertEqual(toHex(original));
      expect(transport.snapshot().retransmitted).assertEqual(1);
    });
  });

  describe('Aircraft registration profiles', () => {
    it('keeps the verified built-in routing identity explicit', 0, () => {
      const profile = builtInRegistrationProfile();
      expect(profile.profileId).assertEqual('neo2-research-verified-v1');
      expect(profile.routingIdentity).assertEqual('8e338dbb');
      expect(profile.templates.has('heartbeat')).assertTrue();
    });

    it('rejects incomplete imported registration profiles', 0, () => {
      let rejected = false;
      try {
        parseRegistrationProfile(JSON.stringify({ version: 1, profileId: 'other-neo',
          routingIdentity: '8e338dbb', templates: [], responseRules: [] }));
      } catch (_) {
        rejected = true;
      }
      expect(rejected).assertTrue();
    });
  });

  describe('Video assembler', () => {
    it('joins a complete two-part frame', 0, () => {
      const assembler = new VideoAssembler();
      const first = videoPacket(2, 7, 2, 0, fromHex('0102'));
      const second = videoPacket(2, 7, 2, 1, fromHex('0304'));
      expect(assembler.feed(first, 0)).assertUndefined();
      assertHex(assembler.feed(second, 1) as Uint8Array, '01020304');
    });

    it('drops conflicting duplicate fragments', 0, () => {
      const assembler = new VideoAssembler();
      assembler.feed(videoPacket(2, 7, 2, 0, fromHex('01')), 0);
      assembler.feed(videoPacket(2, 7, 2, 0, fromHex('02')), 1);
      expect(assembler.snapshot().droppedFrames).assertEqual(1);
    });
  });

  describe('Safe local command parsing', () => {
    it('only accepts the bounded movement vocabulary', 0, () => {
      expect(parseVoiceCommand('前进')?.direction).assertEqual('forward');
      expect(parseVoiceCommand('左转')?.direction).assertEqual('turn_left');
      expect(parseVoiceCommand('飞到窗外')).assertUndefined();
    });

    it('requires a second confirmation event for takeoff', 0, () => {
      const adapter = new VoiceCommandAdapter();
      adapter.setEnabled(true);
      let executed = '';
      adapter.setListener(command => executed = command.kind);
      expect(adapter.acceptTranscript('起飞')).assertUndefined();
      expect(executed).assertEqual('');
      expect(adapter.snapshot().pendingConfirmation).assertEqual('takeoff');
      adapter.confirmPending();
      expect(executed).assertEqual('takeoff');
    });

    it('keeps landing immediate when voice entry is enabled', 0, () => {
      const adapter = new VoiceCommandAdapter();
      adapter.setEnabled(true);
      let executed = '';
      adapter.setListener(command => executed = command.kind);
      adapter.acceptTranscript('立即降落');
      expect(executed).assertEqual('land');
    });
  });
}

function videoPacket(session: number, frame: number, count: number, part: number,
  data: Uint8Array): Uint8Array {
  const raw = new Uint8Array(20 + data.length);
  const length = 0x8000 | raw.length;
  raw[0] = length & 0xff;
  raw[1] = length >>> 8;
  raw[2] = session & 0xff;
  raw[3] = session >>> 8;
  raw[6] = 2;
  for (let index = 0; index < 7; index++) {
    raw[7] ^= raw[index];
  }
  raw[16] = frame;
  raw[17] = count | ((part & 1) << 7);
  raw[18] = part >>> 1;
  raw.set(data, 20);
  return raw;
}
