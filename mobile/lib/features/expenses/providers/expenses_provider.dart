import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';

// ── Expense list (filterable) ─────────────────────────────────
final expensesProvider =
    FutureProvider.family<List<Map<String, dynamic>>, Map<String, String?>>(
        (ref, filters) async {
  final api = ref.read(apiClientProvider);
  final params = <String, dynamic>{};
  filters.forEach((k, v) {
    if (v != null && v.isNotEmpty) params[k] = v;
  });
  final resp = await api.get(
    '/expenses',
    params: params.isEmpty ? null : params,
  );
  final data = resp.data as Map<String, dynamic>;
  return List<Map<String, dynamic>>.from(data['data'] as List? ?? []);
});

// ── Expense list with no filters (convenience) ────────────────
final allExpensesProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final api = ref.read(apiClientProvider);
  final resp = await api.get('/expenses');
  final data = resp.data as Map<String, dynamic>;
  return List<Map<String, dynamic>>.from(data['data'] as List? ?? []);
});

// ── Monthly summary ───────────────────────────────────────────
final expenseSummaryProvider =
    FutureProvider<Map<String, dynamic>>((ref) async {
  final api = ref.read(apiClientProvider);
  final resp = await api.get('/expenses/summary');
  return resp.data as Map<String, dynamic>;
});

// ── Single expense ────────────────────────────────────────────
final expenseDetailProvider =
    FutureProvider.family<Map<String, dynamic>, String>((ref, id) async {
  final api = ref.read(apiClientProvider);
  final resp = await api.get('/expenses/$id');
  return resp.data as Map<String, dynamic>;
});

// ── Accountant export ─────────────────────────────────────────
final expenseExportProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final api = ref.read(apiClientProvider);
  final resp = await api.get('/expenses/export/accountant');
  final data = resp.data as Map<String, dynamic>;
  return List<Map<String, dynamic>>.from(data['data'] as List? ?? []);
});

// ── Expense mutations ─────────────────────────────────────────
class ExpenseNotifier extends StateNotifier<AsyncValue<void>> {
  final ApiClient _api;
  final Ref _ref;

  ExpenseNotifier(this._api, this._ref) : super(const AsyncData(null));

  Future<bool> createExpense(Map<String, dynamic> data) async {
    state = const AsyncLoading();
    try {
      await _api.post('/expenses', data: data);
      _ref.invalidate(allExpensesProvider);
      _ref.invalidate(expenseSummaryProvider);
      // Invalidate family providers with empty filter too
      _ref.invalidate(expensesProvider);
      state = const AsyncData(null);
      return true;
    } catch (e, st) {
      state = AsyncError(e, st);
      return false;
    }
  }

  Future<bool> updateExpense(String id, Map<String, dynamic> data) async {
    state = const AsyncLoading();
    try {
      await _api.patch('/expenses/$id', data: data);
      _ref.invalidate(allExpensesProvider);
      _ref.invalidate(expenseSummaryProvider);
      _ref.invalidate(expensesProvider);
      _ref.invalidate(expenseDetailProvider(id));
      state = const AsyncData(null);
      return true;
    } catch (e, st) {
      state = AsyncError(e, st);
      return false;
    }
  }

  Future<bool> deleteExpense(String id) async {
    state = const AsyncLoading();
    try {
      await _api.delete('/expenses/$id');
      _ref.invalidate(allExpensesProvider);
      _ref.invalidate(expenseSummaryProvider);
      _ref.invalidate(expensesProvider);
      state = const AsyncData(null);
      return true;
    } catch (e, st) {
      state = AsyncError(e, st);
      return false;
    }
  }
}

final expenseNotifierProvider =
    StateNotifierProvider<ExpenseNotifier, AsyncValue<void>>((ref) {
  final api = ref.read(apiClientProvider);
  return ExpenseNotifier(api, ref);
});
