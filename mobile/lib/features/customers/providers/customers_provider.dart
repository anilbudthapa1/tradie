import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';

// ── Models ─────────────────────────────────────────────────────────────────────

class Customer {
  final String id;
  final String firstName;
  final String? lastName;
  final String? companyName;
  final String? email;
  final String? phone;
  final String? mobile;
  final String? notes;
  final List<String> tags;
  final bool isActive;
  final String? source;
  final String status; // M15: lead | active | inactive | archived
  final String createdAt;
  final String updatedAt;

  const Customer({
    required this.id,
    required this.firstName,
    this.lastName,
    this.companyName,
    this.email,
    this.phone,
    this.mobile,
    this.notes,
    required this.tags,
    required this.isActive,
    this.source,
    this.status = 'active',
    required this.createdAt,
    required this.updatedAt,
  });

  String get fullName => lastName != null && lastName!.isNotEmpty
      ? '$firstName $lastName'
      : firstName;

  factory Customer.fromJson(Map<String, dynamic> j) => Customer(
        id: j['id'] as String,
        firstName: j['first_name'] as String,
        lastName: j['last_name'] as String?,
        companyName: j['company_name'] as String?,
        email: j['email'] as String?,
        phone: j['phone'] as String?,
        mobile: j['mobile'] as String?,
        notes: j['notes'] as String?,
        tags: (j['tags'] as List<dynamic>?)?.cast<String>() ?? [],
        isActive: j['is_active'] as bool? ?? true,
        source: j['source'] as String?,
        status: (j['status'] as String?) ?? 'active',
        createdAt: j['created_at'] as String,
        updatedAt: j['updated_at'] as String,
      );

  Map<String, dynamic> toJson() => {
        'first_name': firstName,
        'last_name': lastName ?? '',
        'company_name': companyName ?? '',
        'email': email ?? '',
        'phone': phone ?? '',
        'mobile': mobile ?? '',
        'notes': notes ?? '',
        'tags': tags,
      };

  Customer copyWith({
    String? firstName,
    String? lastName,
    String? companyName,
    String? email,
    String? phone,
    String? mobile,
    String? notes,
    List<String>? tags,
    bool? isActive,
    String? source,
    String? status,
    String? updatedAt,
  }) {
    return Customer(
      id: id,
      firstName: firstName ?? this.firstName,
      lastName: lastName ?? this.lastName,
      companyName: companyName ?? this.companyName,
      email: email ?? this.email,
      phone: phone ?? this.phone,
      mobile: mobile ?? this.mobile,
      notes: notes ?? this.notes,
      tags: tags ?? this.tags,
      isActive: isActive ?? this.isActive,
      source: source ?? this.source,
      status: status ?? this.status,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

class CustomerAddress {
  final String id;
  final String customerId;
  final String label;
  final String addressType; // M17: service | billing | postal | other
  final String addressLine1;
  final String? addressLine2;
  final String city;
  final String? state;
  final String? postcode;
  final String country;
  final bool isPrimary;
  final String status; // M17: active | archived
  final String createdAt;

  const CustomerAddress({
    required this.id,
    required this.customerId,
    required this.label,
    this.addressType = 'service',
    required this.addressLine1,
    this.addressLine2,
    required this.city,
    this.state,
    this.postcode,
    required this.country,
    required this.isPrimary,
    this.status = 'active',
    required this.createdAt,
  });

  factory CustomerAddress.fromJson(Map<String, dynamic> j) => CustomerAddress(
        id: j['id'] as String,
        customerId: j['customer_id'] as String,
        label: j['label'] as String? ?? '',
        addressType: (j['address_type'] as String?) ?? 'service',
        addressLine1: j['address_line1'] as String,
        addressLine2: j['address_line2'] as String?,
        city: j['city'] as String,
        state: j['state'] as String?,
        postcode: j['postcode'] as String?,
        country: j['country'] as String,
        isPrimary: j['is_primary'] as bool? ?? false,
        status: (j['status'] as String?) ?? 'active',
        createdAt: j['created_at'] as String,
      );

  CustomerAddress copyWith({
    String? label,
    String? addressType,
    String? addressLine1,
    String? addressLine2,
    String? city,
    String? state,
    String? postcode,
    String? country,
    bool? isPrimary,
    String? status,
  }) {
    return CustomerAddress(
      id: id,
      customerId: customerId,
      label: label ?? this.label,
      addressType: addressType ?? this.addressType,
      addressLine1: addressLine1 ?? this.addressLine1,
      addressLine2: addressLine2 ?? this.addressLine2,
      city: city ?? this.city,
      state: state ?? this.state,
      postcode: postcode ?? this.postcode,
      country: country ?? this.country,
      isPrimary: isPrimary ?? this.isPrimary,
      status: status ?? this.status,
      createdAt: createdAt,
    );
  }
}

class CustomerContact {
  final String id;
  final String customerId;
  final String name;
  final String? role;
  final String? email;
  final String? phone;
  final bool isPrimary;
  final String createdAt;

  const CustomerContact({
    required this.id,
    required this.customerId,
    required this.name,
    this.role,
    this.email,
    this.phone,
    required this.isPrimary,
    required this.createdAt,
  });

  factory CustomerContact.fromJson(Map<String, dynamic> j) => CustomerContact(
        id: j['id'] as String,
        customerId: j['customer_id'] as String,
        name: j['name'] as String,
        role: j['role'] as String?,
        email: j['email'] as String?,
        phone: j['phone'] as String?,
        isPrimary: j['is_primary'] as bool? ?? false,
        createdAt: j['created_at'] as String,
      );
}

class CustomerNote {
  final String id;
  final String customerId;
  final String content;
  final String? createdBy;
  final String? author;
  final String createdAt;

  const CustomerNote({
    required this.id,
    required this.customerId,
    required this.content,
    this.createdBy,
    this.author,
    required this.createdAt,
  });

  factory CustomerNote.fromJson(Map<String, dynamic> j) => CustomerNote(
        id: j['id'] as String,
        customerId: j['customer_id'] as String,
        content: j['content'] as String,
        createdBy: j['created_by'] as String?,
        author: j['author'] as String?,
        createdAt: j['created_at'] as String,
      );
}

class JobSummary {
  final String id;
  final String jobNumber;
  final String title;
  final String status;
  final String priority;
  final String? scheduledStart;
  final String createdAt;

  const JobSummary({
    required this.id,
    required this.jobNumber,
    required this.title,
    required this.status,
    required this.priority,
    this.scheduledStart,
    required this.createdAt,
  });

  factory JobSummary.fromJson(Map<String, dynamic> j) => JobSummary(
        id: j['id'] as String,
        jobNumber: j['job_number'] as String,
        title: j['title'] as String,
        status: j['status'] as String,
        priority: j['priority'] as String,
        scheduledStart: j['scheduled_start'] as String?,
        createdAt: j['created_at'] as String,
      );
}

class QuoteSummary {
  final String id;
  final String quoteNumber;
  final String title;
  final String status;
  final double total;
  final String createdAt;

  const QuoteSummary({
    required this.id,
    required this.quoteNumber,
    required this.title,
    required this.status,
    required this.total,
    required this.createdAt,
  });

  factory QuoteSummary.fromJson(Map<String, dynamic> j) => QuoteSummary(
        id: j['id'] as String,
        quoteNumber: j['quote_number'] as String,
        title: j['title'] as String,
        status: j['status'] as String,
        total: (j['total'] as num).toDouble(),
        createdAt: j['created_at'] as String,
      );
}

class InvoiceSummary {
  final String id;
  final String invoiceNumber;
  final String status;
  final double total;
  final double amountPaid;
  final String? dueDate;
  final String createdAt;

  const InvoiceSummary({
    required this.id,
    required this.invoiceNumber,
    required this.status,
    required this.total,
    required this.amountPaid,
    this.dueDate,
    required this.createdAt,
  });

  factory InvoiceSummary.fromJson(Map<String, dynamic> j) => InvoiceSummary(
        id: j['id'] as String,
        invoiceNumber: j['invoice_number'] as String,
        status: j['status'] as String,
        total: (j['total'] as num).toDouble(),
        amountPaid: (j['amount_paid'] as num).toDouble(),
        dueDate: j['due_date'] as String?,
        createdAt: j['created_at'] as String,
      );
}

// ── CustomerDetail composite ────────────────────────────────────────────────────

class CustomerDetail {
  final Customer customer;
  final List<CustomerAddress> addresses;
  final List<CustomerContact> contacts;
  final List<CustomerNote> notes;
  final List<JobSummary> jobs;
  final List<QuoteSummary> quotes;
  final List<InvoiceSummary> invoices;

  const CustomerDetail({
    required this.customer,
    this.addresses = const [],
    this.contacts = const [],
    this.notes = const [],
    this.jobs = const [],
    this.quotes = const [],
    this.invoices = const [],
  });

  CustomerDetail copyWith({
    Customer? customer,
    List<CustomerAddress>? addresses,
    List<CustomerContact>? contacts,
    List<CustomerNote>? notes,
    List<JobSummary>? jobs,
    List<QuoteSummary>? quotes,
    List<InvoiceSummary>? invoices,
  }) =>
      CustomerDetail(
        customer: customer ?? this.customer,
        addresses: addresses ?? this.addresses,
        contacts: contacts ?? this.contacts,
        notes: notes ?? this.notes,
        jobs: jobs ?? this.jobs,
        quotes: quotes ?? this.quotes,
        invoices: invoices ?? this.invoices,
      );
}

// ── CustomerListNotifier ───────────────────────────────────────────────────────

final customerListProvider =
    StateNotifierProvider<CustomerListNotifier, AsyncValue<List<Customer>>>(
  (ref) => CustomerListNotifier(ref.read(apiClientProvider)),
);

class CustomerListNotifier extends StateNotifier<AsyncValue<List<Customer>>> {
  final ApiClient _api;

  CustomerListNotifier(this._api) : super(const AsyncValue.loading()) {
    load();
  }

  Future<void> load({String? search}) async {
    state = const AsyncValue.loading();
    try {
      final resp = await _api.get(
        '/customers',
        params: search != null && search.isNotEmpty ? {'search': search} : null,
      );
      final data = (resp.data as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map(Customer.fromJson)
          .toList();
      state = AsyncValue.data(data);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<Customer?> create({
    required String firstName,
    String? lastName,
    String? companyName,
    String? email,
    String? phone,
    String? mobile,
    List<String> tags = const [],
    String? source,
  }) async {
    try {
      final resp = await _api.post('/customers', data: {
        'first_name': firstName,
        if (lastName != null && lastName.isNotEmpty) 'last_name': lastName,
        if (companyName != null && companyName.isNotEmpty)
          'company_name': companyName,
        if (email != null && email.isNotEmpty) 'email': email,
        if (phone != null && phone.isNotEmpty) 'phone': phone,
        if (mobile != null && mobile.isNotEmpty) 'mobile': mobile,
        'tags': tags,
        if (source != null && source.isNotEmpty) 'source': source,
      });
      final customer = Customer.fromJson(resp.data as Map<String, dynamic>);
      // Prepend to list
      final current = state.valueOrNull ?? [];
      state = AsyncValue.data([customer, ...current]);
      return customer;
    } catch (_) {
      return null;
    }
  }
}

// ── CustomerDetailNotifier ─────────────────────────────────────────────────────

final customerDetailProvider = StateNotifierProvider.family<
    CustomerDetailNotifier, AsyncValue<CustomerDetail>, String>(
  (ref, id) => CustomerDetailNotifier(ref.read(apiClientProvider), id),
);

class CustomerDetailNotifier
    extends StateNotifier<AsyncValue<CustomerDetail>> {
  final ApiClient _api;
  final String _id;

  CustomerDetailNotifier(this._api, this._id)
      : super(const AsyncValue.loading()) {
    loadAll();
  }

  Future<void> loadAll() async {
    state = const AsyncValue.loading();
    try {
      // Load customer core first
      final cResp = await _api.get('/customers/$_id');
      final customer =
          Customer.fromJson(cResp.data as Map<String, dynamic>);

      // Load sub-resources in parallel
      final results = await Future.wait([
        _api.get('/customers/$_id/addresses'),
        _api.get('/customers/$_id/contacts'),
        _api.get('/customers/$_id/notes'),
        _api.get('/customers/$_id/jobs'),
        _api.get('/customers/$_id/quotes'),
        _api.get('/customers/$_id/invoices'),
      ]);

      final addresses = (results[0].data as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map(CustomerAddress.fromJson)
          .toList();
      final contacts = (results[1].data as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map(CustomerContact.fromJson)
          .toList();
      final notes = (results[2].data as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map(CustomerNote.fromJson)
          .toList();
      final jobs = (results[3].data as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map(JobSummary.fromJson)
          .toList();
      final quotes = (results[4].data as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map(QuoteSummary.fromJson)
          .toList();
      final invoices = (results[5].data as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map(InvoiceSummary.fromJson)
          .toList();

      state = AsyncValue.data(CustomerDetail(
        customer: customer,
        addresses: addresses,
        contacts: contacts,
        notes: notes,
        jobs: jobs,
        quotes: quotes,
        invoices: invoices,
      ));
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<bool> update({
    required String firstName,
    String? lastName,
    String? companyName,
    String? email,
    String? phone,
    String? mobile,
    String? notes,
    List<String> tags = const [],
  }) async {
    try {
      final resp = await _api.put('/customers/$_id', data: {
        'first_name': firstName,
        'last_name': lastName ?? '',
        'company_name': companyName ?? '',
        'email': email ?? '',
        'phone': phone ?? '',
        'mobile': mobile ?? '',
        'notes': notes ?? '',
        'tags': tags,
      });
      final updated = Customer.fromJson(resp.data as Map<String, dynamic>);
      final current = state.valueOrNull;
      if (current != null) {
        state = AsyncValue.data(current.copyWith(customer: updated));
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> addAddress({
    required String addressLine1,
    String? addressLine2,
    required String city,
    String? state,
    String? postcode,
    required String country,
    String label = '',
    String addressType = 'service',
    bool isPrimary = false,
  }) async {
    try {
      final resp = await _api.post('/customers/$_id/addresses', data: {
        'label': label,
        'address_type': addressType,
        'address_line1': addressLine1,
        'address_line2': addressLine2 ?? '',
        'city': city,
        'state': state ?? '',
        'postcode': postcode ?? '',
        'country': country,
        'is_primary': isPrimary,
      });
      final addr =
          CustomerAddress.fromJson(resp.data as Map<String, dynamic>);
      final current = this.state.valueOrNull;
      if (current != null) {
        final newAddrs = isPrimary
            ? [
                ...current.addresses.map((a) =>
                    a.isPrimary ? a.copyWith(isPrimary: false) : a),
                addr,
              ]
            : [...current.addresses, addr];
        this.state = AsyncValue.data(current.copyWith(addresses: newAddrs));
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// M17 — patch a single address. Backend validates type, postcode and
  /// status transitions. On success the local state is reconciled.
  Future<bool> updateAddress(
    String addressId,
    Map<String, dynamic> patch,
  ) async {
    try {
      final resp = await _api.patch(
        '/customers/$_id/addresses/$addressId',
        data: patch,
      );
      final updated =
          CustomerAddress.fromJson(resp.data as Map<String, dynamic>);
      final current = state.valueOrNull;
      if (current != null) {
        final newAddrs = current.addresses.map((a) {
          if (a.id != updated.id) {
            // If we just promoted another row to primary, demote the old one.
            if (updated.isPrimary && a.isPrimary) {
              return a.copyWith(isPrimary: false);
            }
            return a;
          }
          return updated;
        }).toList();
        state = AsyncValue.data(current.copyWith(addresses: newAddrs));
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// M17 — archive (status='archived') or restore (status='active') an
  /// address. Soft delete is the canonical path; this calls the
  /// dedicated /status endpoint on the top-level resource.
  Future<bool> setAddressStatus(String addressId, String status) async {
    try {
      await _api.post(
        '/customer_addresses/$addressId/status',
        data: {'status': status},
      );
      final current = state.valueOrNull;
      if (current != null) {
        final newAddrs = current.addresses
            .map((a) => a.id == addressId ? a.copyWith(status: status) : a)
            .toList();
        state = AsyncValue.data(current.copyWith(addresses: newAddrs));
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> addContact({
    required String name,
    String? role,
    String? email,
    String? phone,
    bool isPrimary = false,
  }) async {
    try {
      final resp = await _api.post('/customers/$_id/contacts', data: {
        'name': name,
        'role': role ?? '',
        'email': email ?? '',
        'phone': phone ?? '',
        'is_primary': isPrimary,
      });
      final contact =
          CustomerContact.fromJson(resp.data as Map<String, dynamic>);
      final current = state.valueOrNull;
      if (current != null) {
        state = AsyncValue.data(
            current.copyWith(contacts: [...current.contacts, contact]));
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> addNote({required String content}) async {
    try {
      final resp = await _api
          .post('/customers/$_id/notes', data: {'content': content});
      final note = CustomerNote.fromJson(resp.data as Map<String, dynamic>);
      final current = state.valueOrNull;
      if (current != null) {
        state = AsyncValue.data(
            current.copyWith(notes: [note, ...current.notes]));
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> deleteAddress(String addressId) async {
    try {
      await _api.delete('/customers/$_id/addresses/$addressId');
      final current = state.valueOrNull;
      if (current != null) {
        state = AsyncValue.data(current.copyWith(
            addresses:
                current.addresses.where((a) => a.id != addressId).toList()));
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// M15 — move the customer through the lifecycle (lead/active/inactive/archived).
  /// Backend validates the transition; on conflict the call returns false.
  Future<bool> setStatus(String status) async {
    try {
      await _api.post('/customers/$_id/status', data: {'status': status});
      final current = state.valueOrNull;
      if (current != null) {
        state = AsyncValue.data(current.copyWith(
            customer: current.customer.copyWith(status: status)));
      }
      return true;
    } catch (_) {
      return false;
    }
  }
}
