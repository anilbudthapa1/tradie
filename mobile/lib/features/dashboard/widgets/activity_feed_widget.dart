import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';
import '../../../core/utils/theme.dart';
import '../providers/activity_provider.dart';

// Activity Feed widget (M14).
//
// Wired to GET /api/v1/activity via activity_provider. The widget owns
// its own fetch lifecycle so it can be dropped into any screen without
// pulling the entire dashboard payload.
class ActivityFeedWidget extends ConsumerWidget {
  final int limit;
  final String? entityType;

  const ActivityFeedWidget({super.key, this.limit = 8, this.entityType});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ActivityFilter(limit: limit, entityType: entityType);
    final feed = ref.watch(activityFeedProvider(filter));
    return feed.when(
      loading: () => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          children: List.generate(
            3,
            (i) => Container(
              height: 52,
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: TradieColors.grey100,
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ),
      ),
      error: (e, _) => Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Icon(Iconsax.warning_2,
                size: 16, color: TradieColors.alertRed),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Could not load activity',
                style: TextStyle(color: TradieColors.grey600, fontSize: 12),
              ),
            ),
            TextButton(
              onPressed: () => ref.invalidate(activityFeedProvider(filter)),
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
      data: (items) {
        if (items.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Row(children: [
              Icon(Iconsax.activity, size: 16, color: TradieColors.grey400),
              SizedBox(width: 8),
              Text('No recent activity',
                  style:
                      TextStyle(color: TradieColors.grey400, fontSize: 13)),
            ]),
          );
        }
        return ListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: items.length,
          itemBuilder: (_, i) => _ActivityRow(item: items[i]),
        );
      },
    );
  }
}

class _ActivityRow extends StatelessWidget {
  final ActivityItem item;
  const _ActivityRow({required this.item});

  @override
  Widget build(BuildContext context) {
    final color = _categoryColor(item.category);
    final icon = _categoryIcon(item.category);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
              color: color.withOpacity(0.1),
              borderRadius: BorderRadius.circular(9)),
          child: Icon(icon, size: 16, color: color),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            RichText(
              text: TextSpan(
                style: const TextStyle(
                    fontSize: 13,
                    color: TradieColors.navy,
                    fontFamily: 'Inter'),
                children: [
                  TextSpan(
                      text: item.userName,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  TextSpan(text: ' ${_actionLabel(item.action)}'),
                  if (item.entityType != null && item.entityType!.isNotEmpty)
                    TextSpan(
                        text: ' ${item.entityType}',
                        style: const TextStyle(color: TradieColors.grey600)),
                ],
              ),
            ),
            const SizedBox(height: 1),
            Text(_timeAgo(item.createdAt),
                style: const TextStyle(fontSize: 11, color: TradieColors.grey400)),
          ]),
        ),
      ]),
    );
  }

  Color _categoryColor(String cat) {
    switch (cat) {
      case 'job':
        return TradieColors.electricBlue;
      case 'invoice':
        return TradieColors.successGreen;
      case 'quote':
        return TradieColors.warningAmber;
      case 'customer':
        return TradieColors.safetyOrange;
      case 'worker':
        return const Color(0xFF8B5CF6);
      case 'payment':
        return TradieColors.successGreen;
      case 'auth':
        return TradieColors.grey600;
      case 'task':
        return const Color(0xFF8B5CF6);
      case 'lead':
        return TradieColors.warningAmber;
      case 'expense':
        return TradieColors.safetyOrange;
      case 'safety':
        return TradieColors.alertRed;
      default:
        return TradieColors.grey400;
    }
  }

  IconData _categoryIcon(String cat) {
    switch (cat) {
      case 'job':
        return Iconsax.briefcase;
      case 'invoice':
        return Iconsax.receipt_item;
      case 'quote':
        return Iconsax.document_text;
      case 'customer':
        return Iconsax.user;
      case 'worker':
        return Iconsax.people;
      case 'payment':
        return Iconsax.money_tick;
      case 'auth':
        return Iconsax.security_safe;
      case 'task':
        return Iconsax.task_square;
      case 'lead':
        return Iconsax.flag;
      case 'expense':
        return Iconsax.wallet;
      case 'safety':
        return Iconsax.shield;
      default:
        return Iconsax.activity;
    }
  }

  String _actionLabel(String action) {
    // Lower-case first to match both new audit verbs (CUSTOMER_ADDRESS_ADDED)
    // and the legacy dotted form (customer.created).
    final a = action.toLowerCase();
    if (a.contains('viewed')) return 'viewed';
    if (a.contains('added') || a.endsWith('.created') || a.contains('create')) {
      return 'added a';
    }
    if (a.contains('updated') || a.endsWith('.updated')) return 'updated a';
    if (a.contains('deleted') || a.endsWith('.deleted')) return 'deleted a';
    if (a.contains('completed')) return 'completed a';
    if (a.contains('snoozed')) return 'snoozed a';
    if (a.contains('sent')) return 'sent a';
    if (a.contains('paid')) return 'marked paid a';
    if (a.contains('login')) return 'logged in';
    if (a.contains('logout')) return 'logged out';
    return action;
  }

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt.toLocal());
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${(diff.inDays / 7).floor()}w ago';
  }
}
