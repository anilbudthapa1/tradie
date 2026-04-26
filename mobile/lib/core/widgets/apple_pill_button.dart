import 'package:flutter/material.dart';
import '../utils/theme.dart';

/// Apple-style pill button.
///
/// Two grammars exist (per DESIGN-apple.md):
///   * Solid (`primary: true`): Action Blue fill, white label, no border.
///   * Ghost (`primary: false`): transparent fill, Action Blue label,
///     1px Action Blue border.
///
/// Both share: full-pill (StadiumBorder) shape, 11v/22h padding, 17/400 label,
/// scale-to-0.95 press animation over 80ms, and a 2px Focus Blue keyboard ring.
class ApplePillButton extends StatefulWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool primary;
  final bool loading;
  final IconData? leadingIcon;
  final double? width;

  const ApplePillButton({
    super.key,
    required this.label,
    this.onPressed,
    this.primary = true,
    this.loading = false,
    this.leadingIcon,
    this.width,
  });

  @override
  State<ApplePillButton> createState() => _ApplePillButtonState();
}

class _ApplePillButtonState extends State<ApplePillButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 80),
    lowerBound: 0.95,
    upperBound: 1.0,
    value: 1.0,
  );
  bool _focused = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _setPressed(bool pressed) {
    if (pressed) {
      _ctrl.animateTo(0.95);
    } else {
      _ctrl.animateTo(1.0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final disabled = widget.onPressed == null || widget.loading;
    final isPrimary = widget.primary;

    final bg = isPrimary ? TradieColors.electricBlue : Colors.transparent;
    final fg = isPrimary ? TradieColors.white : TradieColors.electricBlue;

    final labelStyle = TextStyle(
      fontFamily: 'Inter',
      fontSize: 17,
      fontWeight: FontWeight.w400,
      color: fg,
      height: 1.0,
      letterSpacing: -0.374,
    );

    final content = widget.loading
        ? SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(fg),
            ),
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (widget.leadingIcon != null) ...[
                Icon(widget.leadingIcon, size: 16, color: fg),
                const SizedBox(width: 8),
              ],
              Text(widget.label, style: labelStyle),
            ],
          );

    Widget button = AnimatedBuilder(
      animation: _ctrl,
      builder: (_, child) => Transform.scale(scale: _ctrl.value, child: child),
      child: Container(
        width: widget.width,
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 11),
        decoration: ShapeDecoration(
          color: bg,
          shape: StadiumBorder(
            side: isPrimary
                ? BorderSide.none
                : const BorderSide(color: TradieColors.electricBlue, width: 1),
          ),
        ),
        child: Center(
          widthFactor: widget.width == null ? 1.0 : null,
          child: content,
        ),
      ),
    );

    // Focus ring (2px Focus Blue ~ Action Blue surrogate via TradieColors).
    button = AnimatedContainer(
      duration: const Duration(milliseconds: 80),
      decoration: ShapeDecoration(
        shape: StadiumBorder(
          side: _focused
              ? const BorderSide(color: TradieColors.electricBlue, width: 2)
              : BorderSide.none,
        ),
      ),
      padding: EdgeInsets.all(_focused ? 2 : 0),
      child: button,
    );

    return Opacity(
      opacity: disabled ? 0.4 : 1.0,
      child: IgnorePointer(
        ignoring: disabled,
        child: Focus(
          onFocusChange: (v) => setState(() => _focused = v),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (_) => _setPressed(true),
            onTapCancel: () => _setPressed(false),
            onTapUp: (_) => _setPressed(false),
            onTap: widget.onPressed,
            child: button,
          ),
        ),
      ),
    );
  }
}
