import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart'
    show ColorScheme, LicensePage, MaterialPageRoute, Theme, ThemeData;
import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../config.dart';
import '../../core/format.dart';
import '../../core/recording_format.dart';
import '../../core/settings.dart';
import '../../platform/native_bridge.dart';
import '../app_scope.dart';
import '../dialogs/dialogs.dart';
import '../icons/app_icons.dart';
import '../spec.dart';
import '../widgets/frame.dart';
import '../widgets/holo_check_box.dart';
import '../widgets/red_bars.dart';
import '../widgets/toast.dart';
import 'common_actions.dart';
import 'recently_deleted_screen.dart';

/// Width of the header's "up" button on iPhone (the caret and the app icon).
const double _upWidth = 66;

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

  /// The controller's trash version counted last.
  int? _counted;

  bool _listed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Android: "Store dates in recordings" needs the folder's recordings,
    // which may not have been listed yet (Settings opens from the
    // Recorder).
    if (!_listed && Platform.isAndroid) {
      _listed = true;
      unawaited(AppScope.read(context).refreshFiles());
    }
    // Counted again after a delete or an undo (the undo toast stays up
    // across screens).
    final version = AppScope.of(context).trashVersion;
    if (_counted != version) {
      _counted = version;
      _countDeleted();
    }
  }

  Future<void> _countDeleted() async {
    final list = await AppScope.read(context).deletedRecordings();
    if (mounted) setState(() => _deleted = list?.length);
  }

  Future<void> _openRecentlyDeleted() async {
    await Navigator.of(context).push(RecentlyDeletedScreen.route());
    if (mounted) await _countDeleted();
  }

  /// iPhone: brings in recordings from the Files app, a whole folder (the
  /// usual way, for many) or single ones.
  Future<void> _import() async {
    final app = AppScope.read(context);
    final choice = await showChoiceDialog(
      context,
      title: 'Import recordings',
      items: const ['A folder, with all its recordings', 'Single recordings'],
      selected: -1,
    );
    if (choice == null || !mounted) return;
    final navigator = Navigator.of(context, rootNavigator: true);
    // Progress shows once the copying starts (after the Files picker).
    final state = ValueNotifier<JobState>((done: 0, total: 0));
    ProgressDialogRoute? dialog;
    void follow() {
      final p = app.importProgress;
      if (p == null) return;
      state.value = p;
      if (dialog == null && navigator.mounted) {
        dialog = ProgressDialogRoute(
          title: 'Importing',
          state: state,
          label: (s) => s.total == 0
              ? 'Looking for recordings…'
              : 'Copying ${formatCount(s.done)} of ${formatCount(s.total)} '
                    "recordings… Keep the app open until it's done.",
          onCancel: app.cancelImport,
        );
        unawaited(navigator.push(dialog!));
      }
    }

    app.addListener(follow);
    final ImportResult? result;
    try {
      result = await app.importRecordings(folder: choice == 0);
    } finally {
      app.removeListener(follow);
      final d = dialog;
      if (d != null && d.isActive) navigator.removeRoute(d);
      WidgetsBinding.instance.addPostFrameCallback((_) => state.dispose());
    }
    if (result == null || !navigator.mounted) return;
    await showMessageDialog(
      navigator.context,
      title: 'Import recordings',
      message: importMessage(result),
    );
  }

  /// Android: stores the date of each renamed recording inside it, so it is
  /// kept when the recordings are moved to a new phone.
  Future<void> _storeDates() async {
    final app = AppScope.read(context);
    if (!app.store.isReady) {
      await showChooseFolderDialog(context);
      return;
    }
    final files = app.datesToStore;
    if (files == null) {
      showToast(
        context,
        'Still checking the recordings. Try again in a moment',
      );
      return;
    }
    if (files.isEmpty) {
      showToast(context, 'Every recording already has its date inside');
      return;
    }
    final n = files.length;
    final ok = await showConfirmDialog(
      context,
      title: 'Store dates in recordings',
      message:
          '${n == 1 ? '1 renamed recording has' : '${formatCount(n)} renamed recordings have'} '
          "no date inside them, only the file's own date, which is often lost "
          'when recordings are copied to another phone. This stores each date '
          'inside its recording, so it goes wherever the recording goes.\n\n'
          "The sound isn't changed. Other apps (like My Files) will show "
          'these recordings as modified today.',
      ok: 'Store dates',
    );
    if (!ok || !mounted) return;
    final result = await runWithProgress(
      context,
      title: 'Storing dates',
      total: n,
      quietUpTo: 0,
      label: (s) =>
          'Storing the date in ${formatCount(s.done)} of ${formatCount(s.total)} '
          'recordings…',
      job: (onProgress, cancelled) =>
          app.storeDates(files, onProgress: onProgress, cancelled: cancelled),
    );
    if (!mounted) return;
    await showMessageDialog(
      context,
      title: 'Store dates in recordings',
      message: storedDatesMessage(result, of: n),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final settings = app.settings;
    final deleted = _deleted;
    // On iPhone the page goes on under the home indicator; the list's end can
    // scroll clear of it.
    final homeIndicator = ScreenFrame.underHomeIndicator
        ? MediaQuery.viewPaddingOf(context).bottom
        : 0.0;
    final appIcon = Semantics(
      label: 'Voice Recorder',
      child: Image.asset(
        'assets/images/app_icon.png',
        filterQuality: FilterQuality.medium,
      ),
    );

    return ScreenFrame(
      child: Column(
        children: [
          RedHeader(
            title: 'Voice Recorder',
            children: [
              // An iPhone has no Back button: an "up" caret before the icon
              // goes back, where the other screens have their back arrow.
              if (defaultTargetPlatform == TargetPlatform.iOS)
                BarButton(
                  center: const Offset(_upWidth / 2, Spec.headerHeight / 2),
                  touchSize: const Size(_upWidth, Spec.headerHeight),
                  semanticLabel: 'Back',
                  onTap: () => Navigator.of(context).maybePop(),
                  child: SizedBox(
                    width: _upWidth,
                    height: Spec.headerHeight,
                    child: Stack(
                      children: [
                        const Positioned(
                          left: 18.26 - 13.7 / 2,
                          top: 23.14 - 26.3 / 2,
                          child: InkIcon(
                            AppIcons.back,
                            size: Size(13.7, 26.3),
                            color: Color(0xFFFFFFFF),
                          ),
                        ),
                        Positioned(
                          left: 30,
                          top: 6.6,
                          width: 34.3,
                          height: 34.3,
                          child: appIcon,
                        ),
                      ],
                    ),
                  ),
                )
              else
                Positioned(
                  left: 10.9,
                  top: 6.6,
                  width: 34.3,
                  height: 34.3,
                  child: appIcon,
                ),
            ],
          ),
          Expanded(
            child: BrushedMetal(
              child: ListView(
                padding: EdgeInsets.only(bottom: homeIndicator),
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
                    summary: settings.type == RecordingType.m4a
                        ? 'Not used for M4A recordings'
                        : 'Filters out background noise',
                    trailing: HoloCheckBox(checked: settings.noiseReduction),
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
                    summary: !app.store.folderChosen
                        ? 'Not chosen yet. Tap to choose it'
                        : app.store.isReady
                        ? app.store.folderDisplayPath
                        : "${app.store.folderDisplayPath} can't be reached. "
                              'Tap to choose it again',
                    onTap: () async {
                      if (app.isRecording) {
                        showToast(
                          context,
                          'Stop recording to change the folder',
                        );
                      } else if (Platform.isAndroid) {
                        await showChooseFolderDialog(context);
                      } else {
                        await app.chooseFolder();
                      }
                    },
                  ),
                  if (Platform.isAndroid)
                    _Item(
                      icon: const InkIcon(
                        AppIcons.calendar,
                        size: Size(20.0, 22.2),
                        color: Color(0xFFFFFFFF),
                      ),
                      title: 'Store dates in recordings',
                      summary: switch (app.datesToStore?.length) {
                        _ when !app.store.isReady =>
                          'Choose the recordings folder first',
                        null => 'Checking the recordings…',
                        0 => 'Every recording has its date inside',
                        1 =>
                          'For moving to a new phone: 1 renamed recording '
                              'needs it',
                        final n =>
                          'For moving to a new phone: ${formatCount(n)} '
                              'renamed recordings need it',
                      },
                      onTap: _storeDates,
                    ),
                  if (Platform.isIOS)
                    _Item(
                      icon: const InkIcon(
                        AppIcons.import,
                        size: Size(19.0, 23.2),
                        color: Color(0xFFFFFFFF),
                      ),
                      title: 'Import recordings',
                      summary: switch (app.importProgress) {
                        null => 'From Files, iCloud Drive or a USB drive',
                        (done: _, total: 0) => 'Looking for recordings…',
                        (:final done, :final total) =>
                          'Copying ${formatCount(done)} of '
                              '${formatCount(total)}… Keep the app open.',
                      },
                      onTap: app.importProgress == null ? _import : null,
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
                      _ =>
                        '${formatCount(deleted)} recordings, kept for 30 days',
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
                        : 'Playback pauses when you leave the app or lock the '
                              'phone',
                    trailing: HoloCheckBox(
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
                  // On iPhone once the app is in the App Store (it needs its
                  // id).
                  if (!Platform.isIOS || AppConfig.appStoreId.isNotEmpty)
                    _Item(
                      icon: const InkIcon(
                        AppIcons.star,
                        size: Size(24.3, 23.1),
                        color: Color(0xFFFFFFFF),
                      ),
                      // The App Store's rules don't allow asking for a
                      // number of stars.
                      title: Platform.isIOS ? 'Rate this app' : 'Rate 5 stars',
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
            'LGPL. Its source code is available there, and is included with '
            "this app's source code.",
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
            colorScheme: const ColorScheme.light(primary: Color(0xFF7D0505)),
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
          checked: checked,
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
