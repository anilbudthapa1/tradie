import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';

import '../../../core/providers/auth_provider.dart';
import '../../../core/utils/theme.dart';
import '../providers/localization_provider.dart';

class LocalizationScreen extends ConsumerStatefulWidget {
  const LocalizationScreen({super.key});

  @override
  ConsumerState<LocalizationScreen> createState() => _LocalizationScreenState();
}

class _LocalizationScreenState extends ConsumerState<LocalizationScreen> {
  final _search = TextEditingController();
  String _status = 'all';
  String _language = '';
  String _templateType = '';
  bool _selfView = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authNotifierProvider);
    final role =
        (auth.asData?.value?['role']?.toString() ?? 'worker').toLowerCase();
    final canManage = const {'owner', 'admin'}.contains(role);
    final filter = LocalizationFilter(
      status: _status,
      language: _language,
      templateType: _templateType,
      query: _search.text,
    );
    final async = _selfView || !canManage
        ? ref.watch(myLocalizationEntriesProvider(_language))
        : ref.watch(localizationEntriesProvider(filter));

    return Scaffold(
      backgroundColor: TradieColors.white,
      appBar: AppBar(
        title: const Text('Languages'),
        backgroundColor: TradieColors.white,
        elevation: 0,
        actions: [
          if (canManage)
            IconButton(
              icon: Icon(_selfView ? Iconsax.edit_2 : Iconsax.document_text),
              tooltip: _selfView ? 'Manage entries' : 'Active translations',
              onPressed: () => setState(() => _selfView = !_selfView),
            ),
          PopupMenuButton<String>(
            icon: const Icon(Iconsax.filter, color: TradieColors.charcoal),
            onSelected: (value) => setState(() => _language = value),
            itemBuilder: (_) => const [
              PopupMenuItem(value: '', child: Text('All languages')),
              PopupMenuItem(value: 'en-AU', child: Text('English AU')),
              PopupMenuItem(value: 'en', child: Text('English')),
              PopupMenuItem(value: 'zh', child: Text('Chinese')),
              PopupMenuItem(value: 'vi', child: Text('Vietnamese')),
              PopupMenuItem(value: 'ar', child: Text('Arabic')),
            ],
          ),
        ],
      ),
      floatingActionButton: canManage && !_selfView
          ? FloatingActionButton.extended(
              onPressed: () => _openEditor(),
              backgroundColor: TradieColors.electricBlue,
              foregroundColor: TradieColors.white,
              icon: const Icon(Iconsax.add),
              label: const Text('New translation'),
            )
          : null,
      body: RefreshIndicator(
        color: TradieColors.electricBlue,
        onRefresh: () async {
          ref.invalidate(localizationEntriesProvider);
          ref.invalidate(myLocalizationEntriesProvider);
        },
        child: async.when(
          loading: () => const Center(
            child: CircularProgressIndicator(color: TradieColors.electricBlue),
          ),
          error: (error, _) => _MessageView(
            icon: Iconsax.warning_2,
            title: 'Could not load languages',
            subtitle: error.toString(),
            color: TradieColors.alertRed,
          ),
          data: (items) {
            final entries =
                items.whereType<LocalizationEntry>().toList(growable: false);
            final activeItems =
                items.whereType<Map<String, dynamic>>().toList(growable: false);

            if (!_selfView && canManage) {
              return _ManagementList(
                entries: entries,
                search: _search,
                status: _status,
                language: _language,
                templateType: _templateType,
                onSearch: () => setState(() {}),
                onStatus: (v) => setState(() => _status = v),
                onTemplateType: (v) => setState(() => _templateType = v),
                onEdit: _openEditor,
                onDelete: _confirmDelete,
              );
            }

            if (activeItems.isEmpty) {
              return const _MessageView(
                icon: Iconsax.document_text,
                title: 'No active translations',
                subtitle: 'Published localization entries will appear here.',
              );
            }
            return ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 96),
              itemCount: activeItems.length,
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (_, index) => _ActiveTile(item: activeItems[index]),
            );
          },
        ),
      ),
    );
  }

  Future<void> _openEditor([LocalizationEntry? entry]) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: TradieColors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => _LocalizationEditor(entry: entry),
    );
  }

  Future<void> _confirmDelete(LocalizationEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TradieColors.white,
        title: const Text('Delete translation?'),
        content: Text(
            '${entry.namespace}.${entry.translationKey} will be soft deleted.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: TradieColors.alertRed),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final ok =
        await ref.read(localizationNotifierProvider.notifier).delete(entry.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? 'Translation deleted' : 'Delete failed')),
    );
  }
}

class _ManagementList extends StatelessWidget {
  final List<LocalizationEntry> entries;
  final TextEditingController search;
  final String status;
  final String language;
  final String templateType;
  final VoidCallback onSearch;
  final ValueChanged<String> onStatus;
  final ValueChanged<String> onTemplateType;
  final ValueChanged<LocalizationEntry> onEdit;
  final ValueChanged<LocalizationEntry> onDelete;

  const _ManagementList({
    required this.entries,
    required this.search,
    required this.status,
    required this.language,
    required this.templateType,
    required this.onSearch,
    required this.onStatus,
    required this.onTemplateType,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 96),
      children: [
        TextField(
          controller: search,
          onSubmitted: (_) => onSearch(),
          decoration: InputDecoration(
            hintText: 'Search namespace, key, or value',
            prefixIcon: const Icon(Iconsax.search_normal, size: 18),
            suffixIcon: IconButton(
              icon: const Icon(Iconsax.refresh, size: 18),
              onPressed: onSearch,
            ),
            filled: true,
            fillColor: TradieColors.grey50,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _Choice(
              value: status,
              values: const ['all', 'draft', 'active', 'archived'],
              onChanged: onStatus,
            ),
            _Choice(
              value: templateType.isEmpty ? 'all types' : templateType,
              values: const [
                'all types',
                'ui',
                'email',
                'sms',
                'push',
                'document',
                'customer_portal',
              ],
              onChanged: (v) => onTemplateType(v == 'all types' ? '' : v),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (entries.isEmpty)
          const _MessageView(
            icon: Iconsax.document_text,
            title: 'No translations yet',
            subtitle: 'Create the first tenant-scoped localization entry.',
          )
        else
          for (final entry in entries) ...[
            _EntryTile(entry: entry, onEdit: onEdit, onDelete: onDelete),
            const SizedBox(height: 12),
          ],
      ],
    );
  }
}

class _EntryTile extends StatelessWidget {
  final LocalizationEntry entry;
  final ValueChanged<LocalizationEntry> onEdit;
  final ValueChanged<LocalizationEntry> onDelete;

  const _EntryTile({
    required this.entry,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final tone = entry.status == 'active'
        ? TradieColors.successGreen
        : entry.status == 'archived'
            ? TradieColors.grey400
            : TradieColors.electricBlue;
    return Container(
      decoration: BoxDecoration(
        color: TradieColors.white,
        border: Border.all(color: TradieColors.grey200),
        borderRadius: BorderRadius.circular(14),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: tone.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Iconsax.document_text, size: 18, color: tone),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${entry.namespace}.${entry.translationKey}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: TradieColors.charcoal,
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),
                    Text(
                      '${entry.language} · ${entry.templateType} · ${entry.status}',
                      style: const TextStyle(
                        color: TradieColors.grey600,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                icon: const Icon(Iconsax.more, color: TradieColors.grey400),
                onSelected: (value) {
                  if (value == 'edit') onEdit(entry);
                  if (value == 'delete') onDelete(entry);
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('Edit')),
                  PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            entry.value,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: TradieColors.grey600, fontSize: 14),
          ),
        ],
      ),
    );
  }
}

class _ActiveTile extends StatelessWidget {
  final Map<String, dynamic> item;

  const _ActiveTile({required this.item});

  @override
  Widget build(BuildContext context) {
    final ns = item['namespace']?.toString() ?? 'common';
    final key = item['translation_key']?.toString() ?? '';
    return Container(
      decoration: BoxDecoration(
        color: TradieColors.white,
        border: Border.all(color: TradieColors.grey200),
        borderRadius: BorderRadius.circular(14),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$ns.$key',
            style: const TextStyle(
              color: TradieColors.charcoal,
              fontWeight: FontWeight.w600,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${item['language']} · ${item['template_type']}',
            style: const TextStyle(color: TradieColors.grey600, fontSize: 12),
          ),
          const SizedBox(height: 10),
          Text(
            item['value']?.toString() ?? '',
            style: const TextStyle(color: TradieColors.grey600, fontSize: 14),
          ),
        ],
      ),
    );
  }
}

class _LocalizationEditor extends ConsumerStatefulWidget {
  final LocalizationEntry? entry;

  const _LocalizationEditor({this.entry});

  @override
  ConsumerState<_LocalizationEditor> createState() =>
      _LocalizationEditorState();
}

class _LocalizationEditorState extends ConsumerState<_LocalizationEditor> {
  late final TextEditingController _namespace;
  late final TextEditingController _key;
  late final TextEditingController _value;
  String _language = 'en-AU';
  String _templateType = 'ui';
  String _status = 'draft';
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final entry = widget.entry;
    _namespace = TextEditingController(text: entry?.namespace ?? 'common');
    _key = TextEditingController(text: entry?.translationKey ?? '');
    _value = TextEditingController(text: entry?.value ?? '');
    _language = entry?.language ?? 'en-AU';
    _templateType = entry?.templateType ?? 'ui';
    _status = entry?.status ?? 'draft';
  }

  @override
  void dispose() {
    _namespace.dispose();
    _key.dispose();
    _value.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, bottom + 20),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Iconsax.document_text,
                    color: TradieColors.electricBlue),
                const SizedBox(width: 10),
                Text(
                  widget.entry == null ? 'New translation' : 'Edit translation',
                  style: const TextStyle(
                    color: TradieColors.charcoal,
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Iconsax.close_circle),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _namespace,
              decoration: _decoration('Namespace', Iconsax.folder),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _key,
              decoration: _decoration('Translation key', Iconsax.key),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _Dropdown(
                    label: 'Language',
                    value: _language,
                    values: const ['en-AU', 'en', 'zh', 'vi', 'ar'],
                    onChanged: (v) => setState(() => _language = v),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _Dropdown(
                    label: 'Status',
                    value: _status,
                    values: const ['draft', 'active', 'archived'],
                    onChanged: (v) => setState(() => _status = v),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _Dropdown(
              label: 'Template type',
              value: _templateType,
              values: const [
                'ui',
                'email',
                'sms',
                'push',
                'document',
                'customer_portal'
              ],
              onChanged: (v) => setState(() => _templateType = v),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _value,
              minLines: 4,
              maxLines: 8,
              decoration:
                  _decoration('Translated value', Iconsax.document_text),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!,
                  style: const TextStyle(color: TradieColors.alertRed)),
            ],
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Iconsax.tick_circle),
                label: Text(widget.entry == null ? 'Create' : 'Save'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    if (_key.text.trim().isEmpty || _value.text.trim().isEmpty) {
      setState(() => _error = 'Translation key and value are required.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final data = {
      'namespace':
          _namespace.text.trim().isEmpty ? 'common' : _namespace.text.trim(),
      'translation_key': _key.text.trim(),
      'language': _language,
      'value': _value.text.trim(),
      'template_type': _templateType,
      'status': _status,
    };
    final notifier = ref.read(localizationNotifierProvider.notifier);
    final error = widget.entry == null
        ? await notifier.create(data)
        : await notifier.update(widget.entry!.id, data);
    if (!mounted) return;
    setState(() => _saving = false);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(widget.entry == null
              ? 'Translation created'
              : 'Translation saved')),
    );
  }

  InputDecoration _decoration(String label, IconData icon) {
    return InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon, size: 18),
      filled: true,
      fillColor: TradieColors.grey50,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
    );
  }
}

class _Dropdown extends StatelessWidget {
  final String label;
  final String value;
  final List<String> values;
  final ValueChanged<String> onChanged;

  const _Dropdown({
    required this.label,
    required this.value,
    required this.values,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      initialValue: value,
      decoration: InputDecoration(
        labelText: label,
        filled: true,
        fillColor: TradieColors.grey50,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
      items: values
          .map((v) => DropdownMenuItem<String>(value: v, child: Text(v)))
          .toList(),
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
    );
  }
}

class _Choice extends StatelessWidget {
  final String value;
  final List<String> values;
  final ValueChanged<String> onChanged;

  const _Choice({
    required this.value,
    required this.values,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      onSelected: onChanged,
      itemBuilder: (_) => [
        for (final item in values)
          PopupMenuItem(value: item, child: Text(item)),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: TradieColors.grey50,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: TradieColors.grey200),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(value, style: const TextStyle(color: TradieColors.grey600)),
            const SizedBox(width: 6),
            const Icon(Iconsax.arrow_down_1,
                size: 14, color: TradieColors.grey600),
          ],
        ),
      ),
    );
  }
}

class _MessageView extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;

  const _MessageView({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.color = TradieColors.grey400,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(24, 120, 24, 24),
      children: [
        Icon(icon, size: 52, color: color),
        const SizedBox(height: 16),
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: TradieColors.charcoal,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          style: const TextStyle(color: TradieColors.grey600, fontSize: 14),
        ),
      ],
    );
  }
}
