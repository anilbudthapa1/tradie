import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_client.dart';

class LeaveRequest {
  final String id;
  final String workerId;
  final String workerName;
  final String leaveType;
  final String startDate;
  final String endDate;
  final int daysCount;
  final String reason;
  final String status;
  final String rejectionReason;

  const LeaveRequest({
    required this.id,
    this.workerId = '',
    this.workerName = '',
    required this.leaveType,
    required this.startDate,
    required this.endDate,
    required this.daysCount,
    this.reason = '',
    required this.status,
    this.rejectionReason = '',
  });

  factory LeaveRequest.fromJson(Map<String, dynamic> json) {
    return LeaveRequest(
      id: json['id'] as String,
      workerId: json['worker_id']?.toString() ?? '',
      workerName: json['worker_name']?.toString() ?? '',
      leaveType: json['leave_type']?.toString() ?? 'annual',
      startDate: _dateOnly(json['start_date']),
      endDate: _dateOnly(json['end_date']),
      daysCount: (json['days_count'] as num?)?.toInt() ?? 0,
      reason: json['reason']?.toString() ?? '',
      status: json['status']?.toString() ?? 'pending',
      rejectionReason: json['rejection_reason']?.toString() ?? '',
    );
  }

  static String _dateOnly(dynamic raw) {
    final value = raw?.toString() ?? '';
    if (value.length >= 10) return value.substring(0, 10);
    return value;
  }
}

class LeaveFilter {
  final String status;
  final String workerId;

  const LeaveFilter({this.status = '', this.workerId = ''});

  @override
  bool operator ==(Object other) {
    return other is LeaveFilter &&
        other.status == status &&
        other.workerId == workerId;
  }

  @override
  int get hashCode => Object.hash(status, workerId);
}

final leaveRequestsProvider =
    FutureProvider.family<List<LeaveRequest>, LeaveFilter>((ref, filter) async {
  final params = <String, dynamic>{};
  if (filter.status.isNotEmpty) params['status'] = filter.status;
  if (filter.workerId.isNotEmpty) params['worker_id'] = filter.workerId;
  final resp = await ref
      .read(apiClientProvider)
      .get('/leave_management_module', params: params);
  return (resp.data as List<dynamic>)
      .cast<Map<String, dynamic>>()
      .map(LeaveRequest.fromJson)
      .toList();
});

final myLeaveManagementProvider =
    FutureProvider<Map<String, dynamic>>((ref) async {
  final resp =
      await ref.read(apiClientProvider).get('/me/leave_management_module');
  return resp.data as Map<String, dynamic>;
});

final leaveManagementNotifierProvider =
    StateNotifierProvider<LeaveManagementNotifier, AsyncValue<void>>(
  (ref) => LeaveManagementNotifier(ref.read(apiClientProvider), ref),
);

class LeaveManagementNotifier extends StateNotifier<AsyncValue<void>> {
  final ApiClient _api;
  final Ref _ref;

  LeaveManagementNotifier(this._api, this._ref)
      : super(const AsyncValue.data(null));

  Future<String?> create(Map<String, dynamic> data) async {
    try {
      await _api.post('/leave_management_module', data: data);
      _invalidate();
      return null;
    } on DioException catch (e) {
      return e.response?.data?['error']?.toString() ?? 'create_failed';
    }
  }

  Future<String?> update(String id, Map<String, dynamic> data) async {
    try {
      await _api.patch('/leave_management_module/$id', data: data);
      _invalidate();
      return null;
    } on DioException catch (e) {
      return e.response?.data?['error']?.toString() ?? 'update_failed';
    }
  }

  Future<bool> approve(String id) =>
      _post('/leave_management_module/$id/approve');

  Future<bool> cancel(String id) =>
      _post('/leave_management_module/$id/cancel');

  Future<bool> reject(String id, {String? reason}) async {
    final data = reason == null || reason.trim().isEmpty
        ? null
        : {'rejection_reason': reason.trim()};
    return _post('/leave_management_module/$id/reject', data: data);
  }

  Future<bool> delete(String id) async {
    try {
      await _api.delete('/leave_management_module/$id');
      _invalidate();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _post(String path, {dynamic data}) async {
    try {
      await _api.post(path, data: data);
      _invalidate();
      return true;
    } catch (_) {
      return false;
    }
  }

  void _invalidate() {
    _ref.invalidate(leaveRequestsProvider);
    _ref.invalidate(myLeaveManagementProvider);
  }
}
