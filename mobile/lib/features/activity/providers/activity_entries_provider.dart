import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';

// ── Module 14: Activity Feed — tenant-authored entries ───────────

final activityEntriesProvider =
    FutureProvider.family<List<dynamic>, String?>((ref, status) async {
  final params = <String, dynamic>{};
  if (status != null && status.isNotEmpty) params['status'] = status;
  final resp = await ref.read(apiClientProvider).get('/activity/entries', params: params);
  return resp.data as List<dynamic>;
});

final myActivityProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  final resp = await ref.read(apiClientProvider).get('/me/activity_feed');
  return resp.data as Map<String, dynamic>;
});

final activityEntryNotifierProvider =
    StateNotifierProvider<ActivityEntryNotifier, AsyncValue<void>>(
  (ref) => ActivityEntryNotifier(ref.read(apiClientProvider), ref),
);

class ActivityEntryNotifier extends StateNotifier<AsyncValue<void>> {
  final ApiClient _api;
  final Ref _ref;
  ActivityEntryNotifier(this._api, this._ref) : super(const AsyncValue.data(null));

  Future<String?> create(Map<String, dynamic> data) async {
    try {
      await _api.post('/activity/entries', data: data);
      _invalidate();
      return null;
    } on DioException catch (e) {
      return e.response?.data?['error'] ?? 'create_failed';
    }
  }

  Future<String?> update(String id, Map<String, dynamic> data) async {
    try {
      await _api.patch('/activity/entries/$id', data: data);
      _invalidate();
      return null;
    } on DioException catch (e) {
      return e.response?.data?['error'] ?? 'update_failed';
    }
  }

  Future<bool> archive(String id) async => (await update(id, {'status': 'archived'})) == null;
  Future<bool> restore(String id) async => (await update(id, {'status': 'active'})) == null;
  Future<bool> pin(String id, bool pinned) async => (await update(id, {'pinned': pinned})) == null;

  Future<bool> delete(String id) async {
    try {
      await _api.delete('/activity/entries/$id');
      _invalidate();
      return true;
    } catch (_) {
      return false;
    }
  }

  void _invalidate() {
    _ref.invalidate(activityEntriesProvider);
    _ref.invalidate(myActivityProvider);
  }
}
