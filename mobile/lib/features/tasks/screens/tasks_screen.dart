import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';

import '../../../core/utils/theme.dart';
import '../../dashboard/providers/dashboard_provider.dart';

class TasksScreen extends ConsumerStatefulWidget {
  const TasksScreen({super.key});
  @override
  ConsumerState<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends ConsumerState<TasksScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabs;
  static const _statuses = ['pending', 'in_progress', 'completed'];
  static const _statusLabels = ['Pending', 'In Progress', 'Done'];

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
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
        title: Row(children: [
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              color: const Color(0xFF8B5CF6).withOpacity(0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Iconsax.task_square, color: Color(0xFF8B5CF6), size: 20),
          ),
          const SizedBox(width: 10),
          const Text('Task Reminders'),
        ]),
        bottom: TabBar(
          controller: _tabs,
          labelStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w400, fontSize: 13),
          labelColor: TradieColors.electricBlue,
          unselectedLabelColor: TradieColors.grey600,
          indicatorColor: TradieColors.electricBlue,
          indicatorWeight: 2,
          tabs: _statusLabels.map((l) => Tab(text: l)).toList(),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showCreateSheet(context),
        icon: const Icon(Iconsax.add),
        label: const Text('Add Task'),
        backgroundColor: const Color(0xFF8B5CF6),
        foregroundColor: TradieColors.white,
      ),
      body: TabBarView(
        controller: _tabs,
        children: _statuses.map((s) => _TaskList(status: s)).toList(),
      ),
    );
  }

  Future<void> _showCreateSheet(BuildContext context) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _CreateTaskSheet(),
    );
  }
}

// ── Task list ─────────────────────────────────────────────────────

class _TaskList extends ConsumerWidget {
  final String status;
  const _TaskList({required this.status});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(tasksProvider(status));
    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(tasksProvider(status)),
      child: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (tasks) {
          if (tasks.isEmpty) {
            return Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Iconsax.task_square, size: 52, color: TradieColors.grey400),
                const SizedBox(height: 12),
                Text('No $status tasks',
                  style: const TextStyle(color: TradieColors.grey600, fontWeight: FontWeight.w600)),
              ]),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
            itemCount: tasks.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (_, i) => _TaskCard(
              task: tasks[i] as Map<String, dynamic>,
              status: status,
            ),
          );
        },
      ),
    );
  }
}

// ── Task card ─────────────────────────────────────────────────────

class _TaskCard extends ConsumerWidget {
  final Map<String, dynamic> task;
  final String status;
  const _TaskCard({required this.task, required this.status});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final priority = task['priority']?.toString() ?? 'medium';
    final overdue  = task['overdue'] == true;
    final assignedName = task['assigned_name']?.toString();
    final due = task['due_date'];

    return Container(
      decoration: BoxDecoration(
        color: TradieColors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: overdue ? TradieColors.alertRed.withOpacity(0.3) : TradieColors.grey200,
        ),
      ),
      child: IntrinsicHeight(
        child: Row(children: [
          // Priority bar
          Container(
            width: 4,
            decoration: BoxDecoration(
              color: _priorityColor(priority),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(12), bottomLeft: Radius.circular(12),
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  _PriorityBadge(priority: priority),
                  const SizedBox(width: 8),
                  if (overdue)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: TradieColors.alertRed.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text('OVERDUE',
                        style: TextStyle(fontSize: 9, fontWeight: FontWeight.w800, color: TradieColors.alertRed)),
                    ),
                  const Spacer(),
                  if (status == 'pending')
                    _ActionMenu(task: task),
                ]),
                const SizedBox(height: 6),
                Text(task['title']?.toString() ?? '',
                  style: TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 14,
                    color: TradieColors.navy,
                    decoration: status == 'completed' ? TextDecoration.lineThrough : null,
                  )),
                if (task['description'] != null && task['description'].toString().isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(task['description'].toString(),
                    maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: TradieColors.grey600)),
                ],
                const SizedBox(height: 8),
                Row(children: [
                  if (due != null) ...[
                    Icon(Iconsax.calendar, size: 12, color: overdue ? TradieColors.alertRed : TradieColors.grey400),
                    const SizedBox(width: 4),
                    Text(_formatDate(due.toString()),
                      style: TextStyle(fontSize: 11, color: overdue ? TradieColors.alertRed : TradieColors.grey400)),
                    const SizedBox(width: 12),
                  ],
                  if (assignedName != null) ...[
                    Icon(Iconsax.user, size: 12, color: TradieColors.grey400),
                    const SizedBox(width: 4),
                    Text(assignedName, style: const TextStyle(fontSize: 11, color: TradieColors.grey400)),
                  ],
                ]),
              ]),
            ),
          ),
        ]),
      ),
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

  String _formatDate(String iso) {
    try {
      final dt = DateTime.parse(iso).toLocal();
      const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
      return '${dt.day} ${months[dt.month - 1]}';
    } catch (_) { return iso; }
  }
}

// ── Priority badge ────────────────────────────────────────────────

class _PriorityBadge extends StatelessWidget {
  final String priority;
  const _PriorityBadge({required this.priority});

  @override
  Widget build(BuildContext context) {
    final color = _color(priority);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(6)),
      child: Text(priority.toUpperCase(),
        style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: color)),
    );
  }

  Color _color(String p) {
    switch (p) {
      case 'urgent': return TradieColors.alertRed;
      case 'high':   return TradieColors.safetyOrange;
      case 'medium': return TradieColors.warningAmber;
      default:       return TradieColors.grey400;
    }
  }
}

// ── Action menu ───────────────────────────────────────────────────

class _ActionMenu extends ConsumerWidget {
  final Map<String, dynamic> task;
  const _ActionMenu({required this.task});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<String>(
      onSelected: (v) async {
        if (v == 'complete') {
          await ref.read(taskNotifierProvider.notifier).complete(task['id'].toString());
        } else if (v == 'delete') {
          await ref.read(taskNotifierProvider.notifier).delete(task['id'].toString());
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'complete', child: Row(children: [
          Icon(Iconsax.tick_circle, size: 16, color: TradieColors.successGreen),
          SizedBox(width: 8), Text('Mark Complete'),
        ])),
        const PopupMenuItem(value: 'delete', child: Row(children: [
          Icon(Iconsax.trash, size: 16, color: TradieColors.alertRed),
          SizedBox(width: 8), Text('Delete', style: TextStyle(color: TradieColors.alertRed)),
        ])),
      ],
      child: const Icon(Iconsax.more, size: 18, color: TradieColors.grey400),
    );
  }
}

// ── Create task sheet ─────────────────────────────────────────────

class _CreateTaskSheet extends ConsumerStatefulWidget {
  const _CreateTaskSheet();
  @override
  ConsumerState<_CreateTaskSheet> createState() => _CreateTaskSheetState();
}

class _CreateTaskSheetState extends ConsumerState<_CreateTaskSheet> {
  final _titleCtrl = TextEditingController();
  final _descCtrl  = TextEditingController();
  String _priority = 'medium';
  DateTime? _dueDate;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _titleCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_titleCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Title is required');
      return;
    }
    setState(() { _saving = true; _error = null; });
    final err = await ref.read(taskNotifierProvider.notifier).create({
      'title':       _titleCtrl.text.trim(),
      'description': _descCtrl.text.trim(),
      'priority':    _priority,
      if (_dueDate != null) 'due_date': _dueDate!.toUtc().toIso8601String(),
    });
    setState(() { _saving = false; _error = err; });
    if (err == null && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(context).viewInsets.bottom + 24),
      decoration: const BoxDecoration(
        color: TradieColors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Handle
        Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: TradieColors.grey200, borderRadius: BorderRadius.circular(2)))),
        const SizedBox(height: 16),
        const Text('New Task', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: TradieColors.navy)),
        const SizedBox(height: 16),

        // Title
        TextField(
          controller: _titleCtrl,
          autofocus: true,
          decoration: InputDecoration(
            labelText: 'Task title',
            prefixIcon: const Icon(Iconsax.task_square, size: 18),
            filled: true, fillColor: TradieColors.grey50,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: TradieColors.grey200)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: TradieColors.grey200)),
          ),
        ),
        const SizedBox(height: 12),

        // Description
        TextField(
          controller: _descCtrl,
          maxLines: 2,
          decoration: InputDecoration(
            labelText: 'Description (optional)',
            filled: true, fillColor: TradieColors.grey50,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: TradieColors.grey200)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: TradieColors.grey200)),
          ),
        ),
        const SizedBox(height: 12),

        // Priority + Due date row
        Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Priority', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: TradieColors.grey600)),
            const SizedBox(height: 6),
            Wrap(spacing: 6, children: [
              for (final p in ['low', 'medium', 'high', 'urgent'])
                GestureDetector(
                  onTap: () => setState(() => _priority = p),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: _priority == p ? _priorityColor(p) : _priorityColor(p).withOpacity(0.08),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: _priorityColor(p).withOpacity(0.3)),
                    ),
                    child: Text(p[0].toUpperCase() + p.substring(1),
                      style: TextStyle(
                        fontSize: 11, fontWeight: FontWeight.w600,
                        color: _priority == p ? TradieColors.white : _priorityColor(p),
                      )),
                  ),
                ),
            ]),
          ])),
        ]),
        const SizedBox(height: 12),

        // Due date
        InkWell(
          onTap: () async {
            final picked = await showDatePicker(
              context: context,
              initialDate: DateTime.now(),
              firstDate: DateTime.now(),
              lastDate: DateTime.now().add(const Duration(days: 365)),
            );
            if (picked != null) setState(() => _dueDate = picked);
          },
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            decoration: BoxDecoration(
              color: TradieColors.grey50,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: TradieColors.grey200),
            ),
            child: Row(children: [
              const Icon(Iconsax.calendar, size: 18, color: TradieColors.grey600),
              const SizedBox(width: 10),
              Text(
                _dueDate != null ? _formatDate(_dueDate!) : 'Set due date (optional)',
                style: TextStyle(
                  color: _dueDate != null ? TradieColors.navy : TradieColors.grey400,
                  fontSize: 14,
                ),
              ),
              if (_dueDate != null) ...[
                const Spacer(),
                GestureDetector(
                  onTap: () => setState(() => _dueDate = null),
                  child: const Icon(Iconsax.close_circle, size: 16, color: TradieColors.grey400),
                ),
              ],
            ]),
          ),
        ),

        if (_error != null) ...[
          const SizedBox(height: 10),
          Text(_error!, style: const TextStyle(color: TradieColors.alertRed, fontSize: 13)),
        ],
        const SizedBox(height: 20),

        SizedBox(
          width: double.infinity,
          height: 48,
          child: FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: TradieColors.white))
                : const Icon(Iconsax.add_circle, size: 18),
            label: Text(_saving ? 'Creating…' : 'Create Task'),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF8B5CF6),
              foregroundColor: TradieColors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
      ]),
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

  String _formatDate(DateTime dt) {
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${dt.day} ${months[dt.month - 1]} ${dt.year}';
  }
}
