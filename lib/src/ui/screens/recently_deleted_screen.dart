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
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      _load();
    }
  }

  Future<void> _load() async {
    final items = await AppScope.read(context).deletedRecordings();
    if (!mounted) return;
    setState(() {
      _items = items;
      if (!items.any((t) => t.file.id == _selected)) _selected = null;
    });
  }

  TrashedRecording? get _selectedItem {
    for (final t in _items ?? const <TrashedRecording>[]) {
      if (t.file.id == _selected) return t;
    }
    return null;
  }

  Future<void> _restore() async {
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
  }

  Future<void> _deleteForever() async {
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
    if (await app.deleteForever([t]) == 0 && mounted) {
      showToast(context, 'Delete failed');
    }
    await _load();
  }

  Future<void> _empty() async {
    final items = _items ?? const <TrashedRecording>[];
    if (items.isEmpty) return;
    final app = AppScope.read(context);
    final ok = await showConfirmDialog(
      context,
      title: 'Delete forever',
      message: items.length == 1
          ? 'The recording in Recently deleted will be deleted for good.'
          : 'All ${items.length} recordings in Recently deleted will be '
                'deleted for good.',
      ok: 'Delete',
    );
    if (!ok || !mounted) return;
    final n = await app.deleteForever(items);
    if (n < items.length && mounted) {
      showToast(context, "${items.length - n} couldn't be deleted");
    }
    await _load();
  }

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
                  : items.isEmpty
                  ? const _Empty()
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

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(24, 48, 24, 0),
      child: Align(
        alignment: Alignment.topCenter,
        child: AText(
          'No recently deleted recordings.\n\n'
          'Deleted recordings stay here for 30 days, so you can put them '
          'back.',
          style: Spec.listDetail,
          textAlign: TextAlign.center,
        ),
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
                AText(
                  item.originalName,
                  style: Spec.listName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
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
