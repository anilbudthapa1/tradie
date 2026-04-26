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

  /// M22 — drive the worker lifecycle (invited / active / suspended /
  /// archived). Backend trigger blocks invalid transitions.
  Future<bool> setWorkerStatus(String id, String status) async {
    try {
      await _api.post('/api/v1/workers/$id/status', data: {'status': status});
      state = const AsyncValue.data(null);
      return true;
    } catch (e, st) {
      state = AsyncValue.error(e, st);
      return false;
    }
  }
}

final workerNotifierProvider =
    StateNotifierProvider<WorkerNotifier, AsyncValue<void>>(
  (ref) => WorkerNotifier(ref.read(apiClientProvider)),
);

/// M22 — calling user's own worker profile + operational stats.
/// Backend: GET /api/v1/me/worker_management_module
final myWorkerProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  final client = ref.read(apiClientProvider);
  final resp = await client.get('/api/v1/me/worker_management_module');
  return resp.data as Map<String, dynamic>;
});

/// M25 — calling user's timesheets in the last 30 days + aggregate hours.
/// Backend: GET /api/v1/me/time_tracking_module
final myTimesheetsProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  final client = ref.read(apiClientProvider);
  final resp = await client.get('/api/v1/me/time_tracking_module');
  return resp.data as Map<String, dynamic>;
});

/// M26 — calling user's active check-in (or null) + recent history.
/// Backend: GET /api/v1/me/check_in_check_out_module
final myCheckInProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  final client = ref.read(apiClientProvider);
  final resp = await client.get('/api/v1/me/check_in_check_out_module');
  return resp.data as Map<String, dynamic>;
});

/// M27 — calling user's leave requests in the last 12 months + days
/// approved / pending. Backend: GET /api/v1/me/leave_management_module
final myLeaveProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  final client = ref.read(apiClientProvider);
  final resp = await client.get('/api/v1/me/leave_management_module');
  return resp.data as Map<String, dynamic>;
});

/// M28 — calling user's payslips in the last 12 months + aggregate
/// gross / net / super. Backend: GET /api/v1/me/payroll_module
final myPayrollProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  final client = ref.read(apiClientProvider);
  final resp = await client.get('/api/v1/me/payroll_module');
  return resp.data as Map<String, dynamic>;
});

/// M28 — pay-run lifecycle helpers (process / mark-paid / cancel).
final payRunLifecycleProvider =
    StateNotifierProvider<PayRunLifecycleNotifier, AsyncValue<void>>(
  (ref) => PayRunLifecycleNotifier(ref.read(apiClientProvider), ref),
);

class PayRunLifecycleNotifier extends StateNotifier<AsyncValue<void>> {
  final ApiClient _api;
  final Ref _ref;
  PayRunLifecycleNotifier(this._api, this._ref)
      : super(const AsyncValue.data(null));

  Future<Map<String, dynamic>?> process(String id) async {
    try {
      final resp = await _api.post('/api/v1/payroll/runs/$id/process');
      _ref.invalidate(myPayrollProvider);
      return resp.data as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<bool> markPaid(String id) async {
    try {
      await _api.post('/api/v1/payroll/runs/$id/pay');
      _ref.invalidate(myPayrollProvider);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> cancel(String id) async {
    try {
      await _api.post('/api/v1/payroll/runs/$id/cancel');
      _ref.invalidate(myPayrollProvider);
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// M27 — leave-request lifecycle helpers. The notifier already exists
/// for create / approve via WorkerNotifier; this notifier groups the
/// new lifecycle endpoints (cancel, edit, reject) so the UI doesn't
/// need to mix mutation classes.
final leaveLifecycleProvider =
    StateNotifierProvider<LeaveLifecycleNotifier, AsyncValue<void>>(
  (ref) => LeaveLifecycleNotifier(ref.read(apiClientProvider), ref),
);

class LeaveLifecycleNotifier extends StateNotifier<AsyncValue<void>> {
  final ApiClient _api;
  final Ref _ref;
  LeaveLifecycleNotifier(this._api, this._ref)
      : super(const AsyncValue.data(null));

  Future<bool> cancel(String id) async {
    try {
      await _api.post('/api/v1/payroll/leave-requests/$id/cancel');
      _ref.invalidate(myLeaveProvider);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> reject(String id, {String? reason}) async {
    try {
      await _api.post('/api/v1/payroll/leave-requests/$id/reject',
          data: reason == null || reason.isEmpty ? null : {'rejection_reason': reason});
      _ref.invalidate(myLeaveProvider);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> updateRequest(String id, Map<String, dynamic> patch) async {
    try {
      await _api.patch('/api/v1/payroll/leave-requests/$id', data: patch);
      _ref.invalidate(myLeaveProvider);
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// M26 — check-in / check-out actions for the calling user. The backend
/// uses the JWT identity, not any user_id from the body, so the mobile
/// client just sends location + optional job context.
final checkInNotifierProvider =
    StateNotifierProvider<CheckInNotifier, AsyncValue<void>>(
  (ref) => CheckInNotifier(ref.read(apiClientProvider), ref),
);

class CheckInNotifier extends StateNotifier<AsyncValue<void>> {
  final ApiClient _api;
  final Ref _ref;
  CheckInNotifier(this._api, this._ref)
      : super(const AsyncValue.data(null));

  Future<Map<String, dynamic>?> checkIn({
    String? jobId,
    double? lat,
    double? lng,
    double? accuracyM,
    String? notes,
  }) async {
    try {
      final body = <String, dynamic>{};
      if (jobId != null) body['job_id'] = jobId;
      if (lat != null) body['lat'] = lat;
      if (lng != null) body['lng'] = lng;
      if (accuracyM != null) body['accuracy_m'] = accuracyM;
      if (notes != null && notes.isNotEmpty) body['notes'] = notes;
      final resp = await _api.post('/api/v1/workers/check-in', data: body);
      _ref.invalidate(myCheckInProvider);
      return resp.data as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<bool> checkOut({
    double? lat,
    double? lng,
    double? accuracyM,
    String? notes,
  }) async {
    try {
      final body = <String, dynamic>{};
      if (lat != null) body['lat'] = lat;
      if (lng != null) body['lng'] = lng;
      if (accuracyM != null) body['accuracy_m'] = accuracyM;
      if (notes != null && notes.isNotEmpty) body['notes'] = notes;
      await _api.post('/api/v1/workers/check-out',
          data: body.isEmpty ? null : body);
      _ref.invalidate(myCheckInProvider);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> cancelActive(String id) async {
    try {
      await _api.post('/api/v1/workers/check-ins/$id/cancel');
      _ref.invalidate(myCheckInProvider);
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// M25 — timesheet lifecycle mutations (submit / reject / cancel).
final timesheetLifecycleProvider =
    StateNotifierProvider<TimesheetLifecycleNotifier, AsyncValue<void>>(
  (ref) => TimesheetLifecycleNotifier(ref.read(apiClientProvider), ref),
);

class TimesheetLifecycleNotifier extends StateNotifier<AsyncValue<void>> {
  final ApiClient _api;
  final Ref _ref;
  TimesheetLifecycleNotifier(this._api, this._ref)
      : super(const AsyncValue.data(null));

  Future<bool> submit(String id) async => _post('/api/v1/workers/timesheets/$id/submit');
  Future<bool> cancel(String id) async => _post('/api/v1/workers/timesheets/$id/cancel');
  Future<bool> approve(String id) async => _post('/api/v1/workers/timesheets/$id/approve');

  Future<bool> reject(String id, {String reason = ''}) async {
    try {
      await _api.post('/api/v1/workers/timesheets/$id/reject',
          data: reason.isEmpty ? null : {'reason': reason});
      _ref.invalidate(myTimesheetsProvider);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _post(String path) async {
    try {
      await _api.post(path);
      _ref.invalidate(myTimesheetsProvider);
      return true;
    } catch (_) {
      return false;
    }
  }
}
