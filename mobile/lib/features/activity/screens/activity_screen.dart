import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';

import '../../../core/providers/auth_provider.dart';
import '../../../core/utils/theme.dart';
import '../../dashboard/providers/activity_provider.dart' as audit_feed;
import '../providers/activity_entries_provider.dart';

/// Module 14 — Activity Feed.
///
/// Two tabs:
///   * Timeline — read-only audit-derived feed (everyone with activity.view)
///   * Entries  — tenant-authored announcements / milestones / notes
///                (managers+ can author; workers read only)
class ActivityScreen extends ConsumerStatefulWidget {
  const ActivityScreen({super.key});

  @override
  ConsumerState<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends ConsumerState<ActivityScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authNotifierProvider);
    final role = (auth.asData?.value?['role']?.toString() ?? 'worker').toLowerCase();
    final canManage = const {'owner', 'admin', 'manager'}.contains(role);

    return Scaffold(
      backgroundColor: TradieColors.white,
      appBar: AppBar(
        backgroundColor: TradieColors.white,
        elevation: 0,
        title: const Text('Activity'),
        bottom: TabBar(
          controller: _tabs,
          labelColor: TradieColors.electricBlue,
          unselectedLabelColor: TradieColors.grey600,
          indicatorColor: TradieColors.electricBlue,
          tabs: const [
            Tab(text: 'Timeline'),
            Tab(text: 'Entries'),
          ],
        ),
      ),
      floatingActionButton: canManage && _tabs.index == 1
          ? FloatingActionButton.extended(
              onPressed: () => _openCreateSheet(context),
              backgroundColor: TradieColors.electricBlue,
              foregroundColor: TradieColors.white,
              icon: const Icon(Iconsax.add),
              label: const Text('New entry'),
            )
          : null,
      body: TabBarView(
        controller: _tabs,
        children: [
          const _TimelineTab(),
          _EntriesTab(canManage: canManage),
        ],
      ),
    );
  }

  Future<void> _openCreateSheet(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: TradieColors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => const _CreateEntrySheet(),
    );
  }
}

// ── Timeline tab ────────────────────────────────────────────────

class _TimelineTab extends ConsumerWidget {
  const _TimelineTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(audit_feed.activityFeedProvider(const audit_feed.ActivityFilter(limit: 100)));

    return RefreshIndicator(
      color: TradieColors.electricBlue,
      onRefresh: () async => ref.invalidate(audit_feed.activityFeedProvider),
      child: async.when(
        loading: () => const Center(child: CircularProgressIndicator(color: TradieColors.electricBlue)),
        error: (e, _) => _ErrorView(message: e.toString(), onRetry: () => ref.invalidate(audit_feed.activityFeedProvider)),
        data: (items) {
          if (items.isEmpty) {
            return const _EmptyView(icon: Iconsax.activity, message: 'Nothing has happened yet.');
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
            physics: const AlwaysScrollableScrollPhysics(),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (_, i) {
              final it = items[i];
              return _AuditRow(
                userName: it.userName,
                action: it.action,
                entityType: it.entityType,
                category: it.category,
                createdAt: it.createdAt,
              );
            },
          );
        },
      ),
    );
  }
}

class _AuditRow extends StatelessWidget {
  final String userName;
  final String action;
  final String? entityType;
  final String category;
  final DateTime createdAt;

  const _AuditRow({
    required this.userName,
    required this.action,
    this.entityType,
    required this.category,
    required this.createdAt,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: TradieColors.white,
        border: Border.all(color: TradieColors.grey200),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Container(
            width: 32, height: 32,
            decoration: BoxDecoration(
              color: TradieColors.electricBlue.withOpacity(0.10),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(_iconFor(category), size: 16, color: TradieColors.electricBlue),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                RichText(
                  text: TextSpan(
                    style: const TextStyle(fontSize: 13, color: TradieColors.charcoal),
                    children: [
                      TextSpan(
                        text: userName,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const TextSpan(text: '  '),
                      TextSpan(
                        text: action,
                        style: const TextStyle(color: TradieColors.grey600),
                      ),
                      if (entityType != null) ...[
                        const TextSpan(text: '  ·  '),
                        TextSpan(
                          text: entityType!,
                          style: const TextStyle(color: TradieColors.grey600),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _relative(createdAt),
                  style: const TextStyle(fontSize: 11, color: TradieColors.grey400),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  IconData _iconFor(String c) => switch (c) {
        'job' => Iconsax.briefcase,
        'invoice' => Iconsax.receipt,
        'quote' => Iconsax.document_text,
        'customer' => Iconsax.user,
        'worker' => Iconsax.people,
        'payment' => Iconsax.dollar_circle,
        'auth' => Iconsax.lock,
        'task' => Iconsax.task_square,
        'lead' => Iconsax.call,
        'expense' => Iconsax.wallet,
        'safety' => Iconsax.health,
        _ => Iconsax.activity,
      };

  String _relative(DateTime dt) {
    final d = DateTime.now().difference(dt);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    if (d.inDays < 7) return '${d.inDays}d ago';
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }
}

// ── Entries tab ─────────────────────────────────────────────────

class _EntriesTab extends ConsumerStatefulWidget {
  final bool canManage;
  const _EntriesTab({required this.canManage});

  @override
  ConsumerState<_EntriesTab> createState() => _EntriesTabState();
}

class _EntriesTabState extends ConsumerState<_EntriesTab> {
  String _filter = 'active';

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(activityEntriesProvider(_filter == 'all' ? '' : _filter));

    return Column(
      children: [
        if (widget.canManage)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Row(
              children: [
                const Icon(Iconsax.filter, size: 16, color: TradieColors.grey600),
                const SizedBox(width: 6),
                DropdownButton<String>(
                  value: _filter,
                  underline: const SizedBox.shrink(),
                  items: const [
                    DropdownMenuItem(value: 'active', child: Text('Active')),
                    DropdownMenuItem(value: 'archived', child: Text('Archived')),
                    DropdownMenuItem(value: 'all', child: Text('All')),
                  ],
                  onChanged: (v) => setState(() => _filter = v ?? 'active'),
                ),
              ],
            ),
          ),
        Expanded(
          child: RefreshIndicator(
            color: TradieColors.electricBlue,
            onRefresh: () async => ref.invalidate(activityEntriesProvider),
            child: async.when(
              loading: () => const Center(child: CircularProgressIndicator(color: TradieColors.electricBlue)),
              error: (e, _) => _ErrorView(message: e.toString(), onRetry: () => ref.invalidate(activityEntriesProvider)),
              data: (list) {
                if (list.isEmpty) {
                  return _EmptyView(
                    icon: Iconsax.note,
                    message: widget.canManage
                        ? 'No entries yet. Tap "New entry" to post an announcement.'
                        : 'No announcements yet.',
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 96),
                  physics: const AlwaysScrollableScrollPhysics(),
                  itemCount: list.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (_, i) {
                    final e = list[i] as Map<String, dynamic>;
                    return _EntryCard(
                      entry: e,
                      canManage: widget.canManage,
                      onPin: () => _runMutation(
                        () => ref.read(activityEntryNotifierProvider.notifier).pin(e['id'] as String, !(e['pinned'] == true)),
                        success: (e['pinned'] == true) ? 'Unpinned' : 'Pinned',
                      ),
                      onArchive: () => _runMutation(
                        () => ref.read(activityEntryNotifierProvider.notifier).archive(e['id'] as String),
                        success: 'Archived',
                      ),
                      onRestore: () => _runMutation(
                        () => ref.read(activityEntryNotifierProvider.notifier).restore(e['id'] as String),
                        success: 'Restored',
                      ),
                      onDelete: () => _confirmDelete(context, e['id'] as String),
                    );
                  },
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _runMutation(Future<bool> Function() op, {required String success}) async {
    final ok = await op();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ok ? success : 'Action failed')));
  }

  Future<void> _confirmDelete(BuildContext context, String id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TradieColors.white,
        title: const Text('Delete entry?'),
        content: const Text('This action cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: TradieColors.alertRed),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final ok = await ref.read(activityEntryNotifierProvider.notifier).delete(id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ok ? 'Deleted' : 'Delete failed')));
  }
}

class _EntryCard extends StatelessWidget {
  final Map<String, dynamic> entry;
  final bool canManage;
  final VoidCallback onPin;
  final VoidCallback onArchive;
  final VoidCallback onRestore;
  final VoidCallback onDelete;

  const _EntryCard({
    required this.entry,
    required this.canManage,
    required this.onPin,
    required this.onArchive,
    required this.onRestore,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final category = entry['category']?.toString() ?? 'announcement';
    final status = entry['status']?.toString() ?? 'active';
    final pinned = entry['pinned'] == true;
    final tone = switch (category) {
      'alert' => TradieColors.alertRed,
      'milestone' => TradieColors.successGreen,
      'note' => TradieColors.grey600,
      _ => TradieColors.electricBlue,
    };

    return Container(
      decoration: BoxDecoration(
        color: TradieColors.white,
        border: Border.all(color: pinned ? tone.withOpacity(0.30) : TradieColors.grey200),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: tone.withOpacity(0.10),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    category.toUpperCase(),
                    style: TextStyle(color: tone, fontSize: 11, fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: TradieColors.grey50,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(status,
                      style: const TextStyle(color: TradieColors.grey600, fontSize: 11, fontWeight: FontWeight.w500)),
                ),
                const Spacer(),
                if (pinned)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: TradieColors.electricBlue.withOpacity(0.10),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text(
                      'PINNED',
                      style: TextStyle(
                        fontSize: 9, fontWeight: FontWeight.w700,
                        color: TradieColors.electricBlue, letterSpacing: 0.5),
                    ),
                  ),
                if (canManage)
                  PopupMenuButton<String>(
                    icon: const Icon(Iconsax.more, size: 18, color: TradieColors.grey400),
                    onSelected: (v) {
                      if (v == 'pin') onPin();
                      if (v == 'archive') onArchive();
                      if (v == 'restore') onRestore();
                      if (v == 'delete') onDelete();
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(value: 'pin', child: Text(pinned ? 'Unpin' : 'Pin')),
                      if (status == 'active') const PopupMenuItem(value: 'archive', child: Text('Archive')),
                      if (status == 'archived') const PopupMenuItem(value: 'restore', child: Text('Restore')),
                      const PopupMenuItem(value: 'delete', child: Text('Delete')),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              entry['title']?.toString() ?? '',
              style: const TextStyle(
                color: TradieColors.charcoal,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            if ((entry['body'] ?? '').toString().isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                entry['body'].toString(),
                style: const TextStyle(color: TradieColors.grey600, fontSize: 13),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Create sheet ────────────────────────────────────────────────

class _CreateEntrySheet extends ConsumerStatefulWidget {
  const _CreateEntrySheet();

  @override
  ConsumerState<_CreateEntrySheet> createState() => _CreateEntrySheetState();
}

class _CreateEntrySheetState extends ConsumerState<_CreateEntrySheet> {
  final _title = TextEditingController();
  final _body = TextEditingController();
  String _category = 'announcement';
  String _visibility = 'tenant';
  bool _pinned = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets;

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, viewInsets.bottom + 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 36, height: 4,
              decoration: BoxDecoration(color: TradieColors.grey200, borderRadius: BorderRadius.circular(2)),
            ),
          ),
          const SizedBox(height: 16),
          const Text('New activity entry', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          const SizedBox(height: 16),
          TextField(
            controller: _title,
            decoration: const InputDecoration(labelText: 'Title', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _body,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'Body', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                value: _category,
                decoration: const InputDecoration(labelText: 'Category', border: OutlineInputBorder()),
                items: const [
                  DropdownMenuItem(value: 'announcement', child: Text('Announcement')),
                  DropdownMenuItem(value: 'milestone', child: Text('Milestone')),
                  DropdownMenuItem(value: 'alert', child: Text('Alert')),
                  DropdownMenuItem(value: 'note', child: Text('Note')),
                ],
                onChanged: (v) => setState(() => _category = v ?? 'announcement'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButtonFormField<String>(
                value: _visibility,
                decoration: const InputDecoration(labelText: 'Visibility', border: OutlineInputBorder()),
                items: const [
                  DropdownMenuItem(value: 'tenant', child: Text('Everyone')),
                  DropdownMenuItem(value: 'managers', child: Text('Managers')),
                ],
                onChanged: (v) => setState(() => _visibility = v ?? 'tenant'),
              ),
            ),
          ]),
          const SizedBox(height: 8),
          SwitchListTile.adaptive(
            value: _pinned,
            onChanged: (v) => setState(() => _pinned = v),
            title: const Text('Pin to top'),
            contentPadding: EdgeInsets.zero,
            activeColor: TradieColors.electricBlue,
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: const TextStyle(color: TradieColors.alertRed)),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _submit,
            style: FilledButton.styleFrom(
              backgroundColor: TradieColors.electricBlue,
              minimumSize: const Size.fromHeight(48),
            ),
            child: _busy
                ? const SizedBox(
                    width: 20, height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('Post'),
          ),
        ],
      ),
    );
  }

  Future<void> _submit() async {
    if (_title.text.trim().isEmpty) {
      setState(() => _error = 'Title is required');
      return;
    }
    setState(() { _busy = true; _error = null; });
    final err = await ref.read(activityEntryNotifierProvider.notifier).create({
      'title': _title.text.trim(),
      'body': _body.text.trim(),
      'category': _category,
      'visibility': _visibility,
      'pinned': _pinned,
    });
    if (!mounted) return;
    if (err != null) {
      setState(() { _busy = false; _error = err; });
      return;
    }
    Navigator.of(context).pop();
  }
}

// ── Empty / Error views ─────────────────────────────────────────

class _EmptyView extends StatelessWidget {
  final IconData icon;
  final String message;
  const _EmptyView({required this.icon, required this.message});

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 120),
        Icon(icon, size: 56, color: TradieColors.grey400),
        const SizedBox(height: 16),
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: TradieColors.grey600),
            ),
          ),
        ),
      ],
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 120),
        const Icon(Iconsax.warning_2, size: 56, color: TradieColors.alertRed),
        const SizedBox(height: 16),
        const Center(
          child: Text(
            'Could not load activity',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(height: 6),
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(message, textAlign: TextAlign.center, style: const TextStyle(color: TradieColors.grey600)),
          ),
        ),
        const SizedBox(height: 16),
        Center(child: OutlinedButton(onPressed: onRetry, child: const Text('Retry'))),
      ],
    );
  }
}
