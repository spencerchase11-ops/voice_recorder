import 'package:flutter/material.dart' show MaterialPageRoute;
import 'package:flutter/widgets.dart';

import '../../core/format.dart';
import '../../core/recording_file.dart';
import '../app_scope.dart';
import '../dialogs/dialogs.dart';
import '../icons/app_icons.dart';
import '../spec.dart';
import '../widgets/frame.dart';
import '../widgets/red_bars.dart';
import '../widgets/toast.dart';

const _white = Color(0xFFFFFFFF);

/// Recordings deleted in the last 30 days, which can be put back.
class RecentlyDeletedScreen extends StatefulWidget {
  const RecentlyDeletedScreen({super.key});

  static Route<void> route() =>
      MaterialPageRoute<void>(builder: (_) => const RecentlyDeletedScreen());

  @override
  State<RecentlyDeletedScreen> createState() => _RecentlyDeletedScreenState();
}

class _RecentlyDeletedScreenState extends State<RecentlyDeletedScreen> {
  List<TrashedRecording>? _items;
  String? _selected;

  /// The folder couldn't be read.
  bool _failed = false;

  /// A restore or delete is being carried out: more taps wait for it.
  bool _busy = false;

  /// The controller's trash version shown last.
  int? _shown;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Loaded again after a change elsewhere (an undo from the toast).
    final version = AppScope.of(context).trashVersion;
    if (_shown != version) {
      _shown = version;
      _load();
    }
  }

  Future<void> _load() async {
    if (!mounted) return;
    final items = await AppScope.read(context).deletedRecordings();
    if (!mounted) return;
    setState(() {
      _failed = items == null;
      _items = items ?? const [];
      if (!_items!.any((t) => t.file.id == _selected)) _selected = null;
    });
  }

  /// Runs [action] unless another one is running.
  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  TrashedRecording? get _selectedItem {
    for (final t in _items ?? const <TrashedRecording>[]) {
      if (t.file.id == _selected) return t;
    }
    return null;
  }

  /// [message], or, when the folder itself can't be reached, how to fix that.
  String _problem(String message) => AppScope.read(context).store.isReady
      ? message
      : "The folder can't be reached. Choose it again in Settings > Folder.";

  /// Restores the selected recording, or all of them when none is selected.
  Future<void> _restore() => _run(() async {
    final items = _items ?? const <TrashedRecording>[];
    if (items.isEmpty) return;
    final app = AppScope.read(context);
    final t = _selectedItem;
    if (t != null) {
      final restored = await app.restoreDeleted(t);
      if (!mounted) return;
      showToast(
        context,
        restored == null
            ? _problem("Couldn't restore the recording")
            : 'Restored ${restored.name}',
      );
      return;
    }
    final ok = await showConfirmDialog(
      context,
      title: 'Restore all',
      message: items.length == 1
          ? 'The recording in Recently deleted will go back to the list.'
          : 'All ${formatCount(items.length)} recordings in Recently deleted '
                'will go back to the list.',
      ok: 'Restore all',
    );
    if (!ok || !mounted) return;
    final n = await runWithProgress(
      context,
      title: 'Restoring',
      total: items.length,
      label: (s) =>
          'Restoring ${formatCount(s.done)} of ${formatCount(s.total)} '
          'recordings…',
      job: (onProgress, cancelled) =>
          app.restoreAll(items, onProgress: onProgress, cancelled: cancelled),
    );
    if (!mounted) return;
    showToast(
      context,
      n == 0
          ? _problem("Couldn't restore the recordings")
          : n == 1
          ? 'Restored 1 recording'
          : 'Restored ${formatCount(n)} recordings',
    );
  });

  /// Deletes the selected recording for good, or all of them when none is
  /// selected.
  Future<void> _deleteForever() => _run(() async {
    final items = _items ?? const <TrashedRecording>[];
    if (items.isEmpty) return;
    final app = AppScope.read(context);
    final t = _selectedItem;
    final targets = t == null ? items : [t];
    final ok = await showConfirmDialog(
      context,
      title: t == null ? 'Empty Recently deleted' : 'Delete forever',
      message: t != null
          ? '"${t.originalName}" will be deleted forever. This can\'t be '
                'undone.'
          : items.length == 1
          ? 'The recording in Recently deleted will be deleted forever. This '
                'can\'t be undone.'
          : 'All ${formatCount(items.length)} recordings in Recently deleted '
                'will be deleted forever. This can\'t be undone.',
      ok: t == null ? 'Delete all' : 'Delete',
    );
    if (!ok || !mounted) return;
    final n = await runWithProgress(
      context,
      title: 'Deleting',
      total: targets.length,
      label: (s) =>
          'Deleting ${formatCount(s.done)} of ${formatCount(s.total)} '
          'recordings…',
      job: (onProgress, cancelled) => app.deleteForever(
        targets,
        onProgress: onProgress,
        cancelled: cancelled,
      ),
    );
    if (!mounted) return;
    if (n == 0) {
      showToast(
        context,
        _problem(
          targets.length == 1
              ? "Couldn't delete the recording"
              : "Couldn't delete the recordings",
        ),
      );
    } else if (n < targets.length) {
      final left = targets.length - n;
      showToast(
        context,
        left == 1
            ? "1 recording couldn't be deleted"
            : "${formatCount(left)} recordings couldn't be deleted",
      );
    }
  });

  @override
  Widget build(BuildContext context) {
    final items = _items;
    final hasItems = items != null && items.isNotEmpty;
    final now = DateTime.now();

    return ScreenFrame(
      child: Column(
        children: [
          RedHeader(
            title: 'Recently deleted',
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
            ],
          ),
          Expanded(
            child: BrushedMetal(
              child: items == null
                  ? const SizedBox.expand()
                  : _failed
                  ? const _Message(
                      "Can't open the recordings folder. Check it in "
                      'Settings > Folder.',
                    )
                  : items.isEmpty
                  ? const _Message(
                      'No recently deleted recordings.\n\n'
                      'Deleted recordings stay here for 30 days, so you can '
                      'restore them.',
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.only(top: Spec.listTopGap),
                      itemCount: items.length,
                      itemBuilder: (context, i) {
                        final t = items[i];
                        return _DeletedRow(
                          key: ValueKey(t.file.id),
                          item: t,
                          now: now,
                          selected: t.file.id == _selected,
                          // Tapping the selected one again selects none
                          // (the buttons then act on all).
                          onTap: () => setState(
                            () => _selected = _selected == t.file.id
                                ? null
                                : t.file.id,
                          ),
                        );
                      },
                    ),
            ),
          ),
          RedFooter(
            height: Spec.actionBarHeight,
            cells: [
              _FooterButton(
                icon: AppIcons.restore,
                size: const Size(23.3, 30.0),
                label: _selected == null ? 'Restore all' : 'Restore',
                onTap: hasItems ? _restore : null,
              ),
              _FooterButton(
                icon: _selected == null
                    ? AppIcons.emptyTrash
                    : AppIcons.deleteForever,
                size: _selected == null
                    ? const Size(28.0, 22.5)
                    : const Size(23.3, 30.0),
                label: _selected == null ? 'Delete all' : 'Delete forever',
                onTap: hasItems ? _deleteForever : null,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 48, 24, 0),
      child: Align(
        alignment: Alignment.topCenter,
        child: AText(text, style: Spec.listDetail, textAlign: TextAlign.center),
      ),
    );
  }
}

class _DeletedRow extends StatelessWidget {
  const _DeletedRow({
    super.key,
    required this.item,
    required this.now,
    required this.selected,
    required this.onTap,
  });

  final TrashedRecording item;
  final DateTime now;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final lineBox = AText.boxHeight(context, Spec.listName);
    final days = item.daysLeft(now);
    return Column(
      children: [
        PressableArea(
          onTap: onTap,
          semanticLabel: item.originalName,
          selected: selected,
          // The date and days left are read after the name.
          excludeSemantics: false,
          child: Container(
            color: selected ? Spec.listSelected : null,
            height: Spec.listRowPadding * 2 + lineBox * 2,
            padding: const EdgeInsets.fromLTRB(
              16,
              Spec.listRowPadding,
              Spec.listTextRight,
              Spec.listRowPadding,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ExcludeSemantics(
                  child: AText(
                    item.originalName,
                    style: Spec.listName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: AText(
                        'Deleted ${formatListDate(item.deletedAt)}',
                        style: Spec.listDetail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    AText(
                      days == 1 ? '1 day left' : '$days days left',
                      style: Spec.listDetail,
                      maxLines: 1,
                    ),
                  ],
                ),
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

/// An icon with its label under it (these actions have no icon everyone
/// knows).
class _FooterButton extends StatelessWidget {
  const _FooterButton({
    required this.icon,
    required this.size,
    required this.label,
    required this.onTap,
  });

  final IconShape icon;
  final Size size;
  final String label;

  /// Null greys the button out (nothing to act on).
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return PressableArea(
      onTap: onTap,
      semanticLabel: label,
      highlight: const Color(0x26FFFFFF),
      child: Opacity(
        opacity: onTap == null ? 0.4 : 1,
        child: LayoutBuilder(
          builder: (context, c) => Stack(
            children: [
              Positioned(
                left: (c.maxWidth - size.width) / 2,
                top: Spec.actionIconCenterY - 4 - size.height / 2,
                child: InkIcon(icon, size: size, color: _white),
              ),
              Positioned(
                left: 4,
                right: 4,
                top: Spec.actionIconCenterY + 17,
                child: AText(
                  label,
                  style: const TextStyle(
                    fontFamily: Spec.font,
                    fontSize: 12,
                    color: _white,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
