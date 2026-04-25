import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';
import '../../../core/utils/theme.dart';
import '../providers/dashboard_provider.dart';

class ActivityFeedWidget extends ConsumerWidget {
  final int limit;
  const ActivityFeedWidget({super.key, this.limit = 8});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(dashboardStatsProvider);
    return stats.when(
      loading: () => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(children: List.generate(3, (i) => Container(
          height: 52, margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(color: TradieColors.grey100, borderRadius: BorderRadius.circular(10)),
        ))),
      ),
      error: (_, __) => const SizedBox(),
      data: (data) {
        final activity = (data['activity'] as List<dynamic>?) ?? [];
        if (activity.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Text('No recent activity', style: TextStyle(color: TradieColors.grey400, fontSize: 13)),
          );
        }
        return ListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: activity.take(limit).length,
          itemBuilder: (_, i) {
            final item = activity[i] as Map<String, dynamic>;
            return _ActivityRow(item: item);
          },
        );
      },
    );
  }
}

class _ActivityRow extends StatelessWidget {
  final Map<String, dynamic> item;
  const _ActivityRow({required this.item});

  @override
  Widget build(BuildContext context) {
    final action = item['action']?.toString() ?? '';
    final category = _category(action);
    final color = _categoryColor(category);
    final icon = _categoryIcon(category);
    final userName = item['user_name']?.toString() ?? 'System';
    final entityType = item['entity_type']?.toString() ?? '';

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 34, height: 34,
          decoration: BoxDecoration(color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(9)),
          child: Icon(icon, size: 16, color: color),
        ),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          RichText(text: TextSpan(
            style: const TextStyle(fontSize: 13, color: TradieColors.navy, fontFamily: 'Inter'),
            children: [
              TextSpan(text: userName, style: const TextStyle(fontWeight: FontWeight.w600)),
              TextSpan(text: ' ${_actionLabel(action)}'),
              if (entityType.isNotEmpty)
                TextSpan(text: ' $entityType', style: const TextStyle(color: TradieColors.grey600)),
            ],
          )),
          const SizedBox(height: 1),
          Text(_timeAgo(item['created_at']),
            style: const TextStyle(fontSize: 11, color: TradieColors.grey400)),
        ])),
      ]),
    );
  }

  String _category(String action) {
    if (action.startsWith('job'))      return 'job';
    if (action.startsWith('invoice'))  return 'invoice';
    if (action.startsWith('quote'))    return 'quote';
    if (action.startsWith('customer')) return 'customer';
    if (action.startsWith('worker'))   return 'worker';
    if (action.startsWith('payment'))  return 'payment';
    if (action.startsWith('session'))  return 'auth';
    return 'system';
  }

  Color _categoryColor(String cat) {
    switch (cat) {
      case 'job':      return TradieColors.electricBlue;
      case 'invoice':  return TradieColors.successGreen;
      case 'quote':    return TradieColors.warningAmber;
      case 'customer': return TradieColors.safetyOrange;
      case 'worker':   return const Color(0xFF8B5CF6);
      case 'payment':  return TradieColors.successGreen;
      case 'auth':     return TradieColors.grey600;
      default:         return TradieColors.grey400;
    }
  }

  IconData _categoryIcon(String cat) {
    switch (cat) {
      case 'job':      return Iconsax.briefcase;
      case 'invoice':  return Iconsax.receipt_item;
      case 'quote':    return Iconsax.document_text;
      case 'customer': return Iconsax.user;
      case 'worker':   return Iconsax.people;
      case 'payment':  return Iconsax.money_tick;
      case 'auth':     return Iconsax.security_safe;
      default:         return Iconsax.activity;
    }
  }

  String _actionLabel(String action) {
    final parts = action.split('.');
    if (parts.length < 2) return action;
    switch (parts[1]) {
      case 'created':   return 'created a';
      case 'updated':   return 'updated a';
      case 'deleted':   return 'deleted a';
      case 'completed': return 'completed a';
      case 'sent':      return 'sent a';
      case 'paid':      return 'marked paid a';
      case 'login':     return 'logged in';
      case 'logout':    return 'logged out';
      default:          return parts[1];
    }
  }

  String _timeAgo(dynamic iso) {
    if (iso == null) return '';
    try {
      final dt = DateTime.parse(iso.toString()).toLocal();
      final diff = DateTime.now().difference(dt);
      if (diff.inMinutes < 1)  return 'just now';
      if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
      if (diff.inHours < 24)   return '${diff.inHours}h ago';
      if (diff.inDays < 7)     return '${diff.inDays}d ago';
      return '${(diff.inDays / 7).floor()}w ago';
    } catch (_) { return ''; }
  }
}
