import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';

import '../../../core/utils/theme.dart';
import '../../../core/providers/auth_provider.dart';
import '../../../core/providers/business_provider.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});
  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final authAsync = ref.watch(authStateProvider);
    final user = authAsync.asData?.value;

    return Scaffold(
      backgroundColor: TradieColors.grey50,
      appBar: AppBar(
        title: Row(children: [
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              color: TradieColors.safetyOrange.withOpacity(0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Iconsax.user, color: TradieColors.safetyOrange, size: 20),
          ),
          const SizedBox(width: 10),
          const Text('My Profile'),
        ]),
        actions: [
          TextButton.icon(
            onPressed: _confirmLogout,
            icon: const Icon(Iconsax.logout, size: 16),
            label: const Text('Sign Out'),
            style: TextButton.styleFrom(foregroundColor: TradieColors.alertRed),
          ),
          const SizedBox(width: 8),
        ],
        bottom: TabBar(
          controller: _tabs,
          labelStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w400, fontSize: 13),
          labelColor: TradieColors.electricBlue,
          unselectedLabelColor: TradieColors.grey600,
          indicatorColor: TradieColors.electricBlue,
          indicatorWeight: 2,
          tabs: const [Tab(text: 'My Account'), Tab(text: 'Business')],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _MyAccountTab(user: user),
          const _BusinessTab(),
        ],
      ),
    );
  }

  Future<void> _confirmLogout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Sign Out'),
        content: const Text('Are you sure you want to sign out?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: TradieColors.alertRed),
            child: const Text('Sign Out'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await ref.read(authNotifierProvider.notifier).logout();
      if (mounted) context.go('/auth/login');
    }
  }
}

// ── My Account Tab ────────────────────────────────────────────────────────────

class _MyAccountTab extends ConsumerStatefulWidget {
  final Map<String, dynamic>? user;
  const _MyAccountTab({this.user});
  @override
  ConsumerState<_MyAccountTab> createState() => _MyAccountTabState();
}

class _MyAccountTabState extends ConsumerState<_MyAccountTab> {
  late final TextEditingController _firstCtrl;
  late final TextEditingController _lastCtrl;
  late final TextEditingController _phoneCtrl;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final u = widget.user ?? {};
    _firstCtrl = TextEditingController(text: u['first_name'] ?? '');
    _lastCtrl = TextEditingController(text: u['last_name'] ?? '');
    _phoneCtrl = TextEditingController(text: u['phone'] ?? '');
  }

  @override
  void dispose() {
    _firstCtrl.dispose();
    _lastCtrl.dispose();
    _phoneCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() { _saving = true; _error = null; });
    try {
      await ref.read(apiClientProvider).patch('/auth/me', data: {
        'first_name': _firstCtrl.text.trim(),
        'last_name': _lastCtrl.text.trim(),
        'phone': _phoneCtrl.text.trim(),
      });
      ref.invalidate(authStateProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Profile updated'), backgroundColor: TradieColors.successGreen),
        );
      }
    } catch (e) {
      setState(() => _error = 'Update failed. Please try again.');
    }
    setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final u = widget.user ?? {};
    final role = u['role'] ?? 'worker';
    final email = u['email'] ?? '';
    final initials = '${(u['first_name'] ?? 'U').toString().isNotEmpty ? (u['first_name'] as String)[0] : ''}${(u['last_name'] ?? '').toString().isNotEmpty ? (u['last_name'] as String)[0] : ''}';

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(children: [
        // Avatar card
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [TradieColors.electricBlue, Color(0xFF3B82F6)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(children: [
            CircleAvatar(
              radius: 36,
              backgroundColor: TradieColors.white.withOpacity(0.2),
              child: Text(initials.toUpperCase(),
                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: TradieColors.white)),
            ),
            const SizedBox(height: 12),
            Text('${'${u['first_name'] ?? ''} ${u['last_name'] ?? ''}'.trim()}',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: TradieColors.white)),
            const SizedBox(height: 4),
            Text(email, style: TextStyle(fontSize: 13, color: TradieColors.white.withOpacity(0.8))),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: TradieColors.white.withOpacity(0.2),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(role.toString().toUpperCase(),
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: TradieColors.white, letterSpacing: 0.5)),
            ),
          ]),
        ),
        const SizedBox(height: 20),
        _Card(
          icon: Iconsax.user_edit,
          title: 'Personal Details',
          children: [
            _FieldRow(label: 'First Name', ctrl: _firstCtrl),
            const SizedBox(height: 12),
            _FieldRow(label: 'Last Name', ctrl: _lastCtrl),
            const SizedBox(height: 12),
            _FieldRow(label: 'Phone', ctrl: _phoneCtrl, keyboardType: TextInputType.phone),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: TradieColors.grey100,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(children: [
                const Icon(Iconsax.sms, size: 16, color: TradieColors.grey600),
                const SizedBox(width: 8),
                Expanded(child: Text(email, style: const TextStyle(fontSize: 14, color: TradieColors.grey600))),
                const Text('Cannot change', style: TextStyle(fontSize: 11, color: TradieColors.grey400)),
              ]),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _Card(
          icon: Iconsax.security_safe,
          title: 'Security',
          children: [
            _LinkRow(icon: Iconsax.password_check, label: 'Change Password', onTap: () => context.push('/auth/reset-password')),
            const Divider(height: 1, color: TradieColors.grey100),
            _LinkRow(icon: Iconsax.mobile, label: 'Two-Factor Authentication', onTap: () {}),
            const Divider(height: 1, color: TradieColors.grey100),
            _LinkRow(icon: Iconsax.devices, label: 'Active Sessions', onTap: () {}),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          _ErrorBanner(_error!),
        ],
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          height: 50,
          child: FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: TradieColors.white))
                : const Icon(Iconsax.tick_circle, size: 18),
            label: Text(_saving ? 'Saving…' : 'Save Changes'),
            style: FilledButton.styleFrom(
              backgroundColor: TradieColors.electricBlue,
              foregroundColor: TradieColors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
      ]),
    );
  }
}

// ── Business Tab ──────────────────────────────────────────────────────────────

class _BusinessTab extends ConsumerStatefulWidget {
  const _BusinessTab();
  @override
  ConsumerState<_BusinessTab> createState() => _BusinessTabState();
}

class _BusinessTabState extends ConsumerState<_BusinessTab> {
  final _nameCtrl = TextEditingController();
  final _abnCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _websiteCtrl = TextEditingController();
  final _addr1Ctrl = TextEditingController();
  final _cityCtrl = TextEditingController();
  final _stateCtrl = TextEditingController();
  final _postcodeCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  bool _loaded = false;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_nameCtrl, _abnCtrl, _phoneCtrl, _emailCtrl, _websiteCtrl,
        _addr1Ctrl, _cityCtrl, _stateCtrl, _postcodeCtrl, _descCtrl]) {
      c.dispose();
    }
    super.dispose();
  }

  void _populate(Map<String, dynamic> b, Map<String, dynamic> p) {
    if (_loaded) return;
    _nameCtrl.text = b['name'] ?? '';
    _abnCtrl.text = b['abn'] ?? '';
    _phoneCtrl.text = b['phone'] ?? '';
    _emailCtrl.text = b['email'] ?? '';
    _websiteCtrl.text = b['website'] ?? '';
    _addr1Ctrl.text = b['address_line1'] ?? '';
    _cityCtrl.text = b['city'] ?? '';
    _stateCtrl.text = b['state'] ?? '';
    _postcodeCtrl.text = b['postcode'] ?? '';
    _descCtrl.text = p['description'] ?? '';
    _loaded = true;
  }

  Future<void> _save() async {
    setState(() { _saving = true; _error = null; });
    final bizErr = await ref.read(businessNotifierProvider.notifier).updateBusiness({
      'name': _nameCtrl.text.trim(),
      'abn': _abnCtrl.text.trim(),
      'phone': _phoneCtrl.text.trim(),
      'email': _emailCtrl.text.trim(),
      'website': _websiteCtrl.text.trim(),
      'address_line1': _addr1Ctrl.text.trim(),
      'city': _cityCtrl.text.trim(),
      'state': _stateCtrl.text.trim(),
      'postcode': _postcodeCtrl.text.trim(),
    });
    if (bizErr == null) {
      await ref.read(businessNotifierProvider.notifier).updateProfile({
        'description': _descCtrl.text.trim(),
      });
    }
    setState(() { _saving = false; _error = bizErr; });
    if (bizErr == null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Business profile updated'), backgroundColor: TradieColors.successGreen),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bizAsync = ref.watch(businessProvider);
    final profAsync = ref.watch(businessProfileProvider);

    final biz = bizAsync.asData?.value ?? {};
    final prof = profAsync.asData?.value ?? {};
    _populate(biz, prof);

    if (bizAsync.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _Card(
          icon: Iconsax.building,
          title: 'Business Details',
          children: [
            _FieldRow(label: 'Business Name', ctrl: _nameCtrl),
            const SizedBox(height: 12),
            _FieldRow(label: 'ABN', ctrl: _abnCtrl, hint: 'XX XXX XXX XXX'),
            const SizedBox(height: 12),
            _FieldRow(label: 'Phone', ctrl: _phoneCtrl, keyboardType: TextInputType.phone),
            const SizedBox(height: 12),
            _FieldRow(label: 'Email', ctrl: _emailCtrl, keyboardType: TextInputType.emailAddress),
            const SizedBox(height: 12),
            _FieldRow(label: 'Website', ctrl: _websiteCtrl, hint: 'https://...'),
          ],
        ),
        const SizedBox(height: 16),
        _Card(
          icon: Iconsax.location,
          title: 'Address',
          children: [
            _FieldRow(label: 'Street Address', ctrl: _addr1Ctrl),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: _FieldRow(label: 'City / Suburb', ctrl: _cityCtrl)),
              const SizedBox(width: 12),
              SizedBox(width: 80, child: _FieldRow(label: 'State', ctrl: _stateCtrl)),
            ]),
            const SizedBox(height: 12),
            SizedBox(width: 140, child: _FieldRow(label: 'Postcode', ctrl: _postcodeCtrl, keyboardType: TextInputType.number)),
          ],
        ),
        const SizedBox(height: 16),
        _Card(
          icon: Iconsax.document_text,
          title: 'About',
          children: [
            _FieldRow(
              label: 'Business Description',
              ctrl: _descCtrl,
              maxLines: 4,
              hint: 'What services does your business provide?',
            ),
          ],
        ),
        const SizedBox(height: 16),
        _Card(
          icon: Iconsax.setting_4,
          title: 'Manage',
          children: [
            _LinkRow(
              icon: Iconsax.receipt_item,
              label: 'Invoice & Quote Settings',
              onTap: () => context.push('/settings'),
            ),
            const Divider(height: 1, color: TradieColors.grey100),
            _LinkRow(
              icon: Iconsax.money,
              label: 'Payroll Settings',
              onTap: () => context.push('/settings'),
            ),
            const Divider(height: 1, color: TradieColors.grey100),
            _LinkRow(
              icon: Iconsax.crown_1,
              label: 'Subscription & Billing',
              onTap: () => context.push('/settings/subscription'),
            ),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          _ErrorBanner(_error!),
        ],
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          height: 50,
          child: FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: TradieColors.white))
                : const Icon(Iconsax.tick_circle, size: 18),
            label: Text(_saving ? 'Saving…' : 'Save Changes'),
            style: FilledButton.styleFrom(
              backgroundColor: TradieColors.electricBlue,
              foregroundColor: TradieColors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
      ]),
    );
  }
}

// ── Shared Widgets ────────────────────────────────────────────────────────────

class _Card extends StatelessWidget {
  final IconData icon;
  final String title;
  final List<Widget> children;

  const _Card({required this.icon, required this.title, required this.children});

  @override
  Widget build(BuildContext context) => Container(
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
        Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: TradieColors.navy)),
      ]),
      const SizedBox(height: 16),
      ...children,
    ]),
  );
}

class _FieldRow extends StatelessWidget {
  final String label;
  final TextEditingController ctrl;
  final TextInputType? keyboardType;
  final String? hint;
  final int maxLines;

  const _FieldRow({
    required this.label, required this.ctrl,
    this.keyboardType, this.hint, this.maxLines = 1,
  });

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: TradieColors.grey600)),
    const SizedBox(height: 6),
    TextField(
      controller: ctrl,
      keyboardType: keyboardType,
      maxLines: maxLines,
      decoration: InputDecoration(
        hintText: hint,
        filled: true,
        fillColor: TradieColors.grey50,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: TradieColors.grey200)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: TradieColors.grey200)),
      ),
    ),
  ]);
}

class _LinkRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _LinkRow({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(8),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
      child: Row(children: [
        Icon(icon, size: 18, color: TradieColors.grey600),
        const SizedBox(width: 12),
        Expanded(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 14, color: TradieColors.navy))),
        const Icon(Iconsax.arrow_right_3, size: 16, color: TradieColors.grey400),
      ]),
    ),
  );
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
      border: Border.all(color: TradieColors.alertRed.withOpacity(0.2)),
    ),
    child: Row(children: [
      const Icon(Iconsax.warning_2, color: TradieColors.alertRed, size: 16),
      const SizedBox(width: 8),
      Expanded(child: Text(message.replaceAll('_', ' '),
        style: const TextStyle(color: TradieColors.alertRed, fontSize: 13))),
    ]),
  );
}
