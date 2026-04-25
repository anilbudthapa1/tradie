import 'package:flutter/material.dart';
import '../utils/theme.dart';

class TradieButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool loading;
  final Color? color;
  final IconData? icon;

  const TradieButton({super.key, required this.label, this.onPressed, this.loading = false, this.color, this.icon});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      height: 52,
      width: double.infinity,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        gradient: loading || onPressed == null
            ? null
            : LinearGradient(
                colors: [color ?? TradieColors.electricBlue, (color ?? TradieColors.electricBlue).withOpacity(0.8)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
        color: loading || onPressed == null ? TradieColors.grey200 : null,
        boxShadow: loading || onPressed == null
            ? null
            : [BoxShadow(color: (color ?? TradieColors.electricBlue).withOpacity(0.3), blurRadius: 8, offset: const Offset(0, 4))],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: loading ? null : onPressed,
          child: Center(
            child: loading
                ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : Row(mainAxisSize: MainAxisSize.min, children: [
                    if (icon != null) ...[Icon(icon, color: Colors.white, size: 20), const SizedBox(width: 8)],
                    Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 16, fontFamily: 'Inter')),
                  ]),
          ),
        ),
      ),
    );
  }
}
