import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_client.dart';

// ── Model ─────────────────────────────────────────────────────────────────────

class Lead {
  final String id;
  final String businessId;
  final String firstName;
  final String lastName;
  final String email;
  final String phone;
  final String status;
  final String source;
  final String notes;
  final String? assignedTo;
  final String createdAt;
  final String updatedAt;

  const Lead({
    required this.id,
    required this.businessId,
    required this.firstName,
    required this.lastName,
    required this.email,
    required this.phone,
    required this.status,
    required this.source,
    required this.notes,
    this.assignedTo,
    required this.createdAt,
    required this.updatedAt,
  });

  String get fullName =>
      lastName.isNotEmpty ? '$firstName $lastName' : firstName;

  factory Lead.fromJson(Map<String, dynamic> j) => Lead(
        id: j['id'] as String,
        businessId: j['business_id'] as String,
        firstName: j['first_name'] as String,
        lastName: j['last_name'] as String? ?? '',
        email: j['email'] as String? ?? '',
        phone: j['phone'] as String? ?? '',
        status: j['status'] as String? ?? 'new',
        source: j['source'] as String? ?? '',
        notes: j['notes'] as String? ?? '',
        assignedTo: j['assigned_to'] as String?,
        createdAt: j['created_at'] as String,
        updatedAt: j['updated_at'] as String,
      );

  Map<String, dynamic> toJson() => {
        'first_name': firstName,
        'last_name': lastName,
        'email': email,
        'phone': phone,
        'status': status,
        'source': source,
        'notes': notes,
        if (assignedTo != null) 'assigned_to': assignedTo,
      };

  Lead copyWith({
    String? status,
    String? firstName,
    String? lastName,
    String? email,
    String? phone,
    String? source,
    String? notes,
    String? assignedTo,
  }) =>
      Lead(
        id: id,
        businessId: businessId,
        firstName: firstName ?? this.firstName,
        lastName: lastName ?? this.lastName,
        email: email ?? this.email,
        phone: phone ?? this.phone,
        status: status ?? this.status,
        source: source ?? this.source,
        notes: notes ?? this.notes,
        assignedTo: assignedTo ?? this.assignedTo,
        createdAt: createdAt,
        updatedAt: updatedAt,
      );
}

// ── State ─────────────────────────────────────────────────────────────────────

class LeadsState {
  final List<Lead> leads;
  final bool loading;
  final String? error;
  final String? statusFilter;

  const LeadsState({
    this.leads = const [],
    this.loading = false,
    this.error,
    this.statusFilter,
  });

  LeadsState copyWith({
    List<Lead>? leads,
    bool? loading,
    String? error,
    String? statusFilter,
  }) =>
      LeadsState(
        leads: leads ?? this.leads,
        loading: loading ?? this.loading,
        error: error,
        statusFilter: statusFilter ?? this.statusFilter,
      );

  /// Returns leads filtered by a given status.
  List<Lead> byStatus(String status) =>
      leads.where((l) => l.status == status).toList();
}

// ── Notifier ──────────────────────────────────────────────────────────────────

class LeadsNotifier extends StateNotifier<LeadsState> {
  final ApiClient _api;

  LeadsNotifier(this._api) : super(const LeadsState()) {
    load();
  }

  Future<void> load({String? status}) async {
    state = state.copyWith(loading: true, error: null, statusFilter: status);
    try {
      final params = <String, dynamic>{};
      if (status != null && status.isNotEmpty) params['status'] = status;
      final resp = await _api.get('/leads', params: params.isNotEmpty ? params : null);
      final list = (resp.data as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map(Lead.fromJson)
          .toList();
      state = state.copyWith(leads: list, loading: false);
    } catch (e) {
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  Future<Lead?> create({
    required String firstName,
    String? lastName,
    String? email,
    String? phone,
    String? source,
    String? notes,
    String? assignedTo,
  }) async {
    try {
      final resp = await _api.post('/leads', data: {
        'first_name': firstName,
        if (lastName != null && lastName.isNotEmpty) 'last_name': lastName,
        if (email != null && email.isNotEmpty) 'email': email,
        if (phone != null && phone.isNotEmpty) 'phone': phone,
        if (source != null && source.isNotEmpty) 'source': source,
        if (notes != null && notes.isNotEmpty) 'notes': notes,
        if (assignedTo != null && assignedTo.isNotEmpty)
          'assigned_to': assignedTo,
      });
      final lead = Lead.fromJson(resp.data as Map<String, dynamic>);
      state = state.copyWith(leads: [lead, ...state.leads]);
      return lead;
    } catch (e) {
      state = state.copyWith(error: e.toString());
      return null;
    }
  }

  Future<bool> updateStatus(String leadId, String newStatus) async {
    try {
      final resp = await _api.patch('/leads/$leadId', data: {'status': newStatus});
      final updated = Lead.fromJson(resp.data as Map<String, dynamic>);
      state = state.copyWith(
        leads: state.leads
            .map((l) => l.id == leadId ? updated : l)
            .toList(),
      );
      return true;
    } catch (e) {
      state = state.copyWith(error: e.toString());
      return false;
    }
  }

  Future<bool> update(String leadId, Map<String, dynamic> data) async {
    try {
      final resp = await _api.patch('/leads/$leadId', data: data);
      final updated = Lead.fromJson(resp.data as Map<String, dynamic>);
      state = state.copyWith(
        leads: state.leads
            .map((l) => l.id == leadId ? updated : l)
            .toList(),
      );
      return true;
    } catch (e) {
      state = state.copyWith(error: e.toString());
      return false;
    }
  }

  Future<bool> delete(String leadId) async {
    try {
      await _api.delete('/leads/$leadId');
      state = state.copyWith(
        leads: state.leads.where((l) => l.id != leadId).toList(),
      );
      return true;
    } catch (e) {
      state = state.copyWith(error: e.toString());
      return false;
    }
  }

  /// Convert lead to customer. Returns the new customer_id on success.
  Future<String?> convertToCustomer(String leadId) async {
    try {
      final resp = await _api.post('/leads/$leadId/convert', data: {});
      final data = resp.data as Map<String, dynamic>;
      final customerId = data['customer_id'] as String?;
      // Update lead status locally
      state = state.copyWith(
        leads: state.leads
            .map((l) => l.id == leadId ? l.copyWith(status: 'won') : l)
            .toList(),
      );
      return customerId;
    } catch (e) {
      state = state.copyWith(error: e.toString());
      return null;
    }
  }
}

// ── Provider ──────────────────────────────────────────────────────────────────

final leadsProvider =
    StateNotifierProvider<LeadsNotifier, LeadsState>(
  (ref) => LeadsNotifier(ref.read(apiClientProvider)),
);

/// M20 — workers see leads assigned to them plus unassigned 'new' leads
/// they can pick up from the field. Backend endpoint:
///   GET /api/v1/me/lead_management_module
final myLeadsProvider = FutureProvider<List<Lead>>((ref) async {
  final api = ref.read(apiClientProvider);
  final resp = await api.get('/me/lead_management_module');
  return (resp.data as List<dynamic>)
      .cast<Map<String, dynamic>>()
      .map(Lead.fromJson)
      .toList();
});
