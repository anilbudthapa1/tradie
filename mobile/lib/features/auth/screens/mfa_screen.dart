import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';

import '../../../core/utils/theme.dart';
import '../../../core/providers/auth_provider.dart';
import '../../../core/widgets/tradie_button.dart';

class MFAScreen extends ConsumerStatefulWidget {
  final String mfaToken;
  const MFAScreen({super.key, required this.mfaToken});

  @override
  ConsumerState<MFAScreen> createState() => _MFAScreenState();
}

class _MFAScreenState extends ConsumerState<MFAScreen> {
  final _controllers = List.generate(6, (_) => TextEditingController());
  final _focusNodes = List.generate(6, (_) => FocusNode());
  bool _loading = false;
  bool _useBackup = false;
  String? _error;
  final _backupCtrl = TextEditingController();

  @override
  void dispose() {
    for (final c in _controllers) c.dispose();
    for (final f in _focusNodes) f.dispose();
    _backupCtrl.dispose();
    super.dispose();
  }

  String get _code => _controllers.map((c) => c.text).join();

  Future<void> _verify() async {
    final code = _useBackup ? _backupCtrl.text.trim().toUpperCase() : _code;
    if ((!_useBackup && code.length != 6) || (_useBackup && code.isEmpty)) {
      setState(() => _error = 'Please enter the full code');
      return;
    }

    setState(() { _loading = true; _error = null; });
    await ref.read(authNotifierProvider.notifier).verifyMFALogin(widget.mfaToken, code);
    if (!mounted) return;
    final state = ref.read(authNotifierProvider);
    state.whenOrNull(
      error: (e, _) {
        setState(() {
          _error = 'Invalid code. Please try again.';
          _loading = false;
        });
        if (!_useBackup) _clearCode();
      },
    );
  }

  void _clearCode() {
    for (final c in _controllers) c.clear();
    _focusNodes[0].requestFocus();
  }

  void _onDigitChanged(int index, String value) {
    if (value.length == 1 && index < 5) {
      _focusNodes[index + 1].requestFocus();
    } else if (value.isEmpty && index > 0) {
      _focusNodes[index - 1].requestFocus();
    }
    if (_code.length == 6) _verify();
    setState(() {});
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
              const SizedBox(height: 32),
              Container(
                width: 64, height: 64,
                decoration: BoxDecoration(color: TradieColors.electricBlue.withOpacity(0.1), borderRadius: BorderRadius.circular(18)),
                child: const Icon(Iconsax.shield_tick, color: TradieColors.electricBlue, size: 32),
              ),
              const SizedBox(height: 24),
              Text('Two-factor auth', style: Theme.of(context).textTheme.displayMedium),
              const SizedBox(height: 8),
              Text(
                _useBackup
                    ? 'Enter one of your backup codes'
                    : 'Enter the 6-digit code from your authenticator app',
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
                const SizedBox(height: 24),
              ],

              if (!_useBackup) ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: List.generate(6, (i) => _buildDigitBox(i)),
                ),
                const SizedBox(height: 32),
                TradieButton(label: 'Verify', loading: _loading, onPressed: _verify),
              ] else ...[
                TextField(
                  controller: _backupCtrl,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 18, letterSpacing: 2),
                  textCapitalization: TextCapitalization.characters,
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[A-Fa-f0-9]'))],
                  decoration: InputDecoration(
                    hintText: 'XXXXXXXXXX',
                    hintStyle: TextStyle(color: TradieColors.grey400, letterSpacing: 2),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                  ),
                ),
                const SizedBox(height: 32),
                TradieButton(label: 'Use backup code', loading: _loading, onPressed: _verify),
              ],

              const SizedBox(height: 20),
              Center(
                child: TextButton(
                  onPressed: () => setState(() { _error = null; _useBackup = !_useBackup; }),
                  child: Text(
                    _useBackup ? 'Use authenticator app instead' : 'Use a backup code instead',
                    style: const TextStyle(color: TradieColors.electricBlue, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDigitBox(int index) {
    final filled = _controllers[index].text.isNotEmpty;
    return SizedBox(
      width: 48, height: 58,
      child: TextField(
        controller: _controllers[index],
        focusNode: _focusNodes[index],
        textAlign: TextAlign.center,
        keyboardType: TextInputType.number,
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(1),
        ],
        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: TradieColors.charcoal),
        onChanged: (v) => _onDigitChanged(index, v),
        decoration: InputDecoration(
          filled: true,
          fillColor: filled ? TradieColors.electricBlue.withOpacity(0.06) : TradieColors.grey50,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(
              color: filled ? TradieColors.electricBlue : TradieColors.grey200,
              width: filled ? 2 : 1,
            ),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(
              color: filled ? TradieColors.electricBlue : TradieColors.grey200,
              width: filled ? 2 : 1,
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: TradieColors.electricBlue, width: 2),
          ),
          contentPadding: EdgeInsets.zero,
        ),
      ),
    );
  }
}
