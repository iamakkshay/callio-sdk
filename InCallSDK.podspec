Pod::Spec.new do |s|
  s.name          = 'InCallSDK'
  s.version       = File.read(File.join(__dir__, 'VERSION')).strip
  s.summary       = 'Callio in-app voice calling, chat and live location for iOS.'
  s.description   = 'Native iOS SDK for the Callio platform: calls over SIP and WebRTC with CallKit, chat, and live location, without sharing phone numbers.'
  s.homepage      = 'https://github.com/iamakkshay/callio-sdk'
  s.license       = { :type => 'Proprietary', :file => 'LICENSE' }
  s.author        = { 'Clarigo Infotech' => 'https://github.com/iamakkshay/callio-sdk' }
  s.source        = { :git => 'https://github.com/iamakkshay/callio-sdk.git', :tag => s.version.to_s }
  s.platform      = :ios, '15.0'
  s.swift_version = '5.8'
  s.source_files  = 'ios/Sources/InCallSDK/**/*.swift'
  s.frameworks    = 'AVFoundation', 'CallKit', 'PushKit'
  s.dependency 'WebRTC-lib', '155.0.0'
end
