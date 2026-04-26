import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';

import '../../../core/utils/theme.dart';
import '../providers/workers_provider.dart';

class CheckInScreen extends ConsumerStatefulWidget {
  const CheckInScreen({super.key});

  @override
  ConsumerState<CheckInScreen> createState() => _CheckInScreenState();
}

class _CheckInScreenState extends ConsumerState<CheckInScreen> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(myCheckInProvider);

    return Scaffold(
      backgroundColor: TradieColors.white,
      appBar: AppBar(
        title: const Text('Check in / out'),
        backgroundColor: TradieColors.white,
        elevation: 0,
      ),
      body: RefreshIndicator(
        color: TradieColors.electricBlue,
        onRefresh: () async => ref.invalidate(myCheckInProvider),
        child: async.when(
          loading: () => const Center(
            child: CircularProgressIndicator(color: TradieColors.electricBlue),
          ),
          error: (err, _) => _Empty(
            icon: Iconsax.warning_2,
            title: 'Could not load check-ins',
            subtitle: err.toString(),
            color: TradieColors.alertRed,
          ),
          data: (payload) => _Body(
            payload: payload,
            busy: _busy,
            onCheckIn: () => _capture(checkIn: true),
            onCheckOut: () => _capture(checkIn: false),
            onCancel: _cancelActive,
          ),
        ),
      ),
    );
  }

  Future<void> _capture({required bool checkIn}) async {
    if (_busy) return;
    setState(() => _busy = true);

    final position = await _tryGetPosition();
    final notifier = ref.read(checkInNotifierProvider.notifier);
    final ok = checkIn
        ? await notifier.checkIn(
              lat: position?.latitude,
              lng: position?.longitude,
              accuracyM: position?.accuracy,
            ) !=
            null
        : await notifier.checkOut(
            lat: position?.latitude,
            lng: position?.longitude,
            accuracyM: position?.accuracy,
          );

    if (!mounted) return;
    setState(() => _busy = false);
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? (checkIn ? 'Checked in' : 'Checked out')
              : (checkIn
                  ? 'Check-in failed — already checked in?'
                  : 'Check-out failed — not checked in?'),
        ),
        backgroundColor:
            ok ? TradieColors.electricBlue : TradieColors.alertRed,
      ),
    );
  }

  Future<void> _cancelActive(String id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel check-in?'),
        content: const Text(
          "This removes today's check-in entirely — it won't count as worked time.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep it'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: TradieColors.alertRed),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Cancel check-in'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final ok = await ref.read(checkInNotifierProvider.notifier).cancelActive(id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? 'Check-in cancelled' : 'Cancel failed'),
        backgroundColor:
            ok ? TradieColors.electricBlue : TradieColors.alertRed,
      ),
    );
  }

  Future<Position?> _tryGetPosition() async {
    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) return null;
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        return null;
      }
      return await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
    } catch (_) {
      return null;
    }
  }
}

class _Body extends StatelessWidget {
  final dynamic payload;
  final bool busy;
  final VoidCallback onCheckIn;
  final VoidCallback onCheckOut;
  final void Function(String id) onCancel;

  const _Body({
    required this.payload,
    required this.busy,
    required this.onCheckIn,
    required this.onCheckOut,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final map = payload is Map<String, dynamic>
        ? payload as Map<String, dynamic>
        : <String, dynamic>{};
    final active = map['active'] as Map<String, dynamic>?;
    final history = (map['history'] as List?) ?? const [];

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      children: [
        if (active != null)
          _ActiveCard(
            row: active,
            busy: busy,
            onCheckOut: onCheckOut,
            onCancel: () => onCancel(active['id']?.toString() ?? ''),
          )
        else
          _CheckInCard(busy: busy, onTap: onCheckIn),
        const SizedBox(height: 28),
        const Text(
          'Recent',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: TradieColors.charcoal,
            letterSpacing: 0.4,
          ),
        ),
        const SizedBox(height: 8),
        if (history.isEmpty)
          const _Empty(
            icon: Iconsax.clock,
            title: 'No check-ins yet',
            subtitle: 'Your shift history will show here once you check in.',
          )
        else
          for (final h in history)
            _HistoryTile(row: h as Map<String, dynamic>),
      ],
    );
  }
}

class _CheckInCard extends StatelessWidget {
  final bool busy;
  final VoidCallback onTap;
  const _CheckInCard({required this.busy, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
      decoration: BoxDecoration(
        color: TradieColors.electricBlue,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: TradieColors.electricBlue.withValues(alpha: 0.2),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Iconsax.clock, color: TradieColors.white, size: 28),
          const SizedBox(height: 12),
          const Text(
            'Ready to start your shift',
            style: TextStyle(
              color: TradieColors.white,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Tap below — we\'ll log the time and your location.',
            style: TextStyle(
              color: TradieColors.white.withValues(alpha: 0.85),
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            height: 56,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: TradieColors.white,
                foregroundColor: TradieColors.electricBlue,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: busy ? null : onTap,
              icon: busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: TradieColors.electricBlue,
                      ),
                    )
                  : const Icon(Iconsax.login),
              label: Text(
                busy ? 'Checking in…' : 'Check in now',
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActiveCard extends StatelessWidget {
  final Map<String, dynamic> row;
  final bool busy;
  final VoidCallback onCheckOut;
  final VoidCallback onCancel;

  const _ActiveCard({
    required this.row,
    required this.busy,
    required this.onCheckOut,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final startedAt = DateTime.tryParse(row['check_in_at']?.toString() ?? '');
    final duration = startedAt == null
        ? '—'
        : _fmtDuration(DateTime.now().difference(startedAt));
    final hasGps = row['lat'] != null && row['lng'] != null;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: TradieColors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: TradieColors.electricBlue, width: 1.5),
        boxShadow: [
          BoxShadow(
            color: TradieColors.electricBlue.withValues(alpha: 0.08),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: TradieColors.electricBlue.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Iconsax.timer_1,
                    color: TradieColors.electricBlue, size: 22),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Currently working',
                  style: TextStyle(
                    color: TradieColors.charcoal,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (hasGps)
                const Icon(Iconsax.location,
                    color: TradieColors.electricBlue, size: 18),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            duration,
            style: const TextStyle(
              color: TradieColors.charcoal,
              fontSize: 36,
              fontWeight: FontWeight.w700,
              letterSpacing: -1,
            ),
          ),
          if (startedAt != null)
            Text(
              'Started ${_fmtTime(startedAt)}',
              style: const TextStyle(
                color: TradieColors.charcoal,
                fontSize: 13,
              ),
            ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: TradieColors.alertRed,
                foregroundColor: TradieColors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: busy ? null : onCheckOut,
              icon: busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: TradieColors.white,
                      ),
                    )
                  : const Icon(Iconsax.logout_1),
              label: Text(
                busy ? 'Checking out…' : 'Check out',
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: busy ? null : onCancel,
            child: const Text(
              'Cancel this check-in',
              style: TextStyle(color: TradieColors.charcoal, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

class _HistoryTile extends StatelessWidget {
  final Map<String, dynamic> row;
  const _HistoryTile({required this.row});

  @override
  Widget build(BuildContext context) {
    final startedAt = DateTime.tryParse(row['check_in_at']?.toString() ?? '');
    final endedAt = DateTime.tryParse(row['check_out_at']?.toString() ?? '');
    final mins = (row['duration_minutes'] as num?)?.toInt();
    final cancelled = row['cancelled_at'] != null;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: TradieColors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE7E9EE)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: cancelled
                  ? TradieColors.alertRed.withValues(alpha: 0.1)
                  : TradieColors.electricBlue.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              cancelled ? Iconsax.close_circle : Iconsax.tick_circle,
              size: 20,
              color: cancelled
                  ? TradieColors.alertRed
                  : TradieColors.electricBlue,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  startedAt != null ? _fmtDate(startedAt) : '—',
                  style: const TextStyle(
                    color: TradieColors.charcoal,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  startedAt == null
                      ? ''
                      : endedAt == null
                          ? 'In: ${_fmtTime(startedAt)}'
                          : '${_fmtTime(startedAt)} → ${_fmtTime(endedAt)}',
                  style: const TextStyle(
                    color: TradieColors.charcoal,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          if (cancelled)
            const Text(
              'Cancelled',
              style: TextStyle(
                color: TradieColors.alertRed,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            )
          else if (mins != null)
            Text(
              _fmtMinutes(mins),
              style: const TextStyle(
                color: TradieColors.charcoal,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color? color;
  const _Empty({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? TradieColors.charcoal;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 44, color: c.withValues(alpha: 0.4)),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: c,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(color: c.withValues(alpha: 0.7), fontSize: 13),
          ),
        ],
      ),
    );
  }
}

String _fmtDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  if (h <= 0) return '${m}m';
  return '${h}h ${m}m';
}

String _fmtMinutes(int m) {
  final h = m ~/ 60;
  final r = m % 60;
  if (h <= 0) return '${m}m';
  return '${h}h ${r}m';
}

String _fmtTime(DateTime t) {
  final l = t.toLocal();
  final h = l.hour.toString().padLeft(2, '0');
  final m = l.minute.toString().padLeft(2, '0');
  return '$h:$m';
}

String _fmtDate(DateTime t) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final l = t.toLocal();
  return '${l.day} ${months[l.month - 1]}';
}
