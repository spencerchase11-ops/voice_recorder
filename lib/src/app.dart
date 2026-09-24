import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'ui/app_scope.dart';
import 'ui/screens/recorder_screen.dart';
import 'ui/spec.dart';

class VoiceRecorderApp extends StatefulWidget {
  const VoiceRecorderApp({super.key, required this.controller});

  final AppController controller;

  @override
  State<VoiceRecorderApp> createState() => _VoiceRecorderAppState();
}

class _VoiceRecorderAppState extends State<VoiceRecorderApp> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // Files can change while the app is in the background (Files app, another
    // recorder, a file manager), and so can the free space.
    _lifecycle = AppLifecycleListener(onResume: widget.controller.onResume);
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
