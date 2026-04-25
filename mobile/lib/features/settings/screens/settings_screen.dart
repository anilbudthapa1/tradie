import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';

import '../../../core/utils/theme.dart';
import '../../../core/providers/settings_provider.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});
  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 5, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TradieColors.grey50,
      appBar: AppBar(
        title: Row(children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: TradieColors.electricBlue.withOpacity(0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Iconsax.setting_2,
                color: TradieColors.electricBlue, size: 20),
          ),
          const SizedBox(width: 10),
          const Text('Settings'),
        ]),
        bottom: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          labelStyle:
              const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          unselectedLabelStyle:
              const TextStyle(fontWeight: FontWeight.w400, fontSize: 13),
          labelColor: TradieColors.electricBlue,
          unselectedLabelColor: TradieColors.grey600,
          indicatorColor: TradieColors.electricBlue,
          indicatorWeight: 2,
          tabs: const [
            Tab(text: 'General'),
            Tab(text: 'Security'),
            Tab(text: 'API Keys'),
            Tab(text: 'Notifications'),
            Tab(text: 'Subscription'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: const [
          _GeneralTab(),
          _SecurityTab(),
          _APIKeysTab(),
          _NotificationsTab(),
          _SubscriptionTab(),
        ],
      ),
    );
  }
}

// ── General Tab ────────────────────────────────────────────────────────────────

class _GeneralTab extends ConsumerStatefulWidget {
  const _GeneralTab();
  @override
  ConsumerState<_GeneralTab> createState() => _GeneralTabState();
}

class _GeneralTabState extends ConsumerState<_GeneralTab> {
  final _dateFormatCtrl = TextEditingController();
  final _currencyCtrl = TextEditingController();
  final _langCtrl = TextEditingController();
  final _durationCtrl = TextEditingController();
  bool _autoReminders = true;
  bool _loaded = false;
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _dateFormatCtrl.dispose();
    _currencyCtrl.dispose();
    _langCtrl.dispose();
    _durationCtrl.dispose();
    super.dispose();
  }

  void _populate(Map<String, dynamic> s) {
    if (_loaded) return;
    _dateFormatCtrl.text = s['date_format'] ?? 'DD/MM/YYYY';
    _currencyCtrl.text = s['currency'] ?? 'AUD';
    _langCtrl.text = s['language'] ?? 'en';
    _durationCtrl.text = '${s['default_job_duration_minutes'] ?? 60}';
    _autoReminders = s['auto_send_reminders'] ?? true;
    _loaded = true;
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final err =
        await ref.read(settingsNotifierProvider.notifier).updateGeneral({
      'date_format': _dateFormatCtrl.text.trim(),
      'currency': _currencyCtrl.text.trim(),
      'language': _langCtrl.text.trim(),
      'default_job_duration_minutes':
          int.tryParse(_durationCtrl.text) ?? 60,
      'auto_send_reminders': _autoReminders,
    });
    setState(() {
      _saving = false;
      _error = err;
    });
    if (err == null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Settings saved'),
            backgroundColor: TradieColors.successGreen),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(settingsProvider);
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('$e')),
      data: (s) {
        _populate(s);
        return SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _SectionCard(
                  icon: Iconsax.global,
                  title: 'Regional',
                  children: [
                    _DropdownField(
                      label: 'Date Format',
                      value: _dateFormatCtrl.text,
                      items: const [
                        'DD/MM/YYYY',
                        'MM/DD/YYYY',
                        'YYYY-MM-DD'
                      ],
                      onChanged: (v) =>
                          setState(() => _dateFormatCtrl.text = v!),
                    ),
                    const SizedBox(height: 12),
                    _DropdownField(
                      label: 'Currency',
                      value: _currencyCtrl.text,
                      items: const ['AUD', 'USD', 'GBP', 'NZD', 'EUR'],
                      onChanged: (v) =>
                          setState(() => _currencyCtrl.text = v!),
                    ),
                    const SizedBox(height: 12),
                    _DropdownField(
                      label: 'Language',
                      value: _langCtrl.text,
                      items: const ['en', 'en-AU', 'en-US'],
                      onChanged: (v) =>
                          setState(() => _langCtrl.text = v!),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _SectionCard(
                  icon: Iconsax.clock,
                  title: 'Jobs',
                  children: [
                    _LabeledField(
                      label: 'Default Job Duration (minutes)',
                      ctrl: _durationCtrl,
                      keyboardType: TextInputType.number,
                    ),
                    const SizedBox(height: 12),
                    _ToggleRow(
                      icon: Iconsax.notification,
                      label: 'Auto-send Reminders',
                      subtitle:
                          'Automatically remind customers before jobs',
                      value: _autoReminders,
                      onChanged: (v) =>
                          setState(() => _autoReminders = v),
                    ),
                  ],
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  _ErrorBanner(_error!),
                ],
                const SizedBox(height: 24),
                _SaveButton(saving: _saving, onTap: _save),
              ]),
        );
      },
    );
  }
}

// ── Security Tab ───────────────────────────────────────────────────────────────
//
// Sections:
//   1. Business-level security policy (require 2FA, session timeout)
//   2. Personal MFA (enable / disable TOTP on current account)
//   3. Active sessions list with revoke
//   4. Shortcut to audit log

class _SecurityTab extends ConsumerStatefulWidget {
  const _SecurityTab();
  @override
  ConsumerState<_SecurityTab> createState() => _SecurityTabState();
}

class _SecurityTabState extends ConsumerState<_SecurityTab> {
  // -- policy state
  bool _require2FA = false;
  int _sessionTimeout = 480;
  bool _policyLoaded = false;
  bool _savingPolicy = false;
  String? _policyError;

  // -- MFA dialog state
  bool _mfaLoading = false;

  void _populatePolicy(Map<String, dynamic> s) {
    if (_policyLoaded) return;
    _require2FA = s['require_2fa'] ?? false;
    _sessionTimeout = s['session_timeout_min'] ?? 480;
    _policyLoaded = true;
  }

  Future<void> _savePolicy() async {
    setState(() {
      _savingPolicy = true;
      _policyError = null;
    });
    final err =
        await ref.read(settingsNotifierProvider.notifier).updateSecurity({
      'require_2fa': _require2FA,
      'session_timeout_min': _sessionTimeout,
    });
    setState(() {
      _savingPolicy = false;
      _policyError = err;
    });
    if (err == null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Security settings saved'),
            backgroundColor: TradieColors.successGreen),
      );
    }
  }

  // -- MFA enable flow: show QR secret then confirm with TOTP code
  Future<void> _enableMFA() async {
    setState(() => _mfaLoading = true);
    final result =
        await ref.read(settingsNotifierProvider.notifier).enableMFA();
    setState(() => _mfaLoading = false);
    if (result == null || !mounted) return;

    final secret = result['secret'] as String? ?? '';
    final backupCodes =
        List<String>.from(result['backup_codes'] as List? ?? []);

    // Show setup dialog
    final codeCtrl = TextEditingController();
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setDlg) {
        String? dlgError;
        bool dlgLoading = false;
        return AlertDialog(
          title: Row(children: [
            const Icon(Iconsax.shield_tick,
                color: TradieColors.electricBlue, size: 20),
            const SizedBox(width: 8),
            const Text('Set up 2FA'),
          ]),
          content: SingleChildScrollView(
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Scan this secret in your authenticator app (Google Authenticator, Authy, etc.), then enter the 6-digit code to confirm.',
                    style: TextStyle(fontSize: 13, color: TradieColors.grey600),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: TradieColors.grey100,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(children: [
                      Expanded(
                        child: SelectableText(
                          secret,
                          style: const TextStyle(
                              fontFamily: 'monospace', fontSize: 13),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Iconsax.copy, size: 18),
                        onPressed: () =>
                            Clipboard.setData(ClipboardData(text: secret)),
                        tooltip: 'Copy secret',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 16),
                  const Text('Backup codes — save these somewhere safe:',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: TradieColors.navy)),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: backupCodes
                        .map((c) => Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: TradieColors.grey100,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(c,
                                  style: const TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 11)),
                            ))
                        .toList(),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: codeCtrl,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(6),
                    ],
                    decoration: InputDecoration(
                      labelText: '6-digit verification code',
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10)),
                      errorText: dlgError,
                    ),
                  ),
                ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            StatefulBuilder(builder: (ctx2, setSub) {
              return FilledButton(
                onPressed: dlgLoading
                    ? null
                    : () async {
                        setSub(() => dlgLoading = true);
                        final err = await ref
                            .read(settingsNotifierProvider.notifier)
                            .verifyMFA(codeCtrl.text.trim());
                        setSub(() => dlgLoading = false);
                        if (err == null) {
                          if (ctx.mounted) Navigator.pop(ctx);
                          ref.invalidate(mfaStatusProvider);
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('2FA enabled successfully'),
                                backgroundColor: TradieColors.successGreen,
                              ),
                            );
                          }
                        } else {
                          setDlg(() => dlgError =
                              'Invalid code — try again');
                        }
                      },
                child: dlgLoading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: TradieColors.white))
                    : const Text('Confirm & Enable'),
              );
            }),
          ],
        );
      }),
    );
  }

  Future<void> _disableMFA() async {
    final codeCtrl = TextEditingController();
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setDlg) {
        String? dlgError;
        bool dlgLoading = false;
        return AlertDialog(
          title: const Text('Disable 2FA'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text(
              'Enter your current authenticator code (or a backup code) to confirm.',
              style: TextStyle(
                  fontSize: 13, color: TradieColors.grey600),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: codeCtrl,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(6),
              ],
              decoration: InputDecoration(
                labelText: 'Verification code',
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10)),
                errorText: dlgError,
              ),
            ),
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            StatefulBuilder(builder: (ctx2, setSub) {
              return TextButton(
                style: TextButton.styleFrom(
                    foregroundColor: TradieColors.alertRed),
                onPressed: dlgLoading
                    ? null
                    : () async {
                        setSub(() => dlgLoading = true);
                        final err = await ref
                            .read(settingsNotifierProvider.notifier)
                            .disableMFA(codeCtrl.text.trim());
                        setSub(() => dlgLoading = false);
                        if (err == null) {
                          if (ctx.mounted) Navigator.pop(ctx);
                          ref.invalidate(mfaStatusProvider);
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text('2FA disabled'),
                                  backgroundColor:
                                      TradieColors.alertRed),
                            );
                          }
                        } else {
                          setDlg(() => dlgError =
                              'Invalid code — try again');
                        }
                      },
                child: dlgLoading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: TradieColors.alertRed))
                    : const Text('Disable 2FA'),
              );
            }),
          ],
        );
      }),
    );
  }

  Future<void> _revokeSession(String id, bool isCurrent) async {
    if (isCurrent) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Revoke current session?'),
          content: const Text(
              'This will log you out immediately from this device.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel')),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              style: TextButton.styleFrom(
                  foregroundColor: TradieColors.alertRed),
              child: const Text('Revoke & Logout'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    final ok =
        await ref.read(settingsNotifierProvider.notifier).revokeSession(id);
    if (ok && isCurrent && mounted) {
      context.go('/auth/login');
    } else if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to revoke session')),
      );
    }
  }

  String _timeoutLabel(int min) {
    if (min < 60) return '${min}m';
    if (min < 1440) return '${min ~/ 60}h';
    if (min < 10080) return '${min ~/ 1440}d';
    return '${min ~/ 10080}w';
  }

  @override
  Widget build(BuildContext context) {
    final policyAsync = ref.watch(securitySettingsProvider);
    final sessionsAsync = ref.watch(sessionsProvider);
    final mfaAsync = ref.watch(mfaStatusProvider);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // ── Business Security Policy ───────────────────────────────
        policyAsync.when(
          loading: () => const _CardShimmer(),
          error: (e, _) => _ErrorBanner('Failed to load security settings'),
          data: (s) {
            _populatePolicy(s);
            return _SectionCard(
              icon: Iconsax.shield_tick,
              title: 'Business Security Policy',
              children: [
                _ToggleRow(
                  icon: Iconsax.lock,
                  label: 'Require 2FA for All Users',
                  subtitle:
                      'Every team member must set up two-factor authentication',
                  value: _require2FA,
                  onChanged: (v) => setState(() => _require2FA = v),
                ),
                const SizedBox(height: 16),
                Text('Session Timeout',
                    style: TextStyle(
                        color: TradieColors.grey600,
                        fontSize: 13,
                        fontWeight: FontWeight.w500)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final opt in [60, 240, 480, 1440, 10080])
                      _ChipOption(
                        label: _timeoutLabel(opt),
                        selected: _sessionTimeout == opt,
                        onTap: () =>
                            setState(() => _sessionTimeout = opt),
                      ),
                  ],
                ),
                if (_policyError != null) ...[
                  const SizedBox(height: 12),
                  _ErrorBanner(_policyError!),
                ],
                const SizedBox(height: 16),
                _SaveButton(
                    saving: _savingPolicy, onTap: _savePolicy),
              ],
            );
          },
        ),

        const SizedBox(height: 16),

        // ── Personal MFA ──────────────────────────────────────────
        mfaAsync.when(
          loading: () => const _CardShimmer(),
          error: (_, __) => const SizedBox.shrink(),
          data: (mfa) {
            final enabled = mfa['enabled'] as bool? ?? false;
            return _SectionCard(
              icon: Iconsax.mobile,
              title: 'Two-Factor Authentication',
              children: [
                Row(children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: enabled
                          ? TradieColors.successGreen.withOpacity(0.1)
                          : TradieColors.grey100,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      enabled
                          ? Iconsax.shield_tick
                          : Iconsax.shield_cross,
                      size: 18,
                      color: enabled
                          ? TradieColors.successGreen
                          : TradieColors.grey600,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            enabled
                                ? '2FA is active'
                                : '2FA is not enabled',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                              color: enabled
                                  ? TradieColors.successGreen
                                  : TradieColors.navy,
                            ),
                          ),
                          Text(
                            enabled
                                ? 'Your account is protected with a TOTP authenticator'
                                : 'Add an extra layer of security to your account',
                            style: const TextStyle(
                                fontSize: 12,
                                color: TradieColors.grey600),
                          ),
                        ]),
                  ),
                  const SizedBox(width: 8),
                  _mfaLoading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2))
                      : enabled
                          ? TextButton(
                              onPressed: _disableMFA,
                              style: TextButton.styleFrom(
                                  foregroundColor:
                                      TradieColors.alertRed),
                              child: const Text('Disable'),
                            )
                          : FilledButton(
                              onPressed: _enableMFA,
                              style: FilledButton.styleFrom(
                                backgroundColor:
                                    TradieColors.electricBlue,
                              ),
                              child: const Text('Enable'),
                            ),
                ]),
                const Divider(height: 24, color: TradieColors.grey100),
                _ActionRow(
                  icon: Iconsax.password_check,
                  label: 'Change Password',
                  subtitle: 'Update your account password',
                  onTap: () => context.push('/profile/change-password'),
                ),
              ],
            );
          },
        ),

        const SizedBox(height: 16),

        // ── Active Sessions ───────────────────────────────────────
        _SectionCard(
          icon: Iconsax.monitor,
          title: 'Active Sessions',
          children: [
            sessionsAsync.when(
              loading: () => const Center(
                  child: Padding(
                      padding: EdgeInsets.all(16),
                      child: CircularProgressIndicator())),
              error: (_, __) =>
                  const _ErrorBanner('Failed to load sessions'),
              data: (sessions) {
                if (sessions.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Center(
                      child: Text('No active sessions found',
                          style: TextStyle(
                              color: TradieColors.grey600,
                              fontSize: 13)),
                    ),
                  );
                }
                return Column(
                  children: sessions.asMap().entries.map((entry) {
                    final i = entry.key;
                    final s = entry.value as Map<String, dynamic>;
                    final isCurrent = s['is_current'] as bool? ?? false;
                    return Column(children: [
                      if (i > 0)
                        const Divider(
                            height: 1, color: TradieColors.grey100),
                      _SessionRow(
                        deviceInfo:
                            s['device_info']?.toString() ?? 'Unknown device',
                        ipAddress:
                            s['ip_address']?.toString() ?? '',
                        lastSeen: s['last_seen']?.toString() ?? '',
                        isCurrent: isCurrent,
                        onRevoke: () => _revokeSession(
                            s['id'].toString(), isCurrent),
                      ),
                    ]);
                  }).toList(),
                );
              },
            ),
          ],
        ),

        const SizedBox(height: 16),

        // ── Audit Log shortcut ────────────────────────────────────
        _SectionCard(
          icon: Iconsax.clipboard_text,
          title: 'Audit Log',
          children: [
            _ActionRow(
              icon: Iconsax.activity,
              label: 'View Audit Log',
              subtitle: 'See all security-relevant actions in your account',
              onTap: () => context.push('/settings/audit-log'),
            ),
          ],
        ),

        const SizedBox(height: 24),
      ]),
    );
  }
}

// ── API Keys Tab ───────────────────────────────────────────────────────────────

class _APIKeysTab extends ConsumerStatefulWidget {
  const _APIKeysTab();
  @override
  ConsumerState<_APIKeysTab> createState() => _APIKeysTabState();
}

class _APIKeysTabState extends ConsumerState<_APIKeysTab> {
  @override
  Widget build(BuildContext context) {
    final async = ref.watch(apiKeysProvider);
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('$e')),
      data: (keys) => Stack(
        children: [
          keys.isEmpty
              ? Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Iconsax.key,
                        size: 48, color: TradieColors.grey400),
                    const SizedBox(height: 12),
                    Text('No API keys',
                        style: TextStyle(
                            color: TradieColors.grey600,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Text('Create a key to access the Tradie API',
                        style: TextStyle(
                            color: TradieColors.grey400, fontSize: 13)),
                  ]),
                )
              : ListView.separated(
                  padding:
                      const EdgeInsets.fromLTRB(20, 20, 20, 100),
                  itemCount: keys.length,
                  separatorBuilder: (_, __) =>
                      const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    final k = keys[i] as Map<String, dynamic>;
                    return _APIKeyCard(
                      id: k['id'].toString(),
                      name: k['name'].toString(),
                      prefix: k['key_prefix'].toString(),
                      scopes:
                          List<String>.from(k['scopes'] ?? []),
                      lastUsed: k['last_used_at']?.toString(),
                      onRevoke: () =>
                          _revokeKey(k['id'].toString()),
                    );
                  },
                ),
          Positioned(
            right: 20,
            bottom: 24,
            child: FloatingActionButton.extended(
              onPressed: _showCreateDialog,
              icon: const Icon(Iconsax.add),
              label: const Text('New Key'),
              backgroundColor: TradieColors.electricBlue,
              foregroundColor: TradieColors.white,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _revokeKey(String id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Revoke API Key'),
        content: const Text(
            'This cannot be undone. Any integrations using this key will stop working.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(
                foregroundColor: TradieColors.alertRed),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref
          .read(settingsNotifierProvider.notifier)
          .revokeAPIKey(id);
    }
  }

  Future<void> _showCreateDialog() async {
    final nameCtrl = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Create API Key'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: nameCtrl,
            decoration: const InputDecoration(
                labelText: 'Key Name',
                hintText: 'e.g. Zapier Integration'),
          ),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () =>
                Navigator.pop(ctx, nameCtrl.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (result != null && result.isNotEmpty) {
      final created = await ref
          .read(settingsNotifierProvider.notifier)
          .createAPIKey(result, ['read', 'write']);
      if (created != null && mounted) {
        showDialog(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('API Key Created'),
            content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                      'Copy this key now — it won\'t be shown again.',
                      style: TextStyle(
                          color: TradieColors.alertRed,
                          fontSize: 13)),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                        color: TradieColors.grey100,
                        borderRadius: BorderRadius.circular(8)),
                    child: Row(children: [
                      Expanded(
                        child: SelectableText(
                          created['key'].toString(),
                          style: const TextStyle(
                              fontFamily: 'monospace', fontSize: 12),
                        ),
                      ),
                      IconButton(
                        icon:
                            const Icon(Iconsax.copy, size: 16),
                        onPressed: () => Clipboard.setData(
                            ClipboardData(
                                text: created['key'].toString())),
                        tooltip: 'Copy key',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                    ]),
                  ),
                ]),
            actions: [
              FilledButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Done')),
            ],
          ),
        );
      }
    }
  }
}

class _APIKeyCard extends StatelessWidget {
  final String id, name, prefix;
  final List<String> scopes;
  final String? lastUsed;
  final VoidCallback onRevoke;

  const _APIKeyCard({
    required this.id,
    required this.name,
    required this.prefix,
    required this.scopes,
    this.lastUsed,
    required this.onRevoke,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: TradieColors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: TradieColors.grey200),
      ),
      child: Row(children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: TradieColors.electricBlue.withOpacity(0.08),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Icon(Iconsax.key,
              color: TradieColors.electricBlue, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                        color: TradieColors.navy)),
                Text('$prefix•••',
                    style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        color: TradieColors.grey600)),
                if (scopes.isNotEmpty)
                  Text('Scopes: ${scopes.join(', ')}',
                      style: const TextStyle(
                          fontSize: 11, color: TradieColors.grey400)),
                if (lastUsed != null)
                  Text('Last used: $lastUsed',
                      style: const TextStyle(
                          fontSize: 11, color: TradieColors.grey400)),
              ]),
        ),
        TextButton(
          onPressed: onRevoke,
          style: TextButton.styleFrom(
              foregroundColor: TradieColors.alertRed),
          child: const Text('Revoke'),
        ),
      ]),
    );
  }
}

// ── Notifications Tab (placeholder) ───────────────────────────────────────────

class _NotificationsTab extends StatelessWidget {
  const _NotificationsTab();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: TradieColors.electricBlue.withOpacity(0.08),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Icon(Iconsax.notification,
                size: 36, color: TradieColors.electricBlue),
          ),
          const SizedBox(height: 20),
          const Text('Notification Preferences',
              style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: TradieColors.navy)),
          const SizedBox(height: 8),
          const Text(
            'Manage email, SMS and push notification preferences for your team.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: TradieColors.grey600),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: () =>
                context.push('/settings/notification-preferences'),
            icon: const Icon(Iconsax.arrow_right_3, size: 18),
            label: const Text('Open Notification Preferences'),
            style: FilledButton.styleFrom(
              backgroundColor: TradieColors.electricBlue,
              foregroundColor: TradieColors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              padding: const EdgeInsets.symmetric(
                  horizontal: 20, vertical: 14),
            ),
          ),
        ]),
      ),
    );
  }
}

// ── Subscription Tab (placeholder) ────────────────────────────────────────────

class _SubscriptionTab extends StatelessWidget {
  const _SubscriptionTab();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: TradieColors.safetyOrange.withOpacity(0.08),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Icon(Iconsax.card,
                size: 36, color: TradieColors.safetyOrange),
          ),
          const SizedBox(height: 20),
          const Text('Subscription & Billing',
              style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: TradieColors.navy)),
          const SizedBox(height: 8),
          const Text(
            'Manage your plan, payment method and billing history.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: TradieColors.grey600),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: () => context.push('/settings/subscription'),
            icon: const Icon(Iconsax.arrow_right_3, size: 18),
            label: const Text('Manage Subscription'),
            style: FilledButton.styleFrom(
              backgroundColor: TradieColors.safetyOrange,
              foregroundColor: TradieColors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              padding: const EdgeInsets.symmetric(
                  horizontal: 20, vertical: 14),
            ),
          ),
        ]),
      ),
    );
  }
}

// ── Session Row ────────────────────────────────────────────────────────────────

class _SessionRow extends StatelessWidget {
  final String deviceInfo;
  final String ipAddress;
  final String lastSeen;
  final bool isCurrent;
  final VoidCallback onRevoke;

  const _SessionRow({
    required this.deviceInfo,
    required this.ipAddress,
    required this.lastSeen,
    required this.isCurrent,
    required this.onRevoke,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: isCurrent
                ? TradieColors.electricBlue.withOpacity(0.1)
                : TradieColors.grey100,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            deviceInfo.toLowerCase().contains('mobile') ||
                    deviceInfo.toLowerCase().contains('ios') ||
                    deviceInfo.toLowerCase().contains('android')
                ? Iconsax.mobile
                : Iconsax.monitor,
            size: 18,
            color: isCurrent
                ? TradieColors.electricBlue
                : TradieColors.grey600,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Flexible(
                    child: Text(
                      deviceInfo,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                          color: TradieColors.navy),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (isCurrent) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: TradieColors.electricBlue
                            .withOpacity(0.1),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text('Current',
                          style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: TradieColors.electricBlue)),
                    ),
                  ],
                ]),
                Text(
                  '$ipAddress · $lastSeen',
                  style: const TextStyle(
                      fontSize: 11, color: TradieColors.grey400),
                  overflow: TextOverflow.ellipsis,
                ),
              ]),
        ),
        TextButton(
          onPressed: onRevoke,
          style: TextButton.styleFrom(
              foregroundColor: TradieColors.alertRed,
              padding: EdgeInsets.zero,
              minimumSize: const Size(56, 32)),
          child: const Text('Revoke', style: TextStyle(fontSize: 13)),
        ),
      ]),
    );
  }
}

// ── Shared Widgets ─────────────────────────────────────────────────────────────

class _SectionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final List<Widget> children;

  const _SectionCard(
      {required this.icon,
      required this.title,
      required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: TradieColors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: TradieColors.grey200),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, size: 18, color: TradieColors.electricBlue),
          const SizedBox(width: 8),
          Text(title,
              style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                  color: TradieColors.navy)),
        ]),
        const SizedBox(height: 16),
        ...children,
      ]),
    );
  }
}

class _CardShimmer extends StatelessWidget {
  const _CardShimmer();

  @override
  Widget build(BuildContext context) => Container(
        height: 100,
        decoration: BoxDecoration(
          color: TradieColors.grey100,
          borderRadius: BorderRadius.circular(12),
        ),
      );
}

class _ToggleRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _ToggleRow({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
            color: TradieColors.grey100,
            borderRadius: BorderRadius.circular(8)),
        child: Icon(icon, size: 18, color: TradieColors.grey600),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                      color: TradieColors.navy)),
              Text(subtitle,
                  style: const TextStyle(
                      fontSize: 12, color: TradieColors.grey600)),
            ]),
      ),
      Switch(
        value: value,
        onChanged: onChanged,
        activeColor: TradieColors.electricBlue,
      ),
    ]);
  }
}

class _ActionRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final VoidCallback onTap;

  const _ActionRow(
      {required this.icon,
      required this.label,
      required this.subtitle,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
                color: TradieColors.grey100,
                borderRadius: BorderRadius.circular(8)),
            child: Icon(icon, size: 18, color: TradieColors.grey600),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                          color: TradieColors.navy)),
                  Text(subtitle,
                      style: const TextStyle(
                          fontSize: 12, color: TradieColors.grey600)),
                ]),
          ),
          const Icon(Iconsax.arrow_right_3,
              size: 16, color: TradieColors.grey400),
        ]),
      ),
    );
  }
}

class _LabeledField extends StatelessWidget {
  final String label;
  final TextEditingController ctrl;
  final TextInputType? keyboardType;

  const _LabeledField(
      {required this.label, required this.ctrl, this.keyboardType});

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label,
          style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: TradieColors.grey600)),
      const SizedBox(height: 6),
      TextField(
        controller: ctrl,
        keyboardType: keyboardType,
        decoration: InputDecoration(
          filled: true,
          fillColor: TradieColors.grey50,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide:
                  const BorderSide(color: TradieColors.grey200)),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide:
                  const BorderSide(color: TradieColors.grey200)),
        ),
      ),
    ]);
  }
}

class _DropdownField extends StatelessWidget {
  final String label;
  final String value;
  final List<String> items;
  final ValueChanged<String?> onChanged;

  const _DropdownField(
      {required this.label,
      required this.value,
      required this.items,
      required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label,
          style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: TradieColors.grey600)),
      const SizedBox(height: 6),
      DropdownButtonFormField<String>(
        value: items.contains(value) ? value : items.first,
        onChanged: onChanged,
        decoration: InputDecoration(
          filled: true,
          fillColor: TradieColors.grey50,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide:
                  const BorderSide(color: TradieColors.grey200)),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide:
                  const BorderSide(color: TradieColors.grey200)),
        ),
        items: items
            .map((i) => DropdownMenuItem(value: i, child: Text(i)))
            .toList(),
      ),
    ]);
  }
}

class _ChipOption extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ChipOption(
      {required this.label,
      required this.selected,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color:
              selected ? TradieColors.electricBlue : TradieColors.grey100,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
              color: selected
                  ? TradieColors.electricBlue
                  : TradieColors.grey200),
        ),
        child: Text(label,
            style: TextStyle(
              color: selected ? TradieColors.white : TradieColors.grey600,
              fontWeight:
                  selected ? FontWeight.w600 : FontWeight.w400,
              fontSize: 13,
            )),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String message;
  const _ErrorBanner(this.message);

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: TradieColors.alertRed.withOpacity(0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: TradieColors.alertRed.withOpacity(0.2)),
        ),
        child: Row(children: [
          const Icon(Iconsax.warning_2,
              color: TradieColors.alertRed, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message.replaceAll('_', ' '),
                style: const TextStyle(
                    color: TradieColors.alertRed, fontSize: 13)),
          ),
        ]),
      );
}

class _SaveButton extends StatelessWidget {
  final bool saving;
  final VoidCallback onTap;

  const _SaveButton({required this.saving, required this.onTap});

  @override
  Widget build(BuildContext context) => SizedBox(
        width: double.infinity,
        height: 50,
        child: FilledButton.icon(
          onPressed: saving ? null : onTap,
          icon: saving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: TradieColors.white))
              : const Icon(Iconsax.tick_circle, size: 18),
          label: Text(saving ? 'Saving…' : 'Save Changes',
              style:
                  const TextStyle(fontWeight: FontWeight.w600)),
          style: FilledButton.styleFrom(
            backgroundColor: TradieColors.electricBlue,
            foregroundColor: TradieColors.white,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
          ),
        ),
      );
}
