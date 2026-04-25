import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';

import '../../../core/utils/theme.dart';
import '../../../core/providers/auth_provider.dart';
import '../../../core/widgets/tradie_button.dart';
import '../../../core/widgets/tradie_text_field.dart';

class ResetPasswordScreen extends ConsumerStatefulWidget {
  final String token;
  const ResetPasswordScreen({super.key, required this.token});

  @override
  ConsumerState<ResetPasswordScreen> createState() => _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends ConsumerState<ResetPasswordScreen> {
  final _passwordCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  bool _obscurePass = true;
  bool _obscureConfirm = true;
  bool _loading = false;
  bool _done = false;
  String? _error;

  @override
  void dispose() {
    _passwordCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _reset() async {
    final password = _passwordCtrl.text;
    if (password.length < 8) {
      setState(() => _error = 'Password must be at least 8 characters');
      return;
    }
    if (password != _confirmCtrl.text) {
      setState(() => _error = 'Passwords do not match');
      return;
    }

    setState(() { _loading = true; _error = null; });
    final err = await ref.read(authNotifierProvider.notifier).resetPassword(widget.token, password);
    if (!mounted) return;
    if (err != null) {
      final msg = err == 'invalid_or_expired_token'
          ? 'This link has expired. Please request a new password reset.'
          : 'Something went wrong. Please try again.';
      setState(() { _error = msg; _loading = false; });
    } else {
      setState(() { _loading = false; _done = true; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TradieColors.white,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 24),
              const SizedBox(height: 40),

              if (!_done) ...[
                Container(
                  width: 64, height: 64,
                  decoration: BoxDecoration(color: TradieColors.electricBlue.withOpacity(0.1), borderRadius: BorderRadius.circular(18)),
                  child: const Icon(Iconsax.lock, color: TradieColors.electricBlue, size: 30),
                ),
                const SizedBox(height: 24),
                Text('New password', style: Theme.of(context).textTheme.displayMedium),
                const SizedBox(height: 8),
                Text(
                  'Choose a strong password for your Tradie account.',
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: TradieColors.grey600),
                ),
                const SizedBox(height: 40),

                if (_error != null) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: TradieColors.alertRed.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: TradieColors.alertRed.withOpacity(0.3)),
                    ),
                    child: Row(children: [
                      const Icon(Iconsax.warning_2, color: TradieColors.alertRed, size: 18),
                      const SizedBox(width: 8),
                      Expanded(child: Text(_error!, style: const TextStyle(color: TradieColors.alertRed, fontSize: 14))),
                    ]),
                  ),
                  const SizedBox(height: 20),
                ],

                TradieTextField(
                  controller: _passwordCtrl,
                  label: 'New password',
                  hint: 'At least 8 characters',
                  obscureText: _obscurePass,
                  prefixIcon: Iconsax.lock,
                  suffixIcon: GestureDetector(
                    onTap: () => setState(() => _obscurePass = !_obscurePass),
                    child: Icon(_obscurePass ? Iconsax.eye_slash : Iconsax.eye, size: 20, color: TradieColors.grey400),
                  ),
                ),
                const SizedBox(height: 16),
                TradieTextField(
                  controller: _confirmCtrl,
                  label: 'Confirm new password',
                  hint: 'Repeat your password',
                  obscureText: _obscureConfirm,
                  prefixIcon: Iconsax.lock_1,
                  suffixIcon: GestureDetector(
                    onTap: () => setState(() => _obscureConfirm = !_obscureConfirm),
                    child: Icon(_obscureConfirm ? Iconsax.eye_slash : Iconsax.eye, size: 20, color: TradieColors.grey400),
                  ),
                ),
                const SizedBox(height: 32),
                TradieButton(label: 'Reset password', loading: _loading, onPressed: _reset),
              ] else ...[
                Container(
                  width: 64, height: 64,
                  decoration: BoxDecoration(color: TradieColors.successGreen.withOpacity(0.1), borderRadius: BorderRadius.circular(18)),
                  child: const Icon(Iconsax.tick_circle, color: TradieColors.successGreen, size: 30),
                ),
                const SizedBox(height: 24),
                Text('Password reset!', style: Theme.of(context).textTheme.displayMedium),
                const SizedBox(height: 8),
                Text(
                  'Your password has been changed. You can now sign in with your new password.',
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: TradieColors.grey600),
                ),
                const SizedBox(height: 40),
                TradieButton(
                  label: 'Sign in',
                  onPressed: () => context.go('/auth/login'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
