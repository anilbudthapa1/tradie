import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';

// ── Module 24: Availability + Roster ────────────────────────────

class AvailabilityBlock {
  final String id;
  final String userId;
  final String blockType; // leave|sick|training|public_holiday|unavailable|custom
  final DateTime startsAt;
  final DateTime endsAt;
  final bool allDay;
  final String reason;
  final String status; // pending|approved|cancelled
  final String? approvedBy;
  final DateTime? approvedAt;

  const AvailabilityBlock({
    required this.id,
    required this.userId,
    required this.blockType,
    required this.startsAt,
    required this.endsAt,
    this.allDay = true,
    this.reason = '',
    required this.status,
    this.approvedBy,
    this.approvedAt,
  });

  factory AvailabilityBlock.fromJson(Map<String, dynamic> j) =>
      AvailabilityBlock(
        id: j['id'] as String,
        userId: j['user_id'] as String,
        blockType: (j['block_type'] as String?) ?? 'leave',
        startsAt: DateTime.parse(j['starts_at'] as String),
        endsAt: DateTime.parse(j['ends_at'] as String),
        allDay: (j['all_day'] as bool?) ?? true,
        reason: (j['reason'] as String?) ?? '',
        status: (j['status'] as String?) ?? 'pending',
        approvedBy: j['approved_by'] as String?,
        approvedAt: DateTime.tryParse(j['approved_at']?.toString() ?? ''),
      );
}

class RosterShift {
  final String id;
  final String userId;
  final String? jobId;
  final DateTime startsAt;
  final DateTime endsAt;
  final String notes;
  final String status; // scheduled|confirmed|completed|cancelled

  const RosterShift({
    required this.id,
    required this.userId,
    this.jobId,
    required this.startsAt,
    required this.endsAt,
    this.notes = '',
    required this.status,
  });

  factory RosterShift.fromJson(Map<String, dynamic> j) => RosterShift(
        id: j['id'] as String,
        userId: j['user_id'] as String,
        jobId: j['job_id'] as String?,
        startsAt: DateTime.parse(j['starts_at'] as String),
        endsAt: DateTime.parse(j['ends_at'] as String),
        notes: (j['notes'] as String?) ?? '',
        status: (j['status'] as String?) ?? 'scheduled',
      );
}

// ── Providers ───────────────────────────────────────────────────

class BlocksFilter {
  final String? status;
  final String? userId;
  const BlocksFilter({this.status, this.userId});

  @override
  bool operator ==(Object other) =>
      other is BlocksFilter && other.status == status && other.userId == userId;
  @override
  int get hashCode => Object.hash(status, userId);
}

final availabilityBlocksProvider =
    FutureProvider.family<List<AvailabilityBlock>, BlocksFilter>((ref, f) async {
  final params = <String, dynamic>{};
  if (f.status != null && f.status!.isNotEmpty) params['status'] = f.status;
  if (f.userId != null && f.userId!.isNotEmpty) params['user_id'] = f.userId;
  final resp =
      await ref.read(apiClientProvider).get('/availability_roster', params: params);
  return (resp.data as List<dynamic>)
      .cast<Map<String, dynamic>>()
      .map(AvailabilityBlock.fromJson)
      .toList();
});

class RosterRange {
  final DateTime from;
  final DateTime to;
  final String? userId;
  const RosterRange(this.from, this.to, [this.userId]);

  @override
  bool operator ==(Object other) =>
      other is RosterRange &&
      other.from == from &&
      other.to == to &&
      other.userId == userId;
  @override
  int get hashCode => Object.hash(from, to, userId);
}

final rosterShiftsProvider =
    FutureProvider.family<List<RosterShift>, RosterRange>((ref, r) async {
  final params = <String, dynamic>{
    'from': r.from.toUtc().toIso8601String(),
    'to': r.to.toUtc().toIso8601String(),
  };
  if (r.userId != null && r.userId!.isNotEmpty) params['user_id'] = r.userId;
  final resp = await ref
      .read(apiClientProvider)
      .get('/availability_roster/roster', params: params);
  return (resp.data as List<dynamic>)
      .cast<Map<String, dynamic>>()
      .map(RosterShift.fromJson)
      .toList();
});

/// Self-service: caller's recurring pattern, open blocks, upcoming roster.
final myRosterProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  final resp =
      await ref.read(apiClientProvider).get('/me/availability_roster_module');
  return resp.data as Map<String, dynamic>;
});

// ── Mutations ───────────────────────────────────────────────────

final rosterNotifierProvider =
    StateNotifierProvider<RosterNotifier, AsyncValue<void>>(
  (ref) => RosterNotifier(ref.read(apiClientProvider), ref),
);

class RosterNotifier extends StateNotifier<AsyncValue<void>> {
  final ApiClient _api;
  final Ref _ref;
  RosterNotifier(this._api, this._ref) : super(const AsyncValue.data(null));

  Future<String?> createBlock({
    required String blockType,
    required DateTime startsAt,
    required DateTime endsAt,
    String? userId,
    bool allDay = true,
    String reason = '',
  }) async {
    try {
      final body = <String, dynamic>{
        'block_type': blockType,
        'starts_at': startsAt.toUtc().toIso8601String(),
        'ends_at': endsAt.toUtc().toIso8601String(),
        'all_day': allDay,
        'reason': reason,
      };
      if (userId != null) body['user_id'] = userId;
      await _api.post('/availability_roster', data: body);
      _invalidate();
      return null;
    } on DioException catch (e) {
      return e.response?.data?['error'] ?? 'create_failed';
    }
  }

  Future<bool> approveBlock(String id) async =>
      _patch(id, {'status': 'approved'});
  Future<bool> cancelBlock(String id) async =>
      _patch(id, {'status': 'cancelled'});

  Future<bool> _patch(String id, Map<String, dynamic> body) async {
    try {
      await _api.patch('/availability_roster/$id', data: body);
      _invalidate();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> deleteBlock(String id) async {
    try {
      await _api.delete('/availability_roster/$id');
      _invalidate();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<String?> createShift({
    required String userId,
    required DateTime startsAt,
    required DateTime endsAt,
    String? jobId,
    String notes = '',
  }) async {
    try {
      final body = <String, dynamic>{
        'user_id': userId,
        'starts_at': startsAt.toUtc().toIso8601String(),
        'ends_at': endsAt.toUtc().toIso8601String(),
        'notes': notes,
      };
      if (jobId != null) body['job_id'] = jobId;
      await _api.post('/availability_roster/roster', data: body);
      _invalidate();
      return null;
    } on DioException catch (e) {
      return e.response?.data?['error'] ?? 'create_failed';
    }
  }

  Future<bool> confirmShift(String id) async =>
      _patchShift(id, {'status': 'confirmed'});
  Future<bool> completeShift(String id) async =>
      _patchShift(id, {'status': 'completed'});
  Future<bool> cancelShift(String id) async =>
      _patchShift(id, {'status': 'cancelled'});

  Future<bool> _patchShift(String id, Map<String, dynamic> body) async {
    try {
      await _api.patch('/availability_roster/roster/$id', data: body);
      _invalidate();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> deleteShift(String id) async {
    try {
      await _api.delete('/availability_roster/roster/$id');
      _invalidate();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Replace the recurring weekly pattern for a user. The list should
  /// contain 1-7 entries, one per day_of_week (0-6).
  Future<bool> setRecurring(
    String userId,
    List<Map<String, dynamic>> slots,
  ) async {
    try {
      await _api.put('/availability_roster/recurring/$userId', data: slots);
      _invalidate();
      return true;
    } catch (_) {
      return false;
    }
  }

  void _invalidate() {
    _ref.invalidate(availabilityBlocksProvider);
    _ref.invalidate(rosterShiftsProvider);
    _ref.invalidate(myRosterProvider);
  }
}
