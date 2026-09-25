import 'dart:math' as math;

import 'package:flutter/material.dart' show MaterialPageRoute;
import 'package:flutter/widgets.dart';

import '../../app_controller.dart';
import '../../core/format.dart';
import '../../core/recording_file.dart';
import '../app_scope.dart';
import '../icons/app_icons.dart';
import '../spec.dart';
import '../widgets/frame.dart';
import '../widgets/recorder_widgets.dart';
import '../widgets/red_bars.dart';
import '../widgets/toast.dart';
import 'common_actions.dart';

class RecordingListScreen extends StatefulWidget {
  const RecordingListScreen({super.key, this.initialSelection});

  /// Id of the row to select when the screen opens (used by tests).
  final String? initialSelection;

  static Route<void> route() =>
      MaterialPageRoute<void>(builder: (_) => const RecordingListScreen());

  @override
  State<RecordingListScreen> createState() => _RecordingListScreenState();
}

class _RecordingListScreenState extends State<RecordingListScreen>
    with WidgetsBindingObserver {
  String? _selected;
  late AppController _app;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _selected = widget.initialSelection;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _app = AppScope.read(context);
    if (!_loaded) {
      _loaded = true;
      _app.refreshFiles();
      // Android: until a folder is chosen there is nothing to list, and old
      // recordings would look lost. Ask for it (this also refreshes the list).
      if (!_app.store.isReady) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) showChooseFolderDialog(context);
        });
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Files may have been added or removed by other apps meanwhile.
    if (state == AppLifecycleState.resumed) _app.refreshFiles();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  RecordingFile? _selectedFile(List<RecordingFile> files) {
    for (final f in files) {
      if (f.id == _selected) return f;
    }
    return null;
  }

  Future<void> _withSelection(
    Future<void> Function(RecordingFile f) action,
  ) async {
    final f = _selectedFile(_app.files);
    if (f == null) {
      showToast(context, 'Please select a file');
      return;
    }
    await action(f);
  }

  Future<void> _play(RecordingFile f) async {
    final outcome = await _app.togglePlay(f);
    if (mounted) showPlayProblem(context, outcome);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final files = app.files;
    final width = MediaQuery.sizeOf(context).width;

    return ScreenFrame(
      child: Column(
        children: [
          RedHeader(
            title: 'Recording list',
            children: [
              BarButton(
                center: const Offset(18.26, 23.14),
                semanticLabel: 'Back',
                onTap: () => Navigator.of(context).maybePop(),
                child: const InkIcon(
                  AppIcons.back,
                  size: Size(13.7, 26.3),
                  color: Color(0xFFFFFFFF),
                ),
              ),
            ],
          ),
          Expanded(
            child: BrushedMetal(
              child: ListView.builder(
                padding: const EdgeInsets.only(top: Spec.listTopGap),
                itemCount: files.length,
                itemBuilder: (context, i) {
                  final f = files[i];
                  return _RecordingRow(
                    key: ValueKey(f.id),
                    file: f,
                    selected: f.id == _selected,
                    onSelect: () => setState(() => _selected = f.id),
                    onPlay: () {
                      setState(() => _selected = f.id);
                      if (app.isRecording) {
                        showToast(context, 'Stop recording to play a file');
                        return;
                      }
                      _play(f);
                    },
                  );
                },
              ),
            ),
          ),
          RedFooter(
            height: Spec.actionBarHeight,
            cells: [
              _FooterIcon(
                icon: AppIcons.trash,
                size: const Size(28.6, 34.3),
                semanticLabel: 'Delete',
                onTap: () => _withSelection((f) async {
                  if (await deleteRecording(context, f) && mounted) {
                    setState(() => _selected = null);
                  }
                }),
              ),
              _FooterIcon(
                icon: AppIcons.pencil,
                size: const Size(32.9, 32.9),
                semanticLabel: 'Rename',
                onTap: () => _withSelection((f) async {
                  final renamed = await renameRecording(context, f);
                  if (renamed != null && mounted) {
                    setState(() => _selected = renamed.id);
                  }
                }),
              ),
              _FooterIcon(
                icon: AppIcons.share,
                size: const Size(26.9, 27.1),
                semanticLabel: 'Share',
                onTap: () => _withSelection((f) {
                  final bottom =
                      MediaQuery.sizeOf(context).height -
                      MediaQuery.viewPaddingOf(context).bottom;
                  final origin = Rect.fromLTWH(
                    width * 2 / 3,
                    bottom - Spec.actionBarHeight,
                    width / 3,
                    Spec.actionBarHeight,
                  );
                  return shareRecording(context, f, origin: origin);
                }),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FooterIcon extends StatelessWidget {
  const _FooterIcon({
    required this.icon,
    required this.size,
    required this.onTap,
    this.semanticLabel,
  });

  final IconShape icon;
  final Size size;
  final VoidCallback onTap;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return PressableArea(
      onTap: onTap,
      semanticLabel: semanticLabel,
      highlight: const Color(0x26FFFFFF),
      child: LayoutBuilder(
        builder: (context, c) => Stack(
          children: [
            Positioned(
              left: (c.maxWidth - size.width) / 2,
              top: Spec.actionIconCenterY - size.height / 2,
              child: InkIcon(icon, size: size, color: const Color(0xFFFFFFFF)),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecordingRow extends StatelessWidget {
  const _RecordingRow({
    super.key,
    required this.file,
    required this.selected,
    required this.onSelect,
    required this.onPlay,
  });

  final RecordingFile file;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final playing = app.playback.isPlaying(file.id);
    final lineBox = AText.boxHeight(context, Spec.listName);
    final topPart = Spec.listRowPadding * 2 + lineBox * 2 + Spec.listLineGap;

    final info = SizedBox(
      height: topPart,
      child: Stack(
        children: [
          Positioned(
            left: Spec.listPlayIconLeft,
            top: (topPart - Spec.listPlayCanvas.height) / 2,
            child: GlossyButton(
              asset: playing
                  ? 'assets/images/list_pause.png'
                  : 'assets/images/list_play.png',
              size: Spec.listPlayCanvas,
              semanticLabel: playing
                  ? 'Pause ${file.name}'
                  : 'Play ${file.name}',
              onTap: onPlay,
            ),
          ),
          Positioned(
            left: Spec.listTextLeft,
            right: Spec.listTextRight,
            top: Spec.listRowPadding,
            child: AText(
              file.name,
              style: Spec.listName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Positioned(
            left: Spec.listTextLeft,
            right: Spec.listTextRight,
            top: Spec.listRowPadding + lineBox + Spec.listLineGap,
            child: Row(
              children: [
                AText(
                  formatListDate(file.date),
                  style: Spec.listDetail,
                  maxLines: 1,
                ),
                const Spacer(),
                AText(
                  formatListSize(file.size),
                  style: Spec.listDetail,
                  maxLines: 1,
                ),
              ],
            ),
          ),
        ],
      ),
    );

    return Column(
      children: [
        PressableArea(
          onTap: onSelect,
          semanticLabel: file.name,
          child: Container(
            color: selected ? Spec.listSelected : null,
            child: Column(
              children: [
                info,
                if (selected) _SeekSection(file: file),
              ],
            ),
          ),
        ),
        Container(
          height: 1 / MediaQuery.devicePixelRatioOf(context),
          color: Spec.listDivider,
        ),
      ],
    );
  }
}

/// Seek bar and position shown under the selected row.
class _SeekSection extends StatefulWidget {
  const _SeekSection({required this.file});

  final RecordingFile file;

  @override
  State<_SeekSection> createState() => _SeekSectionState();
}

class _SeekSectionState extends State<_SeekSection> {
  /// Where the thumb is while the user drags it (0..1).
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final loaded = app.playback.fileId == widget.file.id;
    final position = loaded ? app.playback.position : Duration.zero;
    final duration = loaded ? app.playback.duration : Duration.zero;
    final progress =
        _drag ??
        (duration.inMilliseconds <= 0
            ? 0.0
            : (position.inMilliseconds / duration.inMilliseconds).clamp(
                0.0,
                1.0,
              ));
    final shown = _drag != null && duration > Duration.zero
        ? duration * _drag!
        : position;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // measured from the date line; the row's bottom padding is above us
        const SizedBox(height: Spec.seekTopGap - Spec.listRowPadding),
        SizedBox(
          height: Spec.seekHeight,
          child: HoloSeekBar(
            progress: progress,
            onChanged: (p) => setState(() => _drag = p),
            onChangeEnd: (p) async {
              setState(() => _drag = null);
              if (app.isRecording) {
                showToast(context, 'Stop recording to play a file');
                return;
              }
              if (!await app.seek(widget.file, p) && context.mounted) {
                showToast(context, "Can't play this file");
              }
            },
          ),
        ),
        const SizedBox(height: Spec.seekTimeGap),
        Padding(
          padding: const EdgeInsets.only(left: Spec.seekTimeLeft),
          child: AText(
            formatPosition(shown),
            style: Spec.listName,
            maxLines: 1,
          ),
        ),
      ],
    );
  }
}

/// Holo-style seek bar: thin dark track, blue thumb with a translucent halo.
class HoloSeekBar extends StatefulWidget {
  const HoloSeekBar({
    super.key,
    required this.progress,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final double progress;

  /// The thumb moved (while dragging).
  final ValueChanged<double> onChanged;

  /// The user let go (or tapped): seek here.
  final ValueChanged<double> onChangeEnd;

  @override
  State<HoloSeekBar> createState() => _HoloSeekBarState();
}

class _HoloSeekBarState extends State<HoloSeekBar> {
  double? _last;

  void _move(double p) => widget.onChanged(_last = p);

  void _end() {
    final p = _last;
    _last = null;
    if (p != null) widget.onChangeEnd(p);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final start = Spec.seekStart;
        final end = c.maxWidth - Spec.seekEndFromRight;
        double at(Offset p) =>
            ((p.dx - start) / math.max(1, end - start)).clamp(0.0, 1.0);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) => widget.onChangeEnd(at(d.localPosition)),
          onHorizontalDragStart: (d) => _move(at(d.localPosition)),
          onHorizontalDragUpdate: (d) => _move(at(d.localPosition)),
          onHorizontalDragEnd: (_) => _end(),
          onHorizontalDragCancel: _end,
          child: CustomPaint(
            size: Size(c.maxWidth, Spec.seekHeight),
            painter: _SeekPainter(widget.progress, start, end),
          ),
        );
      },
    );
  }
}

class _SeekPainter extends CustomPainter {
  _SeekPainter(this.progress, this.start, this.end);

  final double progress;
  final double start;
  final double end;

  @override
  void paint(Canvas canvas, Size size) {
    final cy = size.height / 2;
    canvas.drawRect(
      Rect.fromLTRB(
        start,
        cy - Spec.seekTrackHeight / 2,
        end,
        cy + Spec.seekTrackHeight / 2,
      ),
      Paint()..color = Spec.seekTrack,
    );
    final x = start + (end - start) * progress;
    canvas
      ..drawCircle(
        Offset(x, cy),
        Spec.seekThumbHalo / 2,
        Paint()..color = Spec.holoBlue.withValues(alpha: 0.6),
      )
      ..drawCircle(
        Offset(x, cy),
        Spec.seekThumbDot / 2,
        Paint()..color = Spec.holoBlue,
      );
  }

  @override
  bool shouldRepaint(_SeekPainter old) =>
      old.progress != progress || old.start != start || old.end != end;
}
