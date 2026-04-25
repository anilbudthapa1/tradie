import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';
import '../../../core/utils/theme.dart';
import '../providers/map_provider.dart';

class LiveLocationScreen extends ConsumerStatefulWidget {
  const LiveLocationScreen({super.key});

  @override
  ConsumerState<LiveLocationScreen> createState() => _LiveLocationScreenState();
}

class _LiveLocationScreenState extends ConsumerState<LiveLocationScreen> {
  Timer? _shareTimer;
  bool _isSimulating = false;

  // Simulated Sydney coordinates for demo (replace with geolocator in production)
  double _lat = -33.8688;
  double _lng = 151.2093;

  @override
  void dispose() {
    _shareTimer?.cancel();
    super.dispose();
  }

  void _startSharing() {
    setState(() => _isSimulating = true);
    ref.read(liveLocationProvider.notifier).updateLocation(_lat, _lng);

    _shareTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      // Slight drift to simulate movement
      _lat += 0.0001;
      _lng += 0.0001;
      ref.read(liveLocationProvider.notifier).updateLocation(_lat, _lng);
    });
  }

  void _stopSharing() {
    _shareTimer?.cancel();
    _shareTimer = null;
    setState(() => _isSimulating = false);
    ref.read(liveLocationProvider.notifier).stopSharing();
  }

  @override
  Widget build(BuildContext context) {
    final locationState = ref.watch(liveLocationProvider);

    return Scaffold(
      backgroundColor: TradieColors.background,
      appBar: AppBar(
        backgroundColor: TradieColors.navyDark,
        leading: IconButton(
          icon: const Icon(Iconsax.arrow_left, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('My Location', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _LocationCard(state: locationState, isSharing: _isSimulating),
            const SizedBox(height: 20),
            _StatusBanner(isSharing: _isSimulating),
            const SizedBox(height: 32),
            if (!_isSimulating)
              _PrimaryButton(
                label: 'Start Sharing Location',
                icon: Iconsax.location,
                color: TradieColors.electricBlue,
                onTap: _startSharing,
              )
            else
              _PrimaryButton(
                label: 'Stop Sharing Location',
                icon: Iconsax.location_slash,
                color: TradieColors.red,
                onTap: _stopSharing,
              ),
            const SizedBox(height: 16),
            const _InfoNote(),
          ],
        ),
      ),
    );
  }
}

class _LocationCard extends StatelessWidget {
  final LiveLocationState state;
  final bool isSharing;

  const _LocationCard({required this.state, required this.isSharing});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 12, offset: const Offset(0, 4))],
      ),
      child: Column(
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: isSharing
                    ? [TradieColors.electricBlue, const Color(0xFF1D4ED8)]
                    : [TradieColors.navyDark, const Color(0xFF0F172A)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              shape: BoxShape.circle,
            ),
            child: Icon(
              isSharing ? Iconsax.location : Iconsax.location_slash,
              color: Colors.white,
              size: 32,
            ),
          ),
          const SizedBox(height: 16),
          if (state.latitude != null && state.longitude != null) ...[
            _CoordRow(label: 'Latitude', value: state.latitude!.toStringAsFixed(6)),
            const SizedBox(height: 8),
            _CoordRow(label: 'Longitude', value: state.longitude!.toStringAsFixed(6)),
          ] else ...[
            const Text(
              'Location not shared',
              style: TextStyle(fontSize: 16, color: TradieColors.textSecondary),
            ),
          ],
          if (state.error != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: TradieColors.red.withOpacity(0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Iconsax.warning_2, size: 16, color: TradieColors.red),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(state.error!, style: const TextStyle(fontSize: 12, color: TradieColors.red)),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _CoordRow extends StatelessWidget {
  final String label;
  final String value;

  const _CoordRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(fontSize: 14, color: TradieColors.textSecondary)),
        Text(value, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: TradieColors.navy)),
      ],
    );
  }
}

class _StatusBanner extends StatelessWidget {
  final bool isSharing;

  const _StatusBanner({required this.isSharing});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: isSharing
            ? TradieColors.green.withOpacity(0.08)
            : TradieColors.textSecondary.withOpacity(0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isSharing ? TradieColors.green.withOpacity(0.3) : Colors.transparent,
        ),
      ),
      child: Row(
        children: [
          Icon(
            isSharing ? Iconsax.wifi : Iconsax.wifi_square,
            size: 18,
            color: isSharing ? TradieColors.green : TradieColors.textSecondary,
          ),
          const SizedBox(width: 10),
          Text(
            isSharing
                ? 'Sharing location with your team — updates every 30 seconds'
                : 'Not sharing your location',
            style: TextStyle(
              fontSize: 13,
              color: isSharing ? TradieColors.green : TradieColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _PrimaryButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 56,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [BoxShadow(color: color.withOpacity(0.3), blurRadius: 12, offset: const Offset(0, 4))],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: Colors.white, size: 20),
            const SizedBox(width: 10),
            Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16)),
          ],
        ),
      ),
    );
  }
}

class _InfoNote extends StatelessWidget {
  const _InfoNote();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: TradieColors.electricBlue.withOpacity(0.06),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Iconsax.info_circle, size: 16, color: TradieColors.electricBlue),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Your location is only visible to your business admin and managers while you are checked in or sharing.',
              style: TextStyle(fontSize: 12, color: TradieColors.textSecondary, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}
