import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/theme.dart';
import '../../jobs/screens/job_create_screen.dart';
import '../../jobs/screens/job_detail_screen.dart';
import '../providers/calendar_provider.dart';

// ─── Entry point ──────────────────────────────────────────────────────────────

class CalendarScreen extends ConsumerStatefulWidget {
  const CalendarScreen({super.key});

  @override
  ConsumerState<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends ConsumerState<CalendarScreen> {
  // 0 = Month, 1 = Week
  int _viewMode = 1;
  DateTime _selectedDay = DateTime.now();
  DateTime _focusedMonth = DateTime.now();

  // Week view: which week are we showing (Monday of that week).
  late DateTime _weekStart;

  @override
  void initState() {
    super.initState();
    _weekStart = _mondayOf(DateTime.now());
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadCurrent());
  }

  DateTime _mondayOf(DateTime d) {
    return d.subtract(Duration(days: d.weekday - 1));
  }

  void _loadCurrent() {
    final notifier = ref.read(calendarProvider.notifier);
    DateTime start, end;
    if (_viewMode == 0) {
      start = DateTime(_focusedMonth.year, _focusedMonth.month, 1);
      end = DateTime(_focusedMonth.year, _focusedMonth.month + 1, 0);
    } else {
      start = _weekStart;
      end = _weekStart.add(const Duration(days: 6));
    }
    notifier.loadRange(start, end);
  }

  String _dayKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final calState = ref.watch(calendarProvider);

    return Scaffold(
      backgroundColor: TradieColors.grey50,
      appBar: _buildAppBar(calState),
      body: Column(
        children: [
          // View mode toggle
          _buildViewToggle(),
          // Conflict warning badge
          if (calState.hasConflicts) _buildConflictBanner(calState.conflicts),
          // Calendar content
          Expanded(
            child: calState.jobsByDate.when(
              data: (byDate) => _viewMode == 0
                  ? _MonthView(
                      focusedMonth: _focusedMonth,
                      selectedDay: _selectedDay,
                      byDate: byDate,
                      onDayTap: (d) => setState(() => _selectedDay = d),
                    )
                  : _WeekView(
                      weekStart: _weekStart,
                      selectedDay: _selectedDay,
                      byDate: byDate,
                      onJobTap: (id) => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => JobDetailScreen(id: id),
                        ),
                      ),
                    ),
              loading: () => const Center(
                child: CircularProgressIndicator(
                  color: TradieColors.electricBlue,
                ),
              ),
              error: (e, _) => _buildErrorState(e),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const JobCreateScreen()),
          );
          _loadCurrent();
        },
        backgroundColor: TradieColors.electricBlue,
        icon: const Icon(Icons.add, color: TradieColors.white),
        label: const Text(
          'Schedule Job',
          style: TextStyle(
            color: TradieColors.white,
            fontFamily: 'Inter',
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  // ── AppBar ─────────────────────────────────────────────────────────────────

  AppBar _buildAppBar(CalendarState calState) {
    final label = _viewMode == 0
        ? _monthLabel(_focusedMonth)
        : _weekRangeLabel(_weekStart);

    return AppBar(
      backgroundColor: TradieColors.white,
      elevation: 0,
      titleSpacing: 16,
      title: Row(
        children: [
          // Prev
          _NavArrow(
            icon: Icons.chevron_left_rounded,
            onTap: _stepBack,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                fontFamily: 'Inter',
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: TradieColors.navy,
              ),
            ),
          ),
          // Today
          TextButton(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              backgroundColor: TradieColors.electricBlue.withOpacity(0.08),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            onPressed: _goToday,
            child: const Text(
              'Today',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: TradieColors.electricBlue,
              ),
            ),
          ),
          const SizedBox(width: 4),
          // Next
          _NavArrow(
            icon: Icons.chevron_right_rounded,
            onTap: _stepForward,
          ),
          // Conflict badge
          if (calState.hasConflicts)
            Container(
              margin: const EdgeInsets.only(left: 8),
              padding: const EdgeInsets.all(4),
              decoration: const BoxDecoration(
                color: TradieColors.alertRed,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.warning_amber_rounded,
                color: TradieColors.white,
                size: 14,
              ),
            ),
        ],
      ),
    );
  }

  void _stepBack() {
    setState(() {
      if (_viewMode == 0) {
        _focusedMonth =
            DateTime(_focusedMonth.year, _focusedMonth.month - 1, 1);
      } else {
        _weekStart = _weekStart.subtract(const Duration(days: 7));
      }
    });
    _loadCurrent();
  }

  void _stepForward() {
    setState(() {
      if (_viewMode == 0) {
        _focusedMonth =
            DateTime(_focusedMonth.year, _focusedMonth.month + 1, 1);
      } else {
        _weekStart = _weekStart.add(const Duration(days: 7));
      }
    });
    _loadCurrent();
  }

  void _goToday() {
    setState(() {
      final now = DateTime.now();
      _selectedDay = now;
      _focusedMonth = DateTime(now.year, now.month, 1);
      _weekStart = _mondayOf(now);
    });
    _loadCurrent();
  }

  String _monthLabel(DateTime d) {
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December'
    ];
    return '${months[d.month - 1]} ${d.year}';
  }

  String _weekRangeLabel(DateTime monday) {
    final sunday = monday.add(const Duration(days: 6));
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    if (monday.month == sunday.month) {
      return '${months[monday.month - 1]} ${monday.day}–${sunday.day}, ${monday.year}';
    }
    return '${months[monday.month - 1]} ${monday.day} – ${months[sunday.month - 1]} ${sunday.day}, ${monday.year}';
  }

  // ── View toggle ────────────────────────────────────────────────────────────

  Widget _buildViewToggle() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      decoration: BoxDecoration(
        color: TradieColors.grey100,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          _ToggleTab(
            label: 'Month',
            active: _viewMode == 0,
            onTap: () {
              if (_viewMode != 0) setState(() => _viewMode = 0);
              _loadCurrent();
            },
          ),
          _ToggleTab(
            label: 'Week',
            active: _viewMode == 1,
            onTap: () {
              if (_viewMode != 1) setState(() => _viewMode = 1);
              _loadCurrent();
            },
          ),
        ],
      ),
    );
  }

  // ── Conflict banner ────────────────────────────────────────────────────────

  Widget _buildConflictBanner(List<Map<String, dynamic>> conflicts) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: TradieColors.alertRed.withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: TradieColors.alertRed.withOpacity(0.3),
        ),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            color: TradieColors.alertRed,
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${conflicts.length} scheduling conflict${conflicts.length > 1 ? 's' : ''} detected',
              style: const TextStyle(
                fontFamily: 'Inter',
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: TradieColors.alertRed,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Error state ────────────────────────────────────────────────────────────

  Widget _buildErrorState(Object e) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off_rounded,
              color: TradieColors.grey400, size: 48),
          const SizedBox(height: 12),
          const Text(
            'Could not load schedule',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: TradieColors.charcoal,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            e.toString(),
            style: const TextStyle(
              fontFamily: 'Inter',
              fontSize: 13,
              color: TradieColors.grey400,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          TextButton(
            onPressed: _loadCurrent,
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}

// ─── Small shared widgets ─────────────────────────────────────────────────────

class _NavArrow extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _NavArrow({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: TradieColors.grey100,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, color: TradieColors.charcoal, size: 20),
      ),
    );
  }
}

class _ToggleTab extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _ToggleTab(
      {required this.label, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          margin: const EdgeInsets.all(3),
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: active ? TradieColors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            boxShadow: active
                ? [
                    BoxShadow(
                      color: TradieColors.navy.withOpacity(0.08),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    )
                  ]
                : null,
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: active ? TradieColors.navy : TradieColors.grey400,
            ),
          ),
        ),
      ),
    );
  }
}

Color _statusColor(String? status) {
  switch (status) {
    case 'scheduled':
      return TradieColors.statusScheduled;
    case 'in_progress':
      return TradieColors.statusInProgress;
    case 'completed':
      return TradieColors.statusCompleted;
    case 'cancelled':
      return TradieColors.statusCancelled;
    case 'on_hold':
      return TradieColors.statusOnHold;
    default:
      return TradieColors.statusDraft;
  }
}

String _fmtTime(String? iso) {
  if (iso == null || iso.length < 16) return '';
  try {
    final dt = DateTime.parse(iso).toLocal();
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  } catch (_) {
    return '';
  }
}

// ─── Month View ───────────────────────────────────────────────────────────────

class _MonthView extends StatelessWidget {
  final DateTime focusedMonth;
  final DateTime selectedDay;
  final Map<String, List<Map<String, dynamic>>> byDate;
  final ValueChanged<DateTime> onDayTap;

  const _MonthView({
    required this.focusedMonth,
    required this.selectedDay,
    required this.byDate,
    required this.onDayTap,
  });

  String _dayKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final firstOfMonth = DateTime(focusedMonth.year, focusedMonth.month, 1);
    // Pad to Monday
    final gridStart =
        firstOfMonth.subtract(Duration(days: firstOfMonth.weekday - 1));
    final selectedKey = _dayKey(selectedDay);
    final jobs = byDate[selectedKey] ?? [];

    return Column(
      children: [
        // Day-of-week header
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(
            children: const ['M', 'T', 'W', 'T', 'F', 'S', 'S']
                .map((d) => Expanded(
                      child: Center(
                        child: Text(
                          d,
                          style: const TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: TradieColors.grey400,
                          ),
                        ),
                      ),
                    ))
                .toList(),
          ),
        ),
        const SizedBox(height: 4),
        // Grid
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
              mainAxisSpacing: 4,
              crossAxisSpacing: 4,
              childAspectRatio: 0.9,
            ),
            itemCount: 42,
            itemBuilder: (_, i) {
              final day = gridStart.add(Duration(days: i));
              final isCurrentMonth = day.month == focusedMonth.month;
              final key = _dayKey(day);
              final dayJobs = byDate[key] ?? [];
              final isSelected = key == selectedKey;
              final isToday = key ==
                  _dayKey(DateTime.now());

              return GestureDetector(
                onTap: () => onDayTap(day),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? TradieColors.electricBlue
                        : isToday
                            ? TradieColors.electricBlue.withOpacity(0.08)
                            : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                    border: isToday && !isSelected
                        ? Border.all(
                            color:
                                TradieColors.electricBlue.withOpacity(0.4),
                            width: 1.5,
                          )
                        : null,
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        '${day.day}',
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: isSelected
                              ? TradieColors.white
                              : isCurrentMonth
                                  ? TradieColors.navy
                                  : TradieColors.grey200,
                        ),
                      ),
                      if (dayJobs.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: dayJobs
                              .take(3)
                              .map((j) => Container(
                                    width: 5,
                                    height: 5,
                                    margin: const EdgeInsets.symmetric(
                                        horizontal: 1),
                                    decoration: BoxDecoration(
                                      color: isSelected
                                          ? TradieColors.white.withOpacity(0.8)
                                          : _statusColor(
                                              j['status'] as String?),
                                      shape: BoxShape.circle,
                                    ),
                                  ))
                              .toList(),
                        ),
                      ],
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        const Divider(height: 16, color: TradieColors.grey100),
        // Job list for selected day
        Expanded(
          child: jobs.isEmpty
              ? _EmptyState(
                  message: 'No jobs on ${selectedDay.day}/${selectedDay.month}')
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
                  itemCount: jobs.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (_, i) => _JobListItem(job: jobs[i]),
                ),
        ),
      ],
    );
  }
}

// ─── Week View ────────────────────────────────────────────────────────────────

class _WeekView extends StatelessWidget {
  final DateTime weekStart;
  final DateTime selectedDay;
  final Map<String, List<Map<String, dynamic>>> byDate;
  final ValueChanged<String> onJobTap;

  const _WeekView({
    required this.weekStart,
    required this.selectedDay,
    required this.byDate,
    required this.onJobTap,
  });

  static const _startHour = 7;
  static const _endHour = 19;
  static const _hourHeight = 64.0;
  static const _timeColWidth = 48.0;

  String _dayKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final days = List.generate(7, (i) => weekStart.add(Duration(days: i)));
    const dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final todayKey = _dayKey(DateTime.now());

    return Column(
      children: [
        // ── Day header row ──────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 4, 0, 0),
          child: Row(
            children: [
              SizedBox(width: _timeColWidth),
              ...List.generate(7, (i) {
                final d = days[i];
                final key = _dayKey(d);
                final isToday = key == todayKey;
                return Expanded(
                  child: Column(
                    children: [
                      Text(
                        dayNames[i],
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: isToday
                              ? TradieColors.electricBlue
                              : TradieColors.grey400,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Container(
                        width: 28,
                        height: 28,
                        decoration: isToday
                            ? const BoxDecoration(
                                color: TradieColors.electricBlue,
                                shape: BoxShape.circle,
                              )
                            : null,
                        child: Center(
                          child: Text(
                            '${d.day}',
                            style: TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: isToday
                                  ? TradieColors.white
                                  : TradieColors.navy,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ],
          ),
        ),
        const SizedBox(height: 4),
        const Divider(height: 1, color: TradieColors.grey200),
        // ── Time grid ───────────────────────────────────────────────
        Expanded(
          child: SingleChildScrollView(
            child: SizedBox(
              height: (_endHour - _startHour) * _hourHeight,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Time labels column
                  SizedBox(
                    width: _timeColWidth,
                    child: Stack(
                      children: List.generate(_endHour - _startHour, (i) {
                        final hour = _startHour + i;
                        return Positioned(
                          top: i * _hourHeight - 7,
                          left: 0,
                          right: 0,
                          child: Text(
                            '${hour.toString().padLeft(2, '0')}:00',
                            style: const TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 10,
                              color: TradieColors.grey400,
                            ),
                            textAlign: TextAlign.right,
                          ),
                        );
                      }),
                    ),
                  ),
                  // Day columns
                  ...List.generate(7, (di) {
                    final d = days[di];
                    final key = _dayKey(d);
                    final isToday = key == todayKey;
                    final dayJobs = byDate[key] ?? [];

                    return Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: isToday
                              ? TradieColors.electricBlue.withOpacity(0.02)
                              : null,
                          border: const Border(
                            left: BorderSide(
                                color: TradieColors.grey100, width: 1),
                          ),
                        ),
                        child: Stack(
                          children: [
                            // Hour grid lines
                            ...List.generate(_endHour - _startHour, (i) {
                              return Positioned(
                                top: i * _hourHeight,
                                left: 0,
                                right: 0,
                                child: const Divider(
                                  height: 1,
                                  color: TradieColors.grey100,
                                ),
                              );
                            }),
                            // Job blocks
                            ...dayJobs.map((job) {
                              return _buildJobBlock(job, onJobTap);
                            }),
                          ],
                        ),
                      ),
                    );
                  }),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildJobBlock(
      Map<String, dynamic> job, ValueChanged<String> onTap) {
    final startStr = job['scheduled_start'] as String?;
    final endStr = job['scheduled_end'] as String?;
    if (startStr == null || endStr == null) return const SizedBox.shrink();

    DateTime start, end;
    try {
      start = DateTime.parse(startStr).toLocal();
      end = DateTime.parse(endStr).toLocal();
    } catch (_) {
      return const SizedBox.shrink();
    }

    final startMinutes = (start.hour - _startHour) * 60 + start.minute;
    final durationMinutes = end.difference(start).inMinutes;

    // Clamp to visible grid.
    final visibleStart = startMinutes.clamp(0, (_endHour - _startHour) * 60);
    final visibleDuration = durationMinutes
        .clamp(15, (_endHour - _startHour) * 60 - visibleStart);

    final top = visibleStart / 60.0 * _hourHeight;
    final height = (visibleDuration / 60.0 * _hourHeight).clamp(24.0, 500.0);

    final color = _statusColor(job['status'] as String?);
    final id = job['id'] as String? ?? '';
    final title = job['title'] as String? ?? 'Job';

    return Positioned(
      top: top,
      left: 2,
      right: 2,
      height: height,
      child: GestureDetector(
        onTap: () => onTap(id),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            color: color.withOpacity(0.15),
            borderRadius: BorderRadius.circular(6),
            border: Border(left: BorderSide(color: color, width: 3)),
          ),
          padding: const EdgeInsets.fromLTRB(5, 3, 3, 3),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
              if (height > 36)
                Text(
                  '${_fmtTime(startStr)} – ${_fmtTime(endStr)}',
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 9,
                    color: TradieColors.grey600,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Job list item (used in Month day-expand) ─────────────────────────────────

class _JobListItem extends StatelessWidget {
  final Map<String, dynamic> job;
  const _JobListItem({required this.job});

  @override
  Widget build(BuildContext context) {
    final status = job['status'] as String? ?? 'draft';
    final color = _statusColor(status);
    final title = job['title'] as String? ?? 'Untitled';
    final customer = job['customer'] as String? ?? job['customer_name'] as String? ?? '';
    final start = job['scheduled_start'] as String?;
    final end = job['scheduled_end'] as String?;
    final workerName = job['worker_name'] as String? ?? job['assigned_worker'] as String? ?? '';

    return Container(
      decoration: BoxDecoration(
        color: TradieColors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: TradieColors.grey200),
      ),
      child: Row(
        children: [
          // Status strip
          Container(
            width: 4,
            height: 72,
            decoration: BoxDecoration(
              color: color,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(12),
                bottomLeft: Radius.circular(12),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: TradieColors.navy,
                    ),
                  ),
                  if (customer.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      customer,
                      style: const TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 12,
                        color: TradieColors.grey600,
                      ),
                    ),
                  ],
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      if (start != null) ...[
                        Icon(Icons.access_time_rounded,
                            size: 12, color: TradieColors.grey400),
                        const SizedBox(width: 3),
                        Text(
                          '${_fmtTime(start)}${end != null ? ' – ${_fmtTime(end)}' : ''}',
                          style: const TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 11,
                            color: TradieColors.grey400,
                          ),
                        ),
                        const SizedBox(width: 10),
                      ],
                      if (workerName.isNotEmpty) ...[
                        Icon(Icons.person_outline_rounded,
                            size: 12, color: TradieColors.grey400),
                        const SizedBox(width: 3),
                        Text(
                          workerName,
                          style: const TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 11,
                            color: TradieColors.grey400,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
          // Status chip
          Container(
            margin: const EdgeInsets.only(right: 12),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: color.withOpacity(0.12),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              status.replaceAll('_', ' '),
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Empty state ──────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final String message;
  const _EmptyState({required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: TradieColors.electricBlue.withOpacity(0.06),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.calendar_today_outlined,
              color: TradieColors.electricBlue,
              size: 32,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            message,
            style: const TextStyle(
              fontFamily: 'Inter',
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: TradieColors.charcoal,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Tap + to schedule a job',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 13,
              color: TradieColors.grey400,
            ),
          ),
        ],
      ),
    );
  }
}
