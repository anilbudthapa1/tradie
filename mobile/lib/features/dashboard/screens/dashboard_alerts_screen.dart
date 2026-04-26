import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';

import '../../../core/providers/auth_provider.dart';
import '../../../core/utils/theme.dart';
import '../providers/dashboard_provider.dart';

/// Owner / manager screen for the Dashboard Module's CRUD entity
/// (`dashboard_alerts`). Workers and accountants get a 403 from the
/// backend; we still hide the screen at the UI level.
class DashboardAlertsScreen extends ConsumerStatefulWidget {
  const DashboardAlertsScreen({super.key});

  @override
  ConsumerState<DashboardAlertsScreen> createState() => _DashboardAlertsScreenState();
}

class _DashboardAlertsScreenState extends ConsumerState<DashboardAlertsScreen> {
  String _filter = 'active';

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authNotifierProvider);
    final role = (auth.asData?.value?['role']?.toString() ?? 'worker').toLowerCase();
    final canManage = const {'owner', 'admin', 'manager'}.contains(role);

    if (!canManage) {
      return _ForbiddenView();
    }

    final alertsAsync = ref.watch(dashboardAlertsProvider(_filter == 'all' ? '' : _filter));

    return Scaffold(
      backgroundColor: TradieColors.white,
      appBar: AppBar(
        title: const Text('Alerts'),
        backgroundColor: TradieColors.white,
        elevation: 0,
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Iconsax.filter, color: TradieColors.charcoal),
            onSelected: (v) => setState(() => _filter = v),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'active', child: Text('Active')),
              PopupMenuItem(value: 'acknowledged', child: Text('Acknowledged')),
              PopupMenuItem(value: 'resolved', child: Text('Resolved')),
              PopupMenuItem(value: 'dismissed', child: Text('Dismissed')),
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
        label: const Text('New alert'),
      ),
      body: RefreshIndicator(
        color: TradieColors.electricBlue,
        onRefresh: () async => ref.invalidate(dashboardAlertsProvider),
        child: alertsAsync.when(
          loading: () => const Center(child: CircularProgressIndicator(color: TradieColors.electricBlue)),
          error: (e, _) => _ErrorView(message: e.toString(), onRetry: () => ref.invalidate(dashboardAlertsProvider)),
          data: (list) {
            if (list.isEmpty) return const _EmptyView();
            return ListView.separated(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 96),
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: list.length,
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (_, i) {
                final a = list[i] as Map<String, dynamic>;
                return _AlertCard(
                  alert: a,
                  onAcknowledge: () => _runMutation(
                    () => ref.read(dashboardAlertNotifierProvider.notifier).acknowledge(a['id'] as String),
                    success: 'Acknowledged',
                  ),
                  onResolve: () => _runMutation(
                    () => ref.read(dashboardAlertNotifierProvider.notifier).resolve(a['id'] as String),
                    success: 'Resolved',
                  ),
                  onDismiss: () => _runMutation(
                    () => ref.read(dashboardAlertNotifierProvider.notifier).dismiss(a['id'] as String),
                    success: 'Dismissed',
                  ),
                  onDelete: () => _confirmDelete(context, a['id'] as String),
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? success : 'Action failed')),
    );
  }

  Future<void> _confirmDelete(BuildContext context, String id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TradieColors.white,
        title: const Text('Delete alert?'),
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
    final ok = await ref.read(dashboardAlertNotifierProvider.notifier).delete(id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? 'Deleted' : 'Delete failed')),
    );
  }

  Future<void> _openCreateSheet(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: TradieColors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => const _CreateAlertSheet(),
    );
  }
}

// ── Alert card ──────────────────────────────────────────────────

class _AlertCard extends StatelessWidget {
  final Map<String, dynamic> alert;
  final VoidCallback onAcknowledge;
  final VoidCallback onResolve;
  final VoidCallback onDismiss;
  final VoidCallback onDelete;

  const _AlertCard({
    required this.alert,
    required this.onAcknowledge,
    required this.onResolve,
    required this.onDismiss,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final severity = alert['severity']?.toString() ?? 'info';
    final status = alert['status']?.toString() ?? 'active';
    final tone = switch (severity) {
      'critical' => TradieColors.alertRed,
      'warning' => TradieColors.electricBlue,
      _ => TradieColors.grey400,
    };

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
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: tone.withOpacity(0.10),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    severity.toUpperCase(),
                    style: TextStyle(color: tone, fontWeight: FontWeight.w600, fontSize: 11),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: TradieColors.grey50,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    status,
                    style: const TextStyle(color: TradieColors.grey600, fontSize: 11, fontWeight: FontWeight.w500),
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Iconsax.trash, size: 18, color: TradieColors.grey400),
                  onPressed: onDelete,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              alert['title']?.toString() ?? '',
              style: const TextStyle(
                color: TradieColors.charcoal,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            if ((alert['message'] ?? '').toString().isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                alert['message'].toString(),
                style: const TextStyle(color: TradieColors.grey600, fontSize: 13),
              ),
            ],
            if (status == 'active' || status == 'acknowledged') ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  if (status == 'active')
                    OutlinedButton(onPressed: onAcknowledge, child: const Text('Acknowledge')),
                  OutlinedButton(onPressed: onResolve, child: const Text('Resolve')),
                  if (status == 'active')
                    OutlinedButton(onPressed: onDismiss, child: const Text('Dismiss')),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Create sheet ────────────────────────────────────────────────

class _CreateAlertSheet extends ConsumerStatefulWidget {
  const _CreateAlertSheet();

  @override
  ConsumerState<_CreateAlertSheet> createState() => _CreateAlertSheetState();
}

class _CreateAlertSheetState extends ConsumerState<_CreateAlertSheet> {
  final _title = TextEditingController();
  final _message = TextEditingController();
  String _severity = 'info';
  String _alertType = 'custom';
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _message.dispose();
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
              decoration: BoxDecoration(
                color: TradieColors.grey200,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text('New alert', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          const SizedBox(height: 16),
          TextField(
            controller: _title,
            decoration: const InputDecoration(labelText: 'Title', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _message,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'Message', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                value: _severity,
                decoration: const InputDecoration(labelText: 'Severity', border: OutlineInputBorder()),
                items: const [
                  DropdownMenuItem(value: 'info', child: Text('Info')),
                  DropdownMenuItem(value: 'warning', child: Text('Warning')),
                  DropdownMenuItem(value: 'critical', child: Text('Critical')),
                ],
                onChanged: (v) => setState(() => _severity = v ?? 'info'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButtonFormField<String>(
                value: _alertType,
                decoration: const InputDecoration(labelText: 'Type', border: OutlineInputBorder()),
                items: const [
                  DropdownMenuItem(value: 'custom', child: Text('Custom')),
                  DropdownMenuItem(value: 'kpi_threshold', child: Text('KPI threshold')),
                  DropdownMenuItem(value: 'overdue', child: Text('Overdue')),
                  DropdownMenuItem(value: 'compliance', child: Text('Compliance')),
                  DropdownMenuItem(value: 'system', child: Text('System')),
                ],
                onChanged: (v) => setState(() => _alertType = v ?? 'custom'),
              ),
            ),
          ]),
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
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Text('Create'),
          ),
        ],
      ),
    );
  }

  Future<void> _submit() async {
    if (_title.text.trim().isEmpty) {
      setState(() => _error = 'Title is required');
      return;
    }
    setState(() { _busy = true; _error = null; });
    final err = await ref.read(dashboardAlertNotifierProvider.notifier).create({
      'title': _title.text.trim(),
      'message': _message.text.trim(),
      'severity': _severity,
      'alert_type': _alertType,
    });
    if (!mounted) return;
    if (err != null) {
      setState(() { _busy = false; _error = err; });
      return;
    }
    Navigator.of(context).pop();
  }
}

// ── Empty / Error / Forbidden views ─────────────────────────────

class _EmptyView extends StatelessWidget {
  const _EmptyView();
  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: const [
        SizedBox(height: 120),
        Icon(Iconsax.notification_status, size: 56, color: TradieColors.grey400),
        SizedBox(height: 16),
        Center(
          child: Text(
            'No alerts',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: TradieColors.charcoal),
          ),
        ),
        SizedBox(height: 6),
        Center(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              "You're all clear. Create one with the button below to track an issue.",
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
            'Could not load alerts',
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
        Center(
          child: OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
        ),
      ],
    );
  }
}

class _ForbiddenView extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Alerts')),
      body: const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            "You don't have permission to manage alerts.",
            textAlign: TextAlign.center,
            style: TextStyle(color: TradieColors.grey600),
          ),
        ),
      ),
    );
  }
}
