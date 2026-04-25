import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';

import '../../../core/utils/theme.dart';
import '../providers/customer_history_provider.dart';

// CustomerHistoryScreen (M19) — chronological timeline combining jobs,
// quotes, invoices, payments and notes for a single customer.
//
// Backend: GET /api/v1/customers/{id}/history
// Add to router.dart: /customers/:id/history → CustomerHistoryScreen(id)
class CustomerHistoryScreen extends ConsumerWidget {
  final String customerId;
  const CustomerHistoryScreen({super.key, required this.customerId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(customerHistoryProvider(customerId));

    return Scaffold(
      backgroundColor: TradieColors.grey50,
      appBar: AppBar(
        backgroundColor: TradieColors.navy,
        foregroundColor: TradieColors.white,
        title: Row(children: const [
          Icon(Iconsax.clock, size: 18),
          SizedBox(width: 8),
          Text('Customer History'),
        ]),
        actions: [
          IconButton(
            icon: const Icon(Iconsax.refresh),
            onPressed: () => ref.invalidate(customerHistoryProvider(customerId)),
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: async.when(
        loading: () => const Center(
          child: CircularProgressIndicator(color: TradieColors.electricBlue),
        ),
        error: (e, _) => _ErrorView(
          message: '$e',
          onRetry: () => ref.invalidate(customerHistoryProvider(customerId)),
        ),
        data: (items) {
          if (items.isEmpty) {
            return const _EmptyView();
          }
          return RefreshIndicator(
            onRefresh: () async =>
                ref.invalidate(customerHistoryProvider(customerId)),
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (_, i) => _HistoryRow(item: items[i]),
            ),
          );
        },
      ),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  final CustomerHistoryItem item;
  const _HistoryRow({required this.item});

  @override
  Widget build(BuildContext context) {
    final color = _kindColor(item.kind);
    final icon = _kindIcon(item.kind);
    final hasAmount = item.amount != null;

    return Container(
      decoration: BoxDecoration(
        color: TradieColors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: TradieColors.grey200),
      ),
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: color.withOpacity(0.10),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 18, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  _KindBadge(kind: item.kind, color: color),
                  if (item.ref.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Text(item.ref,
                        style: const TextStyle(
                            fontSize: 11,
                            color: TradieColors.grey400,
                            fontWeight: FontWeight.w500)),
                  ],
                  const Spacer(),
                  Text(_formatDate(item.occurredAt),
                      style: const TextStyle(
                          fontSize: 11, color: TradieColors.grey400)),
                ]),
                const SizedBox(height: 6),
                Text(
                  item.title.isEmpty ? '(no title)' : item.title,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      color: TradieColors.navy,
                      fontSize: 14),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (item.status.isNotEmpty || hasAmount) ...[
                  const SizedBox(height: 6),
                  Row(children: [
                    if (item.status.isNotEmpty)
                      Text(
                        item.status,
                        style: TextStyle(
                            fontSize: 12,
                            color: color,
                            fontWeight: FontWeight.w600),
                      ),
                    const Spacer(),
                    if (hasAmount)
                      Text(
                        '\$${item.amount!.toStringAsFixed(2)}',
                        style: const TextStyle(
                            fontSize: 14,
                            color: TradieColors.navy,
                            fontWeight: FontWeight.w700),
                      ),
                  ]),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime dt) {
    final local = dt.toLocal();
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${local.day} ${months[local.month - 1]} ${local.year}';
  }

  Color _kindColor(String k) {
    switch (k) {
      case 'job':
        return TradieColors.electricBlue;
      case 'quote':
        return TradieColors.warningAmber;
      case 'invoice':
        return TradieColors.safetyOrange;
      case 'payment':
        return TradieColors.successGreen;
      case 'note':
        return TradieColors.grey600;
      default:
        return TradieColors.grey400;
    }
  }

  IconData _kindIcon(String k) {
    switch (k) {
      case 'job':
        return Iconsax.briefcase;
      case 'quote':
        return Iconsax.document_text;
      case 'invoice':
        return Iconsax.receipt_item;
      case 'payment':
        return Iconsax.money_tick;
      case 'note':
        return Iconsax.note;
      default:
        return Iconsax.activity;
    }
  }
}

class _KindBadge extends StatelessWidget {
  final String kind;
  final Color color;
  const _KindBadge({required this.kind, required this.color});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: color.withOpacity(0.10),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          kind.toUpperCase(),
          style: TextStyle(
              fontSize: 10, fontWeight: FontWeight.w700, color: color),
        ),
      );
}

class _EmptyView extends StatelessWidget {
  const _EmptyView();

  @override
  Widget build(BuildContext context) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: TradieColors.electricBlue.withOpacity(0.07),
              shape: BoxShape.circle,
            ),
            child: const Icon(Iconsax.clock,
                size: 36, color: TradieColors.electricBlue),
          ),
          const SizedBox(height: 16),
          const Text('No history yet',
              style: TextStyle(
                  color: TradieColors.grey600,
                  fontWeight: FontWeight.w600,
                  fontSize: 15)),
          const SizedBox(height: 4),
          const Text(
            'Jobs, quotes, invoices and notes\nwill appear here over time.',
            textAlign: TextAlign.center,
            style: TextStyle(color: TradieColors.grey400, fontSize: 12),
          ),
        ]),
      );
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Iconsax.warning_2,
              size: 36, color: TradieColors.alertRed),
          const SizedBox(height: 12),
          const Text('Failed to load history',
              style: TextStyle(
                  color: TradieColors.navy,
                  fontWeight: FontWeight.w700,
                  fontSize: 15)),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: TradieColors.grey600, fontSize: 12)),
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Iconsax.refresh, size: 16),
            label: const Text('Retry'),
            style: ElevatedButton.styleFrom(
              backgroundColor: TradieColors.electricBlue,
              foregroundColor: TradieColors.white,
            ),
          ),
        ]),
      );
}
