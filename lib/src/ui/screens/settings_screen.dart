import 'dart:io';

import 'package:flutter/material.dart'
    show LicensePage, MaterialPageRoute, Theme, ThemeData;
import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../config.dart';
import '../../core/recording_format.dart';
import '../app_scope.dart';
import '../dialogs/dialogs.dart';
import '../icons/app_icons.dart';
import '../spec.dart';
import '../widgets/frame.dart';
import '../widgets/recorder_widgets.dart';
import '../widgets/red_bars.dart';
import '../widgets/toast.dart';
import 'common_actions.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  static Route<void> route() =>
      MaterialPageRoute<void>(builder: (_) => const SettingsScreen());

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final settings = app.settings;

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
                      AppIcons.folderOpen,
                      size: Size(24.6, 19.7),
                      color: Color(0xFFFFFFFF),
                    ),
                    title: 'Folder',
                    summary: app.store.folderDisplayPath,
                    divider: false,
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
                  const _Section('More app'),
                  _Item(
                    icon: const AdsBadge(size: 31.7, colored: true),
                    title: 'Remove ads',
                    onTap: () => showRemoveAdsDialog(context),
                  ),
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
  });

  final Widget icon;
  final String title;
  final String? summary;
  final VoidCallback? onTap;
  final bool divider;

  @override
  Widget build(BuildContext context) {
    final hairline = 1 / MediaQuery.devicePixelRatioOf(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PressableArea(
          onTap: onTap,
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
                Padding(
                  padding: const EdgeInsets.only(
                    left: Spec.settingsTextLeft,
                    right: 12,
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
