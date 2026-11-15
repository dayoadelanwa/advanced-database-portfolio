// =====================================================================
// MIT 8103 Portfolio 4: seed KoboLedger documents.
// 2,000 customers (_id = the same customer_id as in PostgreSQL) and
// 60,000 transaction events across four channels. Takes ~10-30 seconds.
//
// Run:  mongosh "mongodb://localhost:27017" --file 02_seed_data.js
// =====================================================================
db = db.getSiblingDB('koboledger');

// Small deterministic random generator (mulberry32): same data on every run.
// Uses 32-bit integer maths (Math.imul): a naive LCG overflows JavaScript's
// 53-bit number precision and produces a short, repeating cycle.
let seed = 42;
function rnd() {
  seed = (seed + 0x6D2B79F5) | 0;
  let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
  t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
}
function pick(arr) { return arr[Math.floor(rnd() * arr.length)]; }
function money(min, max) { return Decimal128.fromString((min + rnd() * (max - min)).toFixed(2)); }

const FIRST = ['Ada','Musa','Tolu','Ngozi','Emeka','Fatima','Chidi','Aisha','Bola','Ifeanyi','Zainab','Segun'];
const LAST  = ['Okafor','Bello','Adeyemi','Eze','Ibrahim','Nwosu','Okonkwo','Abubakar','Balogun','Obi'];
const STATES = ['FCT','Lagos','Kano','Rivers','Enugu','Oyo','Kaduna'];
const BANKS = [['000013','Example Bank A'], ['000014','Example Bank B'], ['000016','Example Bank C']];
const MERCHANTS = [['ShopRite Jabi', 5411], ['Total Energies Wuse', 5541], ['Chicken Republic', 5814],
                   ['Jumia Online', 5999], ['Medplus Pharmacy', 5912]];
const NOW = Date.now(), DAY = 86400000;

// ----------------------------------------------------------------- customers
const customers = [];
for (let id = 5; id < 2005; id++) {
  const tier = pick([1, 1, 2, 2, 2, 3]);
  const c = {
    _id: id,
    bvn: String(22200000000 + id),
    phone: '+23480' + String(id).padStart(8, '0'),
    name: { first: pick(FIRST), last: pick(LAST) },
    kyc: { tier: tier, documents: [] },
    accounts: [{ number: String(1000000000 + id), type: 'WALLET' }],
    devices: [{ device_id: 'dev-' + id, os: pick(['Android', 'iOS']), first_seen: new Date(NOW - rnd() * 700 * DAY) }],
    preferences: { notifications: pick(['SMS', 'PUSH', 'EMAIL']), language: pick(['en', 'ha', 'yo', 'ig']) },
    created_at: new Date(NOW - (365 + rnd() * 730) * DAY)
  };
  // Shape grows with KYC tier: the document model's strength
  if (tier >= 2) c.kyc.documents.push({ type: pick(['NIN', 'VOTERS_CARD', 'INTL_PASSPORT']), verified: true,
                                        verified_at: new Date(NOW - rnd() * 300 * DAY) });
  if (tier === 3) {
    c.kyc.documents.push({ type: 'UTILITY_BILL', verified: true, verified_at: new Date(NOW - rnd() * 200 * DAY) });
    c.address = { line1: Math.floor(rnd() * 200) + ' Example Street', city: 'Abuja', state: pick(STATES), verified: true };
    c.accounts.push({ number: String(2000000000 + id), type: 'SAVINGS' });
  }
  if (rnd() < 0.15) c.devices.push({ device_id: 'dev-' + id + '-b', os: pick(['Android', 'iOS']),
                                     first_seen: new Date(NOW - rnd() * 100 * DAY) });
  customers.push(c);
}
db.customers.insertMany(customers);

// ------------------------------------------------------- transaction events
let batch = [], n = 0;
for (let i = 1; i <= 60000; i++) {
  const cust = 5 + Math.floor(rnd() * 2000);
  const channel = pick(['NIP', 'NIP', 'INTERNAL', 'INTERNAL', 'CARD', 'CARD', 'CARD', 'USSD']);
  const e = {
    reference: 'EV-' + i,
    account_number: String(1000000000 + cust),
    customer_id: cust,
    channel: channel,
    direction: channel === 'INTERNAL' && rnd() < 0.5 ? 'CREDIT' : 'DEBIT',
    amount: money(100, 50000),
    status: rnd() < 0.04 ? 'FAILED' : 'SUCCESSFUL',
    ts: new Date(NOW - rnd() * 365 * DAY),
    device: { device_id: 'dev-' + cust, app_version: pick(['4.2.0', '4.3.1', '5.0.0']) }
  };
  // Channel-specific fields: impossible to model in one SQL table without many NULL columns
  if (channel === 'NIP') {
    const b = pick(BANKS);
    e.nip = { session_id: '999001' + String(i).padStart(24, '0'), destination_bank: { code: b[0], name: b[1] },
              beneficiary_name: pick(FIRST).toUpperCase() + ' ' + pick(LAST).toUpperCase() };
  } else if (channel === 'CARD') {
    const m = pick(MERCHANTS);
    e.card = { masked_pan: '539983******' + String(1000 + cust).slice(-4), entry_mode: pick(['CHIP', 'CONTACTLESS', 'ONLINE']),
               merchant: { name: m[0], mcc: m[1], terminal_id: 'T' + String(Math.floor(rnd() * 9999)).padStart(4, '0') } };
  } else if (channel === 'USSD') {
    e.ussd = { short_code: '*5573#', telco: pick(['MTN', 'Airtel', 'Glo', '9mobile']) };
  } else {
    e.internal = { counterparty_account: String(1000000000 + 5 + Math.floor(rnd() * 2000)) };
  }
  batch.push(e);
  if (batch.length === 5000) { db.transaction_events.insertMany(batch); n += batch.length; batch = []; }
}
if (batch.length) { db.transaction_events.insertMany(batch); n += batch.length; }

print('customers:          ' + db.customers.countDocuments());
print('transaction_events: ' + db.transaction_events.countDocuments());
print('\nOne tier-3 customer (note the embedded arrays and objects):');
printjson(db.customers.findOne({ 'kyc.tier': 3 }));
print('\nOne CARD event and one NIP event (different shapes, same collection):');
printjson(db.transaction_events.findOne({ channel: 'CARD' }));
printjson(db.transaction_events.findOne({ channel: 'NIP' }));
