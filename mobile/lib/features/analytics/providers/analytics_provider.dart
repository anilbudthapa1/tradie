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
