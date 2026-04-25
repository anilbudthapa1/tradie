import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';

import '../utils/theme.dart';

class ShellScaffold extends StatelessWidget {
  final Widget child;
  const ShellScaffold({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final location = GoRouterState.of(context).matchedLocation;
    final idx = _indexFromLocation(location);

    return Scaffold(
      body: child,
      bottomNavigationBar: _TradieBottomNav(currentIndex: idx),
      floatingActionButton: _QuickCreateFAB(),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
    );
  }

  int _indexFromLocation(String loc) {
    if (loc.startsWith('/dashboard')) return 0;
    if (loc.startsWith('/jobs')) return 1;
    if (loc.startsWith('/calendar')) return 2;
    if (loc.startsWith('/customers')) return 3;
    if (loc.startsWith('/profile') || loc.startsWith('/settings')) return 4;
    return 0;
  }
}

class _TradieBottomNav extends StatelessWidget {
  final int currentIndex;
  const _TradieBottomNav({required this.currentIndex});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: TradieColors.white,
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 20, offset: const Offset(0, -4))],
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _NavItem(icon: Iconsax.home_2, label: 'Home', index: 0, current: currentIndex, route: '/dashboard'),
              _NavItem(icon: Iconsax.briefcase, label: 'Jobs', index: 1, current: currentIndex, route: '/jobs'),
              const SizedBox(width: 56), // FAB space
              _NavItem(icon: Iconsax.calendar, label: 'Calendar', index: 2, current: currentIndex, route: '/calendar'),
              _NavItem(icon: Iconsax.profile_2user, label: 'More', index: 4, current: currentIndex, route: '/profile'),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final int index;
  final int current;
  final String route;

  const _NavItem({required this.icon, required this.label, required this.index, required this.current, required this.route});

  @override
  Widget build(BuildContext context) {
    final active = index == current;
    return GestureDetector(
      onTap: () => context.go(route),
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: active
            ? BoxDecoration(
                color: TradieColors.electricBlue.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
              )
            : null,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22, color: active ? TradieColors.electricBlue : TradieColors.grey400),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                color: active ? TradieColors.electricBlue : TradieColors.grey400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QuickCreateFAB extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [TradieColors.electricBlue, Color(0xFF1D4ED8)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: TradieColors.electricBlue.withOpacity(0.4), blurRadius: 12, offset: const Offset(0, 4))],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => context.go('/jobs/create'),
          child: const Icon(Iconsax.add, color: Colors.white, size: 28),
        ),
      ),
    );
  }
}
