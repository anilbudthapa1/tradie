import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';
import 'package:intl/intl.dart';

import '../../../core/utils/theme.dart';
import '../providers/quotes_provider.dart';

class QuotesListScreen extends ConsumerStatefulWidget {
  const QuotesListScreen({super.key});

  @override
  ConsumerState<QuotesListScreen> createState() => _QuotesListScreenState();
}

class _QuotesListScreenState extends ConsumerState<QuotesListScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tab;
  final _searchCtrl = TextEditingController();
  String _searchQuery = '';

  static const _statuses = [null, 'draft', 'sent', 'approved', 'expired'];
  static const _labels = ['All', 'Draft', 'Sent', 'Approved', 'Expired'];

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: _statuses.length, vsync: this);
    _searchCtrl.addListener(() {
      setState(() => _searchQuery = _searchCtrl.text.toLowerCase());
    });
  }

  @override
  void dispose() {
    _tab.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TradieColors.grey50,
      appBar: AppBar(
        backgroundColor: TradieColors.white,
        elevation: 0,
        title: Row(children: [
          const Icon(Iconsax.document, size: 20, color: TradieColors.navy),
          const SizedBox(width: 8),
          const Text('Quotes',
              style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: TradieColors.navy)),
        ]),
        actions: [
          IconButton(
            icon: const Icon(Iconsax.add_circle, color: TradieColors.electricBlue),
            onPressed: () => _showCreateSheet(context),
            tooltip: 'New Quote',
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(96),
          child: Column(children: [
            // Search bar
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                controller: _searchCtrl,
                decoration: InputDecoration(
                  hintText: 'Search quotes...',
                  hintStyle: const TextStyle(fontSize: 14, color: TradieColors.grey400),
                  prefixIcon:
                      const Icon(Iconsax.search_normal, size: 18, color: TradieColors.grey400),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Iconsax.close_circle, size: 18, color: TradieColors.grey400),
                          onPressed: () {
                            _searchCtrl.clear();
                            setState(() => _searchQuery = '');
                          },
                        )
                      : null,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  filled: true,
                  fillColor: TradieColors.grey50,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: TradieColors.grey200),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: TradieColors.grey200),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: TradieColors.electricBlue),
                  ),
                ),
              ),
            ),
            // Status tabs
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
            .map((s) => _QuotesList(status: s, searchQuery: _searchQuery))
            .toList(),
      ),
    );
  }

  void _showCreateSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _CreateQuoteSheet(),
    );
  }
}

// ── Quotes list per tab ───────────────────────────────────────
class _QuotesList extends ConsumerWidget {
  final String? status;
  final String searchQuery;
  const _QuotesList({this.status, required this.searchQuery});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final quotesAsync = ref.watch(quotesProvider(status));

    return quotesAsync.when(
      data: (all) {
        final list = searchQuery.isEmpty
            ? all
            : all.where((q) {
                final num = (q['quote_number'] as String? ?? '').toLowerCase();
                final title = (q['title'] as String? ?? '').toLowerCase();
                final customer = (q['customer_name'] as String? ?? '').toLowerCase();
                return num.contains(searchQuery) ||
                    title.contains(searchQuery) ||
                    customer.contains(searchQuery);
              }).toList();

        if (list.isEmpty) return _EmptyState(status: status, isSearch: searchQuery.isNotEmpty);

        return RefreshIndicator(
          color: TradieColors.electricBlue,
          onRefresh: () => ref.refresh(quotesProvider(status).future),
          child: ListView.builder(
            padding: const EdgeInsets.only(top: 8, bottom: 100),
            itemCount: list.length,
            itemBuilder: (ctx, i) {
              final q = list[i];
              final qStatus = q['status'] as String? ?? 'draft';
              return _QuoteCard(
                quote: q,
                onTap: () => ctx.go('/quotes/${q['id']}'),
                onSend: qStatus == 'draft'
                    ? () => _handleSend(context, ref, q['id'] as String)
                    : null,
              );
            },
          ),
        );
      },
      loading: () => ListView.builder(
        itemCount: 5,
        padding: const EdgeInsets.only(top: 8),
        itemBuilder: (_, __) => const _QuoteCardSkeleton(),
      ),
      error: (e, _) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Iconsax.warning_2, size: 40, color: TradieColors.alertRed),
          const SizedBox(height: 12),
          const Text('Failed to load quotes',
              style: TextStyle(color: TradieColors.navy, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => ref.refresh(quotesProvider(status).future),
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
        title: const Text('Send Quote'),
        content: const Text('This will mark the quote as sent and share it with the customer. Continue?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: TradieColors.electricBlue,
              minimumSize: Size.zero,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            ),
            child: const Text('Send'),
          ),
        ],
      ),
    );
    if (confirm != true || !context.mounted) return;

    final ok = await ref.read(quoteNotifierProvider.notifier).sendQuote(id);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok ? 'Quote sent' : 'Failed to send quote'),
        backgroundColor: ok ? TradieColors.successGreen : TradieColors.alertRed,
      ));
    }
  }
}

// ── Quote card ────────────────────────────────────────────────
class _QuoteCard extends StatelessWidget {
  final Map<String, dynamic> quote;
  final VoidCallback onTap;
  final VoidCallback? onSend;

  const _QuoteCard({required this.quote, required this.onTap, this.onSend});

  @override
  Widget build(BuildContext context) {
    final status = quote['status'] as String? ?? 'draft';
    final total = (quote['total'] as num?)?.toDouble() ?? 0.0;
    final createdAt = quote['created_at'] != null
        ? DateTime.tryParse(quote['created_at'] as String)
        : null;
    final fmt = NumberFormat.currency(locale: 'en_AU', symbol: r'$');
    final statusColor = _quoteStatusColor(status);

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
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // Icon bubble
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: TradieColors.electricBlue.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Iconsax.document_text, size: 18, color: TradieColors.electricBlue),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(
                    quote['quote_number'] as String? ?? '',
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 14, color: TradieColors.navy),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    quote['customer_name'] as String? ?? 'Unknown customer',
                    style: const TextStyle(fontSize: 13, color: TradieColors.grey600),
                  ),
                  if ((quote['title'] as String? ?? '').isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        quote['title'] as String,
                        style: const TextStyle(fontSize: 12, color: TradieColors.grey400),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ]),
              ),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(
                  fmt.format(total),
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 16, color: TradieColors.navy),
                ),
                const SizedBox(height: 4),
                _StatusBadge(status: status, color: statusColor),
              ]),
            ]),
            if (createdAt != null) ...[
              const SizedBox(height: 10),
              const Divider(height: 1, color: TradieColors.grey100),
              const SizedBox(height: 8),
              Row(children: [
                const Icon(Iconsax.calendar_1, size: 12, color: TradieColors.grey400),
                const SizedBox(width: 4),
                Text(
                  DateFormat('d MMM yyyy').format(createdAt),
                  style: const TextStyle(fontSize: 12, color: TradieColors.grey400),
                ),
                const Spacer(),
                if (onSend != null)
                  Row(children: [
                    const Icon(Iconsax.send_2, size: 12, color: TradieColors.electricBlue),
                    const SizedBox(width: 4),
                    const Text('Swipe to send',
                        style: TextStyle(fontSize: 11, color: TradieColors.electricBlue)),
                  ]),
              ]),
            ],
          ]),
        ),
      ),
    );

    // Swipe right to send draft quotes
    if (onSend != null) {
      return Dismissible(
        key: Key('quote-${quote['id']}'),
        direction: DismissDirection.startToEnd,
        confirmDismiss: (_) async {
          onSend!();
          return false; // don't remove from list, just trigger action
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
            Text('Send Quote',
                style: TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14)),
          ]),
        ),
        child: card,
      );
    }
    return card;
  }
}

// ── Status badge ──────────────────────────────────────────────
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
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }
}

// ── Empty state ───────────────────────────────────────────────
class _EmptyState extends StatelessWidget {
  final String? status;
  final bool isSearch;
  const _EmptyState({this.status, required this.isSearch});

  @override
  Widget build(BuildContext context) {
    final label = isSearch
        ? 'No quotes match your search'
        : status == null
            ? 'No quotes yet'
            : 'No ${status!} quotes';
    final sub = isSearch
        ? 'Try a different search term'
        : 'Create a quote to start winning jobs';

    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          padding: const EdgeInsets.all(24),
          decoration: const BoxDecoration(
              color: TradieColors.grey100, shape: BoxShape.circle),
          child: const Icon(Iconsax.document, size: 48, color: TradieColors.grey400),
        ),
        const SizedBox(height: 16),
        Text(label,
            style: const TextStyle(
                fontSize: 18, fontWeight: FontWeight.w600, color: TradieColors.navy)),
        const SizedBox(height: 8),
        Text(sub, style: const TextStyle(color: TradieColors.grey600)),
      ]),
    );
  }
}

// ── Skeleton ──────────────────────────────────────────────────
class _QuoteCardSkeleton extends StatelessWidget {
  const _QuoteCardSkeleton();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      height: 100,
      decoration: BoxDecoration(
        color: TradieColors.grey100,
        borderRadius: BorderRadius.circular(12),
      ),
    );
  }
}

// ── Create quote bottom sheet ─────────────────────────────────
class _CreateQuoteSheet extends ConsumerStatefulWidget {
  const _CreateQuoteSheet();

  @override
  ConsumerState<_CreateQuoteSheet> createState() => _CreateQuoteSheetState();
}

class _CreateQuoteSheetState extends ConsumerState<_CreateQuoteSheet> {
  final _customerCtrl = TextEditingController();
  final _titleCtrl = TextEditingController();
  final _validUntilCtrl = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _customerCtrl.dispose();
    _titleCtrl.dispose();
    _validUntilCtrl.dispose();
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
      child:
          Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Handle bar
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
          const Icon(Iconsax.document, size: 20, color: TradieColors.navy),
          const SizedBox(width: 8),
          const Text('New Quote',
              style: TextStyle(
                  fontSize: 18, fontWeight: FontWeight.w700, color: TradieColors.navy)),
        ]),
        const SizedBox(height: 20),
        TextField(
          controller: _customerCtrl,
          decoration: const InputDecoration(
            labelText: 'Customer ID',
            hintText: 'Enter customer ID',
            prefixIcon: Icon(Iconsax.user, size: 18),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _titleCtrl,
          decoration: const InputDecoration(
            labelText: 'Quote Title',
            hintText: 'e.g. Kitchen renovation quote',
            prefixIcon: Icon(Iconsax.document_text, size: 18),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _validUntilCtrl,
          decoration: const InputDecoration(
            labelText: 'Valid Until (YYYY-MM-DD)',
            hintText: 'Optional expiry date',
            prefixIcon: Icon(Iconsax.calendar_1, size: 18),
          ),
          keyboardType: TextInputType.datetime,
          onTap: () async {
            final picked = await showDatePicker(
              context: context,
              initialDate: DateTime.now().add(const Duration(days: 30)),
              firstDate: DateTime.now(),
              lastDate: DateTime.now().add(const Duration(days: 365)),
            );
            if (picked != null) {
              _validUntilCtrl.text = picked.toIso8601String().substring(0, 10);
            }
          },
          readOnly: true,
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
                : const Icon(Iconsax.add, size: 18),
            label: const Text('Create Quote'),
            style: ElevatedButton.styleFrom(
              backgroundColor: TradieColors.electricBlue,
              minimumSize: const Size(0, 48),
            ),
          ),
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
    if (_titleCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Quote title is required')),
      );
      return;
    }
    setState(() => _submitting = true);
    final ok = await ref.read(quoteNotifierProvider.notifier).createQuote(
          customerId: _customerCtrl.text.trim(),
          title: _titleCtrl.text.trim(),
          validUntil:
              _validUntilCtrl.text.isNotEmpty ? _validUntilCtrl.text.trim() : null,
        );
    if (mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok ? 'Quote created' : 'Failed to create quote'),
        backgroundColor: ok ? TradieColors.successGreen : TradieColors.alertRed,
      ));
    }
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
      return const Color(0xFF7C3AED); // purple
    default:
      return TradieColors.grey400;
  }
}
