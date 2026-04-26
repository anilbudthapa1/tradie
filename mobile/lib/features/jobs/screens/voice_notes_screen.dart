// M126 — voice notes screen.
//
// Real audio: record (capture) + just_audio (playback).
// Backend pipeline: presign → S3 PUT → finalize → optional transcribe.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import '../../../core/utils/theme.dart';
import '../providers/voice_notes_provider.dart';

class VoiceNotesScreen extends ConsumerStatefulWidget {
  final String? jobId;
  final String? jobTitle;

  const VoiceNotesScreen({super.key, this.jobId, this.jobTitle});

  @override
  ConsumerState<VoiceNotesScreen> createState() => _VoiceNotesScreenState();
}

class _VoiceNotesScreenState extends ConsumerState<VoiceNotesScreen>
    with SingleTickerProviderStateMixin {
  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();

  bool _isRecording = false;
  DateTime? _recordingStartedAt;
  Timer? _tickTimer;
  Duration _elapsed = Duration.zero;
  String? _activeRecordingPath;

  String? _playingNoteId;
  bool _uploading = false;

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
    _player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        if (mounted) setState(() => _playingNoteId = null);
      }
    });
  }

  @override
  void dispose() {
    _tickTimer?.cancel();
    _pulseCtrl.dispose();
    _player.dispose();
    _recorder.dispose();
    super.dispose();
  }

  // ── Recording ─────────────────────────────────────────────────────────────

  Future<void> _toggleRecord() async {
    if (_uploading) return;
    if (_isRecording) {
      await _stopAndUpload();
    } else {
      await _startRecording();
    }
  }

  Future<void> _startRecording() async {
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      _toast('Microphone permission denied', error: true);
      return;
    }
    if (!await _recorder.hasPermission()) {
      _toast('Recorder lacks permission', error: true);
      return;
    }

    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/voice-${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _recorder.start(
      const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 128000),
      path: path,
    );
    setState(() {
      _isRecording = true;
      _activeRecordingPath = path;
      _recordingStartedAt = DateTime.now();
      _elapsed = Duration.zero;
    });
    _pulseCtrl.repeat(reverse: true);
    _tickTimer?.cancel();
    _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _recordingStartedAt == null) return;
      setState(
          () => _elapsed = DateTime.now().difference(_recordingStartedAt!));
    });
  }

  Future<void> _stopAndUpload() async {
    _tickTimer?.cancel();
    _pulseCtrl.stop();
    _pulseCtrl.reset();
    final stoppedPath = await _recorder.stop();
    final duration = _elapsed.inSeconds;
    final path = stoppedPath ?? _activeRecordingPath;
    setState(() {
      _isRecording = false;
      _recordingStartedAt = null;
    });
    if (path == null) {
      _toast('Recording lost', error: true);
      return;
    }
    if (duration < 1) {
      _toast('Too short to save');
      // Clean up the file.
      try {
        await File(path).delete();
      } catch (_) {}
      return;
    }
    setState(() => _uploading = true);
    final id = await ref.read(voiceNotesNotifierProvider.notifier).uploadRecording(
          filePath: path,
          durationSeconds: duration,
          jobId: widget.jobId,
        );
    if (!mounted) return;
    setState(() => _uploading = false);
    if (id == null) {
      _toast('Upload failed — check connection', error: true);
      return;
    }
    _toast('Voice note saved');
    // Best-effort transcription kickoff in background.
    unawaited(
        ref.read(voiceNotesNotifierProvider.notifier).transcribe(id));
    // Cleanup local file after upload.
    try {
      await File(path).delete();
    } catch (_) {}
  }

  // ── Playback ──────────────────────────────────────────────────────────────

  Future<void> _togglePlay(VoiceNote note) async {
    if (note.fileId == null) {
      _toast('No audio file attached', error: true);
      return;
    }
    if (_playingNoteId == note.id) {
      await _player.pause();
      setState(() => _playingNoteId = null);
      return;
    }
    setState(() => _playingNoteId = note.id);
    try {
      final url = await ref.read(voiceNoteUrlProvider(note.fileId!).future);
      if (url.isEmpty) throw Exception('empty url');
      await _player.setUrl(url);
      await _player.play();
    } catch (_) {
      if (!mounted) return;
      setState(() => _playingNoteId = null);
      _toast('Playback failed', error: true);
    }
  }

  void _toast(String msg, {bool error = false}) {
    final m = ScaffoldMessenger.of(context);
    m.hideCurrentSnackBar();
    m.showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor:
          error ? TradieColors.alertRed : TradieColors.electricBlue,
      duration: const Duration(seconds: 2),
    ));
  }

  // ── UI ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(voiceNotesListProvider(widget.jobId));

    return Scaffold(
      backgroundColor: TradieColors.grey50,
      appBar: AppBar(
        backgroundColor: TradieColors.white,
        elevation: 0,
        leading: const BackButton(color: TradieColors.navy),
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
                style: const TextStyle(
                    fontSize: 12, color: TradieColors.grey400),
              ),
          ],
        ),
      ),
      body: RefreshIndicator(
        color: TradieColors.electricBlue,
        onRefresh: () async =>
            ref.invalidate(voiceNotesListProvider(widget.jobId)),
        child: async.when(
          loading: () => const Center(
            child: CircularProgressIndicator(color: TradieColors.electricBlue),
          ),
          error: (err, _) => _Empty(
            icon: Iconsax.warning_2,
            title: 'Could not load voice notes',
            subtitle: err.toString(),
            color: TradieColors.alertRed,
          ),
          data: (notes) => notes.isEmpty
              ? _Empty(
                  icon: Iconsax.microphone_2,
                  title: 'No voice notes yet',
                  subtitle: widget.jobId == null
                      ? 'Record one with the button below.'
                      : 'Tap the button below to record a voice note for this job.',
                )
              : ListView.builder(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 160),
                  itemCount: notes.length,
                  itemBuilder: (_, i) => _NoteCard(
                    note: notes[i],
                    isPlaying: _playingNoteId == notes[i].id,
                    onPlayToggle: () => _togglePlay(notes[i]),
                  ),
                ),
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: _RecordButton(
        isRecording: _isRecording,
        uploading: _uploading,
        elapsed: _elapsed,
        pulseAnim: _pulseAnim,
        onTap: _toggleRecord,
      ),
    );
  }
}

// ── Sub-widgets ──────────────────────────────────────────────────────────────

class _NoteCard extends StatelessWidget {
  final VoiceNote note;
  final bool isPlaying;
  final VoidCallback onPlayToggle;
  const _NoteCard({
    required this.note,
    required this.isPlaying,
    required this.onPlayToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: TradieColors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE7E9EE)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              GestureDetector(
                onTap: note.fileId == null ? null : onPlayToggle,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: isPlaying
                        ? TradieColors.electricBlue
                        : TradieColors.electricBlue.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    isPlaying ? Iconsax.pause : Iconsax.play,
                    color: isPlaying
                        ? TradieColors.white
                        : TradieColors.electricBlue,
                    size: 20,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _fmtDuration(note.durationSeconds),
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: TradieColors.navy,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _fmtDate(note.createdAt),
                      style: const TextStyle(
                          fontSize: 12, color: TradieColors.grey400),
                    ),
                  ],
                ),
              ),
              _StatusChip(status: note.transcriptionStatus),
            ],
          ),
          if (note.transcript != null && note.transcript!.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: TradieColors.grey50,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                note.transcript!,
                style: const TextStyle(
                  fontSize: 13,
                  color: TradieColors.navy,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ],
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
          'Transcribed',
        ),
      'processing' => (
          TradieColors.safetyOrange.withValues(alpha: 0.14),
          TradieColors.safetyOrange,
          'Transcribing',
        ),
      'error' => (
          TradieColors.alertRed.withValues(alpha: 0.12),
          TradieColors.alertRed,
          'Failed',
        ),
      _ => (
          TradieColors.grey100,
          TradieColors.grey400,
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

class _RecordButton extends StatelessWidget {
  final bool isRecording;
  final bool uploading;
  final Duration elapsed;
  final Animation<double> pulseAnim;
  final VoidCallback onTap;

  const _RecordButton({
    required this.isRecording,
    required this.uploading,
    required this.elapsed,
    required this.pulseAnim,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: _statusPill(),
        ),
        const SizedBox(height: 12),
        ScaleTransition(
          scale: isRecording ? pulseAnim : const AlwaysStoppedAnimation(1.0),
          child: GestureDetector(
            onTap: uploading ? null : onTap,
            child: Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: TradieColors.alertRed,
                boxShadow: [
                  BoxShadow(
                    color: TradieColors.alertRed
                        .withValues(alpha: isRecording ? 0.4 : 0.2),
                    blurRadius: isRecording ? 24 : 12,
                    spreadRadius: isRecording ? 4 : 0,
                  ),
                ],
              ),
              child: uploading
                  ? const Padding(
                      padding: EdgeInsets.all(20),
                      child: CircularProgressIndicator(
                        color: TradieColors.white,
                        strokeWidth: 3,
                      ),
                    )
                  : Icon(
                      isRecording ? Iconsax.stop : Iconsax.microphone_2,
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

  Widget _statusPill() {
    if (uploading) {
      return _pill('Uploading…', TradieColors.electricBlue,
          icon: Iconsax.cloud_add, key: const ValueKey('uploading'));
    }
    if (isRecording) {
      final m =
          elapsed.inMinutes.remainder(60).toString().padLeft(2, '0');
      final s =
          elapsed.inSeconds.remainder(60).toString().padLeft(2, '0');
      return _pill('Recording • $m:$s', TradieColors.alertRed,
          icon: Iconsax.record, key: const ValueKey('recording'));
    }
    return _pill('Tap to record',
        TradieColors.navy.withValues(alpha: 0.85),
        key: const ValueKey('idle'));
  }

  Widget _pill(String text, Color bg, {IconData? icon, Key? key}) {
    return Container(
      key: key,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, color: TradieColors.white, size: 14),
            const SizedBox(width: 6),
          ],
          Text(
            text,
            style: const TextStyle(
              color: TradieColors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

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
    final c = color ?? TradieColors.grey400;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(
          height: MediaQuery.of(context).size.height * 0.6,
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    color: TradieColors.grey100,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Icon(icon, color: c, size: 40),
                ),
                const SizedBox(height: 16),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: TradieColors.navy,
                  ),
                ),
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Text(
                    subtitle,
                    textAlign: TextAlign.center,
                    style:
                        const TextStyle(fontSize: 14, color: TradieColors.grey400),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

String _fmtDuration(int seconds) {
  final m = (seconds ~/ 60).toString().padLeft(2, '0');
  final s = (seconds % 60).toString().padLeft(2, '0');
  return '$m:$s';
}

String _fmtDate(DateTime dt) {
  final now = DateTime.now();
  final diff = now.difference(dt);
  if (diff.inMinutes < 1) return 'Just now';
  if (diff.inHours < 1) return '${diff.inMinutes}m ago';
  if (diff.inDays < 1) return '${diff.inHours}h ago';
  return '${diff.inDays}d ago';
}
