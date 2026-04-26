import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';

import '../../../core/utils/theme.dart';
import '../../../core/widgets/apple_card.dart';
import '../../../core/widgets/apple_tile.dart';

/// Apple-grammar settings screen.
///
/// Top hero tile, then alternating section tiles. Each section is a stack of
/// AppleCard rows. No tabs, no chrome — the colour change is the divider.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: TradieColors.white,
      body: ListView(
        padding: EdgeInsets.zero,
        children: const [
          _HeroTile(),
          _SectionTile(
            heading: 'Business',
            parchment: true,
            rows: [
              _RowSpec(
                label: 'Business profile',
                subtitle: 'Name, ABN, branding',
                route: '/profile',
              ),
              _RowSpec(
                label: 'Invoice & quote settings',
                subtitle: 'Numbering, defaults, GST',
                route: '/settings',
              ),
              _RowSpec(
                label: 'Regional preferences',
                subtitle: 'Currency, date format, language',
                route: '/settings',
              ),
            ],
          ),
          _SectionTile(
            heading: 'Team',
            parchment: false,
            rows: [
              _RowSpec(
                label: 'Workers',
                subtitle: 'Manage your crew',
                route: '/workers',
              ),
              _RowSpec(
                label: 'Roles & permissions',
                subtitle: 'Who can do what',
                route: '/settings',
              ),
              _RowSpec(
                label: 'Payroll settings',
                subtitle: 'Pay rates, super, awards',
                route: '/settings',
              ),
            ],
          ),
          _SectionTile(
            heading: 'Billing',
            parchment: true,
            rows: [
              _RowSpec(
                label: 'Subscription',
                subtitle: 'Plan, payment method, invoices',
                route: '/settings/subscription',
              ),
              _RowSpec(
                label: 'API keys',
                subtitle: 'Programmatic access',
                route: '/settings',
              ),
            ],
          ),
          _SectionTile(
            heading: 'Security',
            parchment: false,
            rows: [
              _RowSpec(
                label: 'Two-factor authentication',
                subtitle: 'TOTP authenticator',
                route: '/settings',
              ),
              _RowSpec(
                label: 'Active sessions',
                subtitle: 'Devices currently signed in',
                route: '/settings',
              ),
              _RowSpec(
                label: 'Audit log',
                subtitle: 'Security-relevant actions',
                route: '/settings/audit-log',
              ),
              _RowSpec(
                label: 'Change password',
                subtitle: 'Update your account password',
                route: '/profile/change-password',
              ),
            ],
          ),
          _SectionTile(
            heading: 'Notifications',
            parchment: true,
            rows: [
              _RowSpec(
                label: 'Notification preferences',
                subtitle: 'Email, SMS, push',
                route: '/settings/notification-preferences',
              ),
              _RowSpec(
                label: 'Reminders',
                subtitle: 'Job, invoice, and quote reminders',
                route: '/settings',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─── Hero ────────────────────────────────────────────────────────────────────

class _HeroTile extends StatelessWidget {
  const _HeroTile();

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return AppleTile(
      alignment: CrossAxisAlignment.start,
      padding: const EdgeInsets.fromLTRB(24, 96, 24, 64),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Settings.',
            style: tt.displayMedium?.copyWith(
              color: TradieColors.charcoal,
              letterSpacing: -0.4,
              height: 1.10,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Manage your workspace and preferences.',
            style: tt.headlineLarge?.copyWith(
              color: TradieColors.grey600,
              height: 1.14,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Section ─────────────────────────────────────────────────────────────────

class _SectionTile extends StatelessWidget {
  final String heading;
  final bool parchment;
  final List<_RowSpec> rows;

  const _SectionTile({
    required this.heading,
    required this.parchment,
    required this.rows,
  });

  @override
  Widget build(BuildContext context) {
    return AppleTile(
      parchment: parchment,
      alignment: CrossAxisAlignment.start,
      padding: const EdgeInsets.fromLTRB(24, 80, 24, 80),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            heading,
            style: const TextStyle(
              fontFamily: 'Inter',
              fontSize: 34,
              fontWeight: FontWeight.w600,
              color: TradieColors.charcoal,
              height: 1.10,
              letterSpacing: -0.374,
            ),
          ),
          const SizedBox(height: 48),
          for (int i = 0; i < rows.length; i++) ...[
            if (i > 0) const SizedBox(height: 12),
            _SettingsRow(spec: rows[i]),
          ],
        ],
      ),
    );
  }
}

class _RowSpec {
  final String label;
  final String subtitle;
  final String route;
  const _RowSpec({
    required this.label,
    required this.subtitle,
    required this.route,
  });
}

class _SettingsRow extends StatelessWidget {
  final _RowSpec spec;
  const _SettingsRow({required this.spec});

  @override
  Widget build(BuildContext context) {
    return AppleCard(
      onTap: () => context.push(spec.route),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  spec.label,
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: TradieColors.charcoal,
                    height: 1.24,
                    letterSpacing: -0.374,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  spec.subtitle,
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
          ),
          const SizedBox(width: 16),
          const Icon(
            Iconsax.arrow_right_3,
            size: 18,
            color: TradieColors.grey400,
          ),
        ],
      ),
    );
  }
}
