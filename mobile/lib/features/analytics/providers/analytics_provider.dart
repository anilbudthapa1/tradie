import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';

// ── Revenue provider (period-aware) ───────────────────────────────

final revenueProvider =
    StateNotifierProvider.family<RevenueNotifier, AsyncValue<Map<String, dynamic>>, String>(
  (ref, period) => RevenueNotifier(ref.read(apiClientProvider), period),
);

class RevenueNotifier extends StateNotifier<AsyncValue<Map<String, dynamic>>> {
  final ApiClient _api;
  final String _period;

  RevenueNotifier(this._api, this._period) : super(const AsyncValue.loading()) {
    load();
  }

  Future<void> load() async {
    state = const AsyncValue.loading();
    try {
      final resp = await _api.get('/reports/revenue', params: {'period': _period});
      state = AsyncValue.data(resp.data as Map<String, dynamic>);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> refresh() => load();
}

// ── Jobs analytics provider ───────────────────────────────────────

final jobsAnalyticsProvider =
    StateNotifierProvider<JobsAnalyticsNotifier, AsyncValue<Map<String, dynamic>>>(
  (ref) => JobsAnalyticsNotifier(ref.read(apiClientProvider)),
);

class JobsAnalyticsNotifier extends StateNotifier<AsyncValue<Map<String, dynamic>>> {
  final ApiClient _api;

  JobsAnalyticsNotifier(this._api) : super(const AsyncValue.loading()) {
    load();
  }

  Future<void> load() async {
    state = const AsyncValue.loading();
    try {
      final resp = await _api.get('/reports/jobs');
      state = AsyncValue.data(resp.data as Map<String, dynamic>);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> refresh() => load();
}

// ── Worker performance provider ───────────────────────────────────

final workerPerformanceProvider =
    StateNotifierProvider<WorkerPerformanceNotifier, AsyncValue<List<dynamic>>>(
  (ref) => WorkerPerformanceNotifier(ref.read(apiClientProvider)),
);

class WorkerPerformanceNotifier extends StateNotifier<AsyncValue<List<dynamic>>> {
  final ApiClient _api;

  WorkerPerformanceNotifier(this._api) : super(const AsyncValue.loading()) {
    load();
  }

  Future<void> load() async {
    state = const AsyncValue.loading();
    try {
      final resp = await _api.get('/reports/workers');
      state = AsyncValue.data(resp.data as List<dynamic>);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> refresh() => load();
}

// ── Module 12: KPI widgets ────────────────────────────────────────

final analyticsCatalogProvider = FutureProvider<List<dynamic>>((ref) async {
  final resp = await ref.read(apiClientProvider).get('/analytics/catalog');
  return resp.data as List<dynamic>;
});

final analyticsWidgetsProvider =
    FutureProvider.family<List<dynamic>, String?>((ref, status) async {
  final params = <String, dynamic>{};
  if (status != null && status.isNotEmpty) params['status'] = status;
  final resp = await ref.read(apiClientProvider).get('/analytics/widgets', params: params);
  return resp.data as List<dynamic>;
});

final myAnalyticsWidgetsProvider = FutureProvider<List<dynamic>>((ref) async {
  final resp = await ref.read(apiClientProvider).get('/me/analytics/widgets');
  return resp.data as List<dynamic>;
});

final analyticsWidgetNotifierProvider =
    StateNotifierProvider<AnalyticsWidgetNotifier, AsyncValue<void>>(
  (ref) => AnalyticsWidgetNotifier(ref.read(apiClientProvider), ref),
);

class AnalyticsWidgetNotifier extends StateNotifier<AsyncValue<void>> {
  final ApiClient _api;
  final Ref _ref;
  AnalyticsWidgetNotifier(this._api, this._ref) : super(const AsyncValue.data(null));

  Future<String?> create(Map<String, dynamic> data) async {
    try {
      await _api.post('/analytics/widgets', data: data);
      _invalidate();
      return null;
    } on DioException catch (e) {
      return e.response?.data?['error'] ?? 'create_failed';
    }
  }

  Future<String?> update(String id, Map<String, dynamic> data) async {
    try {
      await _api.patch('/analytics/widgets/$id', data: data);
      _invalidate();
      return null;
    } on DioException catch (e) {
      return e.response?.data?['error'] ?? 'update_failed';
    }
  }

  Future<bool> archive(String id) async => (await update(id, {'status': 'archived'})) == null;
  Future<bool> restore(String id) async => (await update(id, {'status': 'active'})) == null;

  Future<bool> delete(String id) async {
    try {
      await _api.delete('/analytics/widgets/$id');
      _invalidate();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> reorder(List<String> orderedIds) async {
    try {
      await _api.post('/analytics/widgets/reorder', data: {'ordered_ids': orderedIds});
      _invalidate();
      return true;
    } catch (_) {
      return false;
    }
  }

  void _invalidate() {
    _ref.invalidate(analyticsWidgetsProvider);
    _ref.invalidate(myAnalyticsWidgetsProvider);
  }
}

// ── Finance provider (income/expense + GST) ───────────────────────

final financeAnalyticsProvider =
    StateNotifierProvider<FinanceAnalyticsNotifier, AsyncValue<Map<String, dynamic>>>(
  (ref) => FinanceAnalyticsNotifier(ref.read(apiClientProvider)),
);

class FinanceAnalyticsNotifier extends StateNotifier<AsyncValue<Map<String, dynamic>>> {
  final ApiClient _api;

  FinanceAnalyticsNotifier(this._api) : super(const AsyncValue.loading()) {
    load();
  }

  Future<void> load() async {
    state = const AsyncValue.loading();
    try {
      final results = await Future.wait([
        _api.get('/reports/income-expense'),
        _api.get('/reports/gst-bas'),
      ]);
      state = AsyncValue.data({
        'income_expense': results[0].data as List<dynamic>,
        'gst': results[1].data as Map<String, dynamic>,
      });
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> refresh() => load();
}
