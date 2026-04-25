import 'package:flutter/material.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';

import '../../../core/utils/theme.dart';

// No audio packages detected in pubspec.yaml (record / audioplayers not present).
// Renders a polished placeholder UI with mock recordings, ready to wire up
// when audio packages are added.

// ── Placeholder model ─────────────────────────────────────────────────────────

class _VoiceNote {
  final String id;
  final String label;
  final Duration duration;
  final DateTime createdAt;

  const _VoiceNote({
    required this.id,
    required this.label,
    required this.duration,
    required this.createdAt,
  });
}

// ── Screen ────────────────────────────────────────────────────────────────────

class VoiceNotesScreen extends StatefulWidget {
  final String? jobId;
  final String? jobTitle;

  const VoiceNotesScreen({
    super.key,
    this.jobId,
    this.jobTitle,
  });

  @override
  State<VoiceNotesScreen> createState() => _VoiceNotesScreenState();
}

class _VoiceNotesScreenState extends State<VoiceNotesScreen>
    with SingleTickerProviderStateMixin {
  // Placeholder recordings list
  final List<_VoiceNote> _notes = [
    _VoiceNote(
      id: '1',
      label: 'Site inspection notes',
      duration: const Duration(minutes: 1, seconds: 24),
      createdAt: DateTime.now().subtract(const Duration(hours: 2)),
    ),
    _VoiceNote(
      id: '2',
      label: 'Customer requirements',
      duration: const Duration(seconds: 47),
      createdAt: DateTime.now().subtract(const Duration(days: 1)),
    ),
  ];

  bool _isRecording = false;
  String? _playingId;
  late AnimationController _pulseCtrl;
  late Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _pulseAnim = Tween<double>(begin: 1.0, end: 1.18).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    super.dispose();
  }

  void _toggleRecord() {
    setState(() => _isRecording = !_isRecording);
    if (_isRecording) {
      _pulseCtrl.repeat(reverse: true);
    } else {
      _pulseCtrl.stop();
      _pulseCtrl.reset();
      // Simulate adding a new recording
      setState(() {
        _notes.insert(
          0,
          _VoiceNote(
            id: DateTime.now().millisecondsSinceEpoch.toString(),
            label: 'Voice note ${_notes.length + 1}',
            duration: const Duration(seconds: 12),
            createdAt: DateTime.now(),
          ),
        );
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Voice note saved'),
          backgroundColor: TradieColors.green,
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  void _togglePlay(String id) {
    setState(() => _playingId = _playingId == id ? null : id);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TradieColors.grey50,
      appBar: AppBar(
        backgroundColor: TradieColors.white,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Voice Notes',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: TradieColors.navy,
              ),
            ),
            if (widget.jobTitle != null)
              Text(
                widget.jobTitle!,
                style: const TextStyle(fontSize: 12, color: TradieColors.grey400),
              ),
          ],
        ),
        leading: BackButton(color: TradieColors.navy),
      ),
      body: Column(
        children: [
          // ── Permission notice ─────────────────────────────────────
          Container(
            margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: TradieColors.safetyOrange.withOpacity(0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: TradieColors.safetyOrange.withOpacity(0.2),
              ),
            ),
            child: Row(children: [
              const Icon(
                Iconsax.info_circle,
                color: TradieColors.safetyOrange,
                size: 16,
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Requires microphone permission. Add record & audioplayers packages to enable full audio.',
                  style: TextStyle(
                    fontSize: 12,
                    color: TradieColors.safetyOrange,
                  ),
                ),
              ),
            ]),
          ),

          // ── Recording list ────────────────────────────────────────
          Expanded(
            child: _notes.isEmpty
                ? _buildEmptyState()
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 120),
                    itemCount: _notes.length,
                    itemBuilder: (_, i) => _buildNoteCard(_notes[i]),
                  ),
          ),
        ],
      ),
      // ── Record button ───────────────────────────────────────────
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: _buildRecordButton(),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: TradieColors.grey100,
              borderRadius: BorderRadius.circular(24),
            ),
            child: const Icon(
              Iconsax.microphone_2,
              color: TradieColors.grey300,
              size: 40,
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'No voice notes yet',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: TradieColors.navy,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Tap the button below to record\na voice note for this job',
            style: TextStyle(fontSize: 14, color: TradieColors.grey400),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildNoteCard(_VoiceNote note) {
    final isPlaying = _playingId == note.id;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: TradieColors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        leading: GestureDetector(
          onTap: () => _togglePlay(note.id),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: isPlaying
                  ? TradieColors.electricBlue
                  : TradieColors.electricBlue.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              isPlaying ? Iconsax.pause : Iconsax.play,
              color: isPlaying ? TradieColors.white : TradieColors.electricBlue,
              size: 20,
            ),
          ),
        ),
        title: Text(
          note.label,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: TradieColors.navy,
          ),
        ),
        subtitle: Row(children: [
          const Icon(Iconsax.clock, size: 11, color: TradieColors.grey400),
          const SizedBox(width: 4),
          Text(
            _formatDuration(note.duration),
            style: const TextStyle(fontSize: 12, color: TradieColors.grey400),
          ),
          const SizedBox(width: 12),
          const Icon(Iconsax.calendar_1, size: 11, color: TradieColors.grey400),
          const SizedBox(width: 4),
          Text(
            _formatDate(note.createdAt),
            style: const TextStyle(fontSize: 12, color: TradieColors.grey400),
          ),
        ]),
        trailing: PopupMenuButton<String>(
          icon: const Icon(Iconsax.more, color: TradieColors.grey400, size: 18),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          itemBuilder: (_) => [
            const PopupMenuItem(
              value: 'rename',
              child: Row(children: [
                Icon(Iconsax.edit_2, size: 16, color: TradieColors.navy),
                SizedBox(width: 8),
                Text('Rename'),
              ]),
            ),
            PopupMenuItem(
              value: 'delete',
              child: Row(children: [
                const Icon(Iconsax.trash, size: 16, color: TradieColors.red),
                const SizedBox(width: 8),
                Text('Delete', style: TextStyle(color: TradieColors.red)),
              ]),
            ),
          ],
          onSelected: (v) {
            if (v == 'delete') {
              setState(() => _notes.removeWhere((n) => n.id == note.id));
            }
          },
        ),
      ),
    );
  }

  Widget _buildRecordButton() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Status label
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: _isRecording
              ? Container(
                  key: const ValueKey('recording'),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: TradieColors.red,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Iconsax.record, color: TradieColors.white, size: 14),
                      SizedBox(width: 6),
                      Text(
                        'Recording... tap to stop',
                        style: TextStyle(
                          color: TradieColors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                )
              : Container(
                  key: const ValueKey('idle'),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: TradieColors.navy.withOpacity(0.8),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text(
                    'Tap to record',
                    style: TextStyle(
                      color: TradieColors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
        ),
        const SizedBox(height: 12),
        // Record button with pulse
        ScaleTransition(
          scale: _isRecording ? _pulseAnim : const AlwaysStoppedAnimation(1.0),
          child: GestureDetector(
            onTap: _toggleRecord,
            child: Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _isRecording ? TradieColors.red : TradieColors.red,
                boxShadow: [
                  BoxShadow(
                    color: TradieColors.red.withOpacity(_isRecording ? 0.4 : 0.2),
                    blurRadius: _isRecording ? 24 : 12,
                    spreadRadius: _isRecording ? 4 : 0,
                  ),
                ],
              ),
              child: Icon(
                _isRecording ? Iconsax.stop : Iconsax.microphone_2,
                color: TradieColors.white,
                size: 30,
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}
