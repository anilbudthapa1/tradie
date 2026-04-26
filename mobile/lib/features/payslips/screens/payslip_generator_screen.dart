import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';

import '../../../core/providers/auth_provider.dart';
import '../../../core/utils/theme.dart';
import '../providers/payslip_generator_provider.dart';

class PayslipGeneratorScreen extends ConsumerStatefulWidget {
  const PayslipGeneratorScreen({super.key});

  @override
  ConsumerState<PayslipGeneratorScreen> createState() =>
      _PayslipGeneratorScreenState();
}

class _PayslipGeneratorScreenState
    extends ConsumerState<PayslipGeneratorScreen> {
  String _status = '';
  bool? _selfOnlyOverride;

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authNotifierProvider);
    final role =
        (auth.asData?.value?['role']?.toString() ?? 'worker').toLowerCase();
    final canGenerate =
        const {'owner', 'admin', 'manager', 'accountant'}.contains(role);
    final selfOnly = _selfOnlyOverride ?? !canGenerate;
    final async = selfOnly
        ? ref.watch(myPayslipGeneratorProvider)
        : ref.watch(payslipGeneratorProvider(PayslipFilter(status: _status)));

    return Scaffold(
      backgroundColor: TradieColors.white,
      appBar: AppBar(
        title: const Text('Payslips'),
        backgroundColor: TradieColors.white,
        elevation: 0,
        actions: [
          if (canGenerate)
            IconButton(
              icon: Icon(selfOnly ? Iconsax.receipt : Iconsax.user),
              tooltip: selfOnly ? 'Show all payslips' : 'Show my payslips',
              onPressed: () => setState(() => _selfOnlyOverride = !selfOnly),
            ),
          if (!selfOnly)
            PopupMenuButton<String>(
              icon: const Icon(Iconsax.filter, color: TradieColors.charcoal),
              onSelected: (value) => setState(() => _status = value),
              itemBuilder: (_) => const [
                PopupMenuItem(value: '', child: Text('All')),
                PopupMenuItem(value: 'draft', child: Text('Draft')),
                PopupMenuItem(value: 'locked', child: Text('Locked')),
                PopupMenuItem(value: 'paid', child: Text('Paid')),
                PopupMenuItem(value: 'cancelled', child: Text('Cancelled')),
              ],
            ),
        ],
      ),
      body: RefreshIndicator(
        color: TradieColors.electricBlue,
        onRefresh: () async {
          ref.invalidate(payslipGeneratorProvider);
          ref.invalidate(myPayslipGeneratorProvider);
        },
        child: async.when(
          loading: () => const Center(
            child: CircularProgressIndicator(color: TradieColors.electricBlue),
          ),
          error: (error, _) => _MessageView(
            icon: Iconsax.warning_2,
            title: 'Could not load payslips',
            subtitle: error.toString(),
            color: TradieColors.alertRed,
          ),
          data: (payslips) {
            if (payslips.isEmpty) {
              return const _MessageView(
                icon: Iconsax.receipt,
                title: 'No payslips yet',
                subtitle: 'Payslips appear after payroll is processed.',
              );
            }
            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 96),
              children: [
                for (final payslip in payslips) ...[
                  _PayslipCard(
                    payslip: payslip,
                    canGenerate: canGenerate,
                    onGenerate: () => _generate(payslip),
                    onStatus: (status) => _statusUpdate(payslip, status),
                    onDelete: payslip.status == 'paid' || !canGenerate
                        ? null
                        : () => _confirmDelete(payslip),
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

  Future<void> _generate(GeneratedPayslip payslip) async {
    final error = await ref
        .read(payslipGeneratorNotifierProvider.notifier)
        .generate(payslip.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(error ?? 'Payslip PDF generated')),
    );
  }

  Future<void> _statusUpdate(GeneratedPayslip payslip, String status) async {
    final error = await ref
        .read(payslipGeneratorNotifierProvider.notifier)
        .updateStatus(payslip.id, status);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(error ?? 'Payslip updated')),
    );
  }

  Future<void> _confirmDelete(GeneratedPayslip payslip) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TradieColors.white,
        title: const Text('Delete payslip?'),
        content: Text(
            '${payslip.workerName} ${payslip.periodStart} payslip will be soft deleted.'),
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
    final ok = await ref
        .read(payslipGeneratorNotifierProvider.notifier)
        .delete(payslip.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? 'Payslip deleted' : 'Delete failed')),
    );
  }
}

class _PayslipCard extends StatelessWidget {
  final GeneratedPayslip payslip;
  final bool canGenerate;
  final VoidCallback onGenerate;
  final ValueChanged<String> onStatus;
  final VoidCallback? onDelete;

  const _PayslipCard({
    required this.payslip,
    required this.canGenerate,
    required this.onGenerate,
    required this.onStatus,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final color = _statusColor(payslip.status);
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
                child: Icon(Iconsax.receipt, size: 18, color: color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      payslip.workerName.isEmpty
                          ? 'Payslip'
                          : payslip.workerName,
                      style: const TextStyle(
                        color: TradieColors.charcoal,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${payslip.periodStart} to ${payslip.periodEnd}',
                      style: const TextStyle(
                        color: TradieColors.grey600,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              _StatusBadge(status: payslip.status, color: color),
              PopupMenuButton<String>(
                icon: const Icon(Iconsax.more, color: TradieColors.grey400),
                onSelected: (value) {
                  if (value == 'generate') onGenerate();
                  if (value.startsWith('status:')) {
                    onStatus(value.substring('status:'.length));
                  }
                  if (value == 'delete') onDelete?.call();
                },
                itemBuilder: (_) => [
                  if (canGenerate)
                    const PopupMenuItem(
                      value: 'generate',
                      child: Text('Generate PDF'),
                    ),
                  if (canGenerate && payslip.status != 'paid')
                    const PopupMenuItem(
                      value: 'status:locked',
                      child: Text('Mark locked'),
                    ),
                  if (canGenerate && payslip.status != 'paid')
                    const PopupMenuItem(
                      value: 'status:cancelled',
                      child: Text('Cancel'),
                    ),
                  if (onDelete != null)
                    const PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                  child: _MiniAmount(label: 'Gross', amount: payslip.grossPay)),
              Expanded(
                  child:
                      _MiniAmount(label: 'Tax', amount: payslip.taxWithheld)),
              Expanded(
                  child: _MiniAmount(label: 'Net', amount: payslip.netPay)),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            payslip.pdfGeneratedAt == null
                ? 'PDF not generated yet'
                : 'PDF generated · ${payslip.pdfDownloadCount} downloads',
            style: const TextStyle(color: TradieColors.grey600, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Color _statusColor(String status) {
    return switch (status) {
      'paid' => TradieColors.successGreen,
      'cancelled' => TradieColors.grey400,
      'locked' => TradieColors.electricBlue,
      _ => TradieColors.charcoal,
    };
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
          '\$${amount.toStringAsFixed(2)}',
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
