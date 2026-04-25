import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';

// ── Search results provider ────────────────────────────────────
// Returns the full response map: { results: [...], total: N }
// Pass an empty string to get an empty result without hitting the API.
final searchProvider =
    FutureProvider.family<Map<String, dynamic>, String>((ref, query) async {
  if (query.trim().length < 2) {
    return {'results': <dynamic>[], 'total': 0};
  }
  final api = ref.read(apiClientProvider);
  final resp = await api.get('/search', params: {'q': query.trim()});
  return resp.data as Map<String, dynamic>;
});

// ── Filtered by type ──────────────────────────────────────────
// Convenience record so the screen can pass both query + type filter.
typedef SearchParams = ({String query, String type});

final searchFilteredProvider =
    FutureProvider.family<List<Map<String, dynamic>>, SearchParams>(
        (ref, params) async {
  if (params.query.trim().length < 2) return [];

  final api = ref.read(apiClientProvider);
  final queryParams = <String, dynamic>{'q': params.query.trim()};
  if (params.type != 'all') {
    queryParams['types'] = params.type;
  }
  final resp = await api.get('/search', params: queryParams);
  final data = resp.data as Map<String, dynamic>;
  return List<Map<String, dynamic>>.from(
      (data['results'] as List? ?? []));
});
