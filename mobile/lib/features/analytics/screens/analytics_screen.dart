import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';

import '../../../core/utils/theme.dart';
import '../../../core/api/api_client.dart';
import '../providers/analytics_provider.dart';

class AnalyticsScreen extends ConsumerStatefulWidget {
  const AnalyticsScreen({super.key});
  @override
  ConsumerState<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends ConsumerState<AnalyticsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabs;
  String _revPeriod = 'month';

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 5, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TradieColors.grey50,
      appBar: AppBar(
        backgroundColor: TradieColors.white,
        elevation: 0,
        titleSpacing: 16,
        title: Row(children: [
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              color: TradieColors.electricBlue.withOpacity(0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Iconsax.chart_2, color: TradieColors.electricBlue, size: 20),
          ),
          const SizedBox(width: 10),
          const Text('Analytics',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: TradieColors.navy)),
        ]),
        bottom: TabBar(
          controller: _tabs,
          labelStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
          unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w400, fontSize: 12),
          labelColor: TradieColors.electricBlue,
          unselectedLabelColor: TradieColors.grey600,
          indicatorColor: TradieColors.electricBlue,
          indicatorWeight: 2,
          isScrollable: false,
          tabs: const [
            Tab(text: 'Revenue'),
            Tab(text: 'Jobs'),
            Tab(text: 'Workers'),
            Tab(text: 'Finance'),
            Tab(text: 'Widgets'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _RevenueTab(
            period: _revPeriod,
            onPeriodChange: (p) => setState(() => _revPeriod = p),
          ),
          const _JobsTab(),
          const _WorkersTab(),
          const _FinanceTab(),
          const _WidgetsTab(),
        ],
      ),
    );
  }
}

// ── Shared helpers ────────────────────────────────────────────────

String _fmtMoney(double v) {
  if (v >= 1000000) return '\$${(v / 1000000).toStringAsFixed(1)}M';
  if (v >= 1000)    return '\$${(v / 1000).toStringAsFixed(1)}k';
  return '\$${v.toStringAsFixed(0)}';
}

Widget _sectionCard({required String title, required Widget child}) {
  return Container(
    width: double.infinity,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: TradieColors.white,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: TradieColors.grey200),
      boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 8, offset: const Offset(0, 2))],
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: TradieColors.navy)),
      const SizedBox(height: 14),
      child,
    ]),
  );
}

Widget _loadingCard() => Container(
  height: 180,
  decoration: BoxDecoration(color: TradieColors.grey100, borderRadius: BorderRadius.circular(14)),
  child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
);

Widget _errorCard(Object e, VoidCallback onRetry) => Container(
  padding: const EdgeInsets.all(20),
  decoration: BoxDecoration(color: TradieColors.white, borderRadius: BorderRadius.circular(14),
    border: Border.all(color: TradieColors.grey200)),
  child: Column(mainAxisSize: MainAxisSize.min, children: [
    const Icon(Iconsax.warning_2, color: TradieColors.alertRed, size: 28),
    const SizedBox(height: 8),
    Text('$e', style: const TextStyle(fontSize: 12, color: TradieColors.grey600), textAlign: TextAlign.center, maxLines: 2),
    const SizedBox(height: 12),
    TextButton(onPressed: onRetry, child: const Text('Retry')),
  ]),
);

Widget _exportRow({required String label, required IconData icon, required Color color, required VoidCallback onTap}) {
  return GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.2)),
      ),
      child: Row(children: [
        Icon(icon, color: color, size: 18),
        const SizedBox(width: 10),
        Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: color)),
        const Spacer(),
        Icon(Iconsax.export_2, color: color, size: 16),
      ]),
    ),
  );
}

// ── Revenue Tab ───────────────────────────────────────────────────

class _RevenueTab extends ConsumerWidget {
  final String period;
  final ValueChanged<String> onPeriodChange;
  const _RevenueTab({required this.period, required this.onPeriodChange});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final revenueAsync = ref.watch(revenueProvider(period));

    return RefreshIndicator(
      onRefresh: () async => ref.read(revenueProvider(period).notifier).refresh(),
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Period selector
          Row(children: [
            for (final p in ['week', 'month', 'year'])
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: GestureDetector(
                  onTap: () => onPeriodChange(p),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: period == p ? TradieColors.electricBlue : TradieColors.white,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: period == p ? TradieColors.electricBlue : TradieColors.grey200),
                    ),
                    child: Text(
                      p[0].toUpperCase() + p.substring(1),
                      style: TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600,
                        color: period == p ? TradieColors.white : TradieColors.grey600,
                      ),
                    ),
                  ),
                ),
              ),
          ]),
          const SizedBox(height: 16),

          revenueAsync.when(
            loading: () => _loadingCard(),
            error: (e, _) => _errorCard(e, () => ref.read(revenueProvider(period).notifier).refresh()),
            data: (data) {
              final total  = (data['total'] as num?)?.toDouble() ?? 0;
              final items  = (data['data'] as List<dynamic>?) ?? [];

              // Calculate % change: compare last two buckets
              double? pctChange;
              if (items.length >= 2) {
                final prev = ((items[items.length - 2] as Map)['revenue'] as num?)?.toDouble() ?? 0;
                final curr = ((items[items.length - 1] as Map)['revenue'] as num?)?.toDouble() ?? 0;
                if (prev > 0) pctChange = ((curr - prev) / prev) * 100;
              }

              return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                // Hero revenue card
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [TradieColors.successGreen, Color(0xFF22C55E)],
                      begin: Alignment.topLeft, end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(
                      period == 'week' ? 'Revenue This Week'
                        : period == 'year' ? 'Revenue This Year'
                        : 'Revenue This Month',
                      style: TextStyle(color: TradieColors.white.withOpacity(0.85), fontSize: 13)),
                    const SizedBox(height: 4),
                    Text(_fmtMoney(total),
                      style: const TextStyle(color: TradieColors.white, fontSize: 34, fontWeight: FontWeight.w800)),
                    if (pctChange != null) ...[
                      const SizedBox(height: 8),
                      Row(children: [
                        Icon(
                          pctChange >= 0 ? Iconsax.arrow_up_3 : Iconsax.arrow_down_2,
                          color: TradieColors.white.withOpacity(0.9), size: 14),
                        const SizedBox(width: 4),
                        Text(
                          '${pctChange.abs().toStringAsFixed(1)}% vs previous ${period == 'week' ? 'week' : period == 'year' ? 'month' : 'week'}',
                          style: TextStyle(color: TradieColors.white.withOpacity(0.85), fontSize: 12)),
                      ]),
                    ],
                  ]),
                ),
                const SizedBox(height: 16),

                // Bar chart
                if (items.isNotEmpty)
                  _sectionCard(
                    title: 'Revenue by ${period == 'week' ? 'Day' : period == 'year' ? 'Month' : 'Week'}',
                    child: SizedBox(
                      height: 180,
                      child: _RevenueBarChart(data: items),
                    ),
                  ),
                const SizedBox(height: 16),

                // Export row
                _sectionCard(
                  title: 'Export',
                  child: Column(children: [
                    _exportRow(
                      label: 'Export Invoices CSV',
                      icon: Iconsax.document_download,
                      color: TradieColors.electricBlue,
                      onTap: () => _triggerExport(context, ref, 'invoices'),
                    ),
                    const SizedBox(height: 8),
                    _exportRow(
                      label: 'Export Revenue PDF',
                      icon: Iconsax.document_text,
                      color: TradieColors.safetyOrange,
                      onTap: () => _triggerExportPDF(context, ref, 'revenue'),
                    ),
                  ]),
                ),
              ]);
            },
          ),
          const SizedBox(height: 80),
        ]),
      ),
    );
  }
}

class _RevenueBarChart extends StatelessWidget {
  final List<dynamic> data;
  const _RevenueBarChart({required this.data});

  @override
  Widget build(BuildContext context) {
    final maxY = data.fold<double>(1, (m, e) {
      final v = ((e as Map)['revenue'] as num?)?.toDouble() ?? 0;
      return v > m ? v : m;
    });

    return BarChart(BarChartData(
      alignment: BarChartAlignment.spaceAround,
      maxY: maxY * 1.25,
      barTouchData: BarTouchData(
        touchTooltipData: BarTouchTooltipData(
          getTooltipItem: (group, _, rod, __) => BarTooltipItem(
            _fmtMoney(rod.toY),
            const TextStyle(color: TradieColors.white, fontWeight: FontWeight.w600, fontSize: 12),
          ),
        ),
      ),
      titlesData: FlTitlesData(
        show: true,
        bottomTitles: AxisTitles(sideTitles: SideTitles(
          showTitles: true,
          getTitlesWidget: (v, _) {
            final i = v.toInt();
            if (i >= 0 && i < data.length) {
              return Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text((data[i] as Map)['label']?.toString() ?? '',
                  style: const TextStyle(fontSize: 9, color: TradieColors.grey600)),
              );
            }
            return const SizedBox();
          },
        )),
        leftTitles: AxisTitles(sideTitles: SideTitles(
          showTitles: true, reservedSize: 48,
          getTitlesWidget: (v, _) => Text(
            v >= 1000 ? '\$${(v / 1000).toStringAsFixed(0)}k' : '\$${v.toStringAsFixed(0)}',
            style: const TextStyle(fontSize: 9, color: TradieColors.grey400)),
        )),
        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
      ),
      gridData: FlGridData(
        show: true, drawVerticalLine: false,
        getDrawingHorizontalLine: (_) => const FlLine(color: TradieColors.grey100, strokeWidth: 1),
      ),
      borderData: FlBorderData(show: false),
      barGroups: List.generate(data.length, (i) {
        final v = ((data[i] as Map)['revenue'] as num?)?.toDouble() ?? 0;
        return BarChartGroupData(x: i, barRods: [
          BarChartRodData(
            toY: v,
            color: TradieColors.electricBlue,
            width: 20,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(5)),
            backDrawRodData: BackgroundBarChartRodData(
              show: true, toY: maxY * 1.25, color: TradieColors.grey100,
            ),
          ),
        ]);
      }),
    ));
  }
}

// ── Jobs Tab ──────────────────────────────────────────────────────

class _JobsTab extends ConsumerWidget {
  const _JobsTab();

  static const _statusColors = {
    'scheduled':   TradieColors.electricBlue,
    'in_progress': TradieColors.safetyOrange,
    'completed':   TradieColors.successGreen,
    'on_hold':     TradieColors.warningAmber,
    'cancelled':   TradieColors.alertRed,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final jobsAsync = ref.watch(jobsAnalyticsProvider);

    return RefreshIndicator(
      onRefresh: () async => ref.read(jobsAnalyticsProvider.notifier).refresh(),
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        child: jobsAsync.when(
          loading: () => Column(children: [_loadingCard(), const SizedBox(height: 12), _loadingCard()]),
          error: (e, _) => _errorCard(e, () => ref.read(jobsAnalyticsProvider.notifier).refresh()),
          data: (data) {
            final byStatus      = (data['by_status'] as Map<String, dynamic>?) ?? {};
            final completionRate = (data['completion_rate'] as num?)?.toDouble() ?? 0;
            final completed30   = data['completed_30d'] as int? ?? 0;
            final total30       = data['total_30d'] as int? ?? 0;
            final totalAll      = byStatus.values.fold<int>(0, (s, v) => s + ((v as num?)?.toInt() ?? 0));

            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // Completion rate hero
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: TradieColors.navy,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(children: [
                  SizedBox(
                    width: 80, height: 80,
                    child: Stack(alignment: Alignment.center, children: [
                      CircularProgressIndicator(
                        value: completionRate / 100,
                        strokeWidth: 7,
                        backgroundColor: TradieColors.white.withOpacity(0.15),
                        valueColor: const AlwaysStoppedAnimation(TradieColors.successGreen),
                      ),
                      Text('${completionRate.toStringAsFixed(0)}%',
                        style: const TextStyle(color: TradieColors.white, fontSize: 16, fontWeight: FontWeight.w800)),
                    ]),
                  ),
                  const SizedBox(width: 20),
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('Completion Rate',
                      style: TextStyle(color: TradieColors.white, fontSize: 13, fontWeight: FontWeight.w500)),
                    const SizedBox(height: 4),
                    Text('$completed30 of $total30 jobs',
                      style: TextStyle(color: TradieColors.white.withOpacity(0.7), fontSize: 12)),
                    const SizedBox(height: 6),
                    Text('Last 30 days',
                      style: TextStyle(color: TradieColors.white.withOpacity(0.5), fontSize: 11)),
                  ]),
                ]),
              ),
              const SizedBox(height: 16),

              // Status breakdown
              if (byStatus.isNotEmpty)
                _sectionCard(
                  title: 'Jobs by Status',
                  child: Column(children: [
                    // Proportional bar
                    if (totalAll > 0) ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: SizedBox(
                          height: 16,
                          child: Row(
                            children: byStatus.entries.map((e) {
                              final color = _statusColors[e.key] ?? TradieColors.grey400;
                              final pct   = ((e.value as num?)?.toDouble() ?? 0) / totalAll;
                              return Expanded(
                                flex: ((pct * 1000).round()).clamp(1, 1000),
                                child: Container(color: color),
                              );
                            }).toList(),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                    ],
                    // Legend rows
                    ...byStatus.entries.map((e) {
                      final color = _statusColors[e.key] ?? TradieColors.grey400;
                      final count = (e.value as num?)?.toInt() ?? 0;
                      final pct   = totalAll > 0 ? count / totalAll * 100 : 0.0;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(children: [
                          Container(width: 10, height: 10,
                            decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                          const SizedBox(width: 8),
                          Text(
                            e.key.replaceAll('_', ' ').toUpperCase(),
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: TradieColors.navy)),
                          const Spacer(),
                          Text('$count', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: TradieColors.navy)),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 44,
                            child: Text('${pct.toStringAsFixed(0)}%',
                              style: const TextStyle(fontSize: 12, color: TradieColors.grey400),
                              textAlign: TextAlign.right),
                          ),
                        ]),
                      );
                    }),
                  ]),
                ),
              const SizedBox(height: 16),

              // Export
              _sectionCard(
                title: 'Export',
                child: _exportRow(
                  label: 'Export Jobs CSV',
                  icon: Iconsax.document_download,
                  color: TradieColors.electricBlue,
                  onTap: () => _triggerExport(context, ref, 'jobs'),
                ),
              ),
              const SizedBox(height: 80),
            ]);
          },
        ),
      ),
    );
  }
}

// ── Workers Tab ───────────────────────────────────────────────────

class _WorkersTab extends ConsumerWidget {
  const _WorkersTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final workersAsync = ref.watch(workerPerformanceProvider);

    return RefreshIndicator(
      onRefresh: () async => ref.read(workerPerformanceProvider.notifier).refresh(),
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        child: workersAsync.when(
          loading: () => _loadingCard(),
          error: (e, _) => _errorCard(e, () => ref.read(workerPerformanceProvider.notifier).refresh()),
          data: (workers) {
            if (workers.isEmpty) {
              return _sectionCard(
                title: 'Worker Performance',
                child: const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('No worker data available.',
                      style: TextStyle(color: TradieColors.grey400, fontSize: 13)),
                  ),
                ),
              );
            }

            final topWorker = workers.first as Map<String, dynamic>;
            final topCompleted = topWorker['jobs_completed'] as int? ?? 0;

            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // Top worker highlight
              if (topCompleted > 0)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [const Color(0xFF8B5CF6), const Color(0xFF8B5CF6).withOpacity(0.75)],
                      begin: Alignment.topLeft, end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(children: [
                    CircleAvatar(
                      radius: 26,
                      backgroundColor: TradieColors.white.withOpacity(0.2),
                      child: Text(
                        (topWorker['name']?.toString() ?? 'W')[0].toUpperCase(),
                        style: const TextStyle(color: TradieColors.white, fontSize: 20, fontWeight: FontWeight.w800),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('Top Performer',
                        style: TextStyle(color: TradieColors.white, fontSize: 11, fontWeight: FontWeight.w500)),
                      const SizedBox(height: 2),
                      Text(topWorker['name']?.toString() ?? '',
                        style: const TextStyle(color: TradieColors.white, fontSize: 17, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 2),
                      Text('$topCompleted jobs completed this month',
                        style: TextStyle(color: TradieColors.white.withOpacity(0.75), fontSize: 12)),
                    ]),
                  ]),
                ),
              const SizedBox(height: 16),

              // Performance table
              _sectionCard(
                title: 'Worker Performance — Last 30 Days',
                child: Column(children: [
                  // Header
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(children: const [
                      Expanded(flex: 3, child: Text('Worker',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: TradieColors.grey600))),
                      Expanded(child: Text('Done', textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: TradieColors.grey600))),
                      Expanded(child: Text('Assigned', textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: TradieColors.grey600))),
                      Expanded(child: Text('Avg h', textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: TradieColors.grey600))),
                    ]),
                  ),
                  const Divider(height: 1, color: TradieColors.grey100),
                  ...workers.map((w) {
                    final worker   = w as Map<String, dynamic>;
                    final name     = worker['name']?.toString() ?? '';
                    final done     = worker['jobs_completed'] as int? ?? 0;
                    final assigned = worker['jobs_assigned'] as int? ?? 0;
                    final avgH     = (worker['avg_hours'] as num?)?.toDouble() ?? 0;
                    final initials = name.isNotEmpty
                        ? name.split(' ').take(2).map((p) => p.isNotEmpty ? p[0] : '').join()
                        : 'W';

                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Row(children: [
                        Expanded(flex: 3, child: Row(children: [
                          CircleAvatar(
                            radius: 14,
                            backgroundColor: TradieColors.electricBlue.withOpacity(0.1),
                            child: Text(initials,
                              style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                                color: TradieColors.electricBlue)),
                          ),
                          const SizedBox(width: 8),
                          Expanded(child: Text(name,
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: TradieColors.navy),
                            maxLines: 1, overflow: TextOverflow.ellipsis)),
                        ])),
                        Expanded(child: Text('$done', textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: TradieColors.successGreen))),
                        Expanded(child: Text('$assigned', textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 13, color: TradieColors.navy))),
                        Expanded(child: Text(avgH.toStringAsFixed(1), textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 13, color: TradieColors.grey600))),
                      ]),
                    );
                  }),
                ]),
              ),
              const SizedBox(height: 80),
            ]);
          },
        ),
      ),
    );
  }
}

// ── Finance Tab ───────────────────────────────────────────────────

class _FinanceTab extends ConsumerWidget {
  const _FinanceTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final financeAsync = ref.watch(financeAnalyticsProvider);

    return RefreshIndicator(
      onRefresh: () async => ref.read(financeAnalyticsProvider.notifier).refresh(),
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        child: financeAsync.when(
          loading: () => Column(children: [_loadingCard(), const SizedBox(height: 12), _loadingCard()]),
          error: (e, _) => _errorCard(e, () => ref.read(financeAnalyticsProvider.notifier).refresh()),
          data: (data) {
            final incomeExpense = (data['income_expense'] as List<dynamic>?) ?? [];
            final gst           = (data['gst'] as Map<String, dynamic>?) ?? {};

            final gstCollected = (gst['gst_collected'] as num?)?.toDouble() ?? 0;
            final gstPaid      = (gst['gst_paid'] as num?)?.toDouble() ?? 0;
            final gstOwing     = (gst['gst_owing'] as num?)?.toDouble() ?? 0;
            final quarter      = gst['quarter']?.toString() ?? '';

            // Totals
            final totalIncome  = incomeExpense.fold<double>(0, (s, e) => s + ((e as Map)['income'] as num? ?? 0).toDouble());
            final totalExpense = incomeExpense.fold<double>(0, (s, e) => s + ((e as Map)['expense'] as num? ?? 0).toDouble());
            final totalProfit  = totalIncome - totalExpense;

            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // P&L hero
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: TradieColors.navy,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('6-Month Summary',
                    style: TextStyle(color: Colors.white60, fontSize: 12)),
                  const SizedBox(height: 12),
                  Row(children: [
                    _FinanceStat(label: 'Income', value: _fmtMoney(totalIncome), color: TradieColors.successGreen),
                    const SizedBox(width: 24),
                    _FinanceStat(label: 'Expenses', value: _fmtMoney(totalExpense), color: TradieColors.alertRed),
                    const SizedBox(width: 24),
                    _FinanceStat(
                      label: 'Profit',
                      value: _fmtMoney(totalProfit),
                      color: totalProfit >= 0 ? TradieColors.successGreen : TradieColors.alertRed,
                    ),
                  ]),
                ]),
              ),
              const SizedBox(height: 16),

              // Income vs Expense grouped chart
              if (incomeExpense.isNotEmpty)
                _sectionCard(
                  title: 'Income vs Expenses',
                  child: SizedBox(
                    height: 200,
                    child: _IncomeExpenseChart(data: incomeExpense),
                  ),
                ),
              const SizedBox(height: 16),

              // GST section
              _sectionCard(
                title: 'GST / BAS — $quarter',
                child: Column(children: [
                  _GstRow(label: 'GST Collected', value: gstCollected, color: TradieColors.successGreen),
                  const SizedBox(height: 10),
                  _GstRow(label: 'GST Paid (on expenses)', value: gstPaid, color: TradieColors.electricBlue),
                  const Divider(height: 20, color: TradieColors.grey100),
                  _GstRow(
                    label: 'GST Owing',
                    value: gstOwing,
                    color: gstOwing > 0 ? TradieColors.alertRed : TradieColors.successGreen,
                    bold: true,
                  ),
                ]),
              ),
              const SizedBox(height: 16),

              // Exports
              _sectionCard(
                title: 'Export',
                child: Column(children: [
                  _exportRow(
                    label: 'Export Customers CSV',
                    icon: Iconsax.document_download,
                    color: TradieColors.electricBlue,
                    onTap: () => _triggerExport(context, ref, 'customers'),
                  ),
                  const SizedBox(height: 8),
                  _exportRow(
                    label: 'Year-End Summary',
                    icon: Iconsax.calendar_2,
                    color: TradieColors.safetyOrange,
                    onTap: () => _triggerYearEnd(context, ref),
                  ),
                ]),
              ),
              const SizedBox(height: 80),
            ]);
          },
        ),
      ),
    );
  }
}

class _FinanceStat extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _FinanceStat({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(label, style: const TextStyle(color: Colors.white60, fontSize: 11)),
    const SizedBox(height: 2),
    Text(value, style: TextStyle(color: color, fontSize: 15, fontWeight: FontWeight.w800)),
  ]);
}

class _GstRow extends StatelessWidget {
  final String label;
  final double value;
  final Color color;
  final bool bold;
  const _GstRow({required this.label, required this.value, required this.color, this.bold = false});

  @override
  Widget build(BuildContext context) => Row(children: [
    Expanded(child: Text(label,
      style: TextStyle(fontSize: 13, fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
        color: TradieColors.navy))),
    Text(_fmtMoney(value),
      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: color)),
  ]);
}

class _IncomeExpenseChart extends StatelessWidget {
  final List<dynamic> data;
  const _IncomeExpenseChart({required this.data});

  @override
  Widget build(BuildContext context) {
    final maxY = data.fold<double>(1, (m, e) {
      final inc = ((e as Map)['income'] as num?)?.toDouble() ?? 0;
      final exp = (e['expense'] as num?)?.toDouble() ?? 0;
      final mx  = inc > exp ? inc : exp;
      return mx > m ? mx : m;
    });

    return BarChart(BarChartData(
      alignment: BarChartAlignment.spaceAround,
      maxY: maxY * 1.25,
      groupsSpace: 12,
      barTouchData: BarTouchData(
        touchTooltipData: BarTouchTooltipData(
          getTooltipItem: (group, _, rod, rodIndex) {
            final label = rodIndex == 0 ? 'Income' : 'Expense';
            return BarTooltipItem(
              '$label\n${_fmtMoney(rod.toY)}',
              const TextStyle(color: TradieColors.white, fontSize: 11, fontWeight: FontWeight.w600),
            );
          },
        ),
      ),
      titlesData: FlTitlesData(
        bottomTitles: AxisTitles(sideTitles: SideTitles(
          showTitles: true,
          getTitlesWidget: (v, _) {
            final i = v.toInt();
            if (i >= 0 && i < data.length) {
              return Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text((data[i] as Map)['month']?.toString() ?? '',
                  style: const TextStyle(fontSize: 9, color: TradieColors.grey600)),
              );
            }
            return const SizedBox();
          },
        )),
        leftTitles: AxisTitles(sideTitles: SideTitles(
          showTitles: true, reservedSize: 44,
          getTitlesWidget: (v, _) => Text(
            v >= 1000 ? '\$${(v / 1000).toStringAsFixed(0)}k' : '\$${v.toStringAsFixed(0)}',
            style: const TextStyle(fontSize: 9, color: TradieColors.grey400)),
        )),
        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
      ),
      gridData: FlGridData(
        show: true, drawVerticalLine: false,
        getDrawingHorizontalLine: (_) => const FlLine(color: TradieColors.grey100, strokeWidth: 1),
      ),
      borderData: FlBorderData(show: false),
      barGroups: List.generate(data.length, (i) {
        final item    = data[i] as Map;
        final income  = (item['income'] as num?)?.toDouble() ?? 0;
        final expense = (item['expense'] as num?)?.toDouble() ?? 0;
        return BarChartGroupData(x: i, groupVertically: false, barRods: [
          BarChartRodData(
            toY: income,
            color: TradieColors.successGreen,
            width: 10,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
          ),
          BarChartRodData(
            toY: expense,
            color: TradieColors.alertRed.withOpacity(0.75),
            width: 10,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
          ),
        ]);
      }),
    ));
  }
}

// ── Export helpers ────────────────────────────────────────────────

void _triggerExport(BuildContext context, WidgetRef ref, String type) async {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text('Preparing $type export…'),
    backgroundColor: TradieColors.navy,
    behavior: SnackBarBehavior.floating,
    duration: const Duration(seconds: 2),
  ));
  try {
    final api = ref.read(apiClientProvider);
    await api.get('/reports/export/csv', params: {
      'type': type,
      'start': _monthStart(),
      'end': _today(),
    });
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('$type CSV exported successfully'),
        backgroundColor: TradieColors.successGreen,
        behavior: SnackBarBehavior.floating,
      ));
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Export failed: $e'),
        backgroundColor: TradieColors.alertRed,
        behavior: SnackBarBehavior.floating,
      ));
    }
  }
}

void _triggerExportPDF(BuildContext context, WidgetRef ref, String type) async {
  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
    content: Text('Preparing PDF report…'),
    backgroundColor: TradieColors.navy,
    behavior: SnackBarBehavior.floating,
    duration: Duration(seconds: 2),
  ));
  try {
    final api = ref.read(apiClientProvider);
    await api.get('/reports/export/pdf', params: {'type': type});
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('PDF report ready'),
        backgroundColor: TradieColors.successGreen,
        behavior: SnackBarBehavior.floating,
      ));
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('PDF failed: $e'),
        backgroundColor: TradieColors.alertRed,
        behavior: SnackBarBehavior.floating,
      ));
    }
  }
}

void _triggerYearEnd(BuildContext context, WidgetRef ref) async {
  final year = DateTime.now().year.toString();
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text('Preparing $year year-end summary…'),
    backgroundColor: TradieColors.navy,
    behavior: SnackBarBehavior.floating,
    duration: const Duration(seconds: 2),
  ));
  try {
    final api = ref.read(apiClientProvider);
    await api.get('/reports/export/year-end', params: {'year': year});
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('$year summary ready'),
        backgroundColor: TradieColors.successGreen,
        behavior: SnackBarBehavior.floating,
      ));
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Export failed: $e'),
        backgroundColor: TradieColors.alertRed,
        behavior: SnackBarBehavior.floating,
      ));
    }
  }
}

String _today() {
  final n = DateTime.now();
  return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
}

String _monthStart() {
  final n = DateTime.now();
  return '${n.year}-${n.month.toString().padLeft(2, '0')}-01';
}

// ── Widgets tab (Module 12) ───────────────────────────────────────

class _WidgetsTab extends ConsumerWidget {
  const _WidgetsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tilesAsync = ref.watch(myAnalyticsWidgetsProvider);

    return RefreshIndicator(
      color: TradieColors.electricBlue,
      onRefresh: () async => ref.invalidate(myAnalyticsWidgetsProvider),
      child: tilesAsync.when(
        loading: () => ListView(children: [const SizedBox(height: 200), Center(child: _loadingCard())]),
        error: (e, _) => ListView(
          padding: const EdgeInsets.all(20),
          children: [_errorCard(e, () => ref.invalidate(myAnalyticsWidgetsProvider))],
        ),
        data: (tiles) {
          if (tiles.isEmpty) {
            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(20),
              children: [
                const SizedBox(height: 60),
                const Icon(Iconsax.chart_2, size: 48, color: TradieColors.grey400),
                const SizedBox(height: 12),
                const Center(
                  child: Text('No widgets yet',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                ),
                const SizedBox(height: 6),
                const Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 24),
                    child: Text(
                      'Pin the metrics that matter to you and they will show up here.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: TradieColors.grey600),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Center(
                  child: FilledButton.icon(
                    onPressed: () => context.push('/analytics/widgets'),
                    style: FilledButton.styleFrom(backgroundColor: TradieColors.electricBlue),
                    icon: const Icon(Iconsax.add, size: 18),
                    label: const Text('Manage widgets'),
                  ),
                ),
              ],
            );
          }

          return ListView(
            padding: const EdgeInsets.all(20),
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: tiles.length,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  childAspectRatio: 1.35,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                ),
                itemBuilder: (_, i) {
                  final t = tiles[i] as Map<String, dynamic>;
                  return _LiveTile(tile: t);
                },
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: () => context.push('/analytics/widgets'),
                icon: const Icon(Iconsax.setting_2, size: 16),
                label: const Text('Manage widgets'),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _LiveTile extends StatelessWidget {
  final Map<String, dynamic> tile;
  const _LiveTile({required this.tile});

  @override
  Widget build(BuildContext context) {
    final unit = tile['unit']?.toString() ?? 'count';
    final raw = tile['value'];
    final value = raw == null
        ? '—'
        : unit == 'aud'
            ? _fmtMoney((raw as num).toDouble())
            : unit == 'percent'
                ? '${(raw as num).toStringAsFixed(0)}%'
                : (raw as num).toInt().toString();
    final color = _colorFor(tile['color_token']?.toString() ?? 'blue');

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: TradieColors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: TradieColors.grey200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32, height: 32,
            decoration: BoxDecoration(
              color: color.withOpacity(0.10),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(_iconFor(tile['icon_token']?.toString() ?? 'chart_2'),
                size: 16, color: color),
          ),
          const Spacer(),
          Text(value,
              style: TextStyle(
                fontSize: 22, fontWeight: FontWeight.w800,
                color: color, letterSpacing: -0.5)),
          const SizedBox(height: 2),
          Text(tile['title']?.toString() ?? '',
              style: const TextStyle(fontSize: 12, color: TradieColors.grey600)),
        ],
      ),
    );
  }

  Color _colorFor(String token) => switch (token) {
        'green' => TradieColors.successGreen,
        'red' => TradieColors.alertRed,
        'navy' => TradieColors.navy,
        'grey' => TradieColors.grey600,
        _ => TradieColors.electricBlue,
      };

  IconData _iconFor(String token) => switch (token) {
        'dollar_circle' => Iconsax.dollar_circle,
        'briefcase' => Iconsax.briefcase,
        'document_text' => Iconsax.document_text,
        'receipt' => Iconsax.receipt,
        'wallet' => Iconsax.wallet,
        'health' => Iconsax.health,
        'warning_2' => Iconsax.warning_2,
        'people' => Iconsax.people,
        _ => Iconsax.chart_2,
      };
}
