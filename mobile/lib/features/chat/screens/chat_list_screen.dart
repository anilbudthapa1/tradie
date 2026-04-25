import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';

import '../../../core/utils/theme.dart';
import '../providers/chat_provider.dart';

class ChatListScreen extends ConsumerStatefulWidget {
  const ChatListScreen({super.key});

  @override
  ConsumerState<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends ConsumerState<ChatListScreen> {
  @override
  void initState() {
    super.initState();
    // Connect WS and load rooms on mount.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await ref.read(chatProvider.notifier).connectWebSocket();
      await ref.read(chatProvider.notifier).loadRooms();
    });
  }

  @override
  Widget build(BuildContext context) {
    final chat = ref.watch(chatProvider);

    return Scaffold(
      backgroundColor: TradieColors.grey50,
      appBar: AppBar(
        backgroundColor: TradieColors.white,
        elevation: 0,
        title: Row(
          children: [
            const Icon(Iconsax.message, size: 20, color: TradieColors.electricBlue),
            const SizedBox(width: 8),
            const Text(
              'Team Chat',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: TradieColors.navy,
              ),
            ),
          ],
        ),
        actions: [
          // WebSocket connection badge.
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: _WsBadge(connected: chat.wsConnected),
          ),
          IconButton(
            icon: const Icon(Iconsax.search_normal, color: TradieColors.grey600),
            onPressed: () {},
          ),
        ],
      ),
      body: Builder(builder: (context) {
        if (chat.roomsLoading && chat.rooms.isEmpty) {
          return ListView.builder(
            padding: const EdgeInsets.only(top: 8),
            itemCount: 6,
            itemBuilder: (_, __) => const _RoomSkeleton(),
          );
        }

        if (chat.rooms.isEmpty) {
          return _EmptyState(
            onCreateRoom: () => _showCreateRoomSheet(context),
          );
        }

        return RefreshIndicator(
          color: TradieColors.electricBlue,
          onRefresh: () => ref.read(chatProvider.notifier).loadRooms(),
          child: ListView.separated(
            padding: const EdgeInsets.only(top: 8, bottom: 100),
            itemCount: chat.rooms.length,
            separatorBuilder: (_, __) => const Divider(
              height: 1,
              indent: 72,
              color: TradieColors.grey100,
            ),
            itemBuilder: (ctx, i) {
              final room = chat.rooms[i];
              return _RoomCard(
                room: room,
                onTap: () {
                  final id = room['id'] as String;
                  final name = room['name'] as String? ?? 'Chat';
                  context.go('/chat/$id', extra: name);
                },
              );
            },
          ),
        );
      }),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: TradieColors.electricBlue,
        foregroundColor: TradieColors.white,
        icon: const Icon(Iconsax.message_add, size: 20),
        label: const Text('New Chat'),
        onPressed: () => _showCreateRoomSheet(context),
      ),
    );
  }

  void _showCreateRoomSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _CreateRoomSheet(
        onCreated: (room) {
          if (room != null) {
            final id = room['id'] as String;
            final name = room['name'] as String? ?? 'Chat';
            context.go('/chat/$id', extra: name);
          }
        },
      ),
    );
  }
}

// ── WS connection badge ───────────────────────────────────────────────────────

class _WsBadge extends StatelessWidget {
  final bool connected;
  const _WsBadge({required this.connected});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: connected ? 'Connected' : 'Offline',
      child: Container(
        width: 10,
        height: 10,
        margin: const EdgeInsets.symmetric(vertical: 17),
        decoration: BoxDecoration(
          color: connected ? TradieColors.successGreen : TradieColors.grey400,
          shape: BoxShape.circle,
          boxShadow: connected
              ? [
                  BoxShadow(
                    color: TradieColors.successGreen.withOpacity(0.4),
                    blurRadius: 6,
                    spreadRadius: 2,
                  ),
                ]
              : null,
        ),
      ),
    );
  }
}

// ── Room card ─────────────────────────────────────────────────────────────────

class _RoomCard extends StatelessWidget {
  final Map<String, dynamic> room;
  final VoidCallback onTap;

  const _RoomCard({required this.room, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final name = room['name'] as String? ?? 'Room';
    final type = room['type'] as String? ?? 'group';
    final unread = room['unread_count'] as int? ?? 0;
    final lastMsg = room['last_message'] as Map<String, dynamic>?;
    final lastContent = lastMsg?['content'] as String?;
    final lastTime = lastMsg?['created_at'] != null
        ? _formatTime(lastMsg!['created_at'] as String)
        : null;

    final isGroup = type != 'direct';

    return InkWell(
      onTap: onTap,
      child: Container(
        color: TradieColors.white,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            // Avatar / icon.
            _RoomAvatar(name: name, isGroup: isGroup),
            const SizedBox(width: 12),

            // Name + last message.
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          name,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: unread > 0 ? FontWeight.w700 : FontWeight.w600,
                            color: TradieColors.navy,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (lastTime != null)
                        Text(
                          lastTime,
                          style: TextStyle(
                            fontSize: 12,
                            color: unread > 0
                                ? TradieColors.electricBlue
                                : TradieColors.grey400,
                            fontWeight: unread > 0 ? FontWeight.w600 : FontWeight.normal,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          lastContent ?? 'No messages yet',
                          style: TextStyle(
                            fontSize: 13,
                            color: unread > 0 ? TradieColors.charcoal : TradieColors.grey400,
                            fontWeight: unread > 0 ? FontWeight.w500 : FontWeight.normal,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (unread > 0) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: TradieColors.electricBlue,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            unread > 99 ? '99+' : '$unread',
                            style: const TextStyle(
                              color: TradieColors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(String iso) {
    try {
      final dt = DateTime.parse(iso).toLocal();
      final now = DateTime.now();
      final diff = now.difference(dt);
      if (diff.inMinutes < 1) return 'Now';
      if (diff.inHours < 1) return '${diff.inMinutes}m';
      if (diff.inDays < 1) return '${diff.inHours}h';
      if (diff.inDays < 7) return '${diff.inDays}d';
      return '${dt.day}/${dt.month}';
    } catch (_) {
      return '';
    }
  }
}

// ── Room avatar ───────────────────────────────────────────────────────────────

class _RoomAvatar extends StatelessWidget {
  final String name;
  final bool isGroup;

  const _RoomAvatar({required this.name, required this.isGroup});

  @override
  Widget build(BuildContext context) {
    final initials = name.isNotEmpty
        ? name.trim().split(' ').take(2).map((w) => w[0].toUpperCase()).join()
        : '?';

    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: isGroup
            ? TradieColors.electricBlue.withOpacity(0.12)
            : TradieColors.navy.withOpacity(0.08),
        shape: BoxShape.circle,
      ),
      child: isGroup
          ? Center(
              child: Icon(
                Iconsax.people,
                size: 22,
                color: TradieColors.electricBlue,
              ),
            )
          : Center(
              child: Text(
                initials,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: TradieColors.navy,
                ),
              ),
            ),
    );
  }
}

// ── Create room bottom sheet ──────────────────────────────────────────────────

class _CreateRoomSheet extends ConsumerStatefulWidget {
  final void Function(Map<String, dynamic>?) onCreated;

  const _CreateRoomSheet({required this.onCreated});

  @override
  ConsumerState<_CreateRoomSheet> createState() => _CreateRoomSheetState();
}

class _CreateRoomSheetState extends ConsumerState<_CreateRoomSheet> {
  final _nameCtrl = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Room name is required');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });

    final room = await ref.read(chatProvider.notifier).createRoom(
          name: name,
          type: 'group',
          memberIds: const [],
        );

    if (mounted) {
      setState(() => _loading = false);
      Navigator.pop(context);
      widget.onCreated(room);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + bottom),
      decoration: BoxDecoration(
        color: TradieColors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 20, offset: const Offset(0, -4)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: TradieColors.electricBlue.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Iconsax.message_add, color: TradieColors.electricBlue, size: 20),
              ),
              const SizedBox(width: 12),
              const Text(
                'New Group Chat',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: TradieColors.navy),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Iconsax.close_circle, color: TradieColors.grey400),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _nameCtrl,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
              labelText: 'Room name',
              hintText: 'e.g. Site Team, Plumbers...',
              prefixIcon: const Icon(Iconsax.message, size: 18, color: TradieColors.grey400),
              errorText: _error,
              filled: true,
              fillColor: TradieColors.grey50,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: TradieColors.grey200),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: TradieColors.grey200),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: TradieColors.electricBlue, width: 2),
              ),
            ),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: TradieColors.electricBlue,
                foregroundColor: TradieColors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              onPressed: _loading ? null : _submit,
              icon: _loading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: TradieColors.white),
                    )
                  : const Icon(Iconsax.message_add, size: 18),
              label: Text(_loading ? 'Creating...' : 'Create Room'),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Empty state ───────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final VoidCallback onCreateRoom;
  const _EmptyState({required this.onCreateRoom});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(
                color: TradieColors.electricBlue.withOpacity(0.08),
                shape: BoxShape.circle,
              ),
              child: const Icon(Iconsax.message, size: 52, color: TradieColors.electricBlue),
            ),
            const SizedBox(height: 20),
            const Text(
              'No chats yet',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: TradieColors.navy),
            ),
            const SizedBox(height: 8),
            const Text(
              'Create a group chat to collaborate with your team in real time.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: TradieColors.grey600, height: 1.5),
            ),
            const SizedBox(height: 28),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: TradieColors.electricBlue,
                foregroundColor: TradieColors.white,
                padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              onPressed: onCreateRoom,
              icon: const Icon(Iconsax.message_add, size: 18),
              label: const Text('Start a Chat'),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Skeleton loader ───────────────────────────────────────────────────────────

class _RoomSkeleton extends StatelessWidget {
  const _RoomSkeleton();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: TradieColors.white,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: const BoxDecoration(color: TradieColors.grey100, shape: BoxShape.circle),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(height: 14, width: 140, decoration: BoxDecoration(color: TradieColors.grey100, borderRadius: BorderRadius.circular(6))),
                const SizedBox(height: 8),
                Container(height: 12, width: 200, decoration: BoxDecoration(color: TradieColors.grey100, borderRadius: BorderRadius.circular(6))),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
