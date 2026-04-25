import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';

import '../providers/safety_provider.dart';

// ── Brand colours ──────────────────────────────────────────────
const _navy = Color(0xFF1A2332);
const _blue = Color(0xFF2563EB);
const _orange = Color(0xFFF97316); // safety accent
const _green = Color(0xFF16A34A);
const _red = Color(0xFFDC2626);
const _amber = Color(0xFFF59E0B);
const _grey = Color(0xFFF1F5F9);
const _cardRadius = BorderRadius.all(Radius.circular(12));

// ══════════════════════════════════════════════════════════════
// ROOT SCREEN
// ══════════════════════════════════════════════════════════════

class SafetyScreen extends StatelessWidget {
  const SafetyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        backgroundColor: _grey,
        appBar: AppBar(
          backgroundColor: _navy,
          foregroundColor: Colors.white,
          elevation: 0,
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: _orange.withOpacity(0.18),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Iconsax.shield_tick, color: _orange, size: 20),
              ),
              const SizedBox(width: 10),
              const Text(
                'Safety & WorkSafe',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 18,
                  letterSpacing: -0.3,
                ),
              ),
            ],
          ),
          bottom: const TabBar(
            isScrollable: false,
            indicatorColor: _orange,
            indicatorWeight: 3,
            labelColor: _orange,
            unselectedLabelColor: Colors.white54,
            labelStyle: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
            unselectedLabelStyle: TextStyle(fontSize: 11),
            tabs: [
              Tab(icon: Icon(Iconsax.clipboard_tick, size: 18), text: 'Checklists'),
              Tab(icon: Icon(Iconsax.document_text, size: 18), text: 'SWMS'),
              Tab(icon: Icon(Iconsax.warning_2, size: 18), text: 'Incidents'),
              Tab(icon: Icon(Iconsax.shield_tick, size: 18), text: 'Compliance'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            _ChecklistsTab(),
            _SWMSTab(),
            _IncidentsTab(),
            _ComplianceTab(),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════
// TAB 1 — CHECKLISTS
// ══════════════════════════════════════════════════════════════

class _ChecklistsTab extends ConsumerStatefulWidget {
  const _ChecklistsTab();

  @override
  ConsumerState<_ChecklistsTab> createState() => _ChecklistsTabState();
}

class _ChecklistsTabState extends ConsumerState<_ChecklistsTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(safetyNotifierProvider.notifier).loadChecklists();
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final state = ref.watch(safetyNotifierProvider);

    return Scaffold(
      backgroundColor: _grey,
      body: state.loading && state.checklists.isEmpty
          ? const Center(child: CircularProgressIndicator(color: _orange))
          : state.checklists.isEmpty
              ? _EmptyState(
                  icon: Iconsax.clipboard_tick,
                  label: 'No checklists yet',
                  sub: 'Tap + to create a safety checklist',
                )
              : RefreshIndicator(
                  color: _orange,
                  onRefresh: () =>
                      ref.read(safetyNotifierProvider.notifier).loadChecklists(),
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: state.checklists.length,
                    itemBuilder: (ctx, i) =>
                        _ChecklistCard(item: state.checklists[i]),
                  ),
                ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: _orange,
        foregroundColor: Colors.white,
        onPressed: () => _showCreateChecklistSheet(context),
        child: const Icon(Iconsax.add),
      ),
    );
  }

  void _showCreateChecklistSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _CreateChecklistSheet(),
    );
  }
}

class _ChecklistCard extends ConsumerWidget {
  final Map<String, dynamic> item;
  const _ChecklistCard({required this.item});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = item['status'] as String? ?? 'pending';
    final isPending = status == 'pending';
    final statusColor = isPending ? _orange : _green;
    final items = (item['items'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final totalItems = items.length;
    final checkedItems = items.where((it) => it['checked'] == true).length;
    final pct = totalItems > 0 ? (checkedItems / totalItems * 100).round() : 0;

    return GestureDetector(
      onTap: () => _openDetail(context, item),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: _cardRadius,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Left accent bar
            Container(
              decoration: BoxDecoration(
                border: Border(left: BorderSide(color: statusColor, width: 4)),
                borderRadius:
                    const BorderRadius.horizontal(left: Radius.circular(12)),
              ),
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item['title'] as String? ?? 'Untitled',
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                            color: _navy,
                          ),
                        ),
                        if (item['job_id'] != null) ...[
                          const SizedBox(height: 3),
                          Row(
                            children: [
                              const Icon(Iconsax.briefcase, size: 12, color: Colors.grey),
                              const SizedBox(width: 4),
                              Text(
                                'Linked to job',
                                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: statusColor.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      status.toUpperCase(),
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: statusColor,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 14, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '$checkedItems / $totalItems items',
                        style: const TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                      Text(
                        '$pct%',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: statusColor,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: totalItems > 0 ? checkedItems / totalItems : 0,
                      backgroundColor: _grey,
                      color: statusColor,
                      minHeight: 6,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openDetail(BuildContext context, Map<String, dynamic> item) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ChecklistDetailSheet(checklist: item),
    );
  }
}

class _ChecklistDetailSheet extends ConsumerStatefulWidget {
  final Map<String, dynamic> checklist;
  const _ChecklistDetailSheet({required this.checklist});

  @override
  ConsumerState<_ChecklistDetailSheet> createState() =>
      _ChecklistDetailSheetState();
}

class _ChecklistDetailSheetState extends ConsumerState<_ChecklistDetailSheet> {
  late List<Map<String, dynamic>> _items;
  bool _signing = false;

  @override
  void initState() {
    super.initState();
    final raw = widget.checklist['items'] as List? ?? [];
    _items = raw.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  @override
  Widget build(BuildContext context) {
    final status = widget.checklist['status'] as String? ?? 'pending';
    final isCompleted = status == 'completed';

    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      minChildSize: 0.5,
      builder: (ctx, controller) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            const _SheetHandle(),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: Row(
                children: [
                  const Icon(Iconsax.clipboard_tick, color: _orange, size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      widget.checklist['title'] as String? ?? 'Checklist',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: _navy,
                      ),
                    ),
                  ),
                  if (isCompleted)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: _green.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Text(
                        'COMPLETED',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: _green,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                controller: controller,
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: _items.length,
                itemBuilder: (ctx, i) {
                  final it = _items[i];
                  final checked = it['checked'] as bool? ?? false;
                  return CheckboxListTile(
                    value: checked,
                    activeColor: _orange,
                    onChanged: isCompleted
                        ? null
                        : (val) => setState(() => _items[i] = {...it, 'checked': val ?? false}),
                    title: Text(
                      it['description'] as String? ?? it['item'] as String? ?? '',
                      style: TextStyle(
                        fontSize: 14,
                        color: checked ? Colors.grey : _navy,
                        decoration: checked ? TextDecoration.lineThrough : null,
                      ),
                    ),
                    subtitle: (it['is_required'] as bool? ?? false)
                        ? const Text(
                            'Required',
                            style: TextStyle(fontSize: 11, color: _red),
                          )
                        : null,
                    controlAffinity: ListTileControlAffinity.leading,
                  );
                },
              ),
            ),
            if (!isCompleted)
              Padding(
                padding: EdgeInsets.fromLTRB(
                    20, 12, 20, MediaQuery.of(context).viewInsets.bottom + 24),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _orange,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: _signing ? null : _completeAndSign,
                    icon: _signing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Iconsax.pen_add),
                    label: const Text(
                      'Complete & Sign',
                      style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _completeAndSign() async {
    setState(() => _signing = true);
    final id = widget.checklist['id'] as String;
    // In production, capture an actual signature pad widget here.
    final sig = {
      'signer_name': 'Worker',
      'signed_at': DateTime.now().toIso8601String(),
      'data_url': '',
    };
    final ok = await ref
        .read(safetyNotifierProvider.notifier)
        .completeChecklist(id, sig);
    if (mounted) {
      setState(() => _signing = false);
      if (ok) Navigator.pop(context);
    }
  }
}

class _CreateChecklistSheet extends ConsumerStatefulWidget {
  const _CreateChecklistSheet();

  @override
  ConsumerState<_CreateChecklistSheet> createState() =>
      _CreateChecklistSheetState();
}

class _CreateChecklistSheetState extends ConsumerState<_CreateChecklistSheet> {
  final _titleCtrl = TextEditingController();
  final _items = <String>[''];
  bool _saving = false;

  @override
  void dispose() {
    _titleCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SheetHandle(),
            const SizedBox(height: 8),
            const Text(
              'New Safety Checklist',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: _navy),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _titleCtrl,
              decoration: _inputDecoration('Checklist Title', Iconsax.clipboard_tick),
            ),
            const SizedBox(height: 16),
            const Text(
              'Items',
              style: TextStyle(fontWeight: FontWeight.w700, color: _navy, fontSize: 14),
            ),
            const SizedBox(height: 8),
            ...List.generate(_items.length, (i) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        initialValue: _items[i],
                        onChanged: (v) => _items[i] = v,
                        decoration: _inputDecoration('Item ${i + 1}', Iconsax.tick_circle),
                      ),
                    ),
                    if (_items.length > 1)
                      IconButton(
                        icon: const Icon(Iconsax.trash, color: _red, size: 18),
                        onPressed: () => setState(() => _items.removeAt(i)),
                      ),
                  ],
                ),
              );
            }),
            TextButton.icon(
              onPressed: () => setState(() => _items.add('')),
              icon: const Icon(Iconsax.add, size: 16, color: _orange),
              label: const Text('Add item', style: TextStyle(color: _orange)),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _orange,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('Create Checklist',
                        style: TextStyle(fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    if (_titleCtrl.text.trim().isEmpty) return;
    setState(() => _saving = true);
    final items = _items
        .where((it) => it.trim().isNotEmpty)
        .map((it) => {'description': it.trim(), 'is_required': false})
        .toList();
    await ref.read(safetyNotifierProvider.notifier).createChecklist({
      'title': _titleCtrl.text.trim(),
      'items': items,
    });
    if (mounted) {
      setState(() => _saving = false);
      Navigator.pop(context);
    }
  }
}

// ══════════════════════════════════════════════════════════════
// TAB 2 — SWMS
// ══════════════════════════════════════════════════════════════

class _SWMSTab extends ConsumerStatefulWidget {
  const _SWMSTab();

  @override
  ConsumerState<_SWMSTab> createState() => _SWMSTabState();
}

class _SWMSTabState extends ConsumerState<_SWMSTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(safetyNotifierProvider.notifier).loadSWMS();
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final state = ref.watch(safetyNotifierProvider);

    return Scaffold(
      backgroundColor: _grey,
      body: state.loading && state.swmsList.isEmpty
          ? const Center(child: CircularProgressIndicator(color: _orange))
          : state.swmsList.isEmpty
              ? _EmptyState(
                  icon: Iconsax.document_text,
                  label: 'No SWMS documents',
                  sub: 'Tap + to create a Safe Work Method Statement',
                )
              : RefreshIndicator(
                  color: _orange,
                  onRefresh: () =>
                      ref.read(safetyNotifierProvider.notifier).loadSWMS(),
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: state.swmsList.length,
                    itemBuilder: (ctx, i) => _SWMSCard(item: state.swmsList[i]),
                  ),
                ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: _orange,
        foregroundColor: Colors.white,
        onPressed: () => _showCreateSWMSSheet(context),
        child: const Icon(Iconsax.add),
      ),
    );
  }

  void _showCreateSWMSSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _CreateSWMSSheet(),
    );
  }
}

class _SWMSCard extends StatelessWidget {
  final Map<String, dynamic> item;
  const _SWMSCard({required this.item});

  @override
  Widget build(BuildContext context) {
    final status = item['status'] as String? ?? 'draft';
    final statusColor = status == 'approved' ? _green : _orange;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: _cardRadius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Iconsax.document_text, color: _orange, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    item['title'] as String? ?? 'Untitled SWMS',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                      color: _navy,
                    ),
                  ),
                ),
                _StatusBadge(label: status.toUpperCase(), color: statusColor),
              ],
            ),
            const SizedBox(height: 10),
            _InfoRow(icon: Iconsax.briefcase, text: item['job_type'] as String? ?? '—'),
            const SizedBox(height: 4),
            _InfoRow(
              icon: Iconsax.user,
              text: item['responsible_person'] as String? ?? '—',
            ),
            if (item['review_date'] != null) ...[
              const SizedBox(height: 4),
              _InfoRow(
                icon: Iconsax.calendar_1,
                text: 'Review: ${item['review_date']}',
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CreateSWMSSheet extends ConsumerStatefulWidget {
  const _CreateSWMSSheet();

  @override
  ConsumerState<_CreateSWMSSheet> createState() => _CreateSWMSSheetState();
}

class _CreateSWMSSheetState extends ConsumerState<_CreateSWMSSheet> {
  final _titleCtrl = TextEditingController();
  final _jobTypeCtrl = TextEditingController();
  final _responsibleCtrl = TextEditingController();
  final _reviewDateCtrl = TextEditingController();
  final _highRiskCtrl = TextEditingController();
  final _controlsCtrl = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [
      _titleCtrl, _jobTypeCtrl, _responsibleCtrl, _reviewDateCtrl,
      _highRiskCtrl, _controlsCtrl,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.all(20),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _SheetHandle(),
              const SizedBox(height: 8),
              const Text(
                'New SWMS Document',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: _navy),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _titleCtrl,
                decoration: _inputDecoration('Document Title', Iconsax.document_text),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _jobTypeCtrl,
                decoration: _inputDecoration('Job Type (e.g. Roofing)', Iconsax.briefcase),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _responsibleCtrl,
                decoration: _inputDecoration('Responsible Person', Iconsax.user),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _reviewDateCtrl,
                decoration: _inputDecoration('Review Date (YYYY-MM-DD)', Iconsax.calendar_1),
                keyboardType: TextInputType.datetime,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _highRiskCtrl,
                maxLines: 3,
                decoration: _inputDecoration(
                  'High-Risk Activities (one per line)',
                  Iconsax.warning_2,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _controlsCtrl,
                maxLines: 3,
                decoration: _inputDecoration(
                  'Control Measures (one per line)',
                  Iconsax.shield_tick,
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _orange,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('Create SWMS',
                          style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _save() async {
    if (_titleCtrl.text.trim().isEmpty || _responsibleCtrl.text.trim().isEmpty) return;
    setState(() => _saving = true);

    final highRisk = _highRiskCtrl.text
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .map((l) => {'activity': l.trim()})
        .toList();

    final controls = _controlsCtrl.text
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .map((l) => {'control': l.trim(), 'responsible': _responsibleCtrl.text.trim()})
        .toList();

    await ref.read(safetyNotifierProvider.notifier).createSWMS({
      'title': _titleCtrl.text.trim(),
      'job_type': _jobTypeCtrl.text.trim(),
      'responsible_person': _responsibleCtrl.text.trim(),
      if (_reviewDateCtrl.text.trim().isNotEmpty)
        'review_date': _reviewDateCtrl.text.trim(),
      'high_risk_activities': highRisk,
      'control_measures': controls,
    });
    if (mounted) {
      setState(() => _saving = false);
      Navigator.pop(context);
    }
  }
}

// ══════════════════════════════════════════════════════════════
// TAB 3 — INCIDENTS
// ══════════════════════════════════════════════════════════════

class _IncidentsTab extends ConsumerStatefulWidget {
  const _IncidentsTab();

  @override
  ConsumerState<_IncidentsTab> createState() => _IncidentsTabState();
}

class _IncidentsTabState extends ConsumerState<_IncidentsTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(safetyNotifierProvider.notifier).loadIncidents();
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final state = ref.watch(safetyNotifierProvider);

    return Scaffold(
      backgroundColor: _grey,
      body: state.loading && state.incidents.isEmpty
          ? const Center(child: CircularProgressIndicator(color: _orange))
          : state.incidents.isEmpty
              ? _EmptyState(
                  icon: Iconsax.warning_2,
                  label: 'No incidents reported',
                  sub: 'Tap + to report an incident or near miss',
                )
              : RefreshIndicator(
                  color: _orange,
                  onRefresh: () =>
                      ref.read(safetyNotifierProvider.notifier).loadIncidents(),
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: state.incidents.length,
                    itemBuilder: (ctx, i) =>
                        _IncidentCard(item: state.incidents[i]),
                  ),
                ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: _orange,
        foregroundColor: Colors.white,
        onPressed: () => _showReportIncidentSheet(context),
        child: const Icon(Iconsax.add),
      ),
    );
  }

  void _showReportIncidentSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _ReportIncidentSheet(),
    );
  }
}

Color _severityColor(String severity) {
  switch (severity) {
    case 'critical':
      return _red;
    case 'high':
      return _orange;
    case 'medium':
      return _amber;
    default:
      return Colors.grey;
  }
}

class _IncidentCard extends StatelessWidget {
  final Map<String, dynamic> item;
  const _IncidentCard({required this.item});

  @override
  Widget build(BuildContext context) {
    final severity = item['severity'] as String? ?? 'low';
    final sColor = _severityColor(severity);
    final status = item['status'] as String? ?? 'open';
    final type = (item['incident_type'] as String? ?? 'other')
        .replaceAll('_', ' ')
        .toUpperCase();

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: _cardRadius,
        border: Border(left: BorderSide(color: sColor, width: 4)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _StatusBadge(label: severity.toUpperCase(), color: sColor),
                const SizedBox(width: 8),
                Text(
                  type,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: _navy,
                  ),
                ),
                const Spacer(),
                _StatusBadge(
                  label: status.toUpperCase(),
                  color: status == 'closed' ? Colors.grey : _blue,
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              item['description'] as String? ?? '',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, color: _navy),
            ),
            if (item['location'] != null) ...[
              const SizedBox(height: 6),
              _InfoRow(
                icon: Iconsax.location,
                text: item['location'] as String,
              ),
            ],
            const SizedBox(height: 6),
            _InfoRow(
              icon: Iconsax.calendar_1,
              text: _formatDate(item['created_at'] as String?),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReportIncidentSheet extends ConsumerStatefulWidget {
  const _ReportIncidentSheet();

  @override
  ConsumerState<_ReportIncidentSheet> createState() => _ReportIncidentSheetState();
}

class _ReportIncidentSheetState extends ConsumerState<_ReportIncidentSheet> {
  String _type = 'near_miss';
  String _severity = 'low';
  final _descCtrl = TextEditingController();
  final _locationCtrl = TextEditingController();
  final _injuredCtrl = TextEditingController();
  final _treatmentCtrl = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _descCtrl.dispose();
    _locationCtrl.dispose();
    _injuredCtrl.dispose();
    _treatmentCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.all(20),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _SheetHandle(),
              const SizedBox(height: 8),
              const Text(
                'Report Incident',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: _navy),
              ),
              const SizedBox(height: 16),
              const Text('Incident Type',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: _navy)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: ['near_miss', 'injury', 'property_damage', 'other'].map((t) {
                  final selected = _type == t;
                  return GestureDetector(
                    onTap: () => setState(() => _type = t),
                    child: Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                      decoration: BoxDecoration(
                        color: selected ? _orange : Colors.white,
                        border: Border.all(
                            color: selected ? _orange : Colors.grey.shade300),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        t.replaceAll('_', ' ').toUpperCase(),
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: selected ? Colors.white : Colors.grey.shade700,
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 16),
              const Text('Severity',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: _navy)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: ['low', 'medium', 'high', 'critical'].map((s) {
                  final selected = _severity == s;
                  final sColor = _severityColor(s);
                  return GestureDetector(
                    onTap: () => setState(() => _severity = s),
                    child: Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                      decoration: BoxDecoration(
                        color: selected ? sColor : Colors.white,
                        border: Border.all(
                            color: selected ? sColor : Colors.grey.shade300),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        s.toUpperCase(),
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: selected ? Colors.white : Colors.grey.shade700,
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _descCtrl,
                maxLines: 3,
                decoration: _inputDecoration('Description *', Iconsax.document_text),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _locationCtrl,
                decoration: _inputDecoration('Location', Iconsax.location),
              ),
              if (_type == 'injury') ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _injuredCtrl,
                  decoration: _inputDecoration('Injured Person', Iconsax.user),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _treatmentCtrl,
                  maxLines: 2,
                  decoration:
                      _inputDecoration('Treatment Provided', Iconsax.heart_add),
                ),
              ],
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _orange,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: _saving ? null : _submit,
                  child: _saving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('Submit Report',
                          style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _submit() async {
    if (_descCtrl.text.trim().isEmpty) return;
    setState(() => _saving = true);
    await ref.read(safetyNotifierProvider.notifier).createIncident({
      'incident_type': _type,
      'severity': _severity,
      'description': _descCtrl.text.trim(),
      if (_locationCtrl.text.trim().isNotEmpty)
        'location': _locationCtrl.text.trim(),
      if (_injuredCtrl.text.trim().isNotEmpty)
        'injured_person': _injuredCtrl.text.trim(),
      if (_treatmentCtrl.text.trim().isNotEmpty)
        'treatment_provided': _treatmentCtrl.text.trim(),
    });
    if (mounted) {
      setState(() => _saving = false);
      Navigator.pop(context);
    }
  }
}

// ══════════════════════════════════════════════════════════════
// TAB 4 — COMPLIANCE
// ══════════════════════════════════════════════════════════════

class _ComplianceTab extends ConsumerStatefulWidget {
  const _ComplianceTab();

  @override
  ConsumerState<_ComplianceTab> createState() => _ComplianceTabState();
}

class _ComplianceTabState extends ConsumerState<_ComplianceTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(safetyNotifierProvider.notifier).loadCompliance();
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final state = ref.watch(safetyNotifierProvider);
    final list = state.compliance;

    // Identify urgent items (expired or expiring within 7 days)
    final urgentItems = list.where((c) {
      final days = _daysUntilExpiry(c['expiry_date'] as String?);
      return days != null && days <= 7;
    }).toList();

    return Scaffold(
      backgroundColor: _grey,
      body: state.loading && list.isEmpty
          ? const Center(child: CircularProgressIndicator(color: _orange))
          : Column(
              children: [
                if (urgentItems.isNotEmpty) _UrgencyBanner(items: urgentItems),
                Expanded(
                  child: list.isEmpty
                      ? _EmptyState(
                          icon: Iconsax.shield_tick,
                          label: 'No compliance records',
                          sub: 'Tap + to add a license, cert, or insurance record',
                        )
                      : RefreshIndicator(
                          color: _orange,
                          onRefresh: () =>
                              ref.read(safetyNotifierProvider.notifier).loadCompliance(),
                          child: ListView.builder(
                            padding: const EdgeInsets.all(16),
                            itemCount: list.length,
                            itemBuilder: (ctx, i) =>
                                _ComplianceCard(item: list[i]),
                          ),
                        ),
                ),
              ],
            ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: _orange,
        foregroundColor: Colors.white,
        onPressed: () => _showAddComplianceSheet(context),
        child: const Icon(Iconsax.add),
      ),
    );
  }

  void _showAddComplianceSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _AddComplianceSheet(),
    );
  }
}

class _UrgencyBanner extends StatelessWidget {
  final List<Map<String, dynamic>> items;
  const _UrgencyBanner({required this.items});

  @override
  Widget build(BuildContext context) {
    final expiredCount = items.where((c) {
      final d = _daysUntilExpiry(c['expiry_date'] as String?);
      return d != null && d < 0;
    }).length;

    return Container(
      width: double.infinity,
      color: _red.withOpacity(0.10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          const Icon(Iconsax.warning_2, color: _red, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              expiredCount > 0
                  ? '$expiredCount item(s) expired. Action required.'
                  : '${items.length} item(s) expiring within 7 days.',
              style: const TextStyle(
                color: _red,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ComplianceCard extends ConsumerWidget {
  final Map<String, dynamic> item;
  const _ComplianceCard({required this.item});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final days = _daysUntilExpiry(item['expiry_date'] as String?);
    final trafficColor = _trafficLightColor(days);
    final type = (item['type'] as String? ?? '').toUpperCase();

    String daysLabel;
    if (days == null) {
      daysLabel = 'No expiry';
    } else if (days < 0) {
      daysLabel = 'Expired ${(-days)} days ago';
    } else if (days == 0) {
      daysLabel = 'Expires today!';
    } else {
      daysLabel = '$days days remaining';
    }

    return Dismissible(
      key: Key(item['id'] as String? ?? UniqueKey().toString()),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          color: _red.withOpacity(0.15),
          borderRadius: _cardRadius,
        ),
        child: const Icon(Iconsax.trash, color: _red),
      ),
      confirmDismiss: (_) async {
        return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Delete record?'),
            content: Text('Remove "${item['name']}" from compliance records?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Delete', style: TextStyle(color: _red)),
              ),
            ],
          ),
        );
      },
      onDismissed: (_) {
        ref
            .read(safetyNotifierProvider.notifier)
            .deleteCompliance(item['id'] as String);
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: _cardRadius,
          border: Border(left: BorderSide(color: trafficColor, width: 4)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        _StatusBadge(label: type, color: _orange),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            item['name'] as String? ?? '—',
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                              color: _navy,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      item['holder_name'] as String? ?? '—',
                      style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
                    ),
                    if (item['reference_number'] != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Ref: ${item['reference_number']}',
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Icon(Iconsax.calendar_1, color: trafficColor, size: 16),
                  const SizedBox(height: 4),
                  Text(
                    item['expiry_date'] as String? ?? '—',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: trafficColor,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    daysLabel,
                    style: TextStyle(fontSize: 10, color: trafficColor),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Color _trafficLightColor(int? days) {
  if (days == null) return _green;
  if (days < 0) return _red;
  if (days <= 30) return _orange;
  return _green;
}

class _AddComplianceSheet extends ConsumerStatefulWidget {
  const _AddComplianceSheet();

  @override
  ConsumerState<_AddComplianceSheet> createState() => _AddComplianceSheetState();
}

class _AddComplianceSheetState extends ConsumerState<_AddComplianceSheet> {
  String _type = 'license';
  final _nameCtrl = TextEditingController();
  final _holderCtrl = TextEditingController();
  final _refCtrl = TextEditingController();
  final _issueDateCtrl = TextEditingController();
  final _expiryCtrl = TextEditingController();
  int _reminderDays = 30;
  bool _saving = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _holderCtrl.dispose();
    _refCtrl.dispose();
    _issueDateCtrl.dispose();
    _expiryCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.all(20),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _SheetHandle(),
              const SizedBox(height: 8),
              const Text(
                'Add Compliance Record',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: _navy),
              ),
              const SizedBox(height: 16),
              const Text('Type',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: _navy)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children:
                    ['license', 'certification', 'insurance', 'registration'].map((t) {
                  final selected = _type == t;
                  return GestureDetector(
                    onTap: () => setState(() => _type = t),
                    child: Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                      decoration: BoxDecoration(
                        color: selected ? _orange : Colors.white,
                        border: Border.all(
                            color: selected ? _orange : Colors.grey.shade300),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        t.toUpperCase(),
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: selected ? Colors.white : Colors.grey.shade700,
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _nameCtrl,
                decoration: _inputDecoration('Name (e.g. White Card)', Iconsax.shield_tick),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _holderCtrl,
                decoration: _inputDecoration('Holder Name', Iconsax.user),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _refCtrl,
                decoration:
                    _inputDecoration('Reference Number (optional)', Iconsax.hashtag),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _issueDateCtrl,
                decoration: _inputDecoration('Issue Date YYYY-MM-DD (optional)', Iconsax.calendar_1),
                keyboardType: TextInputType.datetime,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _expiryCtrl,
                decoration:
                    _inputDecoration('Expiry Date YYYY-MM-DD *', Iconsax.calendar_remove),
                keyboardType: TextInputType.datetime,
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Text(
                    'Remind me',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: _navy),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Slider(
                      value: _reminderDays.toDouble(),
                      min: 7,
                      max: 90,
                      divisions: 5,
                      activeColor: _orange,
                      label: '$_reminderDays days before',
                      onChanged: (v) => setState(() => _reminderDays = v.round()),
                    ),
                  ),
                  Text(
                    '$_reminderDays d',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      color: _orange,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _orange,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('Add Record',
                          style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _save() async {
    if (_nameCtrl.text.trim().isEmpty ||
        _holderCtrl.text.trim().isEmpty ||
        _expiryCtrl.text.trim().isEmpty) return;
    setState(() => _saving = true);
    await ref.read(safetyNotifierProvider.notifier).addCompliance({
      'type': _type,
      'name': _nameCtrl.text.trim(),
      'holder_name': _holderCtrl.text.trim(),
      if (_refCtrl.text.trim().isNotEmpty) 'reference_number': _refCtrl.text.trim(),
      if (_issueDateCtrl.text.trim().isNotEmpty)
        'issue_date': _issueDateCtrl.text.trim(),
      'expiry_date': _expiryCtrl.text.trim(),
      'reminder_days_before': _reminderDays,
    });
    if (mounted) {
      setState(() => _saving = false);
      Navigator.pop(context);
    }
  }
}

// ══════════════════════════════════════════════════════════════
// SHARED WIDGETS
// ══════════════════════════════════════════════════════════════

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String label;
  final String sub;
  const _EmptyState({required this.icon, required this.label, required this.sub});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: _orange.withOpacity(0.08),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 48, color: _orange.withOpacity(0.6)),
          ),
          const SizedBox(height: 16),
          Text(
            label,
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: _navy,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            sub,
            style: TextStyle(fontSize: 13, color: Colors.grey.shade500),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _SheetHandle extends StatelessWidget {
  const _SheetHandle();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 36,
        height: 4,
        decoration: BoxDecoration(
          color: Colors.grey.shade300,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final String label;
  final Color color;
  const _StatusBadge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String text;
  const _InfoRow({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 13, color: Colors.grey.shade500),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

InputDecoration _inputDecoration(String hint, IconData icon) {
  return InputDecoration(
    hintText: hint,
    hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 14),
    prefixIcon: Icon(icon, size: 18, color: Colors.grey.shade400),
    filled: true,
    fillColor: const Color(0xFFF8FAFC),
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(color: Colors.grey.shade200),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: _orange, width: 1.5),
    ),
    errorBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: _red),
    ),
    focusedErrorBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: _red, width: 1.5),
    ),
  );
}

// ── Date utilities ─────────────────────────────────────────────

int? _daysUntilExpiry(String? dateStr) {
  if (dateStr == null || dateStr.isEmpty) return null;
  try {
    final expiry = DateTime.parse(dateStr);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final expiryDay = DateTime(expiry.year, expiry.month, expiry.day);
    return expiryDay.difference(today).inDays;
  } catch (_) {
    return null;
  }
}

String _formatDate(String? iso) {
  if (iso == null || iso.isEmpty) return '—';
  try {
    final dt = DateTime.parse(iso).toLocal();
    return '${dt.day.toString().padLeft(2, '0')} '
        '${_monthAbbr(dt.month)} ${dt.year}';
  } catch (_) {
    return iso;
  }
}

const _monthAbbrs = [
  '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String _monthAbbr(int m) => (m >= 1 && m <= 12) ? _monthAbbrs[m] : '';
