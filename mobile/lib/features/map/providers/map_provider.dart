import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';

class WorkerLocation {
  final String userId;
  final String name;
  final double latitude;
  final double longitude;
  final String? jobTitle;
  final String? jobId;
  final DateTime updatedAt;
  final bool isCheckedIn;

  WorkerLocation({
    required this.userId,
    required this.name,
    required this.latitude,
    required this.longitude,
    this.jobTitle,
    this.jobId,
    required this.updatedAt,
    required this.isCheckedIn,
  });

  factory WorkerLocation.fromJson(Map<String, dynamic> j) => WorkerLocation(
        userId: j['user_id'] ?? '',
        name: j['name'] ?? '',
        latitude: (j['latitude'] as num).toDouble(),
        longitude: (j['longitude'] as num).toDouble(),
        jobTitle: j['job_title'],
        jobId: j['job_id'],
        updatedAt: DateTime.parse(j['updated_at']),
        isCheckedIn: j['is_checked_in'] ?? false,
      );
}

final workerLocationsProvider = FutureProvider<List<WorkerLocation>>((ref) async {
  final client = ref.read(apiClientProvider);
  final response = await client.get('/workers/locations');
  final data = response.data as Map<String, dynamic>;
  final list = data['locations'] as List? ?? [];
  return list.map((e) => WorkerLocation.fromJson(e)).toList();
});

class LiveLocationState {
  final double? latitude;
  final double? longitude;
  final bool isSharing;
  final String? error;

  const LiveLocationState({
    this.latitude,
    this.longitude,
    this.isSharing = false,
    this.error,
  });

  LiveLocationState copyWith({
    double? latitude,
    double? longitude,
    bool? isSharing,
    String? error,
  }) =>
      LiveLocationState(
        latitude: latitude ?? this.latitude,
        longitude: longitude ?? this.longitude,
        isSharing: isSharing ?? this.isSharing,
        error: error ?? this.error,
      );
}

class LiveLocationNotifier extends StateNotifier<LiveLocationState> {
  final ApiClient _client;

  LiveLocationNotifier(this._client) : super(const LiveLocationState());

  Future<void> updateLocation(double lat, double lng) async {
    state = state.copyWith(latitude: lat, longitude: lng, isSharing: true);
    try {
      await _client.patch('/workers/location', data: {
        'latitude': lat,
        'longitude': lng,
      });
    } catch (e) {
      state = state.copyWith(error: e.toString());
    }
  }

  Future<void> stopSharing() async {
    state = state.copyWith(isSharing: false);
  }
}

final liveLocationProvider =
    StateNotifierProvider<LiveLocationNotifier, LiveLocationState>((ref) {
  return LiveLocationNotifier(ref.read(apiClientProvider));
});
