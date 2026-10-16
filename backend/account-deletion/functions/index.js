'use strict';

// LogM8 — "Delete account" from inside the app (App Store guideline 5.1.1(v), Google Play account
// deletion policy). Lives in its own functions codebase ("account"), so deploying it never touches
// the other LogM8 functions. Region and secrets are the same ones the main backend already uses.

const { onCall, HttpsError } = require('firebase-functions/v2/https');
const { defineSecret } = require('firebase-functions/params');
const logger = require('firebase-functions/logger');
const { initializeApp } = require('firebase-admin/app');
const { getAuth } = require('firebase-admin/auth');
const { getFirestore } = require('firebase-admin/firestore');
const { getStorage } = require('firebase-admin/storage');
const { deleteAccount, AccountDeletionError } = require('./lib/delete-account');

initializeApp();

const STRIPE_SECRET_KEY = defineSecret('STRIPE_SECRET_KEY');
const REVENUECAT_SECRET_KEY = defineSecret('REVENUECAT_SECRET_KEY');

exports.deleteMyAccount = onCall({
  region: 'australia-southeast1',
  secrets: [STRIPE_SECRET_KEY, REVENUECAT_SECRET_KEY],
  timeoutSeconds: 300,
  memory: '512MiB',
  maxInstances: 5,
}, async (request) => {
  const uid = request.auth && request.auth.uid;
  if (!uid) throw new HttpsError('unauthenticated', 'Please sign in again.');
  if (!request.data || request.data.confirm !== 'DELETE') {
    throw new HttpsError('invalid-argument', 'Type DELETE to confirm.');
  }

  const stripeKey = STRIPE_SECRET_KEY.value();
  const Stripe = require('stripe');
  const stripe = stripeKey ? new Stripe(stripeKey) : null;

  try {
    const summary = await deleteAccount({
      uid,
      db: getFirestore(),
      auth: getAuth(),
      bucket: getStorage().bucket(),
      stripe,
      revenueCatKey: REVENUECAT_SECRET_KEY.value(),
      fetchImpl: fetch,
      log: logger,
    });
    logger.info('LogM8 account deleted', summary);
    return { ok: true };
  } catch (err) {
    if (err instanceof AccountDeletionError) {
      logger.warn('LogM8 account deletion stopped', { uid, code: err.code, message: err.message });
      throw new HttpsError(err.code, err.message);
    }
    logger.error('LogM8 account deletion failed', { uid, error: String((err && err.stack) || err) });
    throw new HttpsError('internal', 'We could not delete your account right now. Please try again.');
  }
});
