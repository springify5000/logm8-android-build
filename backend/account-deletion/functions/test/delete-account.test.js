'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  deleteAccount,
  AccountDeletionError,
  collectStripeIds,
  looksLikeActiveStripeSubscription,
} = require('../lib/delete-account');

// ---- tiny in-memory stand-ins for Firestore / Storage / Auth / Stripe ----
function makeDb(seed) {
  const data = new Map(); // "collection/id" -> object
  for (const [path, value] of Object.entries(seed)) data.set(path, value);
  const ops = { queries: 0, batchCommits: 0, recursiveDeletes: [] };

  function docRef(collection, id) {
    return {
      id,
      path: `${collection}/${id}`,
      async get() {
        const value = data.get(`${collection}/${id}`);
        return { exists: value !== undefined, id, data: () => value };
      },
    };
  }
  function query(collection, field, value, limit) {
    return {
      limit(n) { return query(collection, field, value, n); },
      async get() {
        ops.queries += 1;
        const docs = [];
        for (const [path, doc] of data) {
          const [col, id] = path.split('/');
          if (col !== collection || !doc || doc[field] !== value) continue;
          docs.push({ id, ref: docRef(col, id), data: () => doc });
          if (limit && docs.length >= limit) break;
        }
        return { empty: docs.length === 0, size: docs.length, docs, forEach: (fn) => docs.forEach(fn) };
      },
    };
  }
  return {
    data,
    ops,
    collection(name) {
      return {
        doc: (id) => docRef(name, id),
        where: (field, op, value) => {
          assert.equal(op, '==');
          return query(name, field, value, 0);
        },
      };
    },
    batch() {
      const pending = [];
      return {
        delete(ref) { pending.push(ref.path); },
        async commit() { ops.batchCommits += 1; pending.forEach((p) => data.delete(p)); },
      };
    },
    async recursiveDelete(ref) {
      ops.recursiveDeletes.push(ref.path);
      for (const path of [...data.keys()]) {
        if (path === ref.path || path.startsWith(`${ref.path}/`)) data.delete(path);
      }
    },
  };
}

function makeBucket(paths) {
  const files = new Set(paths);
  return {
    files,
    async getFiles({ prefix }) {
      return [[...files].filter((p) => p.startsWith(prefix)).map((p) => ({
        name: p,
        async delete() { files.delete(p); },
      }))];
    },
  };
}

function makeAuth(existing) {
  const users = new Set(existing);
  return {
    users,
    async deleteUser(uid) {
      if (!users.has(uid)) { const e = new Error('no user'); e.code = 'auth/user-not-found'; throw e; }
      users.delete(uid);
    },
  };
}

function makeStripe({ subs = {}, failList = false, failCancel = false } = {}) {
  const calls = { cancelled: [], listed: [], retrieved: [] };
  return {
    calls,
    subscriptions: {
      async retrieve(id) {
        calls.retrieved.push(id);
        if (!subs[id]) { const e = new Error('No such subscription'); e.code = 'resource_missing'; throw e; }
        return { id, status: subs[id].status };
      },
      async list({ customer }) {
        calls.listed.push(customer);
        if (failList) throw new Error('Stripe is down');
        return { data: Object.entries(subs).filter(([, s]) => s.customer === customer).map(([id, s]) => ({ id, status: s.status })) };
      },
      async cancel(id) {
        if (failCancel) throw new Error('Stripe is down');
        calls.cancelled.push(id);
        subs[id].status = 'canceled';
        return { id, status: 'canceled' };
      },
    },
  };
}

const quietLog = { info() {}, warn() {}, error() {} };

function seedTwoUsers(extraUser = {}) {
  return {
    'users/alice': { vehicles: [], subscription: { isPro: false }, ...extraUser },
    'users/alice/fcmTokens/t1': { token: 'x' },
    'users/bob': { vehicles: [] },
    'trips/t1': { uid: 'alice', km: 10 },
    'trips/t2': { uid: 'alice', km: 20 },
    'trips/t3': { uid: 'bob', km: 30 },
    'trips/legacy': { userId: 'alice', km: 5 },
    'expenses/e1': { uid: 'alice', amount: 50, receiptPath: 'receipts/bob/e9/steal.jpg' },
    'expenses/e2': { uid: 'bob', amount: 70 },
    'stripeCustomers/cus_bob': { uid: 'bob' },
  };
}

test('deletes only the caller\'s data, receipts and login', async () => {
  const db = makeDb(seedTwoUsers());
  const bucket = makeBucket(['receipts/alice/e1/a.jpg', 'receipts/alice/e1/b.pdf', 'receipts/bob/e9/steal.jpg', 'receipts/alice2/x.jpg']);
  const auth = makeAuth(['alice', 'bob']);
  const summary = await deleteAccount({ uid: 'alice', db, auth, bucket, stripe: makeStripe(), revenueCatKey: '', fetchImpl: null, log: quietLog });

  assert.equal(summary.trips, 3);
  assert.equal(summary.expenses, 1);
  assert.equal(summary.receipts, 2);
  assert.equal(summary.userDoc, true);
  assert.equal(summary.authUser, true);
  assert.deepEqual([...db.data.keys()].sort(), ['expenses/e2', 'stripeCustomers/cus_bob', 'trips/t3', 'users/bob']);
  assert.deepEqual([...bucket.files].sort(), ['receipts/alice2/x.jpg', 'receipts/bob/e9/steal.jpg']);
  assert.deepEqual([...auth.users], ['bob']);
});

test('cancels an active web (Stripe) subscription before deleting', async () => {
  const db = makeDb(seedTwoUsers({ subscription: { isPro: true, provider: 'stripe', status: 'active', stripeCustomerId: 'cus_alice', stripeSubscriptionId: 'sub_a1' } }));
  const stripe = makeStripe({ subs: { sub_a1: { customer: 'cus_alice', status: 'active' }, sub_old: { customer: 'cus_alice', status: 'canceled' }, sub_b: { customer: 'cus_bob', status: 'active' } } });
  const summary = await deleteAccount({ uid: 'alice', db, auth: makeAuth(['alice']), bucket: makeBucket([]), stripe, revenueCatKey: '', fetchImpl: null, log: quietLog });
  assert.deepEqual(stripe.calls.cancelled, ['sub_a1']);
  assert.equal(summary.stripeCancelled, 1);
  assert.ok(!db.data.has('users/alice'));
});

test('finds the Stripe customer through stripeCustomers when the profile has no ids', async () => {
  const db = makeDb({ ...seedTwoUsers({ subscription: { isPro: true, provider: 'stripe', status: 'active' } }), 'stripeCustomers/cus_alice': { uid: 'alice' } });
  const stripe = makeStripe({ subs: { sub_a1: { customer: 'cus_alice', status: 'past_due' } } });
  await deleteAccount({ uid: 'alice', db, auth: makeAuth(['alice']), bucket: makeBucket([]), stripe, revenueCatKey: '', fetchImpl: null, log: quietLog });
  assert.deepEqual(stripe.calls.listed, ['cus_alice']);
  assert.deepEqual(stripe.calls.cancelled, ['sub_a1']);
});

test('if Stripe is unreachable, nothing is deleted and the user can retry', async () => {
  const db = makeDb(seedTwoUsers({ subscription: { isPro: true, provider: 'stripe', status: 'active', stripeCustomerId: 'cus_alice' } }));
  const auth = makeAuth(['alice']);
  const before = [...db.data.keys()].sort();
  await assert.rejects(
    deleteAccount({ uid: 'alice', db, auth, bucket: makeBucket(['receipts/alice/e1/a.jpg']), stripe: makeStripe({ failList: true }), revenueCatKey: '', fetchImpl: null, log: quietLog }),
    (err) => err instanceof AccountDeletionError && err.code === 'unavailable',
  );
  assert.deepEqual([...db.data.keys()].sort(), before);
  assert.deepEqual([...auth.users], ['alice']);
});

test('active web subscription but no Stripe key: refuse instead of leaving the customer billed', async () => {
  const db = makeDb(seedTwoUsers({ subscription: { isPro: true, provider: 'stripe', status: 'active', stripeSubscriptionId: 'sub_a1' } }));
  await assert.rejects(
    deleteAccount({ uid: 'alice', db, auth: makeAuth(['alice']), bucket: makeBucket([]), stripe: null, revenueCatKey: '', fetchImpl: null, log: quietLog }),
    (err) => err.code === 'unavailable',
  );
  assert.ok(db.data.has('users/alice'));
});

test('RevenueCat failures do not block deletion; the customer is deleted when it works', async () => {
  const calls = [];
  const okFetch = async (url, init) => { calls.push([url, init.method, init.headers.Authorization]); return { ok: true, status: 200 }; };
  const summary = await deleteAccount({ uid: 'alice', db: makeDb(seedTwoUsers()), auth: makeAuth(['alice']), bucket: makeBucket([]), stripe: null, revenueCatKey: 'sk_rc', fetchImpl: okFetch, log: quietLog });
  assert.equal(summary.revenueCat, 'deleted');
  assert.deepEqual(calls, [['https://api.revenuecat.com/v1/subscribers/alice', 'DELETE', 'Bearer sk_rc']]);

  const badFetch = async () => { throw new Error('network'); };
  const s2 = await deleteAccount({ uid: 'alice', db: makeDb(seedTwoUsers()), auth: makeAuth(['alice']), bucket: makeBucket([]), stripe: null, revenueCatKey: 'sk_rc', fetchImpl: badFetch, log: quietLog });
  assert.equal(s2.revenueCat, 'error');
  assert.equal(s2.authUser, true);
});

test('running it twice is safe (login already gone, nothing left to delete)', async () => {
  const db = makeDb(seedTwoUsers());
  const auth = makeAuth(['alice']);
  await deleteAccount({ uid: 'alice', db, auth, bucket: makeBucket([]), stripe: null, revenueCatKey: '', fetchImpl: null, log: quietLog });
  const again = await deleteAccount({ uid: 'alice', db, auth, bucket: makeBucket([]), stripe: null, revenueCatKey: '', fetchImpl: null, log: quietLog });
  assert.equal(again.trips + again.expenses + again.receipts, 0);
  assert.equal(again.authUser, true);
});

test('pages through more trips than one batch', async () => {
  const seed = { 'users/alice': {} };
  for (let i = 0; i < 950; i += 1) seed[`trips/t${i}`] = { uid: 'alice' };
  const db = makeDb(seed);
  const summary = await deleteAccount({ uid: 'alice', db, auth: makeAuth(['alice']), bucket: makeBucket([]), stripe: null, revenueCatKey: '', fetchImpl: null, log: quietLog });
  assert.equal(summary.trips, 950);
  assert.equal(db.data.size, 0);
});

test('helpers: Stripe id discovery and the active-subscription hint', () => {
  const ids = collectStripeIds({ a: 'cus_123', nested: { b: 'sub_456', c: ['sub_789', 'other'] }, d: 'customer' });
  assert.deepEqual([...ids.customers], ['cus_123']);
  assert.deepEqual([...ids.subscriptions].sort(), ['sub_456', 'sub_789']);
  assert.equal(looksLikeActiveStripeSubscription({ subscription: { provider: 'stripe', isPro: true } }), true);
  assert.equal(looksLikeActiveStripeSubscription({ subscription: { provider: 'revenuecat', isPro: true } }), false);
  assert.equal(looksLikeActiveStripeSubscription({ subscription: { provider: 'stripe', status: 'canceled', isPro: false } }), false);
});
