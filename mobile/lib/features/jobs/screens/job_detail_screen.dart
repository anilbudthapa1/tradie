import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';

import '../../../core/utils/theme.dart';
import '../providers/jobs_provider.dart';

class JobDetailScreen extends ConsumerStatefulWidget {
  final String id;
  const JobDetailScreen({super.key, required this.id});

  @override
  ConsumerState<JobDetailScreen> createState() => _JobDetailScreenState();
}

class _JobDetailScreenState extends ConsumerState<JobDetailScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tab;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 5, vsync: this);
    Future.microtask(() => ref.read(jobDetailProvider(widget.id).notifier).load());
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(jobDetailProvider(widget.id));

    if (state.loading && state.job == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Job Detail')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (state.error != null && state.job == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Job Detail')),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Iconsax.warning_2, size: 48, color: TradieColors.alertRed),
              const SizedBox(height: 12),
              Text('Failed to load job', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: () => ref.read(jobDetailProvider(widget.id).notifier).load(),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    final job = state.job!;
    final status = job['status'] as String? ?? 'draft';
    final isCompleted = status == 'completed';

    return Scaffold(
      backgroundColor: TradieColors.grey50,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(job['job_number'] ?? '', style: const TextStyle(fontSize: 12, color: TradieColors.grey400, fontWeight: FontWeight.w500)),
            Text(job['title'] ?? 'Job Detail', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: TradieColors.navy)),
          ],
        ),
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 4),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: status.jobStatusColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: status.jobStatusColor.withOpacity(0.3)),
            ),
            child: Text(
              _statusLabel(status),
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: status.jobStatusColor),
            ),
          ),
          IconButton(icon: const Icon(Iconsax.edit_2, size: 20), onPressed: () {}),
          IconButton(icon: const Icon(Iconsax.more_circle, size: 20), onPressed: () {}),
        ],
        bottom: TabBar(
          controller: _tab,
          isScrollable: true,
          labelColor: TradieColors.electricBlue,
          unselectedLabelColor: TradieColors.grey400,
          indicatorColor: TradieColors.electricBlue,
          indicatorSize: TabBarIndicatorSize.label,
          tabs: const [
            Tab(text: 'Details'),
            Tab(text: 'Notes'),
            Tab(text: 'Photos'),
            Tab(text: 'Materials'),
            Tab(text: 'Sign-off'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: [
          _DetailsTab(job: job, state: state),
          _NotesTab(jobId: widget.id, state: state),
          _PhotosTab(jobId: widget.id, state: state),
          _MaterialsTab(jobId: widget.id, state: state),
          _SignOffTab(jobId: widget.id),
        ],
      ),
      bottomNavigationBar: isCompleted
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: ElevatedButton.icon(
                  onPressed: () => context.push('/jobs/${widget.id}/complete'),
                  icon: const Icon(Iconsax.tick_circle, size: 20),
                  label: const Text('Complete Job'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: TradieColors.successGreen,
                    minimumSize: const Size(double.infinity, 52),
                  ),
                ),
              ),
            ),
    );
  }

  String _statusLabel(String s) =>
      s.split('_').map((w) => w.isNotEmpty ? w[0].toUpperCase() + w.substring(1) : '').join(' ');
}

// ── Details Tab ────────────────────────────────────────────────

class _DetailsTab extends StatelessWidget {
  final Map<String, dynamic> job;
  final JobDetailState state;

  const _DetailsTab({required this.job, required this.state});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _SectionCard(
          title: 'Job Information',
          icon: Iconsax.briefcase,
          children: [
            _InfoRow(label: 'Job Number', value: job['job_number'] ?? '—'),
            _InfoRow(label: 'Status', value: _statusLabel(job['status'] ?? '—')),
            _InfoRow(label: 'Priority', value: _capitalize(job['priority'] ?? '—')),
            if (job['description'] != null)
              _InfoRow(label: 'Description', value: job['description'] as String),
          ],
        ),
        const SizedBox(height: 12),
        _SectionCard(
          title: 'Schedule',
          icon: Iconsax.calendar,
          children: [
            _InfoRow(
              label: 'Scheduled Start',
              value: _formatDateTime(job['scheduled_start'] as String?),
            ),
            _InfoRow(
              label: 'Scheduled End',
              value: _formatDateTime(job['scheduled_end'] as String?),
            ),
            if (job['actual_start'] != null)
              _InfoRow(label: 'Actual Start', value: _formatDateTime(job['actual_start'] as String?)),
            if (job['actual_end'] != null)
              _InfoRow(label: 'Actual End', value: _formatDateTime(job['actual_end'] as String?)),
          ],
        ),
        if (job['lat'] != null || job['city'] != null) ...[
          const SizedBox(height: 12),
          _SectionCard(
            title: 'Location',
            icon: Iconsax.location,
            children: [
              if (job['address_line1'] != null)
                _InfoRow(label: 'Address', value: job['address_line1'] as String),
              if (job['city'] != null)
                _InfoRow(label: 'City', value: job['city'] as String),
              if (job['lat'] != null && job['lng'] != null)
                _InfoRow(
                  label: 'Coordinates',
                  value: '${(job['lat'] as num).toStringAsFixed(6)}, ${(job['lng'] as num).toStringAsFixed(6)}',
                ),
            ],
          ),
        ],
        const SizedBox(height: 12),
        _SectionCard(
          title: 'Assigned Workers',
          icon: Iconsax.people,
          children: [
            if (job['workers'] == null || (job['workers'] as List).isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('No workers assigned', style: TextStyle(color: TradieColors.grey400)),
              )
            else
              for (final w in job['workers'] as List)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 16,
                        backgroundColor: TradieColors.electricBlue.withOpacity(0.15),
                        child: Text(
                          _initials(w as String),
                          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: TradieColors.electricBlue),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(w, style: const TextStyle(fontSize: 14, color: TradieColors.charcoal)),
                    ],
                  ),
                ),
          ],
        ),
        const SizedBox(height: 80),
      ],
    );
  }

  String _statusLabel(String s) =>
      s.split('_').map((w) => w.isNotEmpty ? w[0].toUpperCase() + w.substring(1) : '').join(' ');

  String _capitalize(String s) => s.isNotEmpty ? s[0].toUpperCase() + s.substring(1) : s;

  String _formatDateTime(String? iso) {
    if (iso == null) return '—';
    try {
      final dt = DateTime.parse(iso).toLocal();
      return '${dt.day}/${dt.month}/${dt.year} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return iso;
    }
  }

  String _initials(String name) {
    final parts = name.trim().split(' ');
    if (parts.length >= 2) return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    return name.isNotEmpty ? name[0].toUpperCase() : '?';
  }
}

// ── Notes Tab ─────────────────────────────────────────────────

class _NotesTab extends ConsumerStatefulWidget {
  final String jobId;
  final JobDetailState state;

  const _NotesTab({required this.jobId, required this.state});

  @override
  ConsumerState<_NotesTab> createState() => _NotesTabState();
}

class _NotesTabState extends ConsumerState<_NotesTab> {
  final _controller = TextEditingController();
  bool _isInternal = false;
  bool _submitting = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final content = _controller.text.trim();
    if (content.isEmpty) return;
    setState(() => _submitting = true);
    final ok = await ref
        .read(jobDetailProvider(widget.jobId).notifier)
        .addNote(content, isInternal: _isInternal);
    setState(() => _submitting = false);
    if (ok) {
      _controller.clear();
      setState(() => _isInternal = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final notes = widget.state.notes;

    return Column(
      children: [
        // Add note form
        Container(
          color: TradieColors.white,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _controller,
                maxLines: 3,
                decoration: const InputDecoration(
                  hintText: 'Add a note...',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Switch(
                    value: _isInternal,
                    onChanged: (v) => setState(() => _isInternal = v),
                    activeColor: TradieColors.electricBlue,
                  ),
                  const Text('Internal only', style: TextStyle(fontSize: 13, color: TradieColors.grey600)),
                  const Spacer(),
                  ElevatedButton(
                    onPressed: _submitting ? null : _submit,
                    style: ElevatedButton.styleFrom(minimumSize: const Size(0, 40)),
                    child: _submitting
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Text('Add Note'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        // Notes list
        Expanded(
          child: notes.isEmpty
              ? const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Iconsax.note_text, size: 48, color: TradieColors.grey400),
                      SizedBox(height: 12),
                      Text('No notes yet', style: TextStyle(color: TradieColors.grey600, fontSize: 16)),
                    ],
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: notes.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (ctx, i) {
                    final n = notes[i];
                    final isInternal = n['is_internal'] as bool? ?? false;
                    return Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: isInternal ? TradieColors.warningAmber.withOpacity(0.06) : TradieColors.white,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: isInternal ? TradieColors.warningAmber.withOpacity(0.3) : TradieColors.grey200,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                n['author'] as String? ?? 'Unknown',
                                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: TradieColors.navy),
                              ),
                              if (isInternal) ...[
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: TradieColors.warningAmber.withOpacity(0.15),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: const Text('Internal', style: TextStyle(fontSize: 10, color: TradieColors.warningAmber, fontWeight: FontWeight.w600)),
                                ),
                              ],
                              const Spacer(),
                              Text(
                                _formatDate(n['created_at'] as String?),
                                style: const TextStyle(fontSize: 11, color: TradieColors.grey400),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(n['content'] as String? ?? '', style: const TextStyle(fontSize: 14, color: TradieColors.charcoal, height: 1.4)),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  String _formatDate(String? iso) {
    if (iso == null) return '';
    try {
      final dt = DateTime.parse(iso).toLocal();
      return '${dt.day}/${dt.month}/${dt.year}';
    } catch (_) {
      return iso;
    }
  }
}

// ── Photos Tab ────────────────────────────────────────────────

class _PhotosTab extends ConsumerStatefulWidget {
  final String jobId;
  final JobDetailState state;

  const _PhotosTab({required this.jobId, required this.state});

  @override
  ConsumerState<_PhotosTab> createState() => _PhotosTabState();
}

class _PhotosTabState extends ConsumerState<_PhotosTab> {
  Future<void> _addPhoto() async {
    final urlController = TextEditingController();
    final captionController = TextEditingController();
    String phase = 'before';

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Photo'),
        content: StatefulBuilder(
          builder: (ctx2, setInner) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: urlController,
                decoration: const InputDecoration(labelText: 'Photo URL', hintText: 'https://...'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: captionController,
                decoration: const InputDecoration(labelText: 'Caption (optional)'),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: phase,
                items: const [
                  DropdownMenuItem(value: 'before', child: Text('Before')),
                  DropdownMenuItem(value: 'during', child: Text('During')),
                  DropdownMenuItem(value: 'after', child: Text('After')),
                ],
                onChanged: (v) => setInner(() => phase = v!),
                decoration: const InputDecoration(labelText: 'Phase'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              if (urlController.text.isNotEmpty) {
                ref.read(jobDetailProvider(widget.jobId).notifier).uploadPhoto({
                  'url': urlController.text.trim(),
                  'caption': captionController.text.trim().isNotEmpty ? captionController.text.trim() : null,
                  'phase': phase,
                });
              }
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final photos = widget.state.photos;
    final phases = ['before', 'during', 'after'];

    return Scaffold(
      backgroundColor: TradieColors.grey50,
      floatingActionButton: FloatingActionButton(
        onPressed: _addPhoto,
        backgroundColor: TradieColors.electricBlue,
        child: const Icon(Iconsax.camera, color: Colors.white),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          for (final phase in phases) ...[
            if ((photos[phase] ?? []).isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: 8, top: 4),
                child: Text(
                  '${phase[0].toUpperCase()}${phase.substring(1)}',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: TradieColors.grey600),
                ),
              ),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                  childAspectRatio: 1,
                ),
                itemCount: (photos[phase] ?? []).length,
                itemBuilder: (ctx, i) {
                  final p = photos[phase]![i];
                  return GestureDetector(
                    onTap: () => _showPhoto(ctx, p['url'] as String),
                    child: Container(
                      decoration: BoxDecoration(
                        color: TradieColors.grey200,
                        borderRadius: BorderRadius.circular(8),
                        image: DecorationImage(
                          image: NetworkImage(p['url'] as String),
                          fit: BoxFit.cover,
                          onError: (_, __) {},
                        ),
                      ),
                      child: p['caption'] != null
                          ? Align(
                              alignment: Alignment.bottomCenter,
                              child: Container(
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                                decoration: const BoxDecoration(
                                  color: Colors.black54,
                                  borderRadius: BorderRadius.vertical(bottom: Radius.circular(8)),
                                ),
                                child: Text(
                                  p['caption'] as String,
                                  style: const TextStyle(color: Colors.white, fontSize: 9),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                          : null,
                    ),
                  );
                },
              ),
              const SizedBox(height: 16),
            ],
          ],
          if (photos.values.every((l) => l.isEmpty))
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 48),
                child: Column(
                  children: [
                    Icon(Iconsax.camera_slash, size: 48, color: TradieColors.grey400),
                    SizedBox(height: 12),
                    Text('No photos yet', style: TextStyle(color: TradieColors.grey600, fontSize: 16)),
                    SizedBox(height: 6),
                    Text('Tap + to add before, during, and after photos', style: TextStyle(color: TradieColors.grey400, fontSize: 13)),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 80),
        ],
      ),
    );
  }

  void _showPhoto(BuildContext context, String url) {
    showDialog(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: Colors.black,
        child: Image.network(url, fit: BoxFit.contain),
      ),
    );
  }
}

// ── Materials Tab ─────────────────────────────────────────────

class _MaterialsTab extends ConsumerStatefulWidget {
  final String jobId;
  final JobDetailState state;

  const _MaterialsTab({required this.jobId, required this.state});

  @override
  ConsumerState<_MaterialsTab> createState() => _MaterialsTabState();
}

class _MaterialsTabState extends ConsumerState<_MaterialsTab> {
  Future<void> _addMaterial() async {
    final nameCtrl = TextEditingController();
    final qtyCtrl = TextEditingController();
    final unitCtrl = TextEditingController();
    final costCtrl = TextEditingController();
    final supplierCtrl = TextEditingController();

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Material'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Material Name *')),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: TextField(controller: qtyCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Qty'))),
                const SizedBox(width: 8),
                Expanded(child: TextField(controller: unitCtrl, decoration: const InputDecoration(labelText: 'Unit (m, kg...)'))),
              ]),
              const SizedBox(height: 10),
              TextField(controller: costCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Unit Cost (\$)')),
              const SizedBox(height: 10),
              TextField(controller: supplierCtrl, decoration: const InputDecoration(labelText: 'Supplier (optional)')),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              if (nameCtrl.text.isNotEmpty) {
                ref.read(jobDetailProvider(widget.jobId).notifier).addMaterial({
                  'name': nameCtrl.text.trim(),
                  'quantity': double.tryParse(qtyCtrl.text) ?? 1.0,
                  'unit': unitCtrl.text.trim().isNotEmpty ? unitCtrl.text.trim() : null,
                  'unit_cost': double.tryParse(costCtrl.text) ?? 0.0,
                  'supplier': supplierCtrl.text.trim().isNotEmpty ? supplierCtrl.text.trim() : null,
                });
              }
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final materials = widget.state.materials;
    final total = widget.state.materialsTotal;

    return Scaffold(
      backgroundColor: TradieColors.grey50,
      floatingActionButton: FloatingActionButton(
        onPressed: _addMaterial,
        backgroundColor: TradieColors.electricBlue,
        child: const Icon(Iconsax.add, color: Colors.white),
      ),
      body: Column(
        children: [
          // Total summary bar
          Container(
            color: TradieColors.white,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Row(
              children: [
                const Icon(Iconsax.dollar_circle, size: 20, color: TradieColors.successGreen),
                const SizedBox(width: 8),
                const Text('Total Materials Cost', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: TradieColors.charcoal)),
                const Spacer(),
                Text(
                  '\$${total.toStringAsFixed(2)}',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: TradieColors.successGreen),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          // List
          Expanded(
            child: materials.isEmpty
                ? const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Iconsax.box, size: 48, color: TradieColors.grey400),
                        SizedBox(height: 12),
                        Text('No materials yet', style: TextStyle(color: TradieColors.grey600, fontSize: 16)),
                      ],
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
                    itemCount: materials.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (ctx, i) {
                      final m = materials[i];
                      final qty = (m['quantity'] as num).toDouble();
                      final unitCost = (m['unit_cost'] as num).toDouble();
                      final total = (m['total_cost'] as num).toDouble();
                      return Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: TradieColors.white,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: TradieColors.grey200),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(m['name'] as String, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: TradieColors.navy)),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${qty.toStringAsFixed(qty == qty.truncate() ? 0 : 2)} ${m['unit'] ?? ''} × \$${unitCost.toStringAsFixed(2)}',
                                    style: const TextStyle(fontSize: 12, color: TradieColors.grey600),
                                  ),
                                  if (m['supplier'] != null) ...[
                                    const SizedBox(height: 2),
                                    Text(m['supplier'] as String, style: const TextStyle(fontSize: 11, color: TradieColors.grey400)),
                                  ],
                                ],
                              ),
                            ),
                            Text(
                              '\$${total.toStringAsFixed(2)}',
                              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: TradieColors.charcoal),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// ── Sign-off Tab ──────────────────────────────────────────────

class _SignOffTab extends ConsumerStatefulWidget {
  final String jobId;
  const _SignOffTab({required this.jobId});

  @override
  ConsumerState<_SignOffTab> createState() => _SignOffTabState();
}

class _SignOffTabState extends ConsumerState<_SignOffTab> {
  final _nameCtrl = TextEditingController();
  final _roleCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();
  bool _signed = false;
  bool _submitting = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _roleCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_nameCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Signer name is required')),
      );
      return;
    }
    setState(() => _submitting = true);
    final ok = await ref.read(jobDetailProvider(widget.jobId).notifier).signOff({
      'signer_name': _nameCtrl.text.trim(),
      'signer_role': _roleCtrl.text.trim(),
      'signature_data_url': 'data:text/plain;base64,c2lnbmVk', // placeholder
      'notes': _notesCtrl.text.trim(),
    });
    setState(() => _submitting = false);
    if (ok && mounted) {
      setState(() => _signed = true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Sign-off recorded'),
          backgroundColor: TradieColors.successGreen,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_signed)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: TradieColors.successGreen.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: TradieColors.successGreen.withOpacity(0.3)),
            ),
            child: const Row(
              children: [
                Icon(Iconsax.tick_circle, color: TradieColors.successGreen),
                SizedBox(width: 12),
                Text('Job signed off', style: TextStyle(color: TradieColors.successGreen, fontWeight: FontWeight.w600)),
              ],
            ),
          )
        else ...[
          const Text('Customer Sign-off', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: TradieColors.navy)),
          const SizedBox(height: 4),
          const Text('Have the customer review and sign off on the completed job.', style: TextStyle(color: TradieColors.grey600, fontSize: 13)),
          const SizedBox(height: 20),
          TextField(
            controller: _nameCtrl,
            decoration: const InputDecoration(
              labelText: 'Signer Name *',
              prefixIcon: Icon(Iconsax.user, size: 18),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _roleCtrl,
            decoration: const InputDecoration(
              labelText: 'Signer Role (e.g. Homeowner)',
              prefixIcon: Icon(Iconsax.briefcase, size: 18),
            ),
          ),
          const SizedBox(height: 20),
          // Signature pad placeholder
          Container(
            height: 160,
            decoration: BoxDecoration(
              color: TradieColors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: TradieColors.grey200, width: 1.5),
            ),
            child: const Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Iconsax.edit_2, size: 32, color: TradieColors.grey400),
                SizedBox(height: 8),
                Text('Signature pad', style: TextStyle(color: TradieColors.grey400, fontSize: 14)),
                SizedBox(height: 4),
                Text('(Draw here)', style: TextStyle(color: TradieColors.grey400, fontSize: 12)),
              ],
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _notesCtrl,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Notes (optional)',
              hintText: 'Any additional notes from the customer...',
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: _submitting ? null : _submit,
            icon: _submitting
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Iconsax.tick_circle, size: 18),
            label: const Text('Record Sign-off'),
            style: ElevatedButton.styleFrom(
              backgroundColor: TradieColors.successGreen,
              minimumSize: const Size(double.infinity, 52),
            ),
          ),
        ],
        const SizedBox(height: 40),
      ],
    );
  }
}

// ── Shared widgets ─────────────────────────────────────────────

class _SectionCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<Widget> children;

  const _SectionCard({required this.title, required this.icon, required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: TradieColors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: TradieColors.grey200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: Row(
              children: [
                Icon(icon, size: 16, color: TradieColors.electricBlue),
                const SizedBox(width: 8),
                Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: TradieColors.navy)),
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(label, style: const TextStyle(fontSize: 13, color: TradieColors.grey400)),
          ),
          Expanded(
            child: Text(value, style: const TextStyle(fontSize: 13, color: TradieColors.charcoal, fontWeight: FontWeight.w500)),
          ),
        ],
      ),
    );
  }
}
