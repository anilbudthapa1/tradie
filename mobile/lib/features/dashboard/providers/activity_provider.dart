import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';

// ── Activity feed item ───────────────────────────────────────────────
//
// Mirrors the backend payload from GET /api/v1/activity. Keeps the
// shape narrow on purpose: the widget renders userName, action,
// entityType, createdAt, category — anything else is opportunistic.
class ActivityItem {
  final String? id;
  final String? userId;
  final String userName;
  final String action;
  final String? entityType;
  final String? entityId;
  final DateTime createdAt;
  final String category;

  const ActivityItem({
    this.id,
    this.userId,
    required this.userName,
    required this.action,
    this.entityType,
    this.entityId,
    required this.createdAt,
    required this.category,
  });

  factory ActivityItem.fromJson(Map<String, dynamic> j) => ActivityItem(
        id: j['id']?.toString(),
        userId: j['user_id']?.toString(),
        userName: (j['user_name'] as String?) ?? 'System',
        action: (j['action'] as String?) ?? '',
        entityType: j['entity_type']?.toString(),
        entityId: j['entity_id']?.toString(),
        createdAt: DateTime.tryParse(j['created_at']?.toString() ?? '') ??
            DateTime.now(),
        category: (j['category'] as String?) ?? 'system',
      );
}

// ── Filter for the feed ──────────────────────────────────────────────
//
// We keep the filter immutable so Riverpod's family memoisation works
// without surprises. `entityType` is the most common filter the UI
// drives (e.g. "show me only customer events on this customer's
// activity tab").
class ActivityFilter {
  final int limit;
  final String? entityType;

  const ActivityFilter({this.limit = 50, this.entityType});

  @override
  bool operator ==(Object other) =>
      other is ActivityFilter &&
      other.limit == limit &&
      other.entityType == entityType;

  @override
  int get hashCode => Object.hash(limit, entityType);
}

// ── Provider ─────────────────────────────────────────────────────────

final activityFeedProvider =
    FutureProvider.family<List<ActivityItem>, ActivityFilter>((ref, filter) async {
  final api = ref.read(apiClientProvider);
  final params = <String, dynamic>{'limit': filter.limit};
  if (filter.entityType != null && filter.entityType!.isNotEmpty) {
    params['entity_type'] = filter.entityType;
  }
  final resp = await api.get('/activity', params: params);
  final body = resp.data as Map<String, dynamic>;
  final items = (body['items'] as List<dynamic>? ?? [])
      .cast<Map<String, dynamic>>()
      .map(ActivityItem.fromJson)
      .toList();
  return items;
});
