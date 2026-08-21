import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'dart:async';
import 'package:provider/provider.dart';
import 'package:printing/printing.dart';
import 'package:geolocator/geolocator.dart';
import '../services/auth_provider.dart';
import '../services/api_service.dart';
import '../models/models.dart';
import 'login_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide User;
class DriverDashboard extends StatefulWidget {
  const DriverDashboard({super.key});
  @override
  State<DriverDashboard> createState() => _DriverDashboardState();
}

class _DriverDashboardState extends State<DriverDashboard> {
  
  int _tabIndex = 0;
  final ApiService _api = ApiService();
  bool _loading = true;

  int? _driverId;

  List<Map<String, dynamic>> _pendingPayments = [];
  bool _loadingPayments = false;

  // Booking IDs for which a ticket PDF is currently being generated.
  final Set<int> _generatingTicketIds = {};

  // Bus IDs for which a daily passenger-list manifest PDF is currently
  // being generated. Separate from _generatingTicketIds since these are
  // two independent PDF features (single ticket vs. bus manifest).
  final Set<int> _generatingManifestBusIds = {};

  // ── Live GPS sharing ────────────────────────────────────────────────────
  // At most one bus can be actively shared at a time per driver session.
  // busId -> periodic position subscription, so toggling one bus off
  // doesn't affect another if the driver switches buses.
  StreamSubscription<Position>? _locationSub;
  int? _sharingBusId;
  int? _startingShareBusId;

// PKT = UTC+5.
DateTime get _pktNow => DateTime.now().toUtc().add(const Duration(hours: 5));

Future<int> _getDriverId() async {
  if (_driverId != null) return _driverId!;

  final userId = context.read<AuthProvider>().currentUser!.id;

  debugPrint("Current User ID = $userId");

  final driver = await Supabase.instance.client
      .from('drivers')
      .select('id,user_id')
      .eq('user_id', userId)
      .maybeSingle();

  debugPrint("Driver Row = $driver");

  if (driver == null) {
    throw Exception("Driver not found");
  }

  _driverId = driver['id'];

  return _driverId!;
}

  Map<String, dynamic> _stats = {};
  List<Map<String, dynamic>> _buses      = [];
  List<Map<String, dynamic>> _routes     = [];
  List<Map<String, dynamic>> _passengers = [];

  // Filter passengers by date
  String? _filterDate; // null = all dates

  // Add Bus form
  final _busNumCtrl = TextEditingController();
  final _busTransportCtrl = TextEditingController();
  final _busCapCtrl = TextEditingController();
  int?   _busRouteId;
  // Timing/fare now live on the bus/transport, not the route.
  final _busTimeCtrl = TextEditingController();
  final _busArrCtrl  = TextEditingController();
  final _busFareCtrl = TextEditingController();
  String _busDays    = 'Daily';

  // All routes in the system (not just this driver's) — used so a driver
  // can add a new bus/transport to any existing route, since a route can
  // now be served by multiple buses/drivers.
  List<Map<String, dynamic>> _allRoutes = [];

  // Add Route form — a route is just the source/destination city pair now.
  final _routeSrcCtrl  = TextEditingController();
  final _routeDstCtrl  = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

 Future<void> _loadAll() async {
  try {
    setState(() {
      _loading = true;
      _loadingPayments = true;
    });

    debugPrint("===== LOAD ALL START =====");

    final driverId = await _getDriverId();

    debugPrint("Driver ID: $driverId");

    // Load pending payments first
    _pendingPayments = await _api.getDriverPendingPayments(
      driverId: driverId,
    );

    debugPrint("Pending Payments: ${_pendingPayments.length}");

    // Load remaining dashboard data
    final results = await Future.wait([
      _api.getDriverStats(driverId: driverId),
      _api.getDriverBuses(driverId: driverId),
      _api.getDriverRoutes(driverId: driverId),
      _api.getDriverPassengers(driverId: driverId),
      _api.getPassengerRoutes(), // all system routes, for the "add bus" route picker
    ]);

    debugPrint("API calls completed");

    if (!mounted) return;

    setState(() {
      _stats = results[0] as Map<String, dynamic>;
      _buses = results[1] as List<Map<String, dynamic>>;
      _routes = results[2] as List<Map<String, dynamic>>;
      _passengers = results[3] as List<Map<String, dynamic>>;
      _allRoutes = results[4] as List<Map<String, dynamic>>;

      _loadingPayments = false;
      _loading = false;
    });
  } catch (e, s) {
    debugPrint("LOAD ERROR: $e");
    debugPrintStack(stackTrace: s);

    if (!mounted) return;

    setState(() {
      _loading = false;
      _loadingPayments = false;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(e.toString())),
    );
  }
}

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? Colors.red : Colors.green,
      behavior: SnackBarBehavior.floating,
    ));
  }

  Future<void> _addBus() async {
    if (_busNumCtrl.text.trim().isEmpty) { _snack('Bus number required.', error: true); return; }
    if (_busTransportCtrl.text.trim().isEmpty) { _snack('Transport name required.', error: true); return; }
    if (_busRouteId == null) { _snack('Please select a route for this bus.', error: true); return; }
    if (_busTimeCtrl.text.trim().isEmpty) { _snack('Departure time required.', error: true); return; }
    if (_busFareCtrl.text.trim().isEmpty) { _snack('Fare required.', error: true); return; }
    final cap = int.tryParse(_busCapCtrl.text.trim()) ?? 50;
    final driverId = await _getDriverId();
    final res = await _api.driverAddBus(
      busNumber: _busNumCtrl.text.trim(),
      transportName: _busTransportCtrl.text.trim(),
      routeId: _busRouteId!,
      driverId: driverId,
      capacity: cap,
      departureTime: _busTimeCtrl.text.trim(),
      arrivalTime: _busArrCtrl.text.trim().isEmpty ? null : _busArrCtrl.text.trim(),
      fare: double.tryParse(_busFareCtrl.text.trim()) ?? 0,
      daysOfWeek: _busDays,
    );
    _snack(res['message'] ?? 'Done.', error: res['status'] != 'success');
    if (res['status'] == 'success') {
      _busNumCtrl.clear(); _busTransportCtrl.clear(); _busCapCtrl.clear();
      _busTimeCtrl.clear(); _busArrCtrl.clear(); _busFareCtrl.clear();
      setState(() { _busRouteId = null; _busDays = 'Daily'; });
    }
    _loadAll();
  }

  Future<void> _updateBusStatus(Map<String, dynamic> b, String newStatus) async {
    final driverId = await _getDriverId();
    final res = await _api.driverUpdateBusStatus(b['id'] as int, newStatus, driverId: driverId);
    _snack(res['message'] ?? 'Done.', error: res['status'] != 'success');
    _loadAll();
  }

  // ── Walk-in seat sale ────────────────────────────────────────────────────
  // Lets a driver mark a seat as booked when a passenger pays cash directly
  // to them without using the app. Creates a normal booking (so it shows up
  // everywhere bookings do) with the driver's own account as the recorded
  // passenger_id, but with the real walk-in passenger's name/phone saved on
  // the booking, and the payment already marked 'confirmed' since the cash
  // was collected on the spot.
  static final RegExp _walkInNameRegex =
      RegExp(r"^[a-zA-Z\u00C0-\u017F][a-zA-Z\u00C0-\u017F .'-]{1,49}$");
  static final RegExp _walkInPhoneRegex = RegExp(r'^(\+92|0)3\d{9}$');

  // ── Live GPS sharing ────────────────────────────────────────────────────
  Future<void> _toggleLocationSharing(Map<String, dynamic> bus) async {
    final busId = bus['id'] as int;

    // Already sharing this bus -> turn it off.
    if (_sharingBusId == busId) {
      await _locationSub?.cancel();
      _locationSub = null;
      final driverId = await _getDriverId();
      await _api.driverStopSharingLocation(busId: busId, driverId: driverId);
      setState(() => _sharingBusId = null);
      _snack('Stopped sharing location for ${bus['transport_name'] ?? bus['bus_number']}.');
      return;
    }

    // Switching from a different bus -> stop that one first.
    if (_sharingBusId != null) {
      await _locationSub?.cancel();
      _locationSub = null;
      final driverId = await _getDriverId();
      await _api.driverStopSharingLocation(busId: _sharingBusId!, driverId: driverId);
      setState(() => _sharingBusId = null);
    }

    setState(() => _startingShareBusId = busId);
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        _snack('Location permission is required to share your position with passengers.', error: true);
        return;
      }
      if (!await Geolocator.isLocationServiceEnabled()) {
        _snack('Please turn on device location services.', error: true);
        return;
      }

      final driverId = await _getDriverId();

      // Push an immediate fix so passengers aren't staring at a blank map,
      // then keep updating as the driver moves.
      final first = await Geolocator.getCurrentPosition();
      await _api.driverUpdateBusLocation(
        busId: busId, driverId: driverId,
        latitude: first.latitude, longitude: first.longitude,
        heading: first.heading, speed: first.speed,
      );

      _locationSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 20),
      ).listen((pos) async {
        await _api.driverUpdateBusLocation(
          busId: busId, driverId: driverId,
          latitude: pos.latitude, longitude: pos.longitude,
          heading: pos.heading, speed: pos.speed,
        );
      });

      setState(() => _sharingBusId = busId);
      _snack('Now sharing live location for ${bus['transport_name'] ?? bus['bus_number']}.');
    } catch (e) {
      _snack('Could not start location sharing: $e', error: true);
    } finally {
      setState(() => _startingShareBusId = null);
    }
  }

  Future<void> _showSellSeatSheet(Map<String, dynamic> bus) async {
    final busId = bus['id'] as int;
    final busCapacity = (bus['capacity'] as num?)?.toInt() ?? 50;
    final route = bus['routes'];
    final routeId = (route is Map) ? route['id'] as int? : null;
    if (routeId == null) {
      _snack('This bus is not assigned to a route yet.', error: true);
      return;
    }

    DateTime date = _pktNow;
    List<int> booked = [];
    int? selectedSeat;
    bool loadingSeats = true;
    bool submitting = false;
    final nameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    String? selectedGender;

    Future<void> loadSeats(StateSetter setModalState) async {
      setModalState(() => loadingSeats = true);
      final dateStr = '${date.year}-${date.month.toString().padLeft(2,'0')}-${date.day.toString().padLeft(2,'0')}';
      final res = await _api.getSeatAvailability(busId, dateStr);
      booked = List<int>.from(res['booked'] ?? []);
      setModalState(() { loadingSeats = false; selectedSeat = null; });
    }

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (sheetCtx) => StatefulBuilder(builder: (sheetCtx, setModalState) {
        if (loadingSeats && booked.isEmpty && selectedSeat == null) {
          // Kick off the first load once the sheet is actually visible.
          Future.microtask(() => loadSeats(setModalState));
        }
        final dateStr = '${date.day.toString().padLeft(2,'0')}/${date.month.toString().padLeft(2,'0')}/${date.year}';
        return Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(sheetCtx).viewInsets.bottom),
          child: DraggableScrollableSheet(
            initialChildSize: 0.85, maxChildSize: 0.95, minChildSize: 0.5,
            expand: false,
            builder: (_, scrollCtrl) => SingleChildScrollView(
              controller: scrollCtrl,
              padding: const EdgeInsets.all(20),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('Sell a Seat — ${bus['transport_name'] ?? bus['bus_number']}',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                const Text('For a passenger who paid you cash directly, without using the app.',
                    style: TextStyle(fontSize: 11, color: Colors.grey)),
                const SizedBox(height: 14),
                InkWell(
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: sheetCtx, initialDate: date, firstDate: _pktNow,
                      lastDate: _pktNow.add(const Duration(days: 90)),
                    );
                    if (picked != null) {
                      date = picked;
                      await loadSeats(setModalState);
                    }
                  },
                  child: InputDecorator(
                    decoration: const InputDecoration(labelText: 'Travel Date', prefixIcon: Icon(Icons.calendar_today_outlined)),
                    child: Text(dateStr),
                  ),
                ),
                const SizedBox(height: 14),
                const Text('Tap a seat to sell it', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                const SizedBox(height: 8),
                Row(children: [
                  _sellSheetLegend(Colors.blue.shade50, Colors.blue.shade700, 'Available'),
                  const SizedBox(width: 10),
                  _sellSheetLegend(Colors.amber.shade600, Colors.white, 'Selected'),
                  const SizedBox(width: 10),
                  _sellSheetLegend(Colors.grey.shade300, Colors.grey.shade600, 'Booked'),
                ]),
                const SizedBox(height: 10),
                loadingSeats
                    ? const Center(child: Padding(padding: EdgeInsets.all(20), child: CircularProgressIndicator()))
                    : Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 8, runSpacing: 8,
                        children: List.generate(busCapacity, (i) {
                          final seat = i + 1;
                          final isBooked = booked.contains(seat);
                          final isSelected = selectedSeat == seat;
                          Color bg, fg;
                          if (isSelected) { bg = Colors.amber.shade600; fg = Colors.white; }
                          else if (isBooked) { bg = Colors.grey.shade300; fg = Colors.grey.shade600; }
                          else { bg = Colors.blue.shade50; fg = Colors.blue.shade700; }
                          return GestureDetector(
                            onTap: isBooked ? null : () => setModalState(() => selectedSeat = isSelected ? null : seat),
                            child: Container(
                              width: 36, height: 36,
                              decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
                              child: Stack(alignment: Alignment.center, children: [
                                Icon(Icons.event_seat, size: 18, color: fg),
                                Positioned(bottom: 1, child: Text('$seat', style: TextStyle(fontSize: 7, fontWeight: FontWeight.bold, color: fg))),
                              ]),
                            ),
                          );
                        }),
                      ),
                if (selectedSeat != null) ...[
                  const SizedBox(height: 18),
                  Text('Seat $selectedSeat — Passenger Details', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  const SizedBox(height: 8),
                  TextField(
                    controller: nameCtrl,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(labelText: 'Full Name', prefixIcon: Icon(Icons.person_outline), border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: phoneCtrl,
                    keyboardType: TextInputType.phone,
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9+\s-]'))],
                    decoration: const InputDecoration(labelText: 'Phone Number', hintText: 'e.g. 03001234567', prefixIcon: Icon(Icons.phone_outlined), border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(
                      child: ChoiceChip(
                        label: const Text('Male'),
                        avatar: const Icon(Icons.male, size: 16),
                        selected: selectedGender == 'Male',
                        onSelected: (_) => setModalState(() => selectedGender = 'Male'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ChoiceChip(
                        label: const Text('Female'),
                        avatar: const Icon(Icons.female, size: 16),
                        selected: selectedGender == 'Female',
                        onSelected: (_) => setModalState(() => selectedGender = 'Female'),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    icon: submitting
                        ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.check_circle_outline),
                    label: Text(submitting ? 'Selling…' : 'Confirm Cash Sale'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.teal.shade800, foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: submitting ? null : () async {
                      final name = nameCtrl.text.trim();
                      final phone = phoneCtrl.text.trim();
                      if (!_walkInNameRegex.hasMatch(name)) {
                        _snack('Enter a valid passenger name.', error: true); return;
                      }
                      if (!_walkInPhoneRegex.hasMatch(phone.replaceAll(RegExp(r'[\s-]'), ''))) {
                        _snack('Enter a valid phone number (e.g. 03001234567).', error: true); return;
                      }
                      if (selectedGender == null) {
                        _snack('Select the passenger\'s gender.', error: true); return;
                      }
                      setModalState(() => submitting = true);
                      final dateStr2 = '${date.year}-${date.month.toString().padLeft(2,'0')}-${date.day.toString().padLeft(2,'0')}';
                      final res = await _api.bookTicket(
                        routeId: routeId,
                        busId: busId,
                        seatNumber: selectedSeat!,
                        departureDate: dateStr2,
                        passengerId: context.read<AuthProvider>().currentUser!.id,
                        passengerName: name,
                        passengerPhone: phone,
                        passengerGender: selectedGender,
                        paymentStatus: 'confirmed', // cash already collected in person
                        bookingStatus: 'confirmed', // driver is booking it in person — seat is booked immediately, no separate confirmation step
                      );
                      if (res['status'] == 'success') {
                        if (mounted) Navigator.pop(sheetCtx);
                        _snack('Seat $selectedSeat sold and marked booked.');
                        _loadAll();
                      } else {
                        setModalState(() => submitting = false);
                        _snack(res['message'] ?? 'Could not sell this seat.', error: true);
                      }
                    },
                  ),
                ],
                const SizedBox(height: 12),
              ]),
            ),
          ),
        );
      }),
    );
  }

  Widget _sellSheetLegend(Color bg, Color fg, String label) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 14, height: 14, decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(4)),
          child: Icon(Icons.event_seat, size: 9, color: fg)),
      const SizedBox(width: 4),
      Text(label, style: const TextStyle(fontSize: 10, color: Colors.grey)),
    ]);
  }

  // ── Ticket download ──────────────────────────────────────────────────────
  // Reuses the existing ApiService.generateTicketPdf(bookingId: ...) that
  // already powers the Passenger Dashboard's ticket download flow.
  bool _canDownloadTicket(Map<String, dynamic> p) {
    final bookingId = p['id'];
    if (bookingId == null) return false;

    // The dashboard's derived maps use camelCase keys, but the raw booking
    // row (spread in from Supabase) may also carry the original snake_case
    // columns — check both so eligibility works regardless of which one is
    // populated.
    final paymentStatus =
        (p['paymentStatus'] ?? p['payment_status'] ?? '').toString().toLowerCase();
    final bookingStatus =
        (p['bookingStatus'] ?? p['booking_status'] ?? '').toString().toLowerCase();

    final paymentOk = paymentStatus == 'paid' ||
        paymentStatus == 'success' ||
        paymentStatus == 'confirmed';
    final bookingOk = bookingStatus != 'cancelled';

    return paymentOk && bookingOk;
  }

  Future<void> _downloadTicket(dynamic rawBookingId) async {
    if (rawBookingId == null) {
      _snack('Ticket unavailable: missing booking ID.', error: true);
      return;
    }
    final int? bookingId =
        rawBookingId is int ? rawBookingId : int.tryParse(rawBookingId.toString());
    if (bookingId == null) {
      _snack('Ticket unavailable: invalid booking ID.', error: true);
      return;
    }
    if (_generatingTicketIds.contains(bookingId)) return;

    setState(() => _generatingTicketIds.add(bookingId));
    try {
      final driverId = await _getDriverId();
      final bytes = await _api.generateTicketPdf(bookingId: bookingId, driverId: driverId);
      await Printing.layoutPdf(onLayout: (_) async => bytes);
    } catch (e) {
      _snack('Failed to generate ticket: $e', error: true);
    } finally {
      if (mounted) setState(() => _generatingTicketIds.remove(bookingId));
    }
  }

  Widget _ticketButton(Map<String, dynamic> p) {
    if (!_canDownloadTicket(p)) return const SizedBox.shrink();

    final bookingId = p['id'];
    final isGenerating = _generatingTicketIds.contains(bookingId);

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: isGenerating ? null : () => _downloadTicket(bookingId),
          icon: isGenerating
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.download_outlined, size: 16),
          label: Text(
            isGenerating ? 'Preparing…' : 'Download Ticket',
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.teal.shade800,
            side: BorderSide(color: Colors.teal.shade300),
            padding: const EdgeInsets.symmetric(vertical: 10),
          ),
        ),
      ),
    );
  }

  // ── Daily bus passenger-list (manifest) download ───────────────────────────
  // Reuses ApiService.generateBusPassengerListPdf(...), a separate feature
  // from the single-passenger ticket above. Driver picks a travel date, then
  // the manifest is built server-side (Supabase) scoped to that bus + date,
  // and the API enforces that the bus actually belongs to this driver.
  String _formatDateForDb(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _downloadBusPassengerList(Map<String, dynamic> bus) async {
    final busId = bus['id'] as int;

    final selectedDate = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (selectedDate == null) return;
    final travelDate = _formatDateForDb(selectedDate);

    if (_generatingManifestBusIds.contains(busId)) return;
    setState(() => _generatingManifestBusIds.add(busId));
    try {
      final driverId = await _getDriverId();
      final bytes = await _api.generateBusPassengerListPdf(
        busId: busId,
        travelDate: travelDate,
        driverId: driverId, // enforces "assigned buses only"
      );
      await Printing.layoutPdf(onLayout: (_) async => bytes);
    } catch (e) {
      _snack('Failed to generate passenger list: $e', error: true);
    } finally {
      if (mounted) setState(() => _generatingManifestBusIds.remove(busId));
    }
  }

  Future<void> _addRoute() async {
    if (_routeSrcCtrl.text.trim().isEmpty || _routeDstCtrl.text.trim().isEmpty) {
      _snack('Source and destination are required.', error: true); return;
    }
    final res  = await _api.driverAddRoute(
      source: _routeSrcCtrl.text.trim(),
      destination: _routeDstCtrl.text.trim(),
    );
    _snack(res['message'] ?? 'Route created — add a bus to it below (with its own timing and fare) to start taking bookings.',
        error: res['status'] != 'success');
    if (res['status'] == 'success') {
      for (final c in [_routeSrcCtrl,_routeDstCtrl]) c.clear();
    }
    _loadAll();
  }

  // ── Get unique departure dates from passenger list ─────────────────────────
  List<String> get _departureDates {
    final dates = _passengers
        .map((p) => p['departureDate']?.toString() ?? '')
        .where((d) => d.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    return dates;
  }

  // ── Filter passengers by selected date ────────────────────────────────────
  List<Map<String, dynamic>> get _filteredPassengers {
    if (_filterDate == null) return _passengers;
    return _passengers.where((p) => p['departureDate']?.toString() == _filterDate).toList();
  }

  /// True when [p]'s cash payment is actually confirmed/paid, so it should
  /// count toward "Cash collected". The DB stores lowercase payment_status
  /// values (e.g. 'confirmed', from confirmCashPayment()/bookTicket()),
  /// while some UI-facing text elsewhere uses Title Case ('Paid') — so this
  /// match is case-insensitive and accepts any of the equivalent "paid"
  /// values instead of a single exact string. Pending, failed, or unset
  /// payments (and cancelled bookings, which the API query already excludes
  /// from `_passengers` entirely) are excluded.
  bool _isCashPaid(Map<String, dynamic> p) {
    final status = (p['paymentStatus'] ?? '').toString().trim().toLowerCase();
    return status == 'paid' || status == 'confirmed' || status == 'success';
  }

  @override
  Widget build(BuildContext context) {
    final auth = Provider.of<AuthProvider>(context);
    final user = auth.currentUser;
    if (user == null) return const LoginScreen();

    final views = [
      _buildOverviewView(user),
      _buildPassengersView(),
      _buildManageView(),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Operator Portal', style: TextStyle(fontWeight: FontWeight.w900)),
        backgroundColor: Colors.teal.shade800,
        foregroundColor: Colors.white,
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loadAll),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () async {
              await auth.logout();
              if (context.mounted) Navigator.of(context).pushReplacement(
                  MaterialPageRoute(builder: (_) => const LoginScreen()));
            },
          ),
        ],
      ),
      body: _loading ? const Center(child: CircularProgressIndicator()) : views[_tabIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _tabIndex,
        selectedItemColor: Colors.teal.shade800,
        onTap: (i) => setState(() => _tabIndex = i),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.dashboard_outlined), label: 'Overview'),
          BottomNavigationBarItem(icon: Icon(Icons.people_outline),     label: 'Passengers'),
          BottomNavigationBarItem(icon: Icon(Icons.build_outlined),     label: 'Manage'),
        ],
      ),
    );
  }

  // ── Tab 0: Overview ────────────────────────────────────────────────────────
  Widget _buildOverviewView(User user) {
    final revenue = _toDouble(_stats['revenue']);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // Driver card
        Card(
          color: Colors.teal.shade900,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Padding(padding: const EdgeInsets.all(16), child: Row(children: [
            CircleAvatar(
              backgroundColor: Colors.white24,
              child: Text(user.name.isNotEmpty ? user.name[0] : 'D',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(width: 16),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(user.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
              const Text('Driver  •  Cash collection on boarding',
                  style: TextStyle(color: Colors.white70, fontSize: 11)),
            ])),
          ])),
        ),
        const SizedBox(height: 20),
        // Stats grid
        GridView.count(
          crossAxisCount: 2, shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          childAspectRatio: 1.5, crossAxisSpacing: 10, mainAxisSpacing: 10,
          children: [
            _statTile('My Buses',     '${_stats["myBuses"]     ?? 0}', Icons.directions_bus_outlined, Colors.blue),
            _statTile('My Routes',    '${_stats["myRoutes"]    ?? 0}', Icons.route_outlined,          Colors.indigo),
            _statTile('Tickets Sold', '${_stats["ticketsSold"] ?? 0}', Icons.confirmation_number_outlined, Colors.purple),
            _statTile('Revenue',      'PKR ${revenue.toStringAsFixed(0)}', Icons.payments_outlined,      Colors.green),
          ],
        ),
        const SizedBox(height: 24),
        // Upcoming passengers (next departure date)
        if (_departureDates.isNotEmpty) ...[
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Upcoming Passengers', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              Text(_departureDates.first,
                  style: TextStyle(color: Colors.teal.shade700, fontWeight: FontWeight.bold, fontSize: 12)),
            ],
          ),
          const SizedBox(height: 10),
          ..._passengers
              .where((p) => p['departureDate']?.toString() == _departureDates.first)
              .map((p) => _passengerTile(p)),
        ],
        const SizedBox(height: 24),
        const Text('My Buses', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(height: 10),
        if (_buses.isEmpty)
          const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('No buses assigned yet.'))),
        ..._buses.map((b) {
          final busId = b['id'] as int;
          final isGeneratingManifest = _generatingManifestBusIds.contains(busId);
          return Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Column(children: [
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: Colors.teal.shade50,
                  child: Icon(Icons.directions_bus, color: Colors.teal.shade700),
                ),
                title: Text('${b['transport_name'] ?? 'Unnamed Transport'}  •  ${b['bus_number'] ?? ''}',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text(
                    'Route: ${(() { final r = b['routes']; return (r is Map && r['source'] != null) ? '${r['source']} → ${r['destination']}' : 'No route'; })()}\n'
                    'Dep: ${b['departure_time'] ?? '-'}${(b['arrival_time'] ?? '').toString().isNotEmpty ? "  •  Arr: ${b['arrival_time']}" : ""}  •  PKR ${_toDouble(b['fare']).toStringAsFixed(0)}\n'
                    'Capacity: ${b['capacity']} seats  •  Status: ${b['status']} • ${b['days_of_week'] ?? 'Daily'}'),
                isThreeLine: true,
                trailing: PopupMenuButton<String>(
                  onSelected: (s) => _updateBusStatus(b, s),
                  itemBuilder: (_) => ['active', 'maintenance', 'retired']
                      .map((s) => PopupMenuItem(value: s, child: Text(_cap(s))))
                      .toList(),
                  child: Chip(
                    label: Text(b['status'] ?? '', style: const TextStyle(fontSize: 11)),
                    backgroundColor: b['status'] == 'active' ? Colors.green.shade50 : Colors.orange.shade50,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: SizedBox(
                  width: double.infinity,
                  child: Builder(builder: (_) {
                    final busId = b['id'] as int;
                    final isThisSharing = _sharingBusId == busId;
                    final isThisStarting = _startingShareBusId == busId;
                    final isBusy = _startingShareBusId != null;
                    return OutlinedButton.icon(
                      onPressed: isBusy ? null : () => _toggleLocationSharing(b),
                      icon: isThisStarting
                          ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                          : Icon(isThisSharing ? Icons.gps_off : Icons.gps_fixed, size: 16,
                              color: isThisSharing ? Colors.red.shade700 : Colors.teal.shade800),
                      label: Text(isThisStarting
                          ? 'Starting…'
                          : isThisSharing
                              ? 'Stop Sharing Location'
                              : 'Share Live Location'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: isThisSharing ? Colors.red.shade700 : Colors.teal.shade800,
                        side: BorderSide(color: isThisSharing ? Colors.red.shade300 : Colors.teal.shade300),
                      ),
                    );
                  }),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () => _showSellSeatSheet(b),
                    icon: const Icon(Icons.event_seat, size: 16),
                    label: const Text('Sell Seat (Walk-in / Cash)'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.teal.shade700, foregroundColor: Colors.white,
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: isGeneratingManifest ? null : () => _downloadBusPassengerList(b),
                    icon: isGeneratingManifest
                        ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.picture_as_pdf_outlined, size: 16),
                    label: Text(isGeneratingManifest ? 'Preparing…' : 'Download Passenger List'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.teal.shade800,
                      side: BorderSide(color: Colors.teal.shade300),
                    ),
                  ),
                ),
              ),
            ]),
          );
        }),
        const SizedBox(height: 20),
        const Text('My Routes', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(height: 10),
        if (_routes.isEmpty)
          const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('No routes yet.'))),
        ..._routes.map((r) {
          final routeId = r['id'];
          final myBuses = _buses.where((b) => b['route_id'] == routeId).toList();
          final busSummary = myBuses.isEmpty
              ? 'No buses of mine assigned yet'
              : myBuses.map((b) {
                  final name = b['transport_name'] ?? b['bus_number'] ?? '-';
                  final dep = (b['departure_time'] ?? '').toString();
                  final fare = _toDouble(b['fare']);
                  return '$name (${dep.isNotEmpty ? "$dep, " : ""}PKR ${fare.toStringAsFixed(0)})';
                }).join(', ');
          return Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: Colors.indigo.shade50,
                child: Icon(Icons.route, color: Colors.indigo.shade700),
              ),
              title: Text('${r["source"]} → ${r["destination"]}',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
              subtitle: Text('My buses: $busSummary'),
              isThreeLine: true,
            ),
          );
        }),
      const SizedBox(height: 24),

const Divider(),

const SizedBox(height: 12),

const Text(
  'Pending Cash Payments',
  style: TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.bold,
  ),
),

const SizedBox(height: 10),

_loadingPayments
    ? const Center(child: CircularProgressIndicator())
    : _pendingPayments.isEmpty
        ? const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Center(
                child: Text('No pending cash payments'),
              ),
            ),
          )
        : Column(
            children: _pendingPayments.map((payment) {
              final bookingId = payment['bookingId'] as int?;
              return Card(
                margin: const EdgeInsets.only(bottom: 10),
                child: ListTile(
                  leading: const CircleAvatar(
                    child: Icon(Icons.payments),
                  ),
                  title: Text(
                    payment['passengerName']?.toString() ?? 'Passenger',
                  ),
                  subtitle: Text(
                    'Seat ${payment['bookings']?['seat_number']}'
                    '${(payment['passengerPhone']?.toString().isNotEmpty ?? false) ? '\n${payment['passengerPhone']}' : ''}'
                    '\nAmount: PKR ${payment['amount']}',
                  ),
                  isThreeLine: true,
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    IconButton(
                      tooltip: 'Reject booking (releases the seat)',
                      icon: const Icon(Icons.close, color: Colors.red),
                      onPressed: bookingId == null ? null : () async {
                        final confirmReject = await showDialog<bool>(
                          context: context,
                          builder: (_) => AlertDialog(
                            title: const Text('Reject Booking?'),
                            content: const Text('This releases the seat back to available and cancels the passenger\'s booking.'),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                              TextButton(onPressed: () => Navigator.pop(context, true),
                                  child: const Text('Reject', style: TextStyle(color: Colors.red))),
                            ],
                          ),
                        );
                        if (confirmReject != true) return;
                        final driverId = await _getDriverId();
                        final res = await _api.driverRejectBooking(bookingId: bookingId, driverId: driverId);
                        if (!mounted) return;
                        _snack(res['message'] ?? 'Booking rejected — seat released.', error: res['status'] != 'success');
                        await _loadAll();
                      },
                    ),
                    ElevatedButton(
                      onPressed: bookingId == null ? null : () async {
                        final driverId = await _getDriverId();
                        final res = await _api.driverConfirmBooking(bookingId: bookingId, driverId: driverId);
                        if (!mounted) return;
                        if (res['status'] == 'success') {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Booking confirmed — seat is now booked.')),
                          );
                          await _loadAll();
                        } else {
                          _snack(res['message'] ?? 'Could not confirm this booking.', error: true);
                        }
                      },
                      child: const Text('Confirm'),
                    ),
                  ]),
                ),
              );
            }).toList(),
          ), ]),
    );
  }

  // ── Tab 1: Passengers (date-wise) ─────────────────────────────────────────
  Widget _buildPassengersView() {
    final dates     = _departureDates;
    final filtered  = _filteredPassengers;
    // Cash collected for the currently selected date (or all dates when no
    // filter is applied) — recomputed on every build from `filtered`, which
    // is itself derived live from `_passengers` + `_filterDate`, so both
    // this total and the passenger count below update immediately whenever
    // the date filter chip changes. Only confirmed/paid cash payments count
    // — pending, failed, and unpaid bookings are excluded via _isCashPaid,
    // and cancelled bookings never appear in `_passengers` at all (the API
    // query already filters them out).
    final totalCash = filtered
        .where(_isCashPaid)
        .fold(0.0, (s, p) => s + _toDouble(p['amount'] ?? 0));

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // Date filter bar
      Container(
        color: Colors.teal.shade50,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Filter by Departure Date',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.teal)),
          const SizedBox(height: 6),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                // "All" chip
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: FilterChip(
                    label: Text('All (${_passengers.length})'),
                    selected: _filterDate == null,
                    selectedColor: Colors.teal.shade100,
                    onSelected: (_) => setState(() => _filterDate = null),
                  ),
                ),
                // One chip per departure date
                ...dates.map((date) {
                  final count = _passengers.where((p) => p['departureDate'] == date).length;
                  return Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: FilterChip(
                      label: Text('$date ($count)'),
                      selected: _filterDate == date,
                      selectedColor: Colors.teal.shade100,
                      onSelected: (_) => setState(() => _filterDate = date),
                    ),
                  );
                }),
              ],
            ),
          ),
        ]),
      ),
      // Summary strip
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        color: Colors.white,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('${filtered.length} passenger(s)',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            Row(children: [
              Icon(Icons.payments_outlined, size: 14, color: Colors.green.shade700),
              const SizedBox(width: 4),
              Text('Cash collected: PKR ${totalCash.toStringAsFixed(0)}',
                  style: TextStyle(color: Colors.green.shade700,
                      fontWeight: FontWeight.bold, fontSize: 12)),
            ]),
          ],
        ),
      ),
      const Divider(height: 1),
      Expanded(
        child: filtered.isEmpty
            ? Center(child: Text(
                _filterDate != null
                    ? 'No passengers on $_filterDate'
                    : 'No bookings on your buses yet.'))
            : ListView.builder(
                padding: const EdgeInsets.all(12),
                itemCount: filtered.length,
                itemBuilder: (_, i) => _passengerTile(filtered[i]),
              ),
      ),
    ]);
  }

  Widget _passengerTile(Map<String, dynamic> p) {
    final pyStatus   = (p['paymentStatus'] ?? 'Pending').toString();
    final method     = (p['paymentMethod'] ?? 'Cash').toString();
    final src        = p['source']        ?? '';
    final dst        = p['destination']   ?? '';
    final bus        = p['busNumber']     ?? '-';
    final transport  = (p['transportName'] ?? '').toString();
    final seat       = p['seatNumber']    ?? '-';
    final bkStatus   = p['bookingStatus'] ?? '-';
    final gender     = (p['passengerGender'] ?? '').toString();
    final depDate = p['departureDate']?.toString() ?? '-';

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // Header
          Row(children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: Colors.teal.shade50,
              child: Text(
                seat.toString(),
                style: TextStyle(fontWeight: FontWeight.bold, color: Colors.teal.shade800, fontSize: 13),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(child: Text(p['passengerName'] ?? 'Unknown',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13), overflow: TextOverflow.ellipsis)),
                if (gender.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  _genderBadge(gender),
                ],
              ]),
              if (p['passengerEmail'] != null && p['passengerEmail'].toString().isNotEmpty)
                Text(p['passengerEmail'].toString(),
                    style: const TextStyle(fontSize: 10, color: Colors.grey)),
              if (p['passengerPhone'] != null && p['passengerPhone'].toString().isNotEmpty)
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.phone, size: 10, color: Colors.grey.shade600),
                  const SizedBox(width: 3),
                  Text(p['passengerPhone'].toString(),
                      style: const TextStyle(fontSize: 10, color: Colors.grey)),
                ]),
            ])),
            _pChip(bkStatus),
          ]),
          const SizedBox(height: 8),
          // Route + date
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: Colors.grey.shade50, borderRadius: BorderRadius.circular(8)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('$src → $dst', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
              Row(children: [
                Icon(Icons.calendar_today, size: 11, color: Colors.indigo.shade600),
                const SizedBox(width: 4),
                Text('Travel: $depDate',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11,
                        color: Colors.indigo.shade700)),
                const SizedBox(width: 12),
                Icon(Icons.directions_bus, size: 11, color: Colors.grey.shade600),
                const SizedBox(width: 4),
                Text(transport.isNotEmpty && transport != '-' ? '$transport ($bus)' : bus,
                    style: const TextStyle(fontSize: 11, color: Colors.grey)),
              ]),
            ]),
          ),
          const SizedBox(height: 6),
          // Payment status
          Row(children: [
            Icon(Icons.payments_outlined, size: 13, color: Colors.grey.shade600),
            const SizedBox(width: 4),
            Text('$method payment: ',
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
            _pChip(pyStatus == 'Paid' || pyStatus == 'Success' ? 'Paid' : pyStatus),
          ]),
          // Ticket download (only shown for eligible confirmed/paid bookings)
          _ticketButton(p),
        ]),
      ),
    );
  }

  // ── Tab 2: Manage ─────────────────────────────────────────────────────────
  Widget _buildManageView() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // Add Bus card
        Card(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Padding(padding: const EdgeInsets.all(16), child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Text('Register a New Bus', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              const Text('Buses you register are automatically assigned to you. Pick the route this bus/transport will serve.',
                  style: TextStyle(color: Colors.grey, fontSize: 11)),
              const SizedBox(height: 12),
              TextField(controller: _busNumCtrl, decoration: const InputDecoration(labelText: 'Bus Number (e.g. BUS-104)')),
              TextField(controller: _busTransportCtrl, decoration: const InputDecoration(
                  labelText: 'Transport Name', hintText: 'e.g. Daewoo Express, Faisal Movers')),
              TextField(controller: _busCapCtrl, decoration: const InputDecoration(labelText: 'Capacity (default 50)'), keyboardType: TextInputType.number),
              DropdownButtonFormField<int>(
                value: _busRouteId,
                hint: const Text('Select Route'),
                isExpanded: true,
                items: _allRoutes.map((r) => DropdownMenuItem<int>(
                  value: r['id'] as int,
                  child: Text('${r['source']} → ${r['destination']}', overflow: TextOverflow.ellipsis),
                )).toList(),
                onChanged: (v) => setState(() => _busRouteId = v),
                decoration: const InputDecoration(labelText: 'Route'),
              ),
              const SizedBox(height: 6),
              const Text('This transport\'s own schedule & price', style: TextStyle(fontSize: 11, color: Colors.grey)),
              TextField(controller: _busTimeCtrl, decoration: const InputDecoration(labelText: 'Departure Time (HH:MM:SS)')),
              TextField(controller: _busArrCtrl,  decoration: const InputDecoration(labelText: 'Arrival Time (HH:MM:SS) — optional')),
              DropdownButtonFormField<String>(
                value: _busDays,
                decoration: const InputDecoration(labelText: 'Days of Operation'),
                items: ['Daily','Weekdays','Weekends','Mon,Wed,Fri','Tue,Thu','Mon,Tue,Wed,Thu,Fri','Sat,Sun']
                    .map((d) => DropdownMenuItem(value: d, child: Text(d))).toList(),
                onChanged: (v) => setState(() => _busDays = v!),
              ),
              TextField(controller: _busFareCtrl, decoration: const InputDecoration(labelText: 'Fare (PKR)'), keyboardType: TextInputType.number),
              const SizedBox(height: 14),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.teal.shade800, foregroundColor: Colors.white),
                onPressed: _addBus, child: const Text('Add Bus to My Fleet'),
              ),
            ],
          )),
        ),
        const SizedBox(height: 20),
        // Add Route card
        Card(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Padding(padding: const EdgeInsets.all(16), child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Text('Create a New Route', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              const Text('A route is just the source/destination city pair. Create it here, then assign a bus to it above — each bus sets its own timing and fare.',
                  style: TextStyle(color: Colors.grey, fontSize: 11)),
              const SizedBox(height: 12),
              TextField(controller: _routeSrcCtrl,  decoration: const InputDecoration(labelText: 'Source')),
              TextField(controller: _routeDstCtrl,  decoration: const InputDecoration(labelText: 'Destination')),
              const SizedBox(height: 14),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.indigo, foregroundColor: Colors.white),
                onPressed: _addRoute, child: const Text('Create Route'),
              ),
            ],
          )),
        ),
      ]),
    );
  }

  Widget _statTile(String title, String val, IconData icon, Color color) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(padding: const EdgeInsets.all(12), child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: color, size: 24),
          const SizedBox(height: 8),
          Text(title, style: const TextStyle(color: Colors.grey, fontSize: 9, fontWeight: FontWeight.bold)),
          const SizedBox(height: 2),
          Text(val,   style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
        ],
      )),
    );
  }

  Widget _genderBadge(String gender) {
    final isMale = gender == 'Male';
    final color = isMale ? Colors.blue : Colors.pink;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: color.shade50, borderRadius: BorderRadius.circular(6)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(isMale ? Icons.male : Icons.female, size: 10, color: color.shade700),
        const SizedBox(width: 2),
        Text(gender, style: TextStyle(fontSize: 9, color: color.shade700, fontWeight: FontWeight.w600)),
      ]),
    );
  }

  Widget _pChip(String status) {
    Color bg, fg;
    final s = status.toLowerCase();
    if (s == 'confirmed' || s == 'paid' || s == 'success') { bg = Colors.green.shade50; fg = Colors.green.shade800; }
    else if (s == 'cancelled' || s == 'failed')            { bg = Colors.red.shade50;   fg = Colors.red.shade800;   }
    else                                                    { bg = Colors.orange.shade50; fg = Colors.orange.shade800; }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(status, style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: fg)),
    );
  }

  String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  double _toDouble(dynamic v) {
    if (v == null) return 0.0;
    if (v is double) return v;
    if (v is int)    return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0.0;
    return 0.0;
  }

  @override
  void dispose() {
    _locationSub?.cancel();
    for (final c in [_busNumCtrl,_busTransportCtrl,_busCapCtrl,_busTimeCtrl,_busArrCtrl,_busFareCtrl,
                     _routeSrcCtrl,_routeDstCtrl]) c.dispose();
    super.dispose();
  }
}