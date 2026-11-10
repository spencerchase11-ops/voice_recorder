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
import '../widgets/red_bars.dart';
import '../widgets/toast.dart';
import 'common_actions.dart';

const _white = Color(0xFFFFFFFF);

/// The page's background: the usual brushed metal, darker.
const _darker = ColorFilter.matrix(<double>[
  Spec.pageBrightness, 0, 0, 0, 0, //
  0, Spec.pageBrightness, 0, 0, 0, //
  0, 0, Spec.pageBrightness, 0, 0, //
  0, 0, 0, 1, 0, //
]);

/// One recording on its own page, opened by tapping its row, as in the
/// original: its details, and a player that goes on to the list's previous
/// and next recordings.
class RecordingScreen extends StatefulWidget {
  const RecordingScreen({
    super.key,
    required this.file,
    this.order = const [],
    this.onShown,
    this.autoplay = true,
  });

  final RecordingFile file;

  /// The list's rows (their ids) in order, for previous and next.
  final List<String> order;

  /// Told which recording the page shows whenever that changes (previous,
  /// next, a rename), so the list can keep it selected.
  final ValueChanged<String>? onShown;

  /// Plays it on opening, as the original did.
  final bool autoplay;

  static Route<void> route({
    required RecordingFile file,
    List<String> order = const [],
    ValueChanged<String>? onShown,
  }) => MaterialPageRoute<void>(
    builder: (_) => RecordingScreen(file: file, order: order, onShown: onShown),
  );

  @override
  State<RecordingScreen> createState() => _RecordingScreenState();
}

class _RecordingScreenState extends State<RecordingScreen> {
  late String _id = widget.file.id;

  /// The recording shown as last known (kept if it goes away meanwhile).
  late RecordingFile _last = widget.file;
  late final List<String> _order = [...widget.order];

  /// A rename, share or delete is being carried out: more taps wait.
  bool _busy = false;

  /// Where the thumb is while the user drags it (0..1).
  double? _drag;

  /// A recording the page started that isn't playing yet (it may take a
  /// moment to load): previous and next count it as playing.
  String? _starting;

  final _shareKey = GlobalKey();

  // The app's files by id, worked out once per list (the page rebuilds many
  // times a second while it plays).
  List<RecordingFile>? _indexed;
  Map<String, RecordingFile> _byId = const {};

  @override
  void initState() {
    super.initState();
    if (widget.autoplay) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _playOnOpening();
      });
    }
  }

  RecordingFile? _lookUp(AppController app, String id) {
    final files = app.files;
    if (!identical(files, _indexed)) {
      _indexed = files;
      _byId = {for (final f in files) f.id: f};
    }
    return _byId[id];
  }

  /// The recording shown, as the app knows it now (its length may have been
  /// read meanwhile).
  RecordingFile _file(AppController app) => _last = _lookUp(app, _id) ?? _last;

  /// The nearest recording [step] rows away that is still there.
  RecordingFile? _neighbour(AppController app, int step) {
    final i = _order.indexOf(_id);
    if (i < 0) return null;
    for (var j = i + step; j >= 0 && j < _order.length; j += step) {
      final f = _lookUp(app, _order[j]);
      if (f != null) return f;
    }
    return null;
  }

  Future<void> _playOnOpening() async {
    final app = AppScope.read(context);
    if (app.isRecording || app.isBusy || app.playback.isPlaying(_id)) return;
    final outcome = await _start(app, _file(app));
    if (mounted) showPlayProblem(context, outcome);
  }

  /// Plays [file], counted as playing until it does (or fails).
  Future<PlayOutcome> _start(AppController app, RecordingFile file) async {
    _starting = file.id;
    try {
      return await app.togglePlay(file);
    } finally {
      // A later start replaces this one; it clears its own.
      if (_starting == file.id) _starting = null;
    }
  }

  /// The player reacts to a tap, not to a recording in progress (also while
  /// it starts or is being saved).
  bool _blocked(AppController app) {
    if (!app.isRecording && !app.isBusy) return false;
    showToast(context, "Can't play while recording");
    return true;
  }

  Future<void> _togglePlay(AppController app) async {
    if (_blocked(app)) return;
    final outcome = await app.togglePlay(_file(app));
    if (mounted) showPlayProblem(context, outcome);
  }

  Future<void> _skip(AppController app, Duration delta) async {
    if (_blocked(app)) return;
    if (!await app.skip(delta, file: _file(app)) && mounted) {
      showToast(context, "Can't play this recording");
    }
  }

  Future<void> _seek(AppController app, double fraction) async {
    if (_blocked(app)) return;
    if (!await app.seek(_file(app), fraction) && mounted) {
      showToast(context, "Can't play this recording");
    }
  }

  /// Shows the previous (-1) or next (1) recording; it plays if this one
  /// did.
  Future<void> _go(AppController app, int step) async {
    final to = _neighbour(app, step);
    if (to == null) return;
    final wasPlaying = app.playback.isPlaying(_id) || _starting == _id;
    setState(() {
      _id = to.id;
      _last = to;
      _drag = null;
    });
    widget.onShown?.call(to.id);
    if (!wasPlaying || app.isRecording || app.isBusy) return;
    final outcome = await _start(app, to);
    if (mounted) showPlayProblem(context, outcome);
  }

  /// Runs [action] unless another one is running.
  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    _busy = true;
    try {
      await action();
    } finally {
      _busy = false;
    }
  }

  Future<void> _rename(AppController app) => _run(() async {
    final file = _file(app);
    final renamed = await renameRecording(context, file);
    if (renamed == null) return;
    // The list keeps it open, also if the page has been closed meanwhile.
    widget.onShown?.call(renamed.id);
    if (!mounted) return;
    setState(() {
      final i = _order.indexOf(file.id);
      if (i >= 0) _order[i] = renamed.id;
      _id = renamed.id;
      _last = renamed;
    });
  });

  Future<void> _share(AppController app) => _run(() async {
    final box = _shareKey.currentContext?.findRenderObject() as RenderBox?;
    final origin = box == null || !box.hasSize
        ? null
        : box.localToGlobal(Offset.zero) & box.size;
    await shareRecordings(context, [_file(app)], origin: origin);
  });

  Future<void> _delete(AppController app) => _run(() async {
    if (!await deleteRecordings(context, [_file(app)]) || !mounted) return;
    // Closes this page only: Back may have closed it already while the
    // delete went on, and something may have opened above it.
    final route = ModalRoute.of(context);
    if (route == null || !route.isActive) return;
    if (route.isCurrent) {
      Navigator.of(context).pop();
    } else {
      Navigator.of(context).removeRoute(route);
    }
  });

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final file = _file(app);
    // The length (and a date stored in the file) are read when first shown.
    if (file.duration == null) app.requestInfo(file);
    final width = MediaQuery.sizeOf(context).width;
    return ScreenFrame(
      child: Column(
        children: [
          _header(app, width),
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                const ColorFiltered(
                  colorFilter: _darker,
                  child: BrushedMetal(),
                ),
                _details(app, file),
              ],
            ),
          ),
          // Inside the frame, which says how far it reaches under the home
          // indicator. The times grow no larger than Android's largest text
          // (2x): larger, they would reach up over the seek bar.
          MediaQuery.withClampedTextScaling(
            maxScaleFactor: 2,
            child: Builder(
              builder: (context) => _player(context, app, file, width),
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(AppController app, double width) {
    BarButton button(
      double fromRight,
      String label,
      IconShape icon,
      Size size,
      VoidCallback onTap, {
      Key? key,
    }) => BarButton(
      key: key,
      center: Offset(width - fromRight, Spec.pageIconCenterY),
      // As wide as the buttons are apart, so a tap goes to the nearest.
      touchSize: const Size(
        Spec.pageRenameFromRight - Spec.pageShareFromRight,
        Spec.headerHeight,
      ),
      semanticLabel: label,
      onTap: onTap,
      child: InkIcon(icon, size: size, color: _white),
    );

    return RedHeader(
      title: '',
      children: [
        BarButton(
          center: const Offset(18.26, 23.14),
          semanticLabel: 'Back',
          onTap: () => Navigator.of(context).maybePop(),
          child: const InkIcon(
            AppIcons.back,
            size: Size(13.7, 26.3),
            color: _white,
          ),
        ),
        Positioned(
          left: Spec.pageTitleLeft,
          right: Spec.pageRenameFromRight + 24,
          top: 0,
          bottom: 0,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Semantics(
              header: true,
              child: const AText(
                'Voice Recorder',
                style: Spec.pageTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
        button(
          Spec.pageRenameFromRight,
          'Rename',
          AppIcons.pencil,
          Spec.pageRenameIcon,
          () => _rename(app),
        ),
        button(
          Spec.pageShareFromRight,
          'Share',
          AppIcons.shareFilled,
          Spec.pageShareIcon,
          () => _share(app),
          key: _shareKey,
        ),
        button(
          Spec.pageDeleteFromRight,
          'Delete',
          AppIcons.deleteFilled,
          Spec.pageDeleteIcon,
          () => _delete(app),
        ),
      ],
    );
  }

  Widget _details(AppController app, RecordingFile file) {
    final playback = app.playback;
    final length =
        file.duration ??
        (playback.fileId == file.id && playback.duration > Duration.zero
            ? playback.duration
            : null);
    final path = app.store.displayPath(file);
    final rows = [
      _DetailRow(
        icon: AppIcons.musicNote,
        iconSize: Spec.pageNameIcon,
        label: 'Name',
        text: file.name,
      ),
      _DetailRow(
        icon: AppIcons.expand,
        iconSize: Spec.pageSizeIcon,
        label: 'Size',
        text: formatFileSize(file.size),
      ),
      _DetailRow(
        icon: AppIcons.pageFloppy,
        iconSize: Spec.pageFolderIcon,
        label: 'Location',
        // It may break after any slash, as the original's did.
        text: path.replaceAll('/', '/​'),
        spoken: path,
      ),
      _DetailRow(
        icon: AppIcons.playedAt,
        iconSize: Spec.pageDateIcon,
        label: 'Recorded',
        text: formatLongDate(file.date),
      ),
      _DetailRow(
        icon: AppIcons.length,
        iconSize: Spec.pageLengthIcon,
        label: 'Length',
        text: length == null ? '--:--' : formatTimer(length),
      ),
    ];
    return LayoutBuilder(
      builder: (context, c) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: c.maxHeight),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < rows.length; i++) ...[
                if (i > 0) const SizedBox(height: Spec.pageRowGap),
                rows[i],
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _player(
    BuildContext context,
    AppController app,
    RecordingFile file,
    double width,
  ) {
    final playback = app.playback;
    final loaded = playback.fileId == file.id;
    final playing = playback.isPlaying(file.id);
    final position = loaded ? playback.position : Duration.zero;
    // Not loaded yet: the length read from the file.
    final duration = loaded && playback.duration > Duration.zero
        ? playback.duration
        : file.duration ?? Duration.zero;
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
    final previous = _neighbour(app, -1);
    final next = _neighbour(app, 1);
    final timeTop =
        Spec.playerTimeBaseline -
        AndroidFontMetrics.of(context, Spec.pageText).firstBaseline;
    final mid = width / 2;
    const y = Spec.playerButtonsCenterY;

    return SizedBox(
      height: Spec.playerHeight + ScreenFrame.homeIndicatorOf(context),
      child: Stack(
        children: [
          const Positioned.fill(child: BrushedMetal()),
          Positioned(
            left: 0,
            right: 0,
            top: Spec.playerTrackTop + Spec.playerTrackHeight / 2 - 24,
            height: 48,
            child: _MetalSeekBar(
              progress: progress,
              duration: duration,
              onChanged: (p) => setState(() => _drag = p),
              onChangeEnd: (p) {
                setState(() => _drag = null);
                _seek(app, p);
              },
            ),
          ),
          // The times let touches through to the seek bar and buttons.
          Positioned(
            left: Spec.playerTimeLeft,
            top: timeTop,
            child: IgnorePointer(
              child: AText(
                formatPosition(shown),
                style: Spec.pageText,
                maxLines: 1,
              ),
            ),
          ),
          Positioned(
            right: Spec.playerTimeRight,
            top: timeTop,
            child: IgnorePointer(
              child: AText(
                formatTimer(duration),
                style: Spec.pageText,
                maxLines: 1,
              ),
            ),
          ),
          _RoundButton(
            center: Offset(mid - Spec.playerFarButton, y),
            diameter: Spec.playerSmallButton,
            ring: Spec.playerSmallRing,
            icon: AppIcons.skipPrevious,
            iconSize: AppIcons.skipPrevious.box,
            semanticLabel: 'Previous recording',
            onTap: previous == null ? null : () => _go(app, -1),
          ),
          _RoundButton(
            center: Offset(mid - Spec.playerNearButton, y),
            diameter: Spec.playerMidButton,
            ring: Spec.playerMidRing,
            icon: AppIcons.rewind,
            iconSize: AppIcons.rewind.box,
            iconOffset: const Offset(-1.2, 0),
            semanticLabel: 'Back 10 seconds',
            onTap: () => _skip(app, -skipInterval),
          ),
          _RoundButton(
            center: Offset(mid, y),
            diameter: Spec.playerBigButton,
            ring: Spec.playerBigRing,
            icon: playing ? AppIcons.pause : AppIcons.play,
            iconSize: playing ? AppIcons.pause.box : AppIcons.play.box,
            iconOffset: playing ? Offset.zero : const Offset(2, 0),
            semanticLabel: playing ? 'Pause' : 'Play',
            onTap: () => _togglePlay(app),
          ),
          _RoundButton(
            center: Offset(mid + Spec.playerNearButton, y),
            diameter: Spec.playerMidButton,
            ring: Spec.playerMidRing,
            icon: AppIcons.fastForward,
            iconSize: AppIcons.fastForward.box,
            iconOffset: const Offset(1.2, 0),
            semanticLabel: 'Forward 10 seconds',
            onTap: () => _skip(app, skipInterval),
          ),
          _RoundButton(
            center: Offset(mid + Spec.playerFarButton, y),
            diameter: Spec.playerSmallButton,
            ring: Spec.playerSmallRing,
            icon: AppIcons.skipNext,
            iconSize: AppIcons.skipNext.box,
            semanticLabel: 'Next recording',
            onTap: next == null ? null : () => _go(app, 1),
          ),
        ],
      ),
    );
  }
}

/// One line of the details: an icon, and the text beside it.
class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.icon,
    required this.iconSize,
    required this.label,
    required this.text,
    this.spoken,
  });

  final IconShape icon;
  final Size iconSize;
  final String label;
  final String text;

  /// What a screen reader says for [text], if not the same.
  final String? spoken;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: '$label: ${spoken ?? text}',
      excludeSemantics: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: Spec.pageRowHeight),
        child: Stack(
          alignment: AlignmentDirectional.centerStart,
          children: [
            Positioned(
              left: Spec.pageIconCenterX - iconSize.width / 2,
              top: (Spec.pageRowHeight - iconSize.height) / 2,
              child: InkIcon(icon, size: iconSize, color: _white),
            ),
            Padding(
              padding: const EdgeInsets.only(
                left: Spec.pageTextLeft,
                right: Spec.pageTextRight,
              ),
              child: AText(text, style: Spec.pageText),
            ),
          ],
        ),
      ),
    );
  }
}

/// A round player button: a thin white ring around its symbol, lit while
/// pressed and dimmed while it can't be used.
class _RoundButton extends StatefulWidget {
  const _RoundButton({
    required this.center,
    required this.diameter,
    required this.icon,
    required this.iconSize,
    required this.ring,
    required this.semanticLabel,
    required this.onTap,
    this.iconOffset = Offset.zero,
  });

  final Offset center;
  final double diameter;

  /// The ring's width.
  final double ring;
  final IconShape icon;
  final Size iconSize;
  final Offset iconOffset;
  final String semanticLabel;
  final VoidCallback? onTap;

  /// The touch area: as wide as the buttons are apart, and taller.
  static const touch = Size(46, 56);

  @override
  State<_RoundButton> createState() => _RoundButtonState();
}

class _RoundButtonState extends State<_RoundButton> {
  bool _down = false;

  void _set(bool v) {
    if (_down != v) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    const touch = _RoundButton.touch;
    return Positioned(
      left: widget.center.dx - touch.width / 2,
      top: widget.center.dy - touch.height / 2,
      width: touch.width,
      height: touch.height,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => _set(true) : null,
        onTapUp: enabled ? (_) => _set(false) : null,
        onTapCancel: enabled ? () => _set(false) : null,
        onTap: widget.onTap,
        child: Semantics(
          button: true,
          enabled: enabled,
          label: widget.semanticLabel,
          excludeSemantics: true,
          child: Opacity(
            opacity: enabled ? 1 : 0.4,
            child: CustomPaint(
              painter: _RingPainter(widget.diameter, widget.ring, _down),
              child: Center(
                child: Transform.translate(
                  offset: widget.iconOffset,
                  child: InkIcon(
                    widget.icon,
                    size: widget.iconSize,
                    color: _white,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.diameter, this.width, this.pressed);

  final double diameter;
  final double width;
  final bool pressed;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    final r = (diameter - width) / 2;
    if (pressed) {
      canvas.drawCircle(centre, r, Paint()..color = const Color(0x40FFFFFF));
    }
    canvas.drawCircle(
      centre,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..color = const Color(0xFFF0F0F0),
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.diameter != diameter || old.width != width || old.pressed != pressed;
}

/// The player's seek bar: a metal track with a metal slider on it.
class _MetalSeekBar extends StatefulWidget {
  const _MetalSeekBar({
    required this.progress,
    required this.duration,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final double progress;

  /// The recording's length, so screen readers say the position as a time;
  /// zero when unknown.
  final Duration duration;

  /// The slider moved (while dragging).
  final ValueChanged<double> onChanged;

  /// The user let go (or tapped): seek here.
  final ValueChanged<double> onChangeEnd;

  @override
  State<_MetalSeekBar> createState() => _MetalSeekBarState();
}

class _MetalSeekBarState extends State<_MetalSeekBar> {
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
        final track = _Track(c.maxWidth);
        final p = widget.progress;
        final length = widget.duration;
        String say(double at) => length > Duration.zero
            ? '${formatTimer(length * at)} of ${formatTimer(length)}'
            : '${(at * 100).round()}%';
        return Semantics(
          slider: true,
          label: 'Position',
          value: say(p),
          increasedValue: say(math.min(1.0, p + 0.05)),
          decreasedValue: say(math.max(0.0, p - 0.05)),
          onIncrease: () => widget.onChangeEnd(math.min(1.0, p + 0.05)),
          onDecrease: () => widget.onChangeEnd(math.max(0.0, p - 0.05)),
          // Not the gestures' tap and scroll: a screen reader's would seek to
          // the middle.
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            excludeFromSemantics: true,
            onTapUp: (d) => widget.onChangeEnd(track.at(d.localPosition.dx)),
            onHorizontalDragStart: (d) => _move(track.at(d.localPosition.dx)),
            onHorizontalDragUpdate: (d) => _move(track.at(d.localPosition.dx)),
            onHorizontalDragEnd: (_) => _end(),
            onHorizontalDragCancel: _end,
            child: CustomPaint(
              size: Size(c.maxWidth, c.maxHeight),
              painter: _MetalSeekPainter(p, track),
            ),
          ),
        );
      },
    );
  }
}

/// Where the track lies across the page, and where on it the slider goes.
class _Track {
  _Track(double width)
    : start = Spec.playerTrackLeft,
      end = width - Spec.playerTrackRight;

  final double start;
  final double end;

  /// The slider stays a little inside the track's ends.
  static const inset = 1.0;

  double get travel =>
      math.max(1, end - start - 2 * inset - Spec.playerThumb.width);

  /// The slider's left edge at [progress].
  double thumbLeft(double progress) => start + inset + travel * progress;

  /// The progress for a touch at [x] (the slider's middle goes there).
  double at(double x) =>
      ((x - start - inset - Spec.playerThumb.width / 2) / travel).clamp(
        0.0,
        1.0,
      );

  @override
  bool operator ==(Object other) =>
      other is _Track && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);
}

class _MetalSeekPainter extends CustomPainter {
  _MetalSeekPainter(this.progress, this.track);

  final double progress;
  final _Track track;

  static const _trackShades = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFF9D9D9D), Color(0xFF5C5C5C), Color(0xFF727272)],
    stops: [0, 0.75, 1],
  );
  static const _thumbShades = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    // Darkest about three quarters down, then lighter to the rim.
    colors: [
      Color(0xFFF2F2F2),
      Color(0xFFE5E5E5),
      Color(0xFFAEAEAE),
      Color(0xFF818181),
      Color(0xFF888888),
      Color(0xFF9C9C9C),
      Color(0xFFCACACA),
    ],
    stops: [0, 0.05, 0.34, 0.72, 0.85, 0.91, 0.97],
  );

  @override
  void paint(Canvas canvas, Size size) {
    final cy = size.height / 2;
    final edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.6
      ..color = const Color(0x55000000);
    final bar = RRect.fromRectAndRadius(
      Rect.fromLTRB(
        track.start,
        cy - Spec.playerTrackHeight / 2,
        track.end,
        cy + Spec.playerTrackHeight / 2,
      ),
      const Radius.circular(Spec.playerTrackRadius),
    );
    canvas
      ..drawRRect(
        bar,
        Paint()..shader = _trackShades.createShader(bar.outerRect),
      )
      ..drawRRect(bar, edge);

    const thumb = Spec.playerThumb;
    final knob = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        track.thumbLeft(progress),
        cy - thumb.height / 2,
        thumb.width,
        thumb.height,
      ),
      const Radius.circular(2.5),
    );
    canvas
      ..drawRRect(
        knob.shift(const Offset(0, 0.8)),
        Paint()..color = const Color(0x80000000),
      )
      ..drawRRect(
        knob,
        Paint()..shader = _thumbShades.createShader(knob.outerRect),
      )
      ..drawRRect(knob, edge);
  }

  @override
  bool shouldRepaint(_MetalSeekPainter old) =>
      old.progress != progress || old.track != track;
}
