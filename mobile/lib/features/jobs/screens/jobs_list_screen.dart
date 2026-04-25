import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';

import '../../../core/utils/theme.dart';
import '../providers/jobs_provider.dart';
import '../widgets/job_card.dart';

class JobsListScreen extends ConsumerStatefulWidget {
  const JobsListScreen({super.key});

  @override
  ConsumerState<JobsListScreen> createState() => _JobsListScreenState();
}

class _JobsListScreenState extends ConsumerState<JobsListScreen> with SingleTickerProviderStateMixin {
  late TabController _tab;
  final _search = TextEditingController();

  final _statuses = ['all', 'scheduled', 'in_progress', 'completed', 'on_hold'];
  final _statusLabels = ['All', 'Scheduled', 'In Progress', 'Completed', 'On Hold'];

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: _statuses.length, vsync: this);
  }

  @override
  void dispose() {
    _tab.dispose();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TradieColors.grey50,
      appBar: AppBar(
        title: const Text('Jobs'),
        actions: [
          IconButton(icon: const Icon(Iconsax.filter), onPressed: () {}),
          IconButton(
            icon: const Icon(Iconsax.add_circle),
            onPressed: () => context.go('/jobs/create'),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(100),
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                controller: _search,
                decoration: InputDecoration(
                  hintText: 'Search jobs...',
                  prefixIcon: const Icon(Iconsax.search_normal, size: 18, color: TradieColors.grey400),
                  filled: true,
                  fillColor: TradieColors.grey50,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: TradieColors.grey200)),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: TradieColors.grey200)),
                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                  isDense: true,
                ),
              ),
            ),
            TabBar(
              controller: _tab,
              isScrollable: true,
              labelColor: TradieColors.electricBlue,
              unselectedLabelColor: TradieColors.grey400,
              indicatorColor: TradieColors.electricBlue,
              indicatorSize: TabBarIndicatorSize.label,
              tabs: _statusLabels.map((s) => Tab(text: s)).toList(),
            ),
          ]),
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: _statuses.map((status) => _JobsList(status: status == 'all' ? null : status)).toList(),
      ),
    );
  }
}

class _JobsList extends ConsumerWidget {
  final String? status;
  const _JobsList({this.status});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final jobs = ref.watch(jobsProvider(status));

    return jobs.when(
      data: (list) => list.isEmpty
          ? _EmptyState(status: status)
          : RefreshIndicator(
              onRefresh: () => ref.refresh(jobsProvider(status).future),
              child: ListView.builder(
                padding: const EdgeInsets.only(top: 8, bottom: 100),
                itemCount: list.length,
                itemBuilder: (ctx, i) => JobCard(job: list[i], onTap: () => ctx.go('/jobs/${list[i]['id']}')),
              ),
            ),
      loading: () => ListView.builder(
        itemCount: 5,
        padding: const EdgeInsets.only(top: 8),
        itemBuilder: (_, __) => const _JobCardSkeleton(),
      ),
      error: (e, _) => Center(child: Text('Failed to load jobs: $e')),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final String? status;
  const _EmptyState({this.status});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(color: TradieColors.grey100, shape: BoxShape.circle),
          child: const Icon(Iconsax.briefcase, size: 48, color: TradieColors.grey400),
        ),
        const SizedBox(height: 16),
        Text(
          status == null ? 'No jobs yet' : 'No ${status!.replaceAll('_', ' ')} jobs',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: TradieColors.navy),
        ),
        const SizedBox(height: 8),
        const Text('Create your first job to get started', style: TextStyle(color: TradieColors.grey600)),
        const SizedBox(height: 24),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 48),
          child: ElevatedButton.icon(
            onPressed: () => context.go('/jobs/create'),
            icon: const Icon(Iconsax.add, size: 18),
            label: const Text('Create Job'),
          ),
        ),
      ]),
    );
  }
}

class _JobCardSkeleton extends StatelessWidget {
  const _JobCardSkeleton();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      height: 100,
      decoration: BoxDecoration(color: TradieColors.grey100, borderRadius: BorderRadius.circular(12)),
    );
  }
}
