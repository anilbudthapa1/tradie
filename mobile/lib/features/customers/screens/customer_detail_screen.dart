import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/customers_provider.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Design tokens
// ─────────────────────────────────────────────────────────────────────────────
const _navy = Color(0xFF1A2332);
const _blue = Color(0xFF2563EB);
const _bgGrey = Color(0xFFF1F5F9);
const _cardWhite = Color(0xFFFFFFFF);
const _textMuted = Color(0xFF64748B);
const _green = Color(0xFF16A34A);
const _orange = Color(0xFFEA580C);
const _red = Color(0xFFDC2626);
const _borderColor = Color(0xFFE2E8F0);

// ─────────────────────────────────────────────────────────────────────────────
// Screen
// ─────────────────────────────────────────────────────────────────────────────

class CustomerDetailScreen extends ConsumerStatefulWidget {
  final String id;
  const CustomerDetailScreen({super.key, required this.id});

  @override
  ConsumerState<CustomerDetailScreen> createState() =>
      _CustomerDetailScreenState();
}

class _CustomerDetailScreenState extends ConsumerState<CustomerDetailScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabs;

  static const _tabLabels = [
    ('Overview', Icons.person_outline_rounded),
    ('Addresses', Icons.location_on_outlined),
    ('Contacts', Icons.contacts_outlined),
    ('Notes', Icons.notes_rounded),
    ('History', Icons.history_rounded),
  ];

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: _tabLabels.length, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _refresh() =>
      ref.read(customerDetailProvider(widget.id).notifier).loadAll();

  void _showEditSheet(Customer customer) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _EditCustomerSheet(customerId: widget.id, customer: customer),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(customerDetailProvider(widget.id));

    return Scaffold(
      backgroundColor: _bgGrey,
      body: state.when(
        loading: () => _loadingScaffold(),
        error: (e, _) => _errorScaffold('$e'),
        data: (detail) => _buildDetail(detail),
      ),
    );
  }

  Widget _loadingScaffold() => Scaffold(
        backgroundColor: _bgGrey,
        appBar: AppBar(backgroundColor: _navy, foregroundColor: Colors.white),
        body: const Center(child: CircularProgressIndicator(color: _blue)),
      );

  Widget _errorScaffold(String msg) => Scaffold(
        backgroundColor: _bgGrey,
        appBar: AppBar(backgroundColor: _navy, foregroundColor: Colors.white),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_rounded, size: 48, color: _textMuted),
              const SizedBox(height: 12),
              const Text('Failed to load customer',
                  style: TextStyle(
                      color: _navy, fontWeight: FontWeight.w700, fontSize: 16)),
              const SizedBox(height: 6),
              Text(msg,
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
      );

  Widget _buildDetail(CustomerDetail detail) {
    final c = detail.customer;
    return NestedScrollView(
      headerSliverBuilder: (_, __) => [
        SliverAppBar(
          backgroundColor: _navy,
          foregroundColor: Colors.white,
          expandedHeight: 160,
          pinned: true,
          actions: [
            IconButton(
              icon: const Icon(Icons.edit_rounded, color: Colors.white),
              onPressed: () => _showEditSheet(c),
              tooltip: 'Edit customer',
            ),
            IconButton(
              icon: const Icon(Icons.refresh_rounded, color: Colors.white70),
              onPressed: _refresh,
              tooltip: 'Refresh',
            ),
            const SizedBox(width: 4),
          ],
          flexibleSpace: FlexibleSpaceBar(
            background: Container(
              decoration: const BoxDecoration(color: _navy),
              padding: const EdgeInsets.fromLTRB(20, 80, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Row(
                    children: [
                      _Avatar(name: c.fullName, size: 52),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              c.fullName,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 20,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.3,
                              ),
                            ),
                            if (c.companyName != null &&
                                c.companyName!.isNotEmpty)
                              Text(
                                c.companyName!,
                                style: TextStyle(
                                    color: Colors.white.withOpacity(0.7),
                                    fontSize: 13),
                              ),
                          ],
                        ),
                      ),
                      _ActiveToggle(customerId: widget.id, detail: detail),
                    ],
                  ),
                ],
              ),
            ),
          ),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(48),
            child: Container(
              color: _navy,
              child: TabBar(
                controller: _tabs,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                indicatorColor: _blue,
                indicatorWeight: 3,
                labelColor: Colors.white,
                unselectedLabelColor: Colors.white54,
                labelStyle: const TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 13),
                tabs: _tabLabels
                    .map((t) => Tab(
                          child: Row(
                            children: [
                              Icon(t.$2, size: 15),
                              const SizedBox(width: 6),
                              Text(t.$1),
                            ],
                          ),
                        ))
                    .toList(),
              ),
            ),
          ),
        ),
      ],
      body: TabBarView(
        controller: _tabs,
        children: [
          _OverviewTab(detail: detail),
          _AddressesTab(detail: detail, customerId: widget.id),
          _ContactsTab(detail: detail, customerId: widget.id),
          _NotesTab(detail: detail, customerId: widget.id),
          _HistoryTab(detail: detail),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Active toggle
// ─────────────────────────────────────────────────────────────────────────────

class _ActiveToggle extends ConsumerWidget {
  final String customerId;
  final CustomerDetail detail;
  const _ActiveToggle({required this.customerId, required this.detail});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = detail.customer;
    return GestureDetector(
      onTap: () {
        ref.read(customerDetailProvider(customerId).notifier).update(
              firstName: c.firstName,
              lastName: c.lastName,
              companyName: c.companyName,
              email: c.email,
              phone: c.phone,
              mobile: c.mobile,
              notes: c.notes,
              tags: c.tags,
            );
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: c.isActive
              ? _green.withOpacity(0.2)
              : _textMuted.withOpacity(0.2),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
              color: c.isActive
                  ? _green.withOpacity(0.4)
                  : _textMuted.withOpacity(0.3)),
        ),
        child: Text(
          c.isActive ? 'Active' : 'Inactive',
          style: TextStyle(
            color: c.isActive ? _green : Colors.white60,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Overview tab
// ─────────────────────────────────────────────────────────────────────────────

class _OverviewTab extends StatelessWidget {
  final CustomerDetail detail;
  const _OverviewTab({required this.detail});

  @override
  Widget build(BuildContext context) {
    final c = detail.customer;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _SectionCard(
          title: 'Contact Information',
          icon: Icons.contact_phone_outlined,
          children: [
            if (c.email != null && c.email!.isNotEmpty)
              _InfoRow(
                  icon: Icons.email_outlined,
                  label: 'Email',
                  value: c.email!),
            if (c.phone != null && c.phone!.isNotEmpty)
              _InfoRow(
                  icon: Icons.phone_outlined,
                  label: 'Phone',
                  value: c.phone!),
            if (c.mobile != null && c.mobile!.isNotEmpty)
              _InfoRow(
                  icon: Icons.smartphone_rounded,
                  label: 'Mobile',
                  value: c.mobile!),
            if (c.companyName != null && c.companyName!.isNotEmpty)
              _InfoRow(
                  icon: Icons.business_outlined,
                  label: 'Company',
                  value: c.companyName!),
            if (c.source != null && c.source!.isNotEmpty)
              _InfoRow(
                  icon: Icons.alt_route_outlined,
                  label: 'Source',
                  value: c.source!),
            if (c.email == null &&
                c.phone == null &&
                c.mobile == null &&
                c.companyName == null)
              const _EmptyRow(message: 'No contact details added'),
          ],
        ),
        const SizedBox(height: 12),
        if (c.tags.isNotEmpty)
          _SectionCard(
            title: 'Tags',
            icon: Icons.label_outline_rounded,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: c.tags
                    .map((t) => Chip(
                          label: Text(t,
                              style: const TextStyle(
                                  fontSize: 12, color: _navy)),
                          backgroundColor: _blue.withOpacity(0.08),
                          side: BorderSide(color: _blue.withOpacity(0.2)),
                          padding: EdgeInsets.zero,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ))
                    .toList(),
              ),
            ],
          ),
        if (c.notes != null && c.notes!.isNotEmpty) ...[
          const SizedBox(height: 12),
          _SectionCard(
            title: 'Notes',
            icon: Icons.sticky_note_2_outlined,
            children: [
              Text(c.notes!,
                  style: const TextStyle(
                      color: _textMuted, fontSize: 14, height: 1.5)),
            ],
          ),
        ],
        const SizedBox(height: 12),
        _SectionCard(
          title: 'Stats',
          icon: Icons.bar_chart_rounded,
          children: [
            Row(
              children: [
                _StatBox(
                    label: 'Jobs',
                    value: '${detail.jobs.length}',
                    color: _blue),
                const SizedBox(width: 10),
                _StatBox(
                    label: 'Quotes',
                    value: '${detail.quotes.length}',
                    color: _orange),
                const SizedBox(width: 10),
                _StatBox(
                    label: 'Invoices',
                    value: '${detail.invoices.length}',
                    color: _green),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Addresses tab
// ─────────────────────────────────────────────────────────────────────────────

class _AddressesTab extends ConsumerWidget {
  final CustomerDetail detail;
  final String customerId;
  const _AddressesTab({required this.detail, required this.customerId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final addresses = detail.addresses;
    return Stack(
      children: [
        addresses.isEmpty
            ? const _TabEmpty(
                icon: Icons.location_off_outlined,
                message: 'No addresses added')
            : ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 80),
                itemCount: addresses.length,
                itemBuilder: (_, i) => _AddressCard(
                  address: addresses[i],
                  onDelete: () async {
                    await ref
                        .read(customerDetailProvider(customerId).notifier)
                        .deleteAddress(addresses[i].id);
                  },
                ),
              ),
        Positioned(
          bottom: 16,
          right: 16,
          child: FloatingActionButton.extended(
            heroTag: 'add_address',
            onPressed: () => showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              backgroundColor: Colors.transparent,
              builder: (_) =>
                  _AddAddressSheet(customerId: customerId),
            ),
            backgroundColor: _blue,
            icon: const Icon(Icons.add_location_alt_rounded,
                color: Colors.white),
            label: const Text('Add Address',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
      ],
    );
  }
}

class _AddressCard extends StatelessWidget {
  final CustomerAddress address;
  final VoidCallback onDelete;
  const _AddressCard({required this.address, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final parts = [
      address.addressLine1,
      if (address.addressLine2 != null && address.addressLine2!.isNotEmpty)
        address.addressLine2!,
      address.city,
      if (address.state != null && address.state!.isNotEmpty) address.state!,
      if (address.postcode != null && address.postcode!.isNotEmpty)
        address.postcode!,
      address.country,
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        decoration: BoxDecoration(
          color: _cardWhite,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _borderColor),
        ),
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: _blue.withOpacity(0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.location_on_outlined,
                  color: _blue, size: 18),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (address.label.isNotEmpty)
                        Text(address.label,
                            style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                color: _navy,
                                fontSize: 14)),
                      if (address.isPrimary) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: _green.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Text('Primary',
                              style: TextStyle(
                                  color: _green,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600)),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    parts.join(', '),
                    style: const TextStyle(color: _textMuted, fontSize: 13),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline_rounded,
                  color: _red, size: 20),
              onPressed: () async {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: const Text('Delete Address'),
                    content:
                        const Text('Remove this address?'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Cancel')),
                      TextButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('Delete',
                              style: TextStyle(color: _red))),
                    ],
                  ),
                );
                if (confirm == true) onDelete();
              },
              tooltip: 'Delete',
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Contacts tab
// ─────────────────────────────────────────────────────────────────────────────

class _ContactsTab extends ConsumerWidget {
  final CustomerDetail detail;
  final String customerId;
  const _ContactsTab({required this.detail, required this.customerId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final contacts = detail.contacts;
    return Stack(
      children: [
        contacts.isEmpty
            ? const _TabEmpty(
                icon: Icons.person_off_outlined, message: 'No contacts added')
            : ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 80),
                itemCount: contacts.length,
                itemBuilder: (_, i) => _ContactCard(contact: contacts[i]),
              ),
        Positioned(
          bottom: 16,
          right: 16,
          child: FloatingActionButton.extended(
            heroTag: 'add_contact',
            onPressed: () => showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              backgroundColor: Colors.transparent,
              builder: (_) => _AddContactSheet(customerId: customerId),
            ),
            backgroundColor: _blue,
            icon: const Icon(Icons.person_add_outlined, color: Colors.white),
            label: const Text('Add Contact',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
      ],
    );
  }
}

class _ContactCard extends StatelessWidget {
  final CustomerContact contact;
  const _ContactCard({required this.contact});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Container(
          decoration: BoxDecoration(
            color: _cardWhite,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _borderColor),
          ),
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              _Avatar(name: contact.name, size: 44),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(contact.name,
                            style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                color: _navy,
                                fontSize: 14)),
                        if (contact.isPrimary) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color: _blue.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: const Text('Primary',
                                style: TextStyle(
                                    color: _blue,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600)),
                          ),
                        ],
                      ],
                    ),
                    if (contact.role != null && contact.role!.isNotEmpty)
                      Text(contact.role!,
                          style: const TextStyle(
                              color: _textMuted, fontSize: 12)),
                    if (contact.email != null && contact.email!.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Row(children: [
                        const Icon(Icons.email_outlined,
                            size: 12, color: _textMuted),
                        const SizedBox(width: 4),
                        Text(contact.email!,
                            style: const TextStyle(
                                color: _textMuted, fontSize: 12)),
                      ]),
                    ],
                    if (contact.phone != null && contact.phone!.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Row(children: [
                        const Icon(Icons.phone_outlined,
                            size: 12, color: _textMuted),
                        const SizedBox(width: 4),
                        Text(contact.phone!,
                            style: const TextStyle(
                                color: _textMuted, fontSize: 12)),
                      ]),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Notes tab
// ─────────────────────────────────────────────────────────────────────────────

class _NotesTab extends ConsumerWidget {
  final CustomerDetail detail;
  final String customerId;
  const _NotesTab({required this.detail, required this.customerId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notes = detail.notes;
    return Stack(
      children: [
        notes.isEmpty
            ? const _TabEmpty(
                icon: Icons.notes_rounded, message: 'No notes yet')
            : ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 80),
                itemCount: notes.length,
                itemBuilder: (_, i) => _NoteCard(note: notes[i]),
              ),
        Positioned(
          bottom: 16,
          right: 16,
          child: FloatingActionButton.extended(
            heroTag: 'add_note',
            onPressed: () => showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              backgroundColor: Colors.transparent,
              builder: (_) => _AddNoteSheet(customerId: customerId),
            ),
            backgroundColor: _navy,
            icon: const Icon(Icons.add_comment_outlined, color: Colors.white),
            label: const Text('Add Note',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
      ],
    );
  }
}

class _NoteCard extends StatelessWidget {
  final CustomerNote note;
  const _NoteCard({required this.note});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Timeline dot
            Column(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: _blue,
                    shape: BoxShape.circle,
                    border: Border.all(color: _blue.withOpacity(0.3), width: 2),
                  ),
                ),
                Container(
                  width: 2,
                  height: 60,
                  color: _borderColor,
                ),
              ],
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: _cardWhite,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _borderColor),
                ),
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (note.author != null && note.author!.isNotEmpty) ...[
                          const Icon(Icons.account_circle_outlined,
                              size: 14, color: _textMuted),
                          const SizedBox(width: 4),
                          Text(note.author!,
                              style: const TextStyle(
                                  color: _textMuted,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600)),
                          const SizedBox(width: 8),
                        ],
                        Expanded(
                          child: Text(
                            _formatDate(note.createdAt),
                            style: const TextStyle(
                                color: _textMuted, fontSize: 11),
                            textAlign: TextAlign.right,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(note.content,
                        style: const TextStyle(
                            color: _navy, fontSize: 14, height: 1.5)),
                  ],
                ),
              ),
            ),
          ],
        ),
      );

  String _formatDate(String iso) {
    try {
      final dt = DateTime.parse(iso).toLocal();
      return '${dt.day}/${dt.month}/${dt.year}';
    } catch (_) {
      return iso;
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// History tab
// ─────────────────────────────────────────────────────────────────────────────

class _HistoryTab extends StatelessWidget {
  final CustomerDetail detail;
  const _HistoryTab({required this.detail});

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _SectionCard(
            title: 'Jobs',
            icon: Icons.work_outline_rounded,
            children: detail.jobs.isEmpty
                ? [const _EmptyRow(message: 'No jobs found')]
                : detail.jobs.map((j) => _JobRow(job: j)).toList(),
          ),
          const SizedBox(height: 12),
          _SectionCard(
            title: 'Quotes',
            icon: Icons.request_quote_outlined,
            children: detail.quotes.isEmpty
                ? [const _EmptyRow(message: 'No quotes found')]
                : detail.quotes.map((q) => _QuoteRow(quote: q)).toList(),
          ),
          const SizedBox(height: 12),
          _SectionCard(
            title: 'Invoices',
            icon: Icons.receipt_long_outlined,
            children: detail.invoices.isEmpty
                ? [const _EmptyRow(message: 'No invoices found')]
                : detail.invoices
                    .map((inv) => _InvoiceRow(invoice: inv))
                    .toList(),
          ),
        ],
      );
}

class _JobRow extends StatelessWidget {
  final JobSummary job;
  const _JobRow({required this.job});

  @override
  Widget build(BuildContext context) {
    final statusColor = _jobStatusColor(job.status);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration:
                BoxDecoration(color: statusColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(job.title,
                    style: const TextStyle(
                        color: _navy,
                        fontWeight: FontWeight.w600,
                        fontSize: 13)),
                Text('${job.jobNumber} · ${job.status}',
                    style: const TextStyle(color: _textMuted, fontSize: 11)),
              ],
            ),
          ),
          _PriorityBadge(priority: job.priority),
        ],
      ),
    );
  }

  Color _jobStatusColor(String status) {
    switch (status.toLowerCase()) {
      case 'completed':
        return _green;
      case 'in_progress':
        return _blue;
      case 'cancelled':
        return _red;
      default:
        return _orange;
    }
  }
}

class _QuoteRow extends StatelessWidget {
  final QuoteSummary quote;
  const _QuoteRow({required this.quote});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            const Icon(Icons.description_outlined, size: 16, color: _orange),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(quote.title,
                      style: const TextStyle(
                          color: _navy,
                          fontWeight: FontWeight.w600,
                          fontSize: 13)),
                  Text('${quote.quoteNumber} · ${quote.status}',
                      style: const TextStyle(color: _textMuted, fontSize: 11)),
                ],
              ),
            ),
            Text(
              '\$${quote.total.toStringAsFixed(2)}',
              style: const TextStyle(
                  color: _navy, fontWeight: FontWeight.w700, fontSize: 13),
            ),
          ],
        ),
      );
}

class _InvoiceRow extends StatelessWidget {
  final InvoiceSummary invoice;
  const _InvoiceRow({required this.invoice});

  @override
  Widget build(BuildContext context) {
    final isOverdue = invoice.status.toLowerCase() == 'overdue';
    final isPaid = invoice.amountPaid >= invoice.total && invoice.total > 0;
    final color = isPaid ? _green : (isOverdue ? _red : _textMuted);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(Icons.receipt_outlined, size: 16, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(invoice.invoiceNumber,
                    style: const TextStyle(
                        color: _navy,
                        fontWeight: FontWeight.w600,
                        fontSize: 13)),
                Text(invoice.status,
                    style: TextStyle(color: color, fontSize: 11)),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '\$${invoice.total.toStringAsFixed(2)}',
                style: const TextStyle(
                    color: _navy, fontWeight: FontWeight.w700, fontSize: 13),
              ),
              if (invoice.amountPaid > 0 && !isPaid)
                Text(
                  'Paid \$${invoice.amountPaid.toStringAsFixed(2)}',
                  style: const TextStyle(color: _green, fontSize: 11),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PriorityBadge extends StatelessWidget {
  final String priority;
  const _PriorityBadge({required this.priority});

  @override
  Widget build(BuildContext context) {
    Color color;
    switch (priority.toLowerCase()) {
      case 'high':
        color = _red;
        break;
      case 'medium':
        color = _orange;
        break;
      default:
        color = _textMuted;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(priority,
          style: TextStyle(
              color: color, fontSize: 10, fontWeight: FontWeight.w600)),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Edit customer sheet
// ─────────────────────────────────────────────────────────────────────────────

class _EditCustomerSheet extends ConsumerStatefulWidget {
  final String customerId;
  final Customer customer;
  const _EditCustomerSheet(
      {required this.customerId, required this.customer});

  @override
  ConsumerState<_EditCustomerSheet> createState() =>
      _EditCustomerSheetState();
}

class _EditCustomerSheetState extends ConsumerState<_EditCustomerSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _firstCtrl;
  late final TextEditingController _lastCtrl;
  late final TextEditingController _companyCtrl;
  late final TextEditingController _emailCtrl;
  late final TextEditingController _phoneCtrl;
  late final TextEditingController _mobileCtrl;
  late final TextEditingController _notesCtrl;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final c = widget.customer;
    _firstCtrl = TextEditingController(text: c.firstName);
    _lastCtrl = TextEditingController(text: c.lastName ?? '');
    _companyCtrl = TextEditingController(text: c.companyName ?? '');
    _emailCtrl = TextEditingController(text: c.email ?? '');
    _phoneCtrl = TextEditingController(text: c.phone ?? '');
    _mobileCtrl = TextEditingController(text: c.mobile ?? '');
    _notesCtrl = TextEditingController(text: c.notes ?? '');
  }

  @override
  void dispose() {
    _firstCtrl.dispose();
    _lastCtrl.dispose();
    _companyCtrl.dispose();
    _emailCtrl.dispose();
    _phoneCtrl.dispose();
    _mobileCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final ok = await ref
        .read(customerDetailProvider(widget.customerId).notifier)
        .update(
          firstName: _firstCtrl.text.trim(),
          lastName: _lastCtrl.text.trim(),
          companyName: _companyCtrl.text.trim(),
          email: _emailCtrl.text.trim(),
          phone: _phoneCtrl.text.trim(),
          mobile: _mobileCtrl.text.trim(),
          notes: _notesCtrl.text.trim(),
          tags: widget.customer.tags,
        );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) {
      Navigator.of(context).pop();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Failed to update customer'),
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
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: _borderColor,
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
                    child: const Icon(Icons.edit_rounded, color: _blue, size: 18),
                  ),
                  const SizedBox(width: 10),
                  const Text('Edit Customer',
                      style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: _navy)),
                ],
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                      child: _SheetField(
                          ctrl: _firstCtrl,
                          label: 'First Name *',
                          validator: (v) =>
                              v == null || v.trim().isEmpty
                                  ? 'Required'
                                  : null)),
                  const SizedBox(width: 12),
                  Expanded(
                      child:
                          _SheetField(ctrl: _lastCtrl, label: 'Last Name')),
                ],
              ),
              const SizedBox(height: 12),
              _SheetField(ctrl: _companyCtrl, label: 'Company'),
              const SizedBox(height: 12),
              _SheetField(
                  ctrl: _emailCtrl,
                  label: 'Email',
                  keyboardType: TextInputType.emailAddress),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                      child: _SheetField(
                          ctrl: _phoneCtrl,
                          label: 'Phone',
                          keyboardType: TextInputType.phone)),
                  const SizedBox(width: 12),
                  Expanded(
                      child: _SheetField(
                          ctrl: _mobileCtrl,
                          label: 'Mobile',
                          keyboardType: TextInputType.phone)),
                ],
              ),
              const SizedBox(height: 12),
              _SheetField(ctrl: _notesCtrl, label: 'Notes', maxLines: 3),
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
                      : const Text('Save Changes',
                          style: TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 15)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Add Address sheet
// ─────────────────────────────────────────────────────────────────────────────

class _AddAddressSheet extends ConsumerStatefulWidget {
  final String customerId;
  const _AddAddressSheet({required this.customerId});

  @override
  ConsumerState<_AddAddressSheet> createState() => _AddAddressSheetState();
}

class _AddAddressSheetState extends ConsumerState<_AddAddressSheet> {
  final _formKey = GlobalKey<FormState>();
  final _labelCtrl = TextEditingController();
  final _line1Ctrl = TextEditingController();
  final _line2Ctrl = TextEditingController();
  final _cityCtrl = TextEditingController();
  final _stateCtrl = TextEditingController();
  final _postcodeCtrl = TextEditingController();
  final _countryCtrl = TextEditingController(text: 'Australia');
  bool _isPrimary = false;
  bool _saving = false;

  @override
  void dispose() {
    _labelCtrl.dispose();
    _line1Ctrl.dispose();
    _line2Ctrl.dispose();
    _cityCtrl.dispose();
    _stateCtrl.dispose();
    _postcodeCtrl.dispose();
    _countryCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final ok = await ref
        .read(customerDetailProvider(widget.customerId).notifier)
        .addAddress(
          label: _labelCtrl.text.trim(),
          addressLine1: _line1Ctrl.text.trim(),
          addressLine2: _line2Ctrl.text.trim(),
          city: _cityCtrl.text.trim(),
          state: _stateCtrl.text.trim(),
          postcode: _postcodeCtrl.text.trim(),
          country: _countryCtrl.text.trim(),
          isPrimary: _isPrimary,
        );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) Navigator.of(context).pop();
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
              _SheetHandle(),
              const SizedBox(height: 20),
              _SheetTitle(icon: Icons.add_location_alt_rounded, title: 'Add Address'),
              const SizedBox(height: 20),
              _SheetField(ctrl: _labelCtrl, label: 'Label (e.g. Home, Office)'),
              const SizedBox(height: 12),
              _SheetField(
                  ctrl: _line1Ctrl,
                  label: 'Address Line 1 *',
                  validator: (v) =>
                      v == null || v.trim().isEmpty ? 'Required' : null),
              const SizedBox(height: 12),
              _SheetField(ctrl: _line2Ctrl, label: 'Address Line 2'),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                      child: _SheetField(
                          ctrl: _cityCtrl,
                          label: 'City *',
                          validator: (v) =>
                              v == null || v.trim().isEmpty
                                  ? 'Required'
                                  : null)),
                  const SizedBox(width: 12),
                  Expanded(
                      child:
                          _SheetField(ctrl: _stateCtrl, label: 'State')),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                      child: _SheetField(
                          ctrl: _postcodeCtrl,
                          label: 'Postcode',
                          keyboardType: TextInputType.number)),
                  const SizedBox(width: 12),
                  Expanded(
                      child:
                          _SheetField(ctrl: _countryCtrl, label: 'Country')),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Switch(
                    value: _isPrimary,
                    onChanged: (v) => setState(() => _isPrimary = v),
                    activeColor: _blue,
                  ),
                  const Text('Set as primary address',
                      style: TextStyle(color: _navy, fontSize: 14)),
                ],
              ),
              const SizedBox(height: 20),
              _SubmitButton(
                  saving: _saving,
                  label: 'Add Address',
                  onPressed: _submit),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Add Contact sheet
// ─────────────────────────────────────────────────────────────────────────────

class _AddContactSheet extends ConsumerStatefulWidget {
  final String customerId;
  const _AddContactSheet({required this.customerId});

  @override
  ConsumerState<_AddContactSheet> createState() => _AddContactSheetState();
}

class _AddContactSheetState extends ConsumerState<_AddContactSheet> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _roleCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  bool _isPrimary = false;
  bool _saving = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _roleCtrl.dispose();
    _emailCtrl.dispose();
    _phoneCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final ok = await ref
        .read(customerDetailProvider(widget.customerId).notifier)
        .addContact(
          name: _nameCtrl.text.trim(),
          role: _roleCtrl.text.trim(),
          email: _emailCtrl.text.trim(),
          phone: _phoneCtrl.text.trim(),
          isPrimary: _isPrimary,
        );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) Navigator.of(context).pop();
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
              _SheetHandle(),
              const SizedBox(height: 20),
              _SheetTitle(icon: Icons.person_add_outlined, title: 'Add Contact'),
              const SizedBox(height: 20),
              _SheetField(
                  ctrl: _nameCtrl,
                  label: 'Full Name *',
                  validator: (v) =>
                      v == null || v.trim().isEmpty ? 'Required' : null),
              const SizedBox(height: 12),
              _SheetField(ctrl: _roleCtrl, label: 'Role / Title'),
              const SizedBox(height: 12),
              _SheetField(
                  ctrl: _emailCtrl,
                  label: 'Email',
                  keyboardType: TextInputType.emailAddress),
              const SizedBox(height: 12),
              _SheetField(
                  ctrl: _phoneCtrl,
                  label: 'Phone',
                  keyboardType: TextInputType.phone),
              const SizedBox(height: 12),
              Row(
                children: [
                  Switch(
                    value: _isPrimary,
                    onChanged: (v) => setState(() => _isPrimary = v),
                    activeColor: _blue,
                  ),
                  const Text('Primary contact',
                      style: TextStyle(color: _navy, fontSize: 14)),
                ],
              ),
              const SizedBox(height: 20),
              _SubmitButton(
                  saving: _saving, label: 'Add Contact', onPressed: _submit),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Add Note sheet
// ─────────────────────────────────────────────────────────────────────────────

class _AddNoteSheet extends ConsumerStatefulWidget {
  final String customerId;
  const _AddNoteSheet({required this.customerId});

  @override
  ConsumerState<_AddNoteSheet> createState() => _AddNoteSheetState();
}

class _AddNoteSheetState extends ConsumerState<_AddNoteSheet> {
  final _formKey = GlobalKey<FormState>();
  final _contentCtrl = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _contentCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final ok = await ref
        .read(customerDetailProvider(widget.customerId).notifier)
        .addNote(content: _contentCtrl.text.trim());
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) Navigator.of(context).pop();
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
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SheetHandle(),
            const SizedBox(height: 20),
            _SheetTitle(icon: Icons.add_comment_outlined, title: 'Add Note'),
            const SizedBox(height: 20),
            _SheetField(
              ctrl: _contentCtrl,
              label: 'Note content *',
              maxLines: 5,
              validator: (v) =>
                  v == null || v.trim().isEmpty ? 'Required' : null,
            ),
            const SizedBox(height: 24),
            _SubmitButton(
                saving: _saving, label: 'Add Note', onPressed: _submit),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared UI components
// ─────────────────────────────────────────────────────────────────────────────

class _SectionCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<Widget> children;

  const _SectionCard({
    required this.title,
    required this.icon,
    required this.children,
  });

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: _cardWhite,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _borderColor),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
              child: Row(
                children: [
                  Icon(icon, size: 16, color: _blue),
                  const SizedBox(width: 8),
                  Text(title,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          color: _navy)),
                ],
              ),
            ),
            const Divider(height: 1, color: _borderColor),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: children),
            ),
          ],
        ),
      );
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _InfoRow(
      {required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          children: [
            Icon(icon, size: 15, color: _blue),
            const SizedBox(width: 10),
            SizedBox(
              width: 70,
              child: Text(label,
                  style:
                      const TextStyle(color: _textMuted, fontSize: 12)),
            ),
            Expanded(
              child: Text(value,
                  style: const TextStyle(
                      color: _navy,
                      fontWeight: FontWeight.w500,
                      fontSize: 13)),
            ),
          ],
        ),
      );
}

class _EmptyRow extends StatelessWidget {
  final String message;
  const _EmptyRow({required this.message});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(message,
              style: const TextStyle(color: _textMuted, fontSize: 13)),
        ),
      );
}

class _StatBox extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _StatBox(
      {required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) => Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: color.withOpacity(0.07),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: color.withOpacity(0.15)),
          ),
          child: Column(
            children: [
              Text(value,
                  style: TextStyle(
                      color: color,
                      fontWeight: FontWeight.w800,
                      fontSize: 22)),
              const SizedBox(height: 4),
              Text(label,
                  style:
                      const TextStyle(color: _textMuted, fontSize: 11)),
            ],
          ),
        ),
      );
}

class _TabEmpty extends StatelessWidget {
  final IconData icon;
  final String message;
  const _TabEmpty({required this.icon, required this.message});

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: _blue.withOpacity(0.07),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 32, color: _blue),
            ),
            const SizedBox(height: 16),
            Text(message,
                style: const TextStyle(
                    color: _textMuted,
                    fontSize: 14,
                    fontWeight: FontWeight.w500)),
          ],
        ),
      );
}

class _Avatar extends StatelessWidget {
  final String name;
  final double size;
  const _Avatar({required this.name, required this.size});

  String get _initials {
    final parts = name.trim().split(' ');
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return name.isNotEmpty ? name[0].toUpperCase() : '?';
  }

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: _blue.withOpacity(0.18),
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Text(
          _initials,
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w800,
            fontSize: size * 0.35,
          ),
        ),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Sheet helpers
// ─────────────────────────────────────────────────────────────────────────────

class _SheetHandle extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Center(
        child: Container(
          width: 40,
          height: 4,
          decoration: BoxDecoration(
            color: _borderColor,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      );
}

class _SheetTitle extends StatelessWidget {
  final IconData icon;
  final String title;
  const _SheetTitle({required this.icon, required this.title});

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: _blue.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: _blue, size: 18),
          ),
          const SizedBox(width: 10),
          Text(title,
              style: const TextStyle(
                  fontSize: 18, fontWeight: FontWeight.w700, color: _navy)),
        ],
      );
}

class _SheetField extends StatelessWidget {
  final TextEditingController ctrl;
  final String label;
  final TextInputType? keyboardType;
  final int? maxLines;
  final String? Function(String?)? validator;

  const _SheetField({
    required this.ctrl,
    required this.label,
    this.keyboardType,
    this.maxLines = 1,
    this.validator,
  });

  @override
  Widget build(BuildContext context) => TextFormField(
        controller: ctrl,
        keyboardType: keyboardType,
        maxLines: maxLines,
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

class _SubmitButton extends StatelessWidget {
  final bool saving;
  final String label;
  final VoidCallback onPressed;

  const _SubmitButton({
    required this.saving,
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) => SizedBox(
        width: double.infinity,
        height: 50,
        child: ElevatedButton(
          onPressed: saving ? null : onPressed,
          style: ElevatedButton.styleFrom(
            backgroundColor: _blue,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
            elevation: 0,
          ),
          child: saving
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      color: Colors.white, strokeWidth: 2))
              : Text(label,
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 15)),
        ),
      );
}
