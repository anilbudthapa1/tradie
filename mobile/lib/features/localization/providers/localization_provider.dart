import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_client.dart';

class LocalizationEntry {
  final String id;
  final String namespace;
  final String translationKey;
  final String language;
  final String value;
  final String templateType;
  final String status;
  final DateTime? updatedAt;

  const LocalizationEntry({
    required this.id,
    required this.namespace,
    required this.translationKey,
    required this.language,
    required this.value,
    required this.templateType,
    required this.status,
    this.updatedAt,
  });

  factory LocalizationEntry.fromJson(Map<String, dynamic> json) {
    return LocalizationEntry(
      id: json['id'] as String,
      namespace: (json['namespace'] as String?) ?? 'common',
      translationKey: (json['translation_key'] as String?) ?? '',
      language: (json['language'] as String?) ?? 'en-AU',
      value: (json['value'] as String?) ?? '',
      templateType: (json['template_type'] as String?) ?? 'ui',
      status: (json['status'] as String?) ?? 'draft',
      updatedAt: DateTime.tryParse(json['updated_at']?.toString() ?? ''),
    );
  }
}

class LocalizationFilter {
  final String status;
  final String language;
  final String templateType;
  final String query;

  const LocalizationFilter({
    this.status = 'all',
    this.language = '',
    this.templateType = '',
    this.query = '',
  });

  @override
  bool operator ==(Object other) {
    return other is LocalizationFilter &&
        other.status == status &&
        other.language == language &&
        other.templateType == templateType &&
        other.query == query;
  }

  @override
  int get hashCode => Object.hash(status, language, templateType, query);
}

final localizationEntriesProvider =
    FutureProvider.family<List<dynamic>, LocalizationFilter>(
        (ref, filter) async {
  final params = <String, dynamic>{};
  if (filter.status.isNotEmpty) params['status'] = filter.status;
  if (filter.language.isNotEmpty) params['language'] = filter.language;
  if (filter.templateType.isNotEmpty) {
    params['template_type'] = filter.templateType;
  }
  if (filter.query.trim().isNotEmpty) params['q'] = filter.query.trim();

  final resp = await ref
      .read(apiClientProvider)
      .get('/multi_language_module', params: params);
  return (resp.data as List<dynamic>)
      .cast<Map<String, dynamic>>()
      .map(LocalizationEntry.fromJson)
      .toList();
});

final myLocalizationEntriesProvider =
    FutureProvider.family<List<dynamic>, String?>((ref, language) async {
  final params = <String, dynamic>{};
  if (language != null && language.isNotEmpty) params['language'] = language;
  final resp = await ref
      .read(apiClientProvider)
      .get('/me/multi_language_module', params: params);
  return resp.data as List<dynamic>;
});

final localizationNotifierProvider =
    StateNotifierProvider<LocalizationNotifier, AsyncValue<void>>(
  (ref) => LocalizationNotifier(ref.read(apiClientProvider), ref),
);

class LocalizationNotifier extends StateNotifier<AsyncValue<void>> {
  final ApiClient _api;
  final Ref _ref;

  LocalizationNotifier(this._api, this._ref)
      : super(const AsyncValue.data(null));

  Future<String?> create(Map<String, dynamic> data) async {
    try {
      await _api.post('/multi_language_module', data: data);
      _invalidate();
      return null;
    } on DioException catch (e) {
      return e.response?.data?['error']?.toString() ?? 'create_failed';
    }
  }

  Future<String?> update(String id, Map<String, dynamic> data) async {
    try {
      await _api.patch('/multi_language_module/$id', data: data);
      _invalidate();
      return null;
    } on DioException catch (e) {
      return e.response?.data?['error']?.toString() ?? 'update_failed';
    }
  }

  Future<bool> delete(String id) async {
    try {
      await _api.delete('/multi_language_module/$id');
      _invalidate();
      return true;
    } catch (_) {
      return false;
    }
  }

  void _invalidate() {
    _ref.invalidate(localizationEntriesProvider);
    _ref.invalidate(myLocalizationEntriesProvider);
  }
}
