import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';

import '../utils/theme.dart';

/// Shell scaffold for the app: pure-black top bar, optional sub-nav strip,
/// and a hairline-bordered white bottom nav. Wires GoRouter location ↔ nav
/// index, preserving the existing routing behaviour.
class ShellScaffold extends StatelessWidget {
  final Widget child;

  /// Optional sub-nav strip rendered directly below the global bar.
  final Widget? subnav;

  /// Optional override for the title label shown in the top bar.
  final String? title;

  /// Optional trailing actions in the top bar (rendered in white at 16px).
  final List<Widget>? trailing;

  const ShellScaffold({
    super.key,
    required this.child,
    this.subnav,
    this.title,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final location = GoRouterState.of(context).matchedLocation;
    final idx = _indexFromLocation(location);

    return Scaffold(
      backgroundColor: TradieColors.white,
      body: Column(
        children: [
          _AppleTopBar(
            title: title ?? 'Tradie',
            trailing: trailing ??
                const [
                  Icon(Iconsax.search_normal_1,
                      color: TradieColors.white, size: 16),
                  SizedBox(width: 16),
                  Icon(Iconsax.notification,
                      color: TradieColors.white, size: 16),
                ],
          ),
          if (subnav != null) subnav!,
          Expanded(child: child),
        ],
      ),
      bottomNavigationBar: _AppleBottomNav(currentIndex: idx),
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

class _AppleTopBar extends StatelessWidget {
  final String title;
  final List<Widget> trailing;

  const _AppleTopBar({required this.title, required this.trailing});

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.of(context).padding.top;
    return Container(
      color: const Color(0xFF000000),
      padding: EdgeInsets.only(top: topInset),
      child: SizedBox(
        height: 44,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                  color: TradieColors.white,
                  letterSpacing: -0.12,
                ),
              ),
              const Spacer(),
              ...trailing,
            ],
          ),
        ),
      ),
    );
  }
}

class _AppleBottomNav extends StatelessWidget {
  final int currentIndex;
  const _AppleBottomNav({required this.currentIndex});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: TradieColors.white,
        border: Border(
          top: BorderSide(color: TradieColors.grey200, width: 1),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _NavItem(
                icon: Iconsax.home_2,
                label: 'Home',
                index: 0,
                current: currentIndex,
                route: '/dashboard',
              ),
              _NavItem(
                icon: Iconsax.briefcase,
                label: 'Jobs',
                index: 1,
                current: currentIndex,
                route: '/jobs',
              ),
              _NavItem(
                icon: Iconsax.calendar,
                label: 'Calendar',
                index: 2,
                current: currentIndex,
                route: '/calendar',
              ),
              _NavItem(
                icon: Iconsax.profile_2user,
                label: 'Customers',
                index: 3,
                current: currentIndex,
                route: '/customers',
              ),
              _NavItem(
                icon: Iconsax.user,
                label: 'Profile',
                index: 4,
                current: currentIndex,
                route: '/profile',
              ),
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

  const _NavItem({
    required this.icon,
    required this.label,
    required this.index,
    required this.current,
    required this.route,
  });

  @override
  Widget build(BuildContext context) {
    final active = index == current;
    final color = active ? TradieColors.electricBlue : TradieColors.grey400;

    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => context.go(route),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 22, color: color),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 11,
                  fontWeight: FontWeight.w400,
                  color: color,
                  letterSpacing: active ? -0.5 : 0,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
