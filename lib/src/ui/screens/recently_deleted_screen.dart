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

  Future<void> _restore() => _run(() async {
    final t = _selectedItem;
    if (t == null) {
      showToast(context, 'Please select a file');
      return;
    }
    final restored = await AppScope.read(context).restoreDeleted(t);
    if (!mounted) return;
    showToast(
      context,
      restored == null ? 'Restore failed' : 'Restored ${restored.name}',
    );
    await _load();
  });

  Future<void> _deleteForever() => _run(() async {
    final t = _selectedItem;
    if (t == null) {
      showToast(context, 'Please select a file');
      return;
    }
    final app = AppScope.read(context);
    final ok = await showConfirmDialog(
      context,
      title: 'Delete forever',
      message: '${t.originalName} will be deleted for good.',
      ok: 'Delete',
    );
    if (!ok || !mounted) return;
    final n = await app.deleteForever([t]);
    if (!mounted) return;
    if (n == 0) showToast(context, 'Delete failed');
    await _load();
  });

  Future<void> _empty() => _run(() async {
    final items = _items ?? const <TrashedRecording>[];
    if (items.isEmpty) return;
    final app = AppScope.read(context);
    final ok = await showConfirmDialog(
      context,
      title: 'Delete forever',
      message: items.length == 1
          ? 'The recording in Recently deleted will be deleted for good.'
          : 'All ${formatCount(items.length)} recordings in Recently deleted will be '
                'deleted for good.',
      ok: 'Delete',
    );
    if (!ok || !mounted) return;
    final n = await app.deleteForever(items);
    if (!mounted) return;
    if (n < items.length) {
      showToast(context, "${items.length - n} couldn't be deleted");
    }
    await _load();
  });

  @override
  Widget build(BuildContext context) {
    final items = _items;
    final width = MediaQuery.sizeOf(context).width;
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
              if (items != null && items.isNotEmpty)
                BarButton(
                  center: Offset(width - 26.0, 24.0),
                  semanticLabel: 'Delete all forever',
                  onTap: _empty,
                  child: const InkIcon(
                    AppIcons.emptyTrash,
                    size: Size(26.0, 20.9),
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
                      "Recently deleted can't be read right now. Check that "
                      'the recordings folder is still there (Settings > '
                      'Folder).',
                    )
                  : items.isEmpty
                  ? const _Message(
                      'No recently deleted recordings.\n\n'
                      'Deleted recordings stay here for 30 days, so you can '
                      'put them back.',
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
                          onTap: () => setState(() => _selected = t.file.id),
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
                label: 'Restore',
                onTap: _restore,
              ),
              _FooterButton(
                icon: AppIcons.deleteForever,
                size: const Size(23.3, 30.0),
                label: 'Delete forever',
                onTap: _deleteForever,
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
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return PressableArea(
      onTap: onTap,
      semanticLabel: label,
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
