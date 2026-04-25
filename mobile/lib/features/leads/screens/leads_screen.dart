import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';

import '../../../core/utils/theme.dart';
import '../providers/leads_provider.dart';

// ── Status config ─────────────────────────────────────────────────────────────

const _statuses = ['new', 'contacted', 'qualified', 'proposal', 'won', 'lost'];
const _statusLabels = {
  'new': 'New',
  'contacted': 'Contacted',
  'qualified': 'Qualified',
  'proposal': 'Proposal',
  'won': 'Won',
  'lost': 'Lost',
};

Color _statusColor(String status) {
  switch (status) {
    case 'new':
      return TradieColors.electricBlue;
    case 'contacted':
      return TradieColors.safetyOrange;
    case 'qualified':
      return const Color(0xFF7C3AED); // purple
    case 'proposal':
      return const Color(0xFFF59E0B); // amber
    case 'won':
      return TradieColors.green;
    case 'lost':
    default:
      return TradieColors.grey400;
  }
}

IconData _statusIcon(String status) {
  switch (status) {
    case 'new':
      return Iconsax.user_add;
    case 'contacted':
      return Iconsax.call;
    case 'qualified':
      return Iconsax.tick_circle;
    case 'proposal':
      return Iconsax.document_text;
    case 'won':
      return Iconsax.medal_star;
    case 'lost':
    default:
      return Iconsax.close_circle;
  }
}

// ── Screen ────────────────────────────────────────────────────────────────────

class LeadsScreen extends ConsumerStatefulWidget {
  const LeadsScreen({super.key});

  @override
  ConsumerState<LeadsScreen> createState() => _LeadsScreenState();
}

class _LeadsScreenState extends ConsumerState<LeadsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tab;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: _statuses.length, vsync: this);
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(leadsProvider);

    return Scaffold(
      backgroundColor: TradieColors.grey50,
      appBar: AppBar(
        backgroundColor: TradieColors.white,
        elevation: 0,
        title: const Row(children: [
          Icon(Iconsax.profile_2user, color: TradieColors.electricBlue, size: 20),
          SizedBox(width: 8),
          Text(
            'Leads',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: TradieColors.navy,
            ),
          ),
        ]),
        actions: [
          IconButton(
            icon: const Icon(Iconsax.refresh, color: TradieColors.grey400),
            onPressed: () => ref.read(leadsProvider.notifier).load(),
          ),
        ],
        bottom: TabBar(
          controller: _tab,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          labelColor: TradieColors.electricBlue,
          unselectedLabelColor: TradieColors.grey400,
          indicatorColor: TradieColors.electricBlue,
          indicatorSize: TabBarIndicatorSize.label,
          labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          tabs: _statuses.map((s) {
            final count = state.byStatus(s).length;
            return Tab(
              child: Row(children: [
                Text(_statusLabels[s]!),
                if (count > 0) ...[
                  const SizedBox(width: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: _statusColor(s).withOpacity(0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '$count',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: _statusColor(s),
                      ),
                    ),
                  ),
                ],
              ]),
            );
          }).toList(),
        ),
      ),
      body: state.loading
          ? const Center(child: CircularProgressIndicator(color: TradieColors.electricBlue))
          : state.error != null
              ? _buildError(state.error!)
              : TabBarView(
                  controller: _tab,
                  children: _statuses.map((s) {
                    final leads = state.byStatus(s);
                    return _LeadStatusColumn(status: s, leads: leads);
                  }).toList(),
                ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: TradieColors.electricBlue,
        icon: const Icon(Iconsax.user_add, color: TradieColors.white),
        label: const Text(
          'Add Lead',
          style: TextStyle(color: TradieColors.white, fontWeight: FontWeight.w600),
        ),
        onPressed: () => _showAddLeadSheet(context),
      ),
    );
  }

  Widget _buildError(String error) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Iconsax.warning_2, color: TradieColors.red, size: 40),
          const SizedBox(height: 12),
          Text('Failed to load leads', style: TextStyle(color: TradieColors.navy, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(error, style: TextStyle(color: TradieColors.grey400, fontSize: 12)),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: () => ref.read(leadsProvider.notifier).load(),
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  void _showAddLeadSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _AddLeadSheet(),
    );
  }
}

// ── Lead list for one status column ──────────────────────────────────────────

class _LeadStatusColumn extends ConsumerWidget {
  final String status;
  final List<Lead> leads;

  const _LeadStatusColumn({required this.status, required this.leads});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (leads.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_statusIcon(status), color: TradieColors.grey200, size: 48),
            const SizedBox(height: 12),
            Text(
              'No ${_statusLabels[status]!.toLowerCase()} leads',
              style: const TextStyle(color: TradieColors.grey400, fontSize: 14),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: leads.length,
      itemBuilder: (_, i) => _LeadCard(lead: leads[i]),
    );
  }
}

// ── Lead card ─────────────────────────────────────────────────────────────────

class _LeadCard extends ConsumerWidget {
  final Lead lead;

  const _LeadCard({required this.lead});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final color = _statusColor(lead.status);

    return GestureDetector(
      onLongPress: () => _showActions(context, ref),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: TradieColors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border(left: BorderSide(color: color, width: 3)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.04),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  // Avatar initials
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: color.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Center(
                      child: Text(
                        _initials(lead.fullName),
                        style: TextStyle(
                          color: color,
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          lead.fullName,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: TradieColors.navy,
                          ),
                        ),
                        if (lead.email.isNotEmpty)
                          Text(
                            lead.email,
                            style: const TextStyle(
                              fontSize: 12,
                              color: TradieColors.grey400,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                  // Options menu
                  GestureDetector(
                    onTap: () => _showActions(context, ref),
                    child: const Icon(
                      Iconsax.more,
                      color: TradieColors.grey400,
                      size: 18,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  if (lead.phone.isNotEmpty) ...[
                    const Icon(Iconsax.call, size: 13, color: TradieColors.grey400),
                    const SizedBox(width: 4),
                    Text(lead.phone, style: const TextStyle(fontSize: 12, color: TradieColors.grey400)),
                    const SizedBox(width: 12),
                  ],
                  if (lead.source.isNotEmpty)
                    _SourceBadge(source: lead.source),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _initials(String name) {
    final parts = name.trim().split(' ');
    if (parts.length >= 2) return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
    return name.isNotEmpty ? name[0].toUpperCase() : '?';
  }

  void _showActions(BuildContext context, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _LeadActionsSheet(lead: lead),
    );
  }
}

// ── Source badge ─────────────────────────────────────────────────────────────

class _SourceBadge extends StatelessWidget {
  final String source;
  const _SourceBadge({required this.source});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: TradieColors.grey50,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: TradieColors.grey200),
      ),
      child: Text(
        source,
        style: const TextStyle(
          fontSize: 11,
          color: TradieColors.grey400,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

// ── Lead actions sheet ────────────────────────────────────────────────────────

class _LeadActionsSheet extends ConsumerWidget {
  final Lead lead;
  const _LeadActionsSheet({required this.lead});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      margin: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: TradieColors.white,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 10),
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: TradieColors.grey200,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
            child: Row(children: [
              Text(
                lead.fullName,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: TradieColors.navy,
                ),
              ),
            ]),
          ),
          // Status transitions
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 6,
              children: _statuses
                  .where((s) => s != lead.status)
                  .map((s) => ActionChip(
                        label: Text(
                          'Move to ${_statusLabels[s]!}',
                          style: TextStyle(
                            fontSize: 12,
                            color: _statusColor(s),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        backgroundColor: _statusColor(s).withOpacity(0.08),
                        side: BorderSide(color: _statusColor(s).withOpacity(0.2)),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(20)),
                        onPressed: () async {
                          Navigator.pop(context);
                          await ref
                              .read(leadsProvider.notifier)
                              .updateStatus(lead.id, s);
                        },
                      ))
                  .toList(),
            ),
          ),
          const Divider(height: 1),
          // Convert to customer
          if (lead.status != 'won')
            ListTile(
              leading: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: TradieColors.green.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Iconsax.user_tick, color: TradieColors.green, size: 18),
              ),
              title: const Text(
                'Convert to Customer',
                style: TextStyle(fontWeight: FontWeight.w600, color: TradieColors.navy),
              ),
              subtitle: const Text('Creates a customer record'),
              onTap: () async {
                Navigator.pop(context);
                final customerId = await ref
                    .read(leadsProvider.notifier)
                    .convertToCustomer(lead.id);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        customerId != null
                            ? 'Lead converted to customer successfully'
                            : 'Failed to convert lead',
                      ),
                      backgroundColor:
                          customerId != null ? TradieColors.green : TradieColors.red,
                    ),
                  );
                }
              },
            ),
          // Delete
          ListTile(
            leading: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: TradieColors.red.withOpacity(0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Iconsax.trash, color: TradieColors.red, size: 18),
            ),
            title: const Text(
              'Delete Lead',
              style: TextStyle(fontWeight: FontWeight.w600, color: TradieColors.red),
            ),
            onTap: () async {
              Navigator.pop(context);
              final ok = await ref.read(leadsProvider.notifier).delete(lead.id);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(ok ? 'Lead deleted' : 'Failed to delete lead'),
                  ),
                );
              }
            },
          ),
          SizedBox(height: MediaQuery.of(context).padding.bottom + 8),
        ],
      ),
    );
  }
}

// ── Add lead bottom sheet ─────────────────────────────────────────────────────

class _AddLeadSheet extends ConsumerStatefulWidget {
  const _AddLeadSheet();

  @override
  ConsumerState<_AddLeadSheet> createState() => _AddLeadSheetState();
}

class _AddLeadSheetState extends ConsumerState<_AddLeadSheet> {
  final _firstName = TextEditingController();
  final _lastName = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _notes = TextEditingController();
  String _source = '';
  bool _saving = false;

  final _sources = ['Referral', 'Website', 'Social Media', 'Cold Call', 'Trade Show', 'Other'];

  @override
  void dispose() {
    _firstName.dispose();
    _lastName.dispose();
    _email.dispose();
    _phone.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_firstName.text.trim().isEmpty) return;
    setState(() => _saving = true);
    final lead = await ref.read(leadsProvider.notifier).create(
          firstName: _firstName.text.trim(),
          lastName: _lastName.text.trim(),
          email: _email.text.trim(),
          phone: _phone.text.trim(),
          source: _source,
          notes: _notes.text.trim(),
        );
    setState(() => _saving = false);
    if (mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(lead != null ? 'Lead added successfully' : 'Failed to add lead'),
          backgroundColor: lead != null ? TradieColors.green : TradieColors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        margin: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: TradieColors.white,
          borderRadius: BorderRadius.circular(20),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: TradieColors.electricBlue.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Iconsax.user_add, color: TradieColors.electricBlue, size: 18),
                ),
                const SizedBox(width: 10),
                const Text(
                  'New Lead',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: TradieColors.navy,
                  ),
                ),
              ]),
              const SizedBox(height: 20),
              Row(children: [
                Expanded(child: _field(_firstName, 'First name *', Iconsax.user)),
                const SizedBox(width: 10),
                Expanded(child: _field(_lastName, 'Last name', Iconsax.user)),
              ]),
              const SizedBox(height: 12),
              _field(_email, 'Email', Iconsax.sms, keyboard: TextInputType.emailAddress),
              const SizedBox(height: 12),
              _field(_phone, 'Phone', Iconsax.call, keyboard: TextInputType.phone),
              const SizedBox(height: 12),
              // Source dropdown
              DropdownButtonFormField<String>(
                value: _source.isEmpty ? null : _source,
                hint: const Text('Lead source', style: TextStyle(color: TradieColors.grey400, fontSize: 14)),
                decoration: InputDecoration(
                  prefixIcon: const Icon(Iconsax.hierarchy_3, size: 18, color: TradieColors.grey400),
                  filled: true,
                  fillColor: TradieColors.grey50,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: TradieColors.grey200),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: TradieColors.grey200),
                  ),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  isDense: true,
                ),
                items: _sources.map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
                onChanged: (v) => setState(() => _source = v ?? ''),
              ),
              const SizedBox(height: 12),
              _field(_notes, 'Notes', Iconsax.note_text, maxLines: 3),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  onPressed: _saving ? null : _save,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: TradieColors.electricBlue,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  child: _saving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(color: TradieColors.white, strokeWidth: 2),
                        )
                      : const Text(
                          'Add Lead',
                          style: TextStyle(
                            color: TradieColors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _field(
    TextEditingController ctrl,
    String hint,
    IconData icon, {
    TextInputType? keyboard,
    int maxLines = 1,
  }) {
    return TextField(
      controller: ctrl,
      keyboardType: keyboard,
      maxLines: maxLines,
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: TradieColors.grey400, fontSize: 14),
        prefixIcon: Icon(icon, size: 18, color: TradieColors.grey400),
        filled: true,
        fillColor: TradieColors.grey50,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: TradieColors.grey200),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: TradieColors.grey200),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: TradieColors.electricBlue, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        isDense: true,
      ),
    );
  }
}
