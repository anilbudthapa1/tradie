import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';

import '../../../core/utils/theme.dart';
import '../../../core/providers/auth_provider.dart';
import '../../../core/widgets/apple_pill_button.dart';
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
    if (!mounted) return;
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
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: TradieColors.white,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: MediaQuery.of(context).size.height -
                  MediaQuery.of(context).padding.vertical,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 96),
                // Logo mark
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: TradieColors.electricBlue,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: const Icon(
                    Iconsax.briefcase,
                    color: Colors.white,
                    size: 28,
                  ),
                ),
                const SizedBox(height: 64),
                Text(
                  'Sign in.',
                  style: tt.displayMedium?.copyWith(
                    color: TradieColors.charcoal,
                    letterSpacing: -0.4,
                    height: 1.10,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Use your Tradie ID to access the workspace.',
                  style: tt.headlineLarge?.copyWith(
                    color: TradieColors.grey600,
                    height: 1.14,
                  ),
                ),
                const SizedBox(height: 64),
                TradieTextField(
                  controller: _emailCtrl,
                  label: 'Email address',
                  hint: 'you@business.com.au',
                  keyboardType: TextInputType.emailAddress,
                ),
                const SizedBox(height: 16),
                TradieTextField(
                  controller: _passCtrl,
                  label: 'Password',
                  hint: 'Enter your password',
                  obscureText: _obscure,
                  suffixIcon: GestureDetector(
                    onTap: () => setState(() => _obscure = !_obscure),
                    child: Icon(
                      _obscure ? Iconsax.eye_slash : Iconsax.eye,
                      size: 20,
                      color: TradieColors.grey400,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => context.go('/auth/forgot-password'),
                    style: TextButton.styleFrom(
                      foregroundColor: TradieColors.electricBlue,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text(
                      'Forgot password?',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w400,
                        color: TradieColors.electricBlue,
                      ),
                    ),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _error!,
                    style: const TextStyle(
                      color: TradieColors.alertRed,
                      fontSize: 14,
                      fontWeight: FontWeight.w400,
                      height: 1.43,
                    ),
                  ),
                ],
                const SizedBox(height: 32),
                ApplePillButton(
                  label: 'Sign in',
                  primary: true,
                  loading: _loading,
                  onPressed: _login,
                  width: double.infinity,
                ),
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text(
                      "Don't have an account? ",
                      style: TextStyle(
                        color: TradieColors.grey600,
                        fontSize: 14,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                    TextButton(
                      onPressed: () => context.go('/auth/register'),
                      style: TextButton.styleFrom(
                        foregroundColor: TradieColors.electricBlue,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 2),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text(
                        'Create one',
                        style: TextStyle(
                          color: TradieColors.electricBlue,
                          fontSize: 14,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 48),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
