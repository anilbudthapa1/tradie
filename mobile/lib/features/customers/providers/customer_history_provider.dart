import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';

// ── Derived timeline item (M19) ─────────────────────────────────
//
// `kind` is one of: job, quote, invoice, payment, note. For notes,
// `subKind` is the annotation kind (note, call, sms, email,
// site_visit, other). The UI keys off these to pick badge colour
// and icon.
class CustomerHistoryItem {
  final String kind;
  final String id;
  final String title;
  final String status;
  final double? amount;
  final DateTime occurredAt;
  final String ref;
  final String subKind;

  const CustomerHistoryItem({
    required this.kind,
    required this.id,
    required this.title,
    required this.status,
    required this.occurredAt,
    this.amount,
    this.ref = '',
    this.subKind = '',
  });

  factory CustomerHistoryItem.fromJson(Map<String, dynamic> j) =>
      CustomerHistoryItem(
        kind: j['kind'] as String,
        id: j['id'] as String,
        title: (j['title'] as String?) ?? '',
        status: (j['status'] as String?) ?? '',
        amount: (j['amount'] as num?)?.toDouble(),
        occurredAt:
            DateTime.tryParse(j['occurred_at']?.toString() ?? '') ??
                DateTime.now(),
        ref: (j['ref'] as String?) ?? '',
        subKind: (j['sub_kind'] as String?) ?? '',
      );
}

// Family key combines customerId + kind filter so Riverpod's
// memoisation only fires when one actually changes.
class CustomerHistoryFilter {
  final String customerId;
  final String? kind; // job | quote | invoice | payment | note | null=all
  const CustomerHistoryFilter(this.customerId, [this.kind]);

  @override
  bool operator ==(Object other) =>
      other is CustomerHistoryFilter &&
      other.customerId == customerId &&
      other.kind == kind;

  @override
  int get hashCode => Object.hash(customerId, kind);
}

final customerHistoryProvider = FutureProvider.family<
    List<CustomerHistoryItem>, CustomerHistoryFilter>((ref, f) async {
  final api = ref.read(apiClientProvider);
  final params = <String, dynamic>{};
  if (f.kind != null && f.kind!.isNotEmpty) params['kind'] = f.kind;
  final resp = await api.get('/customers/${f.customerId}/history', params: params);
  final body = resp.data as Map<String, dynamic>;
  return ((body['items'] as List<dynamic>?) ?? const [])
      .cast<Map<String, dynamic>>()
      .map(CustomerHistoryItem.fromJson)
      .toList();
});

// ── Annotation CRUD (customer_history_module records) ───────────

class CustomerHistoryAnnotation {
  final String id;
  final String customerId;
  final String? author;
  final String content;
  final String kind; // note | call | sms | email | site_visit | other
  final String status; // active | archived
  final DateTime createdAt;
  final DateTime updatedAt;

  const CustomerHistoryAnnotation({
    required this.id,
    required this.customerId,
    this.author,
    required this.content,
    required this.kind,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
  });

  factory CustomerHistoryAnnotation.fromJson(Map<String, dynamic> j) =>
      CustomerHistoryAnnotation(
        id: j['id'] as String,
        customerId: j['customer_id'] as String,
        author: j['author'] as String?,
        content: (j['content'] as String?) ?? '',
        kind: (j['kind'] as String?) ?? 'note',
        status: (j['status'] as String?) ?? 'active',
        createdAt:
            DateTime.tryParse(j['created_at']?.toString() ?? '') ??
                DateTime.now(),
        updatedAt:
            DateTime.tryParse(j['updated_at']?.toString() ?? '') ??
                DateTime.now(),
      );
}

final customerAnnotationsProvider = FutureProvider.family<
    List<CustomerHistoryAnnotation>, String>((ref, customerId) async {
  final api = ref.read(apiClientProvider);
  final resp = await api.get('/customers/$customerId/notes');
  return (resp.data as List<dynamic>)
      .cast<Map<String, dynamic>>()
      .map(CustomerHistoryAnnotation.fromJson)
      .toList();
});

final customerHistoryNotifierProvider = StateNotifierProvider<
    CustomerHistoryNotifier, AsyncValue<void>>(
  (ref) => CustomerHistoryNotifier(ref.read(apiClientProvider), ref),
);

class CustomerHistoryNotifier extends StateNotifier<AsyncValue<void>> {
  final ApiClient _api;
  final Ref _ref;
  CustomerHistoryNotifier(this._api, this._ref)
      : super(const AsyncValue.data(null));

  Future<String?> create(String customerId, {
    required String content,
    String kind = 'note',
  }) async {
    try {
      await _api.post('/customers/$customerId/notes', data: {
        'content': content,
        'kind': kind,
      });
      _ref.invalidate(customerAnnotationsProvider);
      _ref.invalidate(customerHistoryProvider);
      return null;
    } on DioException catch (e) {
      return e.response?.data?['error'] ?? 'create_failed';
    }
  }

  Future<String?> update(String id, Map<String, dynamic> patch) async {
    try {
      await _api.patch('/customer_history/$id', data: patch);
      _ref.invalidate(customerAnnotationsProvider);
      _ref.invalidate(customerHistoryProvider);
      return null;
    } on DioException catch (e) {
      return e.response?.data?['error'] ?? 'update_failed';
    }
  }

  Future<bool> archive(String id) async => (await update(id, {'status': 'archived'})) == null;
  Future<bool> restore(String id) async => (await update(id, {'status': 'active'})) == null;

  Future<bool> delete(String id) async {
    try {
      await _api.delete('/customer_history/$id');
      _ref.invalidate(customerAnnotationsProvider);
      _ref.invalidate(customerHistoryProvider);
      return true;
    } catch (_) {
      return false;
    }
  }
}
