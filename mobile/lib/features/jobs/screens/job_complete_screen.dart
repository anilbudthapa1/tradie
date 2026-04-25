import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';

import '../../../core/utils/theme.dart';
import '../providers/jobs_provider.dart';

class JobCompleteScreen extends ConsumerStatefulWidget {
  final String id;
  const JobCompleteScreen({super.key, required this.id});

  @override
  ConsumerState<JobCompleteScreen> createState() => _JobCompleteScreenState();
}

class _JobCompleteScreenState extends ConsumerState<JobCompleteScreen> {
  final _signerNameCtrl = TextEditingController();
  final _signerRoleCtrl = TextEditingController();
  final _sigNotesCtrl = TextEditingController();
  bool _completing = false;
  bool _completed = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(jobDetailProvider(widget.id).notifier).load());
  }

  @override
  void dispose() {
    _signerNameCtrl.dispose();
    _signerRoleCtrl.dispose();
    _sigNotesCtrl.dispose();
    super.dispose();
  }

  Future<void> _completeJob() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Complete Job?'),
        content: const Text(
          'This will mark the job as completed and cannot be undone. Continue?',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: TradieColors.successGreen),
            child: const Text('Complete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _completing = true);

    final notifier = ref.read(jobDetailProvider(widget.id).notifier);

    // Complete the job
    final completed = await notifier.completeJob();
    if (!completed || !mounted) {
      setState(() => _completing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to complete job'), backgroundColor: TradieColors.alertRed),
      );
      return;
    }

    // Sign off if name provided
    if (_signerNameCtrl.text.trim().isNotEmpty) {
      await notifier.signOff({
        'signer_name': _signerNameCtrl.text.trim(),
        'signer_role': _signerRoleCtrl.text.trim(),
        'signature_data_url': 'data:text/plain;base64,c2lnbmVk',
        'notes': _sigNotesCtrl.text.trim(),
      });
    }

    setState(() {
      _completing = false;
      _completed = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(jobDetailProvider(widget.id));
    final job = state.job;

    return Scaffold(
      backgroundColor: TradieColors.grey50,
      appBar: AppBar(
        title: const Text('Complete Job'),
        leading: IconButton(
          icon: const Icon(Iconsax.arrow_left),
          onPressed: () => context.pop(),
        ),
      ),
      body: _completed ? _SuccessView(jobId: widget.id) : _buildForm(context, state, job),
    );
  }

  Widget _buildForm(BuildContext context, JobDetailState state, Map<String, dynamic>? job) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Job summary
        if (job != null) ...[
          _SummaryCard(job: job, materials: state.materials, materialsTotal: state.materialsTotal, notes: state.notes),
          const SizedBox(height: 12),
        ] else if (state.loading) ...[
          const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator())),
          const SizedBox(height: 12),
        ],

        // Sign-off section
        _SignOffSection(
          signerNameCtrl: _signerNameCtrl,
          signerRoleCtrl: _signerRoleCtrl,
          sigNotesCtrl: _sigNotesCtrl,
        ),
        const SizedBox(height: 24),

        // Complete button
        ElevatedButton.icon(
          onPressed: _completing ? null : _completeJob,
          icon: _completing
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
              : const Icon(Iconsax.tick_circle, size: 22),
          label: const Text('Complete Job', style: TextStyle(fontSize: 16)),
          style: ElevatedButton.styleFrom(
            backgroundColor: TradieColors.successGreen,
            minimumSize: const Size(double.infinity, 56),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: _completing ? null : () => context.pop(),
          style: OutlinedButton.styleFrom(
            side: const BorderSide(color: TradieColors.grey200),
            foregroundColor: TradieColors.grey600,
            minimumSize: const Size(double.infinity, 48),
          ),
          child: const Text('Cancel'),
        ),
        const SizedBox(height: 40),
      ],
    );
  }
}

// ── Success View ───────────────────────────────────────────────

class _SuccessView extends StatelessWidget {
  final String jobId;
  const _SuccessView({required this.jobId});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                color: TradieColors.successGreen.withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(Iconsax.tick_circle, size: 52, color: TradieColors.successGreen),
            ),
            const SizedBox(height: 24),
            const Text(
              'Job Completed!',
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: TradieColors.navy),
            ),
            const SizedBox(height: 8),
            const Text(
              'The job has been marked as complete and the customer has been signed off.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: TradieColors.grey600, height: 1.5),
            ),
            const SizedBox(height: 32),
            ElevatedButton.icon(
              onPressed: () => context.go('/jobs/$jobId'),
              icon: const Icon(Iconsax.eye, size: 18),
              label: const Text('View Job'),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(200, 50),
              ),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => context.go('/jobs'),
              child: const Text('Back to Jobs'),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Summary Card ───────────────────────────────────────────────

class _SummaryCard extends StatelessWidget {
  final Map<String, dynamic> job;
  final List<Map<String, dynamic>> materials;
  final double materialsTotal;
  final List<Map<String, dynamic>> notes;

  const _SummaryCard({
    required this.job,
    required this.materials,
    required this.materialsTotal,
    required this.notes,
  });

  @override
  Widget build(BuildContext context) {
    final start = job['scheduled_start'] as String?;
    final end = job['scheduled_end'] as String?;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: TradieColors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: TradieColors.grey200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Iconsax.briefcase, size: 16, color: TradieColors.electricBlue),
            const SizedBox(width: 8),
            const Text('Job Summary', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: TradieColors.navy)),
          ]),
          const SizedBox(height: 14),
          const Divider(height: 1),
          const SizedBox(height: 14),
          Text(job['title'] ?? 'Untitled', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: TradieColors.navy)),
          if (job['customer_name'] != null) ...[
            const SizedBox(height: 4),
            Row(children: [
              const Icon(Iconsax.user, size: 14, color: TradieColors.grey400),
              const SizedBox(width: 6),
              Text(job['customer_name'] as String, style: const TextStyle(fontSize: 14, color: TradieColors.grey600)),
            ]),
          ],
          const SizedBox(height: 12),
          const Divider(height: 1),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: _StatBox(
                label: 'Schedule',
                value: start != null ? _duration(start, end) : '—',
                icon: Iconsax.clock,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _StatBox(
                label: 'Materials',
                value: '\$${materialsTotal.toStringAsFixed(2)}',
                icon: Iconsax.box,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _StatBox(
                label: 'Notes',
                value: '${notes.length}',
                icon: Iconsax.note_text,
              ),
            ),
          ]),
        ],
      ),
    );
  }

  String _duration(String start, String? end) {
    try {
      final s = DateTime.parse(start);
      if (end == null) return '${s.day}/${s.month}';
      final e = DateTime.parse(end);
      final diff = e.difference(s);
      if (diff.inHours >= 1) return '${diff.inHours}h ${diff.inMinutes % 60}m';
      return '${diff.inMinutes}m';
    } catch (_) {
      return '—';
    }
  }
}

class _StatBox extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;

  const _StatBox({required this.label, required this.value, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: TradieColors.grey50,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: TradieColors.grey200),
      ),
      child: Column(
        children: [
          Icon(icon, size: 18, color: TradieColors.electricBlue),
          const SizedBox(height: 6),
          Text(value, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: TradieColors.navy)),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(fontSize: 11, color: TradieColors.grey400)),
        ],
      ),
    );
  }
}

// ── Sign-off Section ───────────────────────────────────────────

class _SignOffSection extends StatefulWidget {
  final TextEditingController signerNameCtrl;
  final TextEditingController signerRoleCtrl;
  final TextEditingController sigNotesCtrl;

  const _SignOffSection({
    required this.signerNameCtrl,
    required this.signerRoleCtrl,
    required this.sigNotesCtrl,
  });

  @override
  State<_SignOffSection> createState() => _SignOffSectionState();
}

class _SignOffSectionState extends State<_SignOffSection> {
  bool _expanded = true;
  final List<Offset> _points = [];
  bool _hasSig = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: TradieColors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: TradieColors.grey200),
      ),
      child: Column(
        children: [
          // Section header (collapsible)
          GestureDetector(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const Icon(Iconsax.edit_2, size: 16, color: TradieColors.electricBlue),
                  const SizedBox(width: 8),
                  const Text('Customer Sign-off', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: TradieColors.navy)),
                  const Spacer(),
                  const Text('Optional', style: TextStyle(fontSize: 12, color: TradieColors.grey400)),
                  const SizedBox(width: 8),
                  Icon(_expanded ? Iconsax.arrow_up_2 : Iconsax.arrow_down_2, size: 16, color: TradieColors.grey400),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: widget.signerNameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Signer Name',
                      prefixIcon: Icon(Iconsax.user, size: 18),
                      hintText: 'Customer or authorised person',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: widget.signerRoleCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Role',
                      prefixIcon: Icon(Iconsax.briefcase, size: 18),
                      hintText: 'e.g. Homeowner, Site Manager',
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Signature pad
                  const Text(
                    'Signature',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: TradieColors.grey600),
                  ),
                  const SizedBox(height: 8),
                  GestureDetector(
                    onPanStart: (d) => setState(() {
                      _points.add(d.localPosition);
                      _hasSig = true;
                    }),
                    onPanUpdate: (d) => setState(() => _points.add(d.localPosition)),
                    onPanEnd: (_) => setState(() => _points.add(const Offset(-1, -1))),
                    child: Container(
                      height: 140,
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: TradieColors.grey50,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: _hasSig ? TradieColors.electricBlue.withOpacity(0.4) : TradieColors.grey200,
                          width: 1.5,
                        ),
                      ),
                      child: Stack(
                        children: [
                          CustomPaint(painter: _SignaturePainter(points: _points), child: const SizedBox.expand()),
                          if (!_hasSig)
                            const Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Iconsax.edit_2, size: 28, color: TradieColors.grey400),
                                  SizedBox(height: 6),
                                  Text('Draw signature here', style: TextStyle(color: TradieColors.grey400, fontSize: 13)),
                                ],
                              ),
                            ),
                          if (_hasSig)
                            Positioned(
                              top: 6,
                              right: 6,
                              child: GestureDetector(
                                onTap: () => setState(() {
                                  _points.clear();
                                  _hasSig = false;
                                }),
                                child: Container(
                                  padding: const EdgeInsets.all(4),
                                  decoration: BoxDecoration(color: TradieColors.grey200, borderRadius: BorderRadius.circular(6)),
                                  child: const Icon(Iconsax.close_circle, size: 14, color: TradieColors.grey600),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: widget.sigNotesCtrl,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: 'Sign-off Notes (optional)',
                      hintText: 'Any comments from the customer...',
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SignaturePainter extends CustomPainter {
  final List<Offset> points;

  const _SignaturePainter({required this.points});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = TradieColors.navy
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    for (int i = 0; i < points.length - 1; i++) {
      if (points[i] != const Offset(-1, -1) && points[i + 1] != const Offset(-1, -1)) {
        canvas.drawLine(points[i], points[i + 1], paint);
      }
    }
  }

  @override
  bool shouldRepaint(_SignaturePainter old) => old.points != points;
}
