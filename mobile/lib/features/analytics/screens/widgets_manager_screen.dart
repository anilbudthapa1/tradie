import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';

import '../../../core/providers/auth_provider.dart';
import '../../../core/utils/theme.dart';
import '../providers/analytics_provider.dart';

/// Module 12 — owner / manager screen to add, edit, archive and
/// reorder KPI widget tiles. Backend enforces analytics.widget_manage;
/// the UI hides the screen for workers/customers as a courtesy.
class WidgetsManagerScreen extends ConsumerStatefulWidget {
  const WidgetsManagerScreen({super.key});

  @override
  ConsumerState<WidgetsManagerScreen> createState() => _WidgetsManagerScreenState();
}

class _WidgetsManagerScreenState extends ConsumerState<WidgetsManagerScreen> {
  String _filter = 'active';

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authNotifierProvider);
    final role = (auth.asData?.value?['role']?.toString() ?? 'worker').toLowerCase();
    final canManage = const {'owner', 'admin', 'manager'}.contains(role);

    if (!canManage) return _ForbiddenView();

    final widgetsAsync = ref.watch(analyticsWidgetsProvider(_filter == 'all' ? '' : _filter));

    return Scaffold(
      backgroundColor: TradieColors.white,
      appBar: AppBar(
        title: const Text('KPI widgets'),
        backgroundColor: TradieColors.white,
        elevation: 0,
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Iconsax.filter, color: TradieColors.charcoal),
            onSelected: (v) => setState(() => _filter = v),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'active', child: Text('Active')),
              PopupMenuItem(value: 'archived', child: Text('Archived')),
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
        label: const Text('New widget'),
      ),
      body: RefreshIndicator(
        color: TradieColors.electricBlue,
        onRefresh: () async => ref.invalidate(analyticsWidgetsProvider),
        child: widgetsAsync.when(
          loading: () => const Center(child: CircularProgressIndicator(color: TradieColors.electricBlue)),
          error: (e, _) => _ErrorView(message: e.toString(), onRetry: () => ref.invalidate(analyticsWidgetsProvider)),
          data: (list) {
            if (list.isEmpty) return const _EmptyView();
            return ReorderableListView.builder(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 96),
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: list.length,
              onReorder: (oldIndex, newIndex) async {
                if (newIndex > oldIndex) newIndex -= 1;
                final reordered = List<dynamic>.from(list);
                final item = reordered.removeAt(oldIndex);
                reordered.insert(newIndex, item);
                final ids = reordered.map((w) => w['id'] as String).toList();
                await ref.read(analyticsWidgetNotifierProvider.notifier).reorder(ids);
              },
              itemBuilder: (_, i) {
                final w = list[i] as Map<String, dynamic>;
                return Padding(
                  key: ValueKey(w['id']),
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _WidgetRow(
                    widget: w,
                    onArchive: () => _runMutation(
                      () => ref.read(analyticsWidgetNotifierProvider.notifier).archive(w['id'] as String),
                      success: 'Archived',
                    ),
                    onRestore: () => _runMutation(
                      () => ref.read(analyticsWidgetNotifierProvider.notifier).restore(w['id'] as String),
                      success: 'Restored',
                    ),
                    onDelete: () => _confirmDelete(context, w['id'] as String),
                  ),
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
        title: const Text('Delete widget?'),
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
    final ok = await ref.read(analyticsWidgetNotifierProvider.notifier).delete(id);
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
      builder: (_) => const _CreateWidgetSheet(),
    );
  }
}

// ── List row ────────────────────────────────────────────────────

class _WidgetRow extends StatelessWidget {
  final Map<String, dynamic> widget;
  final VoidCallback onArchive;
  final VoidCallback onRestore;
  final VoidCallback onDelete;

  const _WidgetRow({
    required this.widget,
    required this.onArchive,
    required this.onRestore,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final status = widget['status']?.toString() ?? 'active';
    final isActive = status == 'active';

    return Container(
      decoration: BoxDecoration(
        color: TradieColors.white,
        border: Border.all(color: TradieColors.grey200),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 36, height: 36,
              decoration: BoxDecoration(
                color: TradieColors.electricBlue.withOpacity(0.10),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(_iconFor(widget['icon_token']?.toString() ?? 'chart_2'),
                  size: 18, color: TradieColors.electricBlue),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget['title']?.toString() ?? '',
                    style: const TextStyle(
                      color: TradieColors.charcoal,
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${widget['metric_key']} · ${widget['period']}',
                    style: const TextStyle(color: TradieColors.grey600, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: TradieColors.grey50,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(status,
                  style: const TextStyle(color: TradieColors.grey600, fontSize: 11, fontWeight: FontWeight.w500)),
            ),
            PopupMenuButton<String>(
              icon: const Icon(Iconsax.more, color: TradieColors.grey400),
              onSelected: (v) {
                if (v == 'archive') onArchive();
                if (v == 'restore') onRestore();
                if (v == 'delete') onDelete();
              },
              itemBuilder: (_) => [
                if (isActive) const PopupMenuItem(value: 'archive', child: Text('Archive')),
                if (!isActive) const PopupMenuItem(value: 'restore', child: Text('Restore')),
                const PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  IconData _iconFor(String token) => switch (token) {
        'dollar_circle' => Iconsax.dollar_circle,
        'briefcase' => Iconsax.briefcase,
        'document_text' => Iconsax.document_text,
        'receipt' => Iconsax.receipt,
        'wallet' => Iconsax.wallet,
        'health' => Iconsax.health,
        'warning_2' => Iconsax.warning_2,
        'people' => Iconsax.people,
        _ => Iconsax.chart_2,
      };
}

// ── Create sheet ────────────────────────────────────────────────

class _CreateWidgetSheet extends ConsumerStatefulWidget {
  const _CreateWidgetSheet();

  @override
  ConsumerState<_CreateWidgetSheet> createState() => _CreateWidgetSheetState();
}

class _CreateWidgetSheetState extends ConsumerState<_CreateWidgetSheet> {
  final _title = TextEditingController();
  String? _metricKey;
  String _period = 'month';
  String _color = 'blue';
  String _icon = 'chart_2';
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets;
    final catalog = ref.watch(analyticsCatalogProvider);

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, viewInsets.bottom + 20),
      child: catalog.when(
        loading: () => const Padding(
          padding: EdgeInsets.all(40),
          child: Center(child: CircularProgressIndicator(color: TradieColors.electricBlue)),
        ),
        error: (e, _) => Padding(
          padding: const EdgeInsets.all(24),
          child: Text('Could not load metrics: $e', style: const TextStyle(color: TradieColors.alertRed)),
        ),
        data: (metrics) {
          if (_metricKey == null && metrics.isNotEmpty) {
            _metricKey = metrics.first['key'] as String;
          }

          return Column(
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
              const Text('New KPI widget',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              const SizedBox(height: 16),
              TextField(
                controller: _title,
                decoration: const InputDecoration(labelText: 'Title', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: _metricKey,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Metric', border: OutlineInputBorder()),
                items: metrics
                    .map((m) => DropdownMenuItem<String>(
                          value: m['key'] as String,
                          child: Text('${m['label']} (${m['category']})',
                              overflow: TextOverflow.ellipsis),
                        ))
                    .toList(),
                onChanged: (v) => setState(() => _metricKey = v),
              ),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _period,
                    decoration: const InputDecoration(labelText: 'Period', border: OutlineInputBorder()),
                    items: const [
                      DropdownMenuItem(value: 'today', child: Text('Today')),
                      DropdownMenuItem(value: 'week', child: Text('Week')),
                      DropdownMenuItem(value: 'month', child: Text('Month')),
                      DropdownMenuItem(value: 'quarter', child: Text('Quarter')),
                      DropdownMenuItem(value: 'year', child: Text('Year')),
                    ],
                    onChanged: (v) => setState(() => _period = v ?? 'month'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _color,
                    decoration: const InputDecoration(labelText: 'Colour', border: OutlineInputBorder()),
                    items: const [
                      DropdownMenuItem(value: 'blue', child: Text('Blue')),
                      DropdownMenuItem(value: 'green', child: Text('Green')),
                      DropdownMenuItem(value: 'red', child: Text('Red')),
                      DropdownMenuItem(value: 'navy', child: Text('Navy')),
                      DropdownMenuItem(value: 'grey', child: Text('Grey')),
                    ],
                    onChanged: (v) => setState(() => _color = v ?? 'blue'),
                  ),
                ),
              ]),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: _icon,
                decoration: const InputDecoration(labelText: 'Icon', border: OutlineInputBorder()),
                items: const [
                  DropdownMenuItem(value: 'chart_2', child: Text('Chart')),
                  DropdownMenuItem(value: 'dollar_circle', child: Text('Dollar')),
                  DropdownMenuItem(value: 'briefcase', child: Text('Briefcase')),
                  DropdownMenuItem(value: 'document_text', child: Text('Document')),
                  DropdownMenuItem(value: 'receipt', child: Text('Receipt')),
                  DropdownMenuItem(value: 'wallet', child: Text('Wallet')),
                  DropdownMenuItem(value: 'health', child: Text('Health')),
                  DropdownMenuItem(value: 'warning_2', child: Text('Warning')),
                  DropdownMenuItem(value: 'people', child: Text('People')),
                ],
                onChanged: (v) => setState(() => _icon = v ?? 'chart_2'),
              ),
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
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Create'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _submit() async {
    if (_title.text.trim().isEmpty) {
      setState(() => _error = 'Title is required');
      return;
    }
    if (_metricKey == null) {
      setState(() => _error = 'Pick a metric');
      return;
    }
    setState(() { _busy = true; _error = null; });
    final err = await ref.read(analyticsWidgetNotifierProvider.notifier).create({
      'title': _title.text.trim(),
      'metric_key': _metricKey,
      'period': _period,
      'color_token': _color,
      'icon_token': _icon,
    });
    if (!mounted) return;
    if (err != null) {
      setState(() { _busy = false; _error = err; });
      return;
    }
    Navigator.of(context).pop();
  }
}

// ── Empty / Error / Forbidden ───────────────────────────────────

class _EmptyView extends StatelessWidget {
  const _EmptyView();
  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: const [
        SizedBox(height: 120),
        Icon(Iconsax.chart_2, size: 56, color: TradieColors.grey400),
        SizedBox(height: 16),
        Center(
          child: Text(
            'No widgets yet',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: TradieColors.charcoal),
          ),
        ),
        SizedBox(height: 6),
        Center(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              'Create a KPI tile to track revenue, jobs, quotes, invoices or safety on your dashboard.',
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
            'Could not load widgets',
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
        Center(child: OutlinedButton(onPressed: onRetry, child: const Text('Retry'))),
      ],
    );
  }
}

class _ForbiddenView extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('KPI widgets')),
      body: const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            "You don't have permission to manage widgets.",
            textAlign: TextAlign.center,
            style: TextStyle(color: TradieColors.grey600),
          ),
        ),
      ),
    );
  }
}
