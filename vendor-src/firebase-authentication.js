// Thin JS bridge to the native @capacitor-firebase/authentication plugin.
// We only need the native methods (Google Sign-In returns an ID token that the
// Firebase JS SDK inside the web app then uses with signInWithCredential), so we
// register the plugin proxy directly instead of bundling the plugin's web layer.
import { registerPlugin } from '@capacitor/core';

export const FirebaseAuthentication = registerPlugin('FirebaseAuthentication');
export default FirebaseAuthentication;
