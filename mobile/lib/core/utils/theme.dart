import 'package:flutter/material.dart';

// ── Design tokens from styling.md ─────────────────────────────
class TradieColors {
  // Primary
  static const navy = Color(0xFF0F172A);
  static const charcoal = Color(0xFF1E293B);
  static const electricBlue = Color(0xFF1E40AF);
  static const electricBlueLight = Color(0xFF3B82F6);

  // Status
  static const safetyOrange = Color(0xFFF97316);
  static const successGreen = Color(0xFF16A34A);
  static const alertRed = Color(0xFFDC2626);
  static const warningAmber = Color(0xFFD97706);

  // Neutral
  static const white = Color(0xFFFFFFFF);
  static const grey50 = Color(0xFFF8FAFC);
  static const grey100 = Color(0xFFF1F5F9);
  static const grey200 = Color(0xFFE2E8F0);
  static const grey400 = Color(0xFF94A3B8);
  static const grey600 = Color(0xFF475569);
  static const grey800 = Color(0xFF1E293B);

  // Job status colours
  static const statusDraft = Color(0xFF94A3B8);
  static const statusScheduled = Color(0xFF3B82F6);
  static const statusInProgress = Color(0xFFF97316);
  static const statusCompleted = Color(0xFF16A34A);
  static const statusCancelled = Color(0xFFDC2626);
  static const statusOnHold = Color(0xFFD97706);

  // Invoice status
  static const invoiceDraft = Color(0xFF94A3B8);
  static const invoiceSent = Color(0xFF3B82F6);
  static const invoicePaid = Color(0xFF16A34A);
  static const invoiceOverdue = Color(0xFFDC2626);
  static const invoicePartial = Color(0xFFD97706);
}

class TradieTheme {
  static ThemeData get light => ThemeData(
        useMaterial3: true,
        fontFamily: 'Inter',
        colorScheme: ColorScheme.fromSeed(
          seedColor: TradieColors.electricBlue,
          brightness: Brightness.light,
          primary: TradieColors.electricBlue,
          secondary: TradieColors.safetyOrange,
          surface: TradieColors.white,
          background: TradieColors.grey50,
          error: TradieColors.alertRed,
          onPrimary: TradieColors.white,
          onSecondary: TradieColors.white,
          onSurface: TradieColors.charcoal,
        ),
        scaffoldBackgroundColor: TradieColors.grey50,
        appBarTheme: const AppBarTheme(
          backgroundColor: TradieColors.white,
          foregroundColor: TradieColors.navy,
          elevation: 0,
          centerTitle: false,
          titleTextStyle: TextStyle(
            fontFamily: 'Inter',
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: TradieColors.navy,
          ),
        ),
        cardTheme: CardTheme(
          color: TradieColors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: TradieColors.grey200, width: 1),
          ),
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        ),
        bottomNavigationBarTheme: const BottomNavigationBarThemeData(
          backgroundColor: TradieColors.white,
          selectedItemColor: TradieColors.electricBlue,
          unselectedItemColor: TradieColors.grey400,
          selectedLabelStyle: TextStyle(fontWeight: FontWeight.w600, fontSize: 11),
          unselectedLabelStyle: TextStyle(fontWeight: FontWeight.w400, fontSize: 11),
          type: BottomNavigationBarType.fixed,
          elevation: 8,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: TradieColors.electricBlue,
            foregroundColor: TradieColors.white,
            minimumSize: const Size(double.infinity, 52),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            textStyle: const TextStyle(
              fontFamily: 'Inter',
              fontWeight: FontWeight.w600,
              fontSize: 16,
            ),
            elevation: 0,
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: TradieColors.electricBlue,
            side: const BorderSide(color: TradieColors.electricBlue),
            minimumSize: const Size(double.infinity, 52),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            textStyle: const TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.w600, fontSize: 16),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: TradieColors.grey50,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: TradieColors.grey200),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: TradieColors.grey200),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: TradieColors.electricBlue, width: 2),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: TradieColors.alertRed),
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          labelStyle: const TextStyle(color: TradieColors.grey600, fontFamily: 'Inter'),
          hintStyle: const TextStyle(color: TradieColors.grey400, fontFamily: 'Inter'),
        ),
        textTheme: const TextTheme(
          displayLarge: TextStyle(fontSize: 32, fontWeight: FontWeight.w700, color: TradieColors.navy, height: 1.2),
          displayMedium: TextStyle(fontSize: 28, fontWeight: FontWeight.w700, color: TradieColors.navy, height: 1.2),
          headlineLarge: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: TradieColors.navy, height: 1.3),
          headlineMedium: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: TradieColors.navy, height: 1.3),
          headlineSmall: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: TradieColors.navy, height: 1.4),
          titleLarge: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: TradieColors.charcoal, height: 1.4),
          titleMedium: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: TradieColors.charcoal, height: 1.4),
          bodyLarge: TextStyle(fontSize: 16, fontWeight: FontWeight.w400, color: TradieColors.charcoal, height: 1.5),
          bodyMedium: TextStyle(fontSize: 14, fontWeight: FontWeight.w400, color: TradieColors.grey600, height: 1.5),
          bodySmall: TextStyle(fontSize: 12, fontWeight: FontWeight.w400, color: TradieColors.grey400, height: 1.4),
          labelLarge: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: TradieColors.charcoal),
          labelSmall: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: TradieColors.grey600),
        ),
        chipTheme: ChipThemeData(
          backgroundColor: TradieColors.grey100,
          labelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: TradieColors.charcoal),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          side: BorderSide.none,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        ),
        dividerTheme: const DividerThemeData(
          color: TradieColors.grey100,
          thickness: 1,
          space: 0,
        ),
      );

  static ThemeData get dark => ThemeData(
        useMaterial3: true,
        fontFamily: 'Inter',
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: TradieColors.electricBlue,
          brightness: Brightness.dark,
          primary: TradieColors.electricBlueLight,
          secondary: TradieColors.safetyOrange,
          surface: const Color(0xFF1E293B),
          background: const Color(0xFF0F172A),
          error: TradieColors.alertRed,
        ),
        scaffoldBackgroundColor: const Color(0xFF0F172A),
        cardTheme: CardTheme(
          color: const Color(0xFF1E293B),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: Color(0xFF334155), width: 1),
          ),
        ),
      );
}

// ── Status badge helpers ──────────────────────────────────────
extension JobStatusColor on String {
  Color get jobStatusColor {
    switch (this) {
      case 'draft': return TradieColors.statusDraft;
      case 'scheduled': return TradieColors.statusScheduled;
      case 'in_progress': return TradieColors.statusInProgress;
      case 'completed': return TradieColors.statusCompleted;
      case 'cancelled': return TradieColors.statusCancelled;
      case 'on_hold': return TradieColors.statusOnHold;
      default: return TradieColors.grey400;
    }
  }

  Color get invoiceStatusColor {
    switch (this) {
      case 'paid': return TradieColors.invoicePaid;
      case 'overdue': return TradieColors.invoiceOverdue;
      case 'sent': return TradieColors.invoiceSent;
      case 'partial': return TradieColors.invoicePartial;
      default: return TradieColors.invoiceDraft;
    }
  }
}
