import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';

import '../../../core/providers/auth_provider.dart';
import '../../../core/utils/theme.dart';
import '../providers/leave_management_provider.dart';

class LeaveManagementScreen extends ConsumerStatefulWidget {
  const LeaveManagementScreen({super.key});

  @override
  ConsumerState<LeaveManagementScreen> createState() =>
      _LeaveManagementScreenState();
}

class _LeaveManagementScreenState extends ConsumerState<LeaveManagementScreen> {
  String _status = '';
  bool? _selfOnlyOverride;

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authNotifierProvider);
    final role =
        (auth.asData?.value?['role']?.toString() ?? 'worker').toLowerCase();
    final canApprove = const {'owner', 'admin', 'manager'}.contains(role);
    final selfOnly = _selfOnlyOverride ?? !canApprove;
    final async = selfOnly
        ? ref.watch(myLeaveManagementProvider)
        : ref.watch(leaveRequestsProvider(LeaveFilter(status: _status)));

    return Scaffold(
      backgroundColor: TradieColors.white,
      appBar: AppBar(
        title: const Text('Leave'),
        backgroundColor: TradieColors.white,
        elevation: 0,
        actions: [
          if (canApprove)
            IconButton(
              icon: Icon(selfOnly ? Iconsax.people : Iconsax.user),
              tooltip: selfOnly ? 'Show team leave' : 'Show my leave',
              onPressed: () => setState(() => _selfOnlyOverride = !selfOnly),
            ),
          if (!selfOnly)
            PopupMenuButton<String>(
              icon: const Icon(Iconsax.filter, color: TradieColors.charcoal),
              onSelected: (value) => setState(() => _status = value),
              itemBuilder: (_) => const [
                PopupMenuItem(value: '', child: Text('All')),
                PopupMenuItem(value: 'pending', child: Text('Pending')),
                PopupMenuItem(value: 'approved', child: Text('Approved')),
                PopupMenuItem(value: 'rejected', child: Text('Rejected')),
                PopupMenuItem(value: 'cancelled', child: Text('Cancelled')),
              ],
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEditor(),
        backgroundColor: TradieColors.electricBlue,
        foregroundColor: TradieColors.white,
        icon: const Icon(Iconsax.add),
        label: const Text('Request leave'),
      ),
      body: RefreshIndicator(
        color: TradieColors.electricBlue,
        onRefresh: () async {
          ref.invalidate(myLeaveManagementProvider);
          ref.invalidate(leaveRequestsProvider);
        },
        child: async.when(
          loading: () => const Center(
            child: CircularProgressIndicator(color: TradieColors.electricBlue),
          ),
          error: (error, _) => _MessageView(
            icon: Iconsax.warning_2,
            title: 'Could not load leave',
            subtitle: error.toString(),
            color: TradieColors.alertRed,
          ),
          data: (payload) {
            final requests = _requestsFromPayload(payload);
            if (requests.isEmpty) {
              return const _MessageView(
                icon: Iconsax.calendar_remove,
                title: 'No leave requests',
                subtitle: 'Approved leave will block worker availability.',
              );
            }
            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 96),
              children: [
                if (payload is Map<String, dynamic>) _Summary(payload: payload),
                for (final request in requests) ...[
                  _LeaveTile(
                    request: request,
                    canApprove: canApprove,
                    onApprove: () => _mutate(
                      () => ref
                          .read(leaveManagementNotifierProvider.notifier)
                          .approve(request.id),
                      'Leave approved',
                    ),
                    onReject: () => _reject(request),
                    onEdit: request.status == 'pending'
                        ? () => _openEditor(request)
                        : null,
                    onCancel: request.status == 'pending' ||
                            (canApprove && request.status != 'cancelled')
                        ? () => _mutate(
                              () => ref
                                  .read(
                                      leaveManagementNotifierProvider.notifier)
                                  .cancel(request.id),
                              'Leave cancelled',
                            )
                        : null,
                    onDelete: canApprove ? () => _confirmDelete(request) : null,
                  ),
                  const SizedBox(height: 12),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  List<LeaveRequest> _requestsFromPayload(Object? payload) {
    if (payload is List<LeaveRequest>) return payload;
    if (payload is Map<String, dynamic>) {
      final raw = (payload['requests'] as List<dynamic>? ?? const []);
      return raw
          .cast<Map<String, dynamic>>()
          .map(LeaveRequest.fromJson)
          .toList();
    }
    return const [];
  }

  Future<void> _mutate(Future<bool> Function() op, String success) async {
    final ok = await op();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? success : 'Action failed')),
    );
  }

  Future<void> _reject(LeaveRequest request) async {
    final controller = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TradieColors.white,
        title: const Text('Reject leave?'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: 'Reason'),
          minLines: 2,
          maxLines: 4,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            style: TextButton.styleFrom(foregroundColor: TradieColors.alertRed),
            child: const Text('Reject'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (reason == null) return;
    await _mutate(
      () => ref
          .read(leaveManagementNotifierProvider.notifier)
          .reject(request.id, reason: reason),
      'Leave rejected',
    );
  }

  Future<void> _confirmDelete(LeaveRequest request) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TradieColors.white,
        title: const Text('Delete leave request?'),
        content: Text(
            '${request.leaveType} leave from ${request.startDate} will be soft deleted.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: TradieColors.alertRed),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _mutate(
      () =>
          ref.read(leaveManagementNotifierProvider.notifier).delete(request.id),
      'Leave deleted',
    );
  }

  Future<void> _openEditor([LeaveRequest? request]) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: TradieColors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => _LeaveEditor(request: request),
    );
  }
}

class _Summary extends StatelessWidget {
  final Map<String, dynamic> payload;

  const _Summary({required this.payload});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        children: [
          Expanded(
            child: _Metric(
              label: 'Approved',
              value: '${payload['days_approved'] ?? 0} days',
              color: TradieColors.successGreen,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _Metric(
              label: 'Pending',
              value: '${payload['days_pending'] ?? 0} days',
              color: TradieColors.electricBlue,
            ),
          ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _Metric(
      {required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: TradieColors.grey50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: TradieColors.grey200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: TradieColors.grey600)),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w600,
              fontSize: 18,
            ),
          ),
        ],
      ),
    );
  }
}

class _LeaveTile extends StatelessWidget {
  final LeaveRequest request;
  final bool canApprove;
  final VoidCallback onApprove;
  final VoidCallback onReject;
  final VoidCallback? onEdit;
  final VoidCallback? onCancel;
  final VoidCallback? onDelete;

  const _LeaveTile({
    required this.request,
    required this.canApprove,
    required this.onApprove,
    required this.onReject,
    required this.onEdit,
    required this.onCancel,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final color = _statusColor(request.status);
    return Container(
      decoration: BoxDecoration(
        color: TradieColors.white,
        border: Border.all(color: TradieColors.grey200),
        borderRadius: BorderRadius.circular(14),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Iconsax.calendar_remove, size: 18, color: color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${request.leaveType.toUpperCase()} · ${request.daysCount} days',
                      style: const TextStyle(
                        color: TradieColors.charcoal,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${request.startDate} to ${request.endDate}',
                      style: const TextStyle(
                        color: TradieColors.grey600,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              _StatusBadge(status: request.status, color: color),
              PopupMenuButton<String>(
                icon: const Icon(Iconsax.more, color: TradieColors.grey400),
                onSelected: (value) {
                  if (value == 'approve') onApprove();
                  if (value == 'reject') onReject();
                  if (value == 'edit') onEdit?.call();
                  if (value == 'cancel') onCancel?.call();
                  if (value == 'delete') onDelete?.call();
                },
                itemBuilder: (_) => [
                  if (canApprove && request.status == 'pending')
                    const PopupMenuItem(
                        value: 'approve', child: Text('Approve')),
                  if (canApprove && request.status == 'pending')
                    const PopupMenuItem(value: 'reject', child: Text('Reject')),
                  if (onEdit != null)
                    const PopupMenuItem(value: 'edit', child: Text('Edit')),
                  if (onCancel != null)
                    const PopupMenuItem(value: 'cancel', child: Text('Cancel')),
                  if (onDelete != null)
                    const PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
            ],
          ),
          if (request.workerName.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              request.workerName,
              style: const TextStyle(color: TradieColors.grey600, fontSize: 13),
            ),
          ],
          if (request.reason.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              request.reason,
              style: const TextStyle(color: TradieColors.grey600, fontSize: 14),
            ),
          ],
          if (request.rejectionReason.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              'Rejected: ${request.rejectionReason}',
              style:
                  const TextStyle(color: TradieColors.alertRed, fontSize: 13),
            ),
          ],
        ],
      ),
    );
  }

  Color _statusColor(String status) {
    return switch (status) {
      'approved' => TradieColors.successGreen,
      'rejected' => TradieColors.alertRed,
      'cancelled' => TradieColors.grey400,
      _ => TradieColors.electricBlue,
    };
  }
}

class _StatusBadge extends StatelessWidget {
  final String status;
  final Color color;

  const _StatusBadge({required this.status, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(
        status,
        style:
            TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _LeaveEditor extends ConsumerStatefulWidget {
  final LeaveRequest? request;

  const _LeaveEditor({this.request});

  @override
  ConsumerState<_LeaveEditor> createState() => _LeaveEditorState();
}

class _LeaveEditorState extends ConsumerState<_LeaveEditor> {
  final _start = TextEditingController();
  final _end = TextEditingController();
  final _reason = TextEditingController();
  String _leaveType = 'annual';
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final request = widget.request;
    if (request != null) {
      _leaveType = request.leaveType;
      _start.text = request.startDate;
      _end.text = request.endDate;
      _reason.text = request.reason;
    }
  }

  @override
  void dispose() {
    _start.dispose();
    _end.dispose();
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, bottom + 20),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Iconsax.calendar_remove,
                    color: TradieColors.electricBlue),
                const SizedBox(width: 10),
                Text(
                  widget.request == null ? 'Request leave' : 'Edit leave',
                  style: const TextStyle(
                    color: TradieColors.charcoal,
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Iconsax.close_circle),
                ),
              ],
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: _leaveType,
              decoration: _decoration('Leave type', Iconsax.calendar_remove),
              items: const [
                DropdownMenuItem(value: 'annual', child: Text('Annual')),
                DropdownMenuItem(value: 'sick', child: Text('Sick')),
                DropdownMenuItem(value: 'personal', child: Text('Personal')),
                DropdownMenuItem(value: 'unpaid', child: Text('Unpaid')),
                DropdownMenuItem(value: 'other', child: Text('Other')),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _leaveType = value);
              },
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _start,
                    decoration: _decoration('Start date', Iconsax.calendar_1),
                    readOnly: true,
                    onTap: () => _pickDate(_start),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _end,
                    decoration: _decoration('End date', Iconsax.calendar_1),
                    readOnly: true,
                    onTap: () => _pickDate(_end),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _reason,
              minLines: 3,
              maxLines: 5,
              decoration: _decoration('Reason', Iconsax.document_text),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!,
                  style: const TextStyle(color: TradieColors.alertRed)),
            ],
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Iconsax.tick_circle),
                label: Text(widget.request == null ? 'Submit request' : 'Save'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickDate(TextEditingController controller) async {
    final initial = DateTime.tryParse(controller.text) ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now().add(const Duration(days: 730)),
    );
    if (picked == null) return;
    controller.text = picked.toIso8601String().substring(0, 10);
  }

  Future<void> _save() async {
    if (_start.text.isEmpty || _end.text.isEmpty) {
      setState(() => _error = 'Start and end dates are required.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final data = {
      'leave_type': _leaveType,
      'start_date': _start.text,
      'end_date': _end.text,
      if (_reason.text.trim().isNotEmpty) 'reason': _reason.text.trim(),
    };
    final notifier = ref.read(leaveManagementNotifierProvider.notifier);
    final error = widget.request == null
        ? await notifier.create(data)
        : await notifier.update(widget.request!.id, data);
    if (!mounted) return;
    setState(() => _saving = false);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(widget.request == null
            ? 'Leave request submitted'
            : 'Leave request saved'),
      ),
    );
  }

  InputDecoration _decoration(String label, IconData icon) {
    return InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon, size: 18),
      filled: true,
      fillColor: TradieColors.grey50,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
    );
  }
}

class _MessageView extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;

  const _MessageView({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.color = TradieColors.grey400,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(24, 120, 24, 24),
      children: [
        Icon(icon, size: 52, color: color),
        const SizedBox(height: 16),
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: TradieColors.charcoal,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          style: const TextStyle(color: TradieColors.grey600, fontSize: 14),
        ),
      ],
    );
  }
}
