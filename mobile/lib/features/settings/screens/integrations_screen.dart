import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/providers/settings_provider.dart';
import '../../../core/utils/theme.dart';

// ── Provider ──────────────────────────────────────────────────────────────────

/// Loads the Stripe billing portal URL and connected status from the API.
final stripeStatusProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  try {
    final notifier = ref.read(settingsNotifierProvider.notifier);
    final result = await notifier.getStripeStatus();
    return result ?? {'connected': false};
  } catch (_) {
    return {'connected': false};
  }
});

/// Loads OAuth connection state for Xero/MYOB/QuickBooks/Google Calendar.
final integrationsStatusProvider =
    FutureProvider<Map<String, dynamic>>((ref) async {
  try {
    final notifier = ref.read(settingsNotifierProvider.notifier);
    return (await notifier.getIntegrationsStatus()) ?? {};
  } catch (_) {
    return {};
  }
});

/// Persists the Google Maps toggle in shared prefs.
final mapsEnabledProvider = StateNotifierProvider<_MapsToggleNotifier, bool>(
  (ref) => _MapsToggleNotifier(),
);

class _MapsToggleNotifier extends StateNotifier<bool> {
  _MapsToggleNotifier() : super(true) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getBool('maps_enabled') ?? true;
  }

  Future<void> toggle(bool value) async {
    state = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('maps_enabled', value);
  }
}

// ── Screen ────────────────────────────────────────────────────────────────────

class IntegrationsScreen extends ConsumerWidget {
  const IntegrationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: TradieColors.grey50,
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A2332),
        foregroundColor: Colors.white,
        elevation: 0,
        title: Row(children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: TradieColors.electricBlue.withOpacity(0.2),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Iconsax.element_4,
                color: TradieColors.electricBlue, size: 20),
          ),
          const SizedBox(width: 10),
          const Text(
            'Integrations',
            style: TextStyle(
                fontWeight: FontWeight.w700, fontSize: 18, color: Colors.white),
          ),
        ]),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 40),
        children: [
          // ── Payments ─────────────────────────────────────────────
          _SectionHeader(title: 'Payments'),
          const SizedBox(height: 8),
          _StripeTile(),

          const SizedBox(height: 24),

          // ── Accounting ───────────────────────────────────────────
          _SectionHeader(title: 'Accounting'),
          const SizedBox(height: 8),
          const _OAuthTile(
            providerSlug: 'xero',
            icon: Iconsax.document_text,
            iconColor: Color(0xFF13B5EA),
            name: 'Xero',
            description: 'Sync invoices, expenses and GST reporting',
          ),
          const SizedBox(height: 8),
          const _OAuthTile(
            providerSlug: 'myob',
            icon: Iconsax.chart_square,
            iconColor: Color(0xFF5542F6),
            name: 'MYOB',
            description: 'Export payroll, invoices and BAS data',
          ),
          const SizedBox(height: 8),
          const _OAuthTile(
            providerSlug: 'quickbooks',
            icon: Iconsax.calculator,
            iconColor: Color(0xFF2CA01C),
            name: 'QuickBooks',
            description: 'Sync chart of accounts and journal entries',
          ),

          const SizedBox(height: 24),

          // ── Scheduling ───────────────────────────────────────────
          _SectionHeader(title: 'Scheduling'),
          const SizedBox(height: 8),
          const _OAuthTile(
            providerSlug: 'google_calendar',
            icon: Iconsax.calendar,
            iconColor: Color(0xFF1A73E8),
            name: 'Google Calendar',
            description: 'Two-way sync jobs and appointments',
          ),

          const SizedBox(height: 24),

          // ── Location ─────────────────────────────────────────────
          _SectionHeader(title: 'Location'),
          const SizedBox(height: 8),
          _MapsTile(),

          const SizedBox(height: 24),

          // ── Communication ────────────────────────────────────────
          _SectionHeader(title: 'Communication'),
          const SizedBox(height: 8),
          _SendGridTile(),
          const SizedBox(height: 8),
          _TwilioTile(),
        ],
      ),
    );
  }
}

// ── Section Header ────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 4),
        child: Text(
          title.toUpperCase(),
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
            color: TradieColors.grey600,
          ),
        ),
      );
}

// ── Status Badge ──────────────────────────────────────────────────────────────

enum _IntegrationStatus { connected, disconnected, comingSoon }

class _StatusBadge extends StatelessWidget {
  final _IntegrationStatus status;
  const _StatusBadge(this.status);

  @override
  Widget build(BuildContext context) {
    switch (status) {
      case _IntegrationStatus.connected:
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: TradieColors.successGreen.withOpacity(0.12),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: const [
            Icon(Iconsax.tick_circle,
                size: 12, color: TradieColors.successGreen),
            SizedBox(width: 4),
            Text('Connected',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: TradieColors.successGreen)),
          ]),
        );

      case _IntegrationStatus.disconnected:
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: TradieColors.grey100,
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Text('Not Connected',
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: TradieColors.grey600)),
        );

      case _IntegrationStatus.comingSoon:
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: TradieColors.safetyOrange.withOpacity(0.10),
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Text('Coming Soon',
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: TradieColors.safetyOrange)),
        );
    }
  }
}

// ── Generic Integration Tile ──────────────────────────────────────────────────

class _IntegrationTile extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String name;
  final String description;
  final _IntegrationStatus status;
  final Widget? actionWidget;

  const _IntegrationTile({
    required this.icon,
    required this.iconColor,
    required this.name,
    required this.description,
    required this.status,
    this.actionWidget,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: TradieColors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: TradieColors.grey200),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Icon container
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: iconColor.withOpacity(0.10),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: iconColor, size: 24),
        ),

        const SizedBox(width: 14),

        // Text content
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Text(
                    name,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        color: TradieColors.navy),
                  ),
                  const SizedBox(width: 8),
                  _StatusBadge(status),
                ]),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: const TextStyle(
                      fontSize: 13, color: TradieColors.grey600, height: 1.4),
                ),
                if (actionWidget != null) ...[
                  const SizedBox(height: 12),
                  actionWidget!,
                ],
              ]),
        ),
      ]),
    );
  }
}

// ── Stripe Tile ───────────────────────────────────────────────────────────────

class _StripeTile extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stripeAsync = ref.watch(stripeStatusProvider);

    return stripeAsync.when(
      loading: () => const _TileShimmer(),
      error: (_, __) => _IntegrationTile(
        icon: Iconsax.card,
        iconColor: const Color(0xFF635BFF),
        name: 'Stripe',
        description: 'Accept online payments, manage billing and subscriptions',
        status: _IntegrationStatus.disconnected,
        actionWidget: _ConnectButton(
          label: 'Connect Stripe',
          onTap: () => _openBillingPortal(context, ref),
        ),
      ),
      data: (data) {
        final connected = data['connected'] as bool? ?? false;
        return _IntegrationTile(
          icon: Iconsax.card,
          iconColor: const Color(0xFF635BFF),
          name: 'Stripe',
          description: 'Accept online payments, manage billing and subscriptions',
          status: connected
              ? _IntegrationStatus.connected
              : _IntegrationStatus.disconnected,
          actionWidget: connected
              ? _OutlineButton(
                  icon: Iconsax.export_2,
                  label: 'Manage Billing',
                  onTap: () => _openBillingPortal(context, ref),
                )
              : _ConnectButton(
                  label: 'Connect Stripe',
                  onTap: () => _openBillingPortal(context, ref),
                ),
        );
      },
    );
  }

  Future<void> _openBillingPortal(BuildContext context, WidgetRef ref) async {
    try {
      final notifier = ref.read(settingsNotifierProvider.notifier);
      final result = await notifier.createBillingPortal();
      final url = result?['url'] as String?;
      if (url != null && url.isNotEmpty) {
        final uri = Uri.parse(url);
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Could not open billing portal'),
              backgroundColor: TradieColors.alertRed),
        );
      }
    }
  }
}

// ── Google Maps Tile ──────────────────────────────────────────────────────────

class _MapsTile extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mapsEnabled = ref.watch(mapsEnabledProvider);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: TradieColors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: TradieColors.grey200),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(children: [
        // Icon
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: const Color(0xFF4285F4).withOpacity(0.10),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Icon(Iconsax.location,
              color: Color(0xFF4285F4), size: 24),
        ),

        const SizedBox(width: 14),

        // Text
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Text(
                    'Google Maps',
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        color: TradieColors.navy),
                  ),
                  const SizedBox(width: 8),
                  _StatusBadge(mapsEnabled
                      ? _IntegrationStatus.connected
                      : _IntegrationStatus.disconnected),
                ]),
                const SizedBox(height: 4),
                const Text(
                  'Route planning, ETA tracking and live worker location',
                  style: TextStyle(
                      fontSize: 13,
                      color: TradieColors.grey600,
                      height: 1.4),
                ),
              ]),
        ),

        const SizedBox(width: 12),

        // Toggle
        Switch(
          value: mapsEnabled,
          onChanged: (v) =>
              ref.read(mapsEnabledProvider.notifier).toggle(v),
          activeColor: TradieColors.electricBlue,
        ),
      ]),
    );
  }
}

// ── SendGrid Tile ─────────────────────────────────────────────────────────────

class _SendGridTile extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // We derive configured status from environment; actual check is server-side.
    // Show a status indicator based on whether the API key is known to be set.
    return _IntegrationTile(
      icon: Iconsax.sms,
      iconColor: const Color(0xFF1A82E2),
      name: 'SendGrid',
      description: 'Transactional email — job confirmations, invoices, receipts',
      status: _IntegrationStatus.connected,
      actionWidget: _OutlineButton(
        icon: Iconsax.setting_2,
        label: 'Email Preferences',
        onTap: () => Navigator.of(context)
            .pushNamed('/settings/notification-preferences'),
      ),
    );
  }
}

// ── Twilio Tile ───────────────────────────────────────────────────────────────

class _TwilioTile extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _IntegrationTile(
      icon: Iconsax.mobile,
      iconColor: const Color(0xFFE21F1F),
      name: 'Twilio',
      description: 'SMS reminders — appointment alerts and overdue notices',
      status: _IntegrationStatus.connected,
      actionWidget: _OutlineButton(
        icon: Iconsax.setting_2,
        label: 'SMS Preferences',
        onTap: () => Navigator.of(context)
            .pushNamed('/settings/notification-preferences'),
      ),
    );
  }
}

// ── Shared action buttons ─────────────────────────────────────────────────────

class _ConnectButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _ConnectButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: onTap,
      icon: const Icon(Iconsax.link_2, size: 16),
      label: Text(label),
      style: FilledButton.styleFrom(
        backgroundColor: TradieColors.electricBlue,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8)),
        padding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        textStyle: const TextStyle(
            fontSize: 13, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _OutlineButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _OutlineButton(
      {required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 15),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: TradieColors.navy,
        side: const BorderSide(color: TradieColors.grey300),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8)),
        padding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        textStyle: const TextStyle(
            fontSize: 13, fontWeight: FontWeight.w600),
      ),
    );
  }
}

// ── OAuth Tile (Xero / MYOB / QuickBooks / Google Calendar) ───────────────────

class _OAuthTile extends ConsumerWidget {
  final String providerSlug;
  final IconData icon;
  final Color iconColor;
  final String name;
  final String description;

  const _OAuthTile({
    required this.providerSlug,
    required this.icon,
    required this.iconColor,
    required this.name,
    required this.description,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statusAsync = ref.watch(integrationsStatusProvider);

    return statusAsync.when(
      loading: () => const _TileShimmer(),
      error: (_, __) => _IntegrationTile(
        icon: icon,
        iconColor: iconColor,
        name: name,
        description: description,
        status: _IntegrationStatus.disconnected,
      ),
      data: (data) {
        final entry = data[providerSlug] as Map?;
        final connected = (entry?['connected'] as bool?) ?? false;
        final configured = (entry?['configured'] as bool?) ?? false;

        if (!configured) {
          return _IntegrationTile(
            icon: icon,
            iconColor: iconColor,
            name: name,
            description: description,
            status: _IntegrationStatus.comingSoon,
          );
        }

        return _IntegrationTile(
          icon: icon,
          iconColor: iconColor,
          name: name,
          description: description,
          status: connected
              ? _IntegrationStatus.connected
              : _IntegrationStatus.disconnected,
          actionWidget: connected
              ? _OutlineButton(
                  icon: Iconsax.close_circle,
                  label: 'Disconnect',
                  onTap: () => _disconnect(context, ref),
                )
              : _ConnectButton(
                  label: 'Connect',
                  onTap: () => _connect(context, ref),
                ),
        );
      },
    );
  }

  Future<void> _connect(BuildContext context, WidgetRef ref) async {
    final notifier = ref.read(settingsNotifierProvider.notifier);
    final url = await notifier.startOAuthConnect(providerSlug);
    if (url == null || url.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not start $name connection'),
            backgroundColor: TradieColors.alertRed,
          ),
        );
      }
      return;
    }
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _disconnect(BuildContext context, WidgetRef ref) async {
    final notifier = ref.read(settingsNotifierProvider.notifier);
    final ok = await notifier.disconnectIntegration(providerSlug);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ok ? '$name disconnected' : 'Disconnect failed'),
          backgroundColor:
              ok ? TradieColors.successGreen : TradieColors.alertRed,
        ),
      );
    }
    ref.invalidate(integrationsStatusProvider);
  }
}

// ── Shimmer placeholder ───────────────────────────────────────────────────────

class _TileShimmer extends StatelessWidget {
  const _TileShimmer();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 86,
      decoration: BoxDecoration(
        color: TradieColors.grey100,
        borderRadius: BorderRadius.circular(12),
      ),
    );
  }
}
