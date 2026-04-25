import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';
import '../../../core/utils/theme.dart';
import '../providers/dashboard_provider.dart';

class TodayJobsWidget extends ConsumerWidget {
  const TodayJobsWidget({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(dashboardStatsProvider);
    return stats.when(
      loading: () => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(children: List.generate(2, (i) => Container(
          height: 76, margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(color: TradieColors.grey100, borderRadius: BorderRadius.circular(12)),
        ))),
      ),
      error: (_, __) => const SizedBox(),
      data: (data) {
        final jobs = (data['today_jobs'] as List<dynamic>?) ?? [];
        if (jobs.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: TradieColors.successGreen.withOpacity(0.06),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: TradieColors.successGreen.withOpacity(0.2)),
              ),
              child: const Row(children: [
                Icon(Iconsax.tick_circle, color: TradieColors.successGreen, size: 22),
                SizedBox(width: 12),
                Text('All clear — no jobs scheduled today',
                  style: TextStyle(color: TradieColors.successGreen, fontWeight: FontWeight.w500)),
              ]),
            ),
          );
        }
        return Column(
          children: jobs.take(4).map((j) {
            final job = j as Map<String, dynamic>;
            return _JobRow(job: job, onTap: () => context.go('/jobs/${job['id']}'));
          }).toList(),
        );
      },
    );
  }
}

class _JobRow extends StatelessWidget {
  final Map<String, dynamic> job;
  final VoidCallback onTap;
  const _JobRow({required this.job, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final status = job['status']?.toString() ?? 'scheduled';
    final statusColor = _statusColor(status);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: TradieColors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: TradieColors.grey200),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 6, offset: const Offset(0, 2))],
        ),
        child: Row(children: [
          Container(
            width: 4, height: 44,
            decoration: BoxDecoration(color: statusColor, borderRadius: BorderRadius.circular(2)),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(job['title']?.toString() ?? '',
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: TradieColors.navy),
                maxLines: 1, overflow: TextOverflow.ellipsis)),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: statusColor.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(_statusLabel(status),
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: statusColor)),
              ),
            ]),
            const SizedBox(height: 3),
            Row(children: [
              if (job['time'] != null) ...[
                const Icon(Iconsax.clock, size: 12, color: TradieColors.grey400),
                const SizedBox(width: 4),
                Text(job['time'].toString(),
                  style: const TextStyle(fontSize: 12, color: TradieColors.grey600)),
                const SizedBox(width: 10),
              ],
              if (job['customer'] != null) ...[
                const Icon(Iconsax.user, size: 12, color: TradieColors.grey400),
                const SizedBox(width: 4),
                Expanded(child: Text(job['customer'].toString(),
                  style: const TextStyle(fontSize: 12, color: TradieColors.grey600),
                  maxLines: 1, overflow: TextOverflow.ellipsis)),
              ],
            ]),
          ])),
          const Icon(Iconsax.arrow_right_3, size: 16, color: TradieColors.grey400),
        ]),
      ),
    );
  }

  Color _statusColor(String s) {
    switch (s) {
      case 'in_progress': return TradieColors.safetyOrange;
      case 'completed':   return TradieColors.successGreen;
      case 'on_hold':     return TradieColors.warningAmber;
      case 'cancelled':   return TradieColors.alertRed;
      default:            return TradieColors.electricBlue;
    }
  }

  String _statusLabel(String s) => s.replaceAll('_', ' ').toUpperCase();
}
