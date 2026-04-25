import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';

// ── Invoice list (filterable by status) ───────────────────────
final invoicesProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String?>(
        (ref, status) async {
  final api = ref.read(apiClientProvider);
  final params = <String, dynamic>{};
  if (status != null) params['status'] = status;
  final resp = await api.get('/invoices', params: params.isEmpty ? null : params);
  final data = resp.data as Map<String, dynamic>;
  return List<Map<String, dynamic>>.from(data['data'] as List? ?? []);
});

// ── Single invoice with line_items + payments ─────────────────
final invoiceDetailProvider =
    FutureProvider.family<Map<String, dynamic>, String>((ref, id) async {
  final api = ref.read(apiClientProvider);
  final resp = await api.get('/invoices/$id');
  return resp.data as Map<String, dynamic>;
});

// ── Invoices actions notifier ─────────────────────────────────
class InvoicesNotifier extends StateNotifier<AsyncValue<void>> {
  final ApiClient _api;
  final Ref _ref;

  InvoicesNotifier(this._api, this._ref) : super(const AsyncData(null));

  Future<bool> sendInvoice(String id) async {
    state = const AsyncLoading();
    try {
      await _api.post('/invoices/$id/send');
      _ref.invalidate(invoicesProvider);
      _ref.invalidate(invoiceDetailProvider(id));
      state = const AsyncData(null);
      return true;
    } catch (e, st) {
      state = AsyncError(e, st);
      return false;
    }
  }

  Future<bool> recordPayment(
    String id, {
    required double amount,
    required String paymentMethod,
    String? reference,
    String? paidAt,
  }) async {
    state = const AsyncLoading();
    try {
      final body = <String, dynamic>{
        'amount': amount,
        'payment_method': paymentMethod,
        if (reference != null && reference.isNotEmpty) 'reference': reference,
        if (paidAt != null) 'paid_at': paidAt,
      };
      await _api.post('/invoices/$id/payment', data: body);
      _ref.invalidate(invoicesProvider);
      _ref.invalidate(invoiceDetailProvider(id));
      state = const AsyncData(null);
      return true;
    } catch (e, st) {
      state = AsyncError(e, st);
      return false;
    }
  }

  Future<bool> createInvoice(Map<String, dynamic> data) async {
    state = const AsyncLoading();
    try {
      await _api.post('/invoices', data: data);
      _ref.invalidate(invoicesProvider);
      state = const AsyncData(null);
      return true;
    } catch (e, st) {
      state = AsyncError(e, st);
      return false;
    }
  }

  Future<bool> deleteInvoice(String id) async {
    state = const AsyncLoading();
    try {
      await _api.delete('/invoices/$id');
      _ref.invalidate(invoicesProvider);
      state = const AsyncData(null);
      return true;
    } catch (e, st) {
      state = AsyncError(e, st);
      return false;
    }
  }

  Future<bool> issueCreditNote(
    String id, {
    required double amount,
    String? reason,
  }) async {
    state = const AsyncLoading();
    try {
      await _api.post('/invoices/$id/credit-note', data: {
        'amount': amount,
        if (reason != null && reason.isNotEmpty) 'reason': reason,
      });
      _ref.invalidate(invoiceDetailProvider(id));
      state = const AsyncData(null);
      return true;
    } catch (e, st) {
      state = AsyncError(e, st);
      return false;
    }
  }
}

final invoicesNotifierProvider =
    StateNotifierProvider<InvoicesNotifier, AsyncValue<void>>((ref) {
  final api = ref.read(apiClientProvider);
  return InvoicesNotifier(api, ref);
});
