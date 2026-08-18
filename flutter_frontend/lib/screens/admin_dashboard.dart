import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:printing/printing.dart';
import '../services/auth_provider.dart';
import '../services/api_service.dart';
import '../models/models.dart';
import 'login_screen.dart';

class AdminDashboard extends StatefulWidget {
  const AdminDashboard({super.key});
  @override
  State<AdminDashboard> createState() => _AdminDashboardState();
}

class _AdminDashboardState extends State<AdminDashboard> {
  int _tabIndex = 0;
  final ApiService _api = ApiService();
  bool _loading = true;

  Map<String, dynamic> _stats          = {};
  Map<String, dynamic> _paymentSummary = {};
  List<Map<String, dynamic>> _drivers  = [];
  List<Map<String, dynamic>> _buses    = [];
  List<Map<String, dynamic>> _routes   = [];
  List<Map<String, dynamic>> _bookings = [];
  List<Map<String, dynamic>> _payments = [];

  // Passengers tab state
  String? _passengerDateFilter; // null = all
  String  _passengerSearch     = '';

  // Payments tab state
  String _payFilter = 'All';

  // Booking IDs for which a ticket PDF is currently being generated.
  final Set<int> _generatingTicketIds = {};

  // Bus IDs for which a daily passenger-list manifest PDF is currently
  // being generated. Separate from _generatingTicketIds since these are
  // two independent PDF features (single ticket vs. bus manifest).
  final Set<int> _generatingManifestBusIds = {};

  // Hire Driver form
  final _hireNameCtrl  = TextEditingController();
  final _hireEmailCtrl = TextEditingController();
  final _hirePassCtrl  = TextEditingController();
  final _hireLicCtrl   = TextEditingController();

  // Add Bus form
  final _busNumberCtrl = TextEditingController();
  final _busTransportCtrl = TextEditingController();
  final _busCapCtrl    = TextEditingController();
  int?  _busDrvId;
  int?  _busRouteId;

  // Add Route form
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
    setState(() => _loading = true);
    debugPrint("1");
final stats = await _api.getAdminStats();

debugPrint("2");
final drivers = await _api.getAdminDrivers();
debugPrint("DRIVERS COUNT = ${drivers.length}");
debugPrint(drivers.toString());

debugPrint("3");
final buses = await _api.getAdminBuses();

debugPrint("4");
final routes = await _api.getAdminRoutes();

debugPrint("5");
final passengers = await _api.getAdminPassengers();

debugPrint("6");
final payments = await _api.getAdminAllPayments();

debugPrint("7");
final summary = await _api.getPaymentSummary();

debugPrint("DONE");
    if (!mounted) return;

setState(() {
  _stats = stats;
  _drivers = drivers;
  _buses = buses;
  _routes = routes;
  _bookings = passengers;
  _payments = payments;
  _paymentSummary = summary;
  _loading = false;
});
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? Colors.red : Colors.green,
      behavior: SnackBarBehavior.floating,
    ));
  }

  // ── All unique departure dates in bookings ─────────────────────────────────
  List<String> get _departureDates {
    final dates = _bookings
        .map((b) => b['departure_date']?.toString() ?? '')
        .where((d) => d.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    return dates;
  }

  // ── Bookings filtered by date + optional search ────────────────────────────
  List<Map<String, dynamic>> get _filteredBookings {
    var list = _passengerDateFilter == null
        ? _bookings
        : _bookings.where((b) =>
            b['departure_date']?.toString() == _passengerDateFilter).toList();
    if (_passengerSearch.isNotEmpty) {
      final q = _passengerSearch.toLowerCase();
      list = list.where((b) =>
        (b['passengerName'] ?? '').toString().toLowerCase().contains(q) ||
        (b['source']        ?? '').toString().toLowerCase().contains(q) ||
        (b['destination']   ?? '').toString().toLowerCase().contains(q) ||
        (b['busNumber']     ?? '').toString().toLowerCase().contains(q)
      ).toList();
    }
    return list;
  }

  // ── Driver actions ─────────────────────────────────────────────────────────
  Future<void> _hireDriver() async {
    if ([_hireNameCtrl,_hireEmailCtrl,_hirePassCtrl,_hireLicCtrl].any((c) => c.text.trim().isEmpty)) {
      _snack('All fields required.', error: true); return;
    }
    final res = await _api.hireDriver(name: _hireNameCtrl.text.trim(),
        email: _hireEmailCtrl.text.trim(), password: _hirePassCtrl.text.trim(),
        license: _hireLicCtrl.text.trim());
    _snack(res['message'] ?? 'Done.', error: res['status'] != 'success');
    if (res['status'] == 'success') {
      for (final c in [_hireNameCtrl,_hireEmailCtrl,_hirePassCtrl,_hireLicCtrl]) c.clear();
      _loadAll();
    }
  }

  Future<void> _toggleDriver(Map<String, dynamic> d) async {
    final s = d['status'] == 'active' ? 'suspended' : 'active';
    final res = await _api.updateDriverStatus(d['id'] as int, s);
    _snack(res['message'] ?? 'Done.', error: res['status'] != 'success');
    _loadAll();
  }

  Future<void> _removeDriver(Map<String, dynamic> d) async {
    final ok = await showDialog<bool>(context: context,
      builder: (_) => AlertDialog(
        title: const Text('Remove Driver'),
        content: Text('Remove ${d['name']} permanently?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true),
              child: const Text('Remove', style: TextStyle(color: Colors.red))),
        ],
      ));
    if (ok != true) return;
    final res = await _api.removeDriver(d['id'] as int);
    _snack(res['message'] ?? 'Done.', error: res['status'] != 'success');
    _loadAll();
  }

  // ── Bus actions ────────────────────────────────────────────────────────────
  Future<void> _addBus() async {
    if (_busNumberCtrl.text.trim().isEmpty) { _snack('Bus number required.', error: true); return; }
    if (_busTransportCtrl.text.trim().isEmpty) { _snack('Transport name required.', error: true); return; }
    if (_busRouteId == null) { _snack('Please select a route for this bus.', error: true); return; }
    final res = await _api.adminAddBus(
        busNumber: _busNumberCtrl.text.trim(),
        transportName: _busTransportCtrl.text.trim(),
        routeId: _busRouteId,
        driverId: _busDrvId,
        capacity: int.tryParse(_busCapCtrl.text.trim()) ?? 50);
    _snack(res['message'] ?? 'Done.', error: res['status'] != 'success');
    if (res['status'] == 'success') {
      _busNumberCtrl.clear(); _busTransportCtrl.clear(); _busCapCtrl.clear();
      setState(() { _busDrvId = null; _busRouteId = null; });
    }
    _loadAll();
  }

  Future<void> _deleteBus(Map<String, dynamic> b) async {
    final ok = await showDialog<bool>(context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Bus'),
        content: Text('Delete ${b['bus_number']}?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete', style: TextStyle(color: Colors.red))),
        ],
      ));
    if (ok != true) return;
    final res = await _api.adminDeleteBus(b['id'] as int);
    _snack(res['message'] ?? 'Done.', error: res['status'] != 'success');
    _loadAll();
  }

  // ── Route actions ──────────────────────────────────────────────────────────
  Future<void> _addRoute() async {
    if ([_routeSrcCtrl,_routeDstCtrl,_routeTimeCtrl,_routeFareCtrl]
        .any((c) => c.text.trim().isEmpty)) {
      _snack('All route fields required.', error: true); return;
    }
    final res = await _api.adminAddRoute(
      source: _routeSrcCtrl.text.trim(),
      destination: _routeDstCtrl.text.trim(), departureTime: _routeTimeCtrl.text.trim(),
      arrivalTime: _routeArrCtrl.text.trim().isEmpty ? null : _routeArrCtrl.text.trim(),
      daysOfWeek: _routeDays, fare: double.tryParse(_routeFareCtrl.text.trim()) ?? 0,
    );
    _snack(res['message'] ?? 'Done.', error: res['status'] != 'success');
    if (res['status'] == 'success') {
      for (final c in [_routeSrcCtrl,_routeDstCtrl,_routeTimeCtrl,_routeArrCtrl,_routeFareCtrl]) c.clear();
      setState(() { _routeDays = 'Daily'; });
    }
    _loadAll();
  }

  Future<void> _deleteRoute(Map<String, dynamic> r) async {
    final ok = await showDialog<bool>(context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Route'),
        content: Text('Delete ${r['source']} → ${r['destination']}?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete', style: TextStyle(color: Colors.red))),
        ],
      ));
    if (ok != true) return;
    final res = await _api.adminDeleteRoute(r['id'] as int);
    _snack(res['message'] ?? 'Done.', error: res['status'] != 'success');
    _loadAll();
  }

  // ── Ticket download ──────────────────────────────────────────────────────
  // Reuses the existing ApiService.generateTicketPdf(bookingId: ...) that
  // already powers the Passenger Dashboard's ticket download flow.
  bool _canDownloadTicket(Map<String, dynamic> b) {
    final bookingId = b['id'];
    if (bookingId == null) return false;

    // getAdminPassengers() derives 'paymentStatus' (camelCase), but the raw
    // booking row spread into the map may also carry snake_case columns.
    // Check both so eligibility works regardless of which is populated.
    final paymentStatus =
        (b['paymentStatus'] ?? b['payment_status'] ?? '').toString().toLowerCase();
    final bookingStatus =
        (b['booking_status'] ?? b['bookingStatus'] ?? '').toString().toLowerCase();

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
      final bytes = await _api.generateTicketPdf(bookingId: bookingId);
      await Printing.layoutPdf(onLayout: (_) async => bytes);
    } catch (e) {
      _snack('Failed to generate ticket: $e', error: true);
    } finally {
      if (mounted) setState(() => _generatingTicketIds.remove(bookingId));
    }
  }

  Widget _ticketButton(Map<String, dynamic> b) {
    if (!_canDownloadTicket(b)) return const SizedBox.shrink();

    final bookingId = b['id'];
    final isGenerating = _generatingTicketIds.contains(bookingId);

    return Padding(
      padding: const EdgeInsets.only(top: 10),
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
            foregroundColor: Colors.indigo.shade900,
            side: BorderSide(color: Colors.indigo.shade200),
            padding: const EdgeInsets.symmetric(vertical: 10),
          ),
        ),
      ),
    );
  }

  // ── Daily bus passenger-list (manifest) download ───────────────────────────
  // Reuses ApiService.generateBusPassengerListPdf(...), a separate feature
  // from the single-passenger ticket above. Admin picks any bus + any travel
  // date; no driverId is passed, so the API does not restrict by ownership.
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
      final bytes = await _api.generateBusPassengerListPdf(
        busId: busId,
        travelDate: travelDate,
        // No driverId — Admin may pull any bus's manifest.
      );
      await Printing.layoutPdf(onLayout: (_) async => bytes);
    } catch (e) {
      _snack('Failed to generate passenger list: $e', error: true);
    } finally {
      if (mounted) setState(() => _generatingManifestBusIds.remove(busId));
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final auth = Provider.of<AuthProvider>(context);
    if (auth.currentUser == null) return const LoginScreen();

    final views = [
      _buildAnalyticsView(),
      _buildPassengersView(),
      _buildDriversView(),
      _buildBusesView(),
      _buildRoutesView(),
      _buildPaymentsView(),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin Dashboard', style: TextStyle(fontWeight: FontWeight.w900)),
        backgroundColor: Colors.indigo.shade900,
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
        selectedItemColor: Colors.indigo.shade900,
        unselectedItemColor: Colors.grey,
        type: BottomNavigationBarType.fixed,
        onTap: (i) => setState(() => _tabIndex = i),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.bar_chart_outlined),       label: 'Analytics'),
          BottomNavigationBarItem(icon: Icon(Icons.people_alt_outlined),      label: 'Passengers'),
          BottomNavigationBarItem(icon: Icon(Icons.badge_outlined),           label: 'Drivers'),
          BottomNavigationBarItem(icon: Icon(Icons.directions_bus_outlined),  label: 'Buses'),
          BottomNavigationBarItem(icon: Icon(Icons.route_outlined),           label: 'Routes'),
          BottomNavigationBarItem(icon: Icon(Icons.payments_outlined),        label: 'Payments'),
        ],
      ),
    );
  }

  // ── Tab 0: Analytics ──────────────────────────────────────────────────────
  Widget _buildAnalyticsView() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        GridView.count(
          crossAxisCount: 2, shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          childAspectRatio: 1.45, crossAxisSpacing: 10, mainAxisSpacing: 10,
          children: [
            _statTile('Tickets Sold',    '${(_stats["totalTicketsSold"] ?? 0)}',                             Icons.confirmation_number_outlined, Colors.purple),
            _statTile('Total Revenue',   'PKR ${_toDouble(_stats['totalRevenue']).toStringAsFixed(0)}',      Icons.payments_outlined,            Colors.green),
            _statTile('Active Drivers',  '${(_stats["activeDrivers"] ?? 0)}',                               Icons.person_outline,               Colors.orange),
            _statTile('Active Buses',    '${(_stats["activeBuses"] ?? 0)}',                                 Icons.directions_bus_outlined,      Colors.blue),
            _statTile('Active Routes',   '${(_stats["activeRoutes"] ?? 0)}',                               Icons.map_outlined,                 Colors.teal),
            _statTile('Pending Payments','${(_paymentSummary["pendingCount"] ?? _stats["pendingPayments"] ?? 0)}', Icons.pending_actions_outlined, Colors.red),
          ],
        ),
        const SizedBox(height: 20),
        // Payment KPIs
        Card(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          color: Colors.indigo.shade50,
          child: Padding(padding: const EdgeInsets.all(16), child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Payment Overview', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(child: _miniKpi('Paid',    '${_paymentSummary["successCount"] ?? 0}', Colors.green)),
                Expanded(child: _miniKpi('Pending', '${_paymentSummary["pendingCount"] ?? 0}', Colors.orange)),
                Expanded(child: _miniKpi('Failed',  '${_paymentSummary["failedCount"]  ?? 0}', Colors.red)),
              ]),
            ],
          )),
        ),
        const SizedBox(height: 20),
        // Upcoming bookings summary (next 5 departure dates)
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Upcoming Bookings', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            TextButton(
              onPressed: () => setState(() => _tabIndex = 1),
              child: const Text('View All →'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_bookings.isEmpty)
          const Center(child: Padding(padding: EdgeInsets.all(16), child: Text('No bookings yet.'))),
        // _bookings already comes from getAdminPassengers(), which excludes
        // cancelled bookings at the query level — so this list is already
        // "upcoming, non-cancelled" bookings only.
        ..._bookings.take(8).map((b) => _bookingRow(b)),
      ]),
    );
  }

  // ── Tab 1: Passengers (date-wise) ─────────────────────────────────────────
  Widget _buildPassengersView() {
    final dates    = _departureDates;
    final filtered = _filteredBookings;
    final totalOnDate = filtered.length;
    // Paid = payments whose payment_status is 'confirmed' (the DB's
    // canonical "Paid" value). Was previously reading the nonexistent key
    // 'payment_status' (the flattened field from getAdminPassengers() is
    // called 'paymentStatus') and comparing against 'paid' instead of
    // 'confirmed' — so this always evaluated to 0.
    final paidOnDate  = filtered.where((b) =>
        (b['paymentStatus'] ?? '').toString().toLowerCase() == 'confirmed').length;

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // Date filter chips
      Container(
        color: Colors.indigo.shade900,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Filter by Departure Date',
              style: TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              _dateChip('All (${_bookings.length})', null),
              ...dates.map((d) {
                final cnt = _bookings
                    .where((b) => b['departure_date']?.toString() == d)
                    .length;
                return _dateChip('${_shortDate(d)} ($cnt)', d);
              }),
            ]),
          ),
        ]),
      ),
      // Search bar
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
        child: TextField(
          decoration: InputDecoration(
            hintText: 'Search passenger, route, bus…',
            prefixIcon: const Icon(Icons.search, size: 20),
            suffixIcon: _passengerSearch.isNotEmpty
                ? IconButton(icon: const Icon(Icons.clear, size: 18),
                    onPressed: () => setState(() => _passengerSearch = ''))
                : null,
            isDense: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
          onChanged: (v) => setState(() => _passengerSearch = v),
        ),
      ),
      // Summary strip
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        color: Colors.grey.shade50,
        child: Row(children: [
          Icon(Icons.people_alt, size: 16, color: Colors.indigo.shade700),
          const SizedBox(width: 6),
          Text('$totalOnDate passenger(s)',
              style: TextStyle(fontWeight: FontWeight.bold, color: Colors.indigo.shade800)),
          const Spacer(),
          Icon(Icons.payments_outlined, size: 14, color: Colors.green.shade700),
          const SizedBox(width: 4),
          Text('$paidOnDate paid',
              style: TextStyle(color: Colors.green.shade700, fontWeight: FontWeight.w600, fontSize: 12)),
        ]),
      ),
      const Divider(height: 1),
      // Passenger list
      Expanded(
        child: filtered.isEmpty
            ? Center(child: Text(
                _passengerDateFilter != null
                    ? 'No passengers on $_passengerDateFilter'
                    : 'No bookings yet.'))
            : ListView.builder(
                padding: const EdgeInsets.all(12),
                itemCount: filtered.length,
                itemBuilder: (_, i) => _passengerCard(filtered[i]),
              ),
      ),
    ]);
  }

  Widget _dateChip(String label, String? date) {
    final selected = _passengerDateFilter == date;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: FilterChip(
        label: Text(label, style: TextStyle(
            fontSize: 11,
            color: selected ? Colors.indigo.shade900 : Colors.white)),
        selected: selected,
        selectedColor: Colors.white,
        backgroundColor: Colors.indigo.shade700,
        onSelected: (_) => setState(() { _passengerDateFilter = date; _passengerSearch = ''; }),
      ),
    );
  }

  Widget _passengerCard(Map<String, dynamic> b) {
    // getAdminPassengers() flattens the joined payment/bus data under
    // camelCase keys ('paymentStatus', 'busNumber') — reading the
    // snake_case originals here previously always fell through to the
    // '??' defaults ('Pending' / '-'), even when the underlying payment
    // was confirmed and the bus was known.
    final pStatus  = (b['paymentStatus'] ?? 'Pending').toString();
    final isPaid   = pStatus.toLowerCase() == 'confirmed';
    final bkStatus = (b['booking_status'] ?? 'Pending').toString();
    final depDate  = b['departure_date']?.toString() ?? '';
    final src      = b['source']       ?? '';
    final dst      = b['destination']  ?? '';
    final bus      = b['busNumber']    ?? '-';
    final transport = (b['transportName'] ?? '-').toString();
    final seat     = b['seat_number']  ?? '-';
    final name     = b['passengerName']  ?? 'Unknown';
    final email    = b['passengerEmail'] ?? '';
    final phone    = (b['passengerPhone'] ?? '').toString();
    final amount   = _toDouble(b['amount']);

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // Header: passenger + booking status
          Row(children: [
            CircleAvatar(
              radius: 20,
              backgroundColor: Colors.indigo.shade50,
              child: Text(name.isNotEmpty ? name[0].toUpperCase() : '?',
                  style: TextStyle(fontWeight: FontWeight.bold,
                      color: Colors.indigo.shade700, fontSize: 16)),
            ),
            const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
              if (email.isNotEmpty)
                Text(email, style: const TextStyle(fontSize: 10, color: Colors.grey)),
              if (phone.isNotEmpty)
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.phone, size: 10, color: Colors.grey.shade600),
                  const SizedBox(width: 3),
                  Text(phone, style: const TextStyle(fontSize: 10, color: Colors.grey)),
                ]),
            ])),
            _statusChip(bkStatus),
          ]),
          const SizedBox(height: 10),
          // Travel info box
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
                color: Colors.indigo.shade50,
                borderRadius: BorderRadius.circular(10)),
            child: Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('$src → $dst',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                const SizedBox(height: 4),
                Row(children: [
                  Icon(Icons.calendar_today, size: 12, color: Colors.indigo.shade600),
                  const SizedBox(width: 4),
                  Text('Travel Date: $depDate',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12,
                          color: Colors.indigo.shade800)),
                ]),
                Row(children: [
                  Icon(Icons.directions_bus, size: 12, color: Colors.grey.shade600),
                  const SizedBox(width: 4),
                  Text('$transport ($bus)  •  Seat: $seat',
                      style: const TextStyle(fontSize: 11, color: Colors.grey)),
                ]),
              ])),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text('PKR ${amount.toStringAsFixed(0)}',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: isPaid ? Colors.green.shade50 : Colors.orange.shade50,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.payments_outlined, size: 10,
                        color: isPaid ? Colors.green.shade700 : Colors.orange.shade700),
                    const SizedBox(width: 3),
                    Text(isPaid ? 'Cash Paid ✓' : 'Cash Pending',
                        style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold,
                            color: isPaid ? Colors.green.shade800 : Colors.orange.shade800)),
                  ]),
                ),
              ]),
            ]),
          ),
          // Ticket download (only shown for eligible confirmed/paid bookings)
          _ticketButton(b),
        ]),
      ),
    );
  }

  // ── Tab 2: Drivers ────────────────────────────────────────────────────────
  Widget _buildDriversView() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Card(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Padding(padding: const EdgeInsets.all(16), child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Text('Hire New Driver', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              const SizedBox(height: 12),
              TextField(controller: _hireNameCtrl,  decoration: const InputDecoration(labelText: 'Full Name')),
              TextField(controller: _hireEmailCtrl, decoration: const InputDecoration(labelText: 'Email'), keyboardType: TextInputType.emailAddress),
              TextField(controller: _hirePassCtrl,  decoration: const InputDecoration(labelText: 'Temporary Password'), obscureText: true),
              TextField(controller: _hireLicCtrl,   decoration: const InputDecoration(labelText: 'License Number')),
              const SizedBox(height: 14),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.indigo.shade900, foregroundColor: Colors.white),
                onPressed: _hireDriver, child: const Text('Hire Driver'),
              ),
            ],
          )),
        ),
        const SizedBox(height: 20),
        Text('All Drivers (${_drivers.length})', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(height: 10),
        if (_drivers.isEmpty) const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('No drivers yet.'))),
        ..._drivers.map((d) => Card(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: d['status'] == 'active' ? Colors.green.shade50 : Colors.red.shade50,
              child: Icon(Icons.person, color: d['status'] == 'active' ? Colors.green : Colors.red),
            ),
            title: Text(d['name'] ?? '', style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text('${d["license_number"]}\n${d["email"]}\nStatus: ${d["status"]}'),
            isThreeLine: true,
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                tooltip: d['status'] == 'active' ? 'Suspend' : 'Reactivate',
                icon: Icon(d['status'] == 'active' ? Icons.pause_circle_outline : Icons.play_circle_outline,
                    color: d['status'] == 'active' ? Colors.orange : Colors.green),
                onPressed: () => _toggleDriver(d),
              ),
              IconButton(tooltip: 'Remove', icon: const Icon(Icons.delete_outline, color: Colors.red),
                  onPressed: () => _removeDriver(d)),
            ]),
          ),
        )),
      ]),
    );
  }

  // ── Tab 3: Buses ──────────────────────────────────────────────────────────
  Widget _buildBusesView() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Card(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Padding(padding: const EdgeInsets.all(16), child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Text('Add New Bus', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              const SizedBox(height: 12),
              TextField(controller: _busNumberCtrl, decoration: const InputDecoration(labelText: 'Bus Number')),
              TextField(controller: _busTransportCtrl, decoration: const InputDecoration(
                  labelText: 'Transport Name', hintText: 'e.g. Daewoo Express, Faisal Movers')),
              TextField(controller: _busCapCtrl,    decoration: const InputDecoration(labelText: 'Capacity'), keyboardType: TextInputType.number),
              DropdownButtonFormField<int>(
                value: _busRouteId,
                hint: const Text('Select Route'),
                isExpanded: true,
                items: _routes.map((r) => DropdownMenuItem<int>(
                  value: r['id'] as int,
                  child: Text('${r['source']} → ${r['destination']}', overflow: TextOverflow.ellipsis),
                )).toList(),
                onChanged: (v) => setState(() => _busRouteId = v),
                decoration: const InputDecoration(labelText: 'Route'),
              ),
              DropdownButtonFormField<int>(
                value: _busDrvId,
                hint: const Text('Assign Driver (optional)'),
                items: _drivers.map((d) => DropdownMenuItem<int>(
  value: d['id'] as int,
  child: Text((d['name'] ?? 'Unknown').toString()),
)).toList(),
                onChanged: (v) => setState(() => _busDrvId = v),
                decoration: const InputDecoration(labelText: 'Driver'),
              ),
              const SizedBox(height: 14),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.indigo.shade900, foregroundColor: Colors.white),
                onPressed: _addBus, child: const Text('Add Bus'),
              ),
            ],
          )),
        ),
        const SizedBox(height: 20),
        Text('All Buses (${_buses.length})', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(height: 10),
        if (_buses.isEmpty) const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('No buses yet.'))),
        ..._buses.map((b) {
          final busId = b['id'] as int;
          final isGeneratingManifest = _generatingManifestBusIds.contains(busId);
          final route = b['routes'];
          final routeLabel = (route is Map && route['source'] != null)
              ? '${route['source']} → ${route['destination']}'
              : 'No route assigned';
          return Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Column(children: [
              ListTile(
                leading: CircleAvatar(backgroundColor: Colors.blue.shade50,
                    child: Icon(Icons.directions_bus, color: Colors.blue.shade700)),
                title: Text('${b['transport_name'] ?? 'Unnamed Transport'}  •  ${b['bus_number'] ?? ''}',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text(
                    'Route: $routeLabel\nCapacity: ${b['capacity']} • Status: ${b['status']}\nDriver: ${(((b['drivers'] ?? {})['users'] ?? {})['name'] ?? 'Unassigned')}'),
                isThreeLine: true,
                trailing: IconButton(icon: const Icon(Icons.delete_outline, color: Colors.red), onPressed: () => _deleteBus(b)),
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
                      foregroundColor: Colors.indigo.shade900,
                      side: BorderSide(color: Colors.indigo.shade200),
                    ),
                  ),
                ),
              ),
            ]),
          );
        }),
      ]),
    );
  }

  // ── Tab 4: Routes ─────────────────────────────────────────────────────────
  Widget _buildRoutesView() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Card(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Padding(padding: const EdgeInsets.all(16), child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Text('Add New Route', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              const SizedBox(height: 12),
              const Text('A route can have multiple buses/transports — add the route here, then assign buses to it from the Buses tab.',
                  style: TextStyle(fontSize: 11, color: Colors.grey)),
              const SizedBox(height: 10),
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
                style: ElevatedButton.styleFrom(backgroundColor: Colors.indigo.shade900, foregroundColor: Colors.white),
                onPressed: _addRoute, child: const Text('Add Route'),
              ),
            ],
          )),
        ),
        const SizedBox(height: 20),
        Text('All Routes (${_routes.length})', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(height: 10),
        if (_routes.isEmpty) const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('No routes yet.'))),
        ..._routes.map((r) {
          final arr  = r['arrival_time']?.toString() ?? '';
          final dep  = r['departure_time']?.toString() ?? '-';
          final days = r['days_of_week']?.toString() ?? 'Daily';
          final fare = _toDouble(r['fare']);
          final busesRaw = r['buses'];
          final busList = busesRaw is List ? List<Map<String, dynamic>>.from(busesRaw) : const <Map<String, dynamic>>[];
          final busSummary = busList.isEmpty
              ? 'No buses assigned yet'
              : busList.map((b) => b['transport_name'] ?? b['bus_number'] ?? '-').join(', ');
          return Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: ListTile(
              leading: CircleAvatar(backgroundColor: Colors.teal.shade50,
                  child: Icon(Icons.route, color: Colors.teal.shade700)),
              title: Text('${r["source"]} → ${r["destination"]}',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
              subtitle: Text(
                '$days\nDep: $dep${arr.isNotEmpty ? "  •  Arr: $arr" : ""}  •  PKR ${fare.toStringAsFixed(0)}\n'
                'Buses (${busList.length}): $busSummary',
              ),
              isThreeLine: true,
              trailing: IconButton(icon: const Icon(Icons.delete_outline, color: Colors.red),
                  onPressed: () => _deleteRoute(r)),
            ),
          );
        }),
      ]),
    );
  }

  // ── Tab 5: Payments ───────────────────────────────────────────────────────
  Widget _buildPaymentsView() {
    final revenue  = _toDouble(_paymentSummary['totalRevenue']);
    final filtered = _payFilter == 'All'
        ? _payments
        : _payments.where((p) => _paymentMatchesFilter(p, _payFilter)).toList();

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        color: Colors.indigo.shade900,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(children: [
          Expanded(child: _payKpi('Revenue (PKR)', '${revenue.toStringAsFixed(0)}', Colors.greenAccent)),
          Expanded(child: _payKpi('Paid',    '${(_paymentSummary["successCount"] ?? 0)}', Colors.lightGreenAccent)),
          Expanded(child: _payKpi('Pending', '${(_paymentSummary["pendingCount"] ?? 0)}', Colors.orangeAccent)),
          Expanded(child: _payKpi('Failed',  '${(_paymentSummary["failedCount"]  ?? 0)}', Colors.redAccent)),
        ]),
      ),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(children: ['All','Paid','Pending','Failed'].map((label) =>
            Padding(padding: const EdgeInsets.only(right: 8), child: FilterChip(
              label: Text(label), selected: _payFilter == label,
              onSelected: (_) => setState(() => _payFilter = label),
              selectedColor: Colors.indigo.shade100,
            ))).toList(),
          ),
        ),
      ),
      Expanded(
        child: filtered.isEmpty
            ? Center(child: Text(_payFilter == 'All' ? 'No payments yet.' : 'No $_payFilter payments.'))
            : ListView.builder(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                itemCount: filtered.length,
                itemBuilder: (_, i) {
                  final p         = filtered[i];
                  final rawStatus = (p['payment_status'] ?? p['status'] ?? 'Pending').toString();
                  // Normalize the DB's lowercase 'confirmed'/'pending'/
                  // 'failed' into the display labels this tab already uses
                  // ('Paid'/'Pending'/'Failed') — previously this compared
                  // the raw lowercase value directly against 'Paid', which
                  // never matched, so every card fell back to the
                  // pending/orange styling regardless of real status.
                  final status  = _displayPaymentStatus(rawStatus);
                  final amount  = _toDouble(p['amount']);
                  final txn     = p['transaction_id']?.toString() ?? '—';
                  final depDate = p['departure_date']?.toString() ?? '';
                  final date    = _shortDate(p['payment_date']?.toString() ?? '');
                  return Card(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    margin: const EdgeInsets.only(bottom: 10),
                    child: Padding(padding: const EdgeInsets.all(12), child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Row(children: [
                          CircleAvatar(radius: 18,
                            backgroundColor: status == 'Paid' ? Colors.green.shade50
                                : status == 'Failed' ? Colors.red.shade50 : Colors.orange.shade50,
                            child: Icon(status == 'Paid' ? Icons.check_circle_outline
                                : status == 'Failed' ? Icons.cancel_outlined : Icons.pending_outlined,
                                size: 20,
                                color: status == 'Paid' ? Colors.green
                                    : status == 'Failed' ? Colors.red : Colors.orange),
                          ),
                          const SizedBox(width: 10),
                          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text('${p["source"] ?? ""} → ${p["destination"] ?? ""}',
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                            Text('${p["passenger_name"] ?? "Unknown"}  •  Seat ${p["seat_number"] ?? "-"}',
                                style: const TextStyle(fontSize: 11, color: Colors.grey)),
                            if ((p['passenger_phone'] ?? '').toString().isNotEmpty)
                              Text('${p["passenger_phone"]}',
                                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
                          ])),
                          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                            Text('PKR ${amount.toStringAsFixed(0)}',
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                            _statusChip(status),
                          ]),
                        ]),
                        const Divider(height: 12),
                        Wrap(spacing: 8, runSpacing: 4, children: [
                          _detailChip('Booking #${p['booking_id'] ?? '-'}', Icons.confirmation_number_outlined),
                          _detailChip('Bus: ${p['bus_number'] ?? '-'}',     Icons.directions_bus_outlined),
                          _detailChip('Cash',                               Icons.payments_outlined),
                          if (depDate.isNotEmpty) _detailChip('Travel: $depDate', Icons.calendar_today_outlined),
                          if (date.isNotEmpty)    _detailChip('Paid: $date',      Icons.event_available_outlined),
                        ]),
                        if (txn != '—') ...[
                          const SizedBox(height: 6),
                          Row(children: [
                            Icon(Icons.tag, size: 12, color: Colors.grey.shade400),
                            const SizedBox(width: 4),
                            Expanded(child: Text('TXN: $txn',
                                style: TextStyle(fontSize: 10, color: Colors.grey.shade600))),
                          ]),
                        ],
                        // Ticket download (only shown for eligible confirmed/paid payments)
                        _ticketButton({
                          'id': p['booking_id'],
                          'paymentStatus': status,
                        }),
                      ],
                    )),
                  );
                },
              ),
      ),
    ]);
  }

  // Normalizes a payment_status coming straight from the DB ('confirmed' /
  // 'pending' / 'failed', or already-friendly 'Paid'/'Pending'/'Failed')
  // into the display label the UI uses.
  String _displayPaymentStatus(String raw) {
    switch (raw.toLowerCase()) {
      case 'confirmed':
      case 'paid':
      case 'success':
        return 'Paid';
      case 'pending':
        return 'Pending';
      case 'failed':
        return 'Failed';
      default:
        return raw;
    }
  }

  // Matches a raw payment row against the Payments-tab filter chips
  // ('Paid' / 'Pending' / 'Failed'). A payment tied to a cancelled booking
  // never counts as Paid here, mirroring ApiService.getPaymentSummary()'s
  // rule so the tab total never contradicts the KPI strip above it.
  bool _paymentMatchesFilter(Map<String, dynamic> p, String filter) {
    final status = (p['payment_status'] ?? p['status'] ?? '').toString().toLowerCase();
    final bookingStatus = (p['bookingStatus'] ?? '').toString().toLowerCase();
    switch (filter) {
      case 'Paid':
        return bookingStatus != 'cancelled' &&
            (status == 'confirmed' || status == 'paid' || status == 'success');
      case 'Pending':
        return status == 'pending';
      case 'Failed':
        return status == 'failed';
      default:
        return true;
    }
  }

  // ── Small helper widgets ──────────────────────────────────────────────────
  Widget _bookingRow(Map<String, dynamic> b) {
    final depDate = b['departure_date']?.toString() ?? '';
    final src     = b['source']       ?? '';
    final dst     = b['destination']  ?? '';
    final bus     = b['busNumber']    ?? '-';
    final transport = (b['transportName'] ?? '').toString();
    final seat    = b['seat_number']  ?? '-';
    final name    = b['passengerName'] ?? 'Unknown';
    final pStatus = (b['paymentStatus'] ?? 'Pending').toString();
    final busLabel = transport.isNotEmpty && transport != '-' ? '$transport ($bus)' : bus;
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        dense: true,
        leading: Container(
          width: 48, height: 48,
          decoration: BoxDecoration(
            color: Colors.indigo.shade50, borderRadius: BorderRadius.circular(10)),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Text(seat.toString(), style: TextStyle(fontWeight: FontWeight.bold,
                color: Colors.indigo.shade800, fontSize: 13)),
            Text('seat', style: TextStyle(fontSize: 8, color: Colors.indigo.shade400)),
          ]),
        ),
        title: Text('$src → $dst', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
        subtitle: Text('$name  •  $busLabel${depDate.isNotEmpty ? "  •  $depDate" : ""}',
            style: const TextStyle(fontSize: 10)),
        trailing: _statusChip(_displayPaymentStatus(pStatus)),
      ),
    );
  }

  Widget _statTile(String title, String val, IconData icon, Color color) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(padding: const EdgeInsets.all(12), child: Column(
        crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center,
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

  Widget _miniKpi(String label, String val, Color color) {
    return Column(children: [
      Text(val, style: TextStyle(fontWeight: FontWeight.w900, fontSize: 22, color: color)),
      Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
    ]);
  }

  Widget _payKpi(String label, String val, Color color) {
    return Column(children: [
      Text(val, style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18, color: color)),
      Text(label, style: const TextStyle(fontSize: 10, color: Colors.white70)),
    ]);
  }

  Widget _statusChip(String status) {
    Color bg, fg;
    final s = status.toLowerCase();
    if (s == 'confirmed' || s == 'paid' || s == 'success') { bg = Colors.green.shade50; fg = Colors.green.shade800; }
    else if (s == 'cancelled' || s == 'failed')            { bg = Colors.red.shade50;   fg = Colors.red.shade800;   }
    else                                                    { bg = Colors.orange.shade50; fg = Colors.orange.shade800; }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(status, style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: fg)),
    );
  }

  Widget _detailChip(String label, IconData icon) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 12, color: Colors.grey),
      const SizedBox(width: 4),
      Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
    ]);
  }

  double _toDouble(dynamic v) {
    if (v == null) return 0.0;
    if (v is double) return v;
    if (v is int)    return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0.0;
    return 0.0;
  }

  /// Format date string as DD/MM/YYYY (Pakistan standard display format).
  String _shortDate(String raw) {
    if (raw.isEmpty) return '';
    try {
      // Input may be: YYYY-MM-DD or YYYY-MM-DD HH:MM:SS
      final datePart = raw.length >= 10 ? raw.substring(0, 10) : raw;
      final parts = datePart.split('-');
      if (parts.length == 3) return '${parts[2]}/${parts[1]}/${parts[0]}';
      return datePart;
    } catch (_) { return raw; }
  }

  @override
  void dispose() {
    for (final c in [_hireNameCtrl,_hireEmailCtrl,_hirePassCtrl,_hireLicCtrl,
                     _busNumberCtrl,_busTransportCtrl,_busCapCtrl,_routeSrcCtrl,_routeDstCtrl,
                     _routeTimeCtrl,_routeArrCtrl,_routeFareCtrl]) c.dispose();
    super.dispose();
  }
}