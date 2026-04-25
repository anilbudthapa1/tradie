import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';

import '../../../core/utils/theme.dart';
import '../../../core/providers/auth_provider.dart';
import '../../../core/widgets/tradie_button.dart';
import '../../../core/widgets/tradie_text_field.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _obscure = true;
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    setState(() { _loading = true; _error = null; });
    await ref.read(authNotifierProvider.notifier).login(
      _emailCtrl.text.trim(),
      _passCtrl.text,
    );
    final state = ref.read(authNotifierProvider);
    state.when(
      data: (user) {
        if (user?['mfa_required'] == true) {
          context.go('/auth/mfa', extra: user?['mfa_token']);
        }
        // Router will redirect on success
      },
      error: (e, _) => setState(() { _error = 'Invalid email or password'; _loading = false; }),
      loading: () {},
    );
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
              const SizedBox(height: 48),
              // Logo
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: TradieColors.electricBlue,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(Iconsax.briefcase, color: Colors.white, size: 28),
              ),
              const SizedBox(height: 32),
              Text('Welcome back', style: Theme.of(context).textTheme.displayMedium),
              const SizedBox(height: 8),
              Text('Sign in to your Tradie account', style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: TradieColors.grey600)),
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
              ),
              const SizedBox(height: 16),
              TradieTextField(
                controller: _passCtrl,
                label: 'Password',
                hint: '••••••••',
                obscureText: _obscure,
                prefixIcon: Iconsax.lock,
                suffixIcon: GestureDetector(
                  onTap: () => setState(() => _obscure = !_obscure),
                  child: Icon(_obscure ? Iconsax.eye_slash : Iconsax.eye, size: 20, color: TradieColors.grey400),
                ),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => context.go('/auth/forgot-password'),
                  child: const Text('Forgot password?', style: TextStyle(color: TradieColors.electricBlue, fontWeight: FontWeight.w600)),
                ),
              ),
              const SizedBox(height: 24),
              TradieButton(
                label: 'Sign in',
                loading: _loading,
                onPressed: _login,
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: () {},
                icon: const Icon(Iconsax.finger_cricle, size: 20),
                label: const Text('Sign in with Passkey'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 52),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
              const SizedBox(height: 32),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Text("Don't have an account? ", style: TextStyle(color: TradieColors.grey600)),
                GestureDetector(
                  onTap: () => context.go('/auth/register'),
                  child: const Text('Sign up free', style: TextStyle(color: TradieColors.electricBlue, fontWeight: FontWeight.w600)),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}
