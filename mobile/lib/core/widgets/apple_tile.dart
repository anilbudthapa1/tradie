import 'package:flutter/material.dart';
import '../utils/theme.dart';

/// Apple-style full-bleed tile.
///
/// Edge-to-edge section that alternates between dark and light canvases.
/// No border, no radius, no shadow — the color change is the divider.
///
/// Default vertical padding is 80; collapses to 48 on mobile (<640px).
class AppleTile extends StatelessWidget {
  final Widget child;
  final bool dark;
  final bool parchment;
  final EdgeInsetsGeometry? padding;
  final CrossAxisAlignment alignment;

  /// Apple's near-black tile colour (`#272729`).
  static const Color _darkTile = Color(0xFF272729);

  const AppleTile({
    super.key,
    required this.child,
    this.dark = false,
    this.parchment = false,
    this.padding,
    this.alignment = CrossAxisAlignment.center,
  });

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 640;
    final resolvedPadding = padding ??
        EdgeInsets.symmetric(
          vertical: isMobile ? 48 : 80,
          horizontal: 24,
        );

    final bg = dark
        ? _darkTile
        : (parchment ? TradieColors.grey50 : TradieColors.white);
    final fg = dark ? TradieColors.white : TradieColors.navy;

    return Container(
      width: double.infinity,
      color: bg,
      padding: resolvedPadding,
      child: DefaultTextStyle.merge(
        style: TextStyle(color: fg),
        child: IconTheme.merge(
          data: IconThemeData(color: fg),
          child: Column(
            crossAxisAlignment: alignment,
            mainAxisSize: MainAxisSize.min,
            children: [child],
          ),
        ),
      ),
    );
  }
}
