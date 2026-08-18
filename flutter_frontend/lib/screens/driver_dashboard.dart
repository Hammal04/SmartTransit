import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:printing/printing.dart';
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
  final _busCapCtrl = TextEditingController();

  // Add Route form
  int?   _routeBusId;
  final _routeSrcCtrl  = TextEditingController();
  final _routeDstCtrl  = TextEditingController();
  final _routeTimeCtrl = TextEditingController();
  final _routeArrCtrl  = TextEditingController();
  final _routeFareCtrl = TextEditingController();
  String _routeDays    = 'Daily';

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
    ]);

    debugPrint("API calls completed");

    if (!mounted) return;

    setState(() {
      _stats = results[0] as Map<String, dynamic>;
      _buses = results[1] as List<Map<String, dynamic>>;
      _routes = results[2] as List<Map<String, dynamic>>;
      _passengers = results[3] as List<Map<String, dynamic>>;

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
    final cap = int.tryParse(_busCapCtrl.text.trim()) ?? 50;
    final driverId = await _getDriverId();
    final res = await _api.driverAddBus(busNumber: _busNumCtrl.text.trim(), driverId: driverId, capacity: cap);
    _snack(res['message'] ?? 'Done.', error: res['status'] != 'success');
    if (res['status'] == 'success') { _busNumCtrl.clear(); _busCapCtrl.clear(); }
    _loadAll();
  }

  Future<void> _updateBusStatus(Map<String, dynamic> b, String newStatus) async {
    final driverId = await _getDriverId();
    final res = await _api.driverUpdateBusStatus(b['id'] as int, newStatus, driverId: driverId);
    _snack(res['message'] ?? 'Done.', error: res['status'] != 'success');
    _loadAll();
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
    if (_routeBusId == null || _routeSrcCtrl.text.trim().isEmpty ||
        _routeDstCtrl.text.trim().isEmpty || _routeTimeCtrl.text.trim().isEmpty ||
        _routeFareCtrl.text.trim().isEmpty) {
      _snack('All route fields are required.', error: true); return;
    }
    final fare = double.tryParse(_routeFareCtrl.text.trim()) ?? 0;
    final res  = await _api.driverAddRoute(
      busId: _routeBusId!, source: _routeSrcCtrl.text.trim(),
      destination: _routeDstCtrl.text.trim(), departureTime: _routeTimeCtrl.text.trim(),
      arrivalTime: _routeArrCtrl.text.trim().isEmpty ? null : _routeArrCtrl.text.trim(),
      daysOfWeek: _routeDays, fare: fare,
    );
    _snack(res['message'] ?? 'Done.', error: res['status'] != 'success');
    if (res['status'] == 'success') {
      for (final c in [_routeSrcCtrl,_routeDstCtrl,_routeTimeCtrl,_routeArrCtrl,_routeFareCtrl]) c.clear();
      setState(() { _routeBusId = null; _routeDays = 'Daily'; });
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
                title: Text(b['bus_number'] ?? '', style: const TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text('Capacity: ${b['capacity']} seats  •  Status: ${b['status']}'),
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
          final arr  = r['arrival_time']?.toString() ?? '';
          final dep  = r['departure_time']?.toString() ?? '-';
          final days = r['days_of_week']?.toString() ?? 'Daily';
          final fare = _toDouble(r['fare']);
          return Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: Colors.indigo.shade50,
                child: Icon(Icons.route, color: Colors.indigo.shade700),
              ),
              title: Text('${r["source"]} → ${r["destination"]}',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
              subtitle: Text(
                '$days\nDep: $dep${arr.isNotEmpty ? "  •  Arr: $arr" : ""}  •  PKR ${fare.toStringAsFixed(0)}',
              ),
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
                  trailing: ElevatedButton(
                    onPressed: () async {
                      final ok = await _api.confirmCashPayment(
                        paymentId: payment['id'],
                      );

                      if (ok) {
                        if (!mounted) return;

                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Payment confirmed successfully',
                            ),
                          ),
                        );

                        await _loadAll();
                      }
                    },
                    child: const Text('Confirm'),
                  ),
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
    final seat       = p['seatNumber']    ?? '-';
    final bkStatus   = p['bookingStatus'] ?? '-';
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
              Text(p['passengerName'] ?? 'Unknown',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
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
                Text(bus, style: const TextStyle(fontSize: 11, color: Colors.grey)),
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
              const Text('Buses you register are automatically assigned to you.',
                  style: TextStyle(color: Colors.grey, fontSize: 11)),
              const SizedBox(height: 12),
              TextField(controller: _busNumCtrl, decoration: const InputDecoration(labelText: 'Bus Number (e.g. BUS-104)')),
              TextField(controller: _busCapCtrl, decoration: const InputDecoration(labelText: 'Capacity (default 50)'), keyboardType: TextInputType.number),
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
              const Text('Add Route for My Bus', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              const Text('You can only add routes for buses assigned to you.',
                  style: TextStyle(color: Colors.grey, fontSize: 11)),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                value: _routeBusId,
                hint: const Text('Select Your Bus'),
                items: _buses.map((b) => DropdownMenuItem<int>(
                    value: b['id'] as int, child: Text(b['bus_number'] ?? ''))).toList(),
                onChanged: (v) => setState(() => _routeBusId = v),
                decoration: const InputDecoration(labelText: 'Bus'),
              ),
              TextField(controller: _routeSrcCtrl,  decoration: const InputDecoration(labelText: 'Source')),
              TextField(controller: _routeDstCtrl,  decoration: const InputDecoration(labelText: 'Destination')),
              TextField(controller: _routeTimeCtrl, decoration: const InputDecoration(labelText: 'Departure Time (HH:MM:SS)')),
              TextField(controller: _routeArrCtrl,  decoration: const InputDecoration(labelText: 'Arrival Time (HH:MM:SS) — optional')),
              const SizedBox(height: 6),
              DropdownButtonFormField<String>(
                value: _routeDays,
                decoration: const InputDecoration(labelText: 'Days of Operation'),
                items: ['Daily','Weekdays','Weekends','Mon,Wed,Fri','Tue,Thu','Mon,Tue,Wed,Thu,Fri','Sat,Sun']
                    .map((d) => DropdownMenuItem(value: d, child: Text(d))).toList(),
                onChanged: (v) => setState(() => _routeDays = v!),
              ),
              TextField(controller: _routeFareCtrl, decoration: const InputDecoration(labelText: 'Fare (PKR)'), keyboardType: TextInputType.number),
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
    for (final c in [_busNumCtrl,_busCapCtrl,_routeSrcCtrl,_routeDstCtrl,
                     _routeTimeCtrl,_routeArrCtrl,_routeFareCtrl]) c.dispose();
    super.dispose();
  }
}