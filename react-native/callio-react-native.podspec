require 'json'
# The native Callio iOS SDK (pod 'InCallSDK') is NOT published on the CocoaPods trunk, so `pod install` must not
# look it up there: pin its source in the app's ios/Podfile, inside the app target, before use_native_modules!:
#
#   pod 'InCallSDK', :git => 'https://github.com/iamakkshay/callio-sdk.git', :tag => '0.3.1'
#
# A dependency in a podspec can't name a git source, so the exact version below is matched against that pin.
package = JSON.parse(File.read(File.join(__dir__, 'package.json')))

Pod::Spec.new do |s|
  s.name         = 'callio-react-native'
  s.version      = package['version']
  s.summary      = package['description']
  s.homepage     = 'https://github.com/iamakkshay/callio-sdk'
  s.license      = { :type => 'Proprietary', :file => 'LICENSE' }
  s.authors      = 'Clarigo Infotech'
  s.platforms    = { :ios => '15.0' }
  s.source       = { :path => '.' }
  s.source_files = 'ios/**/*.{swift,m}'
  s.swift_version = '5.9'
  s.dependency 'React-Core'
  s.dependency 'InCallSDK', '0.3.1'   # exact; its source must be pinned in the Podfile (see the top of this file)
end
