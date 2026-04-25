import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';

// One row of the unified customer history (M19).
//
// `kind` is one of: job, quote, invoice, payment, note. The UI keys
// off this to pick badge colour and icon.
class CustomerHistoryItem {
  final String kind;
  final String id;
  final String title;
  final String status;
  final double? amount;
  final DateTime occurredAt;
  final String ref;

  const CustomerHistoryItem({
    required this.kind,
    required this.id,
    required this.title,
    required this.status,
    required this.occurredAt,
    this.amount,
    this.ref = '',
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
      );
}

// Family on customerId — returns the unified timeline for one customer.
final customerHistoryProvider =
    FutureProvider.family<List<CustomerHistoryItem>, String>(
        (ref, customerId) async {
  final api = ref.read(apiClientProvider);
  final resp = await api.get('/customers/$customerId/history');
  final body = resp.data as Map<String, dynamic>;
  return ((body['items'] as List<dynamic>?) ?? const [])
      .cast<Map<String, dynamic>>()
      .map(CustomerHistoryItem.fromJson)
      .toList();
});
