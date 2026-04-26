import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';

import '../../../core/utils/theme.dart';
import '../providers/dashboard_provider.dart';

/// Compact banner that surfaces active dashboard alerts on the
/// home dashboard. Pulls from /dashboard or /me/dashboard depending
/// on `selfService`. Tapping it routes to /alerts.
class AlertsBanner extends ConsumerWidget {
  final bool selfService;
  const AlertsBanner({super.key, this.selfService = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(selfService ? dashboardMeProvider : dashboardOwnerProvider);

    return async.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (payload) {
        final alerts = (payload['alerts'] as List?) ?? const [];
        if (alerts.isEmpty) return const SizedBox.shrink();

        final critical = alerts.where((a) => a['severity'] == 'critical').length;
        final warning = alerts.where((a) => a['severity'] == 'warning').length;
        final headline = alerts.first['title']?.toString() ?? '';
        final tone = critical > 0 ? TradieColors.alertRed : TradieColors.electricBlue;

        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
          child: Material(
            color: TradieColors.white,
            borderRadius: BorderRadius.circular(18),
            child: InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: () => context.push('/alerts'),
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: tone.withOpacity(0.20)),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 36, height: 36,
                      decoration: BoxDecoration(
                        color: tone.withOpacity(0.10),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(Iconsax.warning_2, color: tone, size: 18),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${alerts.length} active alert${alerts.length == 1 ? '' : 's'}'
                            '${critical > 0 ? ' · $critical critical' : warning > 0 ? ' · $warning warning' : ''}',
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 15,
                              color: TradieColors.charcoal,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            headline,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13,
                              color: TradieColors.grey600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Icon(Iconsax.arrow_right_3, size: 16, color: TradieColors.grey400),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
