import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_client.dart';

class PayRun {
  final String id;
  final String periodStart;
  final String periodEnd;
  final String payDate;
  final String status;
  final double totalGross;
  final double totalTax;
  final double totalNet;
  final List<dynamic> payslips;

  const PayRun({
    required this.id,
    required this.periodStart,
    required this.periodEnd,
    required this.payDate,
    required this.status,
    required this.totalGross,
    required this.totalTax,
    required this.totalNet,
    this.payslips = const [],
  });

  factory PayRun.fromJson(Map<String, dynamic> json) {
    return PayRun(
      id: json['id'] as String,
      periodStart: _dateOnly(json['period_start']),
      periodEnd: _dateOnly(json['period_end']),
      payDate: _dateOnly(json['pay_date']),
      status: json['status']?.toString() ?? 'draft',
      totalGross: (json['total_gross'] as num?)?.toDouble() ?? 0,
      totalTax: (json['total_tax'] as num?)?.toDouble() ?? 0,
      totalNet: (json['total_net'] as num?)?.toDouble() ?? 0,
      payslips: json['payslips'] as List<dynamic>? ?? const [],
    );
  }

  static String _dateOnly(dynamic raw) {
    final value = raw?.toString() ?? '';
    if (value.length >= 10) return value.substring(0, 10);
    return value;
  }
}

class Payslip {
  final String id;
  final String payRunId;
  final double grossPay;
  final double taxWithheld;
  final double netPay;
  final double superAmount;
  final String periodStart;
  final String periodEnd;
  final String status;

  const Payslip({
    required this.id,
    required this.payRunId,
    required this.grossPay,
    required this.taxWithheld,
    required this.netPay,
    required this.superAmount,
    required this.periodStart,
    required this.periodEnd,
    required this.status,
  });

  factory Payslip.fromJson(Map<String, dynamic> json) {
    return Payslip(
      id: json['id'] as String,
      payRunId: json['pay_run_id']?.toString() ?? '',
      grossPay: (json['gross_pay'] as num?)?.toDouble() ?? 0,
      taxWithheld: (json['tax_withheld'] as num?)?.toDouble() ?? 0,
      netPay: (json['net_pay'] as num?)?.toDouble() ?? 0,
      superAmount: (json['super_amount'] as num?)?.toDouble() ?? 0,
      periodStart: PayRun._dateOnly(json['period_start']),
      periodEnd: PayRun._dateOnly(json['period_end']),
      status: json['status']?.toString() ?? 'locked',
    );
  }
}

final payRunsProvider = FutureProvider<List<PayRun>>((ref) async {
  final resp = await ref.read(apiClientProvider).get('/payroll_module');
  return (resp.data as List<dynamic>)
      .cast<Map<String, dynamic>>()
      .map(PayRun.fromJson)
      .toList();
});

final payRunProvider = FutureProvider.family<PayRun, String>((ref, id) async {
  final resp = await ref.read(apiClientProvider).get('/payroll_module/$id');
  return PayRun.fromJson(resp.data as Map<String, dynamic>);
});

final myPayrollModuleProvider =
    FutureProvider<Map<String, dynamic>>((ref) async {
  final resp = await ref.read(apiClientProvider).get('/me/payroll_module');
  return resp.data as Map<String, dynamic>;
});

final payrollNotifierProvider =
    StateNotifierProvider<PayrollNotifier, AsyncValue<void>>(
  (ref) => PayrollNotifier(ref.read(apiClientProvider), ref),
);

class PayrollNotifier extends StateNotifier<AsyncValue<void>> {
  final ApiClient _api;
  final Ref _ref;

  PayrollNotifier(this._api, this._ref) : super(const AsyncValue.data(null));

  Future<String?> create(Map<String, dynamic> data) async {
    try {
      await _api.post('/payroll_module', data: data);
      _invalidate();
      return null;
    } on DioException catch (e) {
      return e.response?.data?['error']?.toString() ?? 'create_failed';
    }
  }

  Future<String?> update(String id, Map<String, dynamic> data) async {
    try {
      await _api.patch('/payroll_module/$id', data: data);
      _invalidate();
      return null;
    } on DioException catch (e) {
      return e.response?.data?['error']?.toString() ?? 'update_failed';
    }
  }

  Future<Map<String, dynamic>?> process(String id) async {
    try {
      final resp = await _api.post('/payroll_module/$id/process');
      _invalidate();
      return resp.data as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<bool> markPaid(String id) => _post('/payroll_module/$id/pay');

  Future<bool> cancel(String id) => _post('/payroll_module/$id/cancel');

  Future<bool> delete(String id) async {
    try {
      await _api.delete('/payroll_module/$id');
      _invalidate();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _post(String path) async {
    try {
      await _api.post(path);
      _invalidate();
      return true;
    } catch (_) {
      return false;
    }
  }

  void _invalidate() {
    _ref.invalidate(payRunsProvider);
    _ref.invalidate(payRunProvider);
    _ref.invalidate(myPayrollModuleProvider);
  }
}
