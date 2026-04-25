import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';

import '../../../core/api/api_client.dart';
import '../../../core/utils/theme.dart';
import '../providers/jobs_provider.dart';

class JobCreateScreen extends ConsumerStatefulWidget {
  const JobCreateScreen({super.key});

  @override
  ConsumerState<JobCreateScreen> createState() => _JobCreateScreenState();
}

class _JobCreateScreenState extends ConsumerState<JobCreateScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _latCtrl = TextEditingController();
  final _lngCtrl = TextEditingController();
  final _address1Ctrl = TextEditingController();
  final _cityCtrl = TextEditingController();

  String _priority = 'normal';
  DateTime? _scheduledStart;
  DateTime? _scheduledEnd;
  Map<String, dynamic>? _selectedCustomer;
  List<Map<String, dynamic>> _customerResults = [];
  List<Map<String, dynamic>> _availableWorkers = [];
  final Set<String> _selectedWorkerIds = {};
  bool _submitting = false;
  bool _searchingCustomers = false;

  @override
  void initState() {
    super.initState();
    _loadWorkers();
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _descCtrl.dispose();
    _latCtrl.dispose();
    _lngCtrl.dispose();
    _address1Ctrl.dispose();
    _cityCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadWorkers() async {
    try {
      final api = ref.read(apiClientProvider);
      final resp = await api.get('/workers');
      setState(() {
        _availableWorkers = List<Map<String, dynamic>>.from(resp.data as List);
      });
    } catch (_) {}
  }

  Future<void> _searchCustomers(String query) async {
    if (query.length < 2) {
      setState(() => _customerResults = []);
      return;
    }
    setState(() => _searchingCustomers = true);
    try {
      final api = ref.read(apiClientProvider);
      final resp = await api.get('/customers', params: {'search': query, 'limit': '10'});
      setState(() {
        _customerResults = List<Map<String, dynamic>>.from(resp.data as List);
        _searchingCustomers = false;
      });
    } catch (_) {
      setState(() => _searchingCustomers = false);
    }
  }

  Future<void> _pickDateTime({required bool isStart}) async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: now.subtract(const Duration(days: 1)),
      lastDate: now.add(const Duration(days: 365)),
    );
    if (date == null || !mounted) return;

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
    );
    if (time == null || !mounted) return;

    final dt = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    setState(() {
      if (isStart) {
        _scheduledStart = dt;
        if (_scheduledEnd == null || _scheduledEnd!.isBefore(dt)) {
          _scheduledEnd = dt.add(const Duration(hours: 2));
        }
      } else {
        _scheduledEnd = dt;
      }
    });
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _submitting = true);

    final data = <String, dynamic>{
      'title': _titleCtrl.text.trim(),
      'description': _descCtrl.text.trim(),
      'priority': _priority,
      if (_selectedCustomer != null) 'customer_id': _selectedCustomer!['id'],
      if (_scheduledStart != null) 'scheduled_start': _scheduledStart!.toUtc().toIso8601String(),
      if (_scheduledEnd != null) 'scheduled_end': _scheduledEnd!.toUtc().toIso8601String(),
      if (_latCtrl.text.isNotEmpty) 'lat': double.tryParse(_latCtrl.text),
      if (_lngCtrl.text.isNotEmpty) 'lng': double.tryParse(_lngCtrl.text),
    };

    final job = await ref.read(jobsNotifierProvider.notifier).createJob(data);

    setState(() => _submitting = false);

    if (job != null && mounted) {
      // Assign workers if selected
      if (_selectedWorkerIds.isNotEmpty) {
        try {
          final api = ref.read(apiClientProvider);
          await api.post('/jobs/${job['id']}/assign',
              data: {'worker_ids': _selectedWorkerIds.toList()});
        } catch (_) {}
      }
      context.go('/jobs/${job['id']}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TradieColors.grey50,
      appBar: AppBar(
        title: const Text('Create Job'),
        leading: IconButton(
          icon: const Icon(Iconsax.arrow_left),
          onPressed: () => context.pop(),
        ),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Job details card
            _FormCard(
              title: 'Job Details',
              icon: Iconsax.briefcase,
              children: [
                _buildLabel('Job Title *'),
                TextFormField(
                  controller: _titleCtrl,
                  decoration: const InputDecoration(hintText: 'e.g. Roof repair at Smith property'),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Title is required' : null,
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 14),
                _buildLabel('Description'),
                TextFormField(
                  controller: _descCtrl,
                  decoration: const InputDecoration(hintText: 'Describe the job...'),
                  maxLines: 3,
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 14),
                _buildLabel('Priority'),
                _PrioritySelector(
                  value: _priority,
                  onChanged: (v) => setState(() => _priority = v),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Customer picker
            _FormCard(
              title: 'Customer',
              icon: Iconsax.user,
              children: [
                if (_selectedCustomer != null)
                  _SelectedCustomerTile(
                    customer: _selectedCustomer!,
                    onRemove: () => setState(() => _selectedCustomer = null),
                  )
                else ...[
                  _buildLabel('Search Customer'),
                  _CustomerSearchField(
                    results: _customerResults,
                    searching: _searchingCustomers,
                    onSearch: _searchCustomers,
                    onSelect: (c) => setState(() {
                      _selectedCustomer = c;
                      _customerResults = [];
                    }),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),

            // Schedule card
            _FormCard(
              title: 'Schedule',
              icon: Iconsax.calendar,
              children: [
                _buildLabel('Scheduled Start'),
                _DateTimeTile(
                  value: _scheduledStart,
                  hint: 'Tap to set start time',
                  onTap: () => _pickDateTime(isStart: true),
                ),
                const SizedBox(height: 14),
                _buildLabel('Scheduled End'),
                _DateTimeTile(
                  value: _scheduledEnd,
                  hint: 'Tap to set end time',
                  onTap: () => _pickDateTime(isStart: false),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Address card
            _FormCard(
              title: 'Location',
              icon: Iconsax.location,
              children: [
                _buildLabel('Address'),
                TextFormField(
                  controller: _address1Ctrl,
                  decoration: const InputDecoration(hintText: '123 Main Street'),
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _cityCtrl,
                  decoration: const InputDecoration(hintText: 'City / Suburb'),
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: TextFormField(
                      controller: _latCtrl,
                      decoration: const InputDecoration(hintText: 'Latitude'),
                      keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
                      textInputAction: TextInputAction.next,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextFormField(
                      controller: _lngCtrl,
                      decoration: const InputDecoration(hintText: 'Longitude'),
                      keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
                    ),
                  ),
                ]),
              ],
            ),
            const SizedBox(height: 12),

            // Worker assignment
            if (_availableWorkers.isNotEmpty)
              _FormCard(
                title: 'Assign Workers',
                icon: Iconsax.people,
                children: [
                  for (final w in _availableWorkers)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      value: _selectedWorkerIds.contains(w['id']),
                      onChanged: (checked) {
                        setState(() {
                          if (checked == true) {
                            _selectedWorkerIds.add(w['id'] as String);
                          } else {
                            _selectedWorkerIds.remove(w['id']);
                          }
                        });
                      },
                      title: Text(
                        '${w['first_name']} ${w['last_name']}'.trim(),
                        style: const TextStyle(fontSize: 14, color: TradieColors.charcoal),
                      ),
                      subtitle: w['role'] != null
                          ? Text(w['role'] as String, style: const TextStyle(fontSize: 12, color: TradieColors.grey400))
                          : null,
                      activeColor: TradieColors.electricBlue,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                ],
              ),
            const SizedBox(height: 24),

            ElevatedButton.icon(
              onPressed: _submitting ? null : _submit,
              icon: _submitting
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Iconsax.add_circle, size: 20),
              label: const Text('Create Job'),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(double.infinity, 54),
              ),
            ),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Widget _buildLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(text, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: TradieColors.grey600)),
    );
  }
}

// ── Sub-widgets ────────────────────────────────────────────────

class _FormCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<Widget> children;

  const _FormCard({required this.title, required this.icon, required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: TradieColors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: TradieColors.grey200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(icon, size: 16, color: TradieColors.electricBlue),
            const SizedBox(width: 8),
            Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: TradieColors.navy)),
          ]),
          const SizedBox(height: 14),
          const Divider(height: 1),
          const SizedBox(height: 14),
          ...children,
        ],
      ),
    );
  }
}

class _PrioritySelector extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;

  const _PrioritySelector({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final options = ['urgent', 'high', 'normal', 'low'];
    final colors = {
      'urgent': TradieColors.alertRed,
      'high': TradieColors.safetyOrange,
      'normal': TradieColors.electricBlue,
      'low': TradieColors.grey400,
    };

    return Wrap(
      spacing: 8,
      children: options.map((o) {
        final selected = value == o;
        final color = colors[o]!;
        return GestureDetector(
          onTap: () => onChanged(o),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: selected ? color.withOpacity(0.12) : TradieColors.grey100,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: selected ? color : TradieColors.grey200,
                width: selected ? 1.5 : 1,
              ),
            ),
            child: Text(
              o[0].toUpperCase() + o.substring(1),
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected ? color : TradieColors.grey600,
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

class _CustomerSearchField extends StatefulWidget {
  final List<Map<String, dynamic>> results;
  final bool searching;
  final ValueChanged<String> onSearch;
  final ValueChanged<Map<String, dynamic>> onSelect;

  const _CustomerSearchField({
    required this.results,
    required this.searching,
    required this.onSearch,
    required this.onSelect,
  });

  @override
  State<_CustomerSearchField> createState() => _CustomerSearchFieldState();
}

class _CustomerSearchFieldState extends State<_CustomerSearchField> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _ctrl,
          decoration: InputDecoration(
            hintText: 'Search by name...',
            prefixIcon: const Icon(Iconsax.search_normal, size: 18, color: TradieColors.grey400),
            suffixIcon: widget.searching
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                : null,
          ),
          onChanged: widget.onSearch,
        ),
        if (widget.results.isNotEmpty) ...[
          const SizedBox(height: 4),
          Container(
            decoration: BoxDecoration(
              color: TradieColors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: TradieColors.grey200),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 8, offset: const Offset(0, 4))],
            ),
            child: Column(
              children: widget.results.map((c) {
                final name = '${c['first_name']} ${c['last_name'] ?? ''}'.trim();
                return ListTile(
                  dense: true,
                  leading: CircleAvatar(
                    radius: 16,
                    backgroundColor: TradieColors.electricBlue.withOpacity(0.1),
                    child: Text(
                      name.isNotEmpty ? name[0].toUpperCase() : '?',
                      style: const TextStyle(fontSize: 13, color: TradieColors.electricBlue, fontWeight: FontWeight.w600),
                    ),
                  ),
                  title: Text(name, style: const TextStyle(fontSize: 13, color: TradieColors.charcoal)),
                  subtitle: c['email'] != null ? Text(c['email'] as String, style: const TextStyle(fontSize: 11)) : null,
                  onTap: () => widget.onSelect(c),
                );
              }).toList(),
            ),
          ),
        ],
      ],
    );
  }
}

class _SelectedCustomerTile extends StatelessWidget {
  final Map<String, dynamic> customer;
  final VoidCallback onRemove;

  const _SelectedCustomerTile({required this.customer, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    final name = '${customer['first_name']} ${customer['last_name'] ?? ''}'.trim();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: TradieColors.electricBlue.withOpacity(0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: TradieColors.electricBlue.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: TradieColors.electricBlue.withOpacity(0.15),
            child: Text(
              name.isNotEmpty ? name[0].toUpperCase() : '?',
              style: const TextStyle(color: TradieColors.electricBlue, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: const TextStyle(fontWeight: FontWeight.w600, color: TradieColors.navy, fontSize: 14)),
                if (customer['email'] != null)
                  Text(customer['email'] as String, style: const TextStyle(fontSize: 12, color: TradieColors.grey600)),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Iconsax.close_circle, size: 20, color: TradieColors.grey400),
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

class _DateTimeTile extends StatelessWidget {
  final DateTime? value;
  final String hint;
  final VoidCallback onTap;

  const _DateTimeTile({this.value, required this.hint, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: TradieColors.grey50,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: value != null ? TradieColors.electricBlue.withOpacity(0.4) : TradieColors.grey200),
        ),
        child: Row(
          children: [
            Icon(
              Iconsax.calendar,
              size: 18,
              color: value != null ? TradieColors.electricBlue : TradieColors.grey400,
            ),
            const SizedBox(width: 10),
            Text(
              value != null ? _format(value!) : hint,
              style: TextStyle(
                fontSize: 14,
                color: value != null ? TradieColors.charcoal : TradieColors.grey400,
                fontWeight: value != null ? FontWeight.w500 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _format(DateTime dt) {
    final local = dt.toLocal();
    return '${local.day}/${local.month}/${local.year}  ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }
}
