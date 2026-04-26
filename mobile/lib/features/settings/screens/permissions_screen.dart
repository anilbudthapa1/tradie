import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';

import '../../../core/api/api_client.dart';
import '../../../core/utils/theme.dart';
import '../../../core/widgets/tradie_button.dart';

/// Owner-only screen to view and edit role -> permission mappings.
/// GET  /api/v1/permissions/all
/// PUT  /api/v1/permissions/role/{role}
class PermissionsScreen extends ConsumerStatefulWidget {
  const PermissionsScreen({super.key});

  @override
  ConsumerState<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends ConsumerState<PermissionsScreen> {
  static const _editableRoles = ['admin', 'manager', 'worker', 'accountant', 'customer'];

  bool _loading = true;
  bool _saving = false;
  String? _error;
  String _selectedRole = 'manager';

  // catalog: list of {key, description, category}
  List<Map<String, dynamic>> _catalog = [];
  // role -> set of granted keys
  final Map<String, Set<String>> _roleMap = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final api = ref.read(apiClientProvider);
      final resp = await api.get('/permissions/all');
      final data = resp.data as Map<String, dynamic>;
      _catalog = ((data['permissions'] as List?) ?? const [])
          .map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      final raw = (data['role_map'] as Map?) ?? {};
      _roleMap.clear();
      raw.forEach((k, v) {
        _roleMap[k.toString()] =
            ((v as List?) ?? const []).map((x) => x.toString()).toSet();
      });
      setState(() { _loading = false; });
    } catch (_) {
      setState(() {
        _error = 'Could not load permissions.';
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    setState(() { _saving = true; _error = null; });
    try {
      final api = ref.read(apiClientProvider);
      final keys = (_roleMap[_selectedRole] ?? <String>{}).toList();
      await api.put('/permissions/role/$_selectedRole',
          data: {'permission_keys': keys});
      if (!mounted) return;
      setState(() { _saving = false; });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Permissions saved')),
      );
    } catch (_) {
      setState(() {
        _error = 'Save failed';
        _saving = false;
      });
    }
  }

  void _toggle(String key, bool value) {
    setState(() {
      final set = _roleMap.putIfAbsent(_selectedRole, () => <String>{});
      if (value) {
        set.add(key);
      } else {
        set.remove(key);
      }
    });
  }

  Map<String, List<Map<String, dynamic>>> get _grouped {
    final groups = <String, List<Map<String, dynamic>>>{};
    for (final p in _catalog) {
      final cat = (p['category'] ?? 'misc').toString();
      groups.putIfAbsent(cat, () => []).add(p);
    }
    return groups;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TradieColors.grey50,
      appBar: AppBar(
        title: const Text('Permissions'),
        backgroundColor: TradieColors.white,
        elevation: 0,
        foregroundColor: TradieColors.charcoal,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (_error != null) ...[
                    _errorBanner(_error!),
                    const SizedBox(height: 12),
                  ],
                  _roleSelector(),
                  const SizedBox(height: 16),
                  ..._grouped.entries.map(_categorySection),
                  const SizedBox(height: 24),
                  TradieButton(
                    label: 'Save changes',
                    loading: _saving,
                    onPressed: _save,
                  ),
                  const SizedBox(height: 32),
                ],
              ),
            ),
    );
  }

  Widget _roleSelector() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: TradieColors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: TradieColors.grey200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: const [
            Icon(Iconsax.profile_2user,
                size: 18, color: TradieColors.electricBlue),
            SizedBox(width: 8),
            Text('Role',
                style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: TradieColors.charcoal)),
          ]),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _editableRoles.map((role) {
              final selected = role == _selectedRole;
              return GestureDetector(
                onTap: () => setState(() => _selectedRole = role),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: selected
                        ? TradieColors.electricBlue
                        : TradieColors.grey50,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                        color: selected
                            ? TradieColors.electricBlue
                            : TradieColors.grey200),
                  ),
                  child: Text(
                    role,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      color: selected
                          ? TradieColors.white
                          : TradieColors.charcoal,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _categorySection(MapEntry<String, List<Map<String, dynamic>>> entry) {
    final category = entry.key;
    final perms = entry.value;
    final granted = _roleMap[_selectedRole] ?? <String>{};
    return Container(
      margin: const EdgeInsets.only(top: 12),
      decoration: BoxDecoration(
        color: TradieColors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: TradieColors.grey200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Text(
              category.toUpperCase(),
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
                color: TradieColors.grey600,
              ),
            ),
          ),
          ...perms.map((p) {
            final key = p['key'].toString();
            final desc = (p['description'] ?? '').toString();
            return SwitchListTile(
              dense: true,
              value: granted.contains(key),
              onChanged: (v) => _toggle(key, v),
              activeColor: TradieColors.electricBlue,
              title: Text(key,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      color: TradieColors.charcoal,
                      fontSize: 14)),
              subtitle: desc.isEmpty
                  ? null
                  : Text(desc,
                      style: const TextStyle(
                          color: TradieColors.grey600, fontSize: 12)),
            );
          }),
        ],
      ),
    );
  }

  Widget _errorBanner(String msg) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: TradieColors.alertRed.withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: TradieColors.alertRed.withOpacity(0.3)),
      ),
      child: Row(children: [
        const Icon(Iconsax.warning_2,
            color: TradieColors.alertRed, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Text(msg,
              style: const TextStyle(
                  color: TradieColors.alertRed, fontSize: 14)),
        ),
      ]),
    );
  }
}
