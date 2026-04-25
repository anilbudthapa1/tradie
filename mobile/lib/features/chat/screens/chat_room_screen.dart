import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';

import '../../../core/utils/theme.dart';
import '../providers/chat_provider.dart';

class ChatRoomScreen extends ConsumerStatefulWidget {
  final String roomId;
  final String roomName;

  const ChatRoomScreen({
    super.key,
    required this.roomId,
    required this.roomName,
  });

  @override
  ConsumerState<ChatRoomScreen> createState() => _ChatRoomScreenState();
}

class _ChatRoomScreenState extends ConsumerState<ChatRoomScreen> {
  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final _storage = const FlutterSecureStorage();
  String? _myUserId;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _myUserId = await _storage.read(key: 'user_id');

    final notifier = ref.read(chatProvider.notifier);

    // Ensure WS is connected before loading.
    await notifier.connectWebSocket();

    // Load messages for this room.
    await notifier.loadMessages(widget.roomId);

    // Scroll to bottom on first load.
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    // Clear messages from state but keep WS alive.
    ref.read(chatProvider.notifier).clearCurrentRoom();
    super.dispose();
  }

  void _scrollToBottom({bool animated = false}) {
    if (!_scrollCtrl.hasClients) return;
    final target = _scrollCtrl.position.maxScrollExtent;
    if (animated) {
      _scrollCtrl.animateTo(
        target,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    } else {
      _scrollCtrl.jumpTo(target);
    }
  }

  Future<void> _send() async {
    final content = _inputCtrl.text.trim();
    if (content.isEmpty || _sending) return;

    setState(() => _sending = true);
    _inputCtrl.clear();

    await ref.read(chatProvider.notifier).sendMessage(widget.roomId, content);

    setState(() => _sending = false);

    // Scroll to bottom after send.
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom(animated: true));
  }

  @override
  Widget build(BuildContext context) {
    final chat = ref.watch(chatProvider);

    // Auto-scroll when new messages arrive.
    ref.listen(chatProvider, (prev, next) {
      if ((prev?.messages.length ?? 0) < next.messages.length) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom(animated: true));
      }
    });

    return Scaffold(
      backgroundColor: TradieColors.grey50,
      appBar: AppBar(
        backgroundColor: TradieColors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Iconsax.arrow_left, color: TradieColors.navy),
          onPressed: () => Navigator.pop(context),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.roomName,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: TradieColors.navy,
              ),
            ),
            Row(
              children: [
                Container(
                  width: 7,
                  height: 7,
                  margin: const EdgeInsets.only(right: 5),
                  decoration: BoxDecoration(
                    color: chat.wsConnected ? TradieColors.successGreen : TradieColors.grey400,
                    shape: BoxShape.circle,
                  ),
                ),
                Text(
                  chat.wsConnected ? 'Online' : 'Offline',
                  style: TextStyle(
                    fontSize: 12,
                    color: chat.wsConnected ? TradieColors.successGreen : TradieColors.grey400,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Iconsax.people, color: TradieColors.grey600),
            onPressed: () {
              // Navigate to room members screen (future extension).
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // ── Message list ─────────────────────────────────────────
          Expanded(
            child: Builder(builder: (context) {
              if (chat.messagesLoading && chat.messages.isEmpty) {
                return const Center(
                  child: CircularProgressIndicator(color: TradieColors.electricBlue),
                );
              }

              if (chat.messages.isEmpty) {
                return const _EmptyMessages();
              }

              return NotificationListener<ScrollNotification>(
                onNotification: (n) {
                  // Load older messages when user scrolls to top.
                  if (n is ScrollEndNotification &&
                      _scrollCtrl.position.pixels <= 40 &&
                      !chat.messagesLoading &&
                      chat.messages.isNotEmpty) {
                    final oldest = chat.messages.first;
                    ref.read(chatProvider.notifier).loadMessages(
                          widget.roomId,
                          before: oldest['id'] as String?,
                        );
                  }
                  return false;
                },
                child: ListView.builder(
                  controller: _scrollCtrl,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  itemCount: chat.messages.length,
                  itemBuilder: (ctx, i) {
                    final msg = chat.messages[i];
                    final prev = i > 0 ? chat.messages[i - 1] : null;
                    final isOwn = msg['user_id'] == _myUserId;
                    final showSender = !isOwn &&
                        (prev == null || prev['user_id'] != msg['user_id']);

                    return _MessageBubble(
                      message: msg,
                      isOwn: isOwn,
                      showSenderName: showSender,
                    );
                  },
                ),
              );
            }),
          ),

          // ── Input bar ────────────────────────────────────────────
          _InputBar(
            controller: _inputCtrl,
            sending: _sending,
            onSend: _send,
          ),
        ],
      ),
    );
  }
}

// ── Message bubble ────────────────────────────────────────────────────────────

class _MessageBubble extends StatelessWidget {
  final Map<String, dynamic> message;
  final bool isOwn;
  final bool showSenderName;

  const _MessageBubble({
    required this.message,
    required this.isOwn,
    required this.showSenderName,
  });

  @override
  Widget build(BuildContext context) {
    final content = message['content'] as String? ?? '';
    final createdAt = message['created_at'] as String?;
    final firstName = message['first_name'] as String?;
    final lastName = message['last_name'] as String?;
    final senderName = [firstName, lastName].where((s) => s != null && s.isNotEmpty).join(' ');
    final initials = senderName.isNotEmpty
        ? senderName.trim().split(' ').take(2).map((w) => w[0].toUpperCase()).join()
        : '?';

    final timeStr = createdAt != null ? _formatTime(createdAt) : '';

    return Padding(
      padding: EdgeInsets.only(
        top: showSenderName ? 12 : 2,
        bottom: 2,
      ),
      child: Row(
        mainAxisAlignment: isOwn ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // Avatar for other users.
          if (!isOwn) ...[
            if (showSenderName)
              _Avatar(initials: initials)
            else
              const SizedBox(width: 36),
            const SizedBox(width: 8),
          ],

          // Bubble.
          Flexible(
            child: Column(
              crossAxisAlignment:
                  isOwn ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                if (showSenderName && !isOwn && senderName.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 4),
                    child: Text(
                      senderName,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: TradieColors.grey600,
                      ),
                    ),
                  ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width * 0.70,
                  ),
                  decoration: BoxDecoration(
                    color: isOwn ? TradieColors.electricBlue : TradieColors.white,
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(18),
                      topRight: const Radius.circular(18),
                      bottomLeft: Radius.circular(isOwn ? 18 : 4),
                      bottomRight: Radius.circular(isOwn ? 4 : 18),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.05),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Text(
                    content,
                    style: TextStyle(
                      fontSize: 15,
                      color: isOwn ? TradieColors.white : TradieColors.charcoal,
                      height: 1.4,
                    ),
                  ),
                ),
                if (timeStr.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 3, left: 4, right: 4),
                    child: Text(
                      timeStr,
                      style: const TextStyle(
                        fontSize: 11,
                        color: TradieColors.grey400,
                      ),
                    ),
                  ),
              ],
            ),
          ),

          // Spacer for own messages.
          if (isOwn) const SizedBox(width: 4),
        ],
      ),
    );
  }

  String _formatTime(String iso) {
    try {
      final dt = DateTime.parse(iso).toLocal();
      final h = dt.hour.toString().padLeft(2, '0');
      final m = dt.minute.toString().padLeft(2, '0');
      return '$h:$m';
    } catch (_) {
      return '';
    }
  }
}

// ── Avatar ────────────────────────────────────────────────────────────────────

class _Avatar extends StatelessWidget {
  final String initials;
  const _Avatar({required this.initials});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: TradieColors.navy.withOpacity(0.10),
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Text(
          initials,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: TradieColors.navy,
          ),
        ),
      ),
    );
  }
}

// ── Input bar ─────────────────────────────────────────────────────────────────

class _InputBar extends StatelessWidget {
  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;

  const _InputBar({
    required this.controller,
    required this.sending,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      padding: EdgeInsets.fromLTRB(12, 8, 12, 8 + bottom),
      decoration: BoxDecoration(
        color: TradieColors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.06),
            blurRadius: 12,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            // Attachment (future).
            IconButton(
              icon: const Icon(Iconsax.attach_circle, color: TradieColors.grey400),
              onPressed: () {},
            ),

            // Text field.
            Expanded(
              child: TextField(
                controller: controller,
                minLines: 1,
                maxLines: 5,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: 'Message...',
                  hintStyle: const TextStyle(color: TradieColors.grey400, fontSize: 15),
                  filled: true,
                  fillColor: TradieColors.grey50,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: const BorderSide(color: TradieColors.grey200),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: const BorderSide(color: TradieColors.grey200),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide:
                        const BorderSide(color: TradieColors.electricBlue, width: 1.5),
                  ),
                ),
                onSubmitted: (_) => onSend(),
              ),
            ),
            const SizedBox(width: 8),

            // Send button.
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              child: GestureDetector(
                onTap: sending ? null : onSend,
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: TradieColors.electricBlue,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: TradieColors.electricBlue.withOpacity(0.30),
                        blurRadius: 8,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: sending
                      ? const Center(
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: TradieColors.white,
                            ),
                          ),
                        )
                      : const Icon(Iconsax.send_1, color: TradieColors.white, size: 20),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Empty state ───────────────────────────────────────────────────────────────

class _EmptyMessages extends StatelessWidget {
  const _EmptyMessages();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: TradieColors.electricBlue.withOpacity(0.08),
              shape: BoxShape.circle,
            ),
            child: const Icon(Iconsax.message, size: 44, color: TradieColors.electricBlue),
          ),
          const SizedBox(height: 16),
          const Text(
            'No messages yet',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: TradieColors.navy,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Be the first to say something.',
            style: TextStyle(fontSize: 14, color: TradieColors.grey400),
          ),
        ],
      ),
    );
  }
}
