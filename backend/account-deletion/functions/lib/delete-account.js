'use strict';

// Deletes everything LogM8 keeps for one user. Runs with the Admin SDK because the Firestore rules
// (on purpose) do not let the client delete users/{uid}, and only let trial/Pro users delete trips
// and expenses — account deletion has to work for every user, paid or not.
//
// Order matters: billing is settled first (a web subscriber must never keep being charged after the
// account is gone), and the Firebase Auth user is removed last, so any failure before that leaves a
// working account the user can retry with. Every step is idempotent.

const ACTIVE_STRIPE_STATUSES = new Set(['active', 'trialing', 'past_due', 'unpaid', 'incomplete', 'paused']);
const BATCH_SIZE = 400;

class AccountDeletionError extends Error {
  constructor(code, message) {
    super(message);
    this.name = 'AccountDeletionError';
    this.code = code;
  }
}

const BILLING_RETRY_MESSAGE = 'We could not reach our billing system to cancel your subscription. Nothing was deleted. Please try again in a few minutes.';

function collectStripeIds(value, out = { customers: new Set(), subscriptions: new Set() }, depth = 0) {
  if (value == null || depth > 4) return out;
  if (typeof value === 'string') {
    if (/^cus_[A-Za-z0-9]+$/.test(value)) out.customers.add(value);
    else if (/^sub_[A-Za-z0-9]+$/.test(value)) out.subscriptions.add(value);
    return out;
  }
  if (Array.isArray(value)) {
    for (const item of value) collectStripeIds(item, out, depth + 1);
    return out;
  }
  if (typeof value === 'object') {
    for (const item of Object.values(value)) collectStripeIds(item, out, depth + 1);
  }
  return out;
}

function subscriptionOf(userData) {
  const sub = userData && userData.subscription;
  return sub && typeof sub === 'object' ? sub : null;
}

function looksLikeActiveStripeSubscription(userData) {
  const sub = subscriptionOf(userData);
  if (!sub) return false;
  const provider = `${sub.provider || ''} ${sub.source || ''}`.toLowerCase();
  const status = String(sub.status || '').toLowerCase();
  const isStripe = provider.includes('stripe') || collectStripeIds(sub).subscriptions.size > 0;
  return isStripe && (sub.isPro === true || ACTIVE_STRIPE_STATUSES.has(status));
}

async function findStripeIds(db, uid, userData) {
  const ids = collectStripeIds(userData);
  // stripeCustomers/{customerId} maps a Stripe customer back to the Firebase user.
  for (const field of ['uid', 'firebaseUid', 'userId']) {
    const snap = await db.collection('stripeCustomers').where(field, '==', uid).limit(10).get();
    snap.forEach((docSnap) => {
      if (/^cus_[A-Za-z0-9]+$/.test(docSnap.id)) ids.customers.add(docSnap.id);
      collectStripeIds(docSnap.data(), ids);
    });
  }
  return ids;
}

async function cancelStripeSubscriptions({ db, uid, userData, stripe, log }) {
  const activeHint = looksLikeActiveStripeSubscription(userData);
  const ids = await findStripeIds(db, uid, userData);
  if (!ids.customers.size && !ids.subscriptions.size) {
    if (activeHint) log.error('Stripe subscription looks active but no Stripe ids were found; check Stripe by hand', { uid });
    return { cancelled: [], manualCheck: activeHint };
  }
  if (!stripe) {
    if (activeHint) throw new AccountDeletionError('unavailable', BILLING_RETRY_MESSAGE);
    log.warn('Stripe ids found but no Stripe key configured; nothing cancelled', { uid });
    return { cancelled: [], manualCheck: true };
  }

  const toCancel = new Set();
  try {
    for (const subscriptionId of ids.subscriptions) {
      try {
        const sub = await stripe.subscriptions.retrieve(subscriptionId);
        if (ACTIVE_STRIPE_STATUSES.has(sub.status)) toCancel.add(sub.id);
      } catch (err) {
        if (err && err.code === 'resource_missing') continue;
        throw err;
      }
    }
    for (const customer of ids.customers) {
      try {
        const page = await stripe.subscriptions.list({ customer, status: 'all', limit: 100 });
        for (const sub of page.data || []) {
          if (ACTIVE_STRIPE_STATUSES.has(sub.status)) toCancel.add(sub.id);
        }
      } catch (err) {
        if (err && err.code === 'resource_missing') continue;
        throw err;
      }
    }
    const cancelled = [];
    for (const subscriptionId of toCancel) {
      await stripe.subscriptions.cancel(subscriptionId, {
        cancellation_details: { comment: 'Customer deleted their LogM8 account' },
      });
      cancelled.push(subscriptionId);
    }
    return { cancelled, manualCheck: false };
  } catch (err) {
    log.error('Stripe cancellation failed; account kept', { uid, error: String((err && err.message) || err) });
    throw new AccountDeletionError('unavailable', BILLING_RETRY_MESSAGE);
  }
}

async function deleteWhere(db, collection, field, uid) {
  let total = 0;
  for (;;) {
    const snap = await db.collection(collection).where(field, '==', uid).limit(BATCH_SIZE).get();
    if (snap.empty) break;
    const batch = db.batch();
    snap.docs.forEach((docSnap) => batch.delete(docSnap.ref));
    await batch.commit();
    total += snap.size;
    if (snap.size < BATCH_SIZE) break;
  }
  return total;
}

// Only the user's own folder. Never delete paths taken from documents: expenses are written by the
// client, so a receiptPath there could point at someone else's file.
async function deleteReceipts(bucket, uid) {
  const [files] = await bucket.getFiles({ prefix: `receipts/${uid}/` });
  for (let i = 0; i < files.length; i += 20) {
    await Promise.all(files.slice(i, i + 20).map((file) => file.delete({ ignoreNotFound: true })));
  }
  return files.length;
}

async function deleteRevenueCatCustomer({ uid, revenueCatKey, fetchImpl, log }) {
  if (!revenueCatKey || typeof fetchImpl !== 'function') return 'skipped';
  try {
    const res = await fetchImpl(`https://api.revenuecat.com/v1/subscribers/${encodeURIComponent(uid)}`, {
      method: 'DELETE',
      headers: { Authorization: `Bearer ${revenueCatKey}` },
    });
    if (res.status === 404) return 'not-found';
    if (res.ok) return 'deleted';
    log.warn('RevenueCat customer not deleted', { uid, status: res.status });
    return `http-${res.status}`;
  } catch (err) {
    log.warn('RevenueCat customer not deleted', { uid, error: String((err && err.message) || err) });
    return 'error';
  }
}

async function deleteAccount({ uid, db, auth, bucket, stripe, revenueCatKey, fetchImpl, log }) {
  if (!uid || typeof uid !== 'string') throw new AccountDeletionError('invalid-argument', 'Missing user.');
  const logger = log || console;

  const userRef = db.collection('users').doc(uid);
  const userSnap = await userRef.get();
  const userData = userSnap.exists ? (userSnap.data() || {}) : {};

  const billing = await cancelStripeSubscriptions({ db, uid, userData, stripe, log: logger });

  const summary = {
    uid,
    stripeCancelled: billing.cancelled.length,
    stripeManualCheck: billing.manualCheck,
    trips: 0,
    expenses: 0,
    receipts: 0,
    userDoc: false,
    revenueCat: 'skipped',
    authUser: false,
  };
  for (const field of ['uid', 'userId']) {
    summary.trips += await deleteWhere(db, 'trips', field, uid);
    summary.expenses += await deleteWhere(db, 'expenses', field, uid);
  }
  summary.receipts = await deleteReceipts(bucket, uid);
  await db.recursiveDelete(userRef);
  summary.userDoc = true;
  summary.revenueCat = await deleteRevenueCatCustomer({ uid, revenueCatKey, fetchImpl, log: logger });
  try {
    await auth.deleteUser(uid);
  } catch (err) {
    if (!err || err.code !== 'auth/user-not-found') throw err;
  }
  summary.authUser = true;
  return summary;
}

module.exports = {
  ACTIVE_STRIPE_STATUSES,
  AccountDeletionError,
  collectStripeIds,
  looksLikeActiveStripeSubscription,
  cancelStripeSubscriptions,
  deleteWhere,
  deleteReceipts,
  deleteRevenueCatCustomer,
  deleteAccount,
};
