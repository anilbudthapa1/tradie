import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/screens/login_screen.dart';
import '../../features/auth/screens/register_screen.dart';
import '../../features/auth/screens/forgot_password_screen.dart';
import '../../features/auth/screens/mfa_screen.dart';
import '../../features/auth/screens/reset_password_screen.dart';
import '../../features/auth/screens/email_verification_screen.dart';
import '../../features/dashboard/screens/dashboard_screen.dart';
import '../../features/jobs/screens/jobs_list_screen.dart';
import '../../features/jobs/screens/job_detail_screen.dart';
import '../../features/jobs/screens/job_create_screen.dart';
import '../../features/jobs/screens/job_complete_screen.dart';
import '../../features/customers/screens/customers_list_screen.dart';
import '../../features/customers/screens/customer_detail_screen.dart';
import '../../features/quotes/screens/quotes_list_screen.dart';
import '../../features/quotes/screens/quote_detail_screen.dart';
import '../../features/invoices/screens/invoices_list_screen.dart';
import '../../features/invoices/screens/invoice_detail_screen.dart';
import '../../features/calendar/screens/calendar_screen.dart';
import '../../features/safety/screens/safety_screen.dart';
import '../../features/notifications/screens/notifications_screen.dart';
import '../../features/notifications/screens/notification_preferences_screen.dart';
import '../../features/profile/screens/profile_screen.dart';
import '../../features/settings/screens/settings_screen.dart';
import '../../features/settings/screens/subscription_screen.dart';
import '../../features/settings/screens/audit_log_screen.dart';
import '../../features/tasks/screens/tasks_screen.dart';
import '../../features/analytics/screens/analytics_screen.dart';
import '../../features/chat/screens/chat_list_screen.dart';
import '../../features/chat/screens/chat_room_screen.dart';
import '../providers/auth_provider.dart';
import '../widgets/shell_scaffold.dart';

final appRouterProvider = Provider<GoRouter>((ref) {
  final authState = ref.watch(authStateProvider);

  return GoRouter(
    initialLocation: '/dashboard',
    redirect: (context, state) {
      final isLoggedIn = authState.asData?.value != null;
      final isAuthRoute = state.matchedLocation.startsWith('/auth');
      final isPublicRoute = state.matchedLocation.startsWith('/auth/verify-email') ||
          state.matchedLocation.startsWith('/auth/reset-password');

      if (!isLoggedIn && !isAuthRoute) return '/auth/login';
      if (isLoggedIn && isAuthRoute && !isPublicRoute) return '/dashboard';
      return null;
    },
    routes: [
      // ── Auth routes ──────────────────────────────────────────────
      GoRoute(path: '/auth/login', builder: (_, __) => const LoginScreen()),
      GoRoute(path: '/auth/register', builder: (_, __) => const RegisterScreen()),
      GoRoute(path: '/auth/forgot-password', builder: (_, __) => const ForgotPasswordScreen()),
      GoRoute(
        path: '/auth/mfa',
        builder: (_, state) {
          final mfaToken = state.extra as String? ?? '';
          return MFAScreen(mfaToken: mfaToken);
        },
      ),
      GoRoute(
        path: '/auth/reset-password',
        builder: (_, state) {
          final token = state.uri.queryParameters['token'] ?? '';
          return ResetPasswordScreen(token: token);
        },
      ),
      GoRoute(
        path: '/auth/verify-email',
        builder: (_, state) {
          final token = state.uri.queryParameters['token'];
          return EmailVerificationScreen(token: token);
        },
      ),

      // ── Main shell with bottom nav ───────────────────────────────
      ShellRoute(
        builder: (context, state, child) => ShellScaffold(child: child),
        routes: [
          GoRoute(path: '/dashboard', builder: (_, __) => const DashboardScreen()),

          GoRoute(
            path: '/jobs',
            builder: (_, __) => const JobsListScreen(),
            routes: [
              GoRoute(path: 'create', builder: (_, __) => const JobCreateScreen()),
              GoRoute(path: ':id', builder: (ctx, s) => JobDetailScreen(id: s.pathParameters['id']!)),
              GoRoute(path: ':id/complete', builder: (ctx, s) => JobCompleteScreen(id: s.pathParameters['id']!)),
            ],
          ),

          GoRoute(
            path: '/customers',
            builder: (_, __) => const CustomersListScreen(),
            routes: [
              GoRoute(path: ':id', builder: (ctx, s) => CustomerDetailScreen(id: s.pathParameters['id']!)),
            ],
          ),

          GoRoute(path: '/calendar', builder: (_, __) => const CalendarScreen()),

          GoRoute(
            path: '/quotes',
            builder: (_, __) => const QuotesListScreen(),
            routes: [
              GoRoute(path: ':id', builder: (ctx, s) => QuoteDetailScreen(id: s.pathParameters['id']!)),
            ],
          ),

          GoRoute(
            path: '/invoices',
            builder: (_, __) => const InvoicesListScreen(),
            routes: [
              GoRoute(path: ':id', builder: (ctx, s) => InvoiceDetailScreen(id: s.pathParameters['id']!)),
            ],
          ),

          GoRoute(path: '/tasks', builder: (_, __) => const TasksScreen()),
          GoRoute(path: '/analytics', builder: (_, __) => const AnalyticsScreen()),
          GoRoute(path: '/safety', builder: (_, __) => const SafetyScreen()),
          GoRoute(
            path: '/chat',
            builder: (_, __) => const ChatListScreen(),
            routes: [
              GoRoute(
                path: ':id',
                builder: (ctx, s) => ChatRoomScreen(
                  roomId: s.pathParameters['id']!,
                  roomName: s.extra as String? ?? 'Chat',
                ),
              ),
            ],
          ),

          GoRoute(path: '/notifications', builder: (_, __) => const NotificationsScreen()),
          GoRoute(path: '/notifications/preferences', builder: (_, __) => const NotificationPreferencesScreen()),
          GoRoute(path: '/profile', builder: (_, __) => const ProfileScreen()),
          GoRoute(
            path: '/settings',
            builder: (_, __) => const SettingsScreen(),
            routes: [
              GoRoute(path: 'subscription', builder: (_, __) => const SubscriptionScreen()),
              GoRoute(path: 'audit-log', builder: (_, __) => const AuditLogScreen()),
              GoRoute(
                path: 'notification-preferences',
                builder: (_, __) => const NotificationPreferencesScreen(),
              ),
            ],
          ),
        ],
      ),
    ],
  );
});
