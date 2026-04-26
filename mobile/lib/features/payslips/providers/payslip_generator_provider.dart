import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_client.dart';

class GeneratedPayslip {
  final String id;
  final String workerId;
  final String workerName;
  final String payRunId;
  final double grossPay;
  final double taxWithheld;
  final double netPay;
  final double superAmount;
  final double hoursWorked;
  final double hourlyRate;
  final String periodStart;
  final String periodEnd;
  final String status;
  final String? pdfGeneratedAt;
  final int pdfDownloadCount;

  const GeneratedPayslip({
    required this.id,
    required this.workerId,
    required this.workerName,
    required this.payRunId,
    required this.grossPay,
    required this.taxWithheld,
    required this.netPay,
    required this.superAmount,
    required this.hoursWorked,
    required this.hourlyRate,
    required this.periodStart,
    required this.periodEnd,
    required this.status,
    this.pdfGeneratedAt,
    this.pdfDownloadCount = 0,
  });

  factory GeneratedPayslip.fromJson(Map<String, dynamic> json) {
    return GeneratedPayslip(
      id: json['id'] as String,
      workerId: json['worker_id']?.toString() ?? '',
      workerName: json['worker_name']?.toString() ?? '',
      payRunId: json['pay_run_id']?.toString() ?? '',
      grossPay: (json['gross_pay'] as num?)?.toDouble() ?? 0,
      taxWithheld: (json['tax_withheld'] as num?)?.toDouble() ?? 0,
      netPay: (json['net_pay'] as num?)?.toDouble() ?? 0,
      superAmount: (json['super_amount'] as num?)?.toDouble() ?? 0,
      hoursWorked: (json['hours_worked'] as num?)?.toDouble() ?? 0,
      hourlyRate: (json['hourly_rate'] as num?)?.toDouble() ?? 0,
      periodStart: _dateOnly(json['period_start']),
      periodEnd: _dateOnly(json['period_end']),
      status: json['status']?.toString() ?? 'locked',
      pdfGeneratedAt: json['pdf_generated_at']?.toString(),
      pdfDownloadCount: (json['pdf_download_count'] as num?)?.toInt() ?? 0,
    );
  }

  static String _dateOnly(dynamic raw) {
    final value = raw?.toString() ?? '';
    if (value.length >= 10) return value.substring(0, 10);
    return value;
  }
}

class PayslipFilter {
  final String status;
  final String workerId;

  const PayslipFilter({this.status = '', this.workerId = ''});

  @override
  bool operator ==(Object other) {
    return other is PayslipFilter &&
        other.status == status &&
        other.workerId == workerId;
  }

  @override
  int get hashCode => Object.hash(status, workerId);
}

final payslipGeneratorProvider =
    FutureProvider.family<List<GeneratedPayslip>, PayslipFilter>(
        (ref, filter) async {
  final params = <String, dynamic>{};
  if (filter.status.isNotEmpty) params['status'] = filter.status;
  if (filter.workerId.isNotEmpty) params['worker_id'] = filter.workerId;
  final resp = await ref
      .read(apiClientProvider)
      .get('/payslip_generator_module', params: params);
  return (resp.data as List<dynamic>)
      .cast<Map<String, dynamic>>()
      .map(GeneratedPayslip.fromJson)
      .toList();
});

final myPayslipGeneratorProvider =
    FutureProvider<List<GeneratedPayslip>>((ref) async {
  final resp =
      await ref.read(apiClientProvider).get('/me/payslip_generator_module');
  return (resp.data as List<dynamic>)
      .cast<Map<String, dynamic>>()
      .map(GeneratedPayslip.fromJson)
      .toList();
});

final payslipGeneratorNotifierProvider =
    StateNotifierProvider<PayslipGeneratorNotifier, AsyncValue<void>>(
  (ref) => PayslipGeneratorNotifier(ref.read(apiClientProvider), ref),
);

class PayslipGeneratorNotifier extends StateNotifier<AsyncValue<void>> {
  final ApiClient _api;
  final Ref _ref;

  PayslipGeneratorNotifier(this._api, this._ref)
      : super(const AsyncValue.data(null));

  Future<String?> generate(String payslipId) async {
    try {
      await _api
          .post('/payslip_generator_module', data: {'payslip_id': payslipId});
      _invalidate();
      return null;
    } on DioException catch (e) {
      return e.response?.data?['error']?.toString() ?? 'generate_failed';
    }
  }

  Future<String?> updateStatus(String payslipId, String status) async {
    try {
      await _api.patch('/payslip_generator_module/$payslipId',
          data: {'status': status});
      _invalidate();
      return null;
    } on DioException catch (e) {
      return e.response?.data?['error']?.toString() ?? 'update_failed';
    }
  }

  Future<bool> delete(String payslipId) async {
    try {
      await _api.delete('/payslip_generator_module/$payslipId');
      _invalidate();
      return true;
    } catch (_) {
      return false;
    }
  }

  void _invalidate() {
    _ref.invalidate(payslipGeneratorProvider);
    _ref.invalidate(myPayslipGeneratorProvider);
  }
}
