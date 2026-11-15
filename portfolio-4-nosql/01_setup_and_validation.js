// =====================================================================
// MIT 8103 Portfolio 4: MongoDB (document model) for KoboLedger
// 01: create collections WITH schema validation and indexes.
//
// Run:  mongosh "mongodb://localhost:27017" --file 01_setup_and_validation.js
// (Atlas: mongosh "mongodb+srv://<your-cluster-uri>" --file 01_setup_and_validation.js)
// =====================================================================
db = db.getSiblingDB('koboledger');
db.dropDatabase();                       // start clean on every run

// ---------------------------------------------------------------------
// customers: one document per customer, with KYC documents, addresses and
// devices EMBEDDED. Shape varies by KYC tier (tier 1 has no ID document;
// tier 3 has address verification). In SQL this would be 4+ tables.
// "Schemaless" does not mean "no rules": $jsonSchema enforces the parts
// that must always be true, like CHECK constraints in Portfolio 1.
// ---------------------------------------------------------------------
db.createCollection('customers', {
  validator: {
    $jsonSchema: {
      bsonType: 'object',
      required: ['_id', 'bvn', 'name', 'phone', 'kyc', 'created_at'],
      properties: {
        _id:   { bsonType: 'int', description: 'customer_id from the core ledger (PostgreSQL)' },
        bvn:   { bsonType: 'string', pattern: '^[0-9]{11}$' },
        phone: { bsonType: 'string', pattern: '^\\+234[0-9]{10}$' },
        name:  { bsonType: 'object', required: ['first', 'last'] },
        kyc: {
          bsonType: 'object',
          required: ['tier'],
          properties: {
            tier:      { enum: [1, 2, 3] },
            documents: { bsonType: 'array' }
          }
        },
        devices:    { bsonType: 'array' },
        created_at: { bsonType: 'date' }
      }
    }
  },
  validationAction: 'error'
});
db.customers.createIndex({ bvn: 1 },   { unique: true });
db.customers.createIndex({ phone: 1 }, { unique: true });

// ---------------------------------------------------------------------
// transaction_events: an append-only log of every transaction event as the
// app/channels saw it. POLYMORPHIC: NIP, CARD, USSD and INTERNAL events carry
// different fields. Money is stored as Decimal128, never as a double
// (same reason as NUMERIC vs FLOAT in Portfolio 1).
// ---------------------------------------------------------------------
db.createCollection('transaction_events', {
  validator: {
    $jsonSchema: {
      bsonType: 'object',
      required: ['reference', 'account_number', 'channel', 'direction', 'amount', 'status', 'ts'],
      properties: {
        reference:      { bsonType: 'string' },
        account_number: { bsonType: 'string', pattern: '^[0-9]{10}$' },
        channel:        { enum: ['NIP', 'INTERNAL', 'CARD', 'USSD'] },
        direction:      { enum: ['DEBIT', 'CREDIT'] },
        amount:         { bsonType: 'decimal' },
        status:         { enum: ['SUCCESSFUL', 'FAILED', 'REVERSED'] },
        ts:             { bsonType: 'date' }
      }
    }
  }
});
db.transaction_events.createIndex({ reference: 1 }, { unique: true });
// NOTE: no {account_number, ts} index yet; 03_queries.js measures the
// statement query before and after creating it (as in Portfolio 2).

print('Collections created: ' + db.getCollectionNames().sort().join(', '));

// ---------------------------------------------------------------------
// Evidence: validation rejects bad documents (screenshot this output)
// ---------------------------------------------------------------------
function tryInsert(label, coll, doc) {
  try {
    db[coll].insertOne(doc);
    print('ACCEPTED  ' + label);
  } catch (e) {
    // Dig out WHICH rule failed from the validation error details
    let why = e.message;
    try {
      const rules = e.errInfo.details.schemaRulesNotSatisfied;
      why = rules.map(r => (r.propertiesNotSatisfied || []).map(p =>
              p.propertyName + ': ' + (p.details || []).map(d => d.operatorName +
                (d.reason ? ' (' + d.reason + ')' : '')).join(', ')).join('; ')).join(' | ');
    } catch (ignored) {}
    print('REJECTED  ' + label + '  ->  ' + why);
  }
}
tryInsert('BVN with letters', 'customers', {
  _id: 999999, bvn: 'ABC12345678', phone: '+2348030000999',
  name: { first: 'Bad', last: 'Data' }, kyc: { tier: 1 }, created_at: new Date() });
tryInsert('KYC tier 7', 'customers', {
  _id: 999998, bvn: '22199999998', phone: '+2348030000998',
  name: { first: 'Bad', last: 'Tier' }, kyc: { tier: 7 }, created_at: new Date() });
tryInsert('amount stored as a double', 'transaction_events', {
  reference: 'BAD-1', account_number: '1000000005', channel: 'NIP', direction: 'DEBIT',
  amount: 5000.5, status: 'SUCCESSFUL', ts: new Date() });
tryInsert('unknown channel BITCOIN', 'transaction_events', {
  reference: 'BAD-2', account_number: '1000000005', channel: 'BITCOIN', direction: 'DEBIT',
  amount: Decimal128.fromString('5000.00'), status: 'SUCCESSFUL', ts: new Date() });
tryInsert('valid tier-1 customer (minimal shape)', 'customers', {
  _id: 1, bvn: '22100000001', phone: '+2348030000001',
  name: { first: 'Ada', last: 'Okafor' }, kyc: { tier: 1 }, created_at: new Date() });
db.customers.deleteOne({ _id: 1 });     // test document only
