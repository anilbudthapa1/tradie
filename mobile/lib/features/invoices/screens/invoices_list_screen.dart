import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';
import 'package:intl/intl.dart';

import '../../../core/utils/theme.dart';
import '../providers/invoices_provider.dart';

class InvoicesListScreen extends ConsumerStatefulWidget {
  const InvoicesListScreen({super.key});

  @override
  ConsumerState<InvoicesListScreen> createState() => _InvoicesListScreenState();
}

class _InvoicesListScreenState extends ConsumerState<InvoicesListScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tab;

  static const _statuses = [null, 'draft', 'sent', 'overdue', 'paid'];
  static const _labels = ['All', 'Draft', 'Sent', 'Overdue', 'Paid'];

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: _statuses.length, vsync: this);
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TradieColors.grey50,
      appBar: AppBar(
        backgroundColor: TradieColors.white,
        title: Row(children: [
          const Icon(Iconsax.receipt, size: 20, color: TradieColors.navy),
          const SizedBox(width: 8),
          const Text('Invoices'),
        ]),
        actions: [
          IconButton(
            icon: const Icon(Iconsax.add_circle, color: TradieColors.electricBlue),
            onPressed: () => _showCreateInvoiceSheet(context),
            tooltip: 'New Invoice',
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(80),
          child: Column(children: [
            _UnpaidBanner(),
            TabBar(
              controller: _tab,
              isScrollable: true,
              labelColor: TradieColors.electricBlue,
              unselectedLabelColor: TradieColors.grey400,
              indicatorColor: TradieColors.electricBlue,
              indicatorSize: TabBarIndicatorSize.label,
              tabs: _labels.map((l) => Tab(text: l)).toList(),
            ),
          ]),
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: _statuses
            .map((s) => _InvoicesList(status: s))
            .toList(),
      ),
    );
  }

  void _showCreateInvoiceSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _CreateInvoiceSheet(),
    );
  }
}

// ── Unpaid total banner ───────────────────────────────────────
class _UnpaidBanner extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final overdue = ref.watch(invoicesProvider('overdue'));
    final sent = ref.watch(invoicesProvider('sent'));

    double totalDue = 0.0;
    overdue.whenData((list) {
      for (final inv in list) {
        totalDue += (inv['amount_due'] as num?)?.toDouble() ?? 0.0;
      }
    });
    sent.whenData((list) {
      for (final inv in list) {
        totalDue += (inv['amount_due'] as num?)?.toDouble() ?? 0.0;
      }
    });

    if (totalDue == 0.0) return const SizedBox.shrink();

    final fmt = NumberFormat.currency(locale: 'en_AU', symbol: '\$');
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: TradieColors.alertRed.withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: TradieColors.alertRed.withOpacity(0.25)),
      ),
      child: Row(children: [
        const Icon(Iconsax.warning_2, size: 16, color: TradieColors.alertRed),
        const SizedBox(width: 8),
        Text(
          'Total unpaid: ${fmt.format(totalDue)}',
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: TradieColors.alertRed,
          ),
        ),
      ]),
    );
  }
}

// ── Invoice list per tab ──────────────────────────────────────
class _InvoicesList extends ConsumerWidget {
  final String? status;
  const _InvoicesList({this.status});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final invoices = ref.watch(invoicesProvider(status));

    return invoices.when(
      data: (list) {
        if (list.isEmpty) return _EmptyState(status: status);
        return RefreshIndicator(
          onRefresh: () => ref.refresh(invoicesProvider(status).future),
          child: ListView.builder(
            padding: const EdgeInsets.only(top: 8, bottom: 100),
            itemCount: list.length,
            itemBuilder: (ctx, i) => _InvoiceCard(
              invoice: list[i],
              onTap: () => ctx.go('/invoices/${list[i]['id']}'),
              onSend: (list[i]['status'] == 'draft')
                  ? () => _handleSend(context, ref, list[i]['id'] as String)
                  : null,
            ),
          ),
        );
      },
      loading: () => ListView.builder(
        itemCount: 5,
        padding: const EdgeInsets.only(top: 8),
        itemBuilder: (_, __) => const _InvoiceCardSkeleton(),
      ),
      error: (e, _) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Iconsax.warning_2, size: 40, color: TradieColors.alertRed),
          const SizedBox(height: 12),
          Text('Failed to load invoices', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => ref.refresh(invoicesProvider(status).future),
            child: const Text('Retry'),
          ),
        ]),
      ),
    );
  }

  Future<void> _handleSend(BuildContext context, WidgetRef ref, String id) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Send Invoice'),
        content: const Text('This will mark the invoice as sent. Continue?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(minimumSize: Size.zero, padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10)),
            child: const Text('Send'),
          ),
        ],
      ),
    );
    if (confirm != true || !context.mounted) return;

    final ok = await ref.read(invoicesNotifierProvider.notifier).sendInvoice(id);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok ? 'Invoice sent' : 'Failed to send invoice'),
        backgroundColor: ok ? TradieColors.successGreen : TradieColors.alertRed,
      ));
    }
  }
}

// ── Invoice card ──────────────────────────────────────────────
class _InvoiceCard extends StatelessWidget {
  final Map<String, dynamic> invoice;
  final VoidCallback onTap;
  final VoidCallback? onSend;

  const _InvoiceCard({
    required this.invoice,
    required this.onTap,
    this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    final status = invoice['status'] as String? ?? 'draft';
    final amountDue = (invoice['amount_due'] as num?)?.toDouble() ?? 0.0;
    final totalAmount = (invoice['total_amount'] as num?)?.toDouble() ?? 0.0;
    final dueDate = invoice['due_date'] != null
        ? DateTime.tryParse(invoice['due_date'] as String)
        : null;
    final fmt = NumberFormat.currency(locale: 'en_AU', symbol: '\$');
    final statusColor = status.invoiceStatusColor;

    Widget card = GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        decoration: BoxDecoration(
          color: TradieColors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: TradieColors.grey200),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.04),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(
                    invoice['invoice_number'] as String? ?? '',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                      color: TradieColors.navy,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    invoice['customer_name'] as String? ?? 'Unknown customer',
                    style: const TextStyle(
                      fontSize: 13,
                      color: TradieColors.grey600,
                    ),
                  ),
                ]),
              ),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(
                  fmt.format(totalAmount),
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                    color: TradieColors.navy,
                  ),
                ),
                const SizedBox(height: 4),
                _StatusBadge(status: status, color: statusColor),
              ]),
            ]),
            if (dueDate != null || amountDue > 0) ...[
              const SizedBox(height: 10),
              const Divider(height: 1, color: TradieColors.grey100),
              const SizedBox(height: 10),
              Row(children: [
                if (dueDate != null) ...[
                  const Icon(Iconsax.calendar_1, size: 13, color: TradieColors.grey400),
                  const SizedBox(width: 4),
                  Text(
                    'Due ${DateFormat('d MMM yyyy').format(dueDate)}',
                    style: TextStyle(
                      fontSize: 12,
                      color: status == 'overdue'
                          ? TradieColors.alertRed
                          : TradieColors.grey600,
                      fontWeight: status == 'overdue' ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ],
                const Spacer(),
                if (status != 'paid')
                  Text(
                    'Due: ${fmt.format(amountDue)}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: amountDue > 0 ? TradieColors.alertRed : TradieColors.successGreen,
                    ),
                  ),
              ]),
            ],
          ]),
        ),
      ),
    );

    // Swipe to send on draft invoices
    if (onSend != null) {
      return Dismissible(
        key: Key('inv-${invoice['id']}'),
        direction: DismissDirection.startToEnd,
        confirmDismiss: (_) async {
          onSend!();
          return false; // don't actually dismiss
        },
        background: Container(
          margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          decoration: BoxDecoration(
            color: TradieColors.electricBlue,
            borderRadius: BorderRadius.circular(12),
          ),
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.only(left: 24),
          child: const Row(children: [
            Icon(Iconsax.send_2, color: Colors.white, size: 20),
            SizedBox(width: 8),
            Text('Send', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
          ]),
        ),
        child: card,
      );
    }
    return card;
  }
}

class _StatusBadge extends StatelessWidget {
  final String status;
  final Color color;
  const _StatusBadge({required this.status, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        status[0].toUpperCase() + status.substring(1),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

// ── Empty state ───────────────────────────────────────────────
class _EmptyState extends StatelessWidget {
  final String? status;
  const _EmptyState({this.status});

  @override
  Widget build(BuildContext context) {
    final label = status == null ? 'invoices' : '$status invoices';
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          padding: const EdgeInsets.all(24),
          decoration: const BoxDecoration(color: TradieColors.grey100, shape: BoxShape.circle),
          child: const Icon(Iconsax.receipt, size: 48, color: TradieColors.grey400),
        ),
        const SizedBox(height: 16),
        Text(
          'No $label yet',
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: TradieColors.navy,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Create an invoice to start tracking payments',
          style: TextStyle(color: TradieColors.grey600),
        ),
      ]),
    );
  }
}

// ── Skeleton loader ───────────────────────────────────────────
class _InvoiceCardSkeleton extends StatelessWidget {
  const _InvoiceCardSkeleton();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      height: 96,
      decoration: BoxDecoration(
        color: TradieColors.grey100,
        borderRadius: BorderRadius.circular(12),
      ),
    );
  }
}

// ── Create invoice bottom sheet (minimal) ─────────────────────
class _CreateInvoiceSheet extends ConsumerStatefulWidget {
  const _CreateInvoiceSheet();

  @override
  ConsumerState<_CreateInvoiceSheet> createState() => _CreateInvoiceSheetState();
}

class _CreateInvoiceSheetState extends ConsumerState<_CreateInvoiceSheet> {
  final _customerCtrl = TextEditingController();
  final _titleCtrl = TextEditingController();
  final _dueDateCtrl = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _customerCtrl.dispose();
    _titleCtrl.dispose();
    _dueDateCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Container(
      decoration: const BoxDecoration(
        color: TradieColors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.fromLTRB(24, 16, 24, 24 + bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Center(
          child: Container(
            width: 40, height: 4,
            decoration: BoxDecoration(color: TradieColors.grey200, borderRadius: BorderRadius.circular(2)),
          ),
        ),
        const SizedBox(height: 16),
        Row(children: [
          const Icon(Iconsax.receipt, size: 20, color: TradieColors.navy),
          const SizedBox(width: 8),
          const Text('New Invoice', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: TradieColors.navy)),
        ]),
        const SizedBox(height: 20),
        TextField(
          controller: _customerCtrl,
          decoration: const InputDecoration(
            labelText: 'Customer ID',
            prefixIcon: Icon(Iconsax.user, size: 18),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _titleCtrl,
          decoration: const InputDecoration(
            labelText: 'Invoice Title',
            prefixIcon: Icon(Iconsax.document_text, size: 18),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _dueDateCtrl,
          decoration: const InputDecoration(
            labelText: 'Due Date (YYYY-MM-DD)',
            prefixIcon: Icon(Iconsax.calendar_1, size: 18),
          ),
          keyboardType: TextInputType.datetime,
        ),
        const SizedBox(height: 24),
        ElevatedButton.icon(
          onPressed: _submitting ? null : _submit,
          icon: _submitting
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Iconsax.add, size: 18),
          label: const Text('Create Invoice'),
        ),
      ]),
    );
  }

  Future<void> _submit() async {
    if (_customerCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Customer ID is required')),
      );
      return;
    }
    setState(() => _submitting = true);
    final ok = await ref.read(invoicesNotifierProvider.notifier).createInvoice({
      'customer_id': _customerCtrl.text.trim(),
      'title': _titleCtrl.text.trim(),
      if (_dueDateCtrl.text.isNotEmpty) 'due_date': _dueDateCtrl.text.trim(),
      'line_items': [],
    });
    if (mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok ? 'Invoice created' : 'Failed to create invoice'),
        backgroundColor: ok ? TradieColors.successGreen : TradieColors.alertRed,
      ));
    }
  }
}
