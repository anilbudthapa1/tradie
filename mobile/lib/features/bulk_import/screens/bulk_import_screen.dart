// M105 — bulk CSV import screen.

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';

import '../../../core/utils/theme.dart';
import '../providers/bulk_import_provider.dart';

class BulkImportScreen extends ConsumerStatefulWidget {
  const BulkImportScreen({super.key});

  @override
  ConsumerState<BulkImportScreen> createState() => _BulkImportScreenState();
}

class _BulkImportScreenState extends ConsumerState<BulkImportScreen> {
  String _entityType = 'customers';
  bool _picking = false;

  @override
  Widget build(BuildContext context) {
    final list = ref.watch(bulkImportListProvider);
    final notifier = ref.watch(bulkImportNotifierProvider);
    final uploading = notifier is AsyncLoading;

    return Scaffold(
      backgroundColor: TradieColors.white,
      appBar: AppBar(
        title: const Text('Bulk import'),
        backgroundColor: TradieColors.white,
        elevation: 0,
      ),
      body: RefreshIndicator(
        color: TradieColors.electricBlue,
        onRefresh: () async => ref.invalidate(bulkImportListProvider),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          children: [
            _UploadCard(
              entityType: _entityType,
              onEntityChanged: (v) => setState(() => _entityType = v),
              onUploadTap:
                  uploading || _picking ? null : () => _pickAndUpload(),
              uploading: uploading,
              picking: _picking,
            ),
            const SizedBox(height: 28),
            const Text(
              'Recent imports',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: TradieColors.charcoal,
                letterSpacing: 0.4,
              ),
            ),
            const SizedBox(height: 8),
            list.when(
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Center(
                  child: CircularProgressIndicator(
                      color: TradieColors.electricBlue),
                ),
              ),
              error: (err, _) => _Empty(
                icon: Iconsax.warning_2,
                title: 'Could not load imports',
                subtitle: err.toString(),
                color: TradieColors.alertRed,
              ),
              data: (jobs) => jobs.isEmpty
                  ? const _Empty(
                      icon: Iconsax.document_upload,
                      title: 'No imports yet',
                      subtitle:
                          'Upload a CSV above to bring customers, jobs or expenses across.',
                    )
                  : Column(
                      children: [
                        for (final j in jobs)
                          _JobTile(
                            job: j,
                            onTap: () => _showDetail(j),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickAndUpload() async {
    setState(() => _picking = true);
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['csv'],
      withData: false,
    );
    setState(() => _picking = false);
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    final path = file.path;
    if (path == null) {
      _toast('Could not read file', error: true);
      return;
    }

    final id = await ref.read(bulkImportNotifierProvider.notifier).upload(
          entityType: _entityType,
          filePath: path,
          filename: file.name,
        );
    if (!mounted) return;
    if (id == null) {
      _toast('Upload failed — check column names match the template',
          error: true);
      return;
    }
    _toast('Import queued — refresh to see progress');
  }

  void _showDetail(BulkImportJob job) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: TradieColors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _DetailSheet(jobId: job.id),
    );
  }

  void _toast(String msg, {bool error = false}) {
    final m = ScaffoldMessenger.of(context);
    m.hideCurrentSnackBar();
    m.showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor:
          error ? TradieColors.alertRed : TradieColors.electricBlue,
    ));
  }
}

// ── Upload card ──────────────────────────────────────────────────────────────

class _UploadCard extends StatelessWidget {
  final String entityType;
  final ValueChanged<String> onEntityChanged;
  final VoidCallback? onUploadTap;
  final bool uploading;
  final bool picking;

  const _UploadCard({
    required this.entityType,
    required this.onEntityChanged,
    required this.onUploadTap,
    required this.uploading,
    required this.picking,
  });

  @override
  Widget build(BuildContext context) {
    final cols = bulkImportColumns[entityType] ?? const [];
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: TradieColors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE7E9EE)),
        boxShadow: [
          BoxShadow(
            color: TradieColors.electricBlue.withValues(alpha: 0.06),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(children: [
            Icon(Iconsax.document_upload,
                color: TradieColors.electricBlue, size: 20),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'New import',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: TradieColors.charcoal,
                ),
              ),
            ),
          ]),
          const SizedBox(height: 14),
          const Text(
            'Type',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: TradieColors.charcoal,
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final t in supportedBulkImportEntities)
                _EntityChip(
                  label: t,
                  selected: t == entityType,
                  onTap: () => onEntityChanged(t),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFF5F7FA),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Expected CSV headers (exact match):',
                  style: TextStyle(
                    fontSize: 11,
                    color: TradieColors.charcoal,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  cols.join(', '),
                  style: const TextStyle(
                    fontSize: 12,
                    color: TradieColors.charcoal,
                    fontFamily: 'monospace',
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: TradieColors.electricBlue,
                foregroundColor: TradieColors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: onUploadTap,
              icon: (uploading || picking)
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: TradieColors.white,
                      ),
                    )
                  : const Icon(Iconsax.import_2),
              label: Text(
                uploading
                    ? 'Uploading…'
                    : picking
                        ? 'Pick file…'
                        : 'Choose CSV & upload',
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Up to 10 MB or 5 000 rows. Unknown columns are rejected.',
            style: TextStyle(fontSize: 11, color: TradieColors.charcoal),
          ),
        ],
      ),
    );
  }
}

class _EntityChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _EntityChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? TradieColors.electricBlue
              : const Color(0xFFEFF1F4),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? TradieColors.white : TradieColors.charcoal,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

// ── Job tile ─────────────────────────────────────────────────────────────────

class _JobTile extends StatelessWidget {
  final BulkImportJob job;
  final VoidCallback onTap;
  const _JobTile({required this.job, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final progress = job.totalRows == 0
        ? 0.0
        : (job.processedRows / job.totalRows).clamp(0.0, 1.0);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: TradieColors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE7E9EE)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          job.fileName.isEmpty
                              ? 'Untitled'
                              : job.fileName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: TradieColors.charcoal,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${job.entityType} · ${_fmtDate(job.createdAt)}',
                          style: const TextStyle(
                              fontSize: 12, color: TradieColors.charcoal),
                        ),
                      ],
                    ),
                  ),
                  _StatusChip(status: job.status),
                ],
              ),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 6,
                  backgroundColor: const Color(0xFFEFF1F4),
                  valueColor: AlwaysStoppedAnimation(
                    job.status == 'failed'
                        ? TradieColors.alertRed
                        : TradieColors.electricBlue,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '${job.successRows} ok · ${job.processedRows}/${job.totalRows} processed',
                style: const TextStyle(
                    fontSize: 12, color: TradieColors.charcoal),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String status;
  const _StatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    late final (Color bg, Color fg, String label) tone = switch (status) {
      'completed' => (
          TradieColors.electricBlue.withValues(alpha: 0.12),
          TradieColors.electricBlue,
          'Done',
        ),
      'processing' => (
          TradieColors.safetyOrange.withValues(alpha: 0.14),
          TradieColors.safetyOrange,
          'Processing',
        ),
      'failed' => (
          TradieColors.alertRed.withValues(alpha: 0.12),
          TradieColors.alertRed,
          'Failed',
        ),
      _ => (
          const Color(0xFFEFF1F4),
          TradieColors.charcoal,
          'Pending',
        ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: tone.$1,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        tone.$3,
        style: TextStyle(
            fontSize: 11, fontWeight: FontWeight.w600, color: tone.$2),
      ),
    );
  }
}

// ── Detail sheet ─────────────────────────────────────────────────────────────

class _DetailSheet extends ConsumerWidget {
  final String jobId;
  const _DetailSheet({required this.jobId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(bulkImportDetailProvider(jobId));
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (_, controller) => async.when(
        loading: () => const Center(
          child: CircularProgressIndicator(color: TradieColors.electricBlue),
        ),
        error: (err, _) => Padding(
          padding: const EdgeInsets.all(24),
          child: Text('Could not load details: $err'),
        ),
        data: (detail) => ListView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFFE7E9EE),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              detail.job.fileName.isEmpty
                  ? 'Untitled import'
                  : detail.job.fileName,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: TradieColors.charcoal,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${detail.job.entityType} · ${detail.job.totalRows} rows · ${detail.job.successRows} ok',
              style: const TextStyle(
                  fontSize: 13, color: TradieColors.charcoal),
            ),
            const SizedBox(height: 20),
            if (detail.errors.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text(
                    'No errors recorded.',
                    style: TextStyle(color: TradieColors.charcoal),
                  ),
                ),
              )
            else ...[
              const Text(
                'Row errors',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: TradieColors.charcoal,
                  letterSpacing: 0.4,
                ),
              ),
              const SizedBox(height: 8),
              for (final e in detail.errors)
                Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: TradieColors.alertRed.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: TradieColors.alertRed.withValues(alpha: 0.2),
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 28,
                        alignment: Alignment.center,
                        padding: const EdgeInsets.only(top: 1),
                        child: Text(
                          '${e.row}',
                          style: const TextStyle(
                            color: TradieColors.alertRed,
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          e.message,
                          style: const TextStyle(
                            fontSize: 13,
                            color: TradieColors.charcoal,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Empty ─────────────────────────────────────────────────────────────────────

class _Empty extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color? color;
  const _Empty({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? TradieColors.charcoal;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 24),
      child: Column(
        children: [
          Icon(icon, size: 44, color: c.withValues(alpha: 0.4)),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: c,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style:
                TextStyle(color: c.withValues(alpha: 0.7), fontSize: 13),
          ),
        ],
      ),
    );
  }
}

String _fmtDate(DateTime t) {
  final l = t.toLocal();
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final h = l.hour.toString().padLeft(2, '0');
  final m = l.minute.toString().padLeft(2, '0');
  return '${l.day} ${months[l.month - 1]} · $h:$m';
}
