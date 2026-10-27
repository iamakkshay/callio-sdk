Pod::Spec.new do |s|
  s.name             = 'incall_flutter'
  s.version          = '0.2.1'
  s.summary          = 'Flutter wrapper for the Callio iOS SDK.'
  s.description       = 'In-app voice calling, chat and live location over SIP and WebRTC.'
  s.homepage         = 'https://github.com/iamakkshay/callio-sdk'
  s.license          = { :type => 'Proprietary', :file => '../LICENSE' }
  s.author           = { 'Clarigo Infotech' => 'https://github.com/iamakkshay/callio-sdk' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.dependency 'InCallSDK', '0.2.1'
  s.platform = :ios, '15.0'
  s.swift_version = '5.8'
end
