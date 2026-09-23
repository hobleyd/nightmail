Pod::Spec.new do |s|
  s.name             = 'html_view'
  s.version          = '0.1.0'
  s.summary          = 'Cross-platform HTML/CSS3 widget using native browser engines.'
  s.description      = 'WKWebView-backed HTML widget for iOS.'
  s.homepage         = 'https://github.com/nightmail/html_view'
  s.license          = { :type => 'MIT' }
  s.author           = { 'NightMail' => 'dev@nightmail.com.au' }
  s.source           = { :path => '.' }
  s.source_files     = 'html_view/Sources/html_view/**/*.swift'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386'
  }
  s.swift_version = '5.0'
end
