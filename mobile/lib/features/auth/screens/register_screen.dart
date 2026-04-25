import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';

import '../../../core/utils/theme.dart';
import '../../../core/providers/auth_provider.dart';
import '../../../core/widgets/tradie_button.dart';
import '../../../core/widgets/tradie_text_field.dart';

class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key});

  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> {
  final _pageCtrl = PageController();
  int _step = 0;

  // Step 1 — Business
  final _bizNameCtrl = TextEditingController();

  // Step 2 — Personal
  final _firstNameCtrl = TextEditingController();
  final _lastNameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();

  // Step 3 — Credentials
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();

  bool _obscurePass = true;
  bool _obscureConfirm = true;
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _pageCtrl.dispose();
    _bizNameCtrl.dispose();
    _firstNameCtrl.dispose();
    _lastNameCtrl.dispose();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  void _nextStep() {
    if (_step == 0 && _bizNameCtrl.text.trim().length < 2) {
      setState(() => _error = 'Business name must be at least 2 characters');
      return;
    }
    if (_step == 1 && (_firstNameCtrl.text.trim().isEmpty || _lastNameCtrl.text.trim().isEmpty)) {
      setState(() => _error = 'Please enter your full name');
      return;
    }
    setState(() { _error = null; _step++; });
    _pageCtrl.animateToPage(_step, duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
  }

  void _prevStep() {
    if (_step == 0) { context.pop(); return; }
    setState(() { _error = null; _step--; });
    _pageCtrl.animateToPage(_step, duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
  }

  Future<void> _register() async {
    final email = _emailCtrl.text.trim();
    final password = _passwordCtrl.text;
    final confirm = _confirmCtrl.text;

    if (!email.contains('@')) {
      setState(() => _error = 'Enter a valid email address');
      return;
    }
    if (password.length < 8) {
      setState(() => _error = 'Password must be at least 8 characters');
      return;
    }
    if (password != confirm) {
      setState(() => _error = 'Passwords do not match');
      return;
    }

    setState(() { _loading = true; _error = null; });
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
        if (e.toString().contains('email_taken')) msg = 'This email is already registered.';
        setState(() { _error = msg; _loading = false; });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TradieColors.white,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            _buildProgressBar(),
            Expanded(
              child: PageView(
                controller: _pageCtrl,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  _StepPage(child: _buildStep0()),
                  _StepPage(child: _buildStep1()),
                  _StepPage(child: _buildStep2()),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final titles = ['Your business', 'About you', 'Create account'];
    final subtitles = [
      'What\'s your business called?',
      'Tell us a bit about yourself',
      'Set up your login credentials',
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      child: Row(
        children: [
          GestureDetector(
            onTap: _prevStep,
            child: Container(
              width: 40, height: 40,
              decoration: BoxDecoration(color: TradieColors.grey100, borderRadius: BorderRadius.circular(10)),
              child: const Icon(Iconsax.arrow_left, size: 20, color: TradieColors.charcoal),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(titles[_step], style: Theme.of(context).textTheme.titleLarge),
                Text(subtitles[_step], style: Theme.of(context).textTheme.bodySmall?.copyWith(color: TradieColors.grey600)),
              ],
            ),
          ),
          Text('${_step + 1}/3', style: const TextStyle(color: TradieColors.grey400, fontSize: 13, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }

  Widget _buildProgressBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
      child: Row(
        children: List.generate(3, (i) => Expanded(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            height: 4,
            margin: EdgeInsets.only(right: i < 2 ? 4 : 0),
            decoration: BoxDecoration(
              color: i <= _step ? TradieColors.electricBlue : TradieColors.grey100,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        )),
      ),
    );
  }

  Widget _buildStep0() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 64, height: 64,
          decoration: BoxDecoration(color: TradieColors.electricBlue.withOpacity(0.1), borderRadius: BorderRadius.circular(18)),
          child: const Icon(Iconsax.briefcase, color: TradieColors.electricBlue, size: 30),
        ),
        const SizedBox(height: 32),
        TradieTextField(
          controller: _bizNameCtrl,
          label: 'Business name',
          hint: 'e.g. Smith\'s Plumbing',
          prefixIcon: Iconsax.building,
          autofocus: true,
        ),
        const SizedBox(height: 12),
        Text(
          'This will appear on your quotes and invoices.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: TradieColors.grey600),
        ),
        if (_error != null) _buildError(_error!),
        const Spacer(),
        TradieButton(label: 'Continue', onPressed: _nextStep),
        const SizedBox(height: 12),
        _buildLoginLink(),
      ],
    );
  }

  Widget _buildStep1() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 64, height: 64,
          decoration: BoxDecoration(color: TradieColors.safetyOrange.withOpacity(0.1), borderRadius: BorderRadius.circular(18)),
          child: const Icon(Iconsax.user, color: TradieColors.safetyOrange, size: 30),
        ),
        const SizedBox(height: 32),
        Row(children: [
          Expanded(child: TradieTextField(controller: _firstNameCtrl, label: 'First name', hint: 'John')),
          const SizedBox(width: 12),
          Expanded(child: TradieTextField(controller: _lastNameCtrl, label: 'Last name', hint: 'Smith')),
        ]),
        const SizedBox(height: 16),
        TradieTextField(
          controller: _phoneCtrl,
          label: 'Phone (optional)',
          hint: '0400 000 000',
          keyboardType: TextInputType.phone,
          prefixIcon: Iconsax.call,
        ),
        if (_error != null) _buildError(_error!),
        const Spacer(),
        TradieButton(label: 'Continue', onPressed: _nextStep),
        const SizedBox(height: 12),
        _buildLoginLink(),
      ],
    );
  }

  Widget _buildStep2() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 64, height: 64,
          decoration: BoxDecoration(color: TradieColors.successGreen.withOpacity(0.1), borderRadius: BorderRadius.circular(18)),
          child: const Icon(Iconsax.shield_tick, color: TradieColors.successGreen, size: 30),
        ),
        const SizedBox(height: 32),
        TradieTextField(
          controller: _emailCtrl,
          label: 'Email address',
          hint: 'you@business.com.au',
          keyboardType: TextInputType.emailAddress,
          prefixIcon: Iconsax.sms,
        ),
        const SizedBox(height: 16),
        TradieTextField(
          controller: _passwordCtrl,
          label: 'Password',
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
          label: 'Confirm password',
          hint: 'Repeat your password',
          obscureText: _obscureConfirm,
          prefixIcon: Iconsax.lock_1,
          suffixIcon: GestureDetector(
            onTap: () => setState(() => _obscureConfirm = !_obscureConfirm),
            child: Icon(_obscureConfirm ? Iconsax.eye_slash : Iconsax.eye, size: 20, color: TradieColors.grey400),
          ),
        ),
        if (_error != null) _buildError(_error!),
        const Spacer(),
        TradieButton(label: 'Create account', loading: _loading, onPressed: _register),
        const SizedBox(height: 12),
        Text(
          'By creating an account you agree to our Terms of Service and Privacy Policy.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: TradieColors.grey400),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        _buildLoginLink(),
      ],
    );
  }

  Widget _buildError(String msg) => Padding(
    padding: const EdgeInsets.only(top: 16),
    child: Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: TradieColors.alertRed.withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: TradieColors.alertRed.withOpacity(0.3)),
      ),
      child: Row(children: [
        const Icon(Iconsax.warning_2, color: TradieColors.alertRed, size: 18),
        const SizedBox(width: 8),
        Expanded(child: Text(msg, style: const TextStyle(color: TradieColors.alertRed, fontSize: 14))),
      ]),
    ),
  );

  Widget _buildLoginLink() => Row(mainAxisAlignment: MainAxisAlignment.center, children: [
    const Text('Already have an account? ', style: TextStyle(color: TradieColors.grey600, fontSize: 14)),
    GestureDetector(
      onTap: () => context.go('/auth/login'),
      child: const Text('Sign in', style: TextStyle(color: TradieColors.electricBlue, fontWeight: FontWeight.w600, fontSize: 14)),
    ),
  ]);
}

class _StepPage extends StatelessWidget {
  final Widget child;
  const _StepPage({required this.child});

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
    child: ConstrainedBox(
      constraints: BoxConstraints(minHeight: MediaQuery.of(context).size.height - 200),
      child: IntrinsicHeight(child: child),
    ),
  );
}
