#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint audioplayers.podspec' to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'audioplayers_darwin'
  s.version          = '0.0.1'
  s.summary          = 'Flutter Audioplayers Plugin'
  s.description      = 'Darwin implementation of audioplayers, a Flutter plugin to play multiple audio files simultaneously.'
  s.homepage         = 'https://github.com/bluefireteam/audioplayers'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'Blue Fire' => 'contact@blue-fire.xyz' }
  s.source           = { :path => '.' }
  s.documentation_url = 'https://pub.dev/packages/audioplayers'
  # Swift plugin sources plus the Objective-C++ pitch bridge
  # (Sources/SignalsmithBridge/SignalsmithProcessor.{h,mm}). CocoaPods
  # compiles both into the one plugin module, so Swift sees the bridge header
  # via the umbrella (no import needed). The vendored Signalsmith headers are
  # NOT globbed as sources — they are reached via HEADER_SEARCH_PATHS below
  # and kept in the pod tree via preserve_paths.
  s.source_files = 'audioplayers_darwin/Sources/audioplayers_darwin/**/*.swift',
                   'audioplayers_darwin/Sources/SignalsmithBridge/SignalsmithProcessor.mm',
                   'audioplayers_darwin/Sources/SignalsmithBridge/include/SignalsmithProcessor.h'
  s.public_header_files = 'audioplayers_darwin/Sources/SignalsmithBridge/include/SignalsmithProcessor.h'
  s.preserve_paths = 'audioplayers_darwin/Sources/SignalsmithBridge/vendor/**/*'
  # MTAudioProcessingTap (metronome click track) lives in MediaToolbox.
  s.frameworks = 'MediaToolbox'
  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'
  s.ios.deployment_target = '13.0'
  s.osx.deployment_target = '10.15'

  # Flutter.framework does not contain a i386 slice.
  # Signalsmith Stretch is header-only C++ (compiled via the .mm bridge):
  # build the .mm as C++17 and point it at the vendored headers. `vendor`
  # resolves `signalsmith-stretch/signalsmith-stretch.h`, which transitively
  # pulls `signalsmith-linear/stft.h` and `./fft.h` from the same root.
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'gnu++17',
    'CLANG_CXX_LIBRARY' => 'libc++',
    'HEADER_SEARCH_PATHS' => '"$(PODS_TARGET_SRCROOT)/audioplayers_darwin/Sources/SignalsmithBridge/vendor"'
  }
end
