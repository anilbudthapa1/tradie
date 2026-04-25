import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';
import 'package:intl/intl.dart';

import '../../../core/utils/theme.dart';
import '../providers/quotes_provider.dart';

class QuoteDetailScreen extends ConsumerWidget {
  final String id;
  const QuoteDetailScreen({super.key, required this.id});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(quoteDetailProvider(id));

    return Scaffold(
      backgroundColor: TradieColors.grey50,
      appBar: AppBar(
        backgroundColor: TradieColors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Iconsax.arrow_left, size: 20, color: TradieColors.navy),
          onPressed: () => context.pop(),
        ),
        title: Row(children: [
          const Icon(Iconsax.document_text, size: 18, color: TradieColors.navy),
          const SizedBox(width: 8),
          detail.when(
            data: (d) => Text(
              (d['quote_number'] as String?) ?? 'Quote',
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w700, color: TradieColors.navy),
            ),
            loading: () => const Text('Quote',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: TradieColors.navy)),
            error: (_, __) => const Text('Quote',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: TradieColors.navy)),
          ),
        ]),
        actions: [
          IconButton(
            icon: const Icon(Iconsax.refresh, size: 20, color: TradieColors.grey600),
            onPressed: () => ref.refresh(quoteDetailProvider(id).future),
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: detail.when(
        data: (d) => _QuoteDetailBody(quoteId: id, data: d),
        loading: () => const _DetailSkeleton(),
        error: (e, _) => Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Iconsax.warning_2, size: 40, color: TradieColors.alertRed),
            const SizedBox(height: 12),
            const Text('Failed to load quote',
                style: TextStyle(color: TradieColors.navy, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => ref.refresh(quoteDetailProvider(id).future),
              child: const Text('Retry'),
            ),
          ]),
        ),
      ),
    );
  }
}

// ── Detail body ───────────────────────────────────────────────
class _QuoteDetailBody extends ConsumerWidget {
  final String quoteId;
  final Map<String, dynamic> data;

  const _QuoteDetailBody({required this.quoteId, required this.data});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final q = data is Map<String, dynamic> ? data : <String, dynamic>{};
    final status = q['status'] as String? ?? 'draft';
    final fmt = NumberFormat.currency(locale: 'en_AU', symbol: r'$');

    // Line items may be nested or returned directly depending on the endpoint
    final lineItems = (q['line_items'] as List?)?.cast<Map<String, dynamic>>() ?? [];

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // ── Header card ────────────────────────────────────────
        _Card(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(
                    q['quote_number'] as String? ?? '',
                    style: const TextStyle(
                        fontSize: 22, fontWeight: FontWeight.w800, color: TradieColors.navy),
                  ),
                  const SizedBox(height: 4),
                  Row(children: [
                    const Icon(Iconsax.user, size: 14, color: TradieColors.grey400),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        q['customer_name'] as String? ?? 'Unknown customer',
                        style: const TextStyle(fontSize: 14, color: TradieColors.grey600),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ]),
                  if ((q['title'] as String? ?? '').isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      q['title'] as String,
                      style: const TextStyle(fontSize: 14, color: TradieColors.charcoal),
                    ),
                  ],
                ]),
              ),
              const SizedBox(width: 12),
              _StatusBadgeLarge(status: status),
            ]),
            if (q['valid_until'] != null) ...[
              const SizedBox(height: 12),
              Row(children: [
                const Icon(Iconsax.calendar_1, size: 14, color: TradieColors.grey400),
                const SizedBox(width: 4),
                Text(
                  'Valid until ${DateFormat('d MMMM yyyy').format(DateTime.parse(q['valid_until'] as String))}',
                  style: TextStyle(
                    fontSize: 13,
                    color: _isExpired(q['valid_until'] as String)
                        ? TradieColors.alertRed
                        : TradieColors.grey600,
                    fontWeight: _isExpired(q['valid_until'] as String)
                        ? FontWeight.w600
                        : FontWeight.w400,
                  ),
                ),
              ]),
            ],
          ]),
        ),
        const SizedBox(height: 12),

        // ── Action buttons ─────────────────────────────────────
        _ActionButtons(quoteId: quoteId, status: status),
        const SizedBox(height: 12),

        // ── Line items ─────────────────────────────────────────
        _SectionHeader(icon: Iconsax.document_text, title: 'LINE ITEMS'),
        const SizedBox(height: 8),
        _Card(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (lineItems.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'No line items yet. Add items to calculate totals.',
                  style: TextStyle(fontSize: 13, color: TradieColors.grey400),
                ),
              )
            else
              _LineItemsTable(quoteId: quoteId, lineItems: lineItems, fmt: fmt, status: status),
            // ── Add item button ──
            if (status == 'draft' || status == 'sent') ...[
              const SizedBox(height: 12),
              const Divider(color: TradieColors.grey100, height: 1),
              const SizedBox(height: 8),
              GestureDetector(
                onTap: () => _showAddItemSheet(context, quoteId),
                child: Row(children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: TradieColors.electricBlue.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Icon(Iconsax.add, size: 16, color: TradieColors.electricBlue),
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    'Add Item',
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: TradieColors.electricBlue),
                  ),
                ]),
              ),
            ],
          ]),
        ),
        const SizedBox(height: 12),

        // ── Summary card ───────────────────────────────────────
        _SectionHeader(icon: Iconsax.calculator, title: 'SUMMARY'),
        const SizedBox(height: 8),
        _TotalsCard(q: q, fmt: fmt, quoteId: quoteId, status: status),
        const SizedBox(height: 24),
      ]),
    );
  }

  bool _isExpired(String dateStr) {
    try {
      return DateTime.parse(dateStr).isBefore(DateTime.now());
    } catch (_) {
      return false;
    }
  }

  void _showAddItemSheet(BuildContext context, String quoteId) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _AddLineItemSheet(quoteId: quoteId),
    );
  }
}

// ── Action buttons ────────────────────────────────────────────
class _ActionButtons extends ConsumerWidget {
  final String quoteId;
  final String status;
  const _ActionButtons({required this.quoteId, required this.status});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(quoteNotifierProvider.notifier);

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // Draft actions
      if (status == 'draft') ...[
        ElevatedButton.icon(
          onPressed: () => _confirmSend(context, ref, notifier),
          icon: const Icon(Iconsax.send_2, size: 18),
          label: const Text('Send Quote'),
          style: ElevatedButton.styleFrom(
            backgroundColor: TradieColors.electricBlue,
            minimumSize: const Size(0, 48),
          ),
        ),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () => _confirmConvert(context, ref, notifier),
              icon: const Icon(Iconsax.convert_3d_cube, size: 16),
              label: const Text('Convert to Job'),
              style: OutlinedButton.styleFrom(
                foregroundColor: TradieColors.successGreen,
                side: const BorderSide(color: TradieColors.successGreen),
                minimumSize: const Size(0, 44),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () => _previewPDF(context),
              icon: const Icon(Iconsax.document_download, size: 16),
              label: const Text('Preview PDF'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 44),
              ),
            ),
          ),
        ]),
      ],

      // Sent actions
      if (status == 'sent') ...[
        Row(children: [
          Expanded(
            child: ElevatedButton.icon(
              onPressed: () => _confirmConvert(context, ref, notifier),
              icon: const Icon(Iconsax.convert_3d_cube, size: 16),
              label: const Text('Convert to Job'),
              style: ElevatedButton.styleFrom(
                backgroundColor: TradieColors.successGreen,
                minimumSize: const Size(0, 48),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () => _previewPDF(context),
              icon: const Icon(Iconsax.document_download, size: 16),
              label: const Text('Preview PDF'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 48),
              ),
            ),
          ),
        ]),
      ],

      // Approved actions
      if (status == 'approved') ...[
        ElevatedButton.icon(
          onPressed: () => _confirmConvert(context, ref, notifier),
          icon: const Icon(Iconsax.convert_3d_cube, size: 18),
          label: const Text('Convert to Job'),
          style: ElevatedButton.styleFrom(
            backgroundColor: TradieColors.successGreen,
            minimumSize: const Size(0, 48),
          ),
        ),
      ],
    ]);
  }

  Future<void> _confirmSend(
      BuildContext context, WidgetRef ref, QuoteNotifier notifier) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Send Quote'),
        content: const Text('This will mark the quote as sent and share it with the customer.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
                backgroundColor: TradieColors.electricBlue,
                minimumSize: Size.zero,
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10)),
            child: const Text('Send'),
          ),
        ],
      ),
    );
    if (confirm != true || !context.mounted) return;

    final ok = await notifier.sendQuote(quoteId);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok ? 'Quote sent' : 'Failed to send quote'),
        backgroundColor: ok ? TradieColors.successGreen : TradieColors.alertRed,
      ));
      if (ok) ref.refresh(quoteDetailProvider(quoteId).future);
    }
  }

  Future<void> _confirmConvert(
      BuildContext context, WidgetRef ref, QuoteNotifier notifier) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Convert to Job'),
        content: const Text(
            'This will create a new job from this quote. The quote status will be set to converted.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
                backgroundColor: TradieColors.successGreen,
                minimumSize: Size.zero,
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10)),
            child: const Text('Convert'),
          ),
        ],
      ),
    );
    if (confirm != true || !context.mounted) return;

    final jobId = await notifier.convertToJob(quoteId);
    if (!context.mounted) return;
    if (jobId != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Job created successfully'),
        backgroundColor: TradieColors.successGreen,
        action: SnackBarAction(
          label: 'View Job',
          textColor: Colors.white,
          onPressed: () => context.go('/jobs/$jobId'),
        ),
      ));
      ref.refresh(quoteDetailProvider(quoteId).future);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Failed to convert to job'),
        backgroundColor: TradieColors.alertRed,
      ));
    }
  }

  void _previewPDF(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('PDF preview coming soon')),
    );
  }
}

// ── Line items table ──────────────────────────────────────────
class _LineItemsTable extends ConsumerWidget {
  final String quoteId;
  final List<Map<String, dynamic>> lineItems;
  final NumberFormat fmt;
  final String status;

  const _LineItemsTable({
    required this.quoteId,
    required this.lineItems,
    required this.fmt,
    required this.status,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canEdit = status == 'draft' || status == 'sent';
    return Column(children: [
      // Header
      Row(children: const [
        Expanded(flex: 4, child: Text('Description', style: _hdrStyle)),
        Expanded(flex: 1, child: Text('Qty', textAlign: TextAlign.center, style: _hdrStyle)),
        Expanded(flex: 2, child: Text('Price', textAlign: TextAlign.right, style: _hdrStyle)),
        Expanded(flex: 2, child: Text('Total', textAlign: TextAlign.right, style: _hdrStyle)),
        SizedBox(width: 24), // space for delete
      ]),
      const SizedBox(height: 8),
      const Divider(color: TradieColors.grey100, height: 1),
      const SizedBox(height: 8),
      ...lineItems.asMap().entries.map((entry) {
        final i = entry.key;
        final li = entry.value;
        final qty = (li['quantity'] as num?)?.toDouble() ?? 1.0;
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
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600, color: TradieColors.navy),
              ),
            ),
            if (canEdit)
              GestureDetector(
                onTap: () => _removeItem(context, ref, li['id'] as String?),
                child: const Padding(
                  padding: EdgeInsets.only(left: 4),
                  child: Icon(Iconsax.trash, size: 16, color: TradieColors.alertRed),
                ),
              )
            else
              const SizedBox(width: 24),
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

  Future<void> _removeItem(BuildContext context, WidgetRef ref, String? itemId) async {
    if (itemId == null) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Remove Item'),
        content: const Text('Remove this line item from the quote?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
                backgroundColor: TradieColors.alertRed,
                minimumSize: Size.zero,
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10)),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirm != true || !context.mounted) return;

    final ok = await ref.read(quoteNotifierProvider.notifier).removeLineItem(quoteId, itemId);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok ? 'Item removed' : 'Failed to remove item'),
        backgroundColor: ok ? TradieColors.successGreen : TradieColors.alertRed,
      ));
    }
  }

  static const _hdrStyle = TextStyle(
      fontSize: 11, fontWeight: FontWeight.w600, color: TradieColors.grey400);
}

// ── Totals card ───────────────────────────────────────────────
class _TotalsCard extends ConsumerWidget {
  final Map<String, dynamic> q;
  final NumberFormat fmt;
  final String quoteId;
  final String status;

  const _TotalsCard({
    required this.q,
    required this.fmt,
    required this.quoteId,
    required this.status,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subtotal = (q['subtotal'] as num?)?.toDouble() ?? 0.0;
    final discount = (q['discount_amount'] as num?)?.toDouble() ?? 0.0;
    final gst = (q['gst_amount'] as num?)?.toDouble() ?? 0.0;
    final total = (q['total'] as num?)?.toDouble() ?? 0.0;
    final canEdit = status == 'draft' || status == 'sent';

    return _Card(
      child: Column(children: [
        _TotalRow(label: 'Subtotal', value: fmt.format(subtotal)),
        if (discount > 0) ...[
          const SizedBox(height: 6),
          _TotalRow(
            label: 'Discount',
            value: '- ${fmt.format(discount)}',
            valueColor: TradieColors.safetyOrange,
          ),
        ],
        const SizedBox(height: 6),
        _TotalRow(label: 'GST (10%)', value: fmt.format(gst)),
        const SizedBox(height: 8),
        const Divider(color: TradieColors.grey100, height: 1),
        const SizedBox(height: 8),
        _TotalRow(
          label: 'Total (AUD)',
          value: fmt.format(total),
          bold: true,
          fontSize: 18,
          valueColor: TradieColors.navy,
        ),
        if (canEdit) ...[
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => _showDiscountSheet(context, ref),
            icon: const Icon(Iconsax.discount_shape, size: 16),
            label: Text(discount > 0 ? 'Edit Discount' : 'Apply Discount'),
            style: OutlinedButton.styleFrom(
              foregroundColor: TradieColors.safetyOrange,
              side: const BorderSide(color: TradieColors.safetyOrange),
              minimumSize: const Size(double.infinity, 40),
            ),
          ),
        ],
      ]),
    );
  }

  void _showDiscountSheet(BuildContext context, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ApplyDiscountSheet(quoteId: quoteId),
    );
  }
}

class _TotalRow extends StatelessWidget {
  final String label;
  final String value;
  final bool bold;
  final double fontSize;
  final Color? valueColor;

  const _TotalRow({
    required this.label,
    required this.value,
    this.bold = false,
    this.fontSize = 14,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Text(
        label,
        style: TextStyle(
          fontSize: 14,
          color: TradieColors.grey600,
          fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
      const Spacer(),
      Text(
        value,
        style: TextStyle(
          fontSize: bold ? fontSize : 14,
          fontWeight: bold ? FontWeight.w800 : FontWeight.w400,
          color: valueColor ?? TradieColors.charcoal,
        ),
      ),
    ]);
  }
}

// ── Add line item sheet ───────────────────────────────────────
class _AddLineItemSheet extends ConsumerStatefulWidget {
  final String quoteId;
  const _AddLineItemSheet({required this.quoteId});

  @override
  ConsumerState<_AddLineItemSheet> createState() => _AddLineItemSheetState();
}

class _AddLineItemSheetState extends ConsumerState<_AddLineItemSheet> {
  final _descCtrl = TextEditingController();
  final _qtyCtrl = TextEditingController(text: '1');
  final _priceCtrl = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _descCtrl.dispose();
    _qtyCtrl.dispose();
    _priceCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    final qty = double.tryParse(_qtyCtrl.text) ?? 1.0;
    final price = double.tryParse(_priceCtrl.text) ?? 0.0;
    final lineTotal = qty * price;
    final gst = lineTotal * 0.1;
    final fmt = NumberFormat.currency(locale: 'en_AU', symbol: r'$');

    return Container(
      decoration: const BoxDecoration(
        color: TradieColors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.fromLTRB(24, 16, 24, 24 + bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                  color: TradieColors.grey200, borderRadius: BorderRadius.circular(2)),
            ),
          ),
          const SizedBox(height: 16),
          Row(children: [
            const Icon(Iconsax.document_text, size: 20, color: TradieColors.navy),
            const SizedBox(width: 8),
            const Text('Add Line Item',
                style: TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w700, color: TradieColors.navy)),
          ]),
          const SizedBox(height: 20),
          TextField(
            controller: _descCtrl,
            decoration: const InputDecoration(
              labelText: 'Description',
              hintText: 'e.g. Labour - 4 hours',
              prefixIcon: Icon(Iconsax.document_text, size: 18),
            ),
            textCapitalization: TextCapitalization.sentences,
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _qtyCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Quantity',
                  prefixIcon: Icon(Iconsax.hashtag, size: 18),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _priceCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Unit Price (\$)',
                  prefixIcon: Icon(Iconsax.money, size: 18),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
          ]),
          // Preview totals
          if (price > 0) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: TradieColors.grey50,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: TradieColors.grey200),
              ),
              child: Column(children: [
                Row(children: [
                  const Text('Line total:',
                      style: TextStyle(fontSize: 13, color: TradieColors.grey600)),
                  const Spacer(),
                  Text(fmt.format(lineTotal),
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600, color: TradieColors.charcoal)),
                ]),
                const SizedBox(height: 4),
                Row(children: [
                  const Text('GST (10%):',
                      style: TextStyle(fontSize: 12, color: TradieColors.grey400)),
                  const Spacer(),
                  Text(fmt.format(gst),
                      style: const TextStyle(fontSize: 12, color: TradieColors.grey400)),
                ]),
              ]),
            ),
          ],
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _submitting ? null : _submit,
              icon: _submitting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Iconsax.add, size: 18),
              label: const Text('Add Item'),
              style: ElevatedButton.styleFrom(
                backgroundColor: TradieColors.electricBlue,
                minimumSize: const Size(0, 48),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _submit() async {
    if (_descCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Description is required')));
      return;
    }
    final qty = double.tryParse(_qtyCtrl.text.trim());
    final price = double.tryParse(_priceCtrl.text.trim());
    if (qty == null || qty <= 0) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Enter a valid quantity')));
      return;
    }
    if (price == null || price < 0) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Enter a valid price')));
      return;
    }
    setState(() => _submitting = true);
    final ok = await ref.read(quoteNotifierProvider.notifier).addLineItem(
          widget.quoteId,
          description: _descCtrl.text.trim(),
          qty: qty,
          price: price,
          taxRate: 0.1,
        );
    if (mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok ? 'Item added' : 'Failed to add item'),
        backgroundColor: ok ? TradieColors.successGreen : TradieColors.alertRed,
      ));
    }
  }
}

// ── Apply discount sheet ──────────────────────────────────────
class _ApplyDiscountSheet extends ConsumerStatefulWidget {
  final String quoteId;
  const _ApplyDiscountSheet({required this.quoteId});

  @override
  ConsumerState<_ApplyDiscountSheet> createState() => _ApplyDiscountSheetState();
}

class _ApplyDiscountSheetState extends ConsumerState<_ApplyDiscountSheet> {
  final _amountCtrl = TextEditingController();
  bool _usePercentage = false;
  bool _submitting = false;

  @override
  void dispose() {
    _amountCtrl.dispose();
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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                  color: TradieColors.grey200, borderRadius: BorderRadius.circular(2)),
            ),
          ),
          const SizedBox(height: 16),
          Row(children: [
            const Icon(Iconsax.discount_shape, size: 20, color: TradieColors.safetyOrange),
            const SizedBox(width: 8),
            const Text('Apply Discount',
                style: TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w700, color: TradieColors.navy)),
          ]),
          const SizedBox(height: 20),
          // Toggle: amount vs percentage
          Row(children: [
            _TypeChip(
              label: 'Fixed Amount (\$)',
              selected: !_usePercentage,
              onTap: () => setState(() => _usePercentage = false),
            ),
            const SizedBox(width: 8),
            _TypeChip(
              label: 'Percentage (%)',
              selected: _usePercentage,
              onTap: () => setState(() => _usePercentage = true),
            ),
          ]),
          const SizedBox(height: 16),
          TextField(
            controller: _amountCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: _usePercentage ? 'Discount Percentage (%)' : 'Discount Amount (\$)',
              prefixIcon: Icon(
                _usePercentage ? Iconsax.percentage_square : Iconsax.money,
                size: 18,
              ),
            ),
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _submitting ? null : _submit,
              icon: _submitting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Iconsax.tick_circle, size: 18),
              label: const Text('Apply Discount'),
              style: ElevatedButton.styleFrom(
                backgroundColor: TradieColors.safetyOrange,
                minimumSize: const Size(0, 48),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _submit() async {
    final val = double.tryParse(_amountCtrl.text.trim());
    if (val == null || val < 0) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Enter a valid discount value')));
      return;
    }
    setState(() => _submitting = true);
    final ok = await ref.read(quoteNotifierProvider.notifier).applyDiscount(
          widget.quoteId,
          amount: _usePercentage ? null : val,
          percentage: _usePercentage ? val : null,
        );
    if (mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok ? 'Discount applied' : 'Failed to apply discount'),
        backgroundColor: ok ? TradieColors.successGreen : TradieColors.alertRed,
      ));
    }
  }
}

class _TypeChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _TypeChip({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? TradieColors.safetyOrange.withOpacity(0.12)
              : TradieColors.grey100,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? TradieColors.safetyOrange : TradieColors.grey200,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? TradieColors.safetyOrange : TradieColors.grey600,
          ),
        ),
      ),
    );
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
      Icon(icon, size: 13, color: TradieColors.grey600),
      const SizedBox(width: 6),
      Text(
        title,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: TradieColors.grey600,
          letterSpacing: 0.8,
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
    final color = _quoteStatusColor(status);
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

class _DetailSkeleton extends StatelessWidget {
  const _DetailSkeleton();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(children: [
        Container(
            height: 160,
            decoration: BoxDecoration(
                color: TradieColors.grey100, borderRadius: BorderRadius.circular(12))),
        const SizedBox(height: 12),
        Container(
            height: 60,
            decoration: BoxDecoration(
                color: TradieColors.grey100, borderRadius: BorderRadius.circular(12))),
        const SizedBox(height: 12),
        Container(
            height: 200,
            decoration: BoxDecoration(
                color: TradieColors.grey100, borderRadius: BorderRadius.circular(12))),
        const SizedBox(height: 12),
        Container(
            height: 120,
            decoration: BoxDecoration(
                color: TradieColors.grey100, borderRadius: BorderRadius.circular(12))),
      ]),
    );
  }
}

// ── Status colour helper ──────────────────────────────────────
Color _quoteStatusColor(String status) {
  switch (status) {
    case 'draft':
      return TradieColors.grey400;
    case 'sent':
      return TradieColors.electricBlue;
    case 'approved':
      return TradieColors.successGreen;
    case 'rejected':
      return TradieColors.alertRed;
    case 'expired':
      return TradieColors.safetyOrange;
    case 'converted':
      return const Color(0xFF7C3AED);
    default:
      return TradieColors.grey400;
  }
}
