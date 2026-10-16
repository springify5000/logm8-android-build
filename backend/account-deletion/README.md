# LogM8: account deletion (`deleteMyAccount`)

This callable function deletes a user's account from inside the app. Both stores require it: App Store 5.1.1(v), and the Google Play account-deletion policy. The app (1.5.33+) calls it from **Profile → Delete account** after the user types DELETE.

What it deletes, in order:
1. **Stripe.** It cancels any active web subscription. If billing can't be reached, it stops and nothing is deleted.
2. **Firestore.** It deletes the user's `trips` and `expenses`, then `users/{uid}` and its subcollections.
3. **Storage.** It deletes the files under `receipts/{uid}/`.
4. **RevenueCat.** It deletes the customer. If this step fails, deletion continues anyway.
5. **Firebase Auth.** It deletes the login last, so any earlier failure leaves an account the user can retry with.

App Store and Google Play subscriptions are billed by Apple and Google, so the app tells the user to cancel those in their store.

## Deploy (PC with the Firebase CLI already logged in)

This is a separate functions codebase (`account`). Deploying it does **not** touch the other LogM8 functions. It reuses the existing `STRIPE_SECRET_KEY` and `REVENUECAT_SECRET_KEY` secrets and runs in `australia-southeast1`.

```powershell
cd $HOME\Desktop
git clone https://github.com/springify5000/logm8-android-build.git logm8-repo   # first time only; otherwise: cd logm8-repo; git pull
cd logm8-repo\backend\account-deletion\functions
npm install
npm test
cd ..
firebase deploy --only functions:account:deleteMyAccount
```

If you don't have git, download `https://github.com/springify5000/logm8-android-build/archive/refs/heads/main.zip`, extract it and run the same commands from `backend\account-deletion`.

**Check:** Firebase console → Functions shows `deleteMyAccount` (australia-southeast1, v2). Then, in app 1.5.33, sign in with a throwaway account, add a trip, go to Profile → Delete account and type DELETE. The app returns to the login screen, and the account disappears from Authentication → Users.

**Undo:** `firebase functions:delete deleteMyAccount --region australia-southeast1`. This leaves the other functions alone. The app button then says to email contact@logm8.com.au.
