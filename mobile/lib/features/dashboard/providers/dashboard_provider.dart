import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';

// ── Dashboard stats (legacy — full reports payload) ──────────────
final dashboardStatsProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  final resp = await ref.read(apiClientProvider).get('/reports/dashboard');
  return resp.data as Map<String, dynamic>;
});

// ── Module 11: owner / employee dashboard payloads ───────────────
final dashboardOwnerProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  final resp = await ref.read(apiClientProvider).get('/dashboard');
  return resp.data as Map<String, dynamic>;
});

final dashboardMeProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  final resp = await ref.read(apiClientProvider).get('/me/dashboard');
  return resp.data as Map<String, dynamic>;
});

// ── Alerts list (admin/owner) ────────────────────────────────────
final dashboardAlertsProvider =
    FutureProvider.family<List<dynamic>, String?>((ref, status) async {
  final params = <String, dynamic>{};
  if (status != null && status.isNotEmpty) params['status'] = status;
  final resp = await ref.read(apiClientProvider).get('/dashboard/alerts', params: params);
  return resp.data as List<dynamic>;
});

// ── Alert mutations ──────────────────────────────────────────────
final dashboardAlertNotifierProvider =
    StateNotifierProvider<DashboardAlertNotifier, AsyncValue<void>>(
  (ref) => DashboardAlertNotifier(ref.read(apiClientProvider), ref),
);

class DashboardAlertNotifier extends StateNotifier<AsyncValue<void>> {
  final ApiClient _api;
  final Ref _ref;
  DashboardAlertNotifier(this._api, this._ref) : super(const AsyncValue.data(null));

  Future<String?> create(Map<String, dynamic> data) async {
    try {
      await _api.post('/dashboard/alerts', data: data);
      _invalidate();
      return null;
    } on DioException catch (e) {
      return e.response?.data?['error'] ?? 'create_failed';
    }
  }

  Future<String?> update(String id, Map<String, dynamic> data) async {
    try {
      await _api.patch('/dashboard/alerts/$id', data: data);
      _invalidate();
      return null;
    } on DioException catch (e) {
      return e.response?.data?['error'] ?? 'update_failed';
    }
  }

  Future<bool> acknowledge(String id) async => (await update(id, {'status': 'acknowledged'})) == null;
  Future<bool> resolve(String id) async => (await update(id, {'status': 'resolved'})) == null;
  Future<bool> dismiss(String id) async => (await update(id, {'status': 'dismissed'})) == null;

  Future<bool> delete(String id) async {
    try {
      await _api.delete('/dashboard/alerts/$id');
      _invalidate();
      return true;
    } catch (_) {
      return false;
    }
  }

  void _invalidate() {
    _ref.invalidate(dashboardAlertsProvider);
    _ref.invalidate(dashboardOwnerProvider);
    _ref.invalidate(dashboardMeProvider);
  }
}

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

  /// Snooze a task — calls POST /api/v1/tasks/{id}/snooze.
  /// `duration` is one of "15m", "1h", "tomorrow", "1d".
  Future<bool> snooze(String id, {String duration = '1h'}) async {
    try {
      await _api.post('/tasks/$id/snooze', data: {'duration': duration});
      _ref.invalidate(tasksProvider);
      _ref.invalidate(dashboardStatsProvider);
      return true;
    } catch (_) {
      return false;
    }
  }
}
