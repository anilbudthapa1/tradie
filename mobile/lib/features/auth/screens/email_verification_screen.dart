import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';

import '../../../core/utils/theme.dart';
import '../../../core/providers/auth_provider.dart';
import '../../../core/widgets/tradie_button.dart';

class EmailVerificationScreen extends ConsumerStatefulWidget {
  final String? token;
  const EmailVerificationScreen({super.key, this.token});

  @override
  ConsumerState<EmailVerificationScreen> createState() => _EmailVerificationScreenState();
}

class _EmailVerificationScreenState extends ConsumerState<EmailVerificationScreen> {
  bool _loading = false;
  bool _verified = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.token != null && widget.token!.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _verify());
    }
  }

  Future<void> _verify() async {
    if (widget.token == null || widget.token!.isEmpty) return;
    setState(() { _loading = true; _error = null; });
    final err = await ref.read(authNotifierProvider.notifier).verifyEmail(widget.token!);
    if (!mounted) return;
    if (err != null) {
      setState(() {
        _error = err == 'invalid_token'
            ? 'This verification link has expired or is invalid.'
            : 'Something went wrong. Please try again.';
        _loading = false;
      });
    } else {
      setState(() { _loading = false; _verified = true; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TradieColors.white,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (_loading) ...[
                const CircularProgressIndicator(color: TradieColors.electricBlue),
                const SizedBox(height: 24),
                Text('Verifying your email...', style: Theme.of(context).textTheme.titleLarge),
              ] else if (_verified) ...[
                Container(
                  width: 80, height: 80,
                  decoration: BoxDecoration(color: TradieColors.successGreen.withOpacity(0.1), borderRadius: BorderRadius.circular(24)),
                  child: const Icon(Iconsax.tick_circle, color: TradieColors.successGreen, size: 40),
                ),
                const SizedBox(height: 24),
                Text('Email verified!', style: Theme.of(context).textTheme.displayMedium, textAlign: TextAlign.center),
                const SizedBox(height: 8),
                Text(
                  'Your email address has been verified. Your account is now fully active.',
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: TradieColors.grey600),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 40),
                TradieButton(
                  label: 'Go to dashboard',
                  onPressed: () => context.go('/dashboard'),
                ),
              ] else ...[
                Container(
                  width: 80, height: 80,
                  decoration: BoxDecoration(color: TradieColors.alertRed.withOpacity(0.08), borderRadius: BorderRadius.circular(24)),
                  child: const Icon(Iconsax.warning_2, color: TradieColors.alertRed, size: 40),
                ),
                const SizedBox(height: 24),
                Text('Verification failed', style: Theme.of(context).textTheme.displayMedium, textAlign: TextAlign.center),
                const SizedBox(height: 8),
                Text(
                  _error ?? 'This link is invalid or has expired.',
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: TradieColors.grey600),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 40),
                TradieButton(
                  label: 'Back to login',
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
