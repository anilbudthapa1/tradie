import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../../core/api/api_client.dart';

// ── Constants ─────────────────────────────────────────────────────────────────

const _wsBaseUrl = String.fromEnvironment('WS_URL', defaultValue: 'ws://10.0.2.2:8080');

// ── Simple FutureProviders ────────────────────────────────────────────────────

final chatRoomsProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final api = ref.read(apiClientProvider);
  final resp = await api.get('/chat/rooms');
  return List<Map<String, dynamic>>.from(resp.data as List);
});

final chatMessagesProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((ref, roomId) async {
  final api = ref.read(apiClientProvider);
  final resp = await api.get('/chat/rooms/$roomId/messages');
  return List<Map<String, dynamic>>.from(resp.data as List);
});

// ── ChatState ─────────────────────────────────────────────────────────────────

class ChatState {
  final List<Map<String, dynamic>> rooms;
  final List<Map<String, dynamic>> messages;
  final bool roomsLoading;
  final bool messagesLoading;
  final bool wsConnected;
  final String? currentRoomId;
  final String? error;

  const ChatState({
    this.rooms = const [],
    this.messages = const [],
    this.roomsLoading = false,
    this.messagesLoading = false,
    this.wsConnected = false,
    this.currentRoomId,
    this.error,
  });

  ChatState copyWith({
    List<Map<String, dynamic>>? rooms,
    List<Map<String, dynamic>>? messages,
    bool? roomsLoading,
    bool? messagesLoading,
    bool? wsConnected,
    String? currentRoomId,
    String? error,
    bool clearError = false,
  }) =>
      ChatState(
        rooms: rooms ?? this.rooms,
        messages: messages ?? this.messages,
        roomsLoading: roomsLoading ?? this.roomsLoading,
        messagesLoading: messagesLoading ?? this.messagesLoading,
        wsConnected: wsConnected ?? this.wsConnected,
        currentRoomId: currentRoomId ?? this.currentRoomId,
        error: clearError ? null : error ?? this.error,
      );
}

// ── ChatNotifier ──────────────────────────────────────────────────────────────

class ChatNotifier extends StateNotifier<ChatState> {
  final ApiClient _api;
  final FlutterSecureStorage _storage;

  WebSocketChannel? _channel;
  StreamSubscription? _wsSub;

  ChatNotifier(this._api, this._storage) : super(const ChatState());

  // ── Room management ─────────────────────────────────────────────

  Future<void> loadRooms() async {
    state = state.copyWith(roomsLoading: true, clearError: true);
    try {
      final resp = await _api.get('/chat/rooms');
      final rooms = List<Map<String, dynamic>>.from(resp.data as List);
      state = state.copyWith(rooms: rooms, roomsLoading: false);
    } catch (e) {
      state = state.copyWith(roomsLoading: false, error: e.toString());
    }
  }

  Future<Map<String, dynamic>?> createRoom({
    required String name,
    required String type,
    required List<String> memberIds,
    String? jobId,
  }) async {
    try {
      final resp = await _api.post('/chat/rooms', data: {
        'name': name,
        'type': type,
        'member_ids': memberIds,
        if (jobId != null) 'job_id': jobId,
      });
      final data = resp.data as Map<String, dynamic>;
      final room = data['room'] as Map<String, dynamic>;
      // Prepend to room list.
      state = state.copyWith(rooms: [room, ...state.rooms]);
      return room;
    } catch (e) {
      state = state.copyWith(error: e.toString());
      return null;
    }
  }

  // ── Message management ───────────────────────────────────────────

  Future<void> loadMessages(String roomId, {String? before}) async {
    state = state.copyWith(
      messagesLoading: true,
      currentRoomId: roomId,
      clearError: true,
    );
    try {
      final resp = await _api.get(
        '/chat/rooms/$roomId/messages',
        params: before != null ? {'before': before} : null,
      );
      final msgs = List<Map<String, dynamic>>.from(resp.data as List);
      // API returns newest-first; reverse for display.
      final ordered = msgs.reversed.toList();
      if (before != null) {
        // Prepend older messages.
        state = state.copyWith(
          messages: [...ordered, ...state.messages],
          messagesLoading: false,
        );
      } else {
        state = state.copyWith(messages: ordered, messagesLoading: false);
      }
    } catch (e) {
      state = state.copyWith(messagesLoading: false, error: e.toString());
    }
  }

  /// Send a message via WebSocket (preferred) with HTTP REST fallback.
  Future<void> sendMessage(String roomId, String content) async {
    if (state.wsConnected && _channel != null) {
      _channel!.sink.add(jsonEncode({
        'type': 'message',
        'room_id': roomId,
        'content': content,
      }));
    } else {
      // Fallback to REST.
      try {
        final resp = await _api.post(
          '/chat/rooms/$roomId/messages',
          data: {'content': content},
        );
        final msg = resp.data as Map<String, dynamic>;
        _appendMessage(msg);
      } catch (e) {
        state = state.copyWith(error: e.toString());
      }
    }
  }

  void _appendMessage(Map<String, dynamic> msg) {
    // Avoid duplicates by id.
    final id = msg['id'] as String?;
    if (id != null && state.messages.any((m) => m['id'] == id)) return;
    state = state.copyWith(messages: [...state.messages, msg]);

    // Update unread count / last message in the rooms list.
    final roomId = msg['room_id'] as String?;
    if (roomId != null) {
      final updatedRooms = state.rooms.map((r) {
        if (r['id'] == roomId) {
          return {
            ...r,
            'last_message': msg,
            'unread_count': (r['unread_count'] as int? ?? 0),
          };
        }
        return r;
      }).toList();
      state = state.copyWith(rooms: updatedRooms);
    }
  }

  // ── WebSocket lifecycle ──────────────────────────────────────────

  Future<void> connectWebSocket() async {
    if (state.wsConnected) return;

    final token = await _storage.read(key: 'access_token');
    if (token == null) return;

    final uri = Uri.parse('$_wsBaseUrl/chat/ws?token=$token');
    _channel = WebSocketChannel.connect(uri);

    _wsSub = _channel!.stream.listen(
      _onWsMessage,
      onError: _onWsError,
      onDone: _onWsDone,
      cancelOnError: false,
    );

    state = state.copyWith(wsConnected: true);
  }

  void _onWsMessage(dynamic raw) {
    try {
      final data = jsonDecode(raw as String) as Map<String, dynamic>;
      final type = data['type'] as String?;

      switch (type) {
        case 'message':
          final msgData = data['data'] as Map<String, dynamic>?;
          if (msgData == null) break;

          // Build a message map compatible with the REST response shape.
          final msg = {
            'id': msgData['id'],
            'room_id': data['room_id'],
            'user_id': msgData['user_id'],
            'content': data['content'],
            'created_at': msgData['created_at'],
            if (msgData['file_url'] != null) 'file_url': msgData['file_url'],
          };

          // Only append to the message list if we're in that room.
          if (data['room_id'] == state.currentRoomId) {
            _appendMessage(msg);
          } else {
            // Increment unread count for other rooms.
            final roomId = data['room_id'] as String?;
            if (roomId != null) {
              final updatedRooms = state.rooms.map((r) {
                if (r['id'] == roomId) {
                  return {
                    ...r,
                    'last_message': msg,
                    'unread_count': (r['unread_count'] as int? ?? 0) + 1,
                  };
                }
                return r;
              }).toList();
              state = state.copyWith(rooms: updatedRooms);
            }
          }
          break;

        case 'ping':
          // Server sent a heartbeat — no action needed.
          break;
      }
    } catch (_) {
      // Malformed frame — ignore.
    }
  }

  void _onWsError(dynamic error) {
    state = state.copyWith(wsConnected: false, error: 'WebSocket error: $error');
  }

  void _onWsDone() {
    state = state.copyWith(wsConnected: false);
  }

  void disconnectWebSocket() {
    _wsSub?.cancel();
    _channel?.sink.close();
    _channel = null;
    _wsSub = null;
    state = state.copyWith(wsConnected: false);
  }

  void clearCurrentRoom() {
    state = state.copyWith(
      messages: const [],
      currentRoomId: null,
      clearError: true,
    );
  }

  @override
  void dispose() {
    disconnectWebSocket();
    super.dispose();
  }
}

// ── Provider ─────────────────────────────────────────────────────────────────

final chatProvider = StateNotifierProvider<ChatNotifier, ChatState>((ref) {
  return ChatNotifier(
    ref.read(apiClientProvider),
    const FlutterSecureStorage(),
  );
});
