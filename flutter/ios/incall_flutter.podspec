#
# incall_flutter iOS plugin. It depends on the native Callio iOS SDK (InCallSDK, with the WebRTC media layer
# and CallKit / PushKit). InCallSDK is not on the CocoaPods trunk, so the host app's ios/Podfile says where it
# comes from, inside `target 'Runner' do`:
#
#   pod 'InCallSDK', :git => 'https://github.com/iamakkshay/callio-sdk.git', :tag => '0.3.3'   # released SDK
#   pod 'InCallSDK', :path => '<path to this repo>/sdk/ios'                                     # in-repo sources
#
Pod::Spec.new do |s|
  s.name             = 'incall_flutter'
  s.version          = '0.3.3'
  s.summary          = 'Callio in-app calling, chat and location for Flutter (iOS side).'
  s.description      = 'Flutter bridge to the native Callio iOS SDK: calls over SIP and WebRTC with CallKit, chat and location.'
  s.homepage         = 'https://github.com/iamakkshay/callio-sdk'
  s.license          = { :type => 'Proprietary' }
  s.author           = { 'Clarigo Infotech' => 'https://github.com/iamakkshay/callio-sdk' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.dependency 'InCallSDK', s.version.to_s
  s.platform         = :ios, '15.0'
  s.frameworks       = 'AVFoundation'
  s.swift_version    = '5.8'
  # Flutter.framework does not contain an i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
end
