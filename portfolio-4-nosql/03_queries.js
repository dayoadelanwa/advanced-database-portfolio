// =====================================================================
// MIT 8103 Portfolio 4: MongoDB queries, aggregation and indexing evidence.
// Run:  mongosh "mongodb://localhost:27017" --file 03_queries.js > ../results/mongodb_queries.txt
// =====================================================================
db = db.getSiblingDB('koboledger');
const ACCT = '1000000105';
function title(t) { print('\n================ ' + t); }

// ---------------------------------------------------------------------
title('M1 Customer 360: one read returns profile + KYC docs + accounts + devices');
// In PostgreSQL this needs customer JOIN kyc_tier JOIN account (+ device/document tables).
printjson(db.customers.findOne({ phone: '+2348000000105' }));

// ---------------------------------------------------------------------
title('M2 Polymorphic query: card spend at supermarkets (MCC 5411) in the last 30 days');
// merchant.mcc only exists on CARD events. No NULL columns, no extra table.
printjson(db.transaction_events.find(
  { channel: 'CARD', 'card.merchant.mcc': 5411, ts: { $gte: new Date(Date.now() - 30 * 86400000) } },
  { _id: 0, reference: 1, account_number: 1, amount: 1, 'card.merchant.name': 1, ts: 1 }
).sort({ ts: -1 }).limit(5).toArray());

// ---------------------------------------------------------------------
title('M3 Schema evolution without ALTER TABLE: KYC upgrade + new device');
// Atomic: both changes to ONE document succeed or fail together.
const r = db.customers.updateOne(
  { _id: 105 },
  { $set:  { 'kyc.tier': 3, address: { line1: '12 Example Close', city: 'Abuja', state: 'FCT', verified: true } },
    $push: { 'kyc.documents': { type: 'UTILITY_BILL', verified: true, verified_at: new Date() },
             devices: { device_id: 'dev-105-new', os: 'iOS', first_seen: new Date() } } }
);
print('matched ' + r.matchedCount + ', modified ' + r.modifiedCount);
printjson(db.customers.findOne({ _id: 105 }, { kyc: 1, address: 1, devices: 1 }));

// ---------------------------------------------------------------------
title('M4 Aggregation pipeline: monthly successful debit volume by channel');
// Same idea as SQL Portfolio 2 Q6: $match = WHERE, $group = GROUP BY, $sort = ORDER BY
printjson(db.transaction_events.aggregate([
  { $match: { status: 'SUCCESSFUL', direction: 'DEBIT' } },
  { $group: { _id: { month: { $dateTrunc: { date: '$ts', unit: 'month' } }, channel: '$channel' },
              transactions: { $sum: 1 }, value_ngn: { $sum: '$amount' } } },
  { $sort: { '_id.month': -1, '_id.channel': 1 } },
  { $limit: 8 }
]).toArray());

// ---------------------------------------------------------------------
title('M5 Indexing evidence: statement query BEFORE and AFTER a compound index');
function statementPlan(label) {
  const ex = db.transaction_events.find({ account_number: ACCT })
              .sort({ ts: -1 }).limit(20).explain('executionStats');
  const s = ex.executionStats;
  let stage = ex.queryPlanner.winningPlan;           // walk down to the leaf stage
  while (stage.inputStage) stage = stage.inputStage;
  print(label.padEnd(8) + ' leaf stage: ' + stage.stage.padEnd(9) +
        ' docsExamined: ' + String(s.totalDocsExamined).padStart(6) +
        '  keysExamined: ' + String(s.totalKeysExamined).padStart(5) +
        '  returned: ' + s.nReturned + '  time: ' + s.executionTimeMillis + ' ms');
}
statementPlan('BEFORE');
// ESR rule (Equality, Sort, Range): MongoDB's version of Portfolio 2's
// "equality column first, then the sort/range column".
db.transaction_events.createIndex({ account_number: 1, ts: -1 });
statementPlan('AFTER');

// ---------------------------------------------------------------------
title('M6 Bucket pattern: build monthly statement documents ($group + $push + $merge)');
// A read model for the app's statement screen: one document per account per
// month with its entries EMBEDDED, so a statement page is a single read.
// Like Portfolio 2's materialized view, it is rebuilt from the event log.
db.transaction_events.aggregate([
  { $match: { status: 'SUCCESSFUL' } },
  { $sort: { ts: 1 } },
  { $group: {
      _id: { $concat: ['$account_number', '-', { $dateToString: { format: '%Y-%m', date: '$ts' } }] },
      account_number: { $first: '$account_number' },
      month: { $first: { $dateToString: { format: '%Y-%m', date: '$ts' } } },
      entry_count: { $sum: 1 },
      total_debit:  { $sum: { $cond: [{ $eq: ['$direction', 'DEBIT'] },  '$amount', Decimal128.fromString('0')] } },
      total_credit: { $sum: { $cond: [{ $eq: ['$direction', 'CREDIT'] }, '$amount', Decimal128.fromString('0')] } },
      entries: { $push: { ts: '$ts', reference: '$reference', channel: '$channel',
                          direction: '$direction', amount: '$amount' } } } },
  { $merge: { into: 'account_statements', whenMatched: 'replace' } }
]);
print('statement buckets: ' + db.account_statements.countDocuments());
const latest = db.account_statements.find({ account_number: ACCT }).sort({ month: -1 }).limit(1).next();
print('Latest bucket for ' + ACCT + ': ' + latest._id + ' with ' + latest.entry_count + ' entries');
printjson(latest);

// ---------------------------------------------------------------------
title('M7 Single-document atomicity: post a new entry into a bucket');
// $push and $inc on ONE document are atomic, no transaction needed.
// (Multi-document transactions also exist, but need a replica set, e.g. Atlas.)
const res = db.account_statements.updateOne(
  { _id: latest._id },
  { $push: { entries: { ts: new Date(), reference: 'EV-LIVE-1', channel: 'USSD', direction: 'DEBIT',
                        amount: Decimal128.fromString('1500.00') } },
    $inc:  { entry_count: 1, total_debit: Decimal128.fromString('1500.00') } }
);
print('modified ' + res.modifiedCount + ' -> entry_count now ' +
      db.account_statements.findOne({ _id: latest._id }).entry_count);
