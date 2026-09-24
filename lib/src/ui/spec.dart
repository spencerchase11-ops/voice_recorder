import 'package:flutter/painting.dart';

/// Visual specification of the original 2016 app.
///
/// Every number here was measured from 1440x3120 screenshots of the original
/// app running on a 3.5x-density phone with a system font scale of ~1.077 (see
/// docs/SPEC.md for the method). Lengths are logical pixels (dp); font sizes
/// are in sp and are scaled by the platform text scaler, exactly like the
/// original's `sp` units. Vertical positions are relative to the container
/// named in each section.
abstract final class Spec {
  // ------------------------------------------------------------ system bars
  static const Color statusBarColor = Color(0xFF000000);
  static const Color navigationBarColor = Color(0xFFF1F1F3);

  // ------------------------------------------------------------- red bars
  static const double headerHeight = 48;

  /// Header (action bar) gradient, top to bottom.
  static const LinearGradient headerGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      Color(0xFF740504),
      Color(0xFF7B0505),
      Color(0xFF7D0505),
      Color(0xFF7A0506),
      Color(0xFF770505),
      Color(0xFF720505),
      Color(0xFF6C0505),
      Color(0xFF610505),
      Color(0xFF580505),
      Color(0xFF4F0504),
      Color(0xFF4A0606),
      Color(0xFF3D0505),
      Color(0xFF2D0404),
      Color(0xFF1F0303),
      Color(0xFF1A0405),
    ],
    stops: [
      0.0,
      0.036,
      0.083,
      0.18,
      0.25,
      0.35,
      0.42,
      0.535,
      0.63,
      0.727,
      0.773,
      0.83,
      0.894,
      0.965,
      1.0,
    ],
  );

  /// Gradient of the bottom tab bar and the list's bottom action bar.
  static const LinearGradient footerGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      Color(0xFF7E0A0B),
      Color(0xFF880505),
      Color(0xFF870606),
      Color(0xFF830606),
      Color(0xFF7F0605),
      Color(0xFF780505),
      Color(0xFF6E0505),
      Color(0xFF610505),
      Color(0xFF550505),
      Color(0xFF4D0506),
      Color(0xFF3C0405),
      Color(0xFF2B0404),
      Color(0xFF1B0303),
    ],
    stops: [
      0.0,
      0.012,
      0.056,
      0.109,
      0.163,
      0.25,
      0.4,
      0.53,
      0.667,
      0.755,
      0.83,
      0.9,
      1.0,
    ],
  );

  static const Color barDividerColor = Color(0xFF0B0000);
  static const double barDividerWidth = 0.857;

  // ------------------------------------------------------- brushed metal
  static const String metalTexture = 'assets/images/brushed_metal.jpg';

  /// The settings section headers are the page texture under 25% white.
  static const Color sectionOverlay = Color(0x40FFFFFF);

  // ------------------------------------------------------------ fonts
  static const String font = 'Roboto';

  static const TextStyle headerTitle = TextStyle(
    fontFamily: font,
    fontSize: 18,
    fontWeight: FontWeight.w700,
    color: Color(0xFFFFFFFF),
  );

  // ------------------------------------------------------ recorder screen
  /// Offsets inside the body (the area between the header and the tab bar).
  static const double adsButtonInset = 16;
  static const double adsButtonSize = 26;

  /// The timer box is vertically centred in the body, 2.5 dp low.
  static const double timerCenterOffset = 2.5;
  static const double timerBoxWidth = 242.6;
  static const double timerBoxHeight = 67.7;
  static const double timerBoxRadius = 4.5;
  static const double timerBevel = 2.3;
  static const TextStyle timerText = TextStyle(
    fontFamily: font,
    fontSize: 45,
    color: Color(0xFFFFFFFF),
  );

  /// Microphone artwork: 148 x 253.14 dp canvas whose bottom sits 0.3 dp above
  /// the timer box and whose axis is on the screen centre.
  static const String microphone = 'assets/images/microphone.png';
  static const Size microphoneSize = Size(148, 253.14);

  /// The original artwork's axis sits 0.86 dp left of the screen centre.
  static const double microphoneOffsetX = -0.86;
  static const double microphoneGap = 0.3;

  /// Glossy buttons: canvas sizes of the rendered artwork and the centres of
  /// the buttons measured from the screen edges.
  static const Size recordButtonCanvas = Size(36, 36);
  static const Size playButtonCanvas = Size(28, 36);
  static const double recordCenterFromLeft = 41.0;
  static const double playCenterFromRight = 42.0;
  static const double buttonsCenterOffset = 0.6;

  /// Level meter: 10 squares under the timer box.
  static const int meterSegments = 10;
  static const double meterTopGap = 6.3;
  static const double meterSquareWidth = 18.57;
  static const double meterSquareHeight = 14.29;
  static const double meterPitch = 21.43;
  static const Color meterOff = Color(0xFF555555);
  static const Color meterOn = Color(0xFF5455FF);

  static const double remainingTopGap = 10.0;
  static const TextStyle remainingText = TextStyle(
    fontFamily: font,
    fontSize: 12,
    color: Color(0xFFFFFFFF),
  );

  /// Current file path at the bottom of the body.
  static const double pathTextLeft = 48.44;
  static const double pathIconCenterX = 24.8;
  static const double pathIconSize = 19.7;
  static const TextStyle pathText = TextStyle(
    fontFamily: font,
    fontSize: 14,
    color: Color(0xFFFFFFFF),
  );

  // ------------------------------------------------------------ tab bar
  static const double tabBarHeight = 75.43;
  static const double tabIconCenterY = 28.05;
  static const TextStyle tabLabel = TextStyle(
    fontFamily: font,
    fontSize: 16,
    color: Color(0xFFFFFFFF),
  );
  static const Color tabSelectedLabel = Color(0xFF0000FE);
  static const Color tabSelectedIcon = Color(0xFF0572E7);

  // -------------------------------------------------- recording list
  static const double listTopGap = 1.8;
  static const double listTextLeft = 53.7;
  static const double listTextRight = 5.34;
  static const double listRowPadding = 10.0;
  static const double listLineGap = 0;

  /// One physical pixel.
  static const Color listDivider = Color(0x40000000);
  static const Color listSelected = Color(0xFFFF8B00);
  static const double listPlayIconLeft = 12.05;
  static const Size listPlayCanvas = Size(32, 36);
  static const TextStyle listName = TextStyle(
    fontFamily: font,
    fontSize: 16,
    color: Color(0xFFFFFFFF),
  );
  static const TextStyle listDetail = TextStyle(
    fontFamily: font,
    fontSize: 16,
    color: Color(0xFFC1C1C1),
  );

  /// Seek bar of the expanded (selected) row, relative to the top of the
  /// row's second part (right below the date line).
  static const double seekTopGap = 11.56;
  static const double seekHeight = 30.0;
  static const double seekStart = 22.7;
  static const double seekEndFromRight = 17.4;
  static const double seekTrackHeight = 0.857;
  static const Color seekTrack = Color(0x3E454545);
  static const Color holoBlue = Color(0xFF33B5E5);
  static const double seekThumbDot = 10.5;
  static const double seekThumbHalo = 30.0;
  static const double seekTimeGap = 2.73;
  static const double seekTimeLeft = 16.48;

  static const double actionBarHeight = 64.2;
  static const double actionIconCenterY = 24.3;

  // ------------------------------------------------------------ settings
  static const double sectionPaddingTop = 5.3;
  static const double sectionPaddingBottom = 5.55;
  static const double sectionTextLeft = 10.78;
  static const TextStyle sectionText = TextStyle(
    fontFamily: font,
    fontSize: 14,
    color: Color(0xFFDFDFDF),
  );
  static const double settingsRowHeight = 48;
  static const double settingsIconCenterX = 32.3;
  static const double settingsTextLeft = 53.7;
  static const double settingsLineGap = 0;
  static const Color settingsDivider = Color(0xFF7A7978);
  static const TextStyle settingsTitle = TextStyle(
    fontFamily: font,
    fontSize: 14,
    color: Color(0xFFFFFFFF),
  );
  static const TextStyle settingsSummary = TextStyle(
    fontFamily: font,
    fontSize: 14,
    color: Color(0xFFE0E0E0),
  );

  // ------------------------------------------------------------ dialogs
  static const Color dialogScrim = Color(0x99000000);

  /// Holo Light alert dialog (delete confirmation and pickers).
  static const double holoInset = 27.43;
  static const double holoRadius = 2;
  static const Color holoBackground = Color(0xFFF5F5F5);
  static const Color holoEdge = Color(0xFFD6D6D6);
  static const double holoTitleHeight = 68.57;
  static const double holoTitleLeft = 60.08;
  static const double holoIconLeft = 16.9;
  static const Size holoIconSize = Size(34.8, 31.0);
  static const double holoIconRaise = 5.0;
  static const double holoTitleRule = 2;
  static const double holoMessagePaddingTop = 8.75;
  static const double holoMessagePaddingBottom = 10.97;
  static const double holoMessageInset = 17.17;
  static const double holoButtonBarHeight = 58.85;
  static const Color holoDivider = Color(0xFFDCDCDC);
  static const double holoDividerWidth = 0.571;
  static const TextStyle holoTitle = TextStyle(
    fontFamily: font,
    fontSize: 22,
    color: holoBlue,
  );
  static const TextStyle holoMessage = TextStyle(
    fontFamily: font,
    fontSize: 18,
    color: Color(0xFF000000),
  );
  static const TextStyle holoButton = TextStyle(
    fontFamily: font,
    fontSize: 14,
    color: Color(0xFF000000),
  );

  /// iOS-style rename dialog.
  static const double renameInset = 41.14;
  static const double renameRadius = 6.9;
  static const Color renameBackground = Color(0xFFDBDAD8);
  static const double renameTitleTop = 16.23;
  static const double renameFieldGap = 5.19;
  static const double renameFieldInset = 16;
  static const double renameFieldHeight = 33.14;
  static const double renameFieldPadding = 5.55;
  static const Color renameFieldBorder = Color(0xFF919191);
  static const double renameRuleGap = 11.0;
  static const Color renameRule = Color(0xFFBEBDBB);
  static const double renameButtonHeight = 42.14;
  static const TextStyle renameTitle = TextStyle(
    fontFamily: font,
    fontSize: 16,
    color: Color(0xFF000000),
  );
  static const TextStyle renameField = TextStyle(
    fontFamily: font,
    fontSize: 14,
    fontWeight: FontWeight.w400,
    letterSpacing: 0,
    color: Color(0xFF000000),
  );
  static const TextStyle renameButton = TextStyle(
    fontFamily: font,
    fontSize: 14,
    color: Color(0xFF007AFF),
  );
}
