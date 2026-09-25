import 'dart:io';

import 'package:flutter/material.dart'
    show LicensePage, MaterialPageRoute, Theme, ThemeData;
import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../config.dart';
import '../../core/recording_format.dart';
import '../../core/settings.dart';
import '../app_scope.dart';
import '../dialogs/dialogs.dart';
import '../icons/app_icons.dart';
import '../spec.dart';
import '../widgets/frame.dart';
import '../widgets/red_bars.dart';
import '../widgets/toast.dart';
import 'common_actions.dart';
import 'recently_deleted_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  static Route<void> route() =>
      MaterialPageRoute<void>(builder: (_) => const SettingsScreen());

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  /// How many recordings are in Recently deleted (null until known).
  int? _deleted;
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      _countDeleted();
    }
  }

  Future<void> _countDeleted() async {
    final n = (await AppScope.read(context).deletedRecordings()).length;
    if (mounted) setState(() => _deleted = n);
  }

  Future<void> _openRecentlyDeleted() async {
    await Navigator.of(context).push(RecentlyDeletedScreen.route());
    if (mounted) await _countDeleted();
  }

  Future<void> _import() async {
    final app = AppScope.read(context);
    final n = await app.importRecordings();
    if (!mounted || n == null) return;
    showToast(
      context,
      n == 0
          ? 'No new recordings were found there'
          : n == 1
          ? '1 recording imported'
          : '$n recordings imported',
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final settings = app.settings;
    final deleted = _deleted;

    return ScreenFrame(
      child: Column(
        children: [
          RedHeader(
            title: 'Voice Recorder',
            children: [
              Positioned(
                left: 10.9,
                top: 6.6,
                width: 34.3,
                height: 34.3,
                child: Semantics(
                  label: 'Voice Recorder',
                  child: Image.asset(
                    'assets/images/app_icon.png',
                    filterQuality: FilterQuality.medium,
                  ),
                ),
              ),
            ],
          ),
          Expanded(
            child: BrushedMetal(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  const _Section('Recorder'),
                  _Item(
                    icon: const InkIcon(
                      AppIcons.file,
                      size: Size(22.0, 24.0),
                      color: Color(0xFFFFFFFF),
                    ),
                    title: 'Recording type',
                    summary: settings.type.label,
                    onTap: () async {
                      final i = await showChoiceDialog(
                        context,
                        title: 'Recording type',
                        items: [for (final t in RecordingType.values) t.label],
                        selected: settings.type.index,
                      );
                      if (i != null) settings.type = RecordingType.values[i];
                    },
                  ),
                  _Item(
                    icon: const InkIcon(
                      AppIcons.quality,
                      size: Size(26.6, 28.3),
                      color: Color(0xFFFFFFFF),
                    ),
                    title: 'Recording quality',
                    summary: settings.quality.label,
                    onTap: () async {
                      final i = await showChoiceDialog(
                        context,
                        title: 'Recording quality',
                        items: [
                          for (final q in RecordingQuality.values) q.label,
                        ],
                        selected: settings.quality.index,
                      );
                      if (i != null) {
                        settings.quality = RecordingQuality.values[i];
                      }
                    },
                  ),
                  _Item(
                    icon: const InkIcon(
                      AppIcons.noise,
                      size: Size(23.6, 23.7),
                      color: Color(0xFFFFFFFF),
                    ),
                    title: 'Noise reduction',
                    summary: 'Filters out background noise (MP3 and WAV)',
                    trailing: _HoloCheckBox(checked: settings.noiseReduction),
                    checked: settings.noiseReduction,
                    onTap: () =>
                        settings.noiseReduction = !settings.noiseReduction,
                  ),
                  _Item(
                    icon: const InkIcon(
                      AppIcons.folderOpen,
                      size: Size(24.6, 19.7),
                      color: Color(0xFFFFFFFF),
                    ),
                    title: 'Folder',
                    summary: app.store.folderDisplayPath,
                    onTap: app.isRecording
                        ? null
                        : () async {
                            if (Platform.isAndroid) {
                              await showChooseFolderDialog(context);
                            } else {
                              await app.chooseFolder();
                            }
                          },
                  ),
                  if (Platform.isIOS)
                    _Item(
                      icon: const InkIcon(
                        AppIcons.import,
                        size: Size(19.0, 23.2),
                        color: Color(0xFFFFFFFF),
                      ),
                      title: 'Import recordings',
                      summary: 'From Files, iCloud Drive or a USB drive',
                      onTap: _import,
                    ),
                  _Item(
                    icon: const InkIcon(
                      AppIcons.recentlyDeleted,
                      size: Size(24.0, 24.0),
                      color: Color(0xFFFFFFFF),
                    ),
                    title: 'Recently deleted',
                    summary: switch (deleted) {
                      null || 0 => 'Deleted recordings are kept for 30 days',
                      1 => '1 recording, kept for 30 days',
                      _ => '$deleted recordings, kept for 30 days',
                    },
                    divider: false,
                    onTap: _openRecentlyDeleted,
                  ),
                  const _Section('Playback'),
                  _Item(
                    icon: const InkIcon(
                      AppIcons.lock,
                      size: Size(17.9, 23.4),
                      color: Color(0xFFFFFFFF),
                    ),
                    title: 'Lock screen controls',
                    summary: settings.lockScreenControls
                        ? 'Keeps playing in the background, with controls on '
                              'the lock screen'
                        : 'Playback stops when you leave the app',
                    trailing: _HoloCheckBox(
                      checked: settings.lockScreenControls,
                    ),
                    checked: settings.lockScreenControls,
                    onTap: () => settings.lockScreenControls =
                        !settings.lockScreenControls,
                  ),
                  _Item(
                    icon: const InkIcon(
                      AppIcons.speed,
                      size: Size(26.6, 21.3),
                      color: Color(0xFFFFFFFF),
                    ),
                    title: 'Playback speed',
                    summary: formatSpeed(settings.playbackSpeed),
                    divider: false,
                    onTap: () async {
                      final i = await showChoiceDialog(
                        context,
                        title: 'Playback speed',
                        items: [for (final v in playbackSpeeds) formatSpeed(v)],
                        selected: playbackSpeeds.indexOf(
                          settings.playbackSpeed,
                        ),
                      );
                      if (i != null) settings.playbackSpeed = playbackSpeeds[i];
                    },
                  ),
                  const _Section('More app'),
                  _Item(
                    icon: const InkIcon(
                      AppIcons.star,
                      size: Size(24.3, 23.1),
                      color: Color(0xFFFFFFFF),
                    ),
                    title: 'Rate 5 stars',
                    onTap: () => _rate(context),
                  ),
                  _Item(
                    icon: const InkIcon(
                      AppIcons.about,
                      size: Size(23.4, 23.4),
                      color: Color(0xFFFFFFFF),
                    ),
                    title: 'About',
                    onTap: () => _about(context),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  static Future<void> _rate(BuildContext context) async {
    Uri? uri;
    if (Platform.isAndroid) {
      final info = await PackageInfo.fromPlatform();
      uri = Uri.parse('market://details?id=${info.packageName}');
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        uri = Uri.parse(
          'https://play.google.com/store/apps/details?id=${info.packageName}',
        );
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
      return;
    }
    if (AppConfig.appStoreId.isEmpty) {
      if (context.mounted) showToast(context, 'Thank you!');
      return;
    }
    uri = Uri.parse(
      'https://apps.apple.com/app/id${AppConfig.appStoreId}?action=write-review',
    );
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  static Future<void> _about(BuildContext context) async {
    final info = await PackageInfo.fromPlatform();
    if (!context.mounted) return;
    final version = '${info.version} (${info.buildNumber})';
    final licenses = await showSpecDialog<bool>(
      context,
      (ctx) => HoloDialog(
        title: 'About',
        message:
            'Voice Recorder\nVersion $version\n\n'
            'A faithful revival of the classic 2016 voice recorder.\n\n'
            'MP3 encoding by LAME (lame.sourceforge.io), used under the GNU '
            'LGPL. Its source code is part of this app\'s source code.',
        buttons: [
          HoloButton('Licenses', onTap: () => Navigator.of(ctx).pop(true)),
          HoloButton('OK', onTap: () => Navigator.of(ctx).pop(false)),
        ],
      ),
    );
    if (licenses != true || !context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Theme(
          // The app theme is tuned for the black screens; use a light one here.
          data: ThemeData(
            useMaterial3: true,
            fontFamily: Spec.font,
            colorSchemeSeed: const Color(0xFF7D0505),
          ),
          child: LicensePage(
            applicationName: 'Voice Recorder',
            applicationVersion: version,
            applicationIcon: Padding(
              padding: const EdgeInsets.all(8),
              child: Image.asset('assets/images/app_icon.png', width: 48),
            ),
          ),
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Spec.sectionOverlay,
      child: Padding(
        padding: const EdgeInsets.only(
          left: Spec.sectionTextLeft,
          top: Spec.sectionPaddingTop,
          bottom: Spec.sectionPaddingBottom,
        ),
        child: Align(
          alignment: Alignment.centerLeft,
          child: AText(title, style: Spec.sectionText, maxLines: 1),
        ),
      ),
    );
  }
}

class _Item extends StatelessWidget {
  const _Item({
    required this.icon,
    required this.title,
    this.summary,
    this.onTap,
    this.divider = true,
    this.trailing,
    this.checked,
  });

  final Widget icon;
  final String title;
  final String? summary;
  final VoidCallback? onTap;
  final bool divider;

  /// A check box at the right end of the row.
  final Widget? trailing;

  /// For accessibility: the state of a check-box row.
  final bool? checked;

  @override
  Widget build(BuildContext context) {
    final hairline = 1 / MediaQuery.devicePixelRatioOf(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PressableArea(
          onTap: onTap,
          selected: checked,
          semanticLabel: summary == null ? title : '$title, $summary',
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: Spec.settingsRowHeight,
            ),
            child: Stack(
              children: [
                Positioned(
                  left: 0,
                  width: Spec.settingsIconCenterX * 2,
                  top: 0,
                  bottom: 0,
                  child: Center(child: icon),
                ),
                if (trailing != null)
                  Positioned(
                    right: 16,
                    top: 0,
                    bottom: 0,
                    child: Center(child: trailing),
                  ),
                Padding(
                  padding: EdgeInsets.only(
                    left: Spec.settingsTextLeft,
                    right: trailing == null ? 12 : 56,
                  ),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: Spec.settingsRowHeight,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        AText(title, style: Spec.settingsTitle),
                        if (summary != null) ...[
                          const SizedBox(height: Spec.settingsLineGap),
                          AText(summary!, style: Spec.settingsSummary),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        // ListView divider: one physical pixel below every row (invisible
        // before a section header, like the original).
        Padding(
          padding: const EdgeInsets.only(left: Spec.settingsTextLeft),
          child: SizedBox(
            height: hairline,
            width: double.infinity,
            child: divider
                ? const ColoredBox(color: Spec.settingsDivider)
                : null,
          ),
        ),
      ],
    );
  }
}

/// A Holo (dark) check box: a light square, with a blue tick when on.
class _HoloCheckBox extends StatelessWidget {
  const _HoloCheckBox({required this.checked});

  final bool checked;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 24,
    child: CustomPaint(painter: _CheckBoxPainter(checked)),
  );
}

class _CheckBoxPainter extends CustomPainter {
  _CheckBoxPainter(this.checked);

  final bool checked;

  @override
  void paint(Canvas canvas, Size size) {
    final box = Rect.fromCenter(
      center: size.center(Offset.zero),
      width: 17,
      height: 17,
    );
    canvas
      ..drawRect(box, Paint()..color = const Color(0x33000000))
      ..drawRect(
        box,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = const Color(0xFFD8D8D8),
      );
    if (!checked) return;
    final tick = Path()
      ..moveTo(box.left + 3.2, box.center.dy + 0.2)
      ..lineTo(box.left + 7.2, box.bottom - 3.6)
      ..lineTo(box.right + 2.6, box.top - 3.2);
    canvas.drawPath(
      tick,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = Spec.holoBlue,
    );
  }

  @override
  bool shouldRepaint(_CheckBoxPainter old) => old.checked != checked;
}
