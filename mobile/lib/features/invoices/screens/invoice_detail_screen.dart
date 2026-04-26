import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';
import 'package:intl/intl.dart';

import '../../../core/utils/theme.dart';
import '../providers/invoices_provider.dart';

class InvoiceDetailScreen extends ConsumerWidget {
  final String id;
  const InvoiceDetailScreen({super.key, required this.id});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(invoiceDetailProvider(id));

    return Scaffold(
      backgroundColor: TradieColors.grey50,
      appBar: AppBar(
        backgroundColor: TradieColors.white,
        leading: IconButton(
          icon: const Icon(Iconsax.arrow_left, size: 20),
          onPressed: () => context.pop(),
        ),
        title: Row(children: [
          const Icon(Iconsax.receipt, size: 18, color: TradieColors.navy),
          const SizedBox(width: 8),
          detail.when(
            data: (d) => Text((d['invoice'] as Map?)?['invoice_number'] ?? 'Invoice'),
            loading: () => const Text('Invoice'),
            error: (_, __) => const Text('Invoice'),
          ),
        ]),
        actions: [
          IconButton(
            icon: const Icon(Iconsax.refresh, size: 20),
            onPressed: () => ref.refresh(invoiceDetailProvider(id).future),
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: detail.when(
        data: (d) => _InvoiceDetailBody(id: id, data: d),
        loading: () => const _DetailSkeleton(),
        error: (e, _) => Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Iconsax.warning_2, size: 40, color: TradieColors.alertRed),
            const SizedBox(height: 12),
            const Text('Failed to load invoice',
                style: TextStyle(color: TradieColors.navy, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => ref.refresh(invoiceDetailProvider(id).future),
              child: const Text('Retry'),
            ),
          ]),
        ),
      ),
    );
  }
}

// ── Main body ─────────────────────────────────────────────────
class _InvoiceDetailBody extends ConsumerWidget {
  final String id;
  final Map<String, dynamic> data;

  const _InvoiceDetailBody({required this.id, required this.data});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inv = (data['invoice'] as Map<String, dynamic>?) ?? {};
    final lineItems = (data['line_items'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final payments = (data['payments'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final status = inv['status'] as String? ?? 'draft';
    final fmt = NumberFormat.currency(locale: 'en_AU', symbol: '\$');

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // ── Header card ────────────────────────────────────────
        _Card(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  inv['invoice_number'] as String? ?? '',
                  style: const TextStyle(
                    fontSize: 22, fontWeight: FontWeight.w800, color: TradieColors.navy,
                  ),
                ),
                const SizedBox(height: 4),
                Row(children: [
                  const Icon(Iconsax.user, size: 14, color: TradieColors.grey400),
                  const SizedBox(width: 4),
                  Text(
                    inv['customer_name'] as String? ?? 'Unknown customer',
                    style: const TextStyle(fontSize: 14, color: TradieColors.grey600),
                  ),
                ]),
              ]),
            ),
            _StatusBadgeLarge(status: status),
          ]),
          const SizedBox(height: 16),
          const Divider(color: TradieColors.grey100),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: _InfoTile(
              icon: Iconsax.money,
              label: 'Total',
              value: fmt.format((inv['total'] as num?)?.toDouble() ?? 0.0),
              valueStyle: const TextStyle(
                fontSize: 20, fontWeight: FontWeight.w800, color: TradieColors.navy,
              ),
            )),
            if ((inv['amount_due'] as num?)?.toDouble() != 0.0)
              Expanded(child: _InfoTile(
                icon: Iconsax.receipt_minus,
                label: 'Amount Due',
                value: fmt.format((inv['amount_due'] as num?)?.toDouble() ?? 0.0),
                valueStyle: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w700, color: TradieColors.alertRed,
                ),
              )),
          ]),
          if (inv['due_date'] != null) ...[
            const SizedBox(height: 8),
            Row(children: [
              const Icon(Iconsax.calendar_1, size: 14, color: TradieColors.grey400),
              const SizedBox(width: 4),
              Text(
                'Due ${DateFormat('d MMMM yyyy').format(DateTime.parse(inv['due_date'] as String))}',
                style: TextStyle(
                  fontSize: 13,
                  color: status == 'overdue' ? TradieColors.alertRed : TradieColors.grey600,
                  fontWeight: status == 'overdue' ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ]),
          ],
        ])),
        const SizedBox(height: 12),

        // ── Action buttons ─────────────────────────────────────
        _ActionButtons(id: id, status: status),
        const SizedBox(height: 12),

        // ── Line items ─────────────────────────────────────────
        if (lineItems.isNotEmpty) ...[
          _SectionHeader(icon: Iconsax.document_text, title: 'Line Items'),
          const SizedBox(height: 8),
          _Card(child: _LineItemsTable(lineItems: lineItems, fmt: fmt)),
          const SizedBox(height: 12),
        ],

        // ── Totals ─────────────────────────────────────────────
        _SectionHeader(icon: Iconsax.calculator, title: 'Summary'),
        const SizedBox(height: 8),
        _TotalsCard(inv: inv, fmt: fmt),
        const SizedBox(height: 12),

        // ── Notes ──────────────────────────────────────────────
        if (inv['notes'] != null && (inv['notes'] as String).isNotEmpty) ...[
          _SectionHeader(icon: Iconsax.note_text, title: 'Notes'),
          const SizedBox(height: 8),
          _Card(child: Text(
            inv['notes'] as String,
            style: const TextStyle(fontSize: 14, color: TradieColors.grey600, height: 1.5),
          )),
          const SizedBox(height: 12),
        ],

        // ── Payment history ────────────────────────────────────
        if (payments.isNotEmpty) ...[
          _SectionHeader(icon: Iconsax.money_recive, title: 'Payments'),
          const SizedBox(height: 8),
          ...payments.map((p) => _PaymentRow(payment: p, fmt: fmt)),
          const SizedBox(height: 12),
        ],
      ]),
    );
  }
}

// ── Action buttons based on status ───────────────────────────
class _ActionButtons extends ConsumerWidget {
  final String id;
  final String status;
  const _ActionButtons({required this.id, required this.status});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(invoicesNotifierProvider.notifier);

    return Column(children: [
      // Draft: show Send button
      if (status == 'draft')
        ElevatedButton.icon(
          onPressed: () => _confirmSend(context, ref, notifier),
          icon: const Icon(Iconsax.send_2, size: 18),
          label: const Text('Send Invoice'),
          style: ElevatedButton.styleFrom(
            backgroundColor: TradieColors.electricBlue,
          ),
        ),

      // Sent or Overdue: show Record Payment button
      if (status == 'sent' || status == 'overdue') ...[
        ElevatedButton.icon(
          onPressed: () => _showRecordPaymentSheet(context, ref, notifier),
          icon: const Icon(Iconsax.money_recive, size: 18),
          label: const Text('Record Payment'),
          style: ElevatedButton.styleFrom(
            backgroundColor: TradieColors.successGreen,
          ),
        ),
        const SizedBox(height: 8),
      ],

      // Partial: show additional payment option
      if (status == 'partial') ...[
        ElevatedButton.icon(
          onPressed: () => _showRecordPaymentSheet(context, ref, notifier),
          icon: const Icon(Iconsax.money_recive, size: 18),
          label: const Text('Record Payment'),
          style: ElevatedButton.styleFrom(
            backgroundColor: TradieColors.safetyOrange,
          ),
        ),
        const SizedBox(height: 8),
      ],

      // All: PDF view / credit note
      Row(children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => _viewPDF(context),
            icon: const Icon(Iconsax.document_download, size: 16),
            label: const Text('View PDF'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 44),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => _showCreditNoteSheet(context, ref, notifier),
            icon: const Icon(Iconsax.receipt_minus, size: 16),
            label: const Text('Credit Note'),
            style: OutlinedButton.styleFrom(
              foregroundColor: TradieColors.safetyOrange,
              side: const BorderSide(color: TradieColors.safetyOrange),
              minimumSize: const Size(0, 44),
            ),
          ),
        ),
      ]),
    ]);
  }

  Future<void> _confirmSend(
      BuildContext context, WidgetRef ref, InvoicesNotifier notifier) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Send Invoice'),
        content: const Text('Mark this invoice as sent?'),
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

    final ok = await notifier.sendInvoice(id);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok ? 'Invoice sent' : 'Failed to send invoice'),
        backgroundColor: ok ? TradieColors.successGreen : TradieColors.alertRed,
      ));
    }
  }

  void _showRecordPaymentSheet(
      BuildContext context, WidgetRef ref, InvoicesNotifier notifier) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _RecordPaymentSheet(id: id, notifier: notifier),
    );
  }

  void _showCreditNoteSheet(
      BuildContext context, WidgetRef ref, InvoicesNotifier notifier) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _CreditNoteSheet(id: id, notifier: notifier),
    );
  }

  void _viewPDF(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('PDF generation coming soon')),
    );
  }
}

// ── Record payment sheet ──────────────────────────────────────
class _RecordPaymentSheet extends StatefulWidget {
  final String id;
  final InvoicesNotifier notifier;
  const _RecordPaymentSheet({required this.id, required this.notifier});

  @override
  State<_RecordPaymentSheet> createState() => _RecordPaymentSheetState();
}

class _RecordPaymentSheetState extends State<_RecordPaymentSheet> {
  final _amountCtrl = TextEditingController();
  final _referenceCtrl = TextEditingController();
  String _method = 'bank_transfer';
  bool _submitting = false;

  static const _methods = [
    ('bank_transfer', 'Bank Transfer'),
    ('cash', 'Cash'),
    ('card', 'Card'),
    ('cheque', 'Cheque'),
    ('online', 'Online'),
  ];

  @override
  void dispose() {
    _amountCtrl.dispose();
    _referenceCtrl.dispose();
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
          const Icon(Iconsax.money_recive, size: 20, color: TradieColors.navy),
          const SizedBox(width: 8),
          const Text('Record Payment', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: TradieColors.navy)),
        ]),
        const SizedBox(height: 20),
        TextField(
          controller: _amountCtrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: 'Amount (\$)',
            prefixIcon: Icon(Iconsax.money, size: 18),
          ),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          value: _method,
          decoration: const InputDecoration(
            labelText: 'Payment Method',
            prefixIcon: Icon(Iconsax.card, size: 18),
          ),
          items: _methods.map((m) => DropdownMenuItem(value: m.$1, child: Text(m.$2))).toList(),
          onChanged: (v) => setState(() => _method = v ?? _method),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _referenceCtrl,
          decoration: const InputDecoration(
            labelText: 'Reference (optional)',
            prefixIcon: Icon(Iconsax.document, size: 18),
          ),
        ),
        const SizedBox(height: 24),
        ElevatedButton.icon(
          onPressed: _submitting ? null : _submit,
          icon: _submitting
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Iconsax.tick_circle, size: 18),
          label: const Text('Record Payment'),
          style: ElevatedButton.styleFrom(backgroundColor: TradieColors.successGreen),
        ),
      ]),
    );
  }

  Future<void> _submit() async {
    final amount = double.tryParse(_amountCtrl.text.trim());
    if (amount == null || amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid amount')),
      );
      return;
    }
    setState(() => _submitting = true);
    final ok = await widget.notifier.recordPayment(
      widget.id,
      amount: amount,
      paymentMethod: _method,
      reference: _referenceCtrl.text.trim().isEmpty ? null : _referenceCtrl.text.trim(),
    );
    if (mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok ? 'Payment recorded' : 'Failed to record payment'),
        backgroundColor: ok ? TradieColors.successGreen : TradieColors.alertRed,
      ));
    }
  }
}

// ── Credit note sheet ─────────────────────────────────────────
class _CreditNoteSheet extends StatefulWidget {
  final String id;
  final InvoicesNotifier notifier;
  const _CreditNoteSheet({required this.id, required this.notifier});

  @override
  State<_CreditNoteSheet> createState() => _CreditNoteSheetState();
}

class _CreditNoteSheetState extends State<_CreditNoteSheet> {
  final _amountCtrl = TextEditingController();
  final _reasonCtrl = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _amountCtrl.dispose();
    _reasonCtrl.dispose();
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
          const Icon(Iconsax.receipt_minus, size: 20, color: TradieColors.safetyOrange),
          const SizedBox(width: 8),
          const Text('Issue Credit Note', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: TradieColors.navy)),
        ]),
        const SizedBox(height: 20),
        TextField(
          controller: _amountCtrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: 'Credit Amount (\$)',
            prefixIcon: Icon(Iconsax.money, size: 18),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _reasonCtrl,
          maxLines: 2,
          decoration: const InputDecoration(
            labelText: 'Reason (optional)',
            prefixIcon: Icon(Iconsax.note_text, size: 18),
          ),
        ),
        const SizedBox(height: 24),
        ElevatedButton.icon(
          onPressed: _submitting ? null : _submit,
          icon: _submitting
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Iconsax.receipt_minus, size: 18),
          label: const Text('Issue Credit Note'),
          style: ElevatedButton.styleFrom(backgroundColor: TradieColors.safetyOrange),
        ),
      ]),
    );
  }

  Future<void> _submit() async {
    final amount = double.tryParse(_amountCtrl.text.trim());
    if (amount == null || amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid amount')),
      );
      return;
    }
    setState(() => _submitting = true);
    final ok = await widget.notifier.issueCreditNote(
      widget.id,
      amount: amount,
      reason: _reasonCtrl.text.trim().isEmpty ? null : _reasonCtrl.text.trim(),
    );
    if (mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok ? 'Credit note issued' : 'Failed to issue credit note'),
        backgroundColor: ok ? TradieColors.successGreen : TradieColors.alertRed,
      ));
    }
  }
}

// ── Line items table ──────────────────────────────────────────
class _LineItemsTable extends StatelessWidget {
  final List<Map<String, dynamic>> lineItems;
  final NumberFormat fmt;
  const _LineItemsTable({required this.lineItems, required this.fmt});

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      // Header row
      Row(children: const [
        Expanded(flex: 4, child: Text('Description', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: TradieColors.grey400))),
        Expanded(flex: 1, child: Text('Qty', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: TradieColors.grey400))),
        Expanded(flex: 2, child: Text('Price', textAlign: TextAlign.right, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: TradieColors.grey400))),
        Expanded(flex: 2, child: Text('Total', textAlign: TextAlign.right, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: TradieColors.grey400))),
      ]),
      const SizedBox(height: 8),
      const Divider(color: TradieColors.grey100, height: 1),
      const SizedBox(height: 8),
      ...lineItems.asMap().entries.map((entry) {
        final i = entry.key;
        final li = entry.value;
        final qty = (li['quantity'] as num?)?.toDouble() ?? 0.0;
        final price = (li['unit_price'] as num?)?.toDouble() ?? 0.0;
        final lineTotal = (li['line_total'] as num?)?.toDouble() ?? (qty * price);
        return Column(children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              flex: 4,
              child: Text(
                li['description'] as String? ?? '',
                style: const TextStyle(fontSize: 13, color: TradieColors.charcoal),
              ),
            ),
            Expanded(
              flex: 1,
              child: Text(
                qty % 1 == 0 ? qty.toInt().toString() : qty.toStringAsFixed(2),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: TradieColors.grey600),
              ),
            ),
            Expanded(
              flex: 2,
              child: Text(
                fmt.format(price),
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 13, color: TradieColors.grey600),
              ),
            ),
            Expanded(
              flex: 2,
              child: Text(
                fmt.format(lineTotal),
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: TradieColors.navy),
              ),
            ),
          ]),
          if (i < lineItems.length - 1) ...[
            const SizedBox(height: 8),
            const Divider(color: TradieColors.grey100, height: 1),
            const SizedBox(height: 8),
          ],
        ]);
      }),
    ]);
  }
}

// ── Totals card ───────────────────────────────────────────────
class _TotalsCard extends StatelessWidget {
  final Map<String, dynamic> inv;
  final NumberFormat fmt;
  const _TotalsCard({required this.inv, required this.fmt});

  @override
  Widget build(BuildContext context) {
    final subtotal = (inv['subtotal'] as num?)?.toDouble() ?? 0.0;
    final gst = (inv['gst_amount'] as num?)?.toDouble() ?? 0.0;
    final total = (inv['total'] as num?)?.toDouble() ?? 0.0;
    final paid = (inv['amount_paid'] as num?)?.toDouble() ?? 0.0;
    final due = (inv['amount_due'] as num?)?.toDouble() ?? 0.0;

    return _Card(child: Column(children: [
      _TotalRow(label: 'Subtotal', value: fmt.format(subtotal)),
      const SizedBox(height: 6),
      _TotalRow(label: 'GST (10%)', value: fmt.format(gst)),
      const SizedBox(height: 8),
      const Divider(color: TradieColors.grey100, height: 1),
      const SizedBox(height: 8),
      _TotalRow(
        label: 'Total',
        value: fmt.format(total),
        bold: true,
        valueColor: TradieColors.navy,
      ),
      if (paid > 0) ...[
        const SizedBox(height: 6),
        _TotalRow(
          label: 'Amount Paid',
          value: fmt.format(paid),
          valueColor: TradieColors.successGreen,
        ),
      ],
      if (due > 0) ...[
        const SizedBox(height: 6),
        _TotalRow(
          label: 'Amount Due',
          value: fmt.format(due),
          bold: true,
          valueColor: TradieColors.alertRed,
        ),
      ],
      if (due <= 0 && total > 0) ...[
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: TradieColors.successGreen.withOpacity(0.08),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Iconsax.tick_circle, size: 16, color: TradieColors.successGreen),
            SizedBox(width: 6),
            Text('Paid in Full', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: TradieColors.successGreen)),
          ]),
        ),
      ],
    ]));
  }
}

class _TotalRow extends StatelessWidget {
  final String label;
  final String value;
  final bool bold;
  final Color? valueColor;
  const _TotalRow({required this.label, required this.value, this.bold = false, this.valueColor});

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontSize: bold ? 15 : 14,
      fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
      color: valueColor ?? TradieColors.charcoal,
    );
    return Row(children: [
      Text(label, style: TextStyle(fontSize: 14, color: TradieColors.grey600, fontWeight: bold ? FontWeight.w600 : FontWeight.w400)),
      const Spacer(),
      Text(value, style: style),
    ]);
  }
}

// ── Payment history row ───────────────────────────────────────
class _PaymentRow extends StatelessWidget {
  final Map<String, dynamic> payment;
  final NumberFormat fmt;
  const _PaymentRow({required this.payment, required this.fmt});

  @override
  Widget build(BuildContext context) {
    final paidAt = payment['paid_at'] != null
        ? DateTime.tryParse(payment['paid_at'] as String)
        : null;
    final amount = (payment['amount'] as num?)?.toDouble() ?? 0.0;
    final method = payment['payment_method'] as String? ?? '';
    final reference = payment['reference'] as String?;

    return _Card(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: TradieColors.successGreen.withOpacity(0.1),
            shape: BoxShape.circle,
          ),
          child: const Icon(Iconsax.money_recive, size: 16, color: TradieColors.successGreen),
        ),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            _methodLabel(method),
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: TradieColors.navy),
          ),
          if (reference != null && reference.isNotEmpty)
            Text('Ref: $reference', style: const TextStyle(fontSize: 12, color: TradieColors.grey400)),
          if (paidAt != null)
            Text(
              DateFormat('d MMM yyyy').format(paidAt),
              style: const TextStyle(fontSize: 12, color: TradieColors.grey600),
            ),
        ])),
        Text(
          fmt.format(amount),
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: TradieColors.successGreen),
        ),
      ]),
    );
  }

  String _methodLabel(String method) {
    switch (method) {
      case 'bank_transfer': return 'Bank Transfer';
      case 'cash': return 'Cash';
      case 'card': return 'Card';
      case 'cheque': return 'Cheque';
      case 'online': return 'Online';
      default: return method.isNotEmpty ? method[0].toUpperCase() + method.substring(1) : 'Payment';
    }
  }
}

// ── Shared widgets ────────────────────────────────────────────
class _Card extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  const _Card({required this.child, this.padding});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 0),
      padding: padding ?? const EdgeInsets.all(16),
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
      child: child,
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  const _SectionHeader({required this.icon, required this.title});

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Icon(icon, size: 14, color: TradieColors.grey600),
      const SizedBox(width: 6),
      Text(
        title,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: TradieColors.grey600,
          letterSpacing: 0.5,
        ),
      ),
    ]);
  }
}

class _StatusBadgeLarge extends StatelessWidget {
  final String status;
  const _StatusBadgeLarge({required this.status});

  @override
  Widget build(BuildContext context) {
    final color = status.invoiceStatusColor;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        status[0].toUpperCase() + status.substring(1),
        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: color),
      ),
    );
  }
}

class _InfoTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final TextStyle? valueStyle;
  const _InfoTile({required this.icon, required this.label, required this.value, this.valueStyle});

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(icon, size: 13, color: TradieColors.grey400),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 11, color: TradieColors.grey400, fontWeight: FontWeight.w500)),
      ]),
      const SizedBox(height: 4),
      Text(value, style: valueStyle ?? const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: TradieColors.navy)),
    ]);
  }
}

// ── Skeleton ──────────────────────────────────────────────────
class _DetailSkeleton extends StatelessWidget {
  const _DetailSkeleton();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(children: [
        Container(height: 160, decoration: BoxDecoration(color: TradieColors.grey100, borderRadius: BorderRadius.circular(12))),
        const SizedBox(height: 12),
        Container(height: 60, decoration: BoxDecoration(color: TradieColors.grey100, borderRadius: BorderRadius.circular(12))),
        const SizedBox(height: 12),
        Container(height: 120, decoration: BoxDecoration(color: TradieColors.grey100, borderRadius: BorderRadius.circular(12))),
      ]),
    );
  }
}

// ── Map extension helper ──────────────────────────────────────
extension _MapGet on Map<String, dynamic> {
  dynamic get(String key) => this[key];
}
