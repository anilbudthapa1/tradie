import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';

import '../../../core/utils/theme.dart';
import '../../../core/providers/auth_provider.dart';
import '../../../core/widgets/tradie_button.dart';
import '../../../core/widgets/tradie_text_field.dart';

class ForgotPasswordScreen extends ConsumerStatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  ConsumerState<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends ConsumerState<ForgotPasswordScreen> {
  final _emailCtrl = TextEditingController();
  bool _loading = false;
  bool _sent = false;
  String? _error;

  @override
  void dispose() {
    _emailCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _emailCtrl.text.trim();
    if (!email.contains('@')) {
      setState(() => _error = 'Enter a valid email address');
      return;
    }
    setState(() { _loading = true; _error = null; });
    await ref.read(authNotifierProvider.notifier).forgotPassword(email);
    if (mounted) setState(() { _loading = false; _sent = true; });
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
              GestureDetector(
                onTap: () => context.go('/auth/login'),
                child: Container(
                  width: 40, height: 40,
                  decoration: BoxDecoration(color: TradieColors.grey100, borderRadius: BorderRadius.circular(10)),
                  child: const Icon(Iconsax.arrow_left, size: 20, color: TradieColors.charcoal),
                ),
              ),
              const SizedBox(height: 40),

              if (!_sent) ...[
                Container(
                  width: 64, height: 64,
                  decoration: BoxDecoration(color: TradieColors.electricBlue.withOpacity(0.1), borderRadius: BorderRadius.circular(18)),
                  child: const Icon(Iconsax.lock_1, color: TradieColors.electricBlue, size: 30),
                ),
                const SizedBox(height: 24),
                Text('Forgot password?', style: Theme.of(context).textTheme.displayMedium),
                const SizedBox(height: 8),
                Text(
                  'Enter your email address and we\'ll send you a link to reset your password.',
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
                      Text(_error!, style: const TextStyle(color: TradieColors.alertRed, fontSize: 14)),
                    ]),
                  ),
                  const SizedBox(height: 20),
                ],

                TradieTextField(
                  controller: _emailCtrl,
                  label: 'Email address',
                  hint: 'you@business.com.au',
                  keyboardType: TextInputType.emailAddress,
                  prefixIcon: Iconsax.sms,
                  autofocus: true,
                ),
                const SizedBox(height: 32),
                TradieButton(label: 'Send reset link', loading: _loading, onPressed: _submit),
              ] else ...[
                Container(
                  width: 64, height: 64,
                  decoration: BoxDecoration(color: TradieColors.successGreen.withOpacity(0.1), borderRadius: BorderRadius.circular(18)),
                  child: const Icon(Iconsax.tick_circle, color: TradieColors.successGreen, size: 30),
                ),
                const SizedBox(height: 24),
                Text('Check your email', style: Theme.of(context).textTheme.displayMedium),
                const SizedBox(height: 8),
                Text(
                  'We\'ve sent a password reset link to\n${_emailCtrl.text.trim()}',
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: TradieColors.grey600),
                ),
                const SizedBox(height: 12),
                Text(
                  'The link will expire in 1 hour. Check your spam folder if you don\'t see it.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: TradieColors.grey600),
                ),
                const SizedBox(height: 40),
                OutlinedButton(
                  onPressed: () => setState(() { _sent = false; _emailCtrl.clear(); }),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 52),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('Try a different email'),
                ),
              ],

              const SizedBox(height: 32),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Text('Remember your password? ', style: TextStyle(color: TradieColors.grey600, fontSize: 14)),
                GestureDetector(
                  onTap: () => context.go('/auth/login'),
                  child: const Text('Sign in', style: TextStyle(color: TradieColors.electricBlue, fontWeight: FontWeight.w600, fontSize: 14)),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}
