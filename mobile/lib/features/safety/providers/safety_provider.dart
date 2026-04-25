import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';

// ── Simple FutureProviders ─────────────────────────────────────

final checklistsProvider =
    FutureProvider.family<List<Map<String, dynamic>>, Map<String, String?>>((ref, filters) async {
  final api = ref.read(apiClientProvider);
  final params = <String, dynamic>{};
  if (filters['job_id'] != null) params['job_id'] = filters['job_id'];
  if (filters['status'] != null) params['status'] = filters['status'];
  final resp = await api.get('/safety/checklists', params: params.isEmpty ? null : params);
  return List<Map<String, dynamic>>.from(resp.data as List);
});

final swmsProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String?>((ref, jobId) async {
  final api = ref.read(apiClientProvider);
  final params = jobId != null ? {'job_id': jobId} : null;
  final resp = await api.get('/safety/swms', params: params);
  return List<Map<String, dynamic>>.from(resp.data as List);
});

final incidentsProvider =
    FutureProvider.family<List<Map<String, dynamic>>, Map<String, String?>>((ref, filters) async {
  final api = ref.read(apiClientProvider);
  final params = <String, dynamic>{};
  if (filters['severity'] != null) params['severity'] = filters['severity'];
  if (filters['status'] != null) params['status'] = filters['status'];
  if (filters['date_from'] != null) params['date_from'] = filters['date_from'];
  final resp = await api.get('/safety/incidents', params: params.isEmpty ? null : params);
  return List<Map<String, dynamic>>.from(resp.data as List);
});

final complianceProvider =
    FutureProvider.family<List<Map<String, dynamic>>, bool>((ref, expiringSoon) async {
  final api = ref.read(apiClientProvider);
  final params = expiringSoon ? {'expiring_soon': 'true'} : null;
  final resp = await api.get('/safety/compliance', params: params);
  return List<Map<String, dynamic>>.from(resp.data as List);
});

final ppeChecklistProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  final api = ref.read(apiClientProvider);
  final resp = await api.get('/safety/ppe');
  return resp.data as Map<String, dynamic>;
});

// ── SafetyState ────────────────────────────────────────────────

class SafetyState {
  final List<Map<String, dynamic>> checklists;
  final List<Map<String, dynamic>> swmsList;
  final List<Map<String, dynamic>> incidents;
  final List<Map<String, dynamic>> compliance;
  final bool loading;
  final String? error;
  final String? successMessage;

  const SafetyState({
    this.checklists = const [],
    this.swmsList = const [],
    this.incidents = const [],
    this.compliance = const [],
    this.loading = false,
    this.error,
    this.successMessage,
  });

  SafetyState copyWith({
    List<Map<String, dynamic>>? checklists,
    List<Map<String, dynamic>>? swmsList,
    List<Map<String, dynamic>>? incidents,
    List<Map<String, dynamic>>? compliance,
    bool? loading,
    String? error,
    String? successMessage,
  }) =>
      SafetyState(
        checklists: checklists ?? this.checklists,
        swmsList: swmsList ?? this.swmsList,
        incidents: incidents ?? this.incidents,
        compliance: compliance ?? this.compliance,
        loading: loading ?? this.loading,
        error: error,
        successMessage: successMessage,
      );
}

// ── SafetyNotifier ─────────────────────────────────────────────

class SafetyNotifier extends StateNotifier<SafetyState> {
  final ApiClient _api;

  SafetyNotifier(this._api) : super(const SafetyState());

  // ── Checklists ─────────────────────────────────────

  Future<void> loadChecklists({String? jobId, String? status}) async {
    state = state.copyWith(loading: true, error: null);
    try {
      final params = <String, dynamic>{};
      if (jobId != null) params['job_id'] = jobId;
      if (status != null) params['status'] = status;
      final resp = await _api.get('/safety/checklists', params: params.isEmpty ? null : params);
      state = state.copyWith(
        checklists: List<Map<String, dynamic>>.from(resp.data as List),
        loading: false,
      );
    } catch (e) {
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  Future<Map<String, dynamic>?> createChecklist(Map<String, dynamic> data) async {
    state = state.copyWith(loading: true, error: null);
    try {
      final resp = await _api.post('/safety/checklists', data: data);
      final item = resp.data as Map<String, dynamic>;
      state = state.copyWith(
        checklists: [item, ...state.checklists],
        loading: false,
        successMessage: 'Checklist created',
      );
      return item;
    } catch (e) {
      state = state.copyWith(loading: false, error: e.toString());
      return null;
    }
  }

  Future<bool> completeChecklist(String id, Map<String, dynamic> signature) async {
    state = state.copyWith(loading: true, error: null);
    try {
      final resp = await _api.post(
        '/safety/checklists/$id/complete',
        data: {'signature': signature},
      );
      final updated = resp.data as Map<String, dynamic>;
      final newList = state.checklists.map((c) {
        if (c['id'] == id) return {...c, 'status': updated['status']};
        return c;
      }).toList();
      state = state.copyWith(
        checklists: newList,
        loading: false,
        successMessage: 'Checklist completed and signed',
      );
      return true;
    } catch (e) {
      state = state.copyWith(loading: false, error: e.toString());
      return false;
    }
  }

  // ── SWMS ───────────────────────────────────────────

  Future<void> loadSWMS({String? jobId}) async {
    state = state.copyWith(loading: true, error: null);
    try {
      final params = jobId != null ? {'job_id': jobId} : null;
      final resp = await _api.get('/safety/swms', params: params);
      state = state.copyWith(
        swmsList: List<Map<String, dynamic>>.from(resp.data as List),
        loading: false,
      );
    } catch (e) {
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  Future<Map<String, dynamic>?> createSWMS(Map<String, dynamic> data) async {
    state = state.copyWith(loading: true, error: null);
    try {
      final resp = await _api.post('/safety/swms', data: data);
      final item = resp.data as Map<String, dynamic>;
      state = state.copyWith(
        swmsList: [item, ...state.swmsList],
        loading: false,
        successMessage: 'SWMS document created',
      );
      return item;
    } catch (e) {
      state = state.copyWith(loading: false, error: e.toString());
      return null;
    }
  }

  // ── Incidents ──────────────────────────────────────

  Future<void> loadIncidents({String? severity, String? status, String? dateFrom}) async {
    state = state.copyWith(loading: true, error: null);
    try {
      final params = <String, dynamic>{};
      if (severity != null) params['severity'] = severity;
      if (status != null) params['status'] = status;
      if (dateFrom != null) params['date_from'] = dateFrom;
      final resp = await _api.get('/safety/incidents', params: params.isEmpty ? null : params);
      state = state.copyWith(
        incidents: List<Map<String, dynamic>>.from(resp.data as List),
        loading: false,
      );
    } catch (e) {
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  Future<Map<String, dynamic>?> createIncident(Map<String, dynamic> data) async {
    state = state.copyWith(loading: true, error: null);
    try {
      final resp = await _api.post('/safety/incidents', data: data);
      final item = resp.data as Map<String, dynamic>;
      state = state.copyWith(
        incidents: [item, ...state.incidents],
        loading: false,
        successMessage: 'Incident report submitted',
      );
      return item;
    } catch (e) {
      state = state.copyWith(loading: false, error: e.toString());
      return null;
    }
  }

  Future<bool> updateIncident(String id, Map<String, dynamic> data) async {
    state = state.copyWith(loading: true, error: null);
    try {
      final resp = await _api.patch('/safety/incidents/$id', data: data);
      final updated = resp.data as Map<String, dynamic>;
      final newList = state.incidents.map((inc) {
        if (inc['id'] == id) return {...inc, ...updated};
        return inc;
      }).toList();
      state = state.copyWith(incidents: newList, loading: false);
      return true;
    } catch (e) {
      state = state.copyWith(loading: false, error: e.toString());
      return false;
    }
  }

  // ── Compliance ─────────────────────────────────────

  Future<void> loadCompliance({bool expiringSoon = false}) async {
    state = state.copyWith(loading: true, error: null);
    try {
      final params = expiringSoon ? {'expiring_soon': 'true'} : null;
      final resp = await _api.get('/safety/compliance', params: params);
      state = state.copyWith(
        compliance: List<Map<String, dynamic>>.from(resp.data as List),
        loading: false,
      );
    } catch (e) {
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  Future<Map<String, dynamic>?> addCompliance(Map<String, dynamic> data) async {
    state = state.copyWith(loading: true, error: null);
    try {
      final resp = await _api.post('/safety/compliance', data: data);
      final item = resp.data as Map<String, dynamic>;
      state = state.copyWith(
        compliance: [item, ...state.compliance],
        loading: false,
        successMessage: 'Compliance record added',
      );
      return item;
    } catch (e) {
      state = state.copyWith(loading: false, error: e.toString());
      return null;
    }
  }

  Future<bool> deleteCompliance(String id) async {
    try {
      await _api.delete('/safety/compliance/$id');
      state = state.copyWith(
        compliance: state.compliance.where((c) => c['id'] != id).toList(),
        successMessage: 'Record deleted',
      );
      return true;
    } catch (e) {
      state = state.copyWith(error: e.toString());
      return false;
    }
  }

  // ── PPE ────────────────────────────────────────────

  Future<Map<String, dynamic>?> submitPPEChecklist(Map<String, dynamic> data) async {
    state = state.copyWith(loading: true, error: null);
    try {
      final resp = await _api.post('/safety/ppe/submit', data: data);
      state = state.copyWith(loading: false, successMessage: 'PPE check submitted');
      return resp.data as Map<String, dynamic>;
    } catch (e) {
      state = state.copyWith(loading: false, error: e.toString());
      return null;
    }
  }

  void clearMessages() {
    state = state.copyWith(error: null, successMessage: null);
  }
}

final safetyNotifierProvider = StateNotifierProvider<SafetyNotifier, SafetyState>((ref) {
  return SafetyNotifier(ref.read(apiClientProvider));
});
