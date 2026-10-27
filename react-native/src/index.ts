// @clarigoinfotech/callio-react-native: Callio calling, chat and location in React Native apps (FR-SDK-02).
//
//   import { InCall } from '@clarigoinfotech/callio-react-native';
//   await InCall.start({ baseUrl: 'https://api.example.sa', tokenProvider: () => myBackend.callioToken() });
//   InCall.on('incomingCall', ({ callId, from }) => showIncoming(from));
//   const call = await InCall.dial('1002');
import { NativeModules, NativeEventEmitter, Platform } from 'react-native';
import { InCallClient, type NativeInCall } from './core';

export * from './core';
export const SDK_VERSION = '0.2.1';

const native = NativeModules.CallioInCall as NativeInCall | undefined;
if (!native) {
  throw new Error(`@clarigoinfotech/callio-react-native: the native module isn't linked. ${Platform.OS === 'ios' ? 'Run `pod install` in ios/.' : 'Rebuild the Android app.'}`);
}

export const InCall = new InCallClient(native, new NativeEventEmitter(NativeModules.CallioInCall));
