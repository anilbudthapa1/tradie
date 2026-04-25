import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';

final workersProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final client = ref.read(apiClientProvider);
  final resp = await client.get('/api/v1/workers');
  return (resp.data as List).cast<Map<String, dynamic>>();
});

final workerDetailProvider =
    FutureProvider.family<Map<String, dynamic>, String>((ref, id) async {
  final client = ref.read(apiClientProvider);
  final resp = await client.get('/api/v1/workers/$id');
  return resp.data as Map<String, dynamic>;
});

final workerTimesheetsProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((ref, id) async {
  final client = ref.read(apiClientProvider);
  final resp = await client.get('/api/v1/workers/$id/timesheets');
  return (resp.data as List).cast<Map<String, dynamic>>();
});

final workerAvailabilityProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((ref, id) async {
  final client = ref.read(apiClientProvider);
  final resp = await client.get('/api/v1/workers/$id/availability');
  return (resp.data as List).cast<Map<String, dynamic>>();
});

final workerPerformanceProvider =
    FutureProvider.family<Map<String, dynamic>, String>((ref, id) async {
  final client = ref.read(apiClientProvider);
  final resp = await client.get('/api/v1/workers/$id/performance');
  return resp.data as Map<String, dynamic>;
});

final workerPayslipsProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((ref, id) async {
  final client = ref.read(apiClientProvider);
  final resp = await client.get('/api/v1/workers/$id/payslips');
  return (resp.data as List).cast<Map<String, dynamic>>();
});

final leaveRequestsProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((ref, workerId) async {
  final client = ref.read(apiClientProvider);
  final resp = await client.get('/api/v1/payroll/leave-requests?worker_id=$workerId');
  return (resp.data as List).cast<Map<String, dynamic>>();
});

class WorkerNotifier extends StateNotifier<AsyncValue<void>> {
  final ApiClient _api;
  WorkerNotifier(this._api) : super(const AsyncValue.data(null));

  Future<Map<String, dynamic>?> createWorker(Map<String, dynamic> data) async {
    state = const AsyncValue.loading();
    try {
      final resp = await _api.post('/api/v1/workers', data: data);
      state = const AsyncValue.data(null);
      return resp.data as Map<String, dynamic>;
    } catch (e, st) {
      state = AsyncValue.error(e, st);
      return null;
    }
  }

  Future<bool> updateWorker(String id, Map<String, dynamic> data) async {
    state = const AsyncValue.loading();
    try {
      await _api.patch('/api/v1/workers/$id', data: data);
      state = const AsyncValue.data(null);
      return true;
    } catch (e, st) {
      state = AsyncValue.error(e, st);
      return false;
    }
  }

  Future<bool> submitLeaveRequest(Map<String, dynamic> data) async {
    state = const AsyncValue.loading();
    try {
      await _api.post('/api/v1/payroll/leave-requests', data: data);
      state = const AsyncValue.data(null);
      return true;
    } catch (e, st) {
      state = AsyncValue.error(e, st);
      return false;
    }
  }

  Future<bool> approveLeave(String id) async {
    try {
      await _api.post('/api/v1/payroll/leave-requests/$id/approve');
      state = const AsyncValue.data(null);
      return true;
    } catch (_) {
      return false;
    }
  }
}

final workerNotifierProvider =
    StateNotifierProvider<WorkerNotifier, AsyncValue<void>>(
  (ref) => WorkerNotifier(ref.read(apiClientProvider)),
);
