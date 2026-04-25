import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';
import '../providers/workers_provider.dart';

const _navy = Color(0xFF1A2332);
const _blue = Color(0xFF2563EB);
const _green = Color(0xFF16A34A);
const _orange = Color(0xFFF97316);
const _red = Color(0xFFDC2626);

class WorkerDetailScreen extends ConsumerStatefulWidget {
  final String workerId;
  const WorkerDetailScreen({super.key, required this.workerId});

  @override
  ConsumerState<WorkerDetailScreen> createState() => _WorkerDetailScreenState();
}

class _WorkerDetailScreenState extends ConsumerState<WorkerDetailScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

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
    final workerAsync = ref.watch(workerDetailProvider(widget.workerId));

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      body: workerAsync.when(
        loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
        error: (e, _) => Scaffold(
          appBar: AppBar(backgroundColor: _navy, foregroundColor: Colors.white),
          body: Center(child: Text('Error: $e')),
        ),
        data: (worker) {
          final name = '${worker['first_name']} ${worker['last_name']}';
          final role = (worker['role'] ?? 'worker').toString();
          final initials = '${(worker['first_name'] ?? '?').toString().characters.first}'
              '${(worker['last_name'] ?? '?').toString().characters.firstOrNull ?? ''}';

          return NestedScrollView(
            headerSliverBuilder: (ctx, _) => [
              SliverAppBar(
                expandedHeight: 180,
                pinned: true,
                backgroundColor: _navy,
                foregroundColor: Colors.white,
                flexibleSpace: FlexibleSpaceBar(
                  background: Container(
                    decoration: const BoxDecoration(color: _navy),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const SizedBox(height: 40),
                        CircleAvatar(
                          radius: 36,
                          backgroundColor: _blue.withOpacity(0.2),
                          child: Text(
                            initials.toUpperCase(),
                            style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(name, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
                          decoration: BoxDecoration(
                            color: _blue.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(role, style: const TextStyle(color: Colors.white70, fontSize: 12)),
                        ),
                      ],
                    ),
                  ),
                ),
                bottom: TabBar(
                  controller: _tabs,
                  indicatorColor: _blue,
                  labelColor: Colors.white,
                  unselectedLabelColor: Colors.white60,
                  isScrollable: true,
                  tabs: const [
                    Tab(icon: Icon(Iconsax.profile_circle, size: 18), text: 'Profile'),
                    Tab(icon: Icon(Iconsax.clock, size: 18), text: 'Timesheets'),
                    Tab(icon: Icon(Iconsax.calendar, size: 18), text: 'Availability'),
                    Tab(icon: Icon(Iconsax.chart_2, size: 18), text: 'Performance'),
                    Tab(icon: Icon(Iconsax.calendar_remove, size: 18), text: 'Leave'),
                  ],
                ),
              ),
            ],
            body: TabBarView(
              controller: _tabs,
              children: [
                _ProfileTab(worker: worker, workerId: widget.workerId),
                _TimesheetsTab(workerId: widget.workerId),
                _AvailabilityTab(workerId: widget.workerId),
                _PerformanceTab(workerId: widget.workerId),
                _LeaveTab(workerId: widget.workerId),
              ],
            ),
          );
        },
      ),
    );
  }
}

// ── Profile Tab ────────────────────────────────────────────────

class _ProfileTab extends ConsumerWidget {
  final Map<String, dynamic> worker;
  final String workerId;
  const _ProfileTab({required this.worker, required this.workerId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(children: [
        _InfoCard(children: [
          _infoRow(Iconsax.sms, 'Email', worker['email'] ?? '-'),
          _infoRow(Iconsax.call, 'Phone', worker['phone']?.toString() ?? '-'),
          _infoRow(Iconsax.briefcase, 'Role', worker['role'] ?? '-'),
          _infoRow(
            Iconsax.timer_1,
            'Active Jobs',
            '${worker['active_jobs'] ?? 0} active',
          ),
        ]),
        const SizedBox(height: 12),
        _InfoCard(children: [
          Row(children: [
            const Icon(Iconsax.status, size: 18, color: _navy),
            const SizedBox(width: 10),
            const Text('Status', style: TextStyle(color: Colors.grey, fontSize: 13)),
            const Spacer(),
            Switch(
              value: worker['is_active'] == true,
              activeColor: _green,
              onChanged: (v) async {
                await ref.read(workerNotifierProvider.notifier)
                    .updateWorker(workerId, {'is_active': v});
                ref.refresh(workerDetailProvider(workerId));
              },
            ),
            Text(
              worker['is_active'] == true ? 'Active' : 'Inactive',
              style: TextStyle(
                color: worker['is_active'] == true ? _green : Colors.grey,
                fontWeight: FontWeight.w600,
              ),
            ),
          ]),
        ]),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () {},
            icon: const Icon(Iconsax.edit_2, size: 18),
            label: const Text('Edit Profile'),
            style: OutlinedButton.styleFrom(
              foregroundColor: _blue,
              side: const BorderSide(color: _blue),
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _infoRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Icon(icon, size: 18, color: _navy.withOpacity(0.6)),
        const SizedBox(width: 10),
        Text(label, style: const TextStyle(color: Colors.grey, fontSize: 13)),
        const Spacer(),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
      ]),
    );
  }
}

// ── Timesheets Tab ─────────────────────────────────────────────

class _TimesheetsTab extends ConsumerWidget {
  final String workerId;
  const _TimesheetsTab({required this.workerId});

  Color _statusColor(String status) {
    switch (status) {
      case 'approved': return _green;
      case 'rejected': return _red;
      default: return _orange;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(workerTimesheetsProvider(workerId));
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('$e')),
      data: (sheets) {
        if (sheets.isEmpty) {
          return _emptyState(Iconsax.clock, 'No timesheets yet');
        }
        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: sheets.length,
          itemBuilder: (ctx, i) {
            final s = sheets[i];
            final status = (s['status'] ?? 'pending').toString();
            return Container(
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border(left: BorderSide(color: _statusColor(status), width: 4)),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 6)],
              ),
              child: ListTile(
                title: Text(s['date']?.toString() ?? '-', style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text('${s['start_time']} - ${s['end_time']} · ${s['total_hours']?.toStringAsFixed(1) ?? '-'} hrs'),
                trailing: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: _statusColor(status).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(status, style: TextStyle(color: _statusColor(status), fontSize: 11, fontWeight: FontWeight.w600)),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

// ── Availability Tab ───────────────────────────────────────────

class _AvailabilityTab extends ConsumerWidget {
  final String workerId;
  const _AvailabilityTab({required this.workerId});

  static const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(workerAvailabilityProvider(workerId));
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('$e')),
      data: (slots) {
        final slotMap = <int, Map<String, dynamic>>{};
        for (final s in slots) {
          slotMap[(s['day_of_week'] as num?)?.toInt() ?? 0] = s;
        }
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text('Weekly Availability', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: _navy)),
            const SizedBox(height: 12),
            ...List.generate(7, (i) {
              final slot = slotMap[i];
              final isAvail = slot?['is_available'] == true;
              return Container(
                margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: isAvail ? _green.withOpacity(0.3) : Colors.grey.withOpacity(0.2)),
                ),
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: isAvail ? _green.withOpacity(0.1) : Colors.grey.withOpacity(0.1),
                    child: Text(_days[i], style: TextStyle(color: isAvail ? _green : Colors.grey, fontWeight: FontWeight.bold, fontSize: 12)),
                  ),
                  title: Text(isAvail ? 'Available' : 'Unavailable',
                      style: TextStyle(color: isAvail ? _green : Colors.grey, fontWeight: FontWeight.w600)),
                  subtitle: slot != null && isAvail
                      ? Text('${slot['start_time']} - ${slot['end_time']}')
                      : null,
                  trailing: Switch(
                    value: isAvail,
                    activeColor: _green,
                    onChanged: (_) {},
                  ),
                ),
              );
            }),
          ],
        );
      },
    );
  }
}

// ── Performance Tab ────────────────────────────────────────────

class _PerformanceTab extends ConsumerWidget {
  final String workerId;
  const _PerformanceTab({required this.workerId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(workerPerformanceProvider(workerId));
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('$e')),
      data: (perf) => SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          Row(children: [
            Expanded(child: _MetricCard(
              icon: Iconsax.briefcase,
              label: 'Total Jobs',
              value: '${perf['total_jobs'] ?? 0}',
              color: _navy,
            )),
            const SizedBox(width: 12),
            Expanded(child: _MetricCard(
              icon: Iconsax.tick_circle,
              label: 'Completed',
              value: '${perf['completed_jobs'] ?? 0}',
              color: _green,
            )),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: _MetricCard(
              icon: Iconsax.chart_2,
              label: 'Completion Rate',
              value: '${perf['completion_rate'] ?? 0}%',
              color: _blue,
            )),
            const SizedBox(width: 12),
            Expanded(child: _MetricCard(
              icon: Iconsax.timer_1,
              label: 'Avg Hours/Job',
              value: '${perf['avg_hours'] ?? 0}h',
              color: _orange,
            )),
          ]),
          const SizedBox(height: 12),
          _InfoCard(children: [
            Row(children: [
              const Icon(Iconsax.clock, size: 18, color: _green),
              const SizedBox(width: 10),
              const Text('On-time Rate', style: TextStyle(fontSize: 14)),
              const Spacer(),
              Text(
                '${perf['on_time_rate'] ?? 0}%',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: _green),
              ),
            ]),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: ((perf['on_time_rate'] as num?)?.toDouble() ?? 0) / 100,
                backgroundColor: Colors.grey[200],
                color: _green,
                minHeight: 8,
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;
  const _MetricCard({required this.icon, required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 6)],
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, color: color, size: 24),
      const SizedBox(height: 8),
      Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: color)),
      const SizedBox(height: 2),
      Text(label, style: TextStyle(fontSize: 12, color: Colors.grey[600])),
    ]),
  );
}

// ── Leave Tab ──────────────────────────────────────────────────

class _LeaveTab extends ConsumerWidget {
  final String workerId;
  const _LeaveTab({required this.workerId});

  Color _statusColor(String status) {
    switch (status) {
      case 'approved': return _green;
      case 'rejected': return _red;
      default: return _orange;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(leaveRequestsProvider(workerId));
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (requests) {
          if (requests.isEmpty) {
            return _emptyState(Iconsax.calendar_remove, 'No leave requests');
          }
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: requests.length,
            itemBuilder: (ctx, i) {
              final req = requests[i];
              final status = (req['status'] ?? 'pending').toString();
              return Container(
                margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border(left: BorderSide(color: _statusColor(status), width: 4)),
                  boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 6)],
                ),
                child: ListTile(
                  title: Text(
                    (req['leave_type'] ?? 'Leave').toString().toUpperCase(),
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                  subtitle: Text('${req['start_date']} – ${req['end_date']} · ${req['days_count']} days'),
                  trailing: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: _statusColor(status).withOpacity(0.1),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(status, style: TextStyle(color: _statusColor(status), fontSize: 11, fontWeight: FontWeight.w600)),
                  ),
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {},
        backgroundColor: _blue,
        foregroundColor: Colors.white,
        child: const Icon(Iconsax.add_circle),
      ),
    );
  }
}

// ── Shared Widgets ─────────────────────────────────────────────

class _InfoCard extends StatelessWidget {
  final List<Widget> children;
  const _InfoCard({required this.children});

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 6)],
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
  );
}

Widget _emptyState(IconData icon, String msg) => Center(
  child: Column(mainAxisSize: MainAxisSize.min, children: [
    Icon(icon, size: 60, color: Colors.grey[300]),
    const SizedBox(height: 12),
    Text(msg, style: TextStyle(color: Colors.grey[500], fontSize: 16)),
  ]),
);
