import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../core/api/api_client.dart';
import '../../../core/utils/theme.dart';
import '../../../core/widgets/tradie_button.dart';

/// Three-step 2FA setup wizard:
///   1. Generate (calls /auth/mfa/enable)
///   2. Show QR + secret + backup codes
///   3. Verify TOTP code (calls /auth/mfa/verify)
class MfaSetupScreen extends ConsumerStatefulWidget {
  const MfaSetupScreen({super.key});

  @override
  ConsumerState<MfaSetupScreen> createState() => _MfaSetupScreenState();
}

class _MfaSetupScreenState extends ConsumerState<MfaSetupScreen> {
  int _step = 0;
  bool _busy = false;
  String? _error;

  String? _secret;
  String? _qrUrl;
  List<String> _backupCodes = const [];

  final _codeCtrl = TextEditingController();

  @override
  void dispose() {
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() { _busy = true; _error = null; });
    try {
      final api = ref.read(apiClientProvider);
      final resp = await api.post('/auth/mfa/enable');
      final data = resp.data as Map<String, dynamic>;
      setState(() {
        _secret = data['secret'] as String?;
        _qrUrl = data['qr_url'] as String?;
        _backupCodes = ((data['backup_codes'] as List?) ?? const [])
            .map((e) => e.toString()).toList();
        _step = 1;
        _busy = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Could not start 2FA setup. Please try again.';
        _busy = false;
      });
    }
  }

  Future<void> _verify() async {
    final code = _codeCtrl.text.trim();
    if (code.length != 6) {
      setState(() => _error = 'Enter the 6-digit code');
      return;
    }
    setState(() { _busy = true; _error = null; });
    try {
      final api = ref.read(apiClientProvider);
      await api.post('/auth/mfa/verify', data: {'code': code});
      if (!mounted) return;
      setState(() { _step = 2; _busy = false; });
    } catch (_) {
      setState(() {
        _error = 'Invalid code. Try again.';
        _busy = false;
      });
    }
  }

  void _copy(String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$label copied')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TradieColors.white,
      appBar: AppBar(
        backgroundColor: TradieColors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Iconsax.arrow_left, color: TradieColors.charcoal),
          onPressed: () => context.canPop() ? context.pop() : context.go('/settings'),
        ),
        title: const Text('Two-factor auth',
            style: TextStyle(color: TradieColors.charcoal, fontWeight: FontWeight.w700)),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: _stepBody(),
        ),
      ),
    );
  }

  Widget _stepBody() {
    switch (_step) {
      case 0:
        return _intro();
      case 1:
        return _qrAndCodes();
      case 2:
        return _success();
      default:
        return const SizedBox.shrink();
    }
  }

  // ── Step 0: intro ───────────────────────────────────────────────
  Widget _intro() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Container(
          width: 64, height: 64,
          decoration: BoxDecoration(
            color: TradieColors.electricBlue.withOpacity(0.1),
            borderRadius: BorderRadius.circular(18),
          ),
          child: const Icon(Iconsax.shield_tick,
              color: TradieColors.electricBlue, size: 32),
        ),
        const SizedBox(height: 20),
        Text('Add an extra layer of security',
            style: Theme.of(context).textTheme.displaySmall),
        const SizedBox(height: 8),
        Text(
          'Use an authenticator app like 1Password, Authy, or Google Authenticator to generate a 6-digit code each time you sign in.',
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: TradieColors.grey600,
                height: 1.5,
              ),
        ),
        const SizedBox(height: 32),
        if (_error != null) _errorBanner(_error!),
        const SizedBox(height: 16),
        TradieButton(label: 'Get started', loading: _busy, onPressed: _start),
      ],
    );
  }

  // ── Step 1: QR + secret + backup codes + verify ─────────────────
  Widget _qrAndCodes() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Scan this QR code',
            style: Theme.of(context).textTheme.displaySmall),
        const SizedBox(height: 8),
        Text('Then enter the 6-digit code from your authenticator app to confirm.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: TradieColors.grey600,
                )),
        const SizedBox(height: 24),
        if (_qrUrl != null)
          Center(
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: TradieColors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: TradieColors.grey200),
              ),
              child: QrImageView(
                data: _qrUrl!,
                size: 220,
                backgroundColor: TradieColors.white,
              ),
            ),
          ),
        const SizedBox(height: 16),
        if (_secret != null)
          GestureDetector(
            onTap: () => _copy(_secret!, 'Secret'),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: TradieColors.grey50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: TradieColors.grey200),
              ),
              child: Row(children: [
                const Icon(Iconsax.key, size: 18, color: TradieColors.grey600),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(_secret!,
                      style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 14,
                          letterSpacing: 1.2)),
                ),
                const Icon(Iconsax.copy,
                    size: 18, color: TradieColors.electricBlue),
              ]),
            ),
          ),
        const SizedBox(height: 24),
        Text('Backup codes',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Save these somewhere safe. Each one can be used once if you lose access to your authenticator.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: TradieColors.grey600,
              ),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: TradieColors.safetyOrange.withOpacity(0.06),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: TradieColors.safetyOrange.withOpacity(0.3)),
          ),
          child: Wrap(
            spacing: 14,
            runSpacing: 8,
            children: _backupCodes
                .map((c) => GestureDetector(
                      onTap: () => _copy(c, 'Code'),
                      child: Text(
                        c,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 13,
                          letterSpacing: 1.2,
                          color: TradieColors.charcoal,
                        ),
                      ),
                    ))
                .toList(),
          ),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          icon: const Icon(Iconsax.copy, size: 16),
          label: const Text('Copy all codes'),
          onPressed: () => _copy(_backupCodes.join('\n'), 'Backup codes'),
        ),
        const SizedBox(height: 24),
        Text('Enter 6-digit code',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        TextField(
          controller: _codeCtrl,
          keyboardType: TextInputType.number,
          maxLength: 6,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              letterSpacing: 6),
          textAlign: TextAlign.center,
          decoration: InputDecoration(
            counterText: '',
            hintText: '000000',
            hintStyle: const TextStyle(
                color: TradieColors.grey400, letterSpacing: 6),
            filled: true,
            fillColor: TradieColors.grey50,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (_error != null) _errorBanner(_error!),
        const SizedBox(height: 16),
        TradieButton(label: 'Verify & enable', loading: _busy, onPressed: _verify),
      ],
    );
  }

  // ── Step 2: success ─────────────────────────────────────────────
  Widget _success() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Container(
          width: 64, height: 64,
          decoration: BoxDecoration(
            color: TradieColors.successGreen.withOpacity(0.1),
            borderRadius: BorderRadius.circular(18),
          ),
          child: const Icon(Iconsax.tick_circle,
              color: TradieColors.successGreen, size: 32),
        ),
        const SizedBox(height: 20),
        Text('Two-factor auth enabled',
            style: Theme.of(context).textTheme.displaySmall),
        const SizedBox(height: 8),
        Text(
          'Next time you sign in we\'ll ask for a 6-digit code from your authenticator app.',
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: TradieColors.grey600,
                height: 1.5,
              ),
        ),
        const SizedBox(height: 32),
        TradieButton(
          label: 'Done',
          onPressed: () => context.canPop()
              ? context.pop()
              : context.go('/settings'),
        ),
      ],
    );
  }

  Widget _errorBanner(String msg) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: TradieColors.alertRed.withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: TradieColors.alertRed.withOpacity(0.3)),
      ),
      child: Row(children: [
        const Icon(Iconsax.warning_2,
            color: TradieColors.alertRed, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Text(msg,
              style: const TextStyle(
                  color: TradieColors.alertRed, fontSize: 14)),
        ),
      ]),
    );
  }
}
