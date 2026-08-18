import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:provider/provider.dart';
import '../services/auth_provider.dart';
import '../services/api_service.dart';
import '../models/models.dart';
import 'login_screen.dart';
import 'chatbot_screen.dart';
import 'package:printing/printing.dart';

class PassengerDashboard extends StatefulWidget {
  const PassengerDashboard({super.key});
  @override
  State<PassengerDashboard> createState() => _PassengerDashboardState();
}

class _PassengerDashboardState extends State<PassengerDashboard> {
  int _tabIndex = 0;
  final ApiService _api = ApiService();
  bool _loading = true;

  List<Map<String, dynamic>> _routes   = [];
  List<Map<String, dynamic>> _bookings = [];
  List<Map<String, dynamic>> _payments = [];

  // Book ticket state
  int?      _selectedRouteId;
  // PKT = UTC+5. Initialise to tomorrow in Pakistan time.
  DateTime  _selectedDate    = DateTime.now().toUtc().add(const Duration(hours: 5, days: 1));
  int?      _selectedSeat;
  List<int> _availableSeats  = [];
  List<int> _bookedSeats     = [];
  int       _busCapacity     = 0;
  bool      _loadingSeats    = false;
  bool      _booking         = false;

  // Passenger details form (Full Name + Phone Number) shown on the booking
  // card. Validated client-side before a booking can be submitted; existing
  // booking functionality/API is unchanged.
  final GlobalKey<FormState> _bookingFormKey = GlobalKey<FormState>();
  final TextEditingController _fullNameController = TextEditingController();
  final TextEditingController _phoneController    = TextEditingController();

  static final RegExp _fullNameRegex =
      RegExp(r"^[a-zA-Z\u00C0-\u017F][a-zA-Z\u00C0-\u017F .'-]{1,49}$");
  // Accepts Pakistani mobile numbers in local (03XXXXXXXXX) or
  // international (+923XXXXXXXXX) format, with optional spaces/dashes.
  static final RegExp _phoneRegex = RegExp(r'^(\+92|0)3\d{9}$');

  // Guards against double-taps on Cancel while a cancellation is in flight
  // for a given booking id.
  final Set<int> _cancellingIds = {};

  @override
  void initState() {
    super.initState();
    _loadAll();
    // Re-render as the passenger types so the Confirm button's enabled
    // state (and any live validation) stays in sync with field validity.
    _fullNameController.addListener(_onPassengerDetailsChanged);
    _phoneController.addListener(_onPassengerDetailsChanged);
  }

  void _onPassengerDetailsChanged() {
    if (mounted) setState(() {});
  }

  bool get _passengerDetailsValid =>
      _validateFullName(_fullNameController.text) == null &&
      _validatePhone(_phoneController.text) == null;

  @override
  void dispose() {
    _fullNameController.removeListener(_onPassengerDetailsChanged);
    _phoneController.removeListener(_onPassengerDetailsChanged);
    _fullNameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  String? _validateFullName(String? value) {
    final v = (value ?? '').trim();
    if (v.isEmpty) return 'Full name is required.';
    if (v.length < 3) return 'Name must be at least 3 characters.';
    if (v.length > 50) return 'Name must be under 50 characters.';
    if (!_fullNameRegex.hasMatch(v)) {
      return 'Enter a valid name (letters, spaces, apostrophes and hyphens only).';
    }
    return null;
  }

  String? _validatePhone(String? value) {
    final raw = (value ?? '').trim();
    if (raw.isEmpty) return 'Phone number is required.';
    final normalized = raw.replaceAll(RegExp(r'[\s-]'), '');
    if (!_phoneRegex.hasMatch(normalized)) {
      return 'Enter a valid phone number (e.g. 03XXXXXXXXX or +923XXXXXXXXX).';
    }
    return null;
  }

  Future<void> _loadAll() async {
    setState(() => _loading = true);
    final passengerId = context.read<AuthProvider>().currentUser!.id;
    final results = await Future.wait([
      _api.getPassengerRoutes(),
      _api.getPassengerBookings(passengerId: passengerId),
      _api.getMyPayments(passengerId: passengerId),
    ]);
    if (!mounted) return;
    setState(() {
      _routes   = results[0] as List<Map<String, dynamic>>;
      _bookings = results[1] as List<Map<String, dynamic>>;
      _payments = results[2] as List<Map<String, dynamic>>;
      _loading  = false;
    });
  }

  void _snack(String msg, {bool error = false, bool success = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error   ? Colors.red.shade700
                     : success ? Colors.green.shade700
                               : Colors.blue.shade800,
      duration: const Duration(seconds: 5),
      behavior: SnackBarBehavior.floating,
    ));
  }

  // ── Load seat availability for selected route + date ──────────────────────
  Future<void> _loadSeats() async {
    if (_selectedRouteId == null) return;
    setState(() { _loadingSeats = true; _selectedSeat = null; });
    final dateStr = '${_selectedDate.year}-${_selectedDate.month.toString().padLeft(2,'0')}-${_selectedDate.day.toString().padLeft(2,'0')}';
    final res = await _api.getSeatAvailability(_selectedRouteId!, dateStr);
    if (!mounted) return;
    setState(() {
      _availableSeats = List<int>.from(res['available'] ?? []);
      _bookedSeats    = List<int>.from(res['booked']    ?? []);
      _busCapacity    = (res['capacity'] as num?)?.toInt() ?? 0;
      _loadingSeats   = false;
    });
    if (res['error'] != null) {
      _snack('Could not load seats: ${res['error']}', error: true);
    }
  }

  // ── Pick departure date ────────────────────────────────────────────────────
  // Pakistan Standard Time = UTC+5
  DateTime get _pktNow => DateTime.now().toUtc().add(const Duration(hours: 5));

  Future<void> _pickDate() async {
    final now    = _pktNow;
    final picked = await showDatePicker(
      context:     context,
      initialDate: _selectedDate,
      firstDate:   now,
      lastDate:    now.add(const Duration(days: 90)),
      helpText:    'Select Departure Date (Pakistan Time)',
    );
    if (picked != null && picked != _selectedDate) {
      setState(() => _selectedDate = picked);
      if (_selectedRouteId != null) await _loadSeats();
    }
  }

  // ── Book ticket (cash on boarding) ─────────────────────────────────────────
  Future<void> _bookTicket() async {
    if (_selectedRouteId == null) { _snack('Please select a route.', error: true); return; }
    if (_selectedSeat == null)    { _snack('Please select a seat.',  error: true); return; }

    // Passenger details (Full Name + Phone Number) must be valid before we
    // allow booking to proceed. This does not change the existing booking
    // API/flow — it only gates it behind client-side validation.
    final formState = _bookingFormKey.currentState;
    if (formState == null || !formState.validate()) {
      _snack('Please fix the highlighted fields before booking.', error: true);
      return;
    }

    setState(() => _booking = true);
    final dateStr = '${_selectedDate.year}-${_selectedDate.month.toString().padLeft(2,'0')}-${_selectedDate.day.toString().padLeft(2,'0')}';

    final res = await _api.bookTicket(
      routeId:       _selectedRouteId!,
      seatNumber:    _selectedSeat!,
      departureDate: dateStr,
      passengerId:   context.read<AuthProvider>().currentUser!.id,
      passengerName: _fullNameController.text.trim(),
      passengerPhone: _phoneController.text.trim(),
    );
    setState(() => _booking = false);
    if (!mounted) return;

    if (res['status'] == 'success') {
      _snack(res['message'] ?? 'Booking confirmed! Pay cash to the driver.', success: true);
      setState(() {
        _selectedRouteId = null; _selectedSeat = null; _availableSeats = []; _bookedSeats = [];
        _fullNameController.clear();
        _phoneController.clear();
      });
      _bookingFormKey.currentState?.reset();
      await _loadAll();
      setState(() => _tabIndex = 2);
    } else {
      _snack(res['message'] ?? 'Booking failed.', error: true);
      await _loadSeats(); // Refresh seats
    }
  }

  // ── Download / generate ticket PDF (used by both Home + Tickets tab) ───────
  Future<void> _downloadTicket(Map<String, dynamic> booking) async {
    try {
      final bookingId = (booking['id'] as num).toInt();

      _snack('Generating your ticket...');

      final pdfBytes = await _api.generateTicketPdf(
        bookingId: bookingId,
        passengerId: context.read<AuthProvider>().currentUser!.id,
      );

      if (!mounted) return;

      await Printing.layoutPdf(
        name: 'SmartTransit-Ticket-$bookingId.pdf',
        onLayout: (_) async => pdfBytes,
      );
    } catch (e) {
      if (!mounted) return;

      _snack(
        'Could not generate ticket: $e',
        error: true,
      );
    }
  }

  // ── Cancel booking ─────────────────────────────────────────────────────────
  //
  // NOTE: The actual DB update (matching on the booking's real integer `id`,
  // setting booking_status = 'cancelled', and NOT using `.single()` so a
  // zero-row result doesn't throw PGRST116) must live in
  // `ApiService.cancelBooking()`. This method only owns: confirming with the
  // user, calling the API, robustly interpreting whatever shape of result
  // comes back, and — on success — reloading `_bookings` + `_payments` and
  // calling setState so Home/Tickets/Payments all reflect the new status
  // immediately.
  Future<void> _cancelBooking(Map<String, dynamic> bk) async {
    final rawId = bk['id'];
    final bookingId = rawId is int ? rawId : int.tryParse(rawId?.toString() ?? '');
    if (bookingId == null) {
      _snack('Could not cancel: booking has no valid id.', error: true);
      return;
    }
    if (_cancellingIds.contains(bookingId)) return; // already in flight

    final src = bk['source'] ?? '';
    final dst = bk['destination'] ?? '';
    final dep = bk['departure_date'] ?? '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Cancel Booking'),
        content: Text('Cancel booking for $src → $dst on $dep?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep')),
          TextButton(onPressed: () => Navigator.pop(context, true),
              child: const Text('Cancel Booking', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _cancellingIds.add(bookingId));

    Map<String, dynamic> res;
    try {
      res = await _api.cancelBooking(
        bookingId,
        passengerId: context.read<AuthProvider>().currentUser!.id,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _cancellingIds.remove(bookingId));
      _snack('Could not cancel booking: $e', error: true);
      return;
    }

    if (!mounted) return;
    setState(() => _cancellingIds.remove(bookingId));

    // Interpret the result defensively — don't assume the API always
    // returns a `status` key. Treat it as success only when explicitly
    // told so; anything else (including an empty/zero-rows result that a
    // fixed cancelBooking() should surface as status != 'success' rather
    // than throwing) is treated as a failure so we never silently show
    // "cancelled" without confirmation from the backend.
    final status = res['status']?.toString().trim().toLowerCase();
    final isSuccess = status == 'success' || status == 'ok';

    _snack(
      res['message']?.toString() ?? (isSuccess ? 'Booking cancelled.' : 'Cancellation failed.'),
      error: !isSuccess,
      success: isSuccess,
    );

    // Refresh bookings + payments (and therefore Home stats and the Tickets
    // tab, which are all derived from the same _bookings/_payments lists)
    // immediately after a successful cancellation.
    if (isSuccess) await _loadAll();
  }

  // ── Booking / payment status helpers ───────────────────────────────────────
  // booking_status and payment_status live on two different tables/records
  // and must never be conflated. These helpers centralize how each booking's
  // *own* payment record is found and read, so every tab (Home, Tickets)
  // agrees on the same values.

  /// Finds the payment record for [bookingId] by matching
  /// `payment.booking_id == booking.id` against the separately-fetched
  /// `_payments` list (from `getMyPayments`), rather than trusting any
  /// embedded/derived field that may live on the booking row itself.
  /// `_payments` is already ordered by `payment_date` descending, so the
  /// first match found is that booking's most recent payment.
  Map<String, dynamic>? _paymentForBooking(dynamic bookingId) {
    if (bookingId == null) return null;
    final id = bookingId is int ? bookingId : int.tryParse(bookingId.toString());
    if (id == null) return null;
    for (final p in _payments) {
      final rawBookingId = p['booking_id'];
      final pBookingId = rawBookingId is int
          ? rawBookingId
          : int.tryParse(rawBookingId?.toString() ?? '');
      if (pBookingId == id) return p;
    }
    return null;
  }

  /// Finds the booking record for [bookingId] by matching
  /// `booking.id == payment.booking_id` against the separately-fetched
  /// `_bookings` list. Used as a fallback for payment cards when the
  /// payment's nested Supabase `bookings` relation isn't present, so a
  /// payment can still show its real seat number (payments.booking_id ->
  /// bookings.id -> bookings.seat_number) instead of `seat_number` being
  /// expected to live directly on the payments table.
  Map<String, dynamic>? _bookingForPayment(dynamic bookingId) {
    if (bookingId == null) return null;
    final id = bookingId is int ? bookingId : int.tryParse(bookingId.toString());
    if (id == null) return null;
    for (final b in _bookings) {
      final rawId = b['id'];
      final bId = rawId is int ? rawId : int.tryParse(rawId?.toString() ?? '');
      if (bId == id) return b;
    }
    return null;
  }

  /// True when [payment]'s related booking has `booking_status ==
  /// 'cancelled'`. This never deletes or modifies the payment row itself —
  /// the payment stays in the database (and in `_payments`) for transaction
  /// history. It is used purely to decide whether the payment should be
  /// shown in the passenger Payments tab / counted toward Total Paid.
  /// Prefers the nested Supabase `bookings` relation on the payment (now
  /// that `getMyPayments` includes `booking_status`); falls back to
  /// matching `payment.booking_id` against the loaded `_bookings` list via
  /// [_bookingForPayment], same pattern as the seat-number lookup.
  bool _isPaymentForCancelledBooking(Map<String, dynamic> p) {
    final nestedBooking = p['bookings'] as Map<String, dynamic>?;
    final matchedBooking = nestedBooking ?? _bookingForPayment(p['booking_id']);
    final status = (nestedBooking?['booking_status'] ?? matchedBooking?['booking_status'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    return status == 'cancelled';
  }

  /// A booking is "confirmed" purely based on its own `booking_status`
  /// column — never based on `payment_status`.
  bool _isBookingConfirmed(Map<String, dynamic> b) =>
      (b['booking_status']?.toString().trim().toLowerCase() ?? '') == 'confirmed';

  /// All of the passenger's confirmed bookings, computed from the exact same
  /// `_bookings` list the Tickets tab uses, so Home and Tickets can never
  /// disagree.
  List<Map<String, dynamic>> get _confirmedBookings =>
      _bookings.where(_isBookingConfirmed).toList();

  /// Confirmed bookings with a departure date today (Pakistan time) or in
  /// the future, sorted soonest-first, for the Home "Upcoming Trips" list.
  List<Map<String, dynamic>> get _upcomingConfirmedBookings {
    final now = _pktNow;
    final todayStr =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final list = _confirmedBookings.where((b) {
      final dep = b['departure_date']?.toString() ?? '';
      return dep.isNotEmpty && dep.compareTo(todayStr) >= 0;
    }).toList()
      ..sort((a, b) => (a['departure_date'] ?? '')
          .toString()
          .compareTo((b['departure_date'] ?? '').toString()));
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final auth = Provider.of<AuthProvider>(context);
    final user = auth.currentUser;
    if (user == null) return const LoginScreen();

    final views = [
      _buildHomeView(user),
      _buildSearchView(),
      _buildTicketsView(),
      _buildPaymentsView(),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('SmartTransit', style: TextStyle(fontWeight: FontWeight.w900)),
        backgroundColor: Colors.blue.shade900,
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
        selectedItemColor: Colors.blue.shade900,
        unselectedItemColor: Colors.grey,
        type: BottomNavigationBarType.fixed,
        onTap: (i) => setState(() => _tabIndex = i),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home_outlined),             label: 'Home'),
          BottomNavigationBarItem(icon: Icon(Icons.search_outlined),           label: 'Book'),
          BottomNavigationBarItem(icon: Icon(Icons.confirmation_num_outlined), label: 'Tickets'),
          BottomNavigationBarItem(icon: Icon(Icons.receipt_long_outlined),     label: 'Payments'),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        heroTag: 'chatbotFab',
        backgroundColor: Colors.blue.shade900,
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const ChatbotScreen()),
          );
        },
        child: const Icon(Icons.smart_toy_rounded, color: Colors.white),
      ),
    );
  }

  // ── Tab 0: Home ────────────────────────────────────────────────────────────
  Widget _buildHomeView(User user) {
    // Both the header count and the stats card use the same
    // booking_status-only "confirmed" list that powers the Tickets tab, and
    // "Upcoming Trips" further filters that list to today/future dates.
    final confirmed = _confirmedBookings.length;
    final upcoming  = _upcomingConfirmedBookings;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Card(
          color: Colors.blue.shade800,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: Padding(padding: const EdgeInsets.all(20), child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('SMART TRANSIT',
                  style: TextStyle(color: Colors.white60, fontSize: 10, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text('Hello, ${user.name.split(' ').first}!',
                  style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w900)),
              const SizedBox(height: 6),
              Text('${_routes.length} routes available  •  $confirmed confirmed trips',
                  style: const TextStyle(color: Colors.white70, fontSize: 12)),
            ],
          )),
        ),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(child: _statCard('My Trips', '${_bookings.length}', Icons.directions_bus, Colors.blue)),
          const SizedBox(width: 12),
          Expanded(child: _statCard('Confirmed', '$confirmed', Icons.check_circle_outline, Colors.green)),
        ]),
        const SizedBox(height: 22),
        const Text('Upcoming Trips', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(height: 10),
        if (upcoming.isEmpty)
          const Card(child: Padding(padding: EdgeInsets.all(20),
              child: Center(child: Text('No confirmed trips yet. Book from the "Book" tab.')))),
        ...upcoming.take(5).map((b) => _bookingCard(b, compact: true)),
      ]),
    );
  }

  // ── Tab 1: Search & Book ───────────────────────────────────────────────────
  Widget _buildSearchView() {
    final dateLabel = '${_selectedDate.day.toString().padLeft(2,'0')}/${_selectedDate.month.toString().padLeft(2,'0')}/${_selectedDate.year}';
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // ── Booking form ──────────────────────────────────────────────────────
        Card(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Padding(padding: const EdgeInsets.all(16), child: Form(
            key: _bookingFormKey,
            autovalidateMode: AutovalidateMode.onUserInteraction,
            child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Text('Book a Ticket', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(color: Colors.green.shade50, borderRadius: BorderRadius.circular(8)),
                child: Row(children: [
                  Icon(Icons.payments_outlined, color: Colors.green.shade700, size: 16),
                  const SizedBox(width: 6),
                  Text('Payment: Cash to Driver on Boarding',
                      style: TextStyle(color: Colors.green.shade800, fontSize: 11, fontWeight: FontWeight.w600)),
                ]),
              ),
              const SizedBox(height: 14),
              // Passenger details
              const Text('Passenger Details', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
              const SizedBox(height: 8),
              TextFormField(
                controller: _fullNameController,
                textCapitalization: TextCapitalization.words,
                keyboardType: TextInputType.name,
                decoration: const InputDecoration(
                  labelText: 'Full Name',
                  hintText: 'e.g. Ahmed Khan',
                  prefixIcon: Icon(Icons.person_outline),
                  border: OutlineInputBorder(),
                ),
                validator: _validateFullName,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _phoneController,
                keyboardType: TextInputType.phone,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9+\s-]')),
                ],
                decoration: const InputDecoration(
                  labelText: 'Phone Number',
                  hintText: 'e.g. 03001234567',
                  prefixIcon: Icon(Icons.phone_outlined),
                  border: OutlineInputBorder(),
                ),
                validator: _validatePhone,
              ),
              const SizedBox(height: 16),
              // Route selector
              DropdownButtonFormField<int>(
                value: _selectedRouteId,
                hint: const Text('Select Route'),
                isExpanded: true,
                items: _routes.map((r) {
                  final src  = r['source']      ?? '';
                  final dst  = r['destination'] ?? '';
                  final fare = _toDouble(r['fare']);
                  return DropdownMenuItem<int>(
                    value: r['id'] as int,
                    child: Text('$src → $dst  (PKR ${fare.toStringAsFixed(0)})',
                        overflow: TextOverflow.ellipsis),
                  );
                }).toList(),
                onChanged: (v) async {
                  setState(() { _selectedRouteId = v; _selectedSeat = null; _availableSeats = []; _bookedSeats = []; });
                  if (v != null) await _loadSeats();
                },
                decoration: const InputDecoration(labelText: 'Route'),
              ),
              if (_selectedRouteId != null) _buildRouteInfoBox(),
              const SizedBox(height: 12),
              // Date picker
              InkWell(
                onTap: _pickDate,
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Departure Date',
                    prefixIcon: Icon(Icons.calendar_today_outlined),
                  ),
                  child: Text(dateLabel, style: const TextStyle(fontSize: 15)),
                ),
              ),
              const SizedBox(height: 16),
              // Seat grid
              if (_selectedRouteId != null) ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Select Seat', style: TextStyle(fontWeight: FontWeight.bold)),
                    if (_availableSeats.isNotEmpty)
                      Text('${_availableSeats.length} / $_busCapacity available',
                          style: TextStyle(fontSize: 11, color: Colors.green.shade700)),
                  ],
                ),
                const SizedBox(height: 6),
                // Legend
                Row(children: [
                  _seatLegend(Colors.green.shade100, Colors.green.shade700, 'Available'),
                  const SizedBox(width: 12),
                  _seatLegend(Colors.red.shade100, Colors.red.shade700, 'Booked'),
                  const SizedBox(width: 12),
                  _seatLegend(Colors.blue.shade700, Colors.white, 'Selected'),
                ]),
                const SizedBox(height: 8),
                _loadingSeats
                    ? const Center(child: Padding(padding: EdgeInsets.all(16),
                        child: CircularProgressIndicator()))
                    : _busCapacity == 0
                        ? const Text('No seat data available.', style: TextStyle(color: Colors.grey))
                        : _buildSeatGrid(),
              ],
              const SizedBox(height: 16),
              _booking
                  ? const Center(child: CircularProgressIndicator())
                  : ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue.shade900, foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      icon: const Icon(Icons.check_circle_outline),
                      label: Text(_selectedSeat == null
                          ? 'Select a Seat to Book'
                          : !_passengerDetailsValid
                              ? 'Enter Valid Name & Phone Number'
                              : 'Confirm Seat $_selectedSeat — Pay Cash on Boarding'),
                      onPressed: (_selectedSeat != null && _passengerDetailsValid)
                          ? _bookTicket
                          : null,
                    ),
            ],
          ))),
        ),
        const SizedBox(height: 22),
        const Text('Available Routes', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(height: 10),
        if (_routes.isEmpty)
          const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('No routes available.'))),
        ..._routes.map(_buildRouteCard),
      ]),
    );
  }

  Widget _buildRouteInfoBox() {
    final r = _routes.firstWhere((r) => r['id'] == _selectedRouteId, orElse: () => {});
    if (r.isEmpty) return const SizedBox();
    final src  = r['source']         ?? '';
    final dst  = r['destination']    ?? '';
    final bus  = r['bus_number']     ?? '-';
    final days = r['days_of_week']   ?? 'Daily';
    final dep  = r['departure_time'] ?? '-';
    final arr  = r['arrival_time']?.toString() ?? '';
    final fare = _toDouble(r['fare']);
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: Colors.blue.shade50, borderRadius: BorderRadius.circular(10)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('$src → $dst', style: const TextStyle(fontWeight: FontWeight.bold)),
        Text('Bus: $bus'),
        Text('Days: $days', style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.blue)),
        Text('Dep: $dep${arr.isNotEmpty ? "  •  Arr: $arr" : ""}'),
        Text('PKR ${fare.toStringAsFixed(0)} per seat',
            style: TextStyle(color: Colors.blue.shade900, fontWeight: FontWeight.bold)),
      ]),
    );
  }

  Widget _buildSeatGrid() {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 8, mainAxisSpacing: 6, crossAxisSpacing: 6, childAspectRatio: 1,
      ),
      itemCount: _busCapacity,
      itemBuilder: (_, i) {
        final seat     = i + 1;
        final isBooked = _bookedSeats.contains(seat);
        final isSelected = _selectedSeat == seat;
        Color bg, fg;
        if (isSelected) { bg = Colors.blue.shade700; fg = Colors.white; }
        else if (isBooked) { bg = Colors.red.shade100; fg = Colors.red.shade700; }
        else { bg = Colors.green.shade100; fg = Colors.green.shade800; }
        return GestureDetector(
          onTap: isBooked ? null : () => setState(() => _selectedSeat = isSelected ? null : seat),
          child: Container(
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(6),
              border: isSelected ? Border.all(color: Colors.blue.shade900, width: 2) : null,
            ),
            child: Center(
              child: Text('$seat',
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: fg)),
            ),
          ),
        );
      },
    );
  }

  Widget _seatLegend(Color bg, Color fg, String label) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 16, height: 16,
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(3)),
        child: Center(child: Text('1', style: TextStyle(fontSize: 8, color: fg))),
      ),
      const SizedBox(width: 4),
      Text(label, style: const TextStyle(fontSize: 10, color: Colors.grey)),
    ]);
  }

  Widget _buildRouteCard(Map<String, dynamic> r) {
    final src  = r['source']         ?? '';
    final dst  = r['destination']    ?? '';
    final days = r['days_of_week']   ?? 'Daily';
    final dep  = r['departure_time'] ?? '-';
    final arr  = r['arrival_time']?.toString() ?? '';
    final bus  = r['bus_number']     ?? '-';
    final fare = _toDouble(r['fare']);
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: Colors.blue.shade50,
          child: Icon(Icons.directions_bus, color: Colors.blue.shade700, size: 20),
        ),
        title: Text('$src → $dst',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
        subtitle: Text(
          '$days\nBus: $bus  •  Dep: $dep${arr.isNotEmpty ? "  Arr: $arr" : ""}',
          style: const TextStyle(fontSize: 11),
        ),
        trailing: Text('PKR ${fare.toStringAsFixed(0)}',
            style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blue.shade900)),
        isThreeLine: true,
        onTap: () async {
          setState(() { _selectedRouteId = r['id'] as int; _tabIndex = 1; });
          await _loadSeats();
        },
      ),
    );
  }

  // ── Tab 2: My Tickets ──────────────────────────────────────────────────────
  Widget _buildTicketsView() {
    if (_bookings.isEmpty) {
      return const Center(child: Padding(padding: EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.confirmation_number_outlined, size: 64, color: Colors.grey),
          SizedBox(height: 16),
          Text('No bookings yet.\nGo to "Book" to find a route.',
              textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
        ]),
      ));
    }
    // Group by departure_date
    final sorted = List<Map<String, dynamic>>.from(_bookings)
      ..sort((a, b) => (a['departure_date'] ?? '').compareTo(b['departure_date'] ?? ''));
    return ListView.builder(
      padding: const EdgeInsets.all(14),
      itemCount: sorted.length,
      itemBuilder: (_, i) => _bookingCard(sorted[i]),
    );
  }

  Widget _bookingCard(Map<String, dynamic> bk, {bool compact = false}) {
    final bkStatus = bk['booking_status'] ?? 'Pending';

    // payment_status belongs to the *payment* record, not the booking row.
    // Look it up by matching payment.booking_id == booking.id against the
    // separately-fetched _payments list — never read a payment_status field
    // off the booking map itself.
    final payment = _paymentForBooking(bk['id']);
    final pyStatus = payment?['payment_status'] ?? payment?['status'] ?? 'Pending';

    // Normalize for case-insensitive comparisons. The DB stores lowercase
    // values (e.g. bookTicket() inserts 'confirmed'/'cancelled', and
    // confirmCashPayment() sets payment_status to 'confirmed'), while some
    // UI-facing values use Title Case ('Paid').
    final normBkStatus = bkStatus.toString().trim().toLowerCase();
    final normPyStatus = pyStatus.toString().trim().toLowerCase();

    final isCancelled = normBkStatus == 'cancelled';
    final isConfirmed = normBkStatus == 'confirmed';
    final isPaid = normPyStatus == 'paid' ||
        normPyStatus == 'confirmed' ||
        normPyStatus == 'success';

    // Download Ticket must require BOTH a confirmed booking AND a
    // confirmed/paid payment — a confirmed booking with a pending payment
    // must show "Pending" and must not allow ticket generation. A cancelled
    // booking can never show Download Ticket regardless of payment status.
    final canDownloadTicket = !isCancelled && isConfirmed && isPaid;

    final routeData = bk['routes'] as Map<String, dynamic>?;

    final src = routeData?['source'] ?? '';
    final dst = routeData?['destination'] ?? '';

    final dep = routeData?['departure_time'] ?? '-';
    final arr = routeData?['arrival_time']?.toString() ?? '';

    final bus = (routeData?['buses'] as Map<String, dynamic>?)?['bus_number'] ?? '-';

    final amount = _toDouble(routeData?['fare']);
    final seat = bk['seat_number'] ?? '-';
    final depDate = bk['departure_date'] ?? '';
    final days = routeData?['days_of_week'] ?? '';

    final rawId = bk['id'];
    final bookingId = rawId is int ? rawId : int.tryParse(rawId?.toString() ?? '');
    final isCancelling = bookingId != null && _cancellingIds.contains(bookingId);

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text('$src → $dst',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 14,
                    color: isCancelled ? Colors.grey : Colors.black,
                    decoration: isCancelled ? TextDecoration.lineThrough : null,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _statusChip(bkStatus),
            ],
          ),
          const SizedBox(height: 4),
          // Departure date prominently
          if (depDate.toString().isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              margin: const EdgeInsets.only(bottom: 4),
              decoration: BoxDecoration(
                color: Colors.indigo.shade50,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.calendar_today, size: 11, color: Colors.indigo.shade700),
                const SizedBox(width: 4),
                Flexible(
                  child: Text('Travel Date: $depDate',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11,
                          color: Colors.indigo.shade800)),
                ),
              ]),
            ),
          if (days.toString().isNotEmpty)
            Text(days.toString(),
                style: const TextStyle(fontSize: 10, color: Colors.blue, fontWeight: FontWeight.w600)),
          Text(
            'Bus: $bus  •  Seat: $seat  •  Dep: $dep${arr.isNotEmpty ? "  •  Arr: $arr" : ""}',
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
          if (!compact) ...[
            const SizedBox(height: 10),
            // Wrap (instead of a plain Row + Spacer) lets the badges and
            // buttons flow onto a second line on narrow screens instead of
            // overflowing — this is what fixes the RenderFlex overflow on
            // small Android widths while keeping the Download Ticket button
            // fully visible at all times.
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                // Cash payment badge
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: Colors.green.shade50, borderRadius: BorderRadius.circular(12)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.payments_outlined, size: 11, color: Colors.green.shade700),
                    const SizedBox(width: 4),
                    Text('Cash  •  PKR ${amount.toStringAsFixed(0)}',
                        style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold,
                            color: Colors.green.shade800)),
                  ]),
                ),
                // Payment badge reflects the *payment record's* own status —
                // shows "Pending" (not "Paid") whenever the payment itself
                // is still pending, even if the booking is confirmed, and
                // cancelling a booking never flips this to Paid.
                _statusChip(isPaid ? 'Paid' : (pyStatus.toString().isEmpty ? 'Pending' : pyStatus.toString()),
                    payment: true),
                if (canDownloadTicket)
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      visualDensity: VisualDensity.compact,
                      textStyle: const TextStyle(fontSize: 12),
                    ),
                    onPressed: () => _downloadTicket(bk),
                    icon: const Icon(Icons.download, size: 16),
                    label: const Text('Download Ticket'),
                  ),
                if (!isCancelled)
                  TextButton(
                    style: TextButton.styleFrom(foregroundColor: Colors.red,
                        textStyle: const TextStyle(fontSize: 11)),
                    onPressed: isCancelling ? null : () => _cancelBooking(bk),
                    child: isCancelling
                        ? const SizedBox(
                            width: 12, height: 12,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Cancel'),
                  ),
              ],
            ),
          ],
        ]),
      ),
    );
  }

  // ── Tab 3: Payment History ─────────────────────────────────────────────────

  /// Normalizes a payment status string for comparisons. The DB stores
  /// lowercase values ('confirmed', 'pending', 'failed') from
  /// bookTicket()/confirmCashPayment(), so all matching is done
  /// case-insensitively to avoid silently excluding real payments.
  String _normalizedPaymentStatus(Map<String, dynamic> p) {
    final raw = p['status'] ?? p['payment_status'] ?? 'pending';
    return raw.toString().trim().toLowerCase();
  }

  bool _isPaidStatus(String normalized) =>
      normalized == 'paid' || normalized == 'confirmed' || normalized == 'success';

  Widget _buildPaymentsView() {
    // Payments belonging to a cancelled booking stay in `_payments` (and in
    // the database) for transaction-history purposes, but must not appear
    // in the passenger-facing Payments tab or count toward Total Paid.
    // Computed live from _payments + _bookings on every build, so it
    // recalculates automatically the moment either list changes — e.g.
    // immediately after `_loadAll()` runs following a cancellation, with no
    // app restart needed.
    final visiblePayments =
        _payments.where((p) => !_isPaymentForCancelledBooking(p)).toList();

    // Total Paid must only include confirmed/paid CASH payments for
    // non-cancelled bookings — pending payments are excluded. Comparison is
    // case-insensitive since the DB stores 'confirmed' (lowercase), not
    // 'Paid'.
    final totalPaid = visiblePayments
        .where((p) => _isPaidStatus(_normalizedPaymentStatus(p)))
        .fold(0.0, (s, p) => s + _toDouble(p['amount']));

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        color: Colors.green.shade50,
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          const Text('Total Paid (Cash)',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.green)),
          Text('PKR ${totalPaid.toStringAsFixed(0)}',
              style: TextStyle(fontWeight: FontWeight.w900, fontSize: 22,
                  color: Colors.green.shade800)),
        ]),
      ),
      Expanded(
        child: visiblePayments.isEmpty
            ? const Center(child: Text('No payment history yet.'))
            : ListView.builder(
                padding: const EdgeInsets.all(12),
                itemCount: visiblePayments.length,
                itemBuilder: (_, i) {
                  final p = visiblePayments[i];
                  final normStatus = _normalizedPaymentStatus(p);
                  final isPaid     = _isPaidStatus(normStatus);
                  final displayStatus = isPaid ? 'Paid' : (normStatus.isEmpty
                      ? 'Pending'
                      : normStatus[0].toUpperCase() + normStatus.substring(1));

                  // Route / seat / date safely handle both the flattened
                  // shape (source/destination/seat_number at the top level)
                  // and a nested bookings->routes shape.
                  //
                  // Seat number fix: payments.seat_number does NOT exist on
                  // the payments table. The seat lives on the related
                  // booking (payments.booking_id -> bookings.id ->
                  // bookings.seat_number). Prefer the nested Supabase
                  // `bookings` relation on the payment if it was fetched;
                  // otherwise fall back to matching payment.booking_id
                  // against the already-loaded `_bookings` list via
                  // `_bookingForPayment`.
                  final nestedBooking = p['bookings'] as Map<String, dynamic>?;
                  final matchedBooking = nestedBooking ?? _bookingForPayment(p['booking_id']);
                  final nestedRoute = (nestedBooking?['routes'] ?? matchedBooking?['routes'])
                      as Map<String, dynamic>?;

                  final src = (p['source'] ?? nestedRoute?['source'] ?? matchedBooking?['source'] ?? '-').toString();
                  final dst = (p['destination'] ?? nestedRoute?['destination'] ?? matchedBooking?['destination'] ?? '-').toString();
                  final seatNum = (p['seat_number'] ?? matchedBooking?['seat_number'] ?? '-').toString();
                  final depDate = (p['departure_date'] ?? matchedBooking?['departure_date'] ?? '').toString();
                  final txn = p['transaction_id'];
                  final dateStr = _shortDate(p['payment_date']?.toString() ?? '');

                  return Card(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    margin: const EdgeInsets.only(bottom: 10),
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: isPaid ? Colors.green.shade50 : Colors.orange.shade50,
                        child: Icon(
                          isPaid ? Icons.payments_outlined : Icons.hourglass_top_outlined,
                          color: isPaid ? Colors.green : Colors.orange,
                        ),
                      ),
                      title: Text('$src → $dst',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('Cash  •  Seat $seatNum${depDate.isNotEmpty ? "  •  Travel: $depDate" : ""}'),
                        if (txn != null) Text('Receipt: $txn',
                            style: const TextStyle(fontSize: 9, color: Colors.grey)),
                        if (dateStr.isNotEmpty) Text('Paid: $dateStr',
                            style: const TextStyle(fontSize: 10, color: Colors.grey)),
                      ]),
                      isThreeLine: true,
                      trailing: Column(mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end, children: [
                        Text('PKR ${_toDouble(p['amount']).toStringAsFixed(0)}',
                            style: const TextStyle(fontWeight: FontWeight.bold)),
                        _statusChip(displayStatus, payment: true),
                      ]),
                    ),
                  );
                },
              ),
      ),
    ]);
  }

  // ── Helpers ────────────────────────────────────────────────────────────────
  Widget _statusChip(String status, {bool payment = false}) {
    Color bg, fg;
    final s = status.trim().toLowerCase();
    if (s == 'confirmed' || s == 'paid' || s == 'success') {
      bg = Colors.green.shade50; fg = Colors.green.shade800;
    } else if (s == 'cancelled' || s == 'failed') {
      bg = Colors.red.shade50; fg = Colors.red.shade800;
    } else {
      bg = Colors.orange.shade50; fg = Colors.orange.shade800;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(status, style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: fg)),
    );
  }

  Widget _statCard(String title, String val, IconData icon, Color color) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(padding: const EdgeInsets.all(14), child: Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(height: 10),
          Text(title, style: const TextStyle(color: Colors.grey, fontSize: 10, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(val, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
        ],
      )),
    );
  }

  double _toDouble(dynamic v) {
    if (v == null) return 0.0;
    if (v is double) return v;
    if (v is int)    return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0.0;
    return 0.0;
  }

  /// Format a date string as DD/MM/YYYY (Pakistan standard display format).
  /// Accepts 'YYYY-MM-DD' or 'YYYY-MM-DD HH:MM:SS' (and full ISO timestamps
  /// with a 'T' separator or timezone offset), and safely falls back to the
  /// raw string if it can't be parsed instead of throwing.
  String _shortDate(String raw) {
    if (raw.isEmpty) return '';
    try {
      final datePart = raw.length >= 10 ? raw.substring(0, 10) : raw;
      final parts = datePart.split('-');
      if (parts.length == 3) {
        final year  = parts[0];
        final month = parts[1];
        final day   = parts[2];
        return '$day/$month/$year';
      }
      return datePart;
    } catch (_) {
      return raw;
    }
  }
}