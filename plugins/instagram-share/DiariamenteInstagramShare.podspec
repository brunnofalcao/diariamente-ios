require 'json'

package = JSON.parse(File.read(File.join(__dir__, 'package.json')))

# O nome do pod TEM de ser este: o @capacitor/cli gera a linha do Podfile com o
# nome do pacote npm convertido (diariamente-instagram-share -> DiariamenteInstagramShare).
Pod::Spec.new do |s|
  s.name = 'DiariamenteInstagramShare'
  s.version = package['version']
  s.summary = package['description']
  s.license = { :type => 'Proprietary', :text => 'Uso exclusivo do app Diariamente.' }
  s.homepage = 'https://github.com/brunnofalcao/diariamente-ios'
  s.author = package['author']
  s.source = { :git => 'https://github.com/brunnofalcao/diariamente-ios.git', :tag => s.version.to_s }
  s.source_files = 'ios/Sources/**/*.{swift,h,m}'
  s.ios.deployment_target = '14.0'
  s.frameworks = 'Photos'
  s.dependency 'Capacitor'
  s.swift_version = '5.1'
end
