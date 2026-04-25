import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';

import '../../../core/utils/theme.dart';
import '../../../core/providers/settings_provider.dart'
    show auditLogProvider, auditLogKey;

class AuditLogScreen extends ConsumerStatefulWidget {
  const AuditLogScreen({super.key});

  @override
  ConsumerState<AuditLogScreen> createState() => _AuditLogScreenState();
}

class _AuditLogScreenState extends ConsumerState<AuditLogScreen> {
  int _page = 1;
  String _actionFilter = '';
  String _entityFilter = '';

  static const _actionOptions = [
    '',
    'create',
    'update',
    'delete',
    'revoke',
    'login',
    'logout',
    'mfa.enabled',
    'mfa.disabled',
    'session.revoked',
  ];

  static const _entityOptions = [
    '',
    'api_key',
    'general_settings',
    'security_settings',
    'user',
    'job',
    'invoice',
    'quote',
    'customer',
  ];

  String get _cacheKey => auditLogKey(
        page: _page,
        limit: 50,
        action: _actionFilter,
        entityType: _entityFilter,
      );

  void _reset() => setState(() {
        _page = 1;
        _actionFilter = '';
        _entityFilter = '';
      });

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(auditLogProvider(_cacheKey));

    return Scaffold(
      backgroundColor: TradieColors.grey50,
      appBar: AppBar(
        title: Row(children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: TradieColors.electricBlue.withOpacity(0.1),
              borderRadius: BorderRadius.circular(9),
            ),
            child: const Icon(Iconsax.clipboard_text,
                color: TradieColors.electricBlue, size: 18),
          ),
          const SizedBox(width: 10),
          const Text('Audit Log'),
        ]),
        actions: [
          IconButton(
            icon: const Icon(Iconsax.filter),
            tooltip: 'Filter',
            onPressed: () => _showFilterSheet(context),
          ),
          if (_actionFilter.isNotEmpty || _entityFilter.isNotEmpty)
            TextButton(
              onPressed: _reset,
              child: const Text('Clear',
                  style: TextStyle(color: TradieColors.electricBlue)),
            ),
        ],
      ),
      body: Column(children: [
        // Active filter chips
        if (_actionFilter.isNotEmpty || _entityFilter.isNotEmpty)
          Container(
            color: TradieColors.white,
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(children: [
              const Icon(Iconsax.filter_edit,
                  size: 14, color: TradieColors.grey600),
              const SizedBox(width: 8),
              if (_actionFilter.isNotEmpty)
                _FilterChip(
                  label: 'Action: $_actionFilter',
                  onRemove: () =>
                      setState(() => _actionFilter = ''),
                ),
              if (_entityFilter.isNotEmpty)
                _FilterChip(
                  label: 'Type: $_entityFilter',
                  onRemove: () =>
                      setState(() => _entityFilter = ''),
                ),
            ]),
          ),

        // Log list
        Expanded(
          child: async.when(
            loading: () =>
                const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Iconsax.warning_2,
                    color: TradieColors.alertRed, size: 40),
                const SizedBox(height: 12),
                Text('Failed to load audit log',
                    style: const TextStyle(
                        color: TradieColors.navy,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text('$e',
                    style: const TextStyle(
                        color: TradieColors.grey600, fontSize: 12)),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: () => ref.invalidate(auditLogProvider(_cacheKey)),
                  icon: const Icon(Iconsax.refresh, size: 16),
                  label: const Text('Retry'),
                  style: FilledButton.styleFrom(
                      backgroundColor: TradieColors.electricBlue),
                ),
              ]),
            ),
            data: (result) {
              final entries =
                  List<dynamic>.from(result['data'] as List? ?? []);
              final meta = result['meta'] as Map<String, dynamic>? ?? {};
              final total = meta['total'] as int? ?? 0;
              final pages = meta['pages'] as int? ?? 1;

              if (entries.isEmpty) {
                return Center(
                  child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Iconsax.clipboard_text,
                            size: 48, color: TradieColors.grey400),
                        const SizedBox(height: 12),
                        const Text('No audit log entries',
                            style: TextStyle(
                                color: TradieColors.grey600,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(height: 4),
                        const Text('Actions will appear here as they happen.',
                            style: TextStyle(
                                color: TradieColors.grey400,
                                fontSize: 13)),
                      ]),
                );
              }

              return Column(children: [
                // Summary bar
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 10),
                  color: TradieColors.white,
                  child: Row(children: [
                    Text(
                      '$total event${total == 1 ? '' : 's'}',
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: TradieColors.navy),
                    ),
                    const Spacer(),
                    Text('Page $_page of $pages',
                        style: const TextStyle(
                            fontSize: 12, color: TradieColors.grey600)),
                  ]),
                ),

                Expanded(
                  child: ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: entries.length,
                    separatorBuilder: (_, __) =>
                        const SizedBox(height: 8),
                    itemBuilder: (_, i) {
                      final e = entries[i] as Map<String, dynamic>;
                      return _AuditEntryCard(entry: e);
                    },
                  ),
                ),

                // Pagination
                if (pages > 1)
                  Container(
                    color: TradieColors.white,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton(
                            icon: const Icon(Iconsax.arrow_left_2),
                            onPressed: _page > 1
                                ? () =>
                                    setState(() => _page--)
                                : null,
                            color: TradieColors.electricBlue,
                          ),
                          const SizedBox(width: 8),
                          Text('$_page / $pages',
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color: TradieColors.navy)),
                          const SizedBox(width: 8),
                          IconButton(
                            icon: const Icon(Iconsax.arrow_right_2),
                            onPressed: _page < pages
                                ? () =>
                                    setState(() => _page++)
                                : null,
                            color: TradieColors.electricBlue,
                          ),
                        ]),
                  ),
              ]);
            },
          ),
        ),
      ]),
    );
  }

  Future<void> _showFilterSheet(BuildContext context) async {
    String tmpAction = _actionFilter;
    String tmpEntity = _entityFilter;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Text('Filter Audit Log',
                      style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: TradieColors.navy)),
                  const Spacer(),
                  TextButton(
                    onPressed: () {
                      setSheet(() {
                        tmpAction = '';
                        tmpEntity = '';
                      });
                    },
                    child: const Text('Reset'),
                  ),
                ]),
                const SizedBox(height: 16),
                const Text('Action',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: TradieColors.grey600)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: _actionOptions.map((opt) {
                    final label = opt.isEmpty ? 'All' : opt;
                    final sel = tmpAction == opt;
                    return GestureDetector(
                      onTap: () => setSheet(() => tmpAction = opt),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 120),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: sel
                              ? TradieColors.electricBlue
                              : TradieColors.grey100,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                              color: sel
                                  ? TradieColors.electricBlue
                                  : TradieColors.grey200),
                        ),
                        child: Text(label,
                            style: TextStyle(
                                color: sel
                                    ? TradieColors.white
                                    : TradieColors.grey600,
                                fontSize: 12,
                                fontWeight: sel
                                    ? FontWeight.w600
                                    : FontWeight.w400)),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),
                const Text('Entity Type',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: TradieColors.grey600)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: _entityOptions.map((opt) {
                    final label = opt.isEmpty ? 'All' : opt;
                    final sel = tmpEntity == opt;
                    return GestureDetector(
                      onTap: () => setSheet(() => tmpEntity = opt),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 120),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: sel
                              ? TradieColors.electricBlue
                              : TradieColors.grey100,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                              color: sel
                                  ? TradieColors.electricBlue
                                  : TradieColors.grey200),
                        ),
                        child: Text(label,
                            style: TextStyle(
                                color: sel
                                    ? TradieColors.white
                                    : TradieColors.grey600,
                                fontSize: 12,
                                fontWeight: sel
                                    ? FontWeight.w600
                                    : FontWeight.w400)),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: FilledButton(
                    onPressed: () {
                      setState(() {
                        _actionFilter = tmpAction;
                        _entityFilter = tmpEntity;
                        _page = 1;
                      });
                      Navigator.pop(ctx);
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: TradieColors.electricBlue,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('Apply Filters',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                  ),
                ),
              ]),
        );
      }),
    );
  }
}

// ── Audit Entry Card ────────────────────────────────────────────────────────────

class _AuditEntryCard extends StatelessWidget {
  final Map<String, dynamic> entry;

  const _AuditEntryCard({required this.entry});

  static const _actionColors = {
    'create': TradieColors.successGreen,
    'update': TradieColors.electricBlue,
    'delete': TradieColors.alertRed,
    'revoke': TradieColors.alertRed,
    'login': TradieColors.navy,
    'logout': TradieColors.grey600,
    'mfa.enabled': TradieColors.successGreen,
    'mfa.disabled': TradieColors.alertRed,
    'session.revoked': TradieColors.safetyOrange,
  };

  static const _actionIcons = {
    'create': Iconsax.add_circle,
    'update': Iconsax.edit,
    'delete': Iconsax.trash,
    'revoke': Iconsax.close_circle,
    'login': Iconsax.login,
    'logout': Iconsax.logout,
    'mfa.enabled': Iconsax.shield_tick,
    'mfa.disabled': Iconsax.shield_cross,
    'session.revoked': Iconsax.monitor,
  };

  Color get _color =>
      _actionColors[entry['action'] as String? ?? ''] ??
      TradieColors.grey600;

  IconData get _icon =>
      _actionIcons[entry['action'] as String? ?? ''] ??
      Iconsax.activity;

  String _formatTime(String? raw) {
    if (raw == null || raw.isEmpty) return '';
    try {
      final dt = DateTime.parse(raw).toLocal();
      return '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year} '
          '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return raw;
    }
  }

  @override
  Widget build(BuildContext context) {
    final action = entry['action']?.toString() ?? '';
    final entityType = entry['entity_type']?.toString() ?? '';
    final userName = (entry['user_name']?.toString() ?? '').trim();
    final ipAddress = entry['ip_address']?.toString() ?? '';
    final createdAt =
        _formatTime(entry['created_at']?.toString());

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: TradieColors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: TradieColors.grey100),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: _color.withOpacity(0.1),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Icon(_icon, size: 18, color: _color),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Flexible(
                    child: Text(
                      _actionLabel(action),
                      style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                          color: TradieColors.navy),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (entityType.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: TradieColors.grey100,
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Text(
                        entityType.replaceAll('_', ' '),
                        style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w500,
                            color: TradieColors.grey600),
                      ),
                    ),
                ]),
                const SizedBox(height: 3),
                if (userName.isNotEmpty && userName != ' ')
                  Text(
                    'By $userName',
                    style: const TextStyle(
                        fontSize: 12, color: TradieColors.grey600),
                  ),
                Row(children: [
                  if (ipAddress.isNotEmpty) ...[
                    const Icon(Iconsax.location,
                        size: 11, color: TradieColors.grey400),
                    const SizedBox(width: 3),
                    Text(ipAddress,
                        style: const TextStyle(
                            fontSize: 11, color: TradieColors.grey400)),
                    const SizedBox(width: 8),
                  ],
                  const Icon(Iconsax.clock,
                      size: 11, color: TradieColors.grey400),
                  const SizedBox(width: 3),
                  Text(createdAt,
                      style: const TextStyle(
                          fontSize: 11, color: TradieColors.grey400)),
                ]),
              ]),
        ),
      ]),
    );
  }

  String _actionLabel(String action) {
    final map = {
      'create': 'Created',
      'update': 'Updated',
      'delete': 'Deleted',
      'revoke': 'Revoked',
      'login': 'Logged in',
      'logout': 'Logged out',
      'mfa.enabled': 'Enabled 2FA',
      'mfa.disabled': 'Disabled 2FA',
      'session.revoked': 'Session revoked',
    };
    return map[action] ?? action.replaceAll('_', ' ').replaceAll('.', ' ');
  }
}

// ── Filter Chip Widget ─────────────────────────────────────────────────────────

class _FilterChip extends StatelessWidget {
  final String label;
  final VoidCallback onRemove;

  const _FilterChip({required this.label, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: TradieColors.electricBlue.withOpacity(0.1),
        borderRadius: BorderRadius.circular(14),
        border:
            Border.all(color: TradieColors.electricBlue.withOpacity(0.3)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text(label,
            style: const TextStyle(
                fontSize: 12,
                color: TradieColors.electricBlue,
                fontWeight: FontWeight.w500)),
        const SizedBox(width: 4),
        GestureDetector(
          onTap: onRemove,
          child: const Icon(Iconsax.close_circle,
              size: 14, color: TradieColors.electricBlue),
        ),
      ]),
    );
  }
}
