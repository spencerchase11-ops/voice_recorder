import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_controller.dart';
import 'ui/app_scope.dart';
import 'ui/screens/recorder_screen.dart';
import 'ui/spec.dart';

/// Portrait only, drawn edge to edge (the screens paint the system bars).
Future<void> applySystemUi() async {
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
}

class VoiceRecorderApp extends StatefulWidget {
  const VoiceRecorderApp({super.key, required this.controller});

  final AppController controller;

  @override
  State<VoiceRecorderApp> createState() => _VoiceRecorderAppState();
}

class _VoiceRecorderAppState extends State<VoiceRecorderApp> {
  final _navigator = GlobalKey<NavigatorState>();
  late final AppLifecycleListener _lifecycle;
  bool _detached = false;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onDetach: () => _detached = true,
      onResume: _onResume,
    );
  }

  void _onResume() {
    if (_detached) {
      // Android: the engine outlives its activity (a recording keeps running
      // after Back or a swipe from Recents). A new activity starts with
      // default system settings, so apply ours again.
      _detached = false;
      applySystemUi();
      SystemNavigator.setFrameworkHandlesBack(
        _navigator.currentState?.canPop() ?? false,
      );
    }
    // Files can change while the app is in the background (Files app, another
    // recorder, a file manager), and so can the free space.
    widget.controller.onResume();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return AppScope(
      controller: controller,
      child: MaterialApp(
        navigatorKey: _navigator,
        title: 'Voice Recorder',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          fontFamily: Spec.font,
          scaffoldBackgroundColor: const Color(0xFF000000),
          textSelectionTheme: const TextSelectionThemeData(
            cursorColor: Color(0xFF007AFF),
            selectionColor: Color(0x55007AFF),
            selectionHandleColor: Color(0xFF007AFF),
          ),
        ),
        home: const RecorderScreen(),
      ),
    );
  }
}
