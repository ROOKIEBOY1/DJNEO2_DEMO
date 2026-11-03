import { wifiManager } from '@kit.ConnectivityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { DroneNetworkSelector, DroneWifiSelection } from './DroneUdpChannel';
import { AircraftProfileRuntime } from '../profile/AircraftProfileStore';

export type WifiProgressHandler = (message: string) => void;

export class NeoWifiLink {
  private candidateId: number = -1;

  async join(profile: AircraftProfileRuntime, onProgress: WifiProgressHandler,
    timeoutMs: number = 90000): Promise<DroneWifiSelection> {
    if (profile.ssid.length === 0 || profile.password.length === 0) {
      throw new Error('Selected aircraft Wi-Fi credentials are incomplete');
    }
    if (!wifiManager.isWifiActive()) {
      throw new Error('WLAN is off; turn it on in Control Center and retry');
    }
    const existing = await this.selectionForSsid(profile.ssid);
    if (existing !== undefined) {
      onProgress('已连接目标飞机热点，复用当前 Wi-Fi');
      return existing;
    }
    onProgress(`请求连接 ${profile.ssid}`);
    const config: wifiManager.WifiDeviceConfig = {
      ssid: profile.ssid,
      preSharedKey: profile.password,
      securityType: wifiManager.WifiSecurityType.WIFI_SEC_TYPE_PSK
    };
    this.candidateId = await wifiManager.addCandidateConfig(config);
    if (this.candidateId < 0) throw new Error('System rejected the aircraft Wi-Fi candidate configuration');
    try {
      await this.connectCandidate(this.candidateId);
      const started = Date.now();
      while (Date.now() - started < timeoutMs) {
        const selection = await this.selectionForSsid(profile.ssid);
        if (selection !== undefined) {
          onProgress(`飞机 Wi-Fi 已就绪：${selection.localAddress}`);
          return selection;
        }
        onProgress(`等待飞机分配地址 ${Math.floor((Date.now() - started) / 1000)}s`);
        await delay(500);
      }
      throw new Error('Timed out waiting for a 192.168.2.x address from the selected aircraft');
    } catch (error) {
      await this.leave();
      throw error instanceof Error ? error : new Error(String(error));
    }
  }

  async leave(): Promise<void> {
    const id = this.candidateId;
    this.candidateId = -1;
    if (id >= 0) {
      try {
        await wifiManager.removeCandidateConfig(id);
      } catch (_) {
        // Session shutdown must continue even if the system already removed the candidate.
      }
    }
  }

  private async selectionForSsid(expectedSsid: string): Promise<DroneWifiSelection | undefined> {
    try {
      const linked = await wifiManager.getLinkedInfo();
      if (normalizeSsid(linked.ssid) !== normalizeSsid(expectedSsid)) return undefined;
      return await DroneNetworkSelector.find();
    } catch (_) {
      return undefined;
    }
  }

  private async connectCandidate(id: number): Promise<void> {
    try {
      await wifiManager.connectToCandidateConfigWithUserAction(id);
    } catch (error) {
      const business = error as BusinessError;
      if (business.code === 2501006) throw new Error('You declined the system Wi-Fi connection request');
      if (business.code === 2501005) throw new Error('The system Wi-Fi confirmation timed out');
      if (business.code === 801 || business.code === 202) {
        wifiManager.connectToCandidateConfig(id);
        return;
      }
      throw new Error(`Aircraft Wi-Fi connection failed (${business.code}): ${business.message}`);
    }
  }
}

function normalizeSsid(value: string): string {
  if (value.length >= 2 && value[0] === '"' && value[value.length - 1] === '"') {
    return value.substring(1, value.length - 1);
  }
  return value;
}

function delay(milliseconds: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => setTimeout(resolve, milliseconds));
}
