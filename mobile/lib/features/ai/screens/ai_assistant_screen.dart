import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';

import '../../../core/api/api_client.dart';
import '../../../core/utils/theme.dart';

// ── Models ────────────────────────────────────────────────────────────────────

enum _MessageRole { user, assistant }

class _ChatMessage {
  final _MessageRole role;
  final String text;
  final DateTime timestamp;

  const _ChatMessage({
    required this.role,
    required this.text,
    required this.timestamp,
  });
}

// ── State & Notifier ──────────────────────────────────────────────────────────

class _AiChatState {
  final List<_ChatMessage> messages;
  final bool loading;
  final String? error;

  const _AiChatState({
    this.messages = const [],
    this.loading = false,
    this.error,
  });

  _AiChatState copyWith({
    List<_ChatMessage>? messages,
    bool? loading,
    String? error,
  }) =>
      _AiChatState(
        messages: messages ?? this.messages,
        loading: loading ?? this.loading,
        error: error,
      );
}

class _AiChatNotifier extends StateNotifier<_AiChatState> {
  final ApiClient _api;

  _AiChatNotifier(this._api) : super(const _AiChatState());

  Future<void> sendMessage(String text, {String page = 'general'}) async {
    if (text.trim().isEmpty) return;

    final userMsg = _ChatMessage(
      role: _MessageRole.user,
      text: text.trim(),
      timestamp: DateTime.now(),
    );

    state = state.copyWith(
      messages: [...state.messages, userMsg],
      loading: true,
      error: null,
    );

    try {
      final resp = await _api.post('/ai/chat', data: {
        'message': text.trim(),
        'context': {'page': page},
      });
      final data = resp.data as Map<String, dynamic>;
      final reply = data['reply'] as String? ?? '';

      final aiMsg = _ChatMessage(
        role: _MessageRole.assistant,
        text: reply,
        timestamp: DateTime.now(),
      );

      state = state.copyWith(
        messages: [...state.messages, aiMsg],
        loading: false,
      );
    } catch (e) {
      state = state.copyWith(
        loading: false,
        error: 'Could not reach AI assistant. Please try again.',
      );
    }
  }

  void clearError() => state = state.copyWith(error: null);
}

final _aiChatProvider =
    StateNotifierProvider.autoDispose<_AiChatNotifier, _AiChatState>(
  (ref) => _AiChatNotifier(ref.read(apiClientProvider)),
);

// ── Quick action chips ─────────────────────────────────────────────────────────

const _quickActions = [
  "Summarize today's jobs",
  "Draft invoice reminder",
  "Check overdue invoices",
  "Safety checklist tips",
];

// ── Screen ────────────────────────────────────────────────────────────────────

class AiAssistantScreen extends ConsumerStatefulWidget {
  const AiAssistantScreen({super.key});

  @override
  ConsumerState<AiAssistantScreen> createState() => _AiAssistantScreenState();
}

class _AiAssistantScreenState extends ConsumerState<AiAssistantScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  bool _showChips = true;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _send(String text) {
    if (text.trim().isEmpty) return;
    _input.clear();
    setState(() => _showChips = false);
    ref.read(_aiChatProvider.notifier).sendMessage(text);
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent + 200,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final chat = ref.watch(_aiChatProvider);

    // Scroll when new messages arrive
    ref.listen(_aiChatProvider, (_, next) {
      if (!next.loading) _scrollToBottom();
    });

    return Scaffold(
      backgroundColor: TradieColors.grey50,
      appBar: AppBar(
        backgroundColor: TradieColors.white,
        elevation: 0,
        title: Row(children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [TradieColors.electricBlue, Color(0xFF3B82F6)],
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Iconsax.cpu, color: TradieColors.white, size: 18),
          ),
          const SizedBox(width: 10),
          const Text(
            'AI Assistant',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: TradieColors.navy,
            ),
          ),
        ]),
        actions: [
          IconButton(
            icon: const Icon(Iconsax.refresh, color: TradieColors.grey400),
            tooltip: 'New conversation',
            onPressed: () {
              ref.invalidate(_aiChatProvider);
              setState(() => _showChips = true);
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // ── Message list ─────────────────────────────────────────
          Expanded(
            child: chat.messages.isEmpty && !chat.loading
                ? _buildEmptyState()
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    itemCount: chat.messages.length + (chat.loading ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index == chat.messages.length) {
                        return _buildTypingIndicator();
                      }
                      return _buildMessageBubble(chat.messages[index]);
                    },
                  ),
          ),

          // ── Error banner ─────────────────────────────────────────
          if (chat.error != null)
            Container(
              color: TradieColors.red.withOpacity(0.08),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(children: [
                const Icon(Iconsax.warning_2, color: TradieColors.red, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    chat.error!,
                    style: const TextStyle(color: TradieColors.red, fontSize: 13),
                  ),
                ),
                GestureDetector(
                  onTap: () => ref.read(_aiChatProvider.notifier).clearError(),
                  child: const Icon(Iconsax.close_circle, color: TradieColors.red, size: 16),
                ),
              ]),
            ),

          // ── Quick action chips ────────────────────────────────────
          if (_showChips && chat.messages.isEmpty)
            _buildQuickChips(),

          // ── Input bar ────────────────────────────────────────────
          _buildInputBar(chat.loading),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [TradieColors.electricBlue, Color(0xFF3B82F6)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Icon(Iconsax.cpu, color: TradieColors.white, size: 36),
          ),
          const SizedBox(height: 16),
          const Text(
            'AI Assistant',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: TradieColors.navy,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Ask me anything about your tradie business',
            style: TextStyle(fontSize: 14, color: TradieColors.grey400),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildQuickChips() {
    return Container(
      color: TradieColors.white,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        children: _quickActions.map((action) {
          return ActionChip(
            label: Text(
              action,
              style: const TextStyle(
                fontSize: 12,
                color: TradieColors.electricBlue,
                fontWeight: FontWeight.w500,
              ),
            ),
            backgroundColor: TradieColors.electricBlue.withOpacity(0.08),
            side: BorderSide(color: TradieColors.electricBlue.withOpacity(0.2)),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            onPressed: () => _send(action),
            padding: const EdgeInsets.symmetric(horizontal: 4),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildMessageBubble(_ChatMessage msg) {
    final isUser = msg.role == _MessageRole.user;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isUser) ...[
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: TradieColors.electricBlue,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Iconsax.cpu, color: TradieColors.white, size: 16),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: isUser ? TradieColors.electricBlue : TradieColors.white,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(isUser ? 16 : 4),
                  bottomRight: Radius.circular(isUser ? 4 : 16),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.04),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Text(
                msg.text,
                style: TextStyle(
                  fontSize: 14,
                  color: isUser ? TradieColors.white : TradieColors.navy,
                  height: 1.4,
                ),
              ),
            ),
          ),
          if (isUser) const SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget _buildTypingIndicator() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: TradieColors.electricBlue,
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Iconsax.cpu, color: TradieColors.white, size: 16),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: TradieColors.white,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(16),
                topRight: Radius.circular(16),
                bottomRight: Radius.circular(16),
                bottomLeft: Radius.circular(4),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.04),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: const _TypingDots(),
          ),
        ],
      ),
    );
  }

  Widget _buildInputBar(bool loading) {
    return Container(
      color: TradieColors.white,
      padding: EdgeInsets.only(
        left: 16,
        right: 12,
        top: 10,
        bottom: MediaQuery.of(context).padding.bottom + 10,
      ),
      child: Row(
        children: [
          // Voice note button (placeholder)
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: TradieColors.grey50,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: TradieColors.grey200),
            ),
            child: IconButton(
              icon: const Icon(
                Iconsax.microphone_2,
                size: 18,
                color: TradieColors.grey400,
              ),
              onPressed: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Voice input coming soon'),
                    duration: Duration(seconds: 2),
                  ),
                );
              },
            ),
          ),
          const SizedBox(width: 8),
          // Text input
          Expanded(
            child: TextField(
              controller: _input,
              enabled: !loading,
              maxLines: 4,
              minLines: 1,
              textInputAction: TextInputAction.send,
              onSubmitted: (v) => _send(v),
              decoration: InputDecoration(
                hintText: 'Ask anything...',
                hintStyle: TextStyle(color: TradieColors.grey400, fontSize: 14),
                filled: true,
                fillColor: TradieColors.grey50,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: TradieColors.grey200),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: TradieColors.grey200),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: TradieColors.electricBlue, width: 1.5),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Send button
          GestureDetector(
            onTap: loading ? null : () => _send(_input.text),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: loading
                    ? TradieColors.grey200
                    : TradieColors.electricBlue,
                borderRadius: BorderRadius.circular(13),
              ),
              child: Icon(
                loading ? Iconsax.clock : Iconsax.send_1,
                color: TradieColors.white,
                size: 18,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Typing animation dots ─────────────────────────────────────────────────────

class _TypingDots extends StatefulWidget {
  const _TypingDots();

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            final delay = i * 0.33;
            final t = (_ctrl.value - delay).clamp(0.0, 1.0);
            final opacity = (t < 0.5 ? t * 2 : (1 - t) * 2).clamp(0.3, 1.0);
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 2),
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                color: TradieColors.electricBlue.withOpacity(opacity),
                shape: BoxShape.circle,
              ),
            );
          }),
        );
      },
    );
  }
}
