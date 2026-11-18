import { HttpClient, type CallioOptions } from './http.js';
import { Cdr, Events, Groups, Orders, Recordings, Tokens, Users } from './resources.js';

/**
 * The Callio tenant API client. Keep it on your server: the API key gives full access to your
 * organisation's users, orders and recordings.
 *
 * ```ts
 * const callio = new Callio({ apiKey: process.env.CALLIO_API_KEY, baseUrl: 'https://api.example.sa' });
 * const { token } = await callio.tokens.forUser('cust-42', { displayName: 'Sara', userType: 'customer' });
 * ```
 */
export class Callio {
  readonly users: Users;
  readonly tokens: Tokens;
  readonly orders: Orders;
  readonly recordings: Recordings;
  readonly groups: Groups;
  readonly events: Events;
  readonly cdr: Cdr;
  /** The underlying HTTP client (low-level `request()` for endpoints the SDK doesn't wrap yet). */
  readonly http: HttpClient;

  constructor(options: CallioOptions = {}) {
    this.http = new HttpClient(options);
    this.users = new Users(this.http);
    this.tokens = new Tokens(this.http, this.users);
    this.orders = new Orders(this.http);
    this.recordings = new Recordings(this.http);
    this.groups = new Groups(this.http);
    this.events = new Events(this.http);
    this.cdr = new Cdr(this.http);
  }

  toJSON() { return this.http.toJSON(); }
  [Symbol.for('nodejs.util.inspect.custom')]() { return `Callio ${JSON.stringify(this.http.toJSON())}`; }
}
