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
  final stopping = app.isRecording;
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
          title: 'Microphone',
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
          reason:
              "The recording couldn't be saved to the folder. It's kept, and "
              'saved as soon as you choose the folder.',
        );
      } else {
        showToast(
          context,
          "The recording couldn't be saved to the folder yet. It will be "
          'saved the next time the app starts.',
        );
      }
    case RecordOutcome.noSpace:
      showToast(context, 'Not enough storage left to record');
    case RecordOutcome.failed:
      showToast(
        context,
        stopping
            ? "The recording couldn't be saved"
            : "Couldn't start recording",
      );
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
  if (renamed == null && context.mounted) {
    showToast(context, _failed(app, "Couldn't rename the recording"));
  }
  return renamed;
}

/// [message], or, when the folder itself can't be reached, how to fix that.
String _failed(AppController app, String message) => app.store.isReady
    ? message
    : "The folder can't be reached. Choose it again in Settings > Folder.";

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
  // The Undo toast is shown even if the user has left the screen meanwhile.
  final navigator = Navigator.of(context, rootNavigator: true);
  final deleted = await runWithProgress(
    context,
    title: 'Deleting',
    total: files.length,
    label: (s) =>
        'Moving ${formatCount(s.done)} of ${formatCount(s.total)} recordings '
        'to Recently deleted…',
    job: (onProgress, cancelled) =>
        app.delete(files, onProgress: onProgress, cancelled: cancelled),
  );
  if (!navigator.mounted) return deleted.items.isNotEmpty;
  if (deleted.items.isEmpty) {
    if (deleted.failed > 0) {
      showToast(
        navigator.context,
        _failed(
          app,
          files.length == 1
              ? "Couldn't delete the recording"
              : "Couldn't delete the recordings",
        ),
      );
    }
    return false;
  }
  final n = deleted.items.length;
  final message = deleted.failed > 0
      ? '${formatCount(n)} ${n == 1 ? 'recording' : 'recordings'} moved to '
            "Recently deleted. ${formatCount(deleted.failed)} couldn't be "
            'moved.'
      : n == 1
      ? 'Moved to Recently deleted'
      : '${formatCount(n)} recordings moved to Recently deleted';
  showActionToast(
    navigator.context,
    message,
    action: 'Undo',
    onAction: () => _undo(navigator, app, deleted),
  );
  return true;
}

/// Puts back what a delete moved to Recently deleted (with progress when
/// it's many).
Future<void> _undo(
  NavigatorState navigator,
  AppController app,
  DeletedRecordings deleted,
) async {
  if (!navigator.mounted) {
    await app.undoDelete(deleted);
    return;
  }
  await runWithProgress(
    navigator.context,
    title: 'Restoring',
    total: deleted.items.length,
    label: (s) =>
        'Restoring ${formatCount(s.done)} of ${formatCount(s.total)} '
        'recordings…',
    job: (onProgress, cancelled) =>
        app.undoDelete(deleted, onProgress: onProgress, cancelled: cancelled),
  );
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
    showToast(
      context,
      files.length == 1
          ? "Couldn't share the recording"
          : "Couldn't share the recordings",
    );
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
          'To keep using your existing recordings, select '
          '${app.store.folderDisplayPath} (create a folder named "Recorders" '
          'if it does not exist yet), tap "Use this folder", then "Allow".',
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
  final other = r.failed - r.full;
  final ignored = r.ignored == 0
      ? null
      : '${count(r.ignored, '1 sound file', 'sound files')} in other formats '
            '(like AMR or OGG) ${r.ignored == 1 ? 'was' : 'were'} left out.';
  if (r.copied + r.skipped + r.failed == 0 && !r.cancelled) {
    return [
      'No recordings were found there (MP3, WAV, M4A, AAC or FLAC).',
      ?ignored,
    ].join(' ');
  }
  return [
    if (r.copied > 0)
      '${count(r.copied, '1 recording', 'recordings')} imported.'
    else if (r.failed == 0 && !r.cancelled)
      'Nothing new to import.',
    if (r.skipped > 0)
      '${count(r.skipped, '1 was', 'were')} already in the app.',
    if (r.full > 0)
      "${formatCount(r.full)} couldn't be copied because the iPhone is full.",
    if (other > 0)
      "${formatCount(other)} couldn't be copied. Import again to try them "
          'once more (what is already in the app is skipped).',
    ?ignored,
    if (r.cancelled)
      'The import was stopped. Import the same folder again to go on.',
  ].join(' ');
}

/// The message after storing dates in recordings (Android), [of] how many
/// were to be done.
String storedDatesMessage(StoredDates r, {required int of}) {
  String some(int n) => n == 1 ? '1 recording' : '${formatCount(n)} recordings';
  String names(List<String> list) {
    final shown = list.take(5).map((n) => '"$n"').join(', ');
    return list.length > 5
        ? '$shown and ${formatCount(list.length - 5)} more'
        : shown;
  }

  final stopped = r.stoppedAt;
  return [
    if (r.stored > 0) 'The date is now stored in ${some(r.stored)}.',
    if (r.refused.isNotEmpty)
      "${some(r.refused.length)} couldn't take one: ${names(r.refused)}. To "
          'keep their dates, start their names with the date, like '
          '"2016_05_23_18_14_00 lunch".',
    if (stopped != null)
      '"$stopped" couldn\'t be written, so it stopped there. Is the storage '
          'full? Its date is kept in the app.',
    if (stopped == null && r.stored + r.refused.length < of)
      'It was stopped. The others can be done later.',
  ].join(' ');
}

/// Tells the user why pressing play didn't play anything.
void showPlayProblem(BuildContext context, PlayOutcome outcome) {
  switch (outcome) {
    case PlayOutcome.ok:
      return;
    case PlayOutcome.notPlayable:
      showToast(context, "Can't play this recording");
    case PlayOutcome.audioBusy:
      showToast(context, "Can't play while a call or another app uses audio");
    case PlayOutcome.recording:
      showToast(context, "Can't play while recording");
  }
}
