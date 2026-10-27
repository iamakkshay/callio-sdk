// The JavaScript side of the React Native wrapper (FR-SDK-02), kept free of react-native imports so it can be
// tested with a mock native module (test/core.test.ts). index.ts wires it to NativeModules.CallioInCall.
//
// Tokens: the native SDK asks for a fresh token whenever it needs one. React Native can't call JS synchronously,
// so native emits `tokenRequest { requestId }` and waits; we answer with provideToken(requestId, token).

export type UserType = 'customer' | 'agent' | 'guest';
export type AudioRoute = 'earpiece' | 'speaker' | 'bluetooth';
export type CallState = 'initiating' | 'ringing' | 'connected' | 'onHold' | 'reconnecting' | 'ended';
export type Contact = { name: string; sipUser: string; displayName: string; userType: UserType };
export type SharedLocation = { lat: number; lng: number; label?: string };
export type Message = { id: string; from: 'me' | 'peer'; text?: string | null; location?: SharedLocation | null; status: string };
export type CallQuality = { rttMs?: number | null; jitterMs?: number | null; lossPct?: number | null; mos?: number | null };
export type HistoryEntry = { callId: string; peer: string; peerDisplayName: string; direction: 'incoming' | 'outgoing'; outcome: string; durationSec: number; at: string };

export type Events = {
  registration: { state: string };
  incomingCall: { callId: string; from: Contact };
  callState: { callId: string; state: CallState };
  quality: { quality: CallQuality };
  message: { peerSip: string; message: Message };
  failure: { code: string; message: string };
  audioRoute: { route: AudioRoute };
};

// What the platform module (ios/CallioInCall.swift, android/CallioInCallModule.kt) exposes.
export interface NativeInCall {
  start(baseUrl: string, forceRelay: boolean): Promise<void>;
  stop(): Promise<void>;
  provideToken(requestId: string, token: string | null): void;
  dial(sipUser: string): Promise<string>;
  answer(): Promise<void>;
  decline(): Promise<void>;
  hangup(): Promise<void>;
  setMuted(muted: boolean): Promise<void>;
  setHold(held: boolean): Promise<void>;
  sendDtmf(tone: string): Promise<void>;
  setAudioRoute(route: AudioRoute): Promise<void>;
  sendText(to: string, text: string): Promise<string>;
  sendLocation(to: string, lat: number, lng: number, label: string): Promise<string>;
  setTyping(to: string, typing: boolean): Promise<void>;
  callHistory(limit: number): Promise<HistoryEntry[]>;
  registerPush(token: string): Promise<void>;
}

// One event stream from native: { event: <name>, ...payload } on the "CallioInCallEvent" channel.
export interface NativeEvents { addListener(name: string, fn: (e: any) => void): { remove(): void } }

export class Call {
  readonly id: string; readonly peerSipUser: string; private readonly n: NativeInCall;
  constructor(n: NativeInCall, id: string, peerSipUser: string) { this.n = n; this.id = id; this.peerSipUser = peerSipUser; }
  answer() { return this.n.answer(); }
  decline() { return this.n.decline(); }
  hangup() { return this.n.hangup(); }
  setMuted(muted: boolean) { return this.n.setMuted(muted); }
  setHold(held: boolean) { return this.n.setHold(held); }
  sendDtmf(tone: string) { return this.n.sendDtmf(tone); }
  setAudioRoute(route: AudioRoute) { return this.n.setAudioRoute(route); }
}

export class InCallClient {
  private readonly n: NativeInCall;
  private readonly listeners = new Map<string, Set<(e: any) => void>>();
  private tokenProvider: (() => Promise<string>) | null = null;
  private sub: { remove(): void } | null = null;

  constructor(native: NativeInCall, events: NativeEvents) {
    this.n = native;
    this.sub = events.addListener('CallioInCallEvent', (e) => this.dispatch(e));
  }

  private dispatch(e: any) {
    if (!e || typeof e.event !== 'string') return;
    if (e.event === 'tokenRequest') { this.answerToken(String(e.requestId)); return; }
    const { event, ...payload } = e;
    for (const fn of this.listeners.get(event) || []) {
      try { fn(payload); } catch (err) { console.warn('[callio] listener for', event, 'threw', err); }
    }
  }

  private async answerToken(requestId: string) {
    let token: string | null = null;
    try { token = this.tokenProvider ? await this.tokenProvider() : null; } catch { token = null; }
    this.n.provideToken(requestId, token);   // null = the SDK reports an auth failure
  }

  /** Fetch the session and sign in to the call line. tokenProvider returns a short-lived token from your backend. */
  async start(opts: { baseUrl: string; tokenProvider: () => Promise<string>; forceRelay?: boolean }) {
    if (!/^https?:\/\//.test(opts.baseUrl)) throw new Error('baseUrl must be an http(s) URL');
    this.tokenProvider = opts.tokenProvider;
    await this.n.start(opts.baseUrl, !!opts.forceRelay);
  }
  stop() { return this.n.stop(); }

  /** Subscribe to an event; returns an unsubscribe function. */
  on<K extends keyof Events>(event: K, fn: (e: Events[K]) => void): () => void {
    let set = this.listeners.get(event);
    if (!set) { set = new Set(); this.listeners.set(event, set); }
    set.add(fn);
    return () => { set!.delete(fn); };
  }

  async dial(sipUser: string): Promise<Call> { return new Call(this.n, await this.n.dial(sipUser), sipUser); }
  answer() { return this.n.answer(); }
  decline() { return this.n.decline(); }
  hangup() { return this.n.hangup(); }
  setMuted(muted: boolean) { return this.n.setMuted(muted); }
  setHold(held: boolean) { return this.n.setHold(held); }
  sendDtmf(tone: string) {
    if (!/^[0-9*#A-D]$/.test(tone)) throw new Error('DTMF tone must be one of 0-9 * # A-D');
    return this.n.sendDtmf(tone);
  }

  /** Earpiece, speaker or Bluetooth headset; `audioRoute` events report changes (headset plugged in, etc.). */
  setAudioRoute(route: AudioRoute) {
    if (!['earpiece', 'speaker', 'bluetooth'].includes(route)) throw new Error('route must be earpiece, speaker or bluetooth');
    return this.n.setAudioRoute(route);
  }

  sendText(to: string, text: string) { return this.n.sendText(to, text); }
  sendLocation(to: string, loc: SharedLocation) {
    if (!(Math.abs(loc.lat) <= 90 && Math.abs(loc.lng) <= 180)) throw new Error('invalid coordinates');
    return this.n.sendLocation(to, loc.lat, loc.lng, loc.label || 'Shared location');
  }
  setTyping(to: string, typing: boolean) { return this.n.setTyping(to, typing); }
  callHistory(limit = 50) { return this.n.callHistory(limit); }
  /** APNs VoIP token on iOS, FCM token on Android: lets calls ring a killed app. */
  registerPush(token: string) { return this.n.registerPush(token); }

  /** Drop the native event subscription (tests, hot reload). */
  dispose() { this.sub?.remove(); this.sub = null; this.listeners.clear(); }
}
