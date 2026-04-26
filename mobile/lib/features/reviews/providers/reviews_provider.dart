import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';

// ── Module 21: Review Requests ──────────────────────────────────

class ReviewRequest {
  final String id;
  final String? customerId;
  final String? jobId;
  final String status; // sent | opened | responded | declined | expired
  final String channel; // email | sms | push | manual
  final int? rating;
  final String? feedback;
  final String? token; // only present on Create response
  final DateTime sentAt;
  final DateTime? openedAt;
  final DateTime? respondedAt;
  final DateTime? expiresAt;
  final int reminderCount;

  const ReviewRequest({
    required this.id,
    this.customerId,
    this.jobId,
    required this.status,
    required this.channel,
    this.rating,
    this.feedback,
    this.token,
    required this.sentAt,
    this.openedAt,
    this.respondedAt,
    this.expiresAt,
    this.reminderCount = 0,
  });

  factory ReviewRequest.fromJson(Map<String, dynamic> j) => ReviewRequest(
        id: j['id'] as String,
        customerId: j['customer_id'] as String?,
        jobId: j['job_id'] as String?,
        status: (j['status'] as String?) ?? 'sent',
        channel: (j['channel'] as String?) ?? 'email',
        rating: j['rating'] as int?,
        feedback: j['feedback'] as String?,
        token: j['token'] as String?,
        sentAt: DateTime.tryParse(j['sent_at']?.toString() ?? '') ??
            DateTime.now(),
        openedAt: DateTime.tryParse(j['opened_at']?.toString() ?? ''),
        respondedAt: DateTime.tryParse(j['responded_at']?.toString() ?? ''),
        expiresAt: DateTime.tryParse(j['expires_at']?.toString() ?? ''),
        reminderCount: (j['reminder_count'] as int?) ?? 0,
      );
}

final reviewRequestsProvider =
    FutureProvider.family<List<ReviewRequest>, String?>((ref, status) async {
  final params = <String, dynamic>{};
  if (status != null && status.isNotEmpty) params['status'] = status;
  final resp =
      await ref.read(apiClientProvider).get('/reviews', params: params);
  return (resp.data as List<dynamic>)
      .cast<Map<String, dynamic>>()
      .map(ReviewRequest.fromJson)
      .toList();
});

final myReviewsProvider = FutureProvider<List<ReviewRequest>>((ref) async {
  final resp =
      await ref.read(apiClientProvider).get('/me/review_request_module');
  return (resp.data as List<dynamic>)
      .cast<Map<String, dynamic>>()
      .map(ReviewRequest.fromJson)
      .toList();
});

final reviewRequestNotifierProvider =
    StateNotifierProvider<ReviewRequestNotifier, AsyncValue<void>>(
  (ref) => ReviewRequestNotifier(ref.read(apiClientProvider), ref),
);

class ReviewRequestNotifier extends StateNotifier<AsyncValue<void>> {
  final ApiClient _api;
  final Ref _ref;
  ReviewRequestNotifier(this._api, this._ref)
      : super(const AsyncValue.data(null));

  /// Returns the created [ReviewRequest] (with `token` set) on success,
  /// or an error message string on failure.
  Future<Object?> create({
    required String customerId,
    String? jobId,
    String channel = 'email',
    int? expiresInDays,
  }) async {
    try {
      final body = <String, dynamic>{
        'customer_id': customerId,
        'channel': channel,
      };
      if (jobId != null) body['job_id'] = jobId;
      if (expiresInDays != null) body['expires_in_days'] = expiresInDays;
      final resp = await _api.post('/reviews', data: body);
      _ref.invalidate(reviewRequestsProvider);
      return ReviewRequest.fromJson(resp.data as Map<String, dynamic>);
    } on DioException catch (e) {
      return e.response?.data?['error'] ?? 'create_failed';
    }
  }

  Future<bool> remind(String id) async {
    try {
      await _api.post('/reviews/$id/remind');
      _ref.invalidate(reviewRequestsProvider);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> cancel(String id) async {
    try {
      await _api.patch('/reviews/$id', data: {'status': 'declined'});
      _ref.invalidate(reviewRequestsProvider);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> delete(String id) async {
    try {
      await _api.delete('/reviews/$id');
      _ref.invalidate(reviewRequestsProvider);
      _ref.invalidate(myReviewsProvider);
      return true;
    } catch (_) {
      return false;
    }
  }
}
