import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';
import 'package:intl/intl.dart';

import '../../../core/utils/theme.dart';
import '../providers/expenses_provider.dart';

// ── Category metadata ─────────────────────────────────────────

class _CategoryMeta {
  final String label;
  final IconData icon;
  final Color color;
  const _CategoryMeta(this.label, this.icon, this.color);
}

const _categories = <String, _CategoryMeta>{
  'fuel':          _CategoryMeta('Fuel',          Iconsax.gas_station,  Color(0xFFF97316)),
  'materials':     _CategoryMeta('Materials',     Iconsax.box,          Color(0xFF2563EB)),
  'tools':         _CategoryMeta('Tools',         Iconsax.briefcase,    Color(0xFF7C3AED)),
  'insurance':     _CategoryMeta('Insurance',     Iconsax.shield_tick,  Color(0xFF16A34A)),
  'rent':          _CategoryMeta('Rent',          Iconsax.buildings_2,  Color(0xFF0891B2)),
  'utilities':     _CategoryMeta('Utilities',     Iconsax.electricity,  Color(0xFFD97706)),
  'subcontractor': _CategoryMeta('Subcontractor', Iconsax.people,       Color(0xFFDB2777)),
  'other':         _CategoryMeta('Other',         Iconsax.category_2,   Color(0xFF94A3B8)),
};

_CategoryMeta _meta(String? cat) =>
    _categories[cat] ?? const _CategoryMeta('Other', Iconsax.category_2, TradieColors.grey400);

// ── Currency formatter ────────────────────────────────────────

final _fmt = NumberFormat.currency(locale: 'en_AU', symbol: '\$');

// ── Main screen ───────────────────────────────────────────────

class ExpensesScreen extends ConsumerStatefulWidget {
  const ExpensesScreen({super.key});

  @override
  ConsumerState<ExpensesScreen> createState() => _ExpensesScreenState();
}

class _ExpensesScreenState extends ConsumerState<ExpensesScreen> {
  String? _activeCategory; // null = All

  @override
  Widget build(BuildContext context) {
    final summary = ref.watch(expenseSummaryProvider);

    return Scaffold(
      backgroundColor: TradieColors.grey50,
      appBar: AppBar(
        backgroundColor: TradieColors.white,
        title: Row(children: const [
          Icon(Iconsax.receipt_item, size: 20, color: TradieColors.navy),
          SizedBox(width: 8),
          Text('Expenses'),
        ]),
        actions: [
          IconButton(
            icon: const Icon(Iconsax.chart_square, color: TradieColors.electricBlue),
            tooltip: 'Summary',
            onPressed: () => _showSummarySheet(context),
          ),
          IconButton(
            icon: const Icon(Iconsax.export_2, color: TradieColors.electricBlue),
            tooltip: 'Export for Accountant',
            onPressed: () => _handleExport(context),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(allExpensesProvider);
          ref.invalidate(expenseSummaryProvider);
        },
        child: CustomScrollView(
          slivers: [
            // Summary bar
            SliverToBoxAdapter(
              child: _SummaryBar(summary: summary),
            ),
            // Category filter chips
            SliverToBoxAdapter(
              child: _CategoryFilter(
                active: _activeCategory,
                onChanged: (c) => setState(() => _activeCategory = c),
              ),
            ),
            // Expense list
            _ExpenseList(category: _activeCategory),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddExpenseSheet(context),
        backgroundColor: TradieColors.electricBlue,
        icon: const Icon(Iconsax.add, color: Colors.white),
        label: const Text(
          'Add Expense',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  void _showAddExpenseSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _AddExpenseSheet(),
    );
  }

  void _showSummarySheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _SummarySheet(),
    );
  }

  Future<void> _handleExport(BuildContext context) async {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Preparing export...'),
        duration: Duration(seconds: 1),
      ),
    );
    try {
      final data = await ref.read(expenseExportProvider.future);
      if (!context.mounted) return;
      showDialog(
        context: context,
        builder: (_) => _ExportDialog(rows: data),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Export failed: $e'),
          backgroundColor: TradieColors.alertRed,
        ),
      );
    }
  }
}

// ── Summary bar (3-metric card) ───────────────────────────────

class _SummaryBar extends StatelessWidget {
  final AsyncValue<Map<String, dynamic>> summary;
  const _SummaryBar({required this.summary});

  @override
  Widget build(BuildContext context) {
    return summary.when(
      data: (data) {
        final total = (data['total_this_month'] as num?)?.toDouble() ?? 0.0;
        final gst   = (data['total_gst_this_month'] as num?)?.toDouble() ?? 0.0;
        final cats  = data['by_category'] as List? ?? [];
        int count   = 0;
        for (final c in cats) {
          count += ((c as Map)['count'] as num?)?.toInt() ?? 0;
        }
        return _SummaryCard(
          totalThisMonth: total,
          gstClaimable: gst,
          expenseCount: count,
        );
      },
      loading: () => _SummaryCardSkeleton(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final double totalThisMonth;
  final double gstClaimable;
  final int expenseCount;
  const _SummaryCard({
    required this.totalThisMonth,
    required this.gstClaimable,
    required this.expenseCount,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1A2332), Color(0xFF1E40AF)],
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF1E40AF).withOpacity(0.25),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(children: [
        Expanded(
          child: _MetricItem(
            label: 'This Month',
            value: _fmt.format(totalThisMonth),
            icon: Iconsax.wallet_3,
            light: true,
          ),
        ),
        Container(width: 1, height: 48, color: Colors.white.withOpacity(0.15)),
        Expanded(
          child: _MetricItem(
            label: 'GST Claimable',
            value: _fmt.format(gstClaimable),
            icon: Iconsax.receipt_tax,
            light: true,
          ),
        ),
        Container(width: 1, height: 48, color: Colors.white.withOpacity(0.15)),
        Expanded(
          child: _MetricItem(
            label: 'Expenses',
            value: '$expenseCount',
            icon: Iconsax.receipt_item,
            light: true,
          ),
        ),
      ]),
    );
  }
}

class _MetricItem extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final bool light;
  const _MetricItem({
    required this.label,
    required this.value,
    required this.icon,
    this.light = false,
  });

  @override
  Widget build(BuildContext context) {
    final textColor = light ? Colors.white : TradieColors.navy;
    final subColor  = light ? Colors.white.withOpacity(0.65) : TradieColors.grey600;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 18, color: light ? Colors.white.withOpacity(0.80) : TradieColors.electricBlue),
      const SizedBox(height: 6),
      Text(value, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: textColor)),
      const SizedBox(height: 2),
      Text(label, style: TextStyle(fontSize: 10, color: subColor)),
    ]);
  }
}

class _SummaryCardSkeleton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      height: 96,
      decoration: BoxDecoration(
        color: TradieColors.grey100,
        borderRadius: BorderRadius.circular(16),
      ),
    );
  }
}

// ── Category filter chips ─────────────────────────────────────

class _CategoryFilter extends StatelessWidget {
  final String? active;
  final ValueChanged<String?> onChanged;
  const _CategoryFilter({required this.active, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final chips = <Widget>[
      _FilterChip(label: 'All', active: active == null, onTap: () => onChanged(null)),
    ];
    for (final entry in _categories.entries) {
      final key  = entry.key;
      final meta = entry.value;
      chips.add(_FilterChip(
        label: meta.label,
        active: active == key,
        color: meta.color,
        onTap: () => onChanged(active == key ? null : key),
      ));
    }

    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemCount: chips.length,
        itemBuilder: (_, i) => chips[i],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final bool active;
  final Color? color;
  final VoidCallback onTap;
  const _FilterChip({required this.label, required this.active, this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final activeColor = color ?? TradieColors.electricBlue;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: active ? activeColor : TradieColors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: active ? activeColor : TradieColors.grey200,
          ),
          boxShadow: active
              ? [BoxShadow(color: activeColor.withOpacity(0.2), blurRadius: 6, offset: const Offset(0, 2))]
              : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: active ? Colors.white : TradieColors.grey600,
          ),
        ),
      ),
    );
  }
}

// ── Expense list sliver ───────────────────────────────────────

class _ExpenseList extends ConsumerWidget {
  final String? category;
  const _ExpenseList({this.category});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final expenses = ref.watch(allExpensesProvider);

    return expenses.when(
      data: (list) {
        final filtered = category == null
            ? list
            : list.where((e) => e['category'] == category).toList();

        if (filtered.isEmpty) {
          return SliverFillRemaining(
            hasScrollBody: false,
            child: _EmptyState(category: category),
          );
        }

        return SliverPadding(
          padding: const EdgeInsets.only(top: 8, bottom: 120),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (ctx, i) => _ExpenseCard(
                expense: filtered[i],
                onDelete: () => _confirmDelete(ctx, ref, filtered[i]['id'] as String),
              ),
              childCount: filtered.length,
            ),
          ),
        );
      },
      loading: () => SliverList(
        delegate: SliverChildBuilderDelegate(
          (_, __) => const _ExpenseCardSkeleton(),
          childCount: 5,
        ),
      ),
      error: (e, _) => SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Iconsax.warning_2, size: 40, color: TradieColors.alertRed),
            const SizedBox(height: 12),
            Text(
              'Failed to load expenses',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => ref.invalidate(allExpensesProvider),
              child: const Text('Retry'),
            ),
          ]),
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref, String id) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Delete Expense'),
        content: const Text('This expense will be permanently removed. Continue?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: TradieColors.alertRed,
              minimumSize: Size.zero,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true || !context.mounted) return;

    final ok = await ref.read(expenseNotifierProvider.notifier).deleteExpense(id);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok ? 'Expense deleted' : 'Failed to delete expense'),
        backgroundColor: ok ? TradieColors.successGreen : TradieColors.alertRed,
      ));
    }
  }
}

// ── Expense card ──────────────────────────────────────────────

class _ExpenseCard extends StatelessWidget {
  final Map<String, dynamic> expense;
  final VoidCallback onDelete;
  const _ExpenseCard({required this.expense, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final category    = expense['category'] as String? ?? 'other';
    final description = expense['description'] as String? ?? '';
    final supplier    = expense['supplier'] as String?;
    final amount      = (expense['amount'] as num?)?.toDouble() ?? 0.0;
    final gstAmount   = (expense['gst_amount'] as num?)?.toDouble() ?? 0.0;
    final dateStr     = expense['date'] as String?;
    final receiptURL  = expense['receipt_url'] as String?;
    final meta        = _meta(category);

    DateTime? date;
    if (dateStr != null) date = DateTime.tryParse(dateStr);

    return Dismissible(
      key: Key('exp-${expense['id']}'),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) async {
        onDelete();
        return false; // actual delete goes through the confirm dialog
      },
      background: Container(
        margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        decoration: BoxDecoration(
          color: TradieColors.alertRed,
          borderRadius: BorderRadius.circular(12),
        ),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        child: const Row(mainAxisSize: MainAxisSize.min, children: [
          Text('Delete', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
          SizedBox(width: 8),
          Icon(Iconsax.trash, color: Colors.white, size: 20),
        ]),
      ),
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
        child: IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // Color-coded left border
            Container(
              width: 4,
              decoration: BoxDecoration(
                color: meta.color,
                borderRadius: const BorderRadius.horizontal(left: Radius.circular(12)),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  // Category icon
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: meta.color.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(meta.icon, size: 20, color: meta.color),
                  ),
                  const SizedBox(width: 12),
                  // Description + supplier + date
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(
                        description,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                          color: TradieColors.navy,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (supplier != null && supplier.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          supplier,
                          style: const TextStyle(
                            fontSize: 12,
                            color: TradieColors.grey600,
                          ),
                        ),
                      ],
                      const SizedBox(height: 4),
                      Row(children: [
                        if (date != null) ...[
                          const Icon(Iconsax.calendar_1, size: 11, color: TradieColors.grey400),
                          const SizedBox(width: 3),
                          Text(
                            DateFormat('d MMM yyyy').format(date),
                            style: const TextStyle(fontSize: 11, color: TradieColors.grey400),
                          ),
                          const SizedBox(width: 8),
                        ],
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: meta.color.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            meta.label,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: meta.color,
                            ),
                          ),
                        ),
                      ]),
                    ]),
                  ),
                  const SizedBox(width: 8),
                  // Amount + badges
                  Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text(
                      _fmt.format(amount),
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        color: TradieColors.navy,
                      ),
                    ),
                    const SizedBox(height: 4),
                    if (gstAmount > 0)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: TradieColors.successGreen.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          'GST ${_fmt.format(gstAmount)}',
                          style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: TradieColors.successGreen,
                          ),
                        ),
                      ),
                    if (receiptURL != null && receiptURL.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      const Icon(Iconsax.receipt_item, size: 14, color: TradieColors.electricBlue),
                    ],
                  ]),
                ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

class _ExpenseCardSkeleton extends StatelessWidget {
  const _ExpenseCardSkeleton();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      height: 80,
      decoration: BoxDecoration(
        color: TradieColors.grey100,
        borderRadius: BorderRadius.circular(12),
      ),
    );
  }
}

// ── Empty state ───────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final String? category;
  const _EmptyState({this.category});

  @override
  Widget build(BuildContext context) {
    final label = category == null ? 'expenses' : '${_meta(category).label} expenses';
    return Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Container(
        padding: const EdgeInsets.all(24),
        decoration: const BoxDecoration(
          color: TradieColors.grey100,
          shape: BoxShape.circle,
        ),
        child: const Icon(Iconsax.receipt_item, size: 48, color: TradieColors.grey400),
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
        'Tap + Add Expense to start tracking',
        style: TextStyle(fontSize: 14, color: TradieColors.grey600),
      ),
    ]);
  }
}

// ── Add expense bottom sheet ──────────────────────────────────

class _AddExpenseSheet extends ConsumerStatefulWidget {
  const _AddExpenseSheet();

  @override
  ConsumerState<_AddExpenseSheet> createState() => _AddExpenseSheetState();
}

class _AddExpenseSheetState extends ConsumerState<_AddExpenseSheet> {
  final _formKey    = GlobalKey<FormState>();
  final _descCtrl   = TextEditingController();
  final _amountCtrl = TextEditingController();
  final _supplierCtrl = TextEditingController();

  String _category       = 'fuel';
  String _paymentMethod  = 'card';
  bool   _isGSTInclusive = true;
  DateTime _date         = DateTime.now();
  bool   _submitting     = false;
  bool   _receiptAttached = false;

  static const _paymentMethods = ['cash', 'card', 'bank_transfer', 'bpay'];
  static const _paymentLabels  = ['Cash', 'Card', 'Bank Transfer', 'BPAY'];

  @override
  void dispose() {
    _descCtrl.dispose();
    _amountCtrl.dispose();
    _supplierCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    final meta   = _meta(_category);

    return Container(
      decoration: const BoxDecoration(
        color: TradieColors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.fromLTRB(24, 16, 24, 24 + bottom),
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Drag handle
            Center(
              child: Container(
                width: 40, height: 4,
                decoration: BoxDecoration(
                  color: TradieColors.grey200,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            // Title
            Row(children: [
              Icon(meta.icon, size: 20, color: meta.color),
              const SizedBox(width: 8),
              const Text(
                'New Expense',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: TradieColors.navy),
              ),
            ]),
            const SizedBox(height: 20),

            // Category dropdown
            const _FieldLabel('Category'),
            const SizedBox(height: 6),
            DropdownButtonFormField<String>(
              value: _category,
              decoration: const InputDecoration(isDense: true),
              items: _categories.entries.map((e) => DropdownMenuItem(
                value: e.key,
                child: Row(children: [
                  Icon(e.value.icon, size: 16, color: e.value.color),
                  const SizedBox(width: 8),
                  Text(e.value.label),
                ]),
              )).toList(),
              onChanged: (v) => setState(() => _category = v!),
            ),
            const SizedBox(height: 14),

            // Description
            const _FieldLabel('Description'),
            const SizedBox(height: 6),
            TextFormField(
              controller: _descCtrl,
              decoration: const InputDecoration(
                hintText: 'e.g. Diesel for site truck',
                prefixIcon: Icon(Iconsax.document_text, size: 18),
              ),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
            ),
            const SizedBox(height: 14),

            // Amount + GST toggle
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const _FieldLabel('Amount (\$)'),
                  const SizedBox(height: 6),
                  TextFormField(
                    controller: _amountCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      hintText: '0.00',
                      prefixIcon: Icon(Iconsax.dollar_circle, size: 18),
                    ),
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) return 'Required';
                      if (double.tryParse(v.trim()) == null) return 'Invalid';
                      if (double.parse(v.trim()) <= 0) return 'Must be > 0';
                      return null;
                    },
                  ),
                ]),
              ),
              const SizedBox(width: 12),
              Column(crossAxisAlignment: CrossAxisAlignment.center, children: [
                const _FieldLabel('GST Incl.'),
                const SizedBox(height: 6),
                Switch(
                  value: _isGSTInclusive,
                  activeColor: TradieColors.electricBlue,
                  onChanged: (v) => setState(() => _isGSTInclusive = v),
                ),
              ]),
            ]),
            const SizedBox(height: 14),

            // Date picker
            const _FieldLabel('Date'),
            const SizedBox(height: 6),
            GestureDetector(
              onTap: _pickDate,
              child: AbsorbPointer(
                child: TextFormField(
                  readOnly: true,
                  decoration: InputDecoration(
                    hintText: DateFormat('d MMM yyyy').format(_date),
                    prefixIcon: const Icon(Iconsax.calendar_1, size: 18),
                    suffixIcon: const Icon(Iconsax.arrow_right_3, size: 16, color: TradieColors.grey400),
                  ),
                  controller: TextEditingController(
                    text: DateFormat('d MMM yyyy').format(_date),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),

            // Payment method
            const _FieldLabel('Payment Method'),
            const SizedBox(height: 6),
            DropdownButtonFormField<String>(
              value: _paymentMethod,
              decoration: const InputDecoration(
                prefixIcon: Icon(Iconsax.card, size: 18),
                isDense: true,
              ),
              items: List.generate(_paymentMethods.length, (i) => DropdownMenuItem(
                value: _paymentMethods[i],
                child: Text(_paymentLabels[i]),
              )),
              onChanged: (v) => setState(() => _paymentMethod = v!),
            ),
            const SizedBox(height: 14),

            // Supplier (optional)
            const _FieldLabel('Supplier (optional)'),
            const SizedBox(height: 6),
            TextFormField(
              controller: _supplierCtrl,
              decoration: const InputDecoration(
                hintText: 'e.g. Ampol Petrol Station',
                prefixIcon: Icon(Iconsax.building_4, size: 18),
              ),
            ),
            const SizedBox(height: 14),

            // Attach receipt
            OutlinedButton.icon(
              onPressed: _attachReceipt,
              icon: Icon(
                _receiptAttached ? Iconsax.tick_circle : Iconsax.camera,
                size: 18,
                color: _receiptAttached ? TradieColors.successGreen : TradieColors.electricBlue,
              ),
              label: Text(
                _receiptAttached ? 'Receipt Attached' : 'Attach Receipt',
                style: TextStyle(
                  color: _receiptAttached ? TradieColors.successGreen : TradieColors.electricBlue,
                ),
              ),
              style: OutlinedButton.styleFrom(
                side: BorderSide(
                  color: _receiptAttached ? TradieColors.successGreen : TradieColors.electricBlue,
                ),
                minimumSize: const Size(double.infinity, 48),
              ),
            ),
            const SizedBox(height: 20),

            // Submit
            ElevatedButton.icon(
              onPressed: _submitting ? null : _submit,
              icon: _submitting
                  ? const SizedBox(
                      width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Iconsax.add, size: 18),
              label: const Text('Save Expense'),
            ),
          ]),
        ),
      ),
    );
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked != null) setState(() => _date = picked);
  }

  void _attachReceipt() {
    showModalBottomSheet(
      context: context,
      backgroundColor: TradieColors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 12),
          ListTile(
            leading: const Icon(Iconsax.camera, color: TradieColors.navy),
            title: const Text('Take Photo'),
            onTap: () {
              Navigator.pop(context);
              setState(() => _receiptAttached = true);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Camera integration coming soon')),
              );
            },
          ),
          ListTile(
            leading: const Icon(Iconsax.gallery, color: TradieColors.navy),
            title: const Text('Choose from Gallery'),
            onTap: () {
              Navigator.pop(context);
              setState(() => _receiptAttached = true);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Gallery integration coming soon')),
              );
            },
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _submitting = true);

    final data = <String, dynamic>{
      'category':        _category,
      'description':     _descCtrl.text.trim(),
      'amount':          double.parse(_amountCtrl.text.trim()),
      'date':            DateFormat('yyyy-MM-dd').format(_date),
      'is_gst_inclusive': _isGSTInclusive,
      'payment_method':  _paymentMethod,
      if (_supplierCtrl.text.trim().isNotEmpty) 'supplier': _supplierCtrl.text.trim(),
    };

    final ok = await ref.read(expenseNotifierProvider.notifier).createExpense(data);

    if (mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok ? 'Expense saved' : 'Failed to save expense'),
        backgroundColor: ok ? TradieColors.successGreen : TradieColors.alertRed,
      ));
    }
  }
}

// ── Summary sheet ─────────────────────────────────────────────

class _SummarySheet extends ConsumerWidget {
  const _SummarySheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = ref.watch(expenseSummaryProvider);

    return Container(
      decoration: const BoxDecoration(
        color: TradieColors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
      child: summary.when(
        data: (data) {
          final total    = (data['total_this_month'] as num?)?.toDouble() ?? 0.0;
          final gst      = (data['total_gst_this_month'] as num?)?.toDouble() ?? 0.0;
          final cats     = List<Map<String, dynamic>>.from(data['by_category'] as List? ?? []);
          final trend    = List<Map<String, dynamic>>.from(data['monthly_trend'] as List? ?? []);

          return SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // Handle
              Center(
                child: Container(
                  width: 40, height: 4,
                  decoration: BoxDecoration(color: TradieColors.grey200, borderRadius: BorderRadius.circular(2)),
                ),
              ),
              const SizedBox(height: 16),
              Row(children: const [
                Icon(Iconsax.chart_square, size: 20, color: TradieColors.navy),
                SizedBox(width: 8),
                Text('Expense Summary', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: TradieColors.navy)),
              ]),
              const SizedBox(height: 20),

              // This month highlight
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: TradieColors.grey50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: TradieColors.grey200),
                ),
                child: Row(children: [
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('This Month', style: TextStyle(fontSize: 12, color: TradieColors.grey600)),
                    const SizedBox(height: 4),
                    Text(_fmt.format(total), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: TradieColors.navy)),
                  ])),
                  Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    const Text('GST Claimable', style: TextStyle(fontSize: 12, color: TradieColors.grey600)),
                    const SizedBox(height: 4),
                    Text(_fmt.format(gst), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: TradieColors.successGreen)),
                  ]),
                ]),
              ),
              const SizedBox(height: 20),

              // By category
              if (cats.isNotEmpty) ...[
                const Text('By Category', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: TradieColors.navy)),
                const SizedBox(height: 10),
                ...cats.map((c) {
                  final cat   = c['category'] as String? ?? 'other';
                  final amt   = (c['total'] as num?)?.toDouble() ?? 0.0;
                  final count = (c['count'] as num?)?.toInt() ?? 0;
                  final meta  = _meta(cat);
                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: TradieColors.white,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: TradieColors.grey200),
                    ),
                    child: Row(children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: meta.color.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(meta.icon, size: 16, color: meta.color),
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(meta.label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: TradieColors.navy)),
                        Text('$count expense${count == 1 ? '' : 's'}', style: const TextStyle(fontSize: 11, color: TradieColors.grey600)),
                      ])),
                      Text(_fmt.format(amt), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: TradieColors.navy)),
                    ]),
                  );
                }),
                const SizedBox(height: 16),
              ],

              // Monthly trend
              if (trend.isNotEmpty) ...[
                const Text('Last 12 Months', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: TradieColors.navy)),
                const SizedBox(height: 10),
                ...trend.reversed.take(6).map((t) {
                  final month = t['month'] as String? ?? '';
                  final amt   = (t['total'] as num?)?.toDouble() ?? 0.0;
                  DateTime? dt;
                  if (month.length >= 7) {
                    dt = DateTime.tryParse('$month-01');
                  }
                  final label = dt != null ? DateFormat('MMM yyyy').format(dt) : month;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(children: [
                      SizedBox(width: 72, child: Text(label, style: const TextStyle(fontSize: 12, color: TradieColors.grey600))),
                      const SizedBox(width: 8),
                      Expanded(
                        child: LinearProgressIndicator(
                          value: (trend.isNotEmpty && (trend.map((x) => (x['total'] as num?)?.toDouble() ?? 0.0).reduce((a, b) => a > b ? a : b)) > 0)
                              ? amt / trend.map((x) => (x['total'] as num?)?.toDouble() ?? 0.0).reduce((a, b) => a > b ? a : b)
                              : 0.0,
                          backgroundColor: TradieColors.grey100,
                          valueColor: const AlwaysStoppedAnimation(TradieColors.electricBlue),
                          minHeight: 6,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 70,
                        child: Text(
                          _fmt.format(amt),
                          textAlign: TextAlign.right,
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: TradieColors.navy),
                        ),
                      ),
                    ]),
                  );
                }),
              ],
            ]),
          );
        },
        loading: () => const Center(child: Padding(
          padding: EdgeInsets.all(40),
          child: CircularProgressIndicator(),
        )),
        error: (e, _) => Padding(
          padding: const EdgeInsets.all(24),
          child: Text('Failed to load summary: $e', style: const TextStyle(color: TradieColors.alertRed)),
        ),
      ),
    );
  }
}

// ── Export dialog ─────────────────────────────────────────────

class _ExportDialog extends StatelessWidget {
  final List<Map<String, dynamic>> rows;
  const _ExportDialog({required this.rows});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: const [
            Icon(Iconsax.export_2, size: 20, color: TradieColors.navy),
            SizedBox(width: 8),
            Text('Accountant Export', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: TradieColors.navy)),
          ]),
          const SizedBox(height: 4),
          Text(
            '${rows.length} expense${rows.length == 1 ? '' : 's'} ready for export',
            style: const TextStyle(fontSize: 13, color: TradieColors.grey600),
          ),
          const SizedBox(height: 16),
          Container(
            constraints: const BoxConstraints(maxHeight: 320),
            decoration: BoxDecoration(
              color: TradieColors.grey50,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: TradieColors.grey200),
            ),
            child: ListView.separated(
              shrinkWrap: true,
              padding: const EdgeInsets.all(8),
              itemCount: rows.length,
              separatorBuilder: (_, __) => const Divider(height: 1, color: TradieColors.grey100),
              itemBuilder: (_, i) {
                final row = rows[i];
                final amount = (row['amount'] as num?)?.toDouble() ?? 0.0;
                final gst    = (row['gst_amount'] as num?)?.toDouble() ?? 0.0;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                  child: Row(children: [
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(
                        row['description'] as String? ?? '',
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: TradieColors.navy),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        '${row['category']} • ${row['date']}',
                        style: const TextStyle(fontSize: 11, color: TradieColors.grey600),
                      ),
                    ])),
                    const SizedBox(width: 8),
                    Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                      Text(_fmt.format(amount), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: TradieColors.navy)),
                      if (gst > 0)
                        Text('GST ${_fmt.format(gst)}', style: const TextStyle(fontSize: 10, color: TradieColors.successGreen)),
                    ]),
                  ]),
                );
              },
            ),
          ),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => Navigator.pop(context),
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
                child: const Text('Close'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: () {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('CSV download coming soon')),
                  );
                },
                icon: const Icon(Iconsax.document_download, size: 16),
                label: const Text('Download CSV'),
                style: ElevatedButton.styleFrom(minimumSize: const Size(0, 44)),
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}

// ── Small helper widget ───────────────────────────────────────

class _FieldLabel extends StatelessWidget {
  final String text;
  const _FieldLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: TradieColors.grey600,
      ),
    );
  }
}
