import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';
import '../providers/workers_provider.dart';

const _navy = Color(0xFF1A2332);
const _blue = Color(0xFF2563EB);
const _green = Color(0xFF16A34A);

class WorkersListScreen extends ConsumerStatefulWidget {
  const WorkersListScreen({super.key});

  @override
  ConsumerState<WorkersListScreen> createState() => _WorkersListScreenState();
}

class _WorkersListScreenState extends ConsumerState<WorkersListScreen> {
  final _searchCtrl = TextEditingController();
  String _search = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Color _roleColor(String role) {
    switch (role) {
      case 'manager': return _blue;
      case 'accountant': return _green;
      case 'owner': return const Color(0xFF7C3AED);
      default: return _navy;
    }
  }

  @override
  Widget build(BuildContext context) {
    final workersAsync = ref.watch(workersProvider);

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        backgroundColor: _navy,
        foregroundColor: Colors.white,
        title: const Row(children: [
          Icon(Iconsax.people, size: 22),
          SizedBox(width: 10),
          Text('Team', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20)),
        ]),
        actions: [
          IconButton(
            icon: const Icon(Iconsax.filter),
            onPressed: () {},
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                hintText: 'Search team members...',
                prefixIcon: const Icon(Iconsax.search_normal, size: 20),
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
              ),
              onChanged: (v) => setState(() => _search = v.toLowerCase()),
            ),
          ),
          Expanded(
            child: workersAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Iconsax.warning_2, size: 40, color: Colors.red),
                  const SizedBox(height: 8),
                  Text('Failed to load team', style: TextStyle(color: Colors.grey[600])),
                  TextButton(
                    onPressed: () => ref.refresh(workersProvider),
                    child: const Text('Retry'),
                  ),
                ]),
              ),
              data: (workers) {
                final filtered = workers.where((w) {
                  if (_search.isEmpty) return true;
                  final name = '${w['first_name']} ${w['last_name']}'.toLowerCase();
                  final email = (w['email'] ?? '').toString().toLowerCase();
                  return name.contains(_search) || email.contains(_search);
                }).toList();

                if (filtered.isEmpty) {
                  return Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Iconsax.people, size: 60, color: Colors.grey[300]),
                      const SizedBox(height: 12),
                      Text(
                        _search.isEmpty ? 'No team members yet' : 'No results for "$_search"',
                        style: TextStyle(color: Colors.grey[500], fontSize: 16),
                      ),
                    ]),
                  );
                }

                return RefreshIndicator(
                  onRefresh: () async => ref.refresh(workersProvider),
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
                    itemCount: filtered.length,
                    itemBuilder: (ctx, i) {
                      final w = filtered[i];
                      final name = '${w['first_name']} ${w['last_name']}';
                      final role = (w['role'] ?? 'worker').toString();
                      final isActive = w['is_active'] == true;
                      final initials = '${(w['first_name'] ?? '?').toString().characters.first}'
                          '${(w['last_name'] ?? '?').toString().characters.firstOrNull ?? ''}';

                      return GestureDetector(
                        onTap: () => context.push('/workers/${w['id']}'),
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.04),
                                blurRadius: 8,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            leading: CircleAvatar(
                              backgroundColor: _roleColor(role).withOpacity(0.12),
                              radius: 24,
                              child: Text(
                                initials.toUpperCase(),
                                style: TextStyle(
                                  color: _roleColor(role),
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                            title: Row(children: [
                              Text(name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: _roleColor(role).withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Text(
                                  role,
                                  style: TextStyle(
                                    color: _roleColor(role),
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ]),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const SizedBox(height: 2),
                                Text(w['email'] ?? '', style: TextStyle(color: Colors.grey[600], fontSize: 13)),
                                if (w['phone'] != null)
                                  Text(w['phone'].toString(), style: TextStyle(color: Colors.grey[500], fontSize: 12)),
                              ],
                            ),
                            trailing: Column(mainAxisSize: MainAxisSize.min, children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: isActive ? _green : Colors.grey[400],
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                isActive ? 'Active' : 'Inactive',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: isActive ? _green : Colors.grey[400],
                                ),
                              ),
                            ]),
                          ),
                        ),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddWorkerSheet(context),
        backgroundColor: _blue,
        foregroundColor: Colors.white,
        icon: const Icon(Iconsax.add_circle),
        label: const Text('Add Member', style: TextStyle(fontWeight: FontWeight.w600)),
      ),
    );
  }

  void _showAddWorkerSheet(BuildContext context) {
    final firstCtrl = TextEditingController();
    final lastCtrl = TextEditingController();
    final emailCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    String role = 'worker';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(ctx).viewInsets.bottom + 20),
        child: StatefulBuilder(
          builder: (ctx, setState) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Icon(Iconsax.people, color: _navy),
                const SizedBox(width: 10),
                const Text('Add Team Member', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: _navy)),
                const Spacer(),
                IconButton(onPressed: () => Navigator.pop(ctx), icon: const Icon(Iconsax.close_circle)),
              ]),
              const Divider(),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: _inputField(firstCtrl, 'First Name', Iconsax.profile_circle)),
                const SizedBox(width: 12),
                Expanded(child: _inputField(lastCtrl, 'Last Name', Iconsax.profile_circle)),
              ]),
              const SizedBox(height: 12),
              _inputField(emailCtrl, 'Email', Iconsax.sms),
              const SizedBox(height: 12),
              _inputField(phoneCtrl, 'Phone (optional)', Iconsax.call),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: role,
                decoration: InputDecoration(
                  labelText: 'Role',
                  prefixIcon: const Icon(Iconsax.briefcase, size: 20),
                  filled: true,
                  fillColor: const Color(0xFFF8FAFC),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                ),
                items: const [
                  DropdownMenuItem(value: 'worker', child: Text('Worker')),
                  DropdownMenuItem(value: 'manager', child: Text('Manager')),
                  DropdownMenuItem(value: 'accountant', child: Text('Accountant')),
                ],
                onChanged: (v) => setState(() => role = v!),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: Consumer(builder: (ctx, ref, _) {
                  final notifier = ref.watch(workerNotifierProvider);
                  return ElevatedButton(
                    onPressed: notifier is AsyncLoading
                        ? null
                        : () async {
                            if (emailCtrl.text.isEmpty || firstCtrl.text.isEmpty) return;
                            final result = await ref.read(workerNotifierProvider.notifier).createWorker({
                              'first_name': firstCtrl.text.trim(),
                              'last_name': lastCtrl.text.trim(),
                              'email': emailCtrl.text.trim(),
                              'phone': phoneCtrl.text.isEmpty ? null : phoneCtrl.text.trim(),
                              'role': role,
                            });
                            if (result != null && ctx.mounted) {
                              Navigator.pop(ctx);
                              ref.refresh(workersProvider);
                            }
                          },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _blue,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: notifier is AsyncLoading
                        ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                        : const Text('Send Invite', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                  );
                }),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _inputField(TextEditingController ctrl, String label, IconData icon) {
    return TextField(
      controller: ctrl,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, size: 20),
        filled: true,
        fillColor: const Color(0xFFF8FAFC),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
        contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
      ),
    );
  }
}
