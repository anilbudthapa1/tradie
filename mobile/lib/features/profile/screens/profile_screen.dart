import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';

import '../../../core/utils/theme.dart';
import '../../../core/providers/auth_provider.dart';
import '../../../core/widgets/apple_card.dart';
import '../../../core/widgets/apple_pill_button.dart';
import '../../../core/widgets/apple_tile.dart';

/// Apple-grammar profile screen.
///
/// Three full-bleed tiles:
///   1. Hero (white)      — avatar, name, role, "Edit profile" ghost pill
///   2. Stats (parchment) — three big-number stats in a row
///   3. Actions (white)   — vertical AppleCard rows: Notifications, Subscription,
///                          Audit log, Sign out (alert red)
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authAsync = ref.watch(authStateProvider);
    final user = authAsync.asData?.value ?? const <String, dynamic>{};

    return Scaffold(
      backgroundColor: TradieColors.white,
      body: ListView(
        padding: EdgeInsets.zero,
        children: [
          _HeroTile(user: user),
          const _StatsTile(),
          _ActionsTile(
            onSignOut: () => _confirmLogout(context, ref),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmLogout(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: TradieColors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text(
          'Sign out',
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: TradieColors.charcoal,
          ),
        ),
        content: const Text(
          'Are you sure you want to sign out?',
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 14,
            fontWeight: FontWeight.w400,
            color: TradieColors.grey600,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: TradieColors.electricBlue),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              'Sign out',
              style: TextStyle(color: TradieColors.alertRed),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(authNotifierProvider.notifier).logout();
      if (context.mounted) context.go('/auth/login');
    }
  }
}

// ─── Tile 1 — Hero ───────────────────────────────────────────────────────────

class _HeroTile extends StatelessWidget {
  final Map<String, dynamic> user;
  const _HeroTile({required this.user});

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    final firstName = user['first_name']?.toString() ?? '';
    final lastName = user['last_name']?.toString() ?? '';
    final fullName = '$firstName $lastName'.trim();
    final email = user['email']?.toString() ?? '';
    final role = (user['role']?.toString() ?? 'worker');
    final initials = '${firstName.isNotEmpty ? firstName[0] : ''}'
            '${lastName.isNotEmpty ? lastName[0] : ''}'
        .toUpperCase();

    return AppleTile(
      alignment: CrossAxisAlignment.center,
      padding: const EdgeInsets.fromLTRB(24, 96, 24, 64),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 96,
            height: 96,
            decoration: const BoxDecoration(
              color: TradieColors.grey50,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(
              initials.isEmpty ? 'U' : initials,
              style: const TextStyle(
                fontFamily: 'Inter',
                fontSize: 28,
                fontWeight: FontWeight.w600,
                color: TradieColors.charcoal,
                letterSpacing: -0.374,
              ),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            fullName.isEmpty ? 'Your profile.' : '$fullName.',
            textAlign: TextAlign.center,
            style: tt.displayMedium?.copyWith(
              color: TradieColors.charcoal,
              letterSpacing: -0.4,
              height: 1.10,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            email.isEmpty
                ? _capitalize(role)
                : '${_capitalize(role)} · $email',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: 'Inter',
              fontSize: 17,
              fontWeight: FontWeight.w400,
              color: TradieColors.grey600,
              height: 1.47,
              letterSpacing: -0.374,
            ),
          ),
          const SizedBox(height: 32),
          ApplePillButton(
            label: 'Edit profile',
            primary: false,
            onPressed: () => context.push('/profile/edit'),
          ),
        ],
      ),
    );
  }

  String _capitalize(String s) =>
      s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
}

// ─── Tile 2 — Stats ──────────────────────────────────────────────────────────

class _StatsTile extends ConsumerWidget {
  const _StatsTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tt = Theme.of(context).textTheme;
    // Stats are not yet wired to a provider — render zeros so the chassis
    // remains correct. The orchestrator can wire a future stats provider in.
    return AppleTile(
      parchment: true,
      alignment: CrossAxisAlignment.center,
      padding: const EdgeInsets.fromLTRB(24, 80, 24, 80),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Stat(
            value: '—',
            label: 'Jobs completed',
            tt: tt,
          ),
          _Stat(
            value: '—',
            label: 'Hours logged',
            tt: tt,
          ),
          _Stat(
            value: '—',
            label: 'Customer rating',
            tt: tt,
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String value;
  final String label;
  final TextTheme tt;
  const _Stat({required this.value, required this.label, required this.tt});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            value,
            textAlign: TextAlign.center,
            style: tt.displayMedium?.copyWith(
              color: TradieColors.charcoal,
              letterSpacing: -0.4,
              height: 1.10,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: 'Inter',
              fontSize: 14,
              fontWeight: FontWeight.w400,
              color: TradieColors.grey600,
              height: 1.43,
              letterSpacing: -0.224,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Tile 3 — Actions ────────────────────────────────────────────────────────

class _ActionsTile extends StatelessWidget {
  final VoidCallback onSignOut;
  const _ActionsTile({required this.onSignOut});

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;

    final rows = <_ActionRowSpec>[
      _ActionRowSpec(
        label: 'Notifications',
        onTap: () => context.push('/settings/notification-preferences'),
      ),
      _ActionRowSpec(
        label: 'Subscription',
        onTap: () => context.push('/settings/subscription'),
      ),
      _ActionRowSpec(
        label: 'Audit log',
        onTap: () => context.push('/settings/audit-log'),
      ),
      _ActionRowSpec(
        label: 'Sign out',
        destructive: true,
        onTap: onSignOut,
      ),
    ];

    return AppleTile(
      alignment: CrossAxisAlignment.start,
      padding: const EdgeInsets.fromLTRB(24, 80, 24, 96),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Account.',
            style: tt.displayMedium?.copyWith(
              color: TradieColors.charcoal,
              letterSpacing: -0.4,
              height: 1.10,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Manage what matters.',
            style: tt.headlineLarge?.copyWith(
              color: TradieColors.grey600,
              height: 1.14,
            ),
          ),
          const SizedBox(height: 48),
          for (int i = 0; i < rows.length; i++) ...[
            if (i > 0) const SizedBox(height: 12),
            _ActionRow(spec: rows[i]),
          ],
        ],
      ),
    );
  }
}

class _ActionRowSpec {
  final String label;
  final VoidCallback onTap;
  final bool destructive;
  const _ActionRowSpec({
    required this.label,
    required this.onTap,
    this.destructive = false,
  });
}

class _ActionRow extends StatelessWidget {
  final _ActionRowSpec spec;
  const _ActionRow({required this.spec});

  @override
  Widget build(BuildContext context) {
    final color = spec.destructive
        ? TradieColors.alertRed
        : TradieColors.charcoal;
    return AppleCard(
      onTap: spec.onTap,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      child: Row(
        children: [
          Expanded(
            child: Text(
              spec.label,
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 17,
                fontWeight: FontWeight.w400,
                color: color,
                height: 1.47,
                letterSpacing: -0.374,
              ),
            ),
          ),
          Icon(
            Iconsax.arrow_right_3,
            size: 18,
            color: spec.destructive
                ? TradieColors.alertRed
                : TradieColors.grey400,
          ),
        ],
      ),
    );
  }
}
