import 'package:flutter/widgets.dart';

import '../../app_controller.dart';
import '../../core/format.dart';
import '../../core/recording_file.dart';
import '../../platform/native_bridge.dart';
import '../app_scope.dart';
import '../dialogs/dialogs.dart';
import '../widgets/toast.dart';

/// The record button: starts a recording (asking for the folder or the
/// microphone first if needed) or stops the one running.
Future<void> toggleRecording(BuildContext context) async {
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

/// Pauses or resumes the running recording.
Future<void> togglePauseRecording(BuildContext context) async {
  final app = AppScope.read(context);
  final resuming = app.isPaused;
  if (!await app.togglePauseRecording() && context.mounted && resuming) {
    showToast(context, "The recording can't continue right now");
  }
}

/// Rename flow shared by the Recorder header and the list's bottom bar.
Future<RecordingFile?> renameRecording(
  BuildContext context,
  RecordingFile file,
) async {
  final app = AppScope.read(context);
  final name = await showRenameDialog(context, file.baseName);
  if (name == null || !context.mounted) return null;
  if (sanitizeFileName(name).isEmpty) {
    showToast(context, 'Enter a name for the file');
    return null;
  }
  final renamed = await app.rename(file, name);
  if (renamed == null && context.mounted) showToast(context, 'Rename failed');
  return renamed;
}

/// Delete flow with the Holo confirmation. The files go to Recently deleted,
/// and a toast offers to undo it. Returns true if anything was deleted.
Future<bool> deleteRecordings(
  BuildContext context,
  List<RecordingFile> files,
) async {
  if (files.isEmpty) return false;
  final app = AppScope.read(context);
  final confirmed = await showDeleteDialog(
    context,
    files.first.name,
    count: files.length,
  );
  if (!confirmed || !context.mounted) return false;
  if (files.length > 20) {
    showToast(
      context,
      'Moving ${formatCount(files.length)} recordings to Recently deleted…',
      long: true,
    );
  }
  final deleted = await app.delete(files);
  if (!context.mounted) return deleted.items.isNotEmpty;
  if (deleted.items.isEmpty) {
    showToast(context, 'Delete failed');
    return false;
  }
  final n = deleted.items.length;
  final message = deleted.failed > 0
      ? "Deleted ${formatCount(n)}. ${formatCount(deleted.failed)} couldn't be "
            'deleted.'
      : n == 1
      ? 'Moved to Recently deleted'
      : '${formatCount(n)} recordings moved to Recently deleted';
  showActionToast(
    context,
    message,
    action: 'Undo',
    onAction: () => app.undoDelete(deleted),
  );
  return true;
}

Future<bool> deleteRecording(BuildContext context, RecordingFile file) =>
    deleteRecordings(context, [file]);

Future<void> shareRecording(
  BuildContext context,
  RecordingFile file, {
  Rect? origin,
}) => shareRecordings(context, [file], origin: origin);

Future<void> shareRecordings(
  BuildContext context,
  List<RecordingFile> files, {
  Rect? origin,
}) async {
  final app = AppScope.read(context);
  if (files.length > maxShareCount) {
    showToast(context, 'Share up to $maxShareCount recordings at a time');
    return;
  }
  final box = context.findRenderObject() as RenderBox?;
  final rect =
      origin ??
      (box == null ? null : box.localToGlobal(Offset.zero) & box.size);
  if (!await app.shareAll(files, origin: rect) && context.mounted) {
    showToast(context, "Couldn't open sharing");
  }
}

/// Explains the folder permission and opens the system folder picker.
/// [reason] is shown first when the dialog appears because something failed.
Future<bool> showChooseFolderDialog(
  BuildContext context, {
  String? reason,
}) async {
  final app = AppScope.read(context);
  final go = await showSpecDialog<bool>(
    context,
    (ctx) => HoloDialog(
      title: 'Folder',
      message:
          '${reason == null ? '' : '$reason\n\n'}'
          'Choose the folder for your recordings.\n\n'
          'To keep using your existing recordings, select ${app.store.folderDisplayPath} '
          '(create a folder named "Recorders" if it does not exist yet) and tap "Use this folder".',
      buttons: [
        HoloButton('Cancel', onTap: () => Navigator.of(ctx).pop(false)),
        HoloButton('OK', onTap: () => Navigator.of(ctx).pop(true)),
      ],
    ),
  );
  if (go != true || !context.mounted) return false;
  return app.chooseFolder();
}

/// The message after an import from Files (iPhone).
String importMessage(ImportResult r) {
  String count(int n, String one, String more) =>
      n == 1 ? one : '${formatCount(n)} $more';
  if (r.copied + r.skipped + r.failed == 0) {
    return 'No recordings were found there (MP3, WAV, M4A, AAC or FLAC).';
  }
  return [
    if (r.copied > 0)
      '${count(r.copied, '1 recording', 'recordings')} imported.'
    else if (r.failed == 0)
      'Nothing new to import.',
    if (r.skipped > 0) '${count(r.skipped, '1 was', 'were')} already here.',
    if (r.failed > 0)
      "${formatCount(r.failed)} couldn't be copied. Is the iPhone full?",
  ].join(' ');
}

/// Tells the user why pressing play didn't play anything.
void showPlayProblem(BuildContext context, PlayOutcome outcome) {
  switch (outcome) {
    case PlayOutcome.ok:
      return;
    case PlayOutcome.notPlayable:
      showToast(context, "Can't play this file");
    case PlayOutcome.audioBusy:
      showToast(context, "Can't play while a call or another app uses audio");
    case PlayOutcome.recording:
      showToast(context, 'Stop recording to play a file');
  }
}
