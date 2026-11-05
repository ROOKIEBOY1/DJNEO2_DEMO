import { fileIo } from '@kit.CoreFileKit';
import { builtInRegistrationProfile, parseRegistrationProfile, RegistrationProfile } from '../transport/RegistrationExchange';
import { RoutingSequenceStore, validateRoutingState } from '../transport/RoutingSequenceStore';

export interface AircraftProfileSummary {
  id: string;
  displayName: string;
  ssid: string;
  configured: boolean;
  routingReady: boolean;
  registrationReady: boolean;
}

interface AircraftProfileRecord {
  id: string;
  displayName: string;
  ssid: string;
  password: string;
  registrationKind: string;
  registrationJson: string;
  registrationProfileId: string;
  routingIdentity: string;
}

interface AircraftProfilesDocument {
  version: number;
  selectedId: string;
  profiles: AircraftProfileRecord[];
}

export interface AircraftProfileRuntime {
  id: string;
  displayName: string;
  ssid: string;
  password: string;
  directory: string;
  registration: RegistrationProfile;
}

export class AircraftProfileStore {
  private readonly root: string;
  private readonly path: string;
  private document: AircraftProfilesDocument;

  constructor(filesDirectory: string) {
    this.root = `${filesDirectory}/aircraft`;
    this.path = `${filesDirectory}/aircraft-profiles.json`;
    ensureDirectory(this.root);
    if (fileIo.accessSync(this.path)) {
      this.document = this.parseDocument(fileIo.readTextSync(this.path));
    } else {
      const builtIn = builtInRegistrationProfile();
      const first: AircraftProfileRecord = {
        id: createLocalId(), displayName: '未配置飞机', ssid: '', password: '',
        registrationKind: 'built_in', registrationJson: '', registrationProfileId: builtIn.profileId,
        routingIdentity: builtIn.routingIdentity
      };
      this.document = { version: 1, selectedId: first.id, profiles: [first] };
      ensureDirectory(this.directory(first.id));
      this.persist();
    }
  }

  list(): AircraftProfileSummary[] {
    return this.document.profiles.map((record: AircraftProfileRecord) => this.summary(record));
  }

  selectedId(): string {
    return this.document.selectedId;
  }

  selected(): AircraftProfileSummary | undefined {
    const record = this.find(this.document.selectedId);
    return record === undefined ? undefined : this.summary(record);
  }

  select(id: string): void {
    this.required(id);
    this.document.selectedId = id;
    this.persist();
  }

  create(displayName: string, ssid: string, password: string): AircraftProfileSummary {
    validateCredentials(displayName, ssid, password);
    const record: AircraftProfileRecord = {
      id: createLocalId(), displayName: displayName.trim(), ssid: ssid.trim(), password: password,
      registrationKind: '', registrationJson: '', registrationProfileId: '', routingIdentity: ''
    };
    this.document.profiles.push(record);
    this.document.selectedId = record.id;
    ensureDirectory(this.directory(record.id));
    this.persist();
    return this.summary(record);
  }

  updateCredentials(id: string, displayName: string, ssid: string, password: string): AircraftProfileSummary {
    validateCredentials(displayName, ssid, password);
    const record = this.required(id);
    record.displayName = displayName.trim();
    record.ssid = ssid.trim();
    record.password = password;
    this.persist();
    return this.summary(record);
  }

  importRoutingState(id: string, jsonText: string): AircraftProfileSummary {
    const record = this.required(id);
    if (record.routingIdentity.length === 0) throw new Error('Import a verified registration profile first');
    validateRoutingState(jsonText, record.routingIdentity);
    new RoutingSequenceStore(this.directory(id), record.routingIdentity).importState(jsonText);
    return this.summary(record);
  }

  initializeRoutingState(id: string): AircraftProfileSummary {
    const record = this.required(id);
    const routingPath = `${this.directory(id)}/routing-sequence.json`;
    if (fileIo.accessSync(routingPath)) return this.summary(record);
    const registration = this.registrationFor(record);
    const initial = JSON.stringify({ version: 1, next_counter: 1,
      routing_identity: registration.routingIdentity });
    new RoutingSequenceStore(this.directory(id), registration.routingIdentity).importState(initial);
    return this.summary(record);
  }

  importRegistrationProfile(id: string, jsonText: string): AircraftProfileSummary {
    const record = this.required(id);
    const profile = parseRegistrationProfile(jsonText);
    const routingPath = `${this.directory(id)}/routing-sequence.json`;
    if (fileIo.accessSync(routingPath)) {
      validateRoutingState(fileIo.readTextSync(routingPath), profile.routingIdentity);
    }
    this.writeAtomic(`${this.directory(id)}/registration-profile.json`, jsonText);
    record.registrationKind = 'imported';
    record.registrationJson = '';
    record.registrationProfileId = profile.profileId;
    record.routingIdentity = profile.routingIdentity;
    this.persist();
    return this.summary(record);
  }

  remove(id: string): void {
    this.required(id);
    if (this.document.profiles.length <= 1) throw new Error('At least one aircraft profile must remain');
    const routingPath = `${this.directory(id)}/routing-sequence.json`;
    if (fileIo.accessSync(routingPath)) fileIo.unlinkSync(routingPath);
    const registrationPath = `${this.directory(id)}/registration-profile.json`;
    if (fileIo.accessSync(registrationPath)) fileIo.unlinkSync(registrationPath);
    const directory = this.directory(id);
    if (fileIo.accessSync(directory)) fileIo.rmdirSync(directory);
    this.document.profiles = this.document.profiles.filter((record: AircraftProfileRecord) => record.id !== id);
    if (this.document.selectedId === id) this.document.selectedId = this.document.profiles[0].id;
    this.persist();
  }

  runtime(id: string): AircraftProfileRuntime {
    const record = this.required(id);
    if (record.password.length === 0) throw new Error('Aircraft Wi-Fi password is not configured');
    const registration = this.registrationFor(record);
    const routingPath = `${this.directory(id)}/routing-sequence.json`;
    if (!fileIo.accessSync(routingPath)) throw new Error('Latest routing state is not imported for this aircraft');
    validateRoutingState(fileIo.readTextSync(routingPath), registration.routingIdentity);
    return { id: record.id, displayName: record.displayName, ssid: record.ssid, password: record.password,
      directory: this.directory(id), registration: registration };
  }

  private registrationFor(record: AircraftProfileRecord): RegistrationProfile {
    if (record.registrationKind === 'built_in') return builtInRegistrationProfile();
    if (record.registrationKind === 'imported') {
      const registrationPath = `${this.directory(record.id)}/registration-profile.json`;
      if (!fileIo.accessSync(registrationPath)) throw new Error('Imported registration profile is missing');
      return parseRegistrationProfile(fileIo.readTextSync(registrationPath));
    }
    throw new Error('Verified registration profile is not configured');
  }

  private summary(record: AircraftProfileRecord): AircraftProfileSummary {
    let routingReady = false;
    const routingPath = `${this.directory(record.id)}/routing-sequence.json`;
    try {
      routingReady = record.routingIdentity.length > 0 && fileIo.accessSync(routingPath) &&
        validateRoutingState(fileIo.readTextSync(routingPath), record.routingIdentity) > 0;
    } catch (_) {
      routingReady = false;
    }
    const registrationReady = record.registrationKind === 'built_in' ||
      (record.registrationKind === 'imported' && fileIo.accessSync(`${this.directory(record.id)}/registration-profile.json`));
    return { id: record.id, displayName: record.displayName, ssid: record.ssid,
      configured: record.ssid.length > 0 && record.password.length > 0, routingReady: routingReady,
      registrationReady: registrationReady };
  }

  private directory(id: string): string {
    if (!/^[a-z0-9-]{16,80}$/.test(id)) throw new Error('Invalid aircraft profile identifier');
    return `${this.root}/${id}`;
  }

  private find(id: string): AircraftProfileRecord | undefined {
    return this.document.profiles.find((record: AircraftProfileRecord) => record.id === id);
  }

  private required(id: string): AircraftProfileRecord {
    const record = this.find(id);
    if (record === undefined) throw new Error('Aircraft profile was not found');
    return record;
  }

  private parseDocument(text: string): AircraftProfilesDocument {
    const document = JSON.parse(text) as AircraftProfilesDocument;
    if (document.version !== 1 || !Array.isArray(document.profiles) || document.profiles.length === 0) {
      throw new Error('Invalid aircraft profile store');
    }
    document.profiles.forEach((record: AircraftProfileRecord) => {
      this.directory(record.id);
      if (record.displayName.length === 0 || record.ssid.length === 0) throw new Error('Invalid aircraft profile');
      ensureDirectory(this.directory(record.id));
    });
    if (document.profiles.find((record: AircraftProfileRecord) => record.id === document.selectedId) === undefined) {
      document.selectedId = document.profiles[0].id;
    }
    return document;
  }

  private persist(): void {
    this.writeAtomic(this.path, JSON.stringify(this.document));
  }

  private writeAtomic(path: string, text: string): void {
    const temporary = `${path}.tmp`;
    const file = fileIo.openSync(temporary, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(file.fd, text);
      fileIo.fsyncSync(file.fd);
    } finally {
      fileIo.closeSync(file);
    }
    fileIo.renameSync(temporary, path);
  }
}

function validateCredentials(displayName: string, ssid: string, password: string): void {
  if (displayName.trim().length < 1 || displayName.trim().length > 40 || ssid.trim().length < 1 ||
    ssid.trim().length > 32 || password.length < 8 || password.length > 63) {
    throw new Error('Display name, SSID or WPA password length is invalid');
  }
}

function createLocalId(): string {
  return `neo2-${Date.now().toString(36)}-${Math.floor(Math.random() * 0x100000000).toString(36)}`;
}

function ensureDirectory(path: string): void {
  if (!fileIo.accessSync(path)) fileIo.mkdirSync(path, true);
}
