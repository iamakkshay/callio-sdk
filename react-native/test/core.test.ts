// Tests the JS side of the wrapper against a mock native module. Run: node test/core.test.ts (Node 22.6+).
import { InCallClient, type NativeInCall } from '../src/core.ts';

let pass = 0, fail = 0;
const check = (cond: unknown, m: string) => { if (cond) { pass++; console.log('  ✓', m); } else { fail++; console.log('  ✗', m); } };

const calls: [string, unknown[]][] = [];
const tokens: [string, string | null][] = [];
const mock = new Proxy({}, { get: (_t, name: string) => (...args: unknown[]) => {
  calls.push([name, args]);
  if (name === 'provideToken') tokens.push(args as [string, string | null]);
  if (name === 'dial') return Promise.resolve('call-1');
  return Promise.resolve(undefined);
} }) as NativeInCall;
let emit: (e: any) => void = () => {};
let removed = false;
const events = { addListener: (_n: string, fn: (e: any) => void) => { emit = fn; return { remove: () => { removed = true; } }; } };

const c = new InCallClient(mock, events);
await c.start({ baseUrl: 'https://api.example.sa', tokenProvider: async () => 'tok-123' });
check(calls.some(([n, a]) => n === 'start' && a[0] === 'https://api.example.sa' && a[1] === false), 'start passes the base URL to the native SDK');

emit({ event: 'tokenRequest', requestId: 'r1' });
await new Promise((r) => setTimeout(r, 0));
check(tokens[0]?.[0] === 'r1' && tokens[0]?.[1] === 'tok-123', 'a native token request is answered from tokenProvider');

const c2 = new InCallClient(mock, { addListener: (_n: string, fn: (e: any) => void) => { emit = fn; return { remove() {} }; } });
await c2.start({ baseUrl: 'https://x.test', tokenProvider: async () => { throw new Error('backend down'); } });
emit({ event: 'tokenRequest', requestId: 'r2' });
await new Promise((r) => setTimeout(r, 0));
check(tokens[1]?.[0] === 'r2' && tokens[1]?.[1] === null, 'a failing tokenProvider answers null instead of hanging the SDK');

const c3events: { fn: (e: any) => void } = { fn: () => {} };
const c3 = new InCallClient(mock, { addListener: (_n, fn) => { c3events.fn = fn; return { remove() {} }; } });
let inc: any = null, n = 0;
const off3 = c3.on('incomingCall', (e) => { inc = e; n++; });
c3events.fn({ event: 'incomingCall', callId: 'c9', from: { name: 'agent1', sipUser: '1002', displayName: 'Agent', userType: 'agent' } });
check(inc?.callId === 'c9' && inc.from.sipUser === '1002' && !('event' in inc), 'native events reach subscribers without the envelope');
off3();
c3events.fn({ event: 'incomingCall', callId: 'c10', from: {} });
check(n === 1, 'unsubscribing stops delivery');
const warn = console.warn; console.warn = () => {};
c3.on('callState', () => { throw new Error('app bug'); });
let after = false; c3.on('callState', () => { after = true; });
c3events.fn({ event: 'callState', callId: 'c9', state: 'connected' });
console.warn = warn;
check(after, "one listener throwing doesn't stop the others");

const call = await c.dial('1002');
check(call.id === 'call-1' && call.peerSipUser === '1002', 'dial returns a Call with the native id');
await call.setMuted(true);
check(calls.some(([n, a]) => n === 'setMuted' && a[0] === true), 'call controls go to the native SDK');

let threw = 0;
try { c.sendDtmf('12'); } catch { threw++; }
try { c.sendLocation('1002', { lat: 120, lng: 0 }); } catch { threw++; }
try { await c.start({ baseUrl: 'api.example.sa', tokenProvider: async () => '' }); } catch { threw++; }
check(threw === 3, 'bad DTMF, coordinates and base URLs are rejected before reaching native');
await c.sendLocation('1002', { lat: 24.7, lng: 46.7 });
check(calls.some(([n, a]) => n === 'sendLocation' && a[3] === 'Shared location'), 'a location without a label gets the default');

c.dispose();
check(removed, 'dispose removes the native subscription');

console.log(`${pass} passed, ${fail} failed`);
if (fail) process.exit(1);
