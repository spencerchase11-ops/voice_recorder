import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'ui/app_scope.dart';
import 'ui/screens/recorder_screen.dart';
import 'ui/spec.dart';

class VoiceRecorderApp extends StatelessWidget {
  const VoiceRecorderApp({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
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
