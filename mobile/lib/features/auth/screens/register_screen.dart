import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/utils/theme.dart';
import '../../../core/providers/auth_provider.dart';
import '../../../core/widgets/apple_pill_button.dart';
import '../../../core/widgets/tradie_text_field.dart';

class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key});

  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> {
  final _firstNameCtrl = TextEditingController();
  final _lastNameCtrl = TextEditingController();
  final _bizNameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();

  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _firstNameCtrl.dispose();
    _lastNameCtrl.dispose();
    _bizNameCtrl.dispose();
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _phoneCtrl.dispose();
    super.dispose();
  }

  Future<void> _register() async {
    final email = _emailCtrl.text.trim();
    final password = _passwordCtrl.text;

    if (_firstNameCtrl.text.trim().isEmpty ||
        _lastNameCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Please enter your full name');
      return;
    }
    if (_bizNameCtrl.text.trim().length < 2) {
      setState(() => _error = 'Business name must be at least 2 characters');
      return;
    }
    if (!email.contains('@')) {
      setState(() => _error = 'Enter a valid email address');
      return;
    }
    if (password.length < 8) {
      setState(() => _error = 'Password must be at least 8 characters');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });
    await ref.read(authNotifierProvider.notifier).register(
          firstName: _firstNameCtrl.text.trim(),
          lastName: _lastNameCtrl.text.trim(),
          email: email,
          password: password,
          businessName: _bizNameCtrl.text.trim(),
          phone: _phoneCtrl.text.trim(),
        );
    if (!mounted) return;
    final state = ref.read(authNotifierProvider);
    state.whenOrNull(
      error: (e, _) {
        String msg = 'Registration failed. Please try again.';
        if (e.toString().contains('email_taken')) {
          msg = 'This email is already registered.';
        }
        setState(() {
          _error = msg;
          _loading = false;
        });
      },
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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 96),
              Text(
                'Create account.',
                style: tt.displayMedium?.copyWith(
                  color: TradieColors.charcoal,
                  letterSpacing: -0.4,
                  height: 1.10,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Get your Tradie ID and start running jobs.',
                style: tt.headlineLarge?.copyWith(
                  color: TradieColors.grey600,
                  height: 1.14,
                ),
              ),
              const SizedBox(height: 64),
              Row(
                children: [
                  Expanded(
                    child: TradieTextField(
                      controller: _firstNameCtrl,
                      label: 'First name',
                      hint: 'John',
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: TradieTextField(
                      controller: _lastNameCtrl,
                      label: 'Last name',
                      hint: 'Smith',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              TradieTextField(
                controller: _bizNameCtrl,
                label: 'Business name',
                hint: "Smith's Plumbing",
              ),
              const SizedBox(height: 16),
              TradieTextField(
                controller: _emailCtrl,
                label: 'Email address',
                hint: 'you@business.com.au',
                keyboardType: TextInputType.emailAddress,
              ),
              const SizedBox(height: 16),
              TradieTextField(
                controller: _passwordCtrl,
                label: 'Password',
                hint: 'At least 8 characters',
                obscureText: true,
              ),
              const SizedBox(height: 16),
              TradieTextField(
                controller: _phoneCtrl,
                label: 'Phone (optional)',
                hint: '0400 000 000',
                keyboardType: TextInputType.phone,
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
                label: 'Create account',
                primary: true,
                loading: _loading,
                onPressed: _register,
                width: double.infinity,
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text(
                    'Have an account? ',
                    style: TextStyle(
                      color: TradieColors.grey600,
                      fontSize: 14,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                  TextButton(
                    onPressed: () => context.go('/auth/login'),
                    style: TextButton.styleFrom(
                      foregroundColor: TradieColors.electricBlue,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 2),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text(
                      'Sign in',
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
    );
  }
}
