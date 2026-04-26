// M126 — voice notes API + upload pipeline.
//
// Three-step write flow matches the backend contract:
//   1. POST /voice-notes/presign  → upload_url + storage_key
//   2. PUT  upload_url            → raw audio bytes (no auth header)
//   3. POST /voice-notes          → finalize, creates DB rows
//
// Read flow:
//   - GET /voice-notes?job_id=…   → list (handler enforces self-vs-team)
//   - GET /files/{file_id}        → 1-hour presigned download URL for playback

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_client.dart';

class VoiceNote {
  final String id;
  final String? jobId;
  final String userId;
  final String? fileId;
  final int durationSeconds;
  final String? transcript;
  final String transcriptionStatus; // pending | processing | completed | error
  final DateTime createdAt;

  const VoiceNote({
    required this.id,
    required this.jobId,
    required this.userId,
    required this.fileId,
    required this.durationSeconds,
    required this.transcript,
    required this.transcriptionStatus,
    required this.createdAt,
  });

  factory VoiceNote.fromJson(Map<String, dynamic> j) => VoiceNote(
        id: j['id'].toString(),
        jobId: j['job_id']?.toString(),
        userId: j['user_id'].toString(),
        fileId: j['file_id']?.toString(),
        durationSeconds: (j['duration_seconds'] as num?)?.toInt() ?? 0,
        transcript: j['transcript'] as String?,
        transcriptionStatus:
            j['transcription_status']?.toString() ?? 'pending',
        createdAt: DateTime.tryParse(j['created_at']?.toString() ?? '') ??
            DateTime.now(),
      );
}

/// List voice notes for a job (or all of the caller's notes when jobId is null).
final voiceNotesListProvider =
    FutureProvider.family<List<VoiceNote>, String?>((ref, jobId) async {
  final api = ref.read(apiClientProvider);
  final resp = await api.get(
    '/api/v1/voice-notes',
    params: jobId == null ? null : {'job_id': jobId},
  );
  final data = resp.data as Map<String, dynamic>;
  final list = (data['voice_notes'] as List?) ?? const [];
  return list
      .map((e) => VoiceNote.fromJson(e as Map<String, dynamic>))
      .toList();
});

/// Resolves a presigned download URL for a voice-note's underlying file.
/// Cached per file_id; URL has a 1-hour TTL on the backend so the FutureProvider
/// is fine to be invalidated when playback fails.
final voiceNoteUrlProvider =
    FutureProvider.family<String, String>((ref, fileId) async {
  final api = ref.read(apiClientProvider);
  final resp = await api.get('/api/v1/files/$fileId');
  final data = resp.data as Map<String, dynamic>;
  return data['url']?.toString() ?? '';
});

/// Mutations: upload a recorded audio file + finalize, plus transcription
/// trigger. Local recording lifecycle (start/stop/level) lives in the screen
/// state — the notifier owns the network side only.
final voiceNotesNotifierProvider =
    StateNotifierProvider<VoiceNotesNotifier, AsyncValue<void>>(
  (ref) => VoiceNotesNotifier(ref.read(apiClientProvider), ref),
);

class VoiceNotesNotifier extends StateNotifier<AsyncValue<void>> {
  final ApiClient _api;
  final Ref _ref;
  VoiceNotesNotifier(this._api, this._ref)
      : super(const AsyncValue.data(null));

  /// Uploads a finished recording. Returns the new note's id, or null on
  /// failure. The screen reads .state for in-flight feedback.
  Future<String?> uploadRecording({
    required String filePath,
    required int durationSeconds,
    String? jobId,
    String contentType = 'audio/m4a',
    String? filename,
  }) async {
    state = const AsyncValue.loading();
    try {
      final file = File(filePath);
      final size = await file.length();
      final name =
          filename ?? filePath.split(Platform.pathSeparator).last;

      // 1) Presign
      final presignResp = await _api.post(
        '/api/v1/voice-notes/presign',
        data: {'filename': name, 'content_type': contentType},
      );
      final presign = presignResp.data as Map<String, dynamic>;
      final uploadUrl = presign['upload_url']?.toString() ?? '';
      final storageKey = presign['storage_key']?.toString() ?? '';
      if (uploadUrl.isEmpty || storageKey.isEmpty) {
        throw Exception('presign returned empty url/key');
      }

      // 2) PUT raw bytes to S3 — bare Dio (no auth interceptor).
      final bytes = await file.readAsBytes();
      await Dio().put(
        uploadUrl,
        data: bytes,
        options: Options(
          headers: {
            Headers.contentTypeHeader: contentType,
            Headers.contentLengthHeader: size,
          },
        ),
      );

      // 3) Finalize
      final finalizeResp = await _api.post(
        '/api/v1/voice-notes',
        data: {
          if (jobId != null) 'job_id': jobId,
          'storage_key': storageKey,
          'filename': name,
          'content_type': contentType,
          'size_bytes': size,
          'duration_seconds': durationSeconds,
        },
      );
      final note = finalizeResp.data as Map<String, dynamic>;
      _ref.invalidate(voiceNotesListProvider);
      state = const AsyncValue.data(null);
      return note['id']?.toString();
    } catch (e, st) {
      state = AsyncValue.error(e, st);
      return null;
    }
  }

  Future<bool> transcribe(String noteId) async {
    try {
      await _api.post('/api/v1/voice-notes/$noteId/transcribe');
      _ref.invalidate(voiceNotesListProvider);
      return true;
    } catch (_) {
      return false;
    }
  }
}
