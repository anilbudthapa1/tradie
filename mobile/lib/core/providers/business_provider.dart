import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../api/api_client.dart';

final businessProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  final resp = await ref.read(apiClientProvider).get('/business');
  return resp.data as Map<String, dynamic>;
});

final businessProfileProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  final resp = await ref.read(apiClientProvider).get('/business/profile');
  return resp.data as Map<String, dynamic>;
});

final businessNotifierProvider =
    StateNotifierProvider<BusinessNotifier, AsyncValue<void>>(
  (ref) => BusinessNotifier(ref.read(apiClientProvider), ref),
);

class BusinessNotifier extends StateNotifier<AsyncValue<void>> {
  final ApiClient _api;
  final Ref _ref;

  BusinessNotifier(this._api, this._ref) : super(const AsyncValue.data(null));

  Future<String?> updateBusiness(Map<String, dynamic> data) async {
    try {
      await _api.patch('/business', data: data);
      _ref.invalidate(businessProvider);
      return null;
    } on DioException catch (e) {
      return e.response?.data?['error'] ?? 'update_failed';
    }
  }

  Future<String?> updateProfile(Map<String, dynamic> data) async {
    try {
      await _api.patch('/business/profile', data: data);
      _ref.invalidate(businessProfileProvider);
      return null;
    } on DioException catch (e) {
      return e.response?.data?['error'] ?? 'update_failed';
    }
  }
}
