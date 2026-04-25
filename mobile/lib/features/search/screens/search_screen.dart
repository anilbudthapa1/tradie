import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';

import '../../../core/utils/theme.dart';
import '../providers/search_provider.dart';

// ── Route helper ──────────────────────────────────────────────
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  Timer? _debounce;
  String _query = '';
  String _activeType = 'all';

  static const _types = ['all', 'jobs', 'customers', 'invoices', 'quotes', 'workers'];
  static const _typeLabels = {
    'all': 'All',
    'jobs': 'Jobs',
    'customers': 'Customers',
    'invoices': 'Invoices',
    'quotes': 'Quotes',
    'workers': 'Workers',
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
    _controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      if (mounted) {
        setState(() => _query = _controller.text.trim());
      }
    });
  }

  // ── Type icon mapping ────────────────────────────────────────
  IconData _iconForType(String type) {
    switch (type) {
      case 'jobs':
        return Iconsax.briefcase;
      case 'customers':
        return Iconsax.people;
      case 'invoices':
        return Iconsax.receipt;
      case 'quotes':
        return Iconsax.document;
      case 'workers':
        return Iconsax.profile_circle;
      default:
        return Iconsax.search_normal;
    }
  }

  Color _colorForType(String type) {
    switch (type) {
      case 'jobs':
        return TradieColors.electricBlue;
      case 'customers':
        return TradieColors.successGreen;
      case 'invoices':
        return TradieColors.safetyOrange;
      case 'quotes':
        return const Color(0xFF7C3AED);
      case 'workers':
        return TradieColors.warningAmber;
      default:
        return TradieColors.grey400;
    }
  }

  Color _statusColor(String status) {
    switch (status.toLowerCase()) {
      case 'paid':
      case 'completed':
      case 'active':
        return TradieColors.successGreen;
      case 'overdue':
      case 'cancelled':
        return TradieColors.alertRed;
      case 'sent':
      case 'scheduled':
        return TradieColors.electricBlue;
      case 'in_progress':
        return TradieColors.safetyOrange;
      case 'draft':
        return TradieColors.grey400;
      case 'partial':
        return TradieColors.warningAmber;
      default:
        return TradieColors.grey400;
    }
  }

  void _navigateTo(Map<String, dynamic> result) {
    final type = result['type'] as String? ?? '';
    final id = result['id'] as String? ?? '';
    switch (type) {
      case 'jobs':
        context.go('/jobs/$id');
      case 'customers':
        context.go('/customers/$id');
      case 'invoices':
        context.go('/invoices/$id');
      case 'quotes':
        context.go('/quotes/$id');
      case 'workers':
        context.go('/workers/$id');
    }
  }

  // ── Skeleton loading card ────────────────────────────────────
  Widget _skeletonCard() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: TradieColors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: TradieColors.grey200),
      ),
      child: Row(children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: TradieColors.grey100,
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: 13,
                width: double.infinity,
                decoration: BoxDecoration(
                  color: TradieColors.grey100,
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
              const SizedBox(height: 8),
              Container(
                height: 11,
                width: 140,
                decoration: BoxDecoration(
                  color: TradieColors.grey100,
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
            ],
          ),
        ),
      ]),
    );
  }

  // ── Result card ──────────────────────────────────────────────
  Widget _resultCard(Map<String, dynamic> result) {
    final type = result['type'] as String? ?? '';
    final title = result['title'] as String? ?? '';
    final subtitle = result['subtitle'] as String? ?? '';
    final status = result['status'] as String? ?? '';
    final typeColor = _colorForType(type);

    return GestureDetector(
      onTap: () => _navigateTo(result),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: TradieColors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: TradieColors.grey200),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.03),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(children: [
          // Type icon badge
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: typeColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(_iconForType(type), size: 20, color: typeColor),
          ),
          const SizedBox(width: 12),

          // Title + subtitle
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: TradieColors.charcoal,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (subtitle.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 12,
                      color: TradieColors.grey400,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),

          // Status badge
          if (status.isNotEmpty) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: _statusColor(status).withOpacity(0.1),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                status.replaceAll('_', ' '),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: _statusColor(status),
                ),
              ),
            ),
          ],

          const SizedBox(width: 4),
          const Icon(Iconsax.arrow_right_3, size: 16, color: TradieColors.grey400),
        ]),
      ),
    );
  }

  // ── Section header ───────────────────────────────────────────
  Widget _sectionHeader(String type) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Row(children: [
        Icon(_iconForType(type), size: 14, color: _colorForType(type)),
        const SizedBox(width: 6),
        Text(
          _typeLabels[type] ?? type,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: _colorForType(type),
            letterSpacing: 0.5,
          ),
        ),
      ]),
    );
  }

  // ── Empty / recent searches state ────────────────────────────
  Widget _emptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: TradieColors.electricBlue.withOpacity(0.08),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Iconsax.search_normal,
              size: 32,
              color: TradieColors.electricBlue,
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Search everything',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: TradieColors.charcoal,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Jobs, customers, invoices, quotes\nand workers — all in one place.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              color: TradieColors.grey400,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  // ── No results state ─────────────────────────────────────────
  Widget _noResultsState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Iconsax.search_status, size: 48, color: TradieColors.grey200),
          const SizedBox(height: 16),
          Text(
            'No results for "$_query"',
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: TradieColors.charcoal,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Try a different search term\nor broaden your filter.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: TradieColors.grey400),
          ),
        ],
      ),
    );
  }

  // ── Build grouped results list ────────────────────────────────
  Widget _buildResults(List<Map<String, dynamic>> results) {
    if (results.isEmpty) return _noResultsState();

    // Group by type maintaining declaration order
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final r in results) {
      final t = r['type'] as String? ?? 'other';
      grouped.putIfAbsent(t, () => []).add(r);
    }

    final items = <Widget>[];
    for (final type in grouped.keys) {
      items.add(_sectionHeader(type));
      for (final result in grouped[type]!) {
        items.add(_resultCard(result));
      }
    }
    items.add(const SizedBox(height: 24));

    return ListView(children: items);
  }

  @override
  Widget build(BuildContext context) {
    final params = (query: _query, type: _activeType);
    final searchAsync = ref.watch(searchFilteredProvider(params));

    return Scaffold(
      backgroundColor: TradieColors.grey50,
      appBar: AppBar(
        backgroundColor: TradieColors.white,
        elevation: 0,
        titleSpacing: 0,
        leading: IconButton(
          icon: const Icon(Iconsax.arrow_left, color: TradieColors.charcoal),
          onPressed: () => context.pop(),
        ),
        title: Padding(
          padding: const EdgeInsets.only(right: 16),
          child: TextField(
            controller: _controller,
            focusNode: _focusNode,
            textInputAction: TextInputAction.search,
            style: const TextStyle(
              fontSize: 15,
              color: TradieColors.charcoal,
              fontWeight: FontWeight.w500,
            ),
            decoration: InputDecoration(
              hintText: 'Search jobs, customers, invoices...',
              hintStyle: const TextStyle(
                color: TradieColors.grey400,
                fontSize: 14,
                fontWeight: FontWeight.w400,
              ),
              prefixIcon: const Icon(
                Iconsax.search_normal,
                size: 18,
                color: TradieColors.grey400,
              ),
              suffixIcon: _query.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Iconsax.close_circle,
                          size: 18, color: TradieColors.grey400),
                      onPressed: () {
                        _controller.clear();
                        setState(() => _query = '');
                      },
                    )
                  : null,
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
                borderSide: const BorderSide(
                    color: TradieColors.electricBlue, width: 1.5),
              ),
              contentPadding: const EdgeInsets.symmetric(vertical: 10),
              isDense: true,
            ),
          ),
        ),
        // Category filter tabs
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(44),
          child: SizedBox(
            height: 44,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              itemCount: _types.length,
              itemBuilder: (context, i) {
                final type = _types[i];
                final isActive = _activeType == type;
                return GestureDetector(
                  onTap: () => setState(() => _activeType = type),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.only(right: 8),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                    decoration: BoxDecoration(
                      color: isActive
                          ? TradieColors.electricBlue
                          : TradieColors.grey100,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: isActive
                            ? TradieColors.electricBlue
                            : TradieColors.grey200,
                      ),
                    ),
                    child: Text(
                      _typeLabels[type]!,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: isActive
                            ? TradieColors.white
                            : TradieColors.grey600,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),

      body: _query.length < 2
          ? _emptyState()
          : searchAsync.when(
              loading: () => ListView(
                children: List.generate(5, (_) => _skeletonCard()),
              ),
              error: (e, _) => Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Iconsax.wifi_square,
                        size: 48, color: TradieColors.alertRed),
                    const SizedBox(height: 12),
                    const Text(
                      'Search failed',
                      style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: TradieColors.charcoal),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      e.toString(),
                      style: const TextStyle(
                          fontSize: 12, color: TradieColors.grey400),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
              data: _buildResults,
            ),
    );
  }
}
