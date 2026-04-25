import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';

// ── Simple FutureProvider for list (used by existing screens) ──
final jobsProvider = FutureProvider.family<List<Map<String, dynamic>>, String?>((ref, status) async {
  final api = ref.read(apiClientProvider);
  final resp = await api.get('/jobs', params: status != null ? {'status': status} : null);
  return List<Map<String, dynamic>>.from(resp.data as List);
});

final jobProvider = FutureProvider.family<Map<String, dynamic>, String>((ref, id) async {
  final api = ref.read(apiClientProvider);
  final resp = await api.get('/jobs/$id');
  return resp.data as Map<String, dynamic>;
});

// ── JobsNotifier (stateful list management) ────────────────────

class JobsState {
  final List<Map<String, dynamic>> jobs;
  final bool loading;
  final String? error;

  const JobsState({this.jobs = const [], this.loading = false, this.error});

  JobsState copyWith({List<Map<String, dynamic>>? jobs, bool? loading, String? error}) =>
      JobsState(jobs: jobs ?? this.jobs, loading: loading ?? this.loading, error: error);
}

class JobsNotifier extends StateNotifier<JobsState> {
  final ApiClient _api;

  JobsNotifier(this._api) : super(const JobsState());

  Future<void> load({String? status}) async {
    state = state.copyWith(loading: true, error: null);
    try {
      final resp = await _api.get('/jobs', params: status != null ? {'status': status} : null);
      final list = List<Map<String, dynamic>>.from(resp.data as List);
      state = state.copyWith(jobs: list, loading: false);
    } catch (e) {
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  Future<Map<String, dynamic>?> createJob(Map<String, dynamic> data) async {
    try {
      final resp = await _api.post('/jobs', data: data);
      final job = resp.data as Map<String, dynamic>;
      state = state.copyWith(jobs: [job, ...state.jobs]);
      return job;
    } catch (e) {
      state = state.copyWith(error: e.toString());
      return null;
    }
  }

  Future<bool> updateStatus(String jobId, String status) async {
    try {
      await _api.patch('/jobs/$jobId/status', data: {'status': status});
      final updated = state.jobs.map((j) {
        if (j['id'] == jobId) return {...j, 'status': status};
        return j;
      }).toList();
      state = state.copyWith(jobs: updated);
      return true;
    } catch (e) {
      state = state.copyWith(error: e.toString());
      return false;
    }
  }
}

final jobsNotifierProvider = StateNotifierProvider<JobsNotifier, JobsState>((ref) {
  return JobsNotifier(ref.read(apiClientProvider));
});

// ── JobDetailNotifier ──────────────────────────────────────────

class JobDetailState {
  final Map<String, dynamic>? job;
  final List<Map<String, dynamic>> notes;
  final Map<String, List<Map<String, dynamic>>> photos;
  final List<Map<String, dynamic>> materials;
  final double materialsTotal;
  final bool loading;
  final String? error;

  const JobDetailState({
    this.job,
    this.notes = const [],
    this.photos = const {},
    this.materials = const [],
    this.materialsTotal = 0.0,
    this.loading = false,
    this.error,
  });

  JobDetailState copyWith({
    Map<String, dynamic>? job,
    List<Map<String, dynamic>>? notes,
    Map<String, List<Map<String, dynamic>>>? photos,
    List<Map<String, dynamic>>? materials,
    double? materialsTotal,
    bool? loading,
    String? error,
  }) =>
      JobDetailState(
        job: job ?? this.job,
        notes: notes ?? this.notes,
        photos: photos ?? this.photos,
        materials: materials ?? this.materials,
        materialsTotal: materialsTotal ?? this.materialsTotal,
        loading: loading ?? this.loading,
        error: error,
      );
}

class JobDetailNotifier extends StateNotifier<JobDetailState> {
  final ApiClient _api;
  final String jobId;

  JobDetailNotifier(this._api, this.jobId) : super(const JobDetailState());

  Future<void> load() async {
    state = state.copyWith(loading: true, error: null);
    try {
      final results = await Future.wait([
        _api.get('/jobs/$jobId'),
        _api.get('/jobs/$jobId/notes'),
        _api.get('/jobs/$jobId/photos'),
        _api.get('/jobs/$jobId/materials'),
      ]);

      final job = results[0].data as Map<String, dynamic>;
      final notes = List<Map<String, dynamic>>.from(results[1].data as List);

      final photosRaw = results[2].data as Map<String, dynamic>;
      final photos = photosRaw.map((k, v) =>
          MapEntry(k, List<Map<String, dynamic>>.from(v as List)));

      final materialsResp = results[3].data as Map<String, dynamic>;
      final materials = List<Map<String, dynamic>>.from(materialsResp['materials'] as List);
      final total = (materialsResp['total'] as num).toDouble();

      state = state.copyWith(
        job: job,
        notes: notes,
        photos: photos,
        materials: materials,
        materialsTotal: total,
        loading: false,
      );
    } catch (e) {
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  Future<bool> addNote(String content, {bool isInternal = false}) async {
    try {
      final resp = await _api.post('/jobs/$jobId/notes',
          data: {'content': content, 'is_internal': isInternal});
      final note = resp.data as Map<String, dynamic>;
      state = state.copyWith(notes: [note, ...state.notes]);
      return true;
    } catch (e) {
      state = state.copyWith(error: e.toString());
      return false;
    }
  }

  Future<bool> addMaterial(Map<String, dynamic> data) async {
    try {
      final resp = await _api.post('/jobs/$jobId/materials', data: data);
      final material = resp.data as Map<String, dynamic>;
      final newTotal = state.materialsTotal + (material['total_cost'] as num).toDouble();
      state = state.copyWith(
        materials: [...state.materials, material],
        materialsTotal: newTotal,
      );
      return true;
    } catch (e) {
      state = state.copyWith(error: e.toString());
      return false;
    }
  }

  Future<bool> uploadPhoto(Map<String, dynamic> data) async {
    try {
      final resp = await _api.post('/jobs/$jobId/photos', data: data);
      final photo = resp.data as Map<String, dynamic>;
      final phase = photo['phase'] as String? ?? 'before';
      final updated = Map<String, List<Map<String, dynamic>>>.from(state.photos);
      updated[phase] = [...(updated[phase] ?? []), photo];
      state = state.copyWith(photos: updated);
      return true;
    } catch (e) {
      state = state.copyWith(error: e.toString());
      return false;
    }
  }

  Future<bool> completeJob() async {
    try {
      final resp = await _api.post('/jobs/$jobId/complete');
      final result = resp.data as Map<String, dynamic>;
      state = state.copyWith(job: {...(state.job ?? {}), 'status': result['status']});
      return true;
    } catch (e) {
      state = state.copyWith(error: e.toString());
      return false;
    }
  }

  Future<bool> signOff(Map<String, dynamic> data) async {
    try {
      await _api.post('/jobs/$jobId/sign-off', data: data);
      return true;
    } catch (e) {
      state = state.copyWith(error: e.toString());
      return false;
    }
  }
}

final jobDetailProvider =
    StateNotifierProvider.family<JobDetailNotifier, JobDetailState, String>((ref, id) {
  return JobDetailNotifier(ref.read(apiClientProvider), id);
});

// ── CalendarNotifier ───────────────────────────────────────────

class CalendarState {
  final List<Map<String, dynamic>> events;
  final Map<String, List<Map<String, dynamic>>> dailySchedule;
  final Map<String, dynamic> weeklySchedule;
  final bool loading;
  final String? error;

  const CalendarState({
    this.events = const [],
    this.dailySchedule = const {},
    this.weeklySchedule = const {},
    this.loading = false,
    this.error,
  });

  CalendarState copyWith({
    List<Map<String, dynamic>>? events,
    Map<String, List<Map<String, dynamic>>>? dailySchedule,
    Map<String, dynamic>? weeklySchedule,
    bool? loading,
    String? error,
  }) =>
      CalendarState(
        events: events ?? this.events,
        dailySchedule: dailySchedule ?? this.dailySchedule,
        weeklySchedule: weeklySchedule ?? this.weeklySchedule,
        loading: loading ?? this.loading,
        error: error,
      );
}

class CalendarNotifier extends StateNotifier<CalendarState> {
  final ApiClient _api;

  CalendarNotifier(this._api) : super(const CalendarState());

  Future<void> loadCalendar(String start, String end) async {
    state = state.copyWith(loading: true, error: null);
    try {
      final resp = await _api.get('/jobs/calendar', params: {'start': start, 'end': end});
      final events = List<Map<String, dynamic>>.from(resp.data as List);
      state = state.copyWith(events: events, loading: false);
    } catch (e) {
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  Future<void> loadDailySchedule(String date) async {
    state = state.copyWith(loading: true, error: null);
    try {
      final resp = await _api.get('/jobs/schedule/daily', params: {'date': date});
      final data = resp.data as Map<String, dynamic>;
      final jobs = List<Map<String, dynamic>>.from(data['jobs'] as List);
      state = state.copyWith(
        dailySchedule: {date: jobs},
        loading: false,
      );
    } catch (e) {
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  Future<void> loadWeeklySchedule(String weekStart) async {
    state = state.copyWith(loading: true, error: null);
    try {
      final resp =
          await _api.get('/jobs/schedule/weekly', params: {'week_start': weekStart});
      final data = resp.data as Map<String, dynamic>;
      state = state.copyWith(weeklySchedule: data, loading: false);
    } catch (e) {
      state = state.copyWith(loading: false, error: e.toString());
    }
  }
}

final calendarNotifierProvider =
    StateNotifierProvider<CalendarNotifier, CalendarState>((ref) {
  return CalendarNotifier(ref.read(apiClientProvider));
});
