Pod::Spec.new do |s|
  s.name          = 'InCallUI'
  s.version       = File.read(File.join(__dir__, 'VERSION')).strip
  s.summary       = 'Ready-made SwiftUI call and chat screens for the Callio iOS SDK.'
  s.description   = 'Themeable SwiftUI screens for Callio: call screen, incoming call and chat with location cards, in English and Arabic.'
  s.homepage      = 'https://github.com/iamakkshay/callio-sdk'
  s.license       = { :type => 'Proprietary', :file => 'LICENSE' }
  s.author        = { 'Clarigo Infotech' => 'https://github.com/iamakkshay/callio-sdk' }
  s.source        = { :git => 'https://github.com/iamakkshay/callio-sdk.git', :tag => s.version.to_s }
  s.platform      = :ios, '15.0'
  s.swift_version = '5.8'
  s.source_files  = 'ios/Sources/InCallUI/**/*.swift'
  s.dependency 'InCallSDK', s.version.to_s
end
