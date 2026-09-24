#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint lame_mp3.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'lame_mp3'
  s.version          = '0.1.0'
  s.summary          = 'MP3 encoding for Flutter through dart:ffi, using the LAME 4.0 encoder.'
  s.description      = <<-DESC
Flutter FFI plugin that bundles the LAME 4.0 MP3 encoder library (libmp3lame,
LGPL-2.0-or-later) and a small C wrapper (MIT) that the Dart code calls
through dart:ffi. Only the wrapper's functions are exported.
                       DESC
  s.homepage         = 'https://github.com/spencerchase11-ops/voice_recorder'
  s.license          = { :type => 'MIT AND LGPL-2.0-or-later', :file => '../LICENSE' }
  s.author           = { 'voice_recorder contributors' => 'https://github.com/spencerchase11-ops/voice_recorder' }

  # This will ensure the source files in Classes/ are included in the native
  # builds of apps using this FFI plugin. Podspec does not support relative
  # paths, so Classes contains forwarder C files that relatively import
  # `../src/*` so that the C sources can be shared among all target platforms:
  # one forwarder per compilation unit (LAME's .c files must not be merged
  # into one unit: they define static symbols with the same names).
  # No header is part of the pod, so none of LAME's headers becomes a public
  # or module header.
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '15.0'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    # Flutter.framework does not contain a i386 slice.
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    # <config.h> (LAME's build configuration), lame.h, LAME's private headers.
    'HEADER_SEARCH_PATHS' => '$(inherited) ' \
      '"${PODS_TARGET_SRCROOT}/../src/lame" ' \
      '"${PODS_TARGET_SRCROOT}/../src/lame/include" ' \
      '"${PODS_TARGET_SRCROOT}/../src/lame/libmp3lame"',
    # Resolve LAME's generic header names (config.h, util.h, version.h, ...)
    # only through the paths above, never through Xcode's header maps of
    # other targets.
    'USE_HEADERMAP' => 'NO',
    # NDEBUG: LAME's assert()s are compiled out, as in the Android build.
    'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) HAVE_CONFIG_H=1 NDEBUG=1',
    # Export only the wrapper's FFI_PLUGIN_EXPORT functions.
    'GCC_SYMBOLS_PRIVATE_EXTERN' => 'YES',
    # Always optimise (also in Debug builds), as on Android: LAME at -O0 is
    # several times slower.
    'GCC_OPTIMIZATION_LEVEL' => '2',
    # LAME is third-party C code written for much older compilers.
    'GCC_WARN_INHIBIT_ALL_WARNINGS' => 'YES',
  }
  s.swift_version = '5.0'
end
