import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';

import '../../../core/providers/auth_provider.dart';
import '../../../core/utils/theme.dart';
import '../providers/reminders_provider.dart';

/// Module 13 — Task Reminders.
///
/// Workers see only their own reminders; managers + see the full list,
/// can create reminders for others, and can dispatch the run queue.
/// The backend enforces these rules; we mirror them in the UI.
class RemindersScreen extends ConsumerStatefulWidget {
  const RemindersScreen({super.key});

  @override
  ConsumerState<RemindersScreen> createState() => _RemindersScreenState();
}

class _RemindersScreenState extends ConsumerState<RemindersScreen> {
  String _filter = 'pending';
  bool? _selfOnlyOverride;

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authNotifierProvider);
    final role = (auth.asData?.value?['role']?.toString() ?? 'worker').toLowerCase();
    final canManage = const {'owner', 'admin', 'manager'}.contains(role);
    final _selfOnly = _selfOnlyOverride ?? !canManage;

    final async = _selfOnly
        ? ref.watch(myRemindersProvider)
        : ref.watch(remindersListProvider(_filter == 'all' ? '' : _filter));

    return Scaffold(
      backgroundColor: TradieColors.white,
      appBar: AppBar(
        title: const Text('Reminders'),
        backgroundColor: TradieColors.white,
        elevation: 0,
        actions: [
          if (canManage)
            IconButton(
              icon: const Icon(Iconsax.refresh, color: TradieColors.charcoal),
              tooltip: _selfOnly ? 'Show all reminders' : 'Show my reminders',
              onPressed: () => setState(() => _selfOnlyOverride = !_selfOnly),
            ),
          if (!_selfOnly)
            PopupMenuButton<String>(
              icon: const Icon(Iconsax.filter, color: TradieColors.charcoal),
              onSelected: (v) => setState(() => _filter = v),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'pending', child: Text('Pending')),
                PopupMenuItem(value: 'snoozed', child: Text('Snoozed')),
                PopupMenuItem(value: 'sent', child: Text('Sent')),
                PopupMenuItem(value: 'dismissed', child: Text('Dismissed')),
                PopupMenuItem(value: 'cancelled', child: Text('Cancelled')),
                PopupMenuItem(value: 'all', child: Text('All')),
              ],
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openCreateSheet(context),
        backgroundColor: TradieColors.electricBlue,
        foregroundColor: TradieColors.white,
        icon: const Icon(Iconsax.add),
        label: const Text('New reminder'),
      ),
      body: RefreshIndicator(
        color: TradieColors.electricBlue,
        onRefresh: () async {
          ref.invalidate(remindersListProvider);
          ref.invalidate(myRemindersProvider);
        },
        child: async.when(
          loading: () => const Center(child: CircularProgressIndicator(color: TradieColors.electricBlue)),
          error: (e, _) => _ErrorView(message: e.toString(), onRetry: () {
            ref.invalidate(remindersListProvider);
            ref.invalidate(myRemindersProvider);
          }),
          data: (list) {
            if (list.isEmpty) return const _EmptyView();
            return ListView.separated(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 96),
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: list.length,
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (_, i) {
                final r = list[i] as Map<String, dynamic>;
                return _ReminderCard(
                  reminder: r,
                  canManage: canManage,
                  onSnooze1h: () => _runMutation(
                    () => ref.read(reminderNotifierProvider.notifier).snooze(r['id'] as String, duration: '1h'),
                    success: 'Snoozed 1h',
                  ),
                  onSnoozeTomorrow: () => _runMutation(
                    () => ref.read(reminderNotifierProvider.notifier).snooze(r['id'] as String, duration: 'tomorrow'),
                    success: 'Snoozed to tomorrow',
                  ),
                  onDismiss: () => _runMutation(
                    () => ref.read(reminderNotifierProvider.notifier).dismiss(r['id'] as String),
                    success: 'Dismissed',
                  ),
                  onDelete: () => _confirmDelete(context, r['id'] as String),
                );
              },
            );
          },
        ),
      ),
    );
  }

  Future<void> _runMutation(Future<bool> Function() op, {required String success}) async {
    final ok = await op();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ok ? success : 'Action failed')));
  }

  Future<void> _confirmDelete(BuildContext context, String id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TradieColors.white,
        title: const Text('Delete reminder?'),
        content: const Text('This action cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: TradieColors.alertRed),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final ok = await ref.read(reminderNotifierProvider.notifier).delete(id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ok ? 'Deleted' : 'Delete failed')));
  }

  Future<void> _openCreateSheet(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: TradieColors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => const _CreateReminderSheet(),
    );
  }
}

// ── Card ────────────────────────────────────────────────────────

class _ReminderCard extends StatelessWidget {
  final Map<String, dynamic> reminder;
  final bool canManage;
  final VoidCallback onSnooze1h;
  final VoidCallback onSnoozeTomorrow;
  final VoidCallback onDismiss;
  final VoidCallback onDelete;

  const _ReminderCard({
    required this.reminder,
    required this.canManage,
    required this.onSnooze1h,
    required this.onSnoozeTomorrow,
    required this.onDismiss,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final status = reminder['status']?.toString() ?? 'pending';
    final entityType = reminder['entity_type']?.toString() ?? 'custom';
    final remindAt = DateTime.tryParse(reminder['remind_at']?.toString() ?? '');
    final overdue = remindAt != null && remindAt.isBefore(DateTime.now()) && status == 'pending';
    final tone = overdue ? TradieColors.alertRed : TradieColors.electricBlue;

    return Container(
      decoration: BoxDecoration(
        color: TradieColors.white,
        border: Border.all(color: TradieColors.grey200),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 36, height: 36,
                  decoration: BoxDecoration(
                    color: tone.withOpacity(0.10),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(_iconFor(entityType), size: 18, color: tone),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        reminder['title']?.toString() ?? '',
                        style: const TextStyle(
                          color: TradieColors.charcoal,
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '$entityType · ${_formatTime(remindAt)}${overdue ? ' · OVERDUE' : ''}',
                        style: TextStyle(
                          color: overdue ? TradieColors.alertRed : TradieColors.grey600,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: TradieColors.grey50,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(status,
                      style: const TextStyle(
                          color: TradieColors.grey600, fontSize: 11, fontWeight: FontWeight.w500)),
                ),
                if (canManage)
                  PopupMenuButton<String>(
                    icon: const Icon(Iconsax.more, color: TradieColors.grey400),
                    onSelected: (v) {
                      if (v == 'delete') onDelete();
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'delete', child: Text('Delete')),
                    ],
                  ),
              ],
            ),
            if ((reminder['note'] ?? '').toString().isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                reminder['note'].toString(),
                style: const TextStyle(color: TradieColors.grey600, fontSize: 13),
              ),
            ],
            if (status == 'pending' || status == 'snoozed') ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton(onPressed: onSnooze1h, child: const Text('Snooze 1h')),
                  OutlinedButton(onPressed: onSnoozeTomorrow, child: const Text('Tomorrow')),
                  OutlinedButton(onPressed: onDismiss, child: const Text('Dismiss')),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  IconData _iconFor(String entityType) => switch (entityType) {
        'job' => Iconsax.briefcase,
        'invoice' => Iconsax.receipt,
        'quote' => Iconsax.document_text,
        'safety' => Iconsax.health,
        'licence' => Iconsax.security_safe,
        'followup' => Iconsax.call,
        _ => Iconsax.notification,
      };

  String _formatTime(DateTime? dt) {
    if (dt == null) return '';
    final local = dt.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }
}

// ── Create sheet ────────────────────────────────────────────────

class _CreateReminderSheet extends ConsumerStatefulWidget {
  const _CreateReminderSheet();

  @override
  ConsumerState<_CreateReminderSheet> createState() => _CreateReminderSheetState();
}

class _CreateReminderSheetState extends ConsumerState<_CreateReminderSheet> {
  final _title = TextEditingController();
  final _note = TextEditingController();
  String _entityType = 'custom';
  String _channel = 'inapp';
  DateTime _remindAt = DateTime.now().add(const Duration(hours: 1));
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets;

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, viewInsets.bottom + 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 36, height: 4,
              decoration: BoxDecoration(color: TradieColors.grey200, borderRadius: BorderRadius.circular(2)),
            ),
          ),
          const SizedBox(height: 16),
          const Text('New reminder', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          const SizedBox(height: 16),
          TextField(
            controller: _title,
            decoration: const InputDecoration(labelText: 'Title', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _note,
            maxLines: 2,
            decoration: const InputDecoration(labelText: 'Note', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                value: _entityType,
                decoration: const InputDecoration(labelText: 'For', border: OutlineInputBorder()),
                items: const [
                  DropdownMenuItem(value: 'custom', child: Text('Custom')),
                  DropdownMenuItem(value: 'job', child: Text('Job')),
                  DropdownMenuItem(value: 'invoice', child: Text('Invoice')),
                  DropdownMenuItem(value: 'quote', child: Text('Quote')),
                  DropdownMenuItem(value: 'safety', child: Text('Safety')),
                  DropdownMenuItem(value: 'licence', child: Text('Licence')),
                  DropdownMenuItem(value: 'followup', child: Text('Follow-up')),
                ],
                onChanged: (v) => setState(() => _entityType = v ?? 'custom'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButtonFormField<String>(
                value: _channel,
                decoration: const InputDecoration(labelText: 'Channel', border: OutlineInputBorder()),
                items: const [
                  DropdownMenuItem(value: 'inapp', child: Text('In-app')),
                  DropdownMenuItem(value: 'email', child: Text('Email')),
                  DropdownMenuItem(value: 'sms', child: Text('SMS')),
                  DropdownMenuItem(value: 'push', child: Text('Push')),
                ],
                onChanged: (v) => setState(() => _channel = v ?? 'inapp'),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _pickDateTime,
            icon: const Icon(Iconsax.calendar_1, size: 16),
            label: Text('Remind at: ${_formatLocal(_remindAt)}'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: TradieColors.alertRed)),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _submit,
            style: FilledButton.styleFrom(
              backgroundColor: TradieColors.electricBlue,
              minimumSize: const Size.fromHeight(48),
            ),
            child: _busy
                ? const SizedBox(
                    width: 20, height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('Create'),
          ),
        ],
      ),
    );
  }

  Future<void> _pickDateTime() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _remindAt,
      firstDate: DateTime.now().subtract(const Duration(minutes: 1)),
      lastDate: DateTime.now().add(const Duration(days: 365 * 2)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_remindAt),
    );
    if (time == null) return;
    setState(() {
      _remindAt = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    });
  }

  Future<void> _submit() async {
    if (_title.text.trim().isEmpty) {
      setState(() => _error = 'Title is required');
      return;
    }
    if (_remindAt.isBefore(DateTime.now().subtract(const Duration(minutes: 1)))) {
      setState(() => _error = 'Time must be in the future');
      return;
    }
    setState(() { _busy = true; _error = null; });
    final err = await ref.read(reminderNotifierProvider.notifier).create({
      'title': _title.text.trim(),
      'note': _note.text.trim(),
      'entity_type': _entityType,
      'channel': _channel,
      'remind_at': _remindAt.toUtc().toIso8601String(),
    });
    if (!mounted) return;
    if (err != null) {
      setState(() { _busy = false; _error = err; });
      return;
    }
    Navigator.of(context).pop();
  }

  String _formatLocal(DateTime dt) {
    final l = dt.toLocal();
    return '${l.year}-${l.month.toString().padLeft(2, '0')}-${l.day.toString().padLeft(2, '0')} '
        '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
  }
}

// ── Empty / Error views ─────────────────────────────────────────

class _EmptyView extends StatelessWidget {
  const _EmptyView();

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: const [
        SizedBox(height: 120),
        Icon(Iconsax.notification, size: 56, color: TradieColors.grey400),
        SizedBox(height: 16),
        Center(
          child: Text(
            'No reminders',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: TradieColors.charcoal),
          ),
        ),
        SizedBox(height: 6),
        Center(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              'Create one to never miss a job follow-up, invoice nudge or licence renewal.',
              textAlign: TextAlign.center,
              style: TextStyle(color: TradieColors.grey600),
            ),
          ),
        ),
      ],
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 120),
        const Icon(Iconsax.warning_2, size: 56, color: TradieColors.alertRed),
        const SizedBox(height: 16),
        const Center(
          child: Text(
            'Could not load reminders',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(height: 6),
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(message, textAlign: TextAlign.center, style: const TextStyle(color: TradieColors.grey600)),
          ),
        ),
        const SizedBox(height: 16),
        Center(child: OutlinedButton(onPressed: onRetry, child: const Text('Retry'))),
      ],
    );
  }
}
