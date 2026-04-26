// M105 — bulk CSV import.
//
// Backend contract (handler enforces 10 MB cap, 5000 rows max,
// strict header allow-list per entity):
//   POST /api/v1/bulk-imports  multipart: file + entity_type
//   GET  /api/v1/bulk-imports
//   GET  /api/v1/bulk-imports/{id}

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_client.dart';

const supportedBulkImportEntities = <String>['customers', 'jobs', 'expenses'];

/// Columns the backend accepts per entity. Surfaced in the UI as a
/// hint so users build a matching CSV. Mirrors allowedHeaders in
/// backend/internal/handlers/bulk_import/bulk_import.go.
const bulkImportColumns = <String, List<String>>{
  'customers': [
    'first_name', 'last_name', 'company_name',
    'email', 'phone', 'mobile', 'notes',
  ],
  'jobs': [
    'job_number', 'title', 'description',
    'status', 'priority', 'customer_email',
  ],
  'expenses': [
    'category', 'description', 'amount', 'supplier', 'date',
  ],
};

class BulkImportJob {
  final String id;
  final String entityType;
  final String fileName;
  final String status; // pending | processing | completed | failed
  final int totalRows;
  final int processedRows;
  final int successRows;
  final DateTime createdAt;
  final DateTime? completedAt;

  const BulkImportJob({
    required this.id,
    required this.entityType,
    required this.fileName,
    required this.status,
    required this.totalRows,
    required this.processedRows,
    required this.successRows,
    required this.createdAt,
    required this.completedAt,
  });

  factory BulkImportJob.fromJson(Map<String, dynamic> j) => BulkImportJob(
        id: j['id'].toString(),
        entityType: j['entity_type']?.toString() ?? '',
        fileName: j['file_name']?.toString() ?? '',
        status: j['status']?.toString() ?? 'pending',
        totalRows: (j['total_rows'] as num?)?.toInt() ?? 0,
        processedRows: (j['processed_rows'] as num?)?.toInt() ?? 0,
        successRows: (j['success_rows'] as num?)?.toInt() ?? 0,
        createdAt: DateTime.tryParse(j['created_at']?.toString() ?? '') ??
            DateTime.now(),
        completedAt: j['completed_at'] == null
            ? null
            : DateTime.tryParse(j['completed_at'].toString()),
      );
}

class BulkImportRowError {
  final int row;
  final String message;
  const BulkImportRowError({required this.row, required this.message});

  factory BulkImportRowError.fromJson(Map<String, dynamic> j) =>
      BulkImportRowError(
        row: (j['row'] as num?)?.toInt() ?? 0,
        message: j['message']?.toString() ?? '',
      );
}

class BulkImportDetail {
  final BulkImportJob job;
  final List<BulkImportRowError> errors;
  const BulkImportDetail({required this.job, required this.errors});
}

final bulkImportListProvider =
    FutureProvider<List<BulkImportJob>>((ref) async {
  final api = ref.read(apiClientProvider);
  final resp = await api.get('/api/v1/bulk-imports');
  final data = resp.data as Map<String, dynamic>;
  final list = (data['jobs'] as List?) ?? const [];
  return list
      .map((e) => BulkImportJob.fromJson(e as Map<String, dynamic>))
      .toList();
});

final bulkImportDetailProvider =
    FutureProvider.family<BulkImportDetail, String>((ref, id) async {
  final api = ref.read(apiClientProvider);
  final resp = await api.get('/api/v1/bulk-imports/$id');
  final data = resp.data as Map<String, dynamic>;
  final job = BulkImportJob.fromJson(data);
  final rawErrs = (data['errors'] as List?) ?? const [];
  final errors = rawErrs
      .map((e) => BulkImportRowError.fromJson(e as Map<String, dynamic>))
      .toList();
  return BulkImportDetail(job: job, errors: errors);
});

final bulkImportNotifierProvider =
    StateNotifierProvider<BulkImportNotifier, AsyncValue<void>>(
  (ref) => BulkImportNotifier(ref.read(apiClientProvider), ref),
);

class BulkImportNotifier extends StateNotifier<AsyncValue<void>> {
  final ApiClient _api;
  final Ref _ref;
  BulkImportNotifier(this._api, this._ref)
      : super(const AsyncValue.data(null));

  /// Returns the new job's id, or null on failure.
  Future<String?> upload({
    required String entityType,
    required String filePath,
    required String filename,
  }) async {
    state = const AsyncValue.loading();
    try {
      final form = FormData.fromMap({
        'entity_type': entityType,
        'file': await MultipartFile.fromFile(filePath, filename: filename),
      });
      final resp = await _api.post('/api/v1/bulk-imports', data: form);
      final data = resp.data as Map<String, dynamic>;
      _ref.invalidate(bulkImportListProvider);
      state = const AsyncValue.data(null);
      return data['id']?.toString();
    } catch (e, st) {
      state = AsyncValue.error(e, st);
      return null;
    }
  }
}
