import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';

import '../../../core/utils/theme.dart';
import '../../../core/providers/auth_provider.dart';
import '../providers/dashboard_provider.dart';
import '../widgets/kpi_card.dart';
import '../widgets/today_jobs_widget.dart';
import '../widgets/activity_feed_widget.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authNotifierProvider);
    final stats = ref.watch(dashboardStatsProvider);
    final firstName = auth.asData?.value?['first_name'] as String? ?? '';

    return Scaffold(
      backgroundColor: TradieColors.grey50,
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(dashboardStatsProvider),
        child: CustomScrollView(
          slivers: [
            // ── App bar ───────────────────────────────────────────
            SliverAppBar(
              floating: true,
              snap: true,
              backgroundColor: TradieColors.white,
              elevation: 0,
              titleSpacing: 16,
              title: Row(children: [
                Container(
                  width: 36, height: 36,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(colors: [TradieColors.electricBlue, Color(0xFF3B82F6)]),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Iconsax.briefcase, color: TradieColors.white, size: 18),
                ),
                const SizedBox(width: 10),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(
                    firstName.isNotEmpty ? 'Hi, $firstName 👋' : 'Dashboard',
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: TradieColors.navy),
                  ),
                  Text(_todayDate(),
                    style: const TextStyle(fontSize: 11, color: TradieColors.grey400, fontWeight: FontWeight.w400)),
                ]),
              ]),
              actions: [
                // Unread badge
                stats.when(
                  data: (d) {
                    final tasksDue = d['tasks_due'] as int? ?? 0;
                    return tasksDue > 0
                        ? IconButton(
                            onPressed: () => context.push('/tasks'),
                            icon: Badge(
                              label: Text('$tasksDue'),
                              child: const Icon(Iconsax.task_square, color: TradieColors.charcoal),
                            ),
                          )
                        : IconButton(
                            onPressed: () => context.push('/tasks'),
                            icon: const Icon(Iconsax.task_square, color: TradieColors.charcoal),
                          );
                  },
                  loading: () => const SizedBox(width: 48),
                  error: (_, __) => const SizedBox(width: 48),
                ),
                IconButton(
                  onPressed: () => context.go('/notifications'),
                  icon: const Icon(Iconsax.notification, color: TradieColors.charcoal),
                ),
                GestureDetector(
                  onTap: () => context.go('/profile'),
                  child: Padding(
                    padding: const EdgeInsets.only(right: 16, left: 4),
                    child: CircleAvatar(
                      radius: 17,
                      backgroundColor: TradieColors.electricBlue.withOpacity(0.12),
                      child: Text(
                        firstName.isNotEmpty ? firstName[0].toUpperCase() : 'U',
                        style: const TextStyle(fontWeight: FontWeight.w700, color: TradieColors.electricBlue, fontSize: 14),
                      ),
                    ),
                  ),
                ),
              ],
            ),

            SliverToBoxAdapter(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

                // ── KPI grid ────────────────────────────────────
                const SizedBox(height: 20),
                _SectionHeader(title: "Today's Overview", action: null),
                const SizedBox(height: 12),
                stats.when(
                  data: (d) => _KPIGrid(data: d),
                  loading: () => const _KPIGridSkeleton(),
                  error: (_, __) => const _KPIGridSkeleton(),
                ),

                // ── Wide KPIs (revenue + workers) ───────────────
                const SizedBox(height: 12),
                stats.when(
                  data: (d) => _WideKPIRow(data: d),
                  loading: () => const SizedBox(height: 72),
                  error: (_, __) => const SizedBox(),
                ),

                // ── Quick actions ────────────────────────────────
                const SizedBox(height: 24),
                const _SectionHeader(title: 'Quick Actions'),
                const SizedBox(height: 12),
                const _QuickActions(),

                // ── Pending tasks ────────────────────────────────
                const SizedBox(height: 24),
                _SectionHeader(
                  title: 'Task Reminders',
                  action: TextButton(
                    onPressed: () => context.push('/tasks'),
                    child: const Text('See all', style: TextStyle(fontSize: 12)),
                  ),
                ),
                const SizedBox(height: 8),
                stats.when(
                  data: (d) => _TasksPreview(tasks: (d['pending_tasks'] as List<dynamic>?) ?? []),
                  loading: () => const _TaskSkeleton(),
                  error: (_, __) => const SizedBox(),
                ),

                // ── Today's jobs ─────────────────────────────────
                const SizedBox(height: 24),
                _SectionHeader(
                  title: "Today's Jobs",
                  action: TextButton(
                    onPressed: () => context.go('/jobs'),
                    child: const Text('See all', style: TextStyle(fontSize: 12)),
                  ),
                ),
                const SizedBox(height: 8),
                const TodayJobsWidget(),

                // ── Activity feed ─────────────────────────────────
                const SizedBox(height: 24),
                _SectionHeader(
                  title: 'Recent Activity',
                  action: TextButton(
                    onPressed: () => context.push('/activity'),
                    child: const Text('See all', style: TextStyle(fontSize: 12)),
                  ),
                ),
                const SizedBox(height: 12),
                const ActivityFeedWidget(limit: 6),
                const SizedBox(height: 100),
              ]),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => context.go('/jobs/create'),
        backgroundColor: TradieColors.electricBlue,
        foregroundColor: TradieColors.white,
        child: const Icon(Iconsax.add),
      ),
    );
  }

  String _todayDate() {
    final now = DateTime.now();
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    const days   = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
    return '${days[now.weekday - 1]}, ${now.day} ${months[now.month - 1]}';
  }
}

// ── KPI grid ──────────────────────────────────────────────────────

class _KPIGrid extends StatelessWidget {
  final Map<String, dynamic> data;
  const _KPIGrid({required this.data});

  @override
  Widget build(BuildContext context) {
    final jobsToday       = data['jobs_today'] ?? 0;
    final jobsInProgress  = data['jobs_in_progress'] ?? 0;
    final pendingQuotes   = data['pending_quotes'] ?? 0;
    final overdueInvoices = data['overdue_invoices'] ?? 0;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: 1.35,
        children: [
          KPICard(
            title: "Jobs Today",
            value: '$jobsToday',
            icon: Iconsax.briefcase,
            color: TradieColors.electricBlue,
            onTap: () => context.go('/jobs'),
          ),
          KPICard(
            title: 'In Progress',
            value: '$jobsInProgress',
            icon: Iconsax.activity,
            color: TradieColors.safetyOrange,
            onTap: () => context.go('/jobs'),
          ),
          KPICard(
            title: 'Pending Quotes',
            value: '$pendingQuotes',
            icon: Iconsax.document_text,
            color: TradieColors.warningAmber,
            onTap: () => context.go('/quotes'),
          ),
          KPICard(
            title: 'Overdue Invoices',
            value: '$overdueInvoices',
            icon: Iconsax.receipt_disslike,
            color: TradieColors.alertRed,
            onTap: () => context.go('/invoices'),
          ),
        ],
      ),
    );
  }
}

class _KPIGridSkeleton extends StatelessWidget {
  const _KPIGridSkeleton();
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: GridView.count(
      crossAxisCount: 2, shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
      crossAxisSpacing: 12, mainAxisSpacing: 12, childAspectRatio: 1.35,
      children: List.generate(4, (_) => Container(
        decoration: BoxDecoration(color: TradieColors.grey200, borderRadius: BorderRadius.circular(14)),
      )),
    ),
  );
}

// ── Wide KPI row ──────────────────────────────────────────────────

class _WideKPIRow extends StatelessWidget {
  final Map<String, dynamic> data;
  const _WideKPIRow({required this.data});

  @override
  Widget build(BuildContext context) {
    final revMonth    = (data['revenue_month'] as num?)?.toDouble() ?? 0;
    final unpaidAmt   = (data['unpaid_invoices'] as num?)?.toDouble() ?? 0;
    final revTrend    = (data['revenue_trend'] as List<dynamic>?)
        ?.map((e) => ((e as Map)['revenue'] as num?)?.toDouble() ?? 0.0)
        .toList() ?? [];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(children: [
        KPICardWide(
          title: 'Revenue This Month',
          value: '\$${_fmt(revMonth)}',
          icon: Iconsax.dollar_circle,
          color: TradieColors.successGreen,
          sparkData: revTrend,
        ),
        const SizedBox(height: 10),
        KPICardWide(
          title: 'Unpaid Invoices',
          value: '\$${_fmt(unpaidAmt)}',
          subtitle: 'outstanding balance',
          icon: Iconsax.receipt_2,
          color: unpaidAmt > 0 ? TradieColors.alertRed : TradieColors.successGreen,
        ),
      ]),
    );
  }

  String _fmt(double v) {
    if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}M';
    if (v >= 1000)    return '${(v / 1000).toStringAsFixed(1)}k';
    return v.toStringAsFixed(0);
  }
}

// ── Quick actions ─────────────────────────────────────────────────

class _QuickActions extends StatelessWidget {
  const _QuickActions();
  @override
  Widget build(BuildContext context) {
    final actions = [
      (Iconsax.add_circle,    'New Job',       TradieColors.electricBlue,    '/jobs/create'),
      (Iconsax.profile_add,   'Add Customer',  TradieColors.successGreen,    '/customers'),
      (Iconsax.document_text, 'New Quote',     TradieColors.warningAmber,    '/quotes'),
      (Iconsax.receipt_add,   'New Invoice',   TradieColors.safetyOrange,    '/invoices'),
      (Iconsax.task_square,   'Add Task',      const Color(0xFF8B5CF6),      '/tasks'),
    ];
    return SizedBox(
      height: 90,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: actions.map((a) => _QuickChip(icon: a.$1, label: a.$2, color: a.$3, route: a.$4)).toList(),
      ),
    );
  }
}

class _QuickChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final String route;
  const _QuickChip({required this.icon, required this.label, required this.color, required this.route});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: () => context.push(route),
    child: Container(
      margin: const EdgeInsets.only(right: 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.2)),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, color: color, size: 22),
        const SizedBox(height: 5),
        Text(label, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600)),
      ]),
    ),
  );
}

// ── Tasks preview ─────────────────────────────────────────────────

class _TasksPreview extends StatelessWidget {
  final List<dynamic> tasks;
  const _TasksPreview({required this.tasks});

  @override
  Widget build(BuildContext context) {
    if (tasks.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: TradieColors.grey100,
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Row(children: [
            Icon(Iconsax.tick_circle, color: TradieColors.successGreen, size: 18),
            SizedBox(width: 10),
            Text('No tasks due soon', style: TextStyle(color: TradieColors.grey600, fontSize: 13)),
          ]),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(children: tasks.take(3).map((t) {
        final task = t as Map<String, dynamic>;
        final priority = task['priority']?.toString() ?? 'medium';
        final overdue = task['overdue'] == true;
        return Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: TradieColors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: overdue ? TradieColors.alertRed.withOpacity(0.3) : TradieColors.grey200),
          ),
          child: Row(children: [
            Container(
              width: 8, height: 8,
              decoration: BoxDecoration(color: _priorityColor(priority), shape: BoxShape.circle),
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(task['title']?.toString() ?? '',
              style: TextStyle(
                fontSize: 13, fontWeight: FontWeight.w500,
                color: overdue ? TradieColors.alertRed : TradieColors.navy,
              ), maxLines: 1, overflow: TextOverflow.ellipsis)),
            if (task['due'] != null)
              Text(task['due'].toString(),
                style: TextStyle(fontSize: 11, color: overdue ? TradieColors.alertRed : TradieColors.grey400)),
          ]),
        );
      }).toList()),
    );
  }

  Color _priorityColor(String p) {
    switch (p) {
      case 'urgent': return TradieColors.alertRed;
      case 'high':   return TradieColors.safetyOrange;
      case 'medium': return TradieColors.warningAmber;
      default:       return TradieColors.grey400;
    }
  }
}

class _TaskSkeleton extends StatelessWidget {
  const _TaskSkeleton();
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: Column(children: List.generate(2, (_) => Container(
      height: 38, margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(color: TradieColors.grey100, borderRadius: BorderRadius.circular(10)),
    ))),
  );
}

// ── Section header ────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  final Widget? action;
  const _SectionHeader({required this.title, this.action});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: Row(children: [
      Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: TradieColors.navy)),
      const Spacer(),
      if (action != null) action!,
    ]),
  );
}
