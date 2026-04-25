import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../api/api_client.dart';

const _storage = FlutterSecureStorage();

// ── Auth state ─────────────────────────────────────────────────────
final authStateProvider = FutureProvider<Map<String, dynamic>?>((ref) async {
  final token = await _storage.read(key: 'access_token');
  if (token == null) return null;
  try {
    final client = ref.read(apiClientProvider);
    final resp = await client.get('/auth/me');
    return resp.data as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
});

// ── Auth notifier ──────────────────────────────────────────────────
final authNotifierProvider =
    StateNotifierProvider<AuthNotifier, AsyncValue<Map<String, dynamic>?>>(
  (ref) => AuthNotifier(ref.read(apiClientProvider)),
);

class AuthNotifier extends StateNotifier<AsyncValue<Map<String, dynamic>?>> {
  final ApiClient _api;

  AuthNotifier(this._api) : super(const AsyncValue.loading()) {
    _init();
  }

  Future<void> _init() async {
    final token = await _storage.read(key: 'access_token');
    if (token == null) {
      state = const AsyncValue.data(null);
      return;
    }
    try {
      final resp = await _api.get('/auth/me');
      state = AsyncValue.data(resp.data as Map<String, dynamic>);
    } catch (_) {
      state = const AsyncValue.data(null);
    }
  }

  Future<void> login(String email, String password) async {
    state = const AsyncValue.loading();
    try {
      final resp = await _api.post('/auth/login', data: {'email': email, 'password': password});
      final data = resp.data as Map<String, dynamic>;
      if (data['mfa_required'] == true) {
        state = AsyncValue.data({'mfa_required': true, 'mfa_token': data['mfa_token']});
        return;
      }
      await _api.saveTokens(data['access_token'], data['refresh_token']);
      state = AsyncValue.data(data['user'] as Map<String, dynamic>);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> verifyMFALogin(String mfaToken, String code) async {
    state = const AsyncValue.loading();
    try {
      final resp = await _api.post('/auth/mfa-login', data: {
        'mfa_token': mfaToken,
        'code': code,
      });
      final data = resp.data as Map<String, dynamic>;
      await _api.saveTokens(data['access_token'], data['refresh_token']);
      state = AsyncValue.data(data['user'] as Map<String, dynamic>);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> register({
    required String firstName,
    required String lastName,
    required String email,
    required String password,
    required String businessName,
    String? phone,
    String? timezone,
  }) async {
    state = const AsyncValue.loading();
    try {
      final resp = await _api.post('/auth/register', data: {
        'first_name': firstName,
        'last_name': lastName,
        'email': email,
        'password': password,
        'business_name': businessName,
        if (phone != null && phone.isNotEmpty) 'phone': phone,
        if (timezone != null) 'timezone': timezone,
      });
      final data = resp.data as Map<String, dynamic>;
      await _api.saveTokens(data['access_token'], data['refresh_token']);
      state = AsyncValue.data(data['user'] as Map<String, dynamic>);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<String?> forgotPassword(String email) async {
    try {
      await _api.post('/auth/forgot-password', data: {'email': email});
      return null;
    } on DioException catch (e) {
      return e.response?.data?['error'] ?? 'network_error';
    }
  }

  Future<String?> resetPassword(String token, String password) async {
    try {
      await _api.post('/auth/reset-password', data: {'token': token, 'password': password});
      return null;
    } on DioException catch (e) {
      return e.response?.data?['error'] ?? 'network_error';
    }
  }

  Future<String?> verifyEmail(String token) async {
    try {
      await _api.post('/auth/verify-email', data: {'token': token});
      return null;
    } on DioException catch (e) {
      return e.response?.data?['error'] ?? 'network_error';
    }
  }

  Future<void> acceptInvite({
    required String token,
    required String firstName,
    required String lastName,
    required String password,
    String? phone,
  }) async {
    state = const AsyncValue.loading();
    try {
      final resp = await _api.post('/auth/accept-invite', data: {
        'token': token,
        'first_name': firstName,
        'last_name': lastName,
        'password': password,
        if (phone != null && phone.isNotEmpty) 'phone': phone,
      });
      final data = resp.data as Map<String, dynamic>;
      await _api.saveTokens(data['access_token'], data['refresh_token']);
      state = AsyncValue.data(data['user'] as Map<String, dynamic>);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> logout() async {
    try {
      final refreshToken = await _storage.read(key: 'refresh_token');
      await _api.post('/auth/logout', data: {'refresh_token': refreshToken ?? ''});
    } catch (_) {}
    await _api.clearTokens();
    state = const AsyncValue.data(null);
  }

  void reset() => state = const AsyncValue.data(null);
}
