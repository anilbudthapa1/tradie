import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';

import '../../../core/utils/theme.dart';
import '../../../core/providers/auth_provider.dart';
import '../../../core/widgets/apple_card.dart';
import '../../../core/widgets/apple_pill_button.dart';
import '../../../core/widgets/apple_tile.dart';
import '../providers/dashboard_provider.dart';
import '../widgets/alerts_banner.dart';

/// Apple-grammar dashboard.
///
/// A scrolling stack of full-bleed tiles that alternate light → dark → light
/// → dark → light → parchment. No padding, no shadows, no chrome — the
/// colour change is the divider.
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authNotifierProvider);
    final stats = ref.watch(dashboardStatsProvider);
    final firstName = auth.asData?.value?['first_name'] as String? ?? '';
    final role = (auth.asData?.value?['role']?.toString() ?? 'worker').toLowerCase();
    final ownerView = const {'owner', 'admin', 'manager', 'accountant'}.contains(role);

    return Scaffold(
      backgroundColor: TradieColors.white,
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(dashboardStatsProvider);
          ref.invalidate(dashboardOwnerProvider);
          ref.invalidate(dashboardMeProvider);
        },
        color: TradieColors.electricBlue,
        backgroundColor: TradieColors.white,
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            _GreetingTile(firstName: firstName),
            AlertsBanner(selfService: !ownerView),
            _ActiveJobsTile(stats: stats),
            _OutstandingInvoicesTile(stats: stats),
            _ScheduleTile(stats: stats),
            const _QuickActionsTile(),
            _RecentActivityTile(stats: stats),
          ],
        ),
      ),
    );
  }
}

// ─── Tile 1 — Greeting (light/white) ─────────────────────────────────────────

class _GreetingTile extends StatelessWidget {
  final String firstName;
  const _GreetingTile({required this.firstName});

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final greeting = _greeting();
    final headline = firstName.isNotEmpty
        ? '$greeting, $firstName.'
        : '$greeting.';

    return AppleTile(
      alignment: CrossAxisAlignment.center,
      padding: const EdgeInsets.fromLTRB(24, 96, 24, 64),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            headline,
            textAlign: TextAlign.center,
            style: tt.displayMedium?.copyWith(
              color: TradieColors.charcoal,
              letterSpacing: -0.4,
              height: 1.10,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            "Here's what's happening today.",
            textAlign: TextAlign.center,
            style: tt.headlineLarge?.copyWith(
              color: TradieColors.grey600,
              height: 1.14,
            ),
          ),
        ],
      ),
    );
  }

  String _greeting() {
    final h = DateTime.now().hour;
    if (h < 12) return 'Good morning';
    if (h < 18) return 'Good afternoon';
    return 'Good evening';
  }
}

// ─── Tile 2 — Active jobs (dark) ─────────────────────────────────────────────

class _ActiveJobsTile extends StatelessWidget {
  final AsyncValue<Map<String, dynamic>> stats;
  const _ActiveJobsTile({required this.stats});

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final data = stats.asData?.value ?? const {};
    final jobsToday = (data['jobs_today'] as int?) ?? 0;
    final jobsInProgress = (data['jobs_in_progress'] as int?) ?? 0;
    final scheduledThisWeek = jobsToday + jobsInProgress;

    return AppleTile(
      dark: true,
      alignment: CrossAxisAlignment.center,
      padding: const EdgeInsets.fromLTRB(24, 80, 24, 80),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            'Active jobs',
            textAlign: TextAlign.center,
            style: tt.displayMedium?.copyWith(
              color: TradieColors.white,
              letterSpacing: -0.4,
              height: 1.10,
            ),
          ),
          const SizedBox(height: 32),
          Text(
            '$jobsInProgress',
            textAlign: TextAlign.center,
            style: tt.displayLarge?.copyWith(
              color: TradieColors.white,
              letterSpacing: -0.6,
              height: 1.07,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            scheduledThisWeek == 1
                ? '1 scheduled this week'
                : '$scheduledThisWeek scheduled this week',
            textAlign: TextAlign.center,
            style: tt.headlineLarge?.copyWith(
              color: TradieColors.white.withOpacity(0.8),
              height: 1.14,
            ),
          ),
          const SizedBox(height: 40),
          ApplePillButton(
            label: 'View jobs',
            primary: true,
            onPressed: () => context.go('/jobs'),
          ),
        ],
      ),
    );
  }
}

// ─── Tile 3 — Outstanding invoices (parchment) ───────────────────────────────

class _OutstandingInvoicesTile extends StatelessWidget {
  final AsyncValue<Map<String, dynamic>> stats;
  const _OutstandingInvoicesTile({required this.stats});

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final data = stats.asData?.value ?? const {};
    final unpaid = (data['unpaid_invoices'] as num?)?.toDouble() ?? 0.0;

    return AppleTile(
      parchment: true,
      alignment: CrossAxisAlignment.center,
      padding: const EdgeInsets.fromLTRB(24, 80, 24, 80),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            'Outstanding invoices',
            textAlign: TextAlign.center,
            style: tt.displayMedium?.copyWith(
              color: TradieColors.charcoal,
              letterSpacing: -0.4,
              height: 1.10,
            ),
          ),
          const SizedBox(height: 32),
          Text(
            '\$${_fmt(unpaid)}',
            textAlign: TextAlign.center,
            style: tt.displayLarge?.copyWith(
              color: TradieColors.charcoal,
              letterSpacing: -0.6,
              height: 1.07,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Outstanding balance.',
            textAlign: TextAlign.center,
            style: tt.headlineLarge?.copyWith(
              color: TradieColors.grey600,
              height: 1.14,
            ),
          ),
          const SizedBox(height: 40),
          ApplePillButton(
            label: 'Send reminders',
            primary: false,
            onPressed: () => context.go('/invoices'),
          ),
        ],
      ),
    );
  }

  String _fmt(double v) {
    if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}M';
    if (v >= 1000) return '${(v / 1000).toStringAsFixed(1)}k';
    return v.toStringAsFixed(0);
  }
}

// ─── Tile 4 — Today's schedule (dark) ────────────────────────────────────────

class _ScheduleTile extends StatelessWidget {
  final AsyncValue<Map<String, dynamic>> stats;
  const _ScheduleTile({required this.stats});

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final data = stats.asData?.value ?? const {};
    final jobs = (data['today_jobs'] as List<dynamic>?) ?? const [];
    final next = jobs.take(3).toList();

    return AppleTile(
      dark: true,
      alignment: CrossAxisAlignment.start,
      padding: const EdgeInsets.fromLTRB(24, 80, 24, 80),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "Today's schedule.",
            style: tt.displayMedium?.copyWith(
              color: TradieColors.white,
              letterSpacing: -0.4,
              height: 1.10,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            next.isEmpty
                ? 'Nothing on the calendar.'
                : '${next.length} upcoming.',
            style: tt.headlineLarge?.copyWith(
              color: TradieColors.white.withOpacity(0.8),
              height: 1.14,
            ),
          ),
          const SizedBox(height: 48),
          if (next.isEmpty)
            Text(
              'Your day is clear.',
              style: tt.bodyLarge?.copyWith(
                color: TradieColors.white.withOpacity(0.48),
                height: 1.47,
              ),
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (int i = 0; i < next.length; i++) ...[
                  if (i > 0)
                    Container(
                      height: 1,
                      color: TradieColors.white.withOpacity(0.08),
                      margin: const EdgeInsets.symmetric(vertical: 20),
                    ),
                  _ScheduleRow(job: next[i] as Map<String, dynamic>),
                ],
              ],
            ),
          const SizedBox(height: 40),
          ApplePillButton(
            label: 'Open schedule',
            primary: true,
            onPressed: () => context.go('/jobs'),
          ),
        ],
      ),
    );
  }
}

class _ScheduleRow extends StatelessWidget {
  final Map<String, dynamic> job;
  const _ScheduleRow({required this.job});

  @override
  Widget build(BuildContext context) {
    final time = job['time']?.toString() ?? '—';
    final title = job['title']?.toString() ?? 'Untitled job';
    final location = job['customer']?.toString() ??
        job['location']?.toString() ??
        '';

    return GestureDetector(
      onTap: () {
        final id = job['id']?.toString();
        if (id != null && id.isNotEmpty) context.go('/jobs/$id');
      },
      behavior: HitTestBehavior.opaque,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 84,
            child: Text(
              time,
              style: const TextStyle(
                fontFamily: 'Inter',
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: TradieColors.white,
                height: 1.24,
                letterSpacing: -0.374,
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 17,
                    fontWeight: FontWeight.w400,
                    color: TradieColors.white,
                    height: 1.47,
                    letterSpacing: -0.374,
                  ),
                ),
                if (location.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    location,
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 14,
                      fontWeight: FontWeight.w400,
                      color: TradieColors.white.withOpacity(0.48),
                      height: 1.43,
                      letterSpacing: -0.224,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Tile 5 — Quick actions (light/white) ────────────────────────────────────

class _QuickActionsTile extends StatelessWidget {
  const _QuickActionsTile();

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;

    final actions = <_QuickAction>[
      _QuickAction(
        icon: Iconsax.add_circle,
        label: 'New job',
        route: '/jobs/create',
      ),
      _QuickAction(
        icon: Iconsax.receipt_add,
        label: 'New invoice',
        route: '/invoices',
      ),
      _QuickAction(
        icon: Iconsax.profile_add,
        label: 'New customer',
        route: '/customers',
      ),
      _QuickAction(
        icon: Iconsax.clock,
        label: 'Time clock',
        route: '/timesheets',
      ),
    ];

    return AppleTile(
      alignment: CrossAxisAlignment.start,
      padding: const EdgeInsets.fromLTRB(24, 80, 24, 80),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Quick actions.',
            style: tt.displayMedium?.copyWith(
              color: TradieColors.charcoal,
              letterSpacing: -0.4,
              height: 1.10,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'One tap to get moving.',
            style: tt.headlineLarge?.copyWith(
              color: TradieColors.grey600,
              height: 1.14,
            ),
          ),
          const SizedBox(height: 48),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisSpacing: 16,
            mainAxisSpacing: 16,
            childAspectRatio: 1.2,
            children: [
              for (final a in actions)
                AppleCard(
                  onTap: () => context.go(a.route),
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Icon(
                        a.icon,
                        color: TradieColors.electricBlue,
                        size: 28,
                      ),
                      Text(
                        a.label,
                        style: const TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          color: TradieColors.charcoal,
                          height: 1.24,
                          letterSpacing: -0.374,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _QuickAction {
  final IconData icon;
  final String label;
  final String route;
  const _QuickAction({
    required this.icon,
    required this.label,
    required this.route,
  });
}

// ─── Tile 6 — Recent activity (parchment) ────────────────────────────────────

class _RecentActivityTile extends StatelessWidget {
  final AsyncValue<Map<String, dynamic>> stats;
  const _RecentActivityTile({required this.stats});

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final data = stats.asData?.value ?? const {};
    final activity = ((data['activity'] as List<dynamic>?) ?? const [])
        .take(5)
        .toList();

    return AppleTile(
      parchment: true,
      alignment: CrossAxisAlignment.start,
      padding: const EdgeInsets.fromLTRB(24, 80, 24, 96),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Recent activity.',
            style: tt.displayMedium?.copyWith(
              color: TradieColors.charcoal,
              letterSpacing: -0.4,
              height: 1.10,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            "What's been happening across your business.",
            style: tt.headlineLarge?.copyWith(
              color: TradieColors.grey600,
              height: 1.14,
            ),
          ),
          const SizedBox(height: 48),
          if (activity.isEmpty)
            Text(
              'No activity yet.',
              style: tt.bodyLarge?.copyWith(
                color: TradieColors.grey400,
                height: 1.47,
              ),
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (int i = 0; i < activity.length; i++) ...[
                  if (i > 0)
                    Container(
                      height: 1,
                      color: TradieColors.grey200,
                      margin: const EdgeInsets.symmetric(vertical: 16),
                    ),
                  _ActivityRow(item: activity[i] as Map<String, dynamic>),
                ],
              ],
            ),
        ],
      ),
    );
  }
}

class _ActivityRow extends StatelessWidget {
  final Map<String, dynamic> item;
  const _ActivityRow({required this.item});

  @override
  Widget build(BuildContext context) {
    final action = item['action']?.toString() ?? '';
    final userName = item['user_name']?.toString() ?? 'System';
    final entityType = item['entity_type']?.toString() ?? '';
    final time = _timeAgo(item['created_at']);
    final summary =
        '$userName ${_actionLabel(action)}${entityType.isNotEmpty ? ' $entityType' : ''}';

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          margin: const EdgeInsets.only(top: 9),
          width: 8,
          height: 8,
          decoration: const BoxDecoration(
            color: TradieColors.electricBlue,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Text(
            summary,
            style: const TextStyle(
              fontFamily: 'Inter',
              fontSize: 17,
              fontWeight: FontWeight.w400,
              color: TradieColors.charcoal,
              height: 1.47,
              letterSpacing: -0.374,
            ),
          ),
        ),
        const SizedBox(width: 16),
        Text(
          time,
          style: const TextStyle(
            fontFamily: 'Inter',
            fontSize: 14,
            fontWeight: FontWeight.w400,
            color: TradieColors.grey400,
            height: 1.43,
            letterSpacing: -0.224,
          ),
        ),
      ],
    );
  }

  String _actionLabel(String action) {
    final parts = action.split('.');
    if (parts.length < 2) return action;
    switch (parts[1]) {
      case 'created':
        return 'created a';
      case 'updated':
        return 'updated a';
      case 'deleted':
        return 'deleted a';
      case 'completed':
        return 'completed a';
      case 'sent':
        return 'sent a';
      case 'paid':
        return 'marked paid a';
      case 'login':
        return 'logged in';
      case 'logout':
        return 'logged out';
      default:
        return parts[1];
    }
  }

  String _timeAgo(dynamic iso) {
    if (iso == null) return '';
    try {
      final dt = DateTime.parse(iso.toString()).toLocal();
      final diff = DateTime.now().difference(dt);
      if (diff.inMinutes < 1) return 'just now';
      if (diff.inMinutes < 60) return '${diff.inMinutes}m';
      if (diff.inHours < 24) return '${diff.inHours}h';
      if (diff.inDays < 7) return '${diff.inDays}d';
      return '${(diff.inDays / 7).floor()}w';
    } catch (_) {
      return '';
    }
  }
}
