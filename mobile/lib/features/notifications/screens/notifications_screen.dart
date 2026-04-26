import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';

import '../../../core/utils/theme.dart';
import '../../../core/api/api_client.dart';

final _notificationsProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  final resp = await ref.read(apiClientProvider).get('/notifications');
  return resp.data as Map<String, dynamic>;
});

class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(_notificationsProvider);

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
            child: async.when(
              data: (data) {
                final unread = data['unread_count'] as int? ?? 0;
                return unread > 0
                    ? Badge(label: Text('$unread'), child: const Icon(Iconsax.notification, color: TradieColors.electricBlue, size: 20))
                    : const Icon(Iconsax.notification, color: TradieColors.electricBlue, size: 20);
              },
              loading: () => const Icon(Iconsax.notification, color: TradieColors.electricBlue, size: 20),
              error: (_, __) => const Icon(Iconsax.notification, color: TradieColors.electricBlue, size: 20),
            ),
          ),
          const SizedBox(width: 10),
          const Text('Notifications'),
        ]),
        actions: [
          IconButton(
            icon: const Icon(Iconsax.setting_2),
            tooltip: 'Preferences',
            onPressed: () => context.push('/notifications/preferences'),
          ),
          if (async.asData?.value?['unread_count'] != null &&
              (async.asData!.value!['unread_count'] as int) > 0)
            TextButton(
              onPressed: () => _markAllRead(ref),
              child: const Text('Mark all read', style: TextStyle(fontSize: 12)),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(_notificationsProvider),
        child: async.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('$e')),
          data: (data) {
            final notifs = data['notifications'] as List<dynamic>? ?? [];
            if (notifs.isEmpty) {
              return Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Iconsax.notification_status, size: 56, color: TradieColors.grey400),
                  const SizedBox(height: 12),
                  const Text('No notifications', style: TextStyle(fontWeight: FontWeight.w600, color: TradieColors.grey600)),
                  const SizedBox(height: 4),
                  const Text('You\'re all caught up!', style: TextStyle(color: TradieColors.grey400, fontSize: 13)),
                ]),
              );
            }
            return ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: notifs.length,
              separatorBuilder: (_, __) => const SizedBox(height: 1),
              itemBuilder: (_, i) {
                final n = notifs[i] as Map<String, dynamic>;
                return _NotifTile(
                  notif: n,
                  onTap: () => _markRead(ref, n['id'].toString()),
                );
              },
            );
          },
        ),
      ),
    );
  }

  Future<void> _markAllRead(WidgetRef ref) async {
    try {
      await ref.read(apiClientProvider).post('/notifications/read-all');
      ref.invalidate(_notificationsProvider);
    } catch (_) {}
  }

  Future<void> _markRead(WidgetRef ref, String id) async {
    try {
      await ref.read(apiClientProvider).post('/notifications/$id/read');
      ref.invalidate(_notificationsProvider);
    } catch (_) {}
  }
}

class _NotifTile extends StatelessWidget {
  final Map<String, dynamic> notif;
  final VoidCallback onTap;

  const _NotifTile({required this.notif, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isRead = notif['read'] == true;
    final type = notif['type']?.toString() ?? '';
    final title = notif['title']?.toString() ?? '';
    final body = notif['body']?.toString() ?? '';

    return InkWell(
      onTap: onTap,
      child: Container(
        color: isRead ? TradieColors.white : TradieColors.electricBlue.withOpacity(0.04),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(
              color: _typeColor(type).withOpacity(0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(_typeIcon(type), size: 20, color: _typeColor(type)),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(title,
                style: TextStyle(
                  fontWeight: isRead ? FontWeight.w500 : FontWeight.w700,
                  fontSize: 14, color: TradieColors.navy))),
              if (!isRead)
                Container(
                  width: 8, height: 8,
                  decoration: const BoxDecoration(color: TradieColors.electricBlue, shape: BoxShape.circle),
                ),
            ]),
            if (body.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(body,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, color: TradieColors.grey600)),
            ],
          ])),
        ]),
      ),
    );
  }

  IconData _typeIcon(String type) {
    switch (type) {
      case 'job_assigned': return Iconsax.briefcase;
      case 'job_reminder': return Iconsax.clock;
      case 'invoice_paid': return Iconsax.money_tick;
      case 'invoice_overdue': return Iconsax.receipt_minus;
      case 'payment_failed': return Iconsax.wallet_remove;
      case 'safety_alert': return Iconsax.shield_cross;
      case 'team_update': return Iconsax.people;
      default: return Iconsax.notification;
    }
  }

  Color _typeColor(String type) {
    switch (type) {
      case 'job_assigned': return TradieColors.electricBlue;
      case 'job_reminder': return TradieColors.warningAmber;
      case 'invoice_paid': return TradieColors.successGreen;
      case 'invoice_overdue': return TradieColors.alertRed;
      case 'payment_failed': return TradieColors.alertRed;
      case 'safety_alert': return TradieColors.safetyOrange;
      default: return TradieColors.electricBlue;
    }
  }
}
