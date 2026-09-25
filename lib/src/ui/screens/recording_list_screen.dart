import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/material.dart'
    show InputBorder, InputDecoration, MaterialPageRoute, TextField;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../app_controller.dart';
import '../../core/format.dart';
import '../../core/recording_file.dart';
import '../../core/settings.dart';
import '../app_scope.dart';
import '../dialogs/dialogs.dart';
import '../icons/app_icons.dart';
import '../spec.dart';
import '../widgets/frame.dart';
import '../widgets/holo_check_box.dart';
import '../widgets/recorder_widgets.dart';
import '../widgets/red_bars.dart';
import '../widgets/toast.dart';
import 'common_actions.dart';

const _white = Color(0xFFFFFFFF);

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
  /// The row that is open (orange, with the seek bar).
  String? _selected;

  /// Rows ticked in selection mode (long press); null when not selecting.
  Set<String>? _ticked;

  /// The search text; null when not searching.
  String? _query;
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  late AppController _app;
  bool _loaded = false;

  /// The app was in the background (not just behind the notification
  /// shade): other apps may have changed the folder meanwhile.
  bool _wasAway = false;
  final _scroll = ScrollController();

  /// A delete, rename or share is being carried out: more taps wait.
  bool _busy = false;

  // The last search result, and what it was worked out from (the screen
  // rebuilds many times a second while something plays).
  List<RecordingFile>? _matchedFrom;
  String? _matchedQuery;
  List<RecordingFile> _matched = const [];

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
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      _wasAway = true;
    } else if (state == AppLifecycleState.resumed && _wasAway) {
      _wasAway = false;
      _app.refreshFiles();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scroll.dispose();
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// The rows shown: all recordings, or those matching the search (by name
  /// or by date, e.g. "2026-09").
  List<RecordingFile> _visible(List<RecordingFile> files) {
    final q = (_query ?? '').trim().toLowerCase();
    if (q.isEmpty) return files;
    if (identical(files, _matchedFrom) && q == _matchedQuery) return _matched;
    _matchedFrom = files;
    _matchedQuery = q;
    return _matched = [
      for (final f in files)
        if (f.name.toLowerCase().contains(q) ||
            formatListDate(f.date).contains(q))
          f,
    ];
  }

  RecordingFile? _selectedFile(List<RecordingFile> files) {
    for (final f in files) {
      if (f.id == _selected) return f;
    }
    return null;
  }

  List<RecordingFile> _tickedFiles(List<RecordingFile> files) {
    final ticked = _ticked ?? const <String>{};
    return [
      for (final f in files)
        if (ticked.contains(f.id)) f,
    ];
  }

  void _startSearch() {
    setState(() {
      _query = '';
      _ticked = null;
    });
    _searchFocus.requestFocus();
  }

  void _endSearch() {
    _search.clear();
    _searchFocus.unfocus();
    setState(() => _query = null);
  }

  void _startSelecting(RecordingFile f) {
    HapticFeedback.selectionClick();
    _searchFocus.unfocus();
    setState(() => _ticked = {f.id});
  }

  void _endSelecting() => setState(() => _ticked = null);

  void _toggleTick(RecordingFile f) {
    final t = _ticked;
    if (t == null) return;
    setState(() {
      if (!t.remove(f.id)) t.add(f.id);
    });
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

  Future<void> _sort() async {
    final settings = _app.settings;
    final i = await showChoiceDialog(
      context,
      title: 'Sort by',
      items: [for (final o in SortOrder.values) o.label],
      selected: settings.sortOrder.index,
    );
    if (i != null) settings.sortOrder = SortOrder.values[i];
  }

  /// The files the bottom bar acts on: the ticked ones in selection mode,
  /// else the open row. Null (with a message) when there are none.
  List<RecordingFile>? _targets(List<RecordingFile> visible) {
    if (_ticked != null) {
      final files = _tickedFiles(visible);
      if (files.isEmpty) {
        showToast(context, 'Please select a file');
        return null;
      }
      return files;
    }
    final f = _selectedFile(visible);
    if (f == null) {
      showToast(context, 'Please select a file');
      return null;
    }
    return [f];
  }

  Future<void> _delete(List<RecordingFile> visible) => _run(() async {
    final files = _targets(visible);
    if (files == null) return;
    if (await deleteRecordings(context, files) && mounted) {
      setState(() {
        _selected = null;
        _ticked = null;
      });
    }
  });

  Future<void> _rename(List<RecordingFile> visible) => _run(() async {
    final files = _targets(visible);
    if (files == null) return;
    if (files.length > 1) {
      showToast(context, 'Select only one recording to rename');
      return;
    }
    final renamed = await renameRecording(context, files.single);
    if (renamed != null && mounted) {
      setState(() {
        if (_ticked != null) {
          _ticked = {renamed.id};
        } else {
          _selected = renamed.id;
        }
      });
    }
  });

  Future<void> _share(List<RecordingFile> visible, Rect origin) =>
      _run(() async {
        final files = _targets(visible);
        if (files == null) return;
        await shareRecordings(context, files, origin: origin);
      });

  Future<void> _play(RecordingFile f) async {
    final outcome = await _app.togglePlay(f);
    if (mounted) showPlayProblem(context, outcome);
  }

  void _open(RecordingFile f) {
    _searchFocus.unfocus();
    setState(() => _selected = f.id);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final visible = _visible(app.files);
    final width = MediaQuery.sizeOf(context).width;
    final ticked = _ticked;

    return PopScope(
      canPop: ticked == null && _query == null,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_ticked != null) {
          _endSelecting();
        } else if (_query != null) {
          _endSearch();
        }
      },
      child: ScreenFrame(
        child: Column(
          children: [
            _header(width, visible),
            Expanded(
              child: BrushedMetal(
                child: visible.isEmpty && (_query ?? '').trim().isNotEmpty
                    ? const _Empty('No recordings match')
                    : app.files.isEmpty
                    ? _emptyList(app)
                    : RawScrollbar(
                        controller: _scroll,
                        // Drag the thumb to go through thousands quickly.
                        interactive: true,
                        thickness: 6,
                        minThumbLength: 48,
                        radius: const Radius.circular(3),
                        thumbColor: const Color(0x80FFFFFF),
                        child: ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.only(top: Spec.listTopGap),
                          keyboardDismissBehavior:
                              ScrollViewKeyboardDismissBehavior.onDrag,
                          itemCount: visible.length,
                          itemBuilder: (context, i) {
                            final f = visible[i];
                            if (ticked != null) {
                              return _RecordingRow(
                                key: ValueKey(f.id),
                                file: f,
                                selected: ticked.contains(f.id),
                                ticking: true,
                                onSelect: () => _toggleTick(f),
                                onPlay: () => _toggleTick(f),
                              );
                            }
                            return _RecordingRow(
                              key: ValueKey(f.id),
                              file: f,
                              selected: f.id == _selected,
                              open: f.id == _selected,
                              onSelect: () => _open(f),
                              onLongPress: () => _startSelecting(f),
                              onPlay: () {
                                _open(f);
                                if (app.isRecording) {
                                  showToast(
                                    context,
                                    "Can't play while recording",
                                  );
                                  return;
                                }
                                _play(f);
                              },
                            );
                          },
                        ),
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
                  onTap: () => _delete(visible),
                ),
                _FooterIcon(
                  icon: AppIcons.pencil,
                  size: const Size(32.9, 32.9),
                  semanticLabel: 'Rename',
                  onTap: () => _rename(visible),
                ),
                _FooterIcon(
                  icon: AppIcons.share,
                  size: const Size(26.9, 27.1),
                  semanticLabel: 'Share',
                  onTap: () {
                    final bottom =
                        MediaQuery.sizeOf(context).height -
                        MediaQuery.viewPaddingOf(context).bottom;
                    _share(
                      visible,
                      Rect.fromLTWH(
                        width * 2 / 3,
                        bottom - Spec.actionBarHeight,
                        width / 3,
                        Spec.actionBarHeight,
                      ),
                    );
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(double width, List<RecordingFile> visible) {
    final ticked = _ticked;
    if (ticked != null) {
      final all =
          visible.isNotEmpty && visible.every((f) => ticked.contains(f.id));
      // Rows that went away meanwhile (deleted elsewhere) don't count.
      return RedHeader(
        title: '${formatCount(_tickedFiles(visible).length)} selected',
        children: [
          BarButton(
            center: const Offset(22.0, 24.0),
            semanticLabel: 'Cancel selection',
            onTap: _endSelecting,
            child: const InkIcon(
              AppIcons.close,
              size: Size(16.5, 16.5),
              color: _white,
            ),
          ),
          BarButton(
            center: Offset(width - 26.0, 24.0),
            semanticLabel: all ? 'Select none' : 'Select all',
            onTap: () => setState(() {
              if (all) {
                ticked.clear();
              } else {
                ticked.addAll(visible.map((f) => f.id));
              }
            }),
            child: HoloCheckBox(checked: all),
          ),
        ],
      );
    }
    final query = _query;
    if (query != null) {
      return RedHeader(
        title: '',
        children: [
          _backButton(_endSearch),
          Positioned(
            left: 40,
            right: query.isEmpty ? 12 : 48,
            top: 0,
            bottom: 0,
            child: Center(
              child: TextField(
                controller: _search,
                focusNode: _searchFocus,
                cursorColor: _white,
                textInputAction: TextInputAction.search,
                style: const TextStyle(
                  fontFamily: Spec.font,
                  fontSize: 18,
                  color: _white,
                ),
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: 'Search by name or date',
                  hintStyle: TextStyle(
                    fontFamily: Spec.font,
                    fontSize: 18,
                    color: Color(0xB3FFFFFF),
                  ),
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
          ),
          if (query.isNotEmpty)
            BarButton(
              center: Offset(width - 26.0, 24.0),
              semanticLabel: 'Clear search',
              onTap: () {
                _search.clear();
                setState(() => _query = '');
                _searchFocus.requestFocus();
              },
              child: const InkIcon(
                AppIcons.close,
                size: Size(15.0, 15.0),
                color: _white,
              ),
            ),
        ],
      );
    }
    return RedHeader(
      title: 'Recording list',
      children: [
        _backButton(() => Navigator.of(context).maybePop()),
        BarButton(
          center: Offset(width - 77.0, 24.0),
          semanticLabel: 'Sort',
          onTap: _sort,
          child: const InkIcon(
            AppIcons.sort,
            size: Size(22.0, 22.4),
            color: _white,
          ),
        ),
        BarButton(
          center: Offset(width - 26.0, 24.0),
          semanticLabel: 'Search',
          onTap: _startSearch,
          child: const InkIcon(
            AppIcons.search,
            size: Size(21.0, 21.0),
            color: _white,
          ),
        ),
      ],
    );
  }

  /// What an empty list shows: why it's empty, and what to do.
  Widget _emptyList(AppController app) {
    final store = app.store;
    if (!app.filesLoaded) {
      return const _Empty('Loading recordings…', delay: true);
    }
    if (!store.isReady) {
      return _Empty(
        store.folderChosen
            ? "The recordings folder can't be reached.\n\nTap here to choose "
                  'it again.'
            : 'Choose the folder for your recordings.\n\nTap here to choose '
                  'it.',
        onTap: () => showChooseFolderDialog(context),
      );
    }
    if (app.filesError) {
      return _Empty(
        "Can't open the recordings folder.\n\nTap here to try again, or "
        'check it in Settings > Folder.',
        onTap: app.refreshFiles,
      );
    }
    return _Empty(
      Platform.isIOS
          ? 'No recordings yet.\n\nTo add the recordings you have in the '
                'Files app, use Settings > Import recordings.'
          : 'No recordings in this folder yet:\n'
                '${store.folderDisplayPath}\n\nTo use another folder, choose '
                'it in Settings > Folder.',
    );
  }

  Widget _backButton(VoidCallback onTap) => BarButton(
    center: const Offset(18.26, 23.14),
    semanticLabel: 'Back',
    onTap: onTap,
    child: const InkIcon(AppIcons.back, size: Size(13.7, 26.3), color: _white),
  );
}

/// A line of text in the middle of an empty list.
class _Empty extends StatefulWidget {
  const _Empty(this.text, {this.onTap, this.delay = false});

  final String text;

  /// Does what the text says to tap for.
  final VoidCallback? onTap;

  /// Shows the text only after a moment (a short wait shows nothing).
  final bool delay;

  @override
  State<_Empty> createState() => _EmptyState();
}

class _EmptyState extends State<_Empty> {
  Timer? _wait;
  late bool _shown = !widget.delay;

  @override
  void initState() {
    super.initState();
    if (!_shown) {
      _wait = Timer(const Duration(milliseconds: 500), () {
        if (mounted) setState(() => _shown = true);
      });
    }
  }

  @override
  void dispose() {
    _wait?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_shown) return const SizedBox.expand();
    final text = Padding(
      padding: const EdgeInsets.fromLTRB(24, 48, 24, 48),
      child: AText(
        widget.text,
        style: Spec.listDetail,
        textAlign: TextAlign.center,
      ),
    );
    return Align(
      alignment: Alignment.topCenter,
      child: widget.onTap == null
          ? text
          : PressableArea(
              onTap: widget.onTap,
              semanticLabel: widget.text,
              highlight: const Color(0x14FFFFFF),
              child: text,
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
              child: InkIcon(icon, size: size, color: _white),
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
    this.open = false,
    this.ticking = false,
    this.onLongPress,
  });

  final RecordingFile file;

  /// Orange: the open row, or a ticked row in selection mode.
  final bool selected;

  /// Shows the seek bar and playback controls.
  final bool open;

  /// Selection mode: a check box instead of the play button.
  final bool ticking;
  final VoidCallback onSelect;
  final VoidCallback onPlay;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    // The length (and a date stored in the file) are read when first shown.
    if (file.duration == null) app.requestInfo(file);
    final playing = app.playback.isPlaying(file.id);
    final lineBox = AText.boxHeight(context, Spec.listName);
    final topPart = Spec.listRowPadding * 2 + lineBox * 2 + Spec.listLineGap;
    final duration = file.duration;
    final date = formatListDate(file.date);

    final info = SizedBox(
      height: topPart,
      child: Stack(
        children: [
          if (ticking)
            Positioned(
              left: Spec.listPlayIconLeft + 4,
              top: (topPart - 24) / 2,
              child: HoloCheckBox(checked: selected),
            )
          else
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
            child: ExcludeSemantics(
              child: AText(
                file.name,
                style: Spec.listName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          Positioned(
            left: Spec.listTextLeft,
            right: Spec.listTextRight,
            top: Spec.listRowPadding + lineBox + Spec.listLineGap,
            child: Row(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: AText(
                      duration == null
                          ? date
                          : '$date · ${formatTimer(duration)}',
                      style: Spec.listDetail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
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
          onLongPress: onLongPress,
          selected: selected,
          semanticLabel: file.name,
          // The date, length and size are read after the name; the buttons
          // inside are separate.
          excludeSemantics: false,
          child: Container(
            color: selected ? Spec.listSelected : null,
            child: Column(
              children: [
                info,
                if (open && !ticking) _SeekSection(file: file),
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

/// Seek bar, position and playback controls shown under the open row.
class _SeekSection extends StatefulWidget {
  const _SeekSection({required this.file});

  final RecordingFile file;

  @override
  State<_SeekSection> createState() => _SeekSectionState();
}

class _SeekSectionState extends State<_SeekSection> {
  /// Where the thumb is while the user drags it (0..1).
  double? _drag;

  /// The controls react to a tap, not to a recording in progress.
  bool _blocked(AppController app) {
    if (!app.isRecording) return false;
    showToast(context, "Can't play while recording");
    return true;
  }

  Future<void> _skip(AppController app, Duration delta) async {
    if (_blocked(app)) return;
    if (!await app.skip(delta, file: widget.file) && mounted) {
      showToast(context, "Can't play this recording");
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final loaded = app.playback.fileId == widget.file.id;
    final position = loaded ? app.playback.position : Duration.zero;
    // Not loaded yet: the length read from the file, for a drag's time.
    final duration = loaded
        ? app.playback.duration
        : widget.file.duration ?? Duration.zero;
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
    final lineBox = AText.boxHeight(context, Spec.listName);
    // The buttons reach a little below the text, for an easier tap.
    final controlsHeight = lineBox + 10;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // measured from the date line; the row's bottom padding is above us
        const SizedBox(height: Spec.seekTopGap - Spec.listRowPadding),
        SizedBox(
          height: Spec.seekHeight,
          child: HoloSeekBar(
            progress: progress,
            duration: duration,
            onChanged: (p) => setState(() => _drag = p),
            onChangeEnd: (p) async {
              setState(() => _drag = null);
              if (_blocked(app)) return;
              if (!await app.seek(widget.file, p) && context.mounted) {
                showToast(context, "Can't play this recording");
              }
            },
          ),
        ),
        const SizedBox(height: Spec.seekTimeGap),
        SizedBox(
          height: controlsHeight,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: Spec.seekTimeLeft),
                child: AText(
                  formatPosition(shown),
                  style: Spec.listName,
                  maxLines: 1,
                ),
              ),
              const Spacer(),
              _ControlButton(
                semanticLabel: 'Back 10 seconds',
                height: controlsHeight,
                lineBox: lineBox,
                onTap: () => _skip(app, -skipInterval),
                child: const InkIcon(
                  AppIcons.replay10,
                  size: Size(17.6, 22.0),
                  color: _white,
                ),
              ),
              _ControlButton(
                semanticLabel:
                    'Playback speed ${formatSpeed(app.settings.playbackSpeed)}',
                height: controlsHeight,
                lineBox: lineBox,
                width: 56,
                onTap: app.cycleSpeed,
                // "1.25x" at a large text size.
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: AText(
                    formatSpeed(app.settings.playbackSpeed),
                    style: Spec.listName,
                    maxLines: 1,
                  ),
                ),
              ),
              _ControlButton(
                semanticLabel: 'Forward 10 seconds',
                height: controlsHeight,
                lineBox: lineBox,
                onTap: () => _skip(app, skipInterval),
                child: const InkIcon(
                  AppIcons.forward10,
                  size: Size(17.6, 22.0),
                  color: _white,
                ),
              ),
              const SizedBox(width: 6),
            ],
          ),
        ),
      ],
    );
  }
}

/// A small button on the position line; its [child] is centred on the text
/// line ([lineBox] high) and the touch area reaches down to [height].
class _ControlButton extends StatelessWidget {
  const _ControlButton({
    required this.child,
    required this.onTap,
    required this.height,
    required this.lineBox,
    required this.semanticLabel,
    this.width = 48,
  });

  final Widget child;
  final VoidCallback onTap;
  final double height;
  final double lineBox;
  final double width;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: PressableArea(
        onTap: onTap,
        semanticLabel: semanticLabel,
        highlight: const Color(0x33FFFFFF),
        child: Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            height: lineBox,
            child: Center(child: child),
          ),
        ),
      ),
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
    this.duration = Duration.zero,
  });

  final double progress;

  /// The recording's length, so screen readers say the position as a time
  /// ("12:30 of 33:57"); zero when unknown.
  final Duration duration;

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
          child: GestureDetector(
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
