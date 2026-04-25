import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/customers_provider.dart';
import 'customer_detail_screen.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Design tokens
// ─────────────────────────────────────────────────────────────────────────────
const _navy = Color(0xFF1A2332);
const _blue = Color(0xFF2563EB);
const _bgGrey = Color(0xFFF1F5F9);
const _cardWhite = Color(0xFFFFFFFF);
const _textMuted = Color(0xFF64748B);
const _green = Color(0xFF16A34A);
const _radius = Radius.circular(12);

// ─────────────────────────────────────────────────────────────────────────────
// Screen
// ─────────────────────────────────────────────────────────────────────────────

class CustomersListScreen extends ConsumerStatefulWidget {
  const CustomersListScreen({super.key});

  @override
  ConsumerState<CustomersListScreen> createState() =>
      _CustomersListScreenState();
}

class _CustomersListScreenState extends ConsumerState<CustomersListScreen> {
  final _searchCtrl = TextEditingController();
  String _searchQuery = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    setState(() => _searchQuery = value.toLowerCase());
  }

  List<Customer> _filtered(List<Customer> all) {
    if (_searchQuery.isEmpty) return all;
    return all.where((c) {
      final name = c.fullName.toLowerCase();
      final company = (c.companyName ?? '').toLowerCase();
      final email = (c.email ?? '').toLowerCase();
      final phone = (c.phone ?? '').toLowerCase();
      return name.contains(_searchQuery) ||
          company.contains(_searchQuery) ||
          email.contains(_searchQuery) ||
          phone.contains(_searchQuery);
    }).toList();
  }

  Future<void> _refresh() async {
    await ref
        .read(customerListProvider.notifier)
        .load(search: _searchQuery.isEmpty ? null : _searchQuery);
  }

  void _showCreateSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _CreateCustomerSheet(
        onCreated: (c) {
          Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => CustomerDetailScreen(id: c.id),
          ));
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(customerListProvider);

    return Scaffold(
      backgroundColor: _bgGrey,
      appBar: _buildAppBar(),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showCreateSheet,
        backgroundColor: _blue,
        icon: const Icon(Icons.person_add_rounded, color: Colors.white),
        label: const Text(
          'New Customer',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w600,
          ),
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      body: Column(
        children: [
          _buildSearchBar(),
          Expanded(child: _buildBody(state)),
        ],
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() => AppBar(
        backgroundColor: _navy,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: _blue.withOpacity(0.18),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.people_alt_rounded,
                  color: Colors.white, size: 20),
            ),
            const SizedBox(width: 10),
            const Text(
              'Customers',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 20,
                letterSpacing: -0.3,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: Colors.white70),
            onPressed: _refresh,
            tooltip: 'Refresh',
          ),
          const SizedBox(width: 4),
        ],
      );

  Widget _buildSearchBar() => Container(
        color: _navy,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Container(
          height: 44,
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.1),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white.withOpacity(0.15)),
          ),
          child: TextField(
            controller: _searchCtrl,
            onChanged: _onSearchChanged,
            style: const TextStyle(color: Colors.white, fontSize: 14),
            decoration: InputDecoration(
              hintText: 'Search customers…',
              hintStyle:
                  TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 14),
              prefixIcon: Icon(Icons.search_rounded,
                  color: Colors.white.withOpacity(0.6), size: 20),
              suffixIcon: _searchQuery.isNotEmpty
                  ? GestureDetector(
                      onTap: () {
                        _searchCtrl.clear();
                        _onSearchChanged('');
                      },
                      child: Icon(Icons.close_rounded,
                          color: Colors.white.withOpacity(0.6), size: 18),
                    )
                  : null,
              border: InputBorder.none,
              contentPadding:
                  const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
            ),
          ),
        ),
      );

  Widget _buildBody(AsyncValue<List<Customer>> state) {
    return state.when(
      loading: () => const Center(
        child: CircularProgressIndicator(color: _blue),
      ),
      error: (e, _) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_rounded, size: 48, color: _textMuted),
            const SizedBox(height: 12),
            Text(
              'Could not load customers',
              style: TextStyle(
                  color: _navy,
                  fontWeight: FontWeight.w600,
                  fontSize: 16),
            ),
            const SizedBox(height: 6),
            Text('$e',
                style:
                    const TextStyle(color: _textMuted, fontSize: 12),
                textAlign: TextAlign.center),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _refresh,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Retry'),
              style: ElevatedButton.styleFrom(backgroundColor: _blue),
            ),
          ],
        ),
      ),
      data: (customers) {
        final filtered = _filtered(customers);
        if (filtered.isEmpty) return _buildEmptyState(customers.isEmpty);
        return RefreshIndicator(
          color: _blue,
          onRefresh: _refresh,
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
            itemCount: filtered.length,
            itemBuilder: (_, i) => _CustomerCard(
              customer: filtered[i],
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => CustomerDetailScreen(id: filtered[i].id),
              )),
            ),
          ),
        );
      },
    );
  }

  Widget _buildEmptyState(bool noCustomers) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                color: _blue.withOpacity(0.08),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.people_alt_outlined,
                  size: 40, color: _blue),
            ),
            const SizedBox(height: 20),
            Text(
              noCustomers ? 'No customers yet' : 'No results found',
              style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: _navy),
            ),
            const SizedBox(height: 8),
            Text(
              noCustomers
                  ? 'Add your first customer to get started'
                  : 'Try a different search term',
              style: const TextStyle(fontSize: 14, color: _textMuted),
            ),
            if (noCustomers) ...[
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: _showCreateSheet,
                icon: const Icon(Icons.person_add_rounded),
                label: const Text('Add your first customer'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _blue,
                  foregroundColor: Colors.white,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ],
          ],
        ),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Customer card
// ─────────────────────────────────────────────────────────────────────────────

class _CustomerCard extends StatelessWidget {
  final Customer customer;
  final VoidCallback onTap;

  const _CustomerCard({required this.customer, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final initials = _initials(customer);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: _cardWhite,
        borderRadius: BorderRadius.all(_radius),
        elevation: 0,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.all(_radius),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.all(_radius),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                // Avatar
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: _navy.withOpacity(0.08),
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    initials,
                    style: const TextStyle(
                      color: _navy,
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                // Info
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              customer.fullName,
                              style: const TextStyle(
                                color: _navy,
                                fontWeight: FontWeight.w700,
                                fontSize: 15,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          _StatusBadge(isActive: customer.isActive),
                        ],
                      ),
                      if (customer.companyName != null &&
                          customer.companyName!.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            const Icon(Icons.business_rounded,
                                size: 12, color: _textMuted),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                customer.companyName!,
                                style: const TextStyle(
                                    color: _textMuted, fontSize: 12),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          if (customer.phone != null &&
                              customer.phone!.isNotEmpty)
                            _InfoChip(
                              icon: Icons.phone_rounded,
                              label: customer.phone!,
                            ),
                          if (customer.email != null &&
                              customer.email!.isNotEmpty) ...[
                            if (customer.phone != null &&
                                customer.phone!.isNotEmpty)
                              const SizedBox(width: 8),
                            Expanded(
                              child: _InfoChip(
                                icon: Icons.email_rounded,
                                label: customer.email!,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(Icons.chevron_right_rounded,
                    color: _textMuted, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _initials(Customer c) {
    final first = c.firstName.isNotEmpty ? c.firstName[0].toUpperCase() : '';
    final last =
        (c.lastName != null && c.lastName!.isNotEmpty)
            ? c.lastName![0].toUpperCase()
            : '';
    return '$first$last'.isNotEmpty ? '$first$last' : '?';
  }
}

class _StatusBadge extends StatelessWidget {
  final bool isActive;
  const _StatusBadge({required this.isActive});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: isActive
              ? _green.withOpacity(0.1)
              : _textMuted.withOpacity(0.1),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          isActive ? 'Active' : 'Inactive',
          style: TextStyle(
            color: isActive ? _green : _textMuted,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
}

class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String label;
  const _InfoChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: _textMuted),
          const SizedBox(width: 3),
          Flexible(
            child: Text(
              label,
              style: const TextStyle(color: _textMuted, fontSize: 12),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Create Customer bottom sheet
// ─────────────────────────────────────────────────────────────────────────────

class _CreateCustomerSheet extends ConsumerStatefulWidget {
  final void Function(Customer) onCreated;
  const _CreateCustomerSheet({required this.onCreated});

  @override
  ConsumerState<_CreateCustomerSheet> createState() =>
      _CreateCustomerSheetState();
}

class _CreateCustomerSheetState extends ConsumerState<_CreateCustomerSheet> {
  final _formKey = GlobalKey<FormState>();
  final _firstCtrl = TextEditingController();
  final _lastCtrl = TextEditingController();
  final _companyCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _mobileCtrl = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _firstCtrl.dispose();
    _lastCtrl.dispose();
    _companyCtrl.dispose();
    _emailCtrl.dispose();
    _phoneCtrl.dispose();
    _mobileCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final customer = await ref.read(customerListProvider.notifier).create(
          firstName: _firstCtrl.text.trim(),
          lastName: _lastCtrl.text.trim(),
          companyName: _companyCtrl.text.trim(),
          email: _emailCtrl.text.trim(),
          phone: _phoneCtrl.text.trim(),
          mobile: _mobileCtrl.text.trim(),
        );
    if (!mounted) return;
    setState(() => _saving = false);
    if (customer != null) {
      Navigator.of(context).pop();
      widget.onCreated(customer);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to create customer. Please try again.'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Container(
      decoration: const BoxDecoration(
        color: _cardWhite,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + bottom),
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Handle
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0xFFE2E8F0),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: _blue.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.person_add_rounded,
                        color: _blue, size: 20),
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    'New Customer',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: _navy,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                      child: _Field(
                          ctrl: _firstCtrl,
                          label: 'First Name *',
                          validator: (v) =>
                              v == null || v.trim().isEmpty
                                  ? 'Required'
                                  : null)),
                  const SizedBox(width: 12),
                  Expanded(
                      child: _Field(
                          ctrl: _lastCtrl, label: 'Last Name')),
                ],
              ),
              const SizedBox(height: 12),
              _Field(ctrl: _companyCtrl, label: 'Company Name'),
              const SizedBox(height: 12),
              _Field(
                  ctrl: _emailCtrl,
                  label: 'Email',
                  keyboardType: TextInputType.emailAddress),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                      child: _Field(
                          ctrl: _phoneCtrl,
                          label: 'Phone',
                          keyboardType: TextInputType.phone)),
                  const SizedBox(width: 12),
                  Expanded(
                      child: _Field(
                          ctrl: _mobileCtrl,
                          label: 'Mobile',
                          keyboardType: TextInputType.phone)),
                ],
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  onPressed: _saving ? null : _submit,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _blue,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    elevation: 0,
                  ),
                  child: _saving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2))
                      : const Text(
                          'Create Customer',
                          style: TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 15),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  final TextEditingController ctrl;
  final String label;
  final TextInputType? keyboardType;
  final String? Function(String?)? validator;

  const _Field({
    required this.ctrl,
    required this.label,
    this.keyboardType,
    this.validator,
  });

  @override
  Widget build(BuildContext context) => TextFormField(
        controller: ctrl,
        keyboardType: keyboardType,
        validator: validator,
        style: const TextStyle(fontSize: 14, color: _navy),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(color: _textMuted, fontSize: 13),
          filled: true,
          fillColor: _bgGrey,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: _blue, width: 1.5),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Colors.red, width: 1.5),
          ),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        ),
      );
}
