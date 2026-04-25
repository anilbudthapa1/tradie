import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/utils/theme.dart';
import '../../../core/providers/settings_provider.dart';

class SubscriptionScreen extends ConsumerWidget {
  const SubscriptionScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subAsync = ref.watch(subscriptionProvider);
    final plansAsync = ref.watch(plansProvider);

    return Scaffold(
      backgroundColor: TradieColors.grey50,
      appBar: AppBar(
        title: Row(children: [
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              color: TradieColors.safetyOrange.withOpacity(0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Iconsax.crown_1, color: TradieColors.safetyOrange, size: 20),
          ),
          const SizedBox(width: 10),
          const Text('Subscription'),
        ]),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(subscriptionProvider);
          ref.invalidate(plansProvider);
        },
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Current plan card
            subAsync.when(
              loading: () => const _SkeletonCard(),
              error: (e, _) => const SizedBox.shrink(),
              data: (data) => _CurrentPlanCard(data: data, ref: ref),
            ),
            const SizedBox(height: 24),
            const Text('Available Plans',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: TradieColors.navy)),
            const SizedBox(height: 12),
            plansAsync.when(
              loading: () => const _SkeletonCard(),
              error: (e, _) => Center(child: Text('$e')),
              data: (plans) => Column(
                children: plans.map((p) {
                  final plan = p as Map<String, dynamic>;
                  final currentSlug = subAsync.asData?.value?['subscription']?['plan_slug'];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _PlanCard(
                      plan: plan,
                      isCurrent: plan['slug'] == currentSlug,
                      onUpgrade: plan['slug'] == currentSlug ? null : () => _upgrade(context, ref, plan['slug'].toString()),
                    ),
                  );
                }).toList(),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Future<void> _upgrade(BuildContext context, WidgetRef ref, String slug) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Upgrade to ${slug[0].toUpperCase()}${slug.substring(1)}'),
        content: const Text('You\'ll be redirected to Stripe to complete your subscription.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: TradieColors.electricBlue),
            child: const Text('Continue to Checkout'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      final url = await ref.read(settingsNotifierProvider.notifier).startUpgrade(slug);
      if (url != null && context.mounted) {
        final uri = Uri.tryParse(url);
        if (uri != null) await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    }
  }
}

class _CurrentPlanCard extends StatelessWidget {
  final Map<String, dynamic> data;
  final WidgetRef ref;

  const _CurrentPlanCard({required this.data, required this.ref});

  @override
  Widget build(BuildContext context) {
    final sub = data['subscription'] as Map<String, dynamic>? ?? {};
    final usage = data['usage'] as Map<String, dynamic>? ?? {};
    final status = sub['status'] ?? 'trialing';
    final planName = sub['plan_name'] ?? 'Starter';
    final cancelAtEnd = sub['cancel_at_period_end'] == true;
    final workers = usage['workers'] ?? 0;
    final jobs = usage['jobs_this_month'] ?? 0;
    final maxWorkers = sub['max_workers'] ?? 5;
    final maxJobs = sub['max_jobs_month'] ?? 100;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [TradieColors.navy, Color(0xFF1E293B)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Current Plan', style: TextStyle(color: TradieColors.white.withOpacity(0.7), fontSize: 12)),
            const SizedBox(height: 4),
            Text(planName, style: const TextStyle(color: TradieColors.white, fontSize: 22, fontWeight: FontWeight.w800)),
          ])),
          _StatusChip(status: status, cancelAtEnd: cancelAtEnd),
        ]),
        const SizedBox(height: 20),
        Row(children: [
          Expanded(child: _UsageBar(
            label: 'Workers',
            icon: Iconsax.people,
            used: workers as int,
            max: maxWorkers as int,
          )),
          const SizedBox(width: 16),
          Expanded(child: _UsageBar(
            label: 'Jobs this month',
            icon: Iconsax.briefcase,
            used: jobs as int,
            max: maxJobs as int,
          )),
        ]),
        if (cancelAtEnd) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: TradieColors.alertRed.withOpacity(0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Row(children: [
              Icon(Iconsax.warning_2, color: TradieColors.alertRed, size: 14),
              SizedBox(width: 8),
              Text('Subscription cancels at end of billing period',
                style: TextStyle(color: TradieColors.alertRed, fontSize: 12)),
            ]),
          ),
        ],
        if (!cancelAtEnd && status == 'active') ...[
          const SizedBox(height: 16),
          TextButton(
            onPressed: () => _confirmCancel(context, ref),
            style: TextButton.styleFrom(
              foregroundColor: TradieColors.white.withOpacity(0.6),
              padding: EdgeInsets.zero,
              minimumSize: Size.zero,
            ),
            child: const Text('Cancel subscription', style: TextStyle(fontSize: 12)),
          ),
        ],
      ]),
    );
  }

  Future<void> _confirmCancel(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Cancel Subscription'),
        content: const Text('Your subscription will remain active until the end of the current billing period.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep Subscription')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: TradieColors.alertRed),
            child: const Text('Cancel Subscription'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(settingsNotifierProvider.notifier).cancelSubscription();
    }
  }
}

class _PlanCard extends StatelessWidget {
  final Map<String, dynamic> plan;
  final bool isCurrent;
  final VoidCallback? onUpgrade;

  const _PlanCard({required this.plan, required this.isCurrent, this.onUpgrade});

  @override
  Widget build(BuildContext context) {
    final name = plan['name'] ?? '';
    final slug = plan['slug'] ?? '';
    final priceM = (plan['price_monthly'] as num?)?.toDouble() ?? 0;
    final maxW = plan['max_workers'] ?? 0;
    final maxJ = plan['max_jobs_month'] ?? 0;
    final features = plan['features'];
    List<String> featureList = [];
    if (features is List) featureList = features.cast<String>();
    else if (features is Map) featureList = features.values.map((v) => v.toString()).toList();

    final isPro = slug == 'pro';
    final isEnterprise = slug == 'enterprise';

    return Container(
      decoration: BoxDecoration(
        color: TradieColors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isCurrent ? TradieColors.electricBlue : (isPro ? TradieColors.safetyOrange.withOpacity(0.3) : TradieColors.grey200),
          width: isCurrent ? 2 : 1,
        ),
      ),
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Text(name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16, color: TradieColors.navy)),
                  if (isPro) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: TradieColors.safetyOrange.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Text('POPULAR', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: TradieColors.safetyOrange)),
                    ),
                  ],
                ]),
                if (priceM > 0)
                  RichText(text: TextSpan(children: [
                    TextSpan(text: '\$${priceM.toStringAsFixed(0)}', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: TradieColors.electricBlue)),
                    const TextSpan(text: '/mo', style: TextStyle(fontSize: 13, color: TradieColors.grey600, fontFamily: 'Inter')),
                  ]))
                else
                  const Text('Free', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: TradieColors.successGreen)),
              ])),
              if (isCurrent)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: TradieColors.electricBlue.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text('Current', style: TextStyle(color: TradieColors.electricBlue, fontWeight: FontWeight.w600, fontSize: 12)),
                ),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              _PlanStat(icon: Iconsax.people, label: '$maxW workers'),
              const SizedBox(width: 16),
              _PlanStat(icon: Iconsax.briefcase, label: '$maxJ jobs/mo'),
            ]),
            if (featureList.isNotEmpty) ...[
              const SizedBox(height: 12),
              ...featureList.take(4).map((f) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Icon(Iconsax.tick_circle, size: 14, color: TradieColors.successGreen),
                  const SizedBox(width: 6),
                  Expanded(child: Text(f, style: const TextStyle(fontSize: 13, color: TradieColors.grey600))),
                ]),
              )),
            ],
          ]),
        ),
        if (onUpgrade != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: SizedBox(
              width: double.infinity,
              height: 44,
              child: FilledButton(
                onPressed: onUpgrade,
                style: FilledButton.styleFrom(
                  backgroundColor: isPro ? TradieColors.safetyOrange : TradieColors.electricBlue,
                  foregroundColor: TradieColors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                child: Text('Upgrade to $name', style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
            ),
          ),
      ]),
    );
  }
}

class _PlanStat extends StatelessWidget {
  final IconData icon;
  final String label;
  const _PlanStat({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) => Row(children: [
    Icon(icon, size: 14, color: TradieColors.grey600),
    const SizedBox(width: 4),
    Text(label, style: const TextStyle(fontSize: 12, color: TradieColors.grey600)),
  ]);
}

class _StatusChip extends StatelessWidget {
  final String status;
  final bool cancelAtEnd;
  const _StatusChip({required this.status, required this.cancelAtEnd});

  @override
  Widget build(BuildContext context) {
    Color bg, fg;
    String label;
    if (cancelAtEnd) { bg = TradieColors.alertRed.withOpacity(0.15); fg = TradieColors.alertRed; label = 'Canceling'; }
    else switch (status) {
      case 'active': bg = TradieColors.successGreen.withOpacity(0.15); fg = TradieColors.successGreen; label = 'Active'; break;
      case 'trialing': bg = TradieColors.electricBlueLight.withOpacity(0.2); fg = TradieColors.electricBlueLight; label = 'Trial'; break;
      case 'past_due': bg = TradieColors.warningAmber.withOpacity(0.15); fg = TradieColors.warningAmber; label = 'Past Due'; break;
      default: bg = TradieColors.grey200; fg = TradieColors.grey600; label = status;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(label, style: TextStyle(color: fg, fontWeight: FontWeight.w600, fontSize: 12)),
    );
  }
}

class _UsageBar extends StatelessWidget {
  final String label;
  final IconData icon;
  final int used;
  final int max;
  const _UsageBar({required this.label, required this.icon, required this.used, required this.max});

  @override
  Widget build(BuildContext context) {
    final pct = max > 0 ? (used / max).clamp(0.0, 1.0) : 0.0;
    final isHigh = pct > 0.8;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(icon, size: 12, color: TradieColors.white.withOpacity(0.6)),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(color: TradieColors.white.withOpacity(0.6), fontSize: 11)),
      ]),
      const SizedBox(height: 4),
      Text('$used / $max', style: TextStyle(
        color: isHigh ? TradieColors.warningAmber : TradieColors.white,
        fontWeight: FontWeight.w700, fontSize: 14,
      )),
      const SizedBox(height: 6),
      ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: LinearProgressIndicator(
          value: pct,
          minHeight: 4,
          backgroundColor: TradieColors.white.withOpacity(0.2),
          valueColor: AlwaysStoppedAnimation(isHigh ? TradieColors.warningAmber : TradieColors.electricBlueLight),
        ),
      ),
    ]);
  }
}

class _SkeletonCard extends StatelessWidget {
  const _SkeletonCard();
  @override
  Widget build(BuildContext context) => Container(
    height: 120,
    decoration: BoxDecoration(color: TradieColors.grey200, borderRadius: BorderRadius.circular(12)),
  );
}
