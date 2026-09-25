import 'package:flutter/widgets.dart';

import '../../app_controller.dart';
import '../../core/recording_file.dart';
import '../app_scope.dart';
import '../dialogs/dialogs.dart';
import '../widgets/toast.dart';

/// Rename flow shared by the Recorder header and the list's bottom bar.
Future<RecordingFile?> renameRecording(
  BuildContext context,
  RecordingFile file,
) async {
  final app = AppScope.read(context);
  final name = await showRenameDialog(context, file.baseName);
  if (name == null || !context.mounted) return null;
  final renamed = await app.rename(file, name);
  if (renamed == null && context.mounted) showToast(context, 'Rename failed');
  return renamed;
}

/// Delete flow with the Holo confirmation.
Future<bool> deleteRecording(BuildContext context, RecordingFile file) async {
  final app = AppScope.read(context);
  if (!await showDeleteDialog(context, file.name) || !context.mounted) {
    return false;
  }
  final ok = await app.delete(file);
  if (!ok && context.mounted) showToast(context, 'Delete failed');
  return ok;
}

Future<void> shareRecording(
  BuildContext context,
  RecordingFile file, {
  Rect? origin,
}) async {
  final app = AppScope.read(context);
  final box = context.findRenderObject() as RenderBox?;
  final rect =
      origin ??
      (box == null ? null : box.localToGlobal(Offset.zero) & box.size);
  await app.share(file, origin: rect);
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

/// Tells the user why pressing play didn't play anything.
void showPlayProblem(BuildContext context, PlayOutcome outcome) {
  switch (outcome) {
    case PlayOutcome.ok:
      return;
    case PlayOutcome.notPlayable:
      showToast(context, "Can't play this file");
    case PlayOutcome.audioBusy:
      showToast(context, "Can't play while a call or another app uses audio");
  }
}
