import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';

// ── State ─────────────────────────────────────────────────────────────────────

class CalendarState {
  final AsyncValue<Map<String, List<Map<String, dynamic>>>> jobsByDate;
  final bool hasConflicts;
  final List<Map<String, dynamic>> conflicts;
  final DateTime focusedDay;

  const CalendarState({
    required this.jobsByDate,
    this.hasConflicts = false,
    this.conflicts = const [],
    required this.focusedDay,
  });

  CalendarState copyWith({
    AsyncValue<Map<String, List<Map<String, dynamic>>>>? jobsByDate,
    bool? hasConflicts,
    List<Map<String, dynamic>>? conflicts,
    DateTime? focusedDay,
  }) {
    return CalendarState(
      jobsByDate: jobsByDate ?? this.jobsByDate,
      hasConflicts: hasConflicts ?? this.hasConflicts,
      conflicts: conflicts ?? this.conflicts,
      focusedDay: focusedDay ?? this.focusedDay,
    );
  }
}

// ── Notifier ──────────────────────────────────────────────────────────────────

class CalendarNotifier extends StateNotifier<CalendarState> {
  final ApiClient _api;

  CalendarNotifier(this._api)
      : super(CalendarState(
          jobsByDate: const AsyncValue.loading(),
          focusedDay: DateTime.now(),
        ));

  /// Load calendar jobs for [start]..[end] from GET /jobs/calendar.
  Future<void> loadRange(DateTime start, DateTime end) async {
    state = state.copyWith(jobsByDate: const AsyncValue.loading());
    try {
      final startStr =
          '${start.year}-${start.month.toString().padLeft(2, '0')}-${start.day.toString().padLeft(2, '0')}';
      final endStr =
          '${end.year}-${end.month.toString().padLeft(2, '0')}-${end.day.toString().padLeft(2, '0')}';

      final resp = await _api.get('/jobs/calendar', params: {
        'start': startStr,
        'end': endStr,
      });

      final raw = resp.data;
      final Map<String, List<Map<String, dynamic>>> byDate = {};

      if (raw is List) {
        for (final job in raw) {
          if (job is! Map<String, dynamic>) continue;
          final scheduledStart = job['scheduled_start'] as String?;
          if (scheduledStart == null) continue;
          // Key = YYYY-MM-DD
          final dayKey = scheduledStart.length >= 10
              ? scheduledStart.substring(0, 10)
              : scheduledStart;
          byDate.putIfAbsent(dayKey, () => []).add(job);
        }
      } else if (raw is Map<String, dynamic>) {
        // Some backends return { "2026-04-25": [...] }
        raw.forEach((key, val) {
          if (val is List) {
            byDate[key] = List<Map<String, dynamic>>.from(val);
          }
        });
      }

      state = state.copyWith(jobsByDate: AsyncValue.data(byDate));
    } catch (e, st) {
      state = state.copyWith(jobsByDate: AsyncValue.error(e, st));
    }
  }

  /// Reschedule a job via POST /scheduler/drag-drop.
  Future<Map<String, dynamic>?> reschedule(
    String jobId,
    DateTime newStart,
    DateTime newEnd, {
    String? workerId,
  }) async {
    try {
      final body = <String, dynamic>{
        'job_id': jobId,
        'new_start': newStart.toUtc().toIso8601String(),
        'new_end': newEnd.toUtc().toIso8601String(),
        if (workerId != null) 'worker_id': workerId,
      };
      final resp = await _api.post('/scheduler/drag-drop', data: body);
      return resp.data as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Check worker conflicts via GET /scheduler/conflicts.
  Future<void> checkConflicts({
    required String workerId,
    required DateTime start,
    required DateTime end,
  }) async {
    try {
      final resp = await _api.get('/scheduler/conflicts', params: {
        'worker_id': workerId,
        'start': start.toUtc().toIso8601String(),
        'end': end.toUtc().toIso8601String(),
      });
      final data = resp.data as Map<String, dynamic>;
      final raw = data['conflicts'] as List? ?? [];
      state = state.copyWith(
        hasConflicts: data['has_conflicts'] == true,
        conflicts: List<Map<String, dynamic>>.from(raw),
      );
    } catch (_) {
      // Silently ignore — conflict badge just stays hidden.
    }
  }

  void setFocusedDay(DateTime day) {
    state = state.copyWith(focusedDay: day);
  }
}

// ── Provider ──────────────────────────────────────────────────────────────────

final calendarProvider =
    StateNotifierProvider<CalendarNotifier, CalendarState>((ref) {
  final api = ref.read(apiClientProvider);
  return CalendarNotifier(api);
});
