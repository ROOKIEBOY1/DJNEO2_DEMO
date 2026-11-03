import { connection, socket } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DRONE_IP, DRONE_PORT } from '../protocol/HandshakeCodec';

const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'NeoUdp';

export interface DroneWifiSelection {
  handle: connection.NetHandle;
  localAddress: string;
  interfaceName: string;
}

export type DatagramHandler = (packet: Uint8Array, receivedAtMs: number) => void;
export type ChannelErrorHandler = (message: string) => void;

export class DroneNetworkSelector {
  static async find(): Promise<DroneWifiSelection> {
    const handles = await connection.getAllNets();
    for (let index = 0; index < handles.length; index++) {
      const handle = handles[index];
      const capabilities = await connection.getNetCapabilities(handle);
      if (!capabilities.bearerTypes.includes(connection.NetBearType.BEARER_WIFI)) {
        continue;
      }
      const properties = await connection.getConnectionProperties(handle);
      for (let addressIndex = 0; addressIndex < properties.linkAddresses.length; addressIndex++) {
        const address = properties.linkAddresses[addressIndex].address.address;
        if (isDroneLocalAddress(address)) {
          return { handle: handle, localAddress: address, interfaceName: properties.interfaceName };
        }
      }
    }
    throw new Error('No connected Wi-Fi interface has a 192.168.2.x aircraft address');
  }
}

export class DroneUdpChannel {
  private udp?: socket.UDPSocket;
  private readonly remoteAddress: socket.NetAddress = {
    address: DRONE_IP,
    family: 1,
    port: DRONE_PORT
  };
  private packetHandler?: DatagramHandler;
  private errorHandler?: ChannelErrorHandler;
  private receivedDatagrams: number = 0;
  private sentDatagrams: number = 0;
  private lastPeerValue: string = '--';

  async open(selection: DroneWifiSelection, onPacket: DatagramHandler,
    onError: ChannelErrorHandler): Promise<void> {
    if (this.udp !== undefined) {
      throw new Error('UDP channel is already open');
    }
    const udp = socket.constructUDPSocketInstance();
    this.receivedDatagrams = 0;
    this.sentDatagrams = 0;
    this.lastPeerValue = '--';
    this.udp = udp;
    this.packetHandler = onPacket;
    this.errorHandler = onError;
    hilog.info(LOG_DOMAIN, LOG_TAG,
      'open local=%{public}s interface=%{public}s remote=%{public}s:%{public}d',
      selection.localAddress, selection.interfaceName, DRONE_IP, DRONE_PORT);
    udp.on('message', (info: socket.SocketMessageInfo) => {
      this.receivedDatagrams++;
      this.lastPeerValue = `${info.remoteInfo.address}:${info.remoteInfo.port}`;
      hilog.info(LOG_DOMAIN, LOG_TAG,
        'message remote=%{public}s:%{public}d length=%{public}d received=%{public}d',
        info.remoteInfo.address, info.remoteInfo.port, info.message.byteLength, this.receivedDatagrams);
      if (!isDronePeerAddress(info.remoteInfo.address) || info.remoteInfo.port !== DRONE_PORT) {
        hilog.warn(LOG_DOMAIN, LOG_TAG,
          'message filtered remote=%{public}s:%{public}d expected=%{public}s:%{public}d',
          info.remoteInfo.address, info.remoteInfo.port, DRONE_IP, DRONE_PORT);
        return;
      }
      const handler = this.packetHandler;
      if (handler !== undefined) {
        handler(new Uint8Array(info.message), Date.now());
      }
    });
    udp.on('error', (error: Error) => {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'socket error=%{public}s', error.message);
      const handler = this.errorHandler;
      if (handler !== undefined) {
        handler(error.message);
      }
    });
    try {
      const localAddress: socket.NetAddress = {
        address: selection.localAddress,
        family: 1,
        port: 0
      };
      await udp.bind(localAddress);
      hilog.info(LOG_DOMAIN, LOG_TAG,
        'bind success local=%{public}s:%{public}d', localAddress.address, localAddress.port);
      await selection.handle.bindSocket(udp);
      hilog.info(LOG_DOMAIN, LOG_TAG, 'network bind success interface=%{public}s', selection.interfaceName);
      await udp.setExtraOptions({ receiveBufferSize: 4 * 1024 * 1024 });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      hilog.error(LOG_DOMAIN, LOG_TAG, 'open failed error=%{public}s', message);
      await this.close();
      throw new Error(message);
    }
  }

  receivedCount(): number {
    return this.receivedDatagrams;
  }

  sentCount(): number {
    return this.sentDatagrams;
  }

  lastPeer(): string {
    return this.lastPeerValue;
  }

  async send(packet: Uint8Array): Promise<void> {
    const udp = this.udp;
    if (udp === undefined) {
      throw new Error('UDP channel is closed');
    }
    const copy = new Uint8Array(packet);
    hilog.info(LOG_DOMAIN, LOG_TAG,
      'send begin remote=%{public}s:%{public}d length=%{public}d',
      this.remoteAddress.address, this.remoteAddress.port, copy.byteLength);
    try {
      await udp.send({ data: copy.buffer, address: this.remoteAddress });
      this.sentDatagrams++;
      hilog.info(LOG_DOMAIN, LOG_TAG,
        'send success remote=%{public}s:%{public}d length=%{public}d sent=%{public}d',
        this.remoteAddress.address, this.remoteAddress.port, copy.byteLength, this.sentDatagrams);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      hilog.error(LOG_DOMAIN, LOG_TAG,
        'send failed remote=%{public}s:%{public}d length=%{public}d error=%{public}s',
        this.remoteAddress.address, this.remoteAddress.port, copy.byteLength, message);
      throw new Error(message);
    }
  }

  async close(): Promise<void> {
    const udp = this.udp;
    this.udp = undefined;
    this.packetHandler = undefined;
    this.errorHandler = undefined;
    if (udp !== undefined) {
      udp.off('message');
      udp.off('error');
      try {
        await udp.close();
      } catch (_) {
      }
    }
  }
}

function isDronePeerAddress(address: string): boolean {
  return address === DRONE_IP || address.endsWith(`:${DRONE_IP}`);
}

function isDroneLocalAddress(address: string): boolean {
  if (!address.startsWith('192.168.2.') || address === DRONE_IP) {
    return false;
  }
  const finalOctet = Number.parseInt(address.substring('192.168.2.'.length), 10);
  return Number.isInteger(finalOctet) && finalOctet > 1 && finalOctet < 255;
}
