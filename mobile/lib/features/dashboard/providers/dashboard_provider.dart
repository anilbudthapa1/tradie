import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';

// ── Dashboard stats (full payload) ───────────────────────────────
final dashboardStatsProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  final resp = await ref.read(apiClientProvider).get('/reports/dashboard');
  return resp.data as Map<String, dynamic>;
});

// ── Revenue report ────────────────────────────────────────────────
final revenueReportProvider = FutureProvider.family<Map<String, dynamic>, String>((ref, period) async {
  final resp = await ref.read(apiClientProvider).get('/reports/revenue', params: {'period': period});
  return resp.data as Map<String, dynamic>;
});

// ── Tasks ─────────────────────────────────────────────────────────
final tasksProvider = FutureProvider.family<List<dynamic>, String>((ref, status) async {
  final resp = await ref.read(apiClientProvider).get('/tasks', params: {'status': status});
  return resp.data as List<dynamic>;
});

// ── Tasks notifier ────────────────────────────────────────────────
final taskNotifierProvider =
    StateNotifierProvider<TaskNotifier, AsyncValue<void>>(
  (ref) => TaskNotifier(ref.read(apiClientProvider), ref),
);

class TaskNotifier extends StateNotifier<AsyncValue<void>> {
  final ApiClient _api;
  final Ref _ref;

  TaskNotifier(this._api, this._ref) : super(const AsyncValue.data(null));

  Future<String?> create(Map<String, dynamic> data) async {
    try {
      await _api.post('/tasks', data: data);
      _ref.invalidate(tasksProvider);
      _ref.invalidate(dashboardStatsProvider);
      return null;
    } on DioException catch (e) {
      return e.response?.data?['error'] ?? 'create_failed';
    }
  }

  Future<bool> complete(String id) async {
    try {
      await _api.post('/tasks/$id/complete');
      _ref.invalidate(tasksProvider);
      _ref.invalidate(dashboardStatsProvider);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> delete(String id) async {
    try {
      await _api.delete('/tasks/$id');
      _ref.invalidate(tasksProvider);
      _ref.invalidate(dashboardStatsProvider);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<String?> update(String id, Map<String, dynamic> data) async {
    try {
      await _api.patch('/tasks/$id', data: data);
      _ref.invalidate(tasksProvider);
      return null;
    } on DioException catch (e) {
      return e.response?.data?['error'] ?? 'update_failed';
    }
  }
}
