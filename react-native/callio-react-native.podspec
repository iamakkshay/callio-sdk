require 'json'
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
  s.dependency 'InCallSDK', '~> 0.2.3'
end
