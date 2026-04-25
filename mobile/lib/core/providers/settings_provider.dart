import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../api/api_client.dart';

// ── General Settings ───────────────────────────────────────────
final settingsProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  final resp = await ref.read(apiClientProvider).get('/settings');
  return resp.data as Map<String, dynamic>;
});

// ── Security Settings ──────────────────────────────────────────
final securitySettingsProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  final resp = await ref.read(apiClientProvider).get('/settings/security');
  return resp.data as Map<String, dynamic>;
});

// ── Scheduling Settings ────────────────────────────────────────
final schedulingSettingsProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  final resp = await ref.read(apiClientProvider).get('/settings/scheduling');
  return resp.data as Map<String, dynamic>;
});

// ── Job Settings ───────────────────────────────────────────────
final jobSettingsProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  final resp = await ref.read(apiClientProvider).get('/settings/jobs');
  return resp.data as Map<String, dynamic>;
});

// ── API Keys ───────────────────────────────────────────────────
final apiKeysProvider = FutureProvider<List<dynamic>>((ref) async {
  final resp = await ref.read(apiClientProvider).get('/settings/api-keys');
  return resp.data as List<dynamic>;
});

// ── Audit Log ──────────────────────────────────────────────────
// Key is a cache-stable string: "page|limit|action|entity_type"
// Build it with auditLogKey() and pass to auditLogProvider().
String auditLogKey({
  int page = 1,
  int limit = 50,
  String action = '',
  String entityType = '',
}) =>
    '$page|$limit|$action|$entityType';

final auditLogProvider = FutureProvider.family<Map<String, dynamic>, String>(
  (ref, key) async {
    final parts = key.split('|');
    final page = parts.isNotEmpty ? parts[0] : '1';
    final limit = parts.length > 1 ? parts[1] : '50';
    final action = parts.length > 2 ? parts[2] : '';
    final entityType = parts.length > 3 ? parts[3] : '';

    final resp = await ref.read(apiClientProvider).get(
      '/settings/audit-log',
      params: {
        'page': page,
        'limit': limit,
        if (action.isNotEmpty) 'action': action,
        if (entityType.isNotEmpty) 'entity_type': entityType,
      },
    );
    return resp.data as Map<String, dynamic>;
  },
);

// ── Sessions ────────────────────────────────────────────────────
final sessionsProvider = FutureProvider<List<dynamic>>((ref) async {
  final resp = await ref.read(apiClientProvider).get('/auth/sessions');
  return resp.data as List<dynamic>;
});

// ── MFA Status ──────────────────────────────────────────────────
final mfaStatusProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  try {
    final resp = await ref.read(apiClientProvider).get('/auth/mfa/status');
    return resp.data as Map<String, dynamic>;
  } catch (_) {
    return {'enabled': false};
  }
});

// ── Subscription ───────────────────────────────────────────────
final subscriptionProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  final resp = await ref.read(apiClientProvider).get('/subscription');
  return resp.data as Map<String, dynamic>;
});

final plansProvider = FutureProvider<List<dynamic>>((ref) async {
  final resp = await ref.read(apiClientProvider).get('/subscription/plans');
  return resp.data as List<dynamic>;
});

// ── Notifications ──────────────────────────────────────────────
final notificationPrefsProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  final resp = await ref.read(apiClientProvider).get('/notifications/preferences');
  return resp.data as Map<String, dynamic>;
});

// ── Settings Notifier ──────────────────────────────────────────
final settingsNotifierProvider =
    StateNotifierProvider<SettingsNotifier, AsyncValue<void>>(
  (ref) => SettingsNotifier(ref.read(apiClientProvider), ref),
);

class SettingsNotifier extends StateNotifier<AsyncValue<void>> {
  final ApiClient _api;
  final Ref _ref;

  SettingsNotifier(this._api, this._ref) : super(const AsyncValue.data(null));

  Future<String?> updateGeneral(Map<String, dynamic> data) async {
    try {
      await _api.patch('/settings', data: data);
      _ref.invalidate(settingsProvider);
      return null;
    } on DioException catch (e) {
      return e.response?.data?['error'] ?? 'update_failed';
    }
  }

  Future<String?> updateSecurity(Map<String, dynamic> data) async {
    try {
      await _api.patch('/settings/security', data: data);
      _ref.invalidate(securitySettingsProvider);
      return null;
    } on DioException catch (e) {
      return e.response?.data?['error'] ?? 'update_failed';
    }
  }

  Future<String?> updateScheduling(Map<String, dynamic> data) async {
    try {
      await _api.patch('/settings/scheduling', data: data);
      _ref.invalidate(schedulingSettingsProvider);
      return null;
    } on DioException catch (e) {
      return e.response?.data?['error'] ?? 'update_failed';
    }
  }

  Future<String?> updateJobSettings(Map<String, dynamic> data) async {
    try {
      await _api.patch('/settings/jobs', data: data);
      _ref.invalidate(jobSettingsProvider);
      return null;
    } on DioException catch (e) {
      return e.response?.data?['error'] ?? 'update_failed';
    }
  }

  Future<Map<String, dynamic>?> createAPIKey(String name, List<String> scopes) async {
    try {
      final resp = await _api.post('/settings/api-keys', data: {'name': name, 'scopes': scopes});
      _ref.invalidate(apiKeysProvider);
      return resp.data as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<bool> revokeAPIKey(String id) async {
    try {
      await _api.delete('/settings/api-keys/$id');
      _ref.invalidate(apiKeysProvider);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<String?> updateNotificationPrefs(Map<String, dynamic> data) async {
    try {
      await _api.patch('/notifications/preferences', data: data);
      _ref.invalidate(notificationPrefsProvider);
      return null;
    } on DioException catch (e) {
      return e.response?.data?['error'] ?? 'update_failed';
    }
  }

  Future<bool> revokeSession(String sessionId) async {
    try {
      await _api.delete('/auth/sessions/$sessionId');
      _ref.invalidate(sessionsProvider);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>?> enableMFA() async {
    try {
      final resp = await _api.post('/auth/mfa/enable');
      return resp.data as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<String?> verifyMFA(String code) async {
    try {
      await _api.post('/auth/mfa/verify', data: {'code': code});
      _ref.invalidate(mfaStatusProvider);
      return null;
    } on DioException catch (e) {
      return e.response?.data?['error'] ?? 'invalid_code';
    }
  }

  Future<String?> disableMFA(String code) async {
    try {
      await _api.post('/auth/mfa/disable', data: {'code': code});
      _ref.invalidate(mfaStatusProvider);
      return null;
    } on DioException catch (e) {
      return e.response?.data?['error'] ?? 'invalid_code';
    }
  }

  Future<String?> cancelSubscription() async {
    try {
      await _api.post('/subscription/cancel');
      _ref.invalidate(subscriptionProvider);
      return null;
    } on DioException catch (e) {
      return e.response?.data?['error'] ?? 'cancel_failed';
    }
  }

  Future<String?> startUpgrade(String planSlug, {bool yearly = false}) async {
    try {
      final resp = await _api.post('/subscription/upgrade',
          data: {'plan_slug': planSlug, 'yearly': yearly});
      return (resp.data as Map<String, dynamic>)['url'] as String?;
    } on DioException catch (e) {
      return null;
    }
  }
}
