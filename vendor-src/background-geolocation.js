// JS bridge to the native @capacitor-community/background-geolocation plugin (the package ships
// no JS layer; its README registers the proxy directly). Native trip GPS keeps recording with the
// screen locked: Android foreground service (notification "Trip in progress"), iOS background location.
import { registerPlugin } from '@capacitor/core';

export const BackgroundGeolocation = registerPlugin('BackgroundGeolocation');
export default BackgroundGeolocation;
