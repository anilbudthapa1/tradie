import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';

// ── Module 23: Staff Roles ──────────────────────────────────────

class StaffRole {
  final String id;
  final String name;
  final String slug;
  final String responsibilities;
  final String baseRole;
  final String colorToken;
  final String iconToken;
  final int displayOrder;
  final String status;
  final int assignedCount;

  const StaffRole({
    required this.id,
    required this.name,
    required this.slug,
    this.responsibilities = '',
    this.baseRole = 'worker',
    this.colorToken = 'blue',
    this.iconToken = 'people',
    this.displayOrder = 0,
    this.status = 'active',
    this.assignedCount = 0,
  });

  factory StaffRole.fromJson(Map<String, dynamic> j) => StaffRole(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? '',
        slug: (j['slug'] as String?) ?? '',
        responsibilities: (j['responsibilities'] as String?) ?? '',
        baseRole: (j['base_role'] as String?) ?? 'worker',
        colorToken: (j['color_token'] as String?) ?? 'blue',
        iconToken: (j['icon_token'] as String?) ?? 'people',
        displayOrder: (j['display_order'] as int?) ?? 0,
        status: (j['status'] as String?) ?? 'active',
        assignedCount: (j['assigned_count'] as int?) ?? 0,
      );
}

final staffRolesProvider =
    FutureProvider.family<List<StaffRole>, String?>((ref, status) async {
  final params = <String, dynamic>{};
  if (status != null && status.isNotEmpty) params['status'] = status;
  final resp =
      await ref.read(apiClientProvider).get('/staff_roles', params: params);
  return (resp.data as List<dynamic>)
      .cast<Map<String, dynamic>>()
      .map(StaffRole.fromJson)
      .toList();
});

/// Self-service: caller's own role + the active catalogue.
final myStaffRoleProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  final resp =
      await ref.read(apiClientProvider).get('/me/staff_roles_module');
  return resp.data as Map<String, dynamic>;
});

final staffRoleNotifierProvider =
    StateNotifierProvider<StaffRoleNotifier, AsyncValue<void>>(
  (ref) => StaffRoleNotifier(ref.read(apiClientProvider), ref),
);

class StaffRoleNotifier extends StateNotifier<AsyncValue<void>> {
  final ApiClient _api;
  final Ref _ref;
  StaffRoleNotifier(this._api, this._ref) : super(const AsyncValue.data(null));

  Future<String?> create(Map<String, dynamic> data) async {
    try {
      await _api.post('/staff_roles', data: data);
      _invalidate();
      return null;
    } on DioException catch (e) {
      return e.response?.data?['error'] ?? 'create_failed';
    }
  }

  Future<String?> update(String id, Map<String, dynamic> patch) async {
    try {
      await _api.patch('/staff_roles/$id', data: patch);
      _invalidate();
      return null;
    } on DioException catch (e) {
      return e.response?.data?['error'] ?? 'update_failed';
    }
  }

  Future<bool> archive(String id) async =>
      (await update(id, {'status': 'archived'})) == null;
  Future<bool> restore(String id) async =>
      (await update(id, {'status': 'active'})) == null;

  Future<bool> delete(String id) async {
    try {
      await _api.delete('/staff_roles/$id');
      _invalidate();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> assign(String roleId, List<String> userIds) async {
    try {
      await _api.post('/staff_roles/$roleId/assign',
          data: {'user_ids': userIds});
      _invalidate();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> unassign(String roleId, List<String> userIds) async {
    try {
      await _api.post('/staff_roles/$roleId/unassign',
          data: {'user_ids': userIds});
      _invalidate();
      return true;
    } catch (_) {
      return false;
    }
  }

  void _invalidate() {
    _ref.invalidate(staffRolesProvider);
    _ref.invalidate(myStaffRoleProvider);
  }
}
