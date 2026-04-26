import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';

// ── Module 13: Task Reminders ────────────────────────────────────

final remindersListProvider =
    FutureProvider.family<List<dynamic>, String?>((ref, status) async {
  final params = <String, dynamic>{};
  if (status != null && status.isNotEmpty) params['status'] = status;
  final resp = await ref.read(apiClientProvider).get('/task_reminders', params: params);
  return resp.data as List<dynamic>;
});

final myRemindersProvider = FutureProvider<List<dynamic>>((ref) async {
  final resp = await ref.read(apiClientProvider).get('/me/task_reminders');
  return resp.data as List<dynamic>;
});

final reminderNotifierProvider =
    StateNotifierProvider<ReminderNotifier, AsyncValue<void>>(
  (ref) => ReminderNotifier(ref.read(apiClientProvider), ref),
);

class ReminderNotifier extends StateNotifier<AsyncValue<void>> {
  final ApiClient _api;
  final Ref _ref;
  ReminderNotifier(this._api, this._ref) : super(const AsyncValue.data(null));

  Future<String?> create(Map<String, dynamic> data) async {
    try {
      await _api.post('/task_reminders', data: data);
      _invalidate();
      return null;
    } on DioException catch (e) {
      return e.response?.data?['error'] ?? 'create_failed';
    }
  }

  Future<String?> update(String id, Map<String, dynamic> data) async {
    try {
      await _api.patch('/task_reminders/$id', data: data);
      _invalidate();
      return null;
    } on DioException catch (e) {
      return e.response?.data?['error'] ?? 'update_failed';
    }
  }

  Future<bool> dismiss(String id) async {
    try {
      await _api.post('/task_reminders/$id/dismiss');
      _invalidate();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> snooze(String id, {String duration = '1h'}) async {
    try {
      await _api.post('/task_reminders/$id/snooze', data: {'duration': duration});
      _invalidate();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> delete(String id) async {
    try {
      await _api.delete('/task_reminders/$id');
      _invalidate();
      return true;
    } catch (_) {
      return false;
    }
  }

  void _invalidate() {
    _ref.invalidate(remindersListProvider);
    _ref.invalidate(myRemindersProvider);
  }
}
