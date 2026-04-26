import 'package:flutter/material.dart';
import '../utils/theme.dart';

/// Apple-style utility card.
///
/// White (or Parchment if `emphasized`) background, 18px radius,
/// 1px hairline border, NO shadow. Optional tap target.
class AppleCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final bool emphasized;

  const AppleCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.onTap,
    this.emphasized = false,
  });

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(18);
    final bg = emphasized ? TradieColors.grey50 : TradieColors.white;

    final container = Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: radius,
        border: Border.all(color: TradieColors.grey200, width: 1),
      ),
      child: Padding(padding: padding, child: child),
    );

    if (onTap == null) return container;

    return Material(
      color: Colors.transparent,
      borderRadius: radius,
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        hoverColor: TradieColors.grey50,
        splashColor: TradieColors.electricBlue.withOpacity(0.06),
        highlightColor: Colors.transparent,
        child: container,
      ),
    );
  }
}
