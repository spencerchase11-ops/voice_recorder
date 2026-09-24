import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../app_controller.dart';
import '../../core/format.dart';
import '../app_scope.dart';
import '../dialogs/dialogs.dart';
import '../icons/app_icons.dart';
import '../spec.dart';
import '../widgets/frame.dart';
import '../widgets/recorder_widgets.dart';
import '../widgets/red_bars.dart';
import '../widgets/toast.dart';
import 'common_actions.dart';
import 'recording_list_screen.dart';
import 'settings_screen.dart';

class RecorderScreen extends StatefulWidget {
  const RecorderScreen({super.key});

  @override
  State<RecorderScreen> createState() => _RecorderScreenState();
}

class _RecorderScreenState extends State<RecorderScreen> {
  StreamSubscription<String>? _notices;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The Recorder is the root screen, so it is always there to show what
    // the app did on its own (e.g. a recording stopped because storage ran
    // out), whichever screen is on top.
    _notices ??= AppScope.read(context).notices.listen((message) {
      if (mounted) showToast(context, message, long: true);
    });
  }

  @override
  void dispose() {
    _notices?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final cur = app.currentFile;
    final canAct = cur != null && !app.isRecording;

    return ScreenFrame(
      child: Column(
        children: [
          // Without a recording the original shows the app name and no file
          // actions.
          RedHeader(
            title: cur == null ? 'Voice Recorder' : 'Recorder',
            children: [
              if (cur != null) ...[
                BarButton(
                  center: const Offset(22.86, 24.0),
                  semanticLabel: 'Share',
                  onTap: canAct ? () => shareRecording(context, cur) : null,
                  child: const InkIcon(
                    AppIcons.share,
                    size: Size(22.9, 22.9),
                    color: Color(0xFFFFFFFF),
                  ),
                ),
                BarButton(
                  center: Offset(width - 77.0, 23.0),
                  semanticLabel: 'Rename',
                  onTap: canAct ? () => renameRecording(context, cur) : null,
                  child: const InkIcon(
                    AppIcons.pencil,
                    size: Size(23.7, 23.7),
                    color: Color(0xFFFFFFFF),
                  ),
                ),
                BarButton(
                  center: Offset(width - 26.0, 23.43),
                  semanticLabel: 'Delete',
                  onTap: canAct ? () => deleteRecording(context, cur) : null,
                  child: const InkIcon(
                    AppIcons.trash,
                    size: Size(20.6, 24.6),
                    color: Color(0xFFFFFFFF),
                  ),
                ),
              ],
            ],
          ),
          const Expanded(child: BrushedMetal(child: _RecorderBody())),
          RedFooter(
            height: Spec.tabBarHeight,
            cells: [
              const _Tab(
                label: 'Recorder',
                icon: AppIcons.mic,
                iconSize: Size(20.3, 33.7),
                selected: true,
              ),
              _Tab(
                label: 'Recording list',
                icon: AppIcons.list,
                iconSize: const Size(32.3, 32.9),
                onTap: () =>
                    Navigator.of(context).push(RecordingListScreen.route()),
              ),
              _Tab(
                label: 'Settings',
                icon: AppIcons.gear,
                iconSize: const Size(32.6, 32.6),
                onTap: () => Navigator.of(context).push(SettingsScreen.route()),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RecorderBody extends StatelessWidget {
  const _RecorderBody();

  Future<void> _record(BuildContext context) async {
    final app = AppScope.read(context);
    var outcome = await app.toggleRecord();
    if (!context.mounted) return;
    if (outcome == RecordOutcome.needsFolder) {
      final ok = await showChooseFolderDialog(context);
      if (!ok || !context.mounted) return;
      outcome = await app.toggleRecord();
      if (!context.mounted) return;
    }
    switch (outcome) {
      case RecordOutcome.noPermission:
        final open = await showSpecDialog<bool>(
          context,
          (ctx) => HoloDialog(
            title: 'Recorder',
            message:
                'Voice Recorder needs access to the microphone. Allow it in '
                'Settings, then try again.',
            buttons: [
              HoloButton('Cancel', onTap: () => Navigator.of(ctx).pop(false)),
              HoloButton('Settings', onTap: () => Navigator.of(ctx).pop(true)),
            ],
          ),
        );
        if (open == true) await app.openAppSettings();
      case RecordOutcome.notSaved:
        // The file is kept in the app and saved once the folder works again.
        if (!app.store.isReady) {
          await showChooseFolderDialog(
            context,
            reason: "The recording couldn't be saved to the folder.",
          );
        } else {
          showToast(
            context,
            "The recording couldn't be saved. It will be saved the next time "
            'the app starts.',
          );
        }
      case RecordOutcome.noSpace:
        showToast(context, 'Not enough storage left to record');
      case RecordOutcome.failed:
        showToast(context, 'Recording failed');
      case RecordOutcome.needsFolder:
      case RecordOutcome.started:
      case RecordOutcome.stopped:
      case RecordOutcome.busy:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final remaining = app.remaining;
    final path = app.currentPath;

    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        final h = c.maxHeight;
        final boxCenterY = h / 2 + Spec.timerCenterOffset;
        final boxTop = boxCenterY - Spec.timerBoxHeight / 2;
        final buttonsY = boxCenterY + Spec.buttonsCenterOffset;

        // The microphone sits on the timer box; shrink it on short screens so it
        // keeps a small margin below the header.
        const micTopLimit = Spec.microphoneTopMargin;
        final micBottom = boxTop - Spec.microphoneGap;
        final micScale = math.min(
          1.0,
          math.max(0.3, (micBottom - micTopLimit) / Spec.microphoneSize.height),
        );
        final micSize = Spec.microphoneSize * micScale;

        final meterTop = boxTop + Spec.timerBoxHeight + Spec.meterTopGap;
        final remainingTop =
            meterTop + Spec.meterSquareHeight + Spec.remainingTopGap;

        return Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: (w - micSize.width) / 2 + Spec.microphoneOffsetX,
              top: micBottom - micSize.height,
              width: micSize.width,
              height: micSize.height,
              child: _Microphone(
                recording: app.isRecording && !app.isInterrupted,
              ),
            ),
            Positioned(
              left: (w - Spec.timerBoxWidth) / 2,
              top: boxTop,
              child: TimerBox(text: formatTimer(app.timerValue)),
            ),
            Positioned(
              left:
                  Spec.recordCenterFromLeft - Spec.recordButtonCanvas.width / 2,
              top: buttonsY - Spec.recordButtonCanvas.height / 2,
              child: GlossyButton(
                asset: app.isRecording
                    ? 'assets/images/record_stop.png'
                    : 'assets/images/record.png',
                size: Spec.recordButtonCanvas,
                semanticLabel: app.isRecording ? 'Stop recording' : 'Record',
                onTap: app.isBusy ? null : () => _record(context),
              ),
            ),
            Positioned(
              left:
                  w -
                  Spec.playCenterFromRight -
                  Spec.playButtonCanvas.width / 2,
              top: buttonsY - Spec.playButtonCanvas.height / 2,
              child: GlossyButton(
                asset: app.isPlayingCurrent
                    ? 'assets/images/pause.png'
                    : 'assets/images/play.png',
                disabledAsset: 'assets/images/play_disabled.png',
                size: Spec.playButtonCanvas,
                semanticLabel: app.isPlayingCurrent ? 'Pause' : 'Play',
                onTap: app.currentFile == null || app.isRecording
                    ? null
                    : () async {
                        if (!await app.togglePlayCurrent() && context.mounted) {
                          showToast(context, "Can't play this file");
                        }
                      },
              ),
            ),
            Positioned(
              left: (w - LevelMeter.width) / 2,
              top: meterTop,
              child: LevelMeter(lit: app.litSegments),
            ),
            if (remaining != null)
              Positioned(
                left: 0,
                right: 0,
                top: remainingTop,
                child: AText(
                  'Remaining time: ${formatRemaining(remaining)}',
                  style: Spec.remainingText,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                ),
              ),
            if (path != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Row(
                  children: [
                    const SizedBox(
                      width: Spec.pathTextLeft,
                      child: Padding(
                        padding: EdgeInsets.only(
                          left: Spec.pathIconCenterX - Spec.pathIconSize / 2,
                        ),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: InkIcon(
                            AppIcons.floppy,
                            size: Size.square(Spec.pathIconSize),
                            color: Color(0xFFFFFFFF),
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(right: 16),
                        child: AText(
                          path,
                          style: Spec.pathText,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

/// The chrome microphone; its red dot glows while recording.
class _Microphone extends StatefulWidget {
  const _Microphone({required this.recording});

  final bool recording;

  @override
  State<_Microphone> createState() => _MicrophoneState();
}

class _MicrophoneState extends State<_Microphone>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  );

  @override
  void initState() {
    super.initState();
    if (widget.recording) _pulse.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(_Microphone old) {
    super.didUpdateWidget(old);
    if (widget.recording && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!widget.recording && _pulse.isAnimating) {
      _pulse
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        // red dot centre in the artwork, as a fraction of the canvas
        final dot = Offset(c.maxWidth * (257 / 518), c.maxHeight * (428 / 886));
        final r = c.maxWidth * (30 / 518);
        return Stack(
          fit: StackFit.expand,
          children: [
            Image.asset(
              Spec.microphone,
              fit: BoxFit.fill,
              filterQuality: FilterQuality.medium,
            ),
            if (widget.recording)
              AnimatedBuilder(
                animation: _pulse,
                builder: (context, _) => CustomPaint(
                  painter: _GlowPainter(dot, r, 0.25 + 0.75 * _pulse.value),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _GlowPainter extends CustomPainter {
  _GlowPainter(this.center, this.radius, this.t);

  final Offset center;
  final double radius;
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawCircle(
      center,
      radius * 2.2,
      Paint()
        ..shader = RadialGradient(
          colors: [
            const Color(0xFFFF3B30).withValues(alpha: 0.55 * t),
            const Color(0xFFFF3B30).withValues(alpha: 0),
          ],
        ).createShader(Rect.fromCircle(center: center, radius: radius * 2.2)),
    );
  }

  @override
  bool shouldRepaint(_GlowPainter old) => old.t != t;
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.label,
    required this.icon,
    required this.iconSize,
    this.selected = false,
    this.onTap,
  });

  final String label;
  final IconShape icon;
  final Size iconSize;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return PressableArea(
      onTap: onTap,
      semanticLabel: label,
      highlight: const Color(0x26FFFFFF),
      child: LayoutBuilder(
        builder: (context, c) {
          return Stack(
            children: [
              Positioned(
                left: (c.maxWidth - iconSize.width) / 2,
                top: Spec.tabIconCenterY - iconSize.height / 2,
                child: InkIcon(
                  icon,
                  size: iconSize,
                  color: selected
                      ? Spec.tabSelectedIcon
                      : const Color(0xFFFFFFFF),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0.4,
                child: AText(
                  label,
                  style: Spec.tabLabel.copyWith(
                    color: selected ? Spec.tabSelectedLabel : null,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
