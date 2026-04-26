import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';
import '../../../core/utils/theme.dart';
import '../providers/map_provider.dart';
import 'live_location_screen.dart';

class MapScreen extends ConsumerStatefulWidget {
  const MapScreen({super.key});

  @override
  ConsumerState<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends ConsumerState<MapScreen> {
  String _filter = 'all';

  @override
  Widget build(BuildContext context) {
    final locationsAsync = ref.watch(workerLocationsProvider);

    return Scaffold(
      backgroundColor: TradieColors.background,
      appBar: AppBar(
        backgroundColor: TradieColors.navyDark,
        title: const Text('Live Map', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
        actions: [
          IconButton(
            icon: const Icon(Iconsax.refresh, color: Colors.white),
            onPressed: () => ref.invalidate(workerLocationsProvider),
          ),
          IconButton(
            icon: const Icon(Iconsax.location, color: Colors.white),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const LiveLocationScreen()),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          _FilterBar(
            selected: _filter,
            onChanged: (v) => setState(() => _filter = v),
          ),
          Expanded(
            child: locationsAsync.when(
              loading: () => const Center(child: CircularProgressIndicator(color: TradieColors.electricBlue)),
              error: (e, _) => _ErrorState(onRetry: () => ref.invalidate(workerLocationsProvider)),
              data: (locations) {
                final filtered = _applyFilter(locations);
                return filtered.isEmpty
                    ? _EmptyState(filter: _filter)
                    : _WorkerList(locations: filtered);
              },
            ),
          ),
        ],
      ),
    );
  }

  List<WorkerLocation> _applyFilter(List<WorkerLocation> all) {
    switch (_filter) {
      case 'active':
        return all.where((w) => w.isCheckedIn).toList();
      case 'on_job':
        return all.where((w) => w.jobId != null).toList();
      default:
        return all;
    }
  }
}

class _FilterBar extends StatelessWidget {
  final String selected;
  final ValueChanged<String> onChanged;

  const _FilterBar({required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final filters = [
      ('all', 'All Workers'),
      ('active', 'Checked In'),
      ('on_job', 'On Job'),
    ];
    return Container(
      color: TradieColors.navyDark,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Row(
        children: filters.map((f) {
          final isActive = selected == f.$1;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: GestureDetector(
              onTap: () => onChanged(f.$1),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  color: isActive ? TradieColors.electricBlue : Colors.white.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  f.$2,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _WorkerList extends StatelessWidget {
  final List<WorkerLocation> locations;

  const _WorkerList({required this.locations});

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: locations.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, i) => _WorkerCard(worker: locations[i]),
    );
  }
}

class _WorkerCard extends StatelessWidget {
  final WorkerLocation worker;

  const _WorkerCard({required this.worker});

  @override
  Widget build(BuildContext context) {
    final initials = worker.name.isNotEmpty
        ? worker.name.split(' ').map((p) => p.isNotEmpty ? p[0] : '').take(2).join().toUpperCase()
        : '?';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: Row(
        children: [
          Stack(
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: TradieColors.navyDark,
                child: Text(initials, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
              ),
              if (worker.isCheckedIn)
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: TradieColors.green,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(worker.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15, color: TradieColors.navy)),
                if (worker.jobTitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Row(
                      children: [
                        const Icon(Iconsax.briefcase, size: 12, color: TradieColors.electricBlue),
                        const SizedBox(width: 4),
                        Text(worker.jobTitle!, style: const TextStyle(fontSize: 12, color: TradieColors.electricBlue)),
                      ],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    children: [
                      const Icon(Iconsax.location, size: 12, color: TradieColors.textSecondary),
                      const SizedBox(width: 4),
                      Text(
                        '${worker.latitude.toStringAsFixed(4)}, ${worker.longitude.toStringAsFixed(4)}',
                        style: const TextStyle(fontSize: 11, color: TradieColors.textSecondary),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: worker.isCheckedIn
                      ? TradieColors.green.withOpacity(0.1)
                      : TradieColors.textSecondary.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  worker.isCheckedIn ? 'Active' : 'Offline',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: worker.isCheckedIn ? TradieColors.green : TradieColors.textSecondary,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _timeAgo(worker.updatedAt),
                style: const TextStyle(fontSize: 10, color: TradieColors.textSecondary),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}

class _EmptyState extends StatelessWidget {
  final String filter;

  const _EmptyState({required this.filter});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: TradieColors.electricBlue.withOpacity(0.08),
              shape: BoxShape.circle,
            ),
            child: const Icon(Iconsax.location_slash, size: 48, color: TradieColors.electricBlue),
          ),
          const SizedBox(height: 16),
          Text(
            filter == 'all' ? 'No worker locations' : 'No workers match this filter',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: TradieColors.navy),
          ),
          const SizedBox(height: 8),
          const Text(
            'Workers share their location when they check in to a job.',
            style: TextStyle(fontSize: 14, color: TradieColors.textSecondary),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final VoidCallback onRetry;

  const _ErrorState({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Iconsax.warning_2, size: 48, color: TradieColors.red),
          const SizedBox(height: 16),
          const Text('Failed to load locations', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Iconsax.refresh),
            label: const Text('Retry'),
            style: ElevatedButton.styleFrom(backgroundColor: TradieColors.electricBlue, foregroundColor: Colors.white),
          ),
        ],
      ),
    );
  }
}
