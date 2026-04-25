import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';

// ── Quote list (filterable by status) ────────────────────────
final quotesProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String?>((ref, status) async {
  final api = ref.read(apiClientProvider);
  final params = <String, dynamic>{};
  if (status != null) params['status'] = status;
  final resp = await api.get('/quotes', params: params.isEmpty ? null : params);
  // Backend returns a plain list
  final raw = resp.data;
  if (raw is List) return List<Map<String, dynamic>>.from(raw);
  // Wrapped in data envelope
  final data = raw as Map<String, dynamic>;
  return List<Map<String, dynamic>>.from(data['data'] as List? ?? []);
});

// ── Single quote detail ───────────────────────────────────────
final quoteDetailProvider =
    FutureProvider.family<Map<String, dynamic>, String>((ref, id) async {
  final api = ref.read(apiClientProvider);
  final resp = await api.get('/quotes/$id');
  return resp.data as Map<String, dynamic>;
});

// ── Quote line items ──────────────────────────────────────────
final quoteLineItemsProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((ref, id) async {
  final api = ref.read(apiClientProvider);
  final resp = await api.get('/quotes/$id/line-items');
  final raw = resp.data;
  if (raw is List) return List<Map<String, dynamic>>.from(raw);
  return List<Map<String, dynamic>>.from((raw as Map)['data'] as List? ?? []);
});

// ── Quote actions notifier ────────────────────────────────────
class QuoteNotifier extends StateNotifier<AsyncValue<void>> {
  final ApiClient _api;
  final Ref _ref;

  QuoteNotifier(this._api, this._ref) : super(const AsyncData(null));

  Future<bool> createQuote({
    required String customerId,
    required String title,
    String? validUntil,
  }) async {
    state = const AsyncLoading();
    try {
      await _api.post('/quotes', data: {
        'customer_id': customerId,
        'title': title,
        if (validUntil != null) 'valid_until': validUntil,
      });
      _ref.invalidate(quotesProvider);
      state = const AsyncData(null);
      return true;
    } catch (e, st) {
      state = AsyncError(e, st);
      return false;
    }
  }

  Future<bool> sendQuote(String id) async {
    state = const AsyncLoading();
    try {
      await _api.post('/quotes/$id/send');
      _ref.invalidate(quotesProvider);
      _ref.invalidate(quoteDetailProvider(id));
      state = const AsyncData(null);
      return true;
    } catch (e, st) {
      state = AsyncError(e, st);
      return false;
    }
  }

  /// Returns the new job_id string on success, null on failure.
  Future<String?> convertToJob(String id) async {
    state = const AsyncLoading();
    try {
      final resp = await _api.post('/quotes/$id/convert-to-job');
      _ref.invalidate(quotesProvider);
      _ref.invalidate(quoteDetailProvider(id));
      state = const AsyncData(null);
      final data = resp.data as Map<String, dynamic>;
      return data['job_id'] as String?;
    } catch (e, st) {
      state = AsyncError(e, st);
      return null;
    }
  }

  Future<bool> addLineItem(
    String id, {
    required String description,
    required double qty,
    required double price,
    double taxRate = 0.1,
  }) async {
    state = const AsyncLoading();
    try {
      await _api.post('/quotes/$id/line-items', data: {
        'description': description,
        'quantity': qty,
        'unit_price': price,
        'tax_rate': taxRate,
      });
      _ref.invalidate(quoteDetailProvider(id));
      _ref.invalidate(quoteLineItemsProvider(id));
      state = const AsyncData(null);
      return true;
    } catch (e, st) {
      state = AsyncError(e, st);
      return false;
    }
  }

  Future<bool> removeLineItem(String quoteId, String itemId) async {
    state = const AsyncLoading();
    try {
      await _api.delete('/quotes/$quoteId/line-items/$itemId');
      _ref.invalidate(quoteDetailProvider(quoteId));
      _ref.invalidate(quoteLineItemsProvider(quoteId));
      state = const AsyncData(null);
      return true;
    } catch (e, st) {
      state = AsyncError(e, st);
      return false;
    }
  }

  Future<bool> applyDiscount(String id, {double? amount, double? percentage}) async {
    state = const AsyncLoading();
    try {
      final body = <String, dynamic>{};
      if (amount != null) body['discount_amount'] = amount;
      if (percentage != null) body['discount_percentage'] = percentage;
      await _api.post('/quotes/$id/discount', data: body);
      _ref.invalidate(quoteDetailProvider(id));
      state = const AsyncData(null);
      return true;
    } catch (e, st) {
      state = AsyncError(e, st);
      return false;
    }
  }

  Future<bool> deleteQuote(String id) async {
    state = const AsyncLoading();
    try {
      await _api.delete('/quotes/$id');
      _ref.invalidate(quotesProvider);
      state = const AsyncData(null);
      return true;
    } catch (e, st) {
      state = AsyncError(e, st);
      return false;
    }
  }
}

final quoteNotifierProvider =
    StateNotifierProvider<QuoteNotifier, AsyncValue<void>>((ref) {
  final api = ref.read(apiClientProvider);
  return QuoteNotifier(api, ref);
});
