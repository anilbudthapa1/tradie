import 'package:flutter/material.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';
import '../../../core/utils/theme.dart';

class JobCard extends StatelessWidget {
  final Map<String, dynamic> job;
  final VoidCallback onTap;
  final VoidCallback? onComplete;

  const JobCard({
    super.key,
    required this.job,
    required this.onTap,
    this.onComplete,
  });

  @override
  Widget build(BuildContext context) {
    final status = job['status'] as String? ?? 'draft';
    final priority = job['priority'] as String? ?? 'normal';
    final isCompleted = status == 'completed';

    return Dismissible(
      key: ValueKey(job['id']),
      direction: isCompleted ? DismissDirection.none : DismissDirection.startToEnd,
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.startToEnd && onComplete != null) {
          onComplete!();
        }
        return false; // Don't actually dismiss — just trigger action
      },
      background: Container(
        margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        decoration: BoxDecoration(
          color: TradieColors.successGreen,
          borderRadius: BorderRadius.circular(12),
        ),
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.only(left: 24),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Iconsax.tick_circle, color: Colors.white, size: 24),
            SizedBox(width: 8),
            Text('Complete', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14)),
          ],
        ),
      ),
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          decoration: BoxDecoration(
            color: TradieColors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: TradieColors.grey200),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.04),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Top row: status chip + job number
                Row(
                  children: [
                    _StatusChip(status: status),
                    const SizedBox(width: 8),
                    _PriorityBadge(priority: priority),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: TradieColors.navy.withOpacity(0.06),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        job['job_number'] ?? '',
                        style: const TextStyle(
                          fontSize: 11,
                          color: TradieColors.navy,
                          fontWeight: FontWeight.w600,
                          fontFamily: 'Inter',
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),

                // Title
                Text(
                  job['title'] ?? 'Untitled Job',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: TradieColors.navy,
                    fontFamily: 'Inter',
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),

                // Customer name
                if (job['customer_name'] != null && (job['customer_name'] as String).isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      const Icon(Iconsax.user, size: 13, color: TradieColors.grey400),
                      const SizedBox(width: 4),
                      Text(
                        job['customer_name'] as String,
                        style: const TextStyle(fontSize: 13, color: TradieColors.grey600),
                      ),
                    ],
                  ),
                ],

                // Address
                if (job['address_line1'] != null || job['city'] != null) ...[
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      const Icon(Iconsax.location, size: 13, color: TradieColors.grey400),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          _formatAddress(job),
                          style: const TextStyle(fontSize: 12, color: TradieColors.grey600),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ] else if (job['lat'] != null) ...[
                  const SizedBox(height: 3),
                  const Row(
                    children: [
                      Icon(Iconsax.location, size: 13, color: TradieColors.grey400),
                      SizedBox(width: 4),
                      Text('Has location', style: TextStyle(fontSize: 12, color: TradieColors.grey600)),
                    ],
                  ),
                ],

                const SizedBox(height: 12),

                // Bottom row: time + workers + arrow
                Row(
                  children: [
                    if (job['scheduled_start'] != null) ...[
                      const Icon(Iconsax.clock, size: 14, color: TradieColors.grey400),
                      const SizedBox(width: 4),
                      Text(
                        _formatDate(job['scheduled_start'] as String?),
                        style: const TextStyle(fontSize: 12, color: TradieColors.grey600),
                      ),
                    ],
                    const Spacer(),
                    if (job['workers'] != null) _WorkersAvatars(workers: job['workers'] as List),
                    const SizedBox(width: 8),
                    const Icon(Iconsax.arrow_right_3, size: 16, color: TradieColors.grey400),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _formatAddress(Map<String, dynamic> job) {
    final parts = <String>[];
    if (job['address_line1'] != null) parts.add(job['address_line1'] as String);
    if (job['city'] != null) parts.add(job['city'] as String);
    return parts.join(', ');
  }

  String _formatDate(String? iso) {
    if (iso == null) return '';
    try {
      final dt = DateTime.parse(iso).toLocal();
      final now = DateTime.now();
      final isToday = dt.year == now.year && dt.month == now.month && dt.day == now.day;
      final isTomorrow = dt.year == now.year && dt.month == now.month && dt.day == now.day + 1;
      final timeStr =
          '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
      if (isToday) return 'Today $timeStr';
      if (isTomorrow) return 'Tomorrow $timeStr';
      return '${dt.day}/${dt.month} $timeStr';
    } catch (_) {
      return iso;
    }
  }
}

class _StatusChip extends StatelessWidget {
  final String status;
  const _StatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    final color = status.jobStatusColor;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 6, height: 6, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 5),
          Text(
            _label(status),
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color),
          ),
        ],
      ),
    );
  }

  String _label(String s) =>
      s.split('_').map((w) => w.isNotEmpty ? w[0].toUpperCase() + w.substring(1) : '').join(' ');
}

class _PriorityBadge extends StatelessWidget {
  final String priority;
  const _PriorityBadge({required this.priority});

  @override
  Widget build(BuildContext context) {
    if (priority == 'normal' || priority == 'low') return const SizedBox.shrink();
    final color = priority == 'urgent'
        ? TradieColors.alertRed
        : priority == 'high'
            ? TradieColors.safetyOrange
            : TradieColors.electricBlue;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        priority[0].toUpperCase() + priority.substring(1),
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: color),
      ),
    );
  }
}

class _WorkersAvatars extends StatelessWidget {
  final List workers;
  const _WorkersAvatars({required this.workers});

  @override
  Widget build(BuildContext context) {
    if (workers.isEmpty) return const SizedBox.shrink();
    const maxShow = 3;
    final shown = workers.take(maxShow).toList();
    final overflow = workers.length - maxShow;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 0; i < shown.length; i++)
          Transform.translate(
            offset: Offset(-(i * 8).toDouble(), 0),
            child: Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: TradieColors.electricBlue.withOpacity(0.15),
                shape: BoxShape.circle,
                border: Border.all(color: TradieColors.white, width: 1.5),
              ),
              child: Center(
                child: Text(
                  _initials(shown[i] as String),
                  style: const TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    color: TradieColors.electricBlue,
                  ),
                ),
              ),
            ),
          ),
        if (overflow > 0)
          Transform.translate(
            offset: Offset(-(shown.length * 8).toDouble(), 0),
            child: Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: TradieColors.grey200,
                shape: BoxShape.circle,
                border: Border.all(color: TradieColors.white, width: 1.5),
              ),
              child: Center(
                child: Text(
                  '+$overflow',
                  style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: TradieColors.grey600),
                ),
              ),
            ),
          ),
      ],
    );
  }

  String _initials(String name) {
    final parts = name.trim().split(' ');
    if (parts.length >= 2) return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    return name.isNotEmpty ? name[0].toUpperCase() : '?';
  }
}
