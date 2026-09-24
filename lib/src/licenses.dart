import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Adds the licenses of bundled code and artwork that Flutter does not collect
/// by itself to the app's license page (Settings > About > Licenses).
void registerThirdPartyLicenses() => LicenseRegistry.addLicense(_licenses);

Stream<LicenseEntry> _licenses() async* {
  for (final (packages, asset) in const [
    (['LAME MP3 encoder'], 'assets/licenses/LAME-COPYING.txt'),
    (['Roboto', 'Material Icons'], 'assets/fonts/Roboto-LICENSE.txt'),
    (['Font Awesome'], 'assets/licenses/FontAwesome-OFL.txt'),
    (['Ionicons'], 'assets/licenses/Ionicons-MIT.txt'),
  ]) {
    try {
      yield LicenseEntryWithLineBreaks(
        packages,
        await rootBundle.loadString(asset),
      );
    } catch (_) {
      // asset missing in a trimmed build
    }
  }
}
