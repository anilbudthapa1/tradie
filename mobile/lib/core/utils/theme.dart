import 'package:flutter/material.dart';

// ── Apple-inspired design tokens (see DESIGN-apple.md) ───────────
// Single accent: Action Blue. No second-accent concept; safety orange
// and warning amber are remapped to Action Blue. Surfaces alternate
// Pure White and Parchment; ink is Near-Black, hairlines are 8% black.
class TradieColors {
  // ── Apple base palette ─────────────────────────────────────────
  static const _actionBlue = Color(0xFF0066CC);
  static const _nearBlackInk = Color(0xFF1D1D1F);
  static const _parchment = Color(0xFFF5F5F7);
  static const _pureWhite = Color(0xFFFFFFFF);
  static const _quietRed = Color(0xFFD70015);
  static const _appleGreen = Color(0xFF34A853);

  // Hairlines & muted ink (Apple's translucent ink ladder)
  static const _hairline08 = Color(0x14000000); // rgba(0,0,0,0.08)
  static const _hairline12 = Color(0x1F000000); // ~rgba(0,0,0,0.12)
  static const _mutedInk48 = Color(0x7A000000); // rgba(0,0,0,0.48)
  static const _mutedInk80 = Color(0xCC000000); // rgba(0,0,0,0.80)

  // Dark-tile surfaces
  static const _nearBlackTile1 = Color(0xFF272729);
  static const _nearBlackTile2 = Color(0xFF2A2A2C);
  static const _hairlineDark16 = Color(0x29FFFFFF); // rgba(255,255,255,0.16)

  // ── Public symbol map (names preserved for 40+ screen call-sites) ──
  // Primary brand
  static const navy = _nearBlackInk;
  static const charcoal = _nearBlackInk;
  static const electricBlue = _actionBlue;
  static const electricBlueLight = _actionBlue; // single accent — no second blue

  // Status (orange & amber collapse onto Action Blue per Apple "single accent")
  static const safetyOrange = _actionBlue;
  static const successGreen = _appleGreen;
  static const alertRed = _quietRed;
  static const warningAmber = _actionBlue;

  // Neutral
  static const white = _pureWhite;
  static const grey50 = _parchment;
  static const grey100 = _parchment;
  static const grey200 = _hairline08;
  static const grey400 = _mutedInk48;
  static const grey600 = _mutedInk80;
  static const grey800 = _nearBlackInk;

  // Job status colours
  static const statusDraft = _mutedInk48;
  static const statusScheduled = _actionBlue;
  static const statusInProgress = _actionBlue;
  static const statusCompleted = _appleGreen;
  static const statusCancelled = _quietRed;
  static const statusOnHold = _nearBlackInk;

  // Invoice status
  static const invoiceDraft = _mutedInk48;
  static const invoiceSent = _actionBlue;
  static const invoicePaid = _appleGreen;
  static const invoiceOverdue = _quietRed;
  static const invoicePartial = _nearBlackInk;

  // Aliases used across screens
  static const red = alertRed;
  static const green = successGreen;
  static const navyDark = _nearBlackInk;
  static const grey300 = _hairline12;
  static const textSecondary = _mutedInk80;
  static const background = _parchment;
}

// ── Apple typographic ladder (Inter substitute for SF Pro) ─────────
// Display sizes nudged with -0.01em tracking per DESIGN-apple.md §3
// Note on Font Substitutes. Weights used: 300 / 400 / 600 / 700 only —
// weight 500 is deliberately absent from Apple's ladder.
const _font = 'Inter';

TextTheme _appleTextTheme({required Color ink}) {
  return TextTheme(
    // Hero Headline — 56/600/1.07/-0.56
    displayLarge: TextStyle(
      fontFamily: _font,
      fontSize: 56,
      fontWeight: FontWeight.w600,
      height: 1.07,
      letterSpacing: -0.56,
      color: ink,
    ),
    // H1 / Tile Headline — 40/600/1.10/-0.4
    displayMedium: TextStyle(
      fontFamily: _font,
      fontSize: 40,
      fontWeight: FontWeight.w600,
      height: 1.10,
      letterSpacing: -0.4,
      color: ink,
    ),
    // 34/600/1.10/-0.34
    displaySmall: TextStyle(
      fontFamily: _font,
      fontSize: 34,
      fontWeight: FontWeight.w600,
      height: 1.10,
      letterSpacing: -0.34,
      color: ink,
    ),
    // Lead / Subhead — 28/400/1.14/-0.28
    headlineLarge: TextStyle(
      fontFamily: _font,
      fontSize: 28,
      fontWeight: FontWeight.w400,
      height: 1.14,
      letterSpacing: -0.28,
      color: ink,
    ),
    // Large Lead — 24/300/1.50 (rare weight 300)
    headlineMedium: TextStyle(
      fontFamily: _font,
      fontSize: 24,
      fontWeight: FontWeight.w300,
      height: 1.50,
      color: ink,
    ),
    // Sub-tile Tagline — 21/600/1.19
    headlineSmall: TextStyle(
      fontFamily: _font,
      fontSize: 21,
      fontWeight: FontWeight.w600,
      height: 1.19,
      color: ink,
    ),
    // Body Strong — 17/600/1.24/-0.374
    titleLarge: TextStyle(
      fontFamily: _font,
      fontSize: 17,
      fontWeight: FontWeight.w600,
      height: 1.24,
      letterSpacing: -0.374,
      color: ink,
    ),
    // 15/600/1.3/-0.3
    titleMedium: TextStyle(
      fontFamily: _font,
      fontSize: 15,
      fontWeight: FontWeight.w600,
      height: 1.3,
      letterSpacing: -0.3,
      color: ink,
    ),
    // Caption Strong — 14/600/1.29/-0.224
    titleSmall: TextStyle(
      fontFamily: _font,
      fontSize: 14,
      fontWeight: FontWeight.w600,
      height: 1.29,
      letterSpacing: -0.224,
      color: ink,
    ),
    // Body — Apple's signature 17/400/1.47/-0.374
    bodyLarge: TextStyle(
      fontFamily: _font,
      fontSize: 17,
      fontWeight: FontWeight.w400,
      height: 1.47,
      letterSpacing: -0.374,
      color: ink,
    ),
    // 15/400/1.45/-0.3
    bodyMedium: TextStyle(
      fontFamily: _font,
      fontSize: 15,
      fontWeight: FontWeight.w400,
      height: 1.45,
      letterSpacing: -0.3,
      color: ink,
    ),
    // Caption — 14/400/1.43/-0.224
    bodySmall: TextStyle(
      fontFamily: _font,
      fontSize: 14,
      fontWeight: FontWeight.w400,
      height: 1.43,
      letterSpacing: -0.224,
      color: ink,
    ),
    // Button text (large) — 17/400/1.0
    labelLarge: TextStyle(
      fontFamily: _font,
      fontSize: 17,
      fontWeight: FontWeight.w400,
      height: 1.0,
      color: ink,
    ),
    // Button text (utility) — 14/400/1.29/-0.224
    labelMedium: TextStyle(
      fontFamily: _font,
      fontSize: 14,
      fontWeight: FontWeight.w400,
      height: 1.29,
      letterSpacing: -0.224,
      color: ink,
    ),
    // Fine print — 12/400/1.0/-0.12
    labelSmall: TextStyle(
      fontFamily: _font,
      fontSize: 12,
      fontWeight: FontWeight.w400,
      height: 1.0,
      letterSpacing: -0.12,
      color: ink,
    ),
  );
}

class TradieTheme {
  // ── Light theme — Apple "daytime" variant ────────────────────────
  static ThemeData get light => ThemeData(
        useMaterial3: true,
        fontFamily: _font,
        brightness: Brightness.light,
        colorScheme: ColorScheme.fromSeed(
          seedColor: TradieColors.electricBlue,
          brightness: Brightness.light,
          primary: TradieColors.electricBlue,
          secondary: TradieColors.electricBlue, // single accent
          surface: TradieColors.white,
          error: TradieColors.alertRed,
          onPrimary: TradieColors.white,
          onSecondary: TradieColors.white,
          onSurface: TradieColors.navy,
          onError: TradieColors.white,
        ),
        scaffoldBackgroundColor: TradieColors.white,
        appBarTheme: const AppBarTheme(
          backgroundColor: TradieColors.white,
          foregroundColor: TradieColors.navy,
          surfaceTintColor: TradieColors.white,
          elevation: 0,
          scrolledUnderElevation: 0,
          shadowColor: Colors.transparent,
          centerTitle: false,
          toolbarHeight: 44,
          titleTextStyle: TextStyle(
            fontFamily: _font,
            fontSize: 17,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.374,
            color: TradieColors.navy,
          ),
          iconTheme: IconThemeData(color: TradieColors.navy, size: 22),
        ),
        cardTheme: CardThemeData(
          color: TradieColors.white,
          surfaceTintColor: TradieColors.white,
          shadowColor: Colors.transparent,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: const BorderSide(color: TradieColors.grey200, width: 1),
          ),
          margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        ),
        bottomNavigationBarTheme: const BottomNavigationBarThemeData(
          backgroundColor: TradieColors.white,
          selectedItemColor: TradieColors.electricBlue,
          unselectedItemColor: TradieColors.grey400,
          selectedLabelStyle: TextStyle(
            fontFamily: _font,
            fontWeight: FontWeight.w600,
            fontSize: 11,
            letterSpacing: -0.12,
          ),
          unselectedLabelStyle: TextStyle(
            fontFamily: _font,
            fontWeight: FontWeight.w400,
            fontSize: 11,
            letterSpacing: -0.12,
          ),
          type: BottomNavigationBarType.fixed,
          elevation: 0,
          showUnselectedLabels: true,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ButtonStyle(
            backgroundColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.disabled)) {
                return TradieColors.grey200;
              }
              return TradieColors.electricBlue;
            }),
            foregroundColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.disabled)) {
                return TradieColors.grey400;
              }
              return TradieColors.white;
            }),
            overlayColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.pressed)) {
                return Colors.black.withValues(alpha: 0.10);
              }
              if (states.contains(WidgetState.hovered)) {
                return Colors.black.withValues(alpha: 0.05);
              }
              return null;
            }),
            shape: const WidgetStatePropertyAll(StadiumBorder()),
            padding: const WidgetStatePropertyAll(
              EdgeInsets.symmetric(horizontal: 22, vertical: 11),
            ),
            textStyle: const WidgetStatePropertyAll(
              TextStyle(
                fontFamily: _font,
                fontSize: 17,
                fontWeight: FontWeight.w400,
                height: 1.0,
              ),
            ),
            elevation: const WidgetStatePropertyAll(0),
            shadowColor: const WidgetStatePropertyAll(Colors.transparent),
            surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: ButtonStyle(
            backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
            foregroundColor: const WidgetStatePropertyAll(TradieColors.electricBlue),
            overlayColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.pressed)) {
                return TradieColors.electricBlue.withValues(alpha: 0.10);
              }
              if (states.contains(WidgetState.hovered)) {
                return TradieColors.electricBlue.withValues(alpha: 0.05);
              }
              return null;
            }),
            side: const WidgetStatePropertyAll(
              BorderSide(color: TradieColors.electricBlue, width: 1),
            ),
            shape: const WidgetStatePropertyAll(StadiumBorder()),
            padding: const WidgetStatePropertyAll(
              EdgeInsets.symmetric(horizontal: 22, vertical: 11),
            ),
            textStyle: const WidgetStatePropertyAll(
              TextStyle(
                fontFamily: _font,
                fontSize: 17,
                fontWeight: FontWeight.w400,
                height: 1.0,
              ),
            ),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: ButtonStyle(
            foregroundColor: const WidgetStatePropertyAll(TradieColors.electricBlue),
            overlayColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.pressed)) {
                return TradieColors.electricBlue.withValues(alpha: 0.10);
              }
              if (states.contains(WidgetState.hovered)) {
                return TradieColors.electricBlue.withValues(alpha: 0.05);
              }
              return null;
            }),
            padding: const WidgetStatePropertyAll(
              EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
            textStyle: const WidgetStatePropertyAll(
              TextStyle(
                fontFamily: _font,
                fontSize: 17,
                fontWeight: FontWeight.w400,
                height: 1.0,
                decoration: TextDecoration.none,
              ),
            ),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: TradieColors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(980),
            borderSide: const BorderSide(color: TradieColors.grey200, width: 1),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(980),
            borderSide: const BorderSide(color: TradieColors.grey200, width: 1),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(980),
            borderSide: const BorderSide(color: TradieColors.electricBlue, width: 2),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(980),
            borderSide: const BorderSide(color: TradieColors.alertRed, width: 1),
          ),
          focusedErrorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(980),
            borderSide: const BorderSide(color: TradieColors.alertRed, width: 2),
          ),
          disabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(980),
            borderSide: const BorderSide(color: TradieColors.grey200, width: 1),
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          labelStyle: const TextStyle(
            fontFamily: _font,
            fontSize: 17,
            fontWeight: FontWeight.w400,
            color: TradieColors.grey600,
            letterSpacing: -0.374,
          ),
          hintStyle: const TextStyle(
            fontFamily: _font,
            fontSize: 17,
            fontWeight: FontWeight.w400,
            color: TradieColors.grey400,
            letterSpacing: -0.374,
          ),
          floatingLabelStyle: const TextStyle(
            fontFamily: _font,
            fontSize: 14,
            fontWeight: FontWeight.w400,
            color: TradieColors.grey600,
            letterSpacing: -0.224,
          ),
        ),
        textTheme: _appleTextTheme(ink: TradieColors.navy),
        chipTheme: ChipThemeData(
          backgroundColor: const Color(0x0D000000), // rgba(0,0,0,0.05)
          selectedColor: TradieColors.electricBlue,
          labelStyle: const TextStyle(
            fontFamily: _font,
            fontSize: 14,
            fontWeight: FontWeight.w400,
            color: TradieColors.navy,
            letterSpacing: -0.224,
          ),
          secondaryLabelStyle: const TextStyle(
            fontFamily: _font,
            fontSize: 14,
            fontWeight: FontWeight.w400,
            color: TradieColors.white,
            letterSpacing: -0.224,
          ),
          shape: const StadiumBorder(),
          side: BorderSide.none,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        ),
        dividerTheme: const DividerThemeData(
          color: TradieColors.grey200,
          thickness: 1,
          space: 0,
        ),
        iconTheme: const IconThemeData(color: TradieColors.navy, size: 22),
        splashFactory: NoSplash.splashFactory,
        highlightColor: Colors.transparent,
      );

  // ── Dark theme — Apple "dark tile" variant ────────────────────────
  static ThemeData get dark => ThemeData(
        useMaterial3: true,
        fontFamily: _font,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: TradieColors.electricBlue,
          brightness: Brightness.dark,
          primary: TradieColors.electricBlue,
          secondary: TradieColors.electricBlue,
          surface: TradieColors._nearBlackTile2,
          error: TradieColors.alertRed,
          onPrimary: TradieColors.white,
          onSecondary: TradieColors.white,
          onSurface: TradieColors.white,
          onError: TradieColors.white,
        ),
        scaffoldBackgroundColor: TradieColors._nearBlackTile1,
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF000000),
          foregroundColor: TradieColors.white,
          surfaceTintColor: Color(0xFF000000),
          elevation: 0,
          scrolledUnderElevation: 0,
          shadowColor: Colors.transparent,
          centerTitle: false,
          toolbarHeight: 44,
          titleTextStyle: TextStyle(
            fontFamily: _font,
            fontSize: 17,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.374,
            color: TradieColors.white,
          ),
          iconTheme: IconThemeData(color: TradieColors.white, size: 22),
        ),
        cardTheme: CardThemeData(
          color: TradieColors._nearBlackTile2,
          surfaceTintColor: TradieColors._nearBlackTile2,
          shadowColor: Colors.transparent,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        ),
        bottomNavigationBarTheme: const BottomNavigationBarThemeData(
          backgroundColor: TradieColors._nearBlackTile1,
          selectedItemColor: TradieColors.white,
          unselectedItemColor: Color(0x7AFFFFFF), // 48% white
          selectedLabelStyle: TextStyle(
            fontFamily: _font,
            fontWeight: FontWeight.w600,
            fontSize: 11,
            letterSpacing: -0.12,
          ),
          unselectedLabelStyle: TextStyle(
            fontFamily: _font,
            fontWeight: FontWeight.w400,
            fontSize: 11,
            letterSpacing: -0.12,
          ),
          type: BottomNavigationBarType.fixed,
          elevation: 0,
          showUnselectedLabels: true,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ButtonStyle(
            backgroundColor: const WidgetStatePropertyAll(TradieColors.electricBlue),
            foregroundColor: const WidgetStatePropertyAll(TradieColors.white),
            overlayColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.pressed)) {
                return Colors.white.withValues(alpha: 0.10);
              }
              return null;
            }),
            shape: const WidgetStatePropertyAll(StadiumBorder()),
            padding: const WidgetStatePropertyAll(
              EdgeInsets.symmetric(horizontal: 22, vertical: 11),
            ),
            textStyle: const WidgetStatePropertyAll(
              TextStyle(
                fontFamily: _font,
                fontSize: 17,
                fontWeight: FontWeight.w400,
                height: 1.0,
              ),
            ),
            elevation: const WidgetStatePropertyAll(0),
            shadowColor: const WidgetStatePropertyAll(Colors.transparent),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: ButtonStyle(
            backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
            foregroundColor: const WidgetStatePropertyAll(TradieColors.electricBlue),
            side: const WidgetStatePropertyAll(
              BorderSide(color: TradieColors.electricBlue, width: 1),
            ),
            shape: const WidgetStatePropertyAll(StadiumBorder()),
            padding: const WidgetStatePropertyAll(
              EdgeInsets.symmetric(horizontal: 22, vertical: 11),
            ),
            textStyle: const WidgetStatePropertyAll(
              TextStyle(
                fontFamily: _font,
                fontSize: 17,
                fontWeight: FontWeight.w400,
                height: 1.0,
              ),
            ),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: ButtonStyle(
            foregroundColor: const WidgetStatePropertyAll(TradieColors.electricBlue),
            padding: const WidgetStatePropertyAll(
              EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
            textStyle: const WidgetStatePropertyAll(
              TextStyle(
                fontFamily: _font,
                fontSize: 17,
                fontWeight: FontWeight.w400,
                height: 1.0,
                decoration: TextDecoration.none,
              ),
            ),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: TradieColors._nearBlackTile2,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(980),
            borderSide: const BorderSide(color: TradieColors._hairlineDark16, width: 1),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(980),
            borderSide: const BorderSide(color: TradieColors._hairlineDark16, width: 1),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(980),
            borderSide: const BorderSide(color: TradieColors.electricBlue, width: 2),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(980),
            borderSide: const BorderSide(color: TradieColors.alertRed, width: 1),
          ),
          focusedErrorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(980),
            borderSide: const BorderSide(color: TradieColors.alertRed, width: 2),
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          labelStyle: const TextStyle(
            fontFamily: _font,
            fontSize: 17,
            fontWeight: FontWeight.w400,
            color: Color(0xCCFFFFFF), // 80% white
            letterSpacing: -0.374,
          ),
          hintStyle: const TextStyle(
            fontFamily: _font,
            fontSize: 17,
            fontWeight: FontWeight.w400,
            color: Color(0x7AFFFFFF), // 48% white
            letterSpacing: -0.374,
          ),
        ),
        textTheme: _appleTextTheme(ink: TradieColors.white),
        chipTheme: ChipThemeData(
          backgroundColor: const Color(0x14FFFFFF), // rgba(255,255,255,0.08)
          selectedColor: TradieColors.electricBlue,
          labelStyle: const TextStyle(
            fontFamily: _font,
            fontSize: 14,
            fontWeight: FontWeight.w400,
            color: TradieColors.white,
            letterSpacing: -0.224,
          ),
          shape: const StadiumBorder(),
          side: BorderSide.none,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        ),
        dividerTheme: const DividerThemeData(
          color: TradieColors._hairlineDark16,
          thickness: 1,
          space: 0,
        ),
        iconTheme: const IconThemeData(color: TradieColors.white, size: 22),
        splashFactory: NoSplash.splashFactory,
        highlightColor: Colors.transparent,
      );
}

// ── Status badge helpers ──────────────────────────────────────
extension JobStatusColor on String {
  Color get jobStatusColor {
    switch (this) {
      case 'draft':
        return TradieColors.statusDraft;
      case 'scheduled':
        return TradieColors.statusScheduled;
      case 'in_progress':
        return TradieColors.statusInProgress;
      case 'completed':
        return TradieColors.statusCompleted;
      case 'cancelled':
        return TradieColors.statusCancelled;
      case 'on_hold':
        return TradieColors.statusOnHold;
      default:
        return TradieColors.grey400;
    }
  }

  Color get invoiceStatusColor {
    switch (this) {
      case 'paid':
        return TradieColors.invoicePaid;
      case 'overdue':
        return TradieColors.invoiceOverdue;
      case 'sent':
        return TradieColors.invoiceSent;
      case 'partial':
        return TradieColors.invoicePartial;
      default:
        return TradieColors.invoiceDraft;
    }
  }
}
