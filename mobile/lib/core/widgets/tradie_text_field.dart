import 'package:flutter/material.dart';
import '../utils/theme.dart';

/// Apple-style text field used across the app.
///
/// Visual rules (per DESIGN-apple.md):
///   * Label sits above the input (SF Pro Text 14/400 in muted-80%, 4px gap).
///   * The field itself is a full pill (radius 980), white fill, hairline border,
///     focused border 2px Action Blue.
///   * Padding inside the field is 12 vertical / 20 horizontal.
///   * Error text is 12/400 in alertRed, 4px below the field.
class TradieTextField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String? hint;
  final bool obscureText;
  final TextInputType? keyboardType;
  final IconData? prefixIcon;
  final Widget? suffixIcon;
  final String? errorText;
  final int? maxLines;
  final void Function(String)? onChanged;
  final TextInputAction? textInputAction;
  final bool autofocus;

  const TradieTextField({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
    this.obscureText = false,
    this.keyboardType,
    this.prefixIcon,
    this.suffixIcon,
    this.errorText,
    this.maxLines = 1,
    this.onChanged,
    this.textInputAction,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    const pillRadius = BorderRadius.all(Radius.circular(980));

    final border = OutlineInputBorder(
      borderRadius: pillRadius,
      borderSide: const BorderSide(color: TradieColors.grey200, width: 1),
    );
    final focusedBorder = OutlineInputBorder(
      borderRadius: pillRadius,
      borderSide: const BorderSide(color: TradieColors.electricBlue, width: 2),
    );
    final errorBorder = OutlineInputBorder(
      borderRadius: pillRadius,
      borderSide: const BorderSide(color: TradieColors.alertRed, width: 1),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontFamily: 'Inter',
            fontSize: 14,
            fontWeight: FontWeight.w400,
            color: TradieColors.grey600,
            letterSpacing: -0.224,
          ),
        ),
        const SizedBox(height: 4),
        TextFormField(
          controller: controller,
          obscureText: obscureText,
          keyboardType: keyboardType,
          maxLines: maxLines,
          onChanged: onChanged,
          textInputAction: textInputAction,
          autofocus: autofocus,
          cursorColor: TradieColors.electricBlue,
          style: const TextStyle(
            fontFamily: 'Inter',
            fontSize: 17,
            fontWeight: FontWeight.w400,
            color: TradieColors.navy,
            letterSpacing: -0.374,
          ),
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: TradieColors.white,
            hintText: hint,
            hintStyle: const TextStyle(
              fontFamily: 'Inter',
              fontSize: 17,
              fontWeight: FontWeight.w400,
              color: TradieColors.grey400,
              letterSpacing: -0.374,
            ),
            // Error text is rendered below by us so we leave the field's own
            // error message visually hidden but pass through for semantics.
            errorText: errorText,
            errorStyle: const TextStyle(
              fontFamily: 'Inter',
              fontSize: 12,
              fontWeight: FontWeight.w400,
              color: TradieColors.alertRed,
              height: 1.0,
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 20,
              vertical: 12,
            ),
            prefixIcon: prefixIcon != null
                ? Padding(
                    padding: const EdgeInsets.only(left: 16, right: 8),
                    child: Icon(prefixIcon, size: 18, color: TradieColors.grey400),
                  )
                : null,
            prefixIconConstraints: const BoxConstraints(
              minWidth: 0,
              minHeight: 0,
            ),
            suffixIcon: suffixIcon,
            border: border,
            enabledBorder: border,
            focusedBorder: focusedBorder,
            errorBorder: errorBorder,
            focusedErrorBorder: errorBorder,
          ),
        ),
      ],
    );
  }
}
