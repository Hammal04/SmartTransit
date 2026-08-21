import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../services/api_service.dart';

/// Live GPS tracking for a single passenger's booked bus.
///
/// Privacy model: this screen is only ever opened with a bookingId, never
/// a bus id directly. ApiService.getPassengerTrackableBus() re-verifies on
/// every load that the booking actually belongs to the current passenger
/// and isn't cancelled before returning which bus to track — so a
/// passenger can never be handed a bus id for a trip that isn't theirs,
/// and the realtime stream that follows is scoped to that one bus only.
class TrackBusScreen extends StatefulWidget {
  final int bookingId;
  final int passengerId;

  const TrackBusScreen({super.key, required this.bookingId, required this.passengerId});

  @override
  State<TrackBusScreen> createState() => _TrackBusScreenState();
}

class _TrackBusScreenState extends State<TrackBusScreen> {
  final ApiService _api = ApiService();
  final MapController _mapController = MapController();

  Map<String, dynamic>? _busInfo;
  StreamSubscription<Map<String, dynamic>?>? _locationSub;
  Map<String, dynamic>? _location;
  bool _loading = true;
  bool _notAuthorized = false;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final info = await _api.getPassengerTrackableBus(
        bookingId: widget.bookingId,
        passengerId: widget.passengerId,
      );
      if (!mounted) return;
      if (info == null) {
        setState(() { _loading = false; _notAuthorized = true; });
        return;
      }
      setState(() { _busInfo = info; _loading = false; });

      _locationSub = _api.streamBusLocation(info['busId'] as int).listen((loc) {
        if (!mounted) return;
        // On the very first location fix, FlutterMap hasn't been built yet
        // (it only appears once _location is non-null), so MapController
        // isn't attached — calling .move() here throws and can blank the
        // whole page on web. Let MapOptions.initialCenter handle placing the
        // map correctly on its first build instead; only .move() on later
        // updates, once the map definitely already exists.
        final hadFixBefore = _location != null;
        setState(() => _location = loc);
        if (loc != null && hadFixBefore) {
          final lat = (loc['latitude'] as num).toDouble();
          final lng = (loc['longitude'] as num).toDouble();
          try {
            _mapController.move(LatLng(lat, lng), _mapController.camera.zoom);
          } catch (_) {
            // Defensive: never let a camera-move failure crash the screen.
          }
        }
      }, onError: (e) {
        if (mounted) setState(() => _loadError = e.toString());
      });
    } catch (e) {
      if (mounted) setState(() { _loading = false; _loadError = e.toString(); });
    }
  }

  @override
  void dispose() {
    _locationSub?.cancel();
    super.dispose();
  }

  String _timeAgo(String? iso) {
    if (iso == null) return '';
    final t = DateTime.tryParse(iso);
    if (t == null) return '';
    final diff = DateTime.now().toUtc().difference(t.toUtc());
    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    return '${diff.inHours}h ago';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Track My Bus'),
        backgroundColor: Colors.teal.shade800,
        foregroundColor: Colors.white,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _notAuthorized
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      "This booking can't be tracked — it may be cancelled or not belong to your account.",
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : _busInfo == null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.error_outline, size: 40, color: Colors.red.shade400),
                          const SizedBox(height: 12),
                          Text(
                            _loadError == null
                                ? 'Could not load tracking info.'
                                : 'Could not load tracking info:\n$_loadError',
                            textAlign: TextAlign.center,
                          ),
                        ]),
                      ),
                    )
                  : Column(children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    color: Colors.teal.shade50,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${_busInfo!['transportName']}  •  ${_busInfo!['busNumber']}',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                      const SizedBox(height: 2),
                      Text('${_busInfo!['source']} → ${_busInfo!['destination']}  •  Driver: ${_busInfo!['driverName']}',
                          style: const TextStyle(fontSize: 12, color: Colors.black87)),
                    ]),
                  ),
                  Expanded(
                    child: _location == null
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Column(mainAxisSize: MainAxisSize.min, children: [
                                Icon(Icons.gps_not_fixed, size: 48, color: Colors.grey.shade400),
                                const SizedBox(height: 12),
                                const Text(
                                  "Your driver hasn't started sharing live location yet.",
                                  textAlign: TextAlign.center,
                                  style: TextStyle(color: Colors.grey),
                                ),
                                const SizedBox(height: 4),
                                const Text(
                                  'This updates automatically once they do — no need to refresh.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(color: Colors.grey, fontSize: 12),
                                ),
                              ]),
                            ),
                          )
                        : Stack(children: [
                            FlutterMap(
                              mapController: _mapController,
                              options: MapOptions(
                                initialCenter: LatLng(
                                  (_location!['latitude'] as num).toDouble(),
                                  (_location!['longitude'] as num).toDouble(),
                                ),
                                initialZoom: 15,
                              ),
                              children: [
                                TileLayer(
                                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                                  userAgentPackageName: 'com.smarttransit.app',
                                ),
                                MarkerLayer(markers: [
                                  Marker(
                                    point: LatLng(
                                      (_location!['latitude'] as num).toDouble(),
                                      (_location!['longitude'] as num).toDouble(),
                                    ),
                                    width: 44,
                                    height: 44,
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: Colors.teal.shade700,
                                        shape: BoxShape.circle,
                                        border: Border.all(color: Colors.white, width: 2),
                                        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)],
                                      ),
                                      child: const Icon(Icons.directions_bus, color: Colors.white, size: 22),
                                    ),
                                  ),
                                ]),
                              ],
                            ),
                            Positioned(
                              left: 12, right: 12, bottom: 12,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(10),
                                  boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 6)],
                                ),
                                child: Row(children: [
                                  Icon(Icons.circle, size: 10, color: Colors.green.shade600),
                                  const SizedBox(width: 6),
                                  const Text('Live', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                                  const Spacer(),
                                  Text('Updated ${_timeAgo(_location!['updated_at']?.toString())}',
                                      style: const TextStyle(fontSize: 11, color: Colors.grey)),
                                ]),
                              ),
                            ),
                          ]),
                  ),
                ]),
    );
  }
}
