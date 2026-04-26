import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';

import '../../../core/providers/auth_provider.dart';
import '../../../core/utils/theme.dart';
import '../providers/payroll_provider.dart';

class PayrollScreen extends ConsumerStatefulWidget {
  const PayrollScreen({super.key});

  @override
  ConsumerState<PayrollScreen> createState() => _PayrollScreenState();
}

class _PayrollScreenState extends ConsumerState<PayrollScreen> {
  bool? _selfOnlyOverride;

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authNotifierProvider);
    final role =
        (auth.asData?.value?['role']?.toString() ?? 'worker').toLowerCase();
    final canProcess = const {'owner', 'admin'}.contains(role);
    final canViewRuns =
        const {'owner', 'admin', 'manager', 'accountant'}.contains(role);
    final selfOnly = _selfOnlyOverride ?? !canViewRuns;
    final async = selfOnly
        ? ref.watch(myPayrollModuleProvider)
        : ref.watch(payRunsProvider);

    return Scaffold(
      backgroundColor: TradieColors.white,
      appBar: AppBar(
        title: const Text('Payroll'),
        backgroundColor: TradieColors.white,
        elevation: 0,
        actions: [
          if (canViewRuns)
            IconButton(
              icon: Icon(selfOnly ? Iconsax.receipt : Iconsax.user),
              tooltip: selfOnly ? 'Show pay runs' : 'Show my payslips',
              onPressed: () => setState(() => _selfOnlyOverride = !selfOnly),
            ),
        ],
      ),
      floatingActionButton: canProcess && !selfOnly
          ? FloatingActionButton.extended(
              onPressed: () => _openEditor(),
              backgroundColor: TradieColors.electricBlue,
              foregroundColor: TradieColors.white,
              icon: const Icon(Iconsax.add),
              label: const Text('New pay run'),
            )
          : null,
      body: RefreshIndicator(
        color: TradieColors.electricBlue,
        onRefresh: () async {
          ref.invalidate(payRunsProvider);
          ref.invalidate(myPayrollModuleProvider);
        },
        child: async.when(
          loading: () => const Center(
            child: CircularProgressIndicator(color: TradieColors.electricBlue),
          ),
          error: (error, _) => _MessageView(
            icon: Iconsax.warning_2,
            title: 'Could not load payroll',
            subtitle: error.toString(),
            color: TradieColors.alertRed,
          ),
          data: (payload) {
            if (payload is Map<String, dynamic>) {
              return _PayslipList(payload: payload);
            }
            final runs = payload as List<PayRun>;
            if (runs.isEmpty) {
              return const _MessageView(
                icon: Iconsax.receipt,
                title: 'No pay runs yet',
                subtitle:
                    'Create a draft pay run for an approved timesheet period.',
              );
            }
            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 96),
              children: [
                for (final run in runs) ...[
                  _PayRunTile(
                    run: run,
                    canProcess: canProcess,
                    onTap: () => _openDetail(run),
                    onEdit:
                        run.status == 'draft' ? () => _openEditor(run) : null,
                    onProcess:
                        run.status == 'draft' ? () => _process(run) : null,
                    onPay: run.status == 'processed'
                        ? () => _mutate(
                              () => ref
                                  .read(payrollNotifierProvider.notifier)
                                  .markPaid(run.id),
                              'Pay run marked paid',
                            )
                        : null,
                    onCancel: run.status == 'draft' || run.status == 'processed'
                        ? () => _mutate(
                              () => ref
                                  .read(payrollNotifierProvider.notifier)
                                  .cancel(run.id),
                              'Pay run cancelled',
                            )
                        : null,
                    onDelete: run.status == 'draft' || run.status == 'cancelled'
                        ? () => _confirmDelete(run)
                        : null,
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

  Future<void> _process(PayRun run) async {
    final result =
        await ref.read(payrollNotifierProvider.notifier).process(run.id);
    if (!mounted) return;
    final count = result?['payslip_count'] ?? 0;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
            result == null ? 'Process failed' : 'Processed $count payslips'),
      ),
    );
  }

  Future<void> _mutate(Future<bool> Function() op, String success) async {
    final ok = await op();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? success : 'Action failed')),
    );
  }

  Future<void> _confirmDelete(PayRun run) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TradieColors.white,
        title: const Text('Delete pay run?'),
        content: Text(
            '${run.periodStart} to ${run.periodEnd} will be soft deleted.'),
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
      () => ref.read(payrollNotifierProvider.notifier).delete(run.id),
      'Pay run deleted',
    );
  }

  Future<void> _openEditor([PayRun? run]) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: TradieColors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => _PayRunEditor(run: run),
    );
  }

  Future<void> _openDetail(PayRun run) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: TradieColors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => _PayRunDetail(runId: run.id),
    );
  }
}

class _PayslipList extends StatelessWidget {
  final Map<String, dynamic> payload;

  const _PayslipList({required this.payload});

  @override
  Widget build(BuildContext context) {
    final slips = (payload['payslips'] as List<dynamic>? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(Payslip.fromJson)
        .toList();
    if (slips.isEmpty) {
      return const _MessageView(
        icon: Iconsax.receipt,
        title: 'No payslips yet',
        subtitle: 'Payslips appear here after payroll is processed.',
      );
    }
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 96),
      children: [
        Row(
          children: [
            Expanded(
              child: _Metric(
                label: 'Gross',
                value:
                    _money((payload['total_gross'] as num?)?.toDouble() ?? 0),
                color: TradieColors.electricBlue,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _Metric(
                label: 'Net',
                value: _money((payload['total_net'] as num?)?.toDouble() ?? 0),
                color: TradieColors.successGreen,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _Metric(
          label: 'Super',
          value: _money((payload['total_super'] as num?)?.toDouble() ?? 0),
          color: TradieColors.charcoal,
        ),
        const SizedBox(height: 16),
        for (final slip in slips) ...[
          _PayslipTile(slip: slip),
          const SizedBox(height: 12),
        ],
      ],
    );
  }
}

class _PayRunTile extends StatelessWidget {
  final PayRun run;
  final bool canProcess;
  final VoidCallback onTap;
  final VoidCallback? onEdit;
  final VoidCallback? onProcess;
  final VoidCallback? onPay;
  final VoidCallback? onCancel;
  final VoidCallback? onDelete;

  const _PayRunTile({
    required this.run,
    required this.canProcess,
    required this.onTap,
    required this.onEdit,
    required this.onProcess,
    required this.onPay,
    required this.onCancel,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final color = _statusColor(run.status);
    return GestureDetector(
      onTap: onTap,
      child: Container(
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
                  child: Icon(Iconsax.receipt, size: 18, color: color),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${run.periodStart} to ${run.periodEnd}',
                        style: const TextStyle(
                          color: TradieColors.charcoal,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Pay date ${run.payDate}',
                        style: const TextStyle(
                          color: TradieColors.grey600,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                _StatusBadge(status: run.status, color: color),
                if (canProcess)
                  PopupMenuButton<String>(
                    icon: const Icon(Iconsax.more, color: TradieColors.grey400),
                    onSelected: (value) {
                      if (value == 'edit') onEdit?.call();
                      if (value == 'process') onProcess?.call();
                      if (value == 'pay') onPay?.call();
                      if (value == 'cancel') onCancel?.call();
                      if (value == 'delete') onDelete?.call();
                    },
                    itemBuilder: (_) => [
                      if (onEdit != null)
                        const PopupMenuItem(value: 'edit', child: Text('Edit')),
                      if (onProcess != null)
                        const PopupMenuItem(
                            value: 'process', child: Text('Process')),
                      if (onPay != null)
                        const PopupMenuItem(
                            value: 'pay', child: Text('Mark paid')),
                      if (onCancel != null)
                        const PopupMenuItem(
                            value: 'cancel', child: Text('Cancel')),
                      if (onDelete != null)
                        const PopupMenuItem(
                            value: 'delete', child: Text('Delete')),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                    child: _MiniAmount(label: 'Gross', amount: run.totalGross)),
                Expanded(
                    child: _MiniAmount(label: 'Tax', amount: run.totalTax)),
                Expanded(
                    child: _MiniAmount(label: 'Net', amount: run.totalNet)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Color _statusColor(String status) {
    return switch (status) {
      'paid' => TradieColors.successGreen,
      'processed' => TradieColors.electricBlue,
      'cancelled' => TradieColors.grey400,
      _ => TradieColors.charcoal,
    };
  }
}

class _PayRunDetail extends ConsumerWidget {
  final String runId;

  const _PayRunDetail({required this.runId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(payRunProvider(runId));
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, bottom + 20),
      child: async.when(
        loading: () => const SizedBox(
          height: 220,
          child: Center(child: CircularProgressIndicator()),
        ),
        error: (error, _) => SizedBox(
          height: 220,
          child: Center(child: Text(error.toString())),
        ),
        data: (run) => SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Iconsax.receipt, color: TradieColors.electricBlue),
                  const SizedBox(width: 10),
                  const Text(
                    'Pay run',
                    style: TextStyle(
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
              const SizedBox(height: 10),
              Text('${run.periodStart} to ${run.periodEnd}',
                  style: const TextStyle(color: TradieColors.grey600)),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _Metric(
                      label: 'Gross',
                      value: _money(run.totalGross),
                      color: TradieColors.electricBlue,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _Metric(
                      label: 'Net',
                      value: _money(run.totalNet),
                      color: TradieColors.successGreen,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Text(
                'Payslips',
                style: TextStyle(
                  color: TradieColors.charcoal,
                  fontWeight: FontWeight.w600,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 10),
              if (run.payslips.isEmpty)
                const Text('No payslips generated yet.',
                    style: TextStyle(color: TradieColors.grey600))
              else
                for (final raw in run.payslips) ...[
                  _RunPayslipTile(data: raw as Map<String, dynamic>),
                  const SizedBox(height: 8),
                ],
            ],
          ),
        ),
      ),
    );
  }
}

class _RunPayslipTile extends StatelessWidget {
  final Map<String, dynamic> data;

  const _RunPayslipTile({required this.data});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: TradieColors.grey50,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              data['worker_name']?.toString() ?? 'Worker',
              style: const TextStyle(
                color: TradieColors.charcoal,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Text(
            _money((data['net_pay'] as num?)?.toDouble() ?? 0),
            style: const TextStyle(color: TradieColors.grey600),
          ),
        ],
      ),
    );
  }
}

class _PayslipTile extends StatelessWidget {
  final Payslip slip;

  const _PayslipTile({required this.slip});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: TradieColors.white,
        border: Border.all(color: TradieColors.grey200),
        borderRadius: BorderRadius.circular(14),
      ),
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: TradieColors.electricBlue.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Iconsax.receipt,
                size: 18, color: TradieColors.electricBlue),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${slip.periodStart} to ${slip.periodEnd}',
                  style: const TextStyle(
                    color: TradieColors.charcoal,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  'Tax ${_money(slip.taxWithheld)} · Super ${_money(slip.superAmount)}',
                  style: const TextStyle(
                      color: TradieColors.grey600, fontSize: 12),
                ),
              ],
            ),
          ),
          Text(
            _money(slip.netPay),
            style: const TextStyle(
              color: TradieColors.successGreen,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _PayRunEditor extends ConsumerStatefulWidget {
  final PayRun? run;

  const _PayRunEditor({this.run});

  @override
  ConsumerState<_PayRunEditor> createState() => _PayRunEditorState();
}

class _PayRunEditorState extends ConsumerState<_PayRunEditor> {
  final _periodStart = TextEditingController();
  final _periodEnd = TextEditingController();
  final _payDate = TextEditingController();
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final run = widget.run;
    if (run != null) {
      _periodStart.text = run.periodStart;
      _periodEnd.text = run.periodEnd;
      _payDate.text = run.payDate;
    }
  }

  @override
  void dispose() {
    _periodStart.dispose();
    _periodEnd.dispose();
    _payDate.dispose();
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
                const Icon(Iconsax.receipt, color: TradieColors.electricBlue),
                const SizedBox(width: 10),
                Text(
                  widget.run == null ? 'New pay run' : 'Edit pay run',
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
            TextField(
              controller: _periodStart,
              readOnly: true,
              onTap: () => _pickDate(_periodStart),
              decoration: _decoration('Period start'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _periodEnd,
              readOnly: true,
              onTap: () => _pickDate(_periodEnd),
              decoration: _decoration('Period end'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _payDate,
              readOnly: true,
              onTap: () => _pickDate(_payDate),
              decoration: _decoration('Pay date'),
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
                label: Text(widget.run == null ? 'Create' : 'Save'),
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
      firstDate: DateTime.now().subtract(const Duration(days: 730)),
      lastDate: DateTime.now().add(const Duration(days: 730)),
    );
    if (picked == null) return;
    controller.text = picked.toIso8601String().substring(0, 10);
  }

  Future<void> _save() async {
    if (_periodStart.text.isEmpty ||
        _periodEnd.text.isEmpty ||
        _payDate.text.isEmpty) {
      setState(() => _error = 'All dates are required.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final data = {
      'period_start': _periodStart.text,
      'period_end': _periodEnd.text,
      'pay_date': _payDate.text,
    };
    final notifier = ref.read(payrollNotifierProvider.notifier);
    final error = widget.run == null
        ? await notifier.create(data)
        : await notifier.update(widget.run!.id, data);
    if (!mounted) return;
    setState(() => _saving = false);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(widget.run == null ? 'Pay run created' : 'Pay run saved'),
      ),
    );
  }

  InputDecoration _decoration(String label) {
    return InputDecoration(
      labelText: label,
      prefixIcon: const Icon(Iconsax.calendar_1, size: 18),
      filled: true,
      fillColor: TradieColors.grey50,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
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

class _MiniAmount extends StatelessWidget {
  final String label;
  final double amount;

  const _MiniAmount({required this.label, required this.amount});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(color: TradieColors.grey600, fontSize: 12)),
        const SizedBox(height: 2),
        Text(
          _money(amount),
          style: const TextStyle(
            color: TradieColors.charcoal,
            fontWeight: FontWeight.w600,
            fontSize: 13,
          ),
        ),
      ],
    );
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

String _money(double value) => '\$${value.toStringAsFixed(2)}';
