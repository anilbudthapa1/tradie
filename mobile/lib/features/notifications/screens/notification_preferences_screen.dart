import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';

import '../../../core/utils/theme.dart';
import '../../../core/providers/settings_provider.dart';

class NotificationPreferencesScreen extends ConsumerStatefulWidget {
  const NotificationPreferencesScreen({super.key});
  @override
  ConsumerState<NotificationPreferencesScreen> createState() =>
      _NotificationPreferencesScreenState();
}

class _NotificationPreferencesScreenState
    extends ConsumerState<NotificationPreferencesScreen> {
  bool _email = true;
  bool _sms = true;
  bool _push = true;
  bool _inApp = true;
  bool _loaded = false;
  bool _saving = false;
  String? _error;

  void _populate(Map<String, dynamic> data) {
    if (_loaded) return;
    final user = data['user'] as Map<String, dynamic>? ?? {};
    _email = user['email'] ?? true;
    _sms = user['sms'] ?? true;
    _push = user['push'] ?? true;
    _inApp = user['in_app'] ?? true;
    _loaded = true;
  }

  Future<void> _save() async {
    setState(() { _saving = true; _error = null; });
    final err = await ref.read(settingsNotifierProvider.notifier).updateNotificationPrefs({
      'user': {
        'email': _email,
        'sms': _sms,
        'push': _push,
        'in_app': _inApp,
      },
    });
    setState(() { _saving = false; _error = err; });
    if (err == null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Preferences saved'), backgroundColor: TradieColors.successGreen),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(notificationPrefsProvider);
    return Scaffold(
      backgroundColor: TradieColors.grey50,
      appBar: AppBar(
        title: Row(children: [
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              color: TradieColors.electricBlue.withOpacity(0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Iconsax.notification, color: TradieColors.electricBlue, size: 20),
          ),
          const SizedBox(width: 10),
          const Text('Notification Preferences'),
        ]),
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (data) {
          _populate(data);
          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _SectionCard(
                icon: Iconsax.notification,
                title: 'Notification Channels',
                subtitle: 'Choose how you want to receive notifications',
                children: [
                  _ChannelToggle(
                    icon: Iconsax.sms,
                    label: 'Email',
                    subtitle: 'Job updates, invoices, reminders',
                    value: _email,
                    onChanged: (v) => setState(() => _email = v),
                  ),
                  const _Divider(),
                  _ChannelToggle(
                    icon: Iconsax.mobile,
                    label: 'SMS',
                    subtitle: 'Urgent alerts and customer messages',
                    value: _sms,
                    onChanged: (v) => setState(() => _sms = v),
                  ),
                  const _Divider(),
                  _ChannelToggle(
                    icon: Iconsax.notification_bing,
                    label: 'Push Notifications',
                    subtitle: 'Real-time alerts on your device',
                    value: _push,
                    onChanged: (v) => setState(() => _push = v),
                  ),
                  const _Divider(),
                  _ChannelToggle(
                    icon: Iconsax.activity,
                    label: 'In-App Notifications',
                    subtitle: 'Notifications within the app',
                    value: _inApp,
                    onChanged: (v) => setState(() => _inApp = v),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _SectionCard(
                icon: Iconsax.info_circle,
                title: 'What you\'ll be notified about',
                children: [
                  for (final item in _notifTypes)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Icon(item.$1, size: 16, color: TradieColors.electricBlue),
                        const SizedBox(width: 10),
                        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(item.$2, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: TradieColors.navy)),
                          Text(item.$3, style: const TextStyle(fontSize: 12, color: TradieColors.grey600)),
                        ])),
                      ]),
                    ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: TradieColors.alertRed.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: TradieColors.alertRed.withOpacity(0.2)),
                  ),
                  child: Row(children: [
                    const Icon(Iconsax.warning_2, color: TradieColors.alertRed, size: 16),
                    const SizedBox(width: 8),
                    Text(_error!.replaceAll('_', ' '),
                      style: const TextStyle(color: TradieColors.alertRed, fontSize: 13)),
                  ]),
                ),
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
                  label: Text(_saving ? 'Saving…' : 'Save Preferences'),
                  style: FilledButton.styleFrom(
                    backgroundColor: TradieColors.electricBlue,
                    foregroundColor: TradieColors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
            ]),
          );
        },
      ),
    );
  }

  static const _notifTypes = [
    (Iconsax.briefcase, 'Job Assignments', 'When you\'re assigned to or removed from a job'),
    (Iconsax.clock, 'Job Reminders', '1 hour before scheduled jobs'),
    (Iconsax.message_text, 'Customer Messages', 'When customers send messages'),
    (Iconsax.receipt_item, 'Invoice Updates', 'When invoices are paid or overdue'),
    (Iconsax.people, 'Team Updates', 'When team members are added or removed'),
    (Iconsax.shield_tick, 'Safety Alerts', 'Incident reports and safety notices'),
  ];
}

class _ChannelToggle extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _ChannelToggle({
    required this.icon, required this.label,
    required this.subtitle, required this.value, required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(children: [
      Container(
        width: 40, height: 40,
        decoration: BoxDecoration(
          color: value ? TradieColors.electricBlue.withOpacity(0.1) : TradieColors.grey100,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, size: 20, color: value ? TradieColors.electricBlue : TradieColors.grey400),
      ),
      const SizedBox(width: 12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: TradieColors.navy)),
        Text(subtitle, style: const TextStyle(fontSize: 12, color: TradieColors.grey600)),
      ])),
      Switch(
        value: value,
        onChanged: onChanged,
        activeColor: TradieColors.electricBlue,
      ),
    ]),
  );
}

class _SectionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final List<Widget> children;

  const _SectionCard({required this.icon, required this.title, this.subtitle, required this.children});

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
      if (subtitle != null) ...[
        const SizedBox(height: 4),
        Text(subtitle!, style: const TextStyle(fontSize: 13, color: TradieColors.grey600)),
      ],
      const SizedBox(height: 16),
      ...children,
    ]),
  );
}

class _Divider extends StatelessWidget {
  const _Divider();
  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: 4),
    child: Divider(height: 1, color: TradieColors.grey100),
  );
}
