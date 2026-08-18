import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide User;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
/// ─────────────────────────────────────────────────────────────────────────
/// SCHEMA ASSUMPTIONS — adjust the table/column constants below to match
/// your actual Supabase schema. Suggested shape:
///
///   public.users       (id integer PK, name, email, role,
///                       wallet_balance numeric, license text, status text)
///   public.buses       (id bigint PK, bus_number text, driver_id integer,
///                       capacity int, status text)
///   public.routes      (id bigint PK, bus_id bigint, source text,
///                       destination text, departure_time text,
///                       arrival_time text, days_of_week text, fare numeric)
///   public.bookings    (id bigint PK, passenger_id integer, route_id bigint,
///                       seat_number int, departure_date date, status text,
///                       created_at timestamptz default now())
///   public.payments    (id bigint PK, booking_id bigint, passenger_id integer,
///                       amount numeric, status text,
///                       created_at timestamptz default now())
///
/// `driver_id` / `passenger_id` reference public.users.id (integer), sourced
/// from AuthProvider.currentUser.id — NOT the Supabase Auth UUID.
///
/// Row Level Security policies should scope Driver/Passenger reads & writes
/// to rows they own, and allow Admin role full access.
///
/// ── STATUS VALUES (canonical, lowercase, used consistently everywhere) ────
///   bookings.booking_status : 'confirmed' | 'pending' | 'cancelled'
///   payments.payment_status : 'confirmed' | 'pending'  | 'failed'
///
/// 'confirmed' on a payment is what the UI displays as "Paid". A payment
/// belonging to a cancelled booking must never be counted toward paid
/// totals/revenue/cash-collected, even if its own payment_status is
/// 'confirmed' (e.g. it was paid before being cancelled/refunded).
/// ─────────────────────────────────────────────────────────────────────────
class ApiService {
  static const String _profiles = 'users';
  static const String _buses = 'buses';
  static const String _routes = 'routes';
  static const String _bookings = 'bookings';
  static const String _payments = 'payments';

  final SupabaseClient _supabase = Supabase.instance.client;

  // ── ADMIN ─────────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> getAdminStats() async {
    try {
      // "Tickets Sold" must represent valid/sold bookings only — cancelled
      // bookings are excluded, matching the rule used everywhere else
      // (Passengers tab, Upcoming Bookings, etc.).
      final ticketsRes = await _supabase
          .from(_bookings)
          .select()
          .neq('booking_status', 'cancelled')
          .count(CountOption.exact);
      final driversRes = await _supabase
          .from(_profiles)
         .select()
         .eq('role_id', 2)
        .count(CountOption.exact);
      final busesRes = await _supabase.from(_buses).select().eq('status', 'active').count(CountOption.exact);
      final routesRes = await _supabase.from(_routes).select().count(CountOption.exact);

      // Revenue / pending-payments are computed by getPaymentSummary(),
      // which already applies the canonical 'confirmed' status rule AND
      // excludes payments tied to cancelled bookings. Reusing it here (
      // instead of re-deriving these numbers with separate, divergent
      // queries) is what keeps Analytics, Passengers, and Payments in
      // agreement with each other.
      final summary = await getPaymentSummary();

      return {
        'totalTicketsSold': ticketsRes.count,
        'totalRevenue': summary['totalRevenue'],
        'activeDrivers': driversRes.count,
        'activeBuses': busesRes.count,
        'activeRoutes': routesRes.count,
        'pendingPayments': summary['pendingCount'],
      };
    } catch (e) {
      debugPrint('[ApiService][getAdminStats] ERROR: $e');
      return {
        'totalTicketsSold': 0, 'totalRevenue': 0, 'activeDrivers': 0,
        'activeBuses': 0, 'activeRoutes': 0, 'pendingPayments': 0,
      };
    }
  }
Future<List<Map<String, dynamic>>> getAdminDrivers() async {
  try {
    final data = await _supabase
        .from('drivers')
        .select('''
          id,
          user_id,
          license_number,
          status,
          users!drivers_user_id_fkey(
            id,
            name,
            email
          )
        ''')
        .order('id');

    return data.map<Map<String, dynamic>>((e) {
      final user = e['users'] ?? {};

      return {
        'id': e['id'],
        'user_id': e['user_id'],
        'license_number': e['license_number'],
        'status': e['status'],
        'name': user['name'] ?? '',
        'email': user['email'] ?? '',
      };
    }).toList();
  } catch (e) {
    debugPrint("getAdminDrivers ERROR: $e");
    return [];
  }
}

  /// Creates a Driver account. The anon/public Supabase key cannot create
  /// *other users'* auth accounts, so this invokes a Supabase Edge Function
  /// (deployed separately, using the service-role key) that creates the auth
  /// user and inserts the matching profile row with role='Driver'.
  Future<Map<String, dynamic>> hireDriver({
    required String name,
    required String email,
    required String password,
    required String license,
  }) async {
    try {
      final res = await _supabase.functions.invoke('admin-hire-driver', body: {
        'name': name,
        'email': email,
        'password': password,
        'license': license,
      });

      if (res.status == 200) {
        return {'status': 'success', 'data': res.data};
      }
      final data = res.data;
      final message = (data is Map && data['message'] != null) ? data['message'] : 'Failed to hire driver.';
      return {'status': 'error', 'message': message};
    } catch (e) {
      return {'status': 'error', 'message': e.toString()};
    }
  }

  Future<Map<String, dynamic>> updateDriverStatus(int driverId, String status) async {
    try {
      final updated = await _supabase
          .from(_profiles)
          .update({'status': status})
          .eq('id', driverId)
          .select()
          .maybeSingle();
      return updated == null
          ? {'status': 'error', 'message': 'Driver not found.'}
          : {'status': 'success', 'data': updated};
    } catch (e) {
      return {'status': 'error', 'message': e.toString()};
    }
  }

  Future<Map<String, dynamic>> removeDriver(int driverId) async {
    try {
      await _supabase.from(_profiles).delete().eq('id', driverId);
      return {'status': 'success'};
    } catch (e) {
      return {'status': 'error', 'message': e.toString()};
    }
  }

 Future<List<Map<String, dynamic>>> getAdminBuses() async {
  try {
    final data = await _supabase
        .from(_buses)
        .select('''
          id,
          bus_number,
          transport_name,
          capacity,
          status,
          driver_id,
          route_id,
          routes!buses_route_id_fkey(
            id,
            source,
            destination,
            departure_time
          ),
          drivers(
            id,
            user_id,
            users(
              name,
              email
            )
          )
        ''')
        .order('bus_number');

    return List<Map<String, dynamic>>.from(data);
  } catch (e) {
    debugPrint('[ApiService][getAdminBuses] ERROR: $e');
    return [];
  }
}

  Future<Map<String, dynamic>> adminAddBus({
    required String busNumber,
    required String transportName,
    int? routeId,
    int? driverId,
    int capacity = 50,
    String status = 'active',
  }) async {
    try {
      if (routeId != null) {
        final dup = await _supabase
            .from(_buses)
            .select('id')
            .eq('route_id', routeId)
            .eq('bus_number', busNumber)
            .maybeSingle();
        if (dup != null) {
          return {
            'status': 'error',
            'message': 'This bus number is already added to this route.',
          };
        }
      }
      final inserted = await _supabase.from(_buses).insert({
        'bus_number': busNumber,
        'transport_name': transportName,
        'route_id': routeId,
        'driver_id': driverId,
        'capacity': capacity,
        'status': status,
      }).select().single();
      return {'status': 'success', 'data': inserted};
    } catch (e) {
      return {'status': 'error', 'message': e.toString()};
    }
  }

  Future<Map<String, dynamic>> adminUpdateBus(
    int busId, {
    String? busNumber,
    String? transportName,
    int? routeId,
    int? driverId,
    int? capacity,
    String? status,
  }) async {
    try {
      final payload = {
        if (busNumber != null) 'bus_number': busNumber,
        if (transportName != null) 'transport_name': transportName,
        if (routeId != null) 'route_id': routeId,
        if (driverId != null) 'driver_id': driverId,
        if (capacity != null) 'capacity': capacity,
        if (status != null) 'status': status,
      };
      final updated = await _supabase.from(_buses).update(payload).eq('id', busId).select().maybeSingle();
      return updated == null
          ? {'status': 'error', 'message': 'Bus not found.'}
          : {'status': 'success', 'data': updated};
    } catch (e) {
      return {'status': 'error', 'message': e.toString()};
    }
  }

  Future<Map<String, dynamic>> adminDeleteBus(int busId) async {
    try {
      await _supabase.from(_buses).delete().eq('id', busId);
      return {'status': 'success'};
    } catch (e) {
      return {'status': 'error', 'message': e.toString()};
    }
  }

  Future<List<Map<String, dynamic>>> getAdminRoutes() async {
    try {
      final data = await _supabase.from(_routes).select('''
        *,
        buses!buses_route_id_fkey(
          id,
          bus_number,
          transport_name,
          status,
          driver_id
        )
      ''').order('departure_time');
      return List<Map<String, dynamic>>.from(data);
    } catch (e) {
      debugPrint('[ApiService][getAdminRoutes] ERROR: $e');
      return [];
    }
  }

  Future<Map<String, dynamic>> adminAddRoute({
    required String source,
    required String destination,
    required String departureTime,
    String? arrivalTime,
    String daysOfWeek = 'Daily',
    required double fare,
  }) async {
    try {
      final inserted = await _supabase.from(_routes).insert({
        'source': source,
        'destination': destination,
        'departure_time': departureTime,
        'arrival_time': arrivalTime,
        'days_of_week': daysOfWeek,
        'fare': fare,
      }).select().single();
      return {'status': 'success', 'data': inserted};
    } catch (e) {
      return {'status': 'error', 'message': e.toString()};
    }
  }

  Future<Map<String, dynamic>> adminUpdateRoute(
    int routeId, {
    String? source,
    String? destination,
    String? departureTime,
    double? fare,
  }) async {
    try {
      final payload = {
        if (source != null) 'source': source,
        if (destination != null) 'destination': destination,
        if (departureTime != null) 'departure_time': departureTime,
        if (fare != null) 'fare': fare,
      };
      final updated = await _supabase.from(_routes).update(payload).eq('id', routeId).select().maybeSingle();
      return updated == null
          ? {'status': 'error', 'message': 'Route not found.'}
          : {'status': 'success', 'data': updated};
    } catch (e) {
      return {'status': 'error', 'message': e.toString()};
    }
  }

  Future<Map<String, dynamic>> adminDeleteRoute(int routeId) async {
    try {
      await _supabase.from(_routes).delete().eq('id', routeId);
      return {'status': 'success'};
    } catch (e) {
      return {'status': 'error', 'message': e.toString()};
    }
  }

  Future<List<Map<String, dynamic>>> getAdminBookings() async {
  try {
    final data = await _supabase
        .from(_bookings)
        .select('''
          *,
          users!bookings_passenger_id_fkey(
            name,
            email
          ),
          routes(
            source,
            destination,
            departure_time
          ),
          buses!bookings_bus_id_fkey(
            bus_number,
            transport_name
          ),
          payments(
            amount,
            payment_status
          )
        ''')
        .order('booking_date', ascending: false);

    final rows = List<Map<String, dynamic>>.from(data);

    return rows.map((e) {
      final user = e['users'] ?? {};
      final route = e['routes'] ?? {};
      final bus = e['buses'] ?? {};

      final payment =
          (e['payments'] as List?)?.isNotEmpty == true
              ? e['payments'][0]
              : {};

      return {
        ...e,
        'passengerName': ((e['passenger_name'] as String?)?.trim().isNotEmpty ?? false)
            ? e['passenger_name']
            : (user['name'] ?? 'Unknown'),
        'passengerPhone': (e['passenger_phone'] as String?)?.trim() ?? '',
        'passengerEmail': user['email'] ?? '',
        'source': route['source'] ?? '-',
        'destination': route['destination'] ?? '-',
        'departureTime': route['departure_time'] ?? '-',
        'busNumber': bus['bus_number'] ?? '-',
        'transportName': bus['transport_name'] ?? '-',
        'paymentStatus': payment['payment_status'] ?? 'Pending',
        'amount': payment['amount'] ?? 0,
      };
    }).toList();
  } catch (e) {
    debugPrint('[ApiService][getAdminBookings] ERROR: $e');
    return [];
  }
}
  Future<List<Map<String, dynamic>>> getAdminAllPayments() async {
  try {
    final data = await _supabase
        .from(_payments)
        .select('''
          *,
          bookings(
            seat_number,
            departure_date,
            booking_status,
            passenger_name,
            passenger_phone,
            users!bookings_passenger_id_fkey(
              name
            ),
            routes(
              source,
              destination
            ),
            buses!bookings_bus_id_fkey(
              bus_number,
              transport_name
            )
          )
        ''')
        .order('payment_date', ascending: false);
          debugPrint(data.toString());

    return List<Map<String, dynamic>>.from(data).map((e) {
      final booking = e['bookings'] ?? {};
      final user = booking['users'] ?? {};
      final route = booking['routes'] ?? {};
      final bus = booking['buses'] ?? {};

      return {
        ...e,
        'passenger_name': ((booking['passenger_name'] as String?)?.trim().isNotEmpty ?? false)
            ? booking['passenger_name']
            : (user['name'] ?? 'Unknown'),
        'passenger_phone': (booking['passenger_phone'] as String?)?.trim() ?? '',
        'seat_number': booking['seat_number'] ?? '-',
        'departure_date': booking['departure_date'],
        // Exposed so the UI can exclude cancelled-booking payments from
        // "Paid" counts/filters without losing the payment's own record.
        'bookingStatus': booking['booking_status'] ?? '-',
        'source': route['source'] ?? '-',
        'destination': route['destination'] ?? '-',
        'bus_number': bus['bus_number'] ?? '-',
        'transport_name': bus['transport_name'] ?? '-',
      };
    }).toList();
  } catch (e) {
    debugPrint(e.toString());
    return [];
  }
}

  Future<Map<String, dynamic>> getPaymentSummary() async {
    try {
      // Join to bookings so payments belonging to a cancelled booking can be
      // excluded from every bucket below. Cancelled bookings stay fully
      // identifiable elsewhere in the UI (Passengers tab, Payments list) —
      // they are only excluded from these aggregate paid/pending/failed/
      // revenue stats, per the same rule used across the whole dashboard.
      final all = await _supabase
          .from(_payments)
          .select('amount, payment_status, bookings!inner(booking_status)');
      final rows = List<Map<String, dynamic>>.from(all);

      double totalRevenue = 0;
      int successCount = 0, pendingCount = 0, failedCount = 0;

      for (final row in rows) {
        final booking = row['bookings'];
        final bookingStatus =
            (booking is Map ? booking['booking_status'] : null)?.toString().toLowerCase();
        if (bookingStatus == 'cancelled') continue;

        final status = (row['payment_status'] as String?)?.toLowerCase();
        // 'confirmed' is the canonical "Paid" status in the database.
        if (status == 'confirmed') {
    successCount++;
    totalRevenue += (row['amount'] as num?)?.toDouble() ?? 0;
} else if (status == 'pending') {
    pendingCount++;
} else if (status == 'failed') {
    failedCount++;
}
      }

      return {
        'totalRevenue': totalRevenue,
        'totalPayments': rows.length,
        'successCount': successCount,
        'pendingCount': pendingCount,
        'failedCount': failedCount,
      };
    } catch (e) {
      debugPrint('[ApiService][getPaymentSummary] ERROR: $e');
      return {'totalRevenue': 0, 'totalPayments': 0, 'successCount': 0, 'pendingCount': 0, 'failedCount': 0};
    }
  }

  // ── DRIVER ────────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> getDriverStats({required int driverId}) async {
    try {
      final buses =
          List<Map<String, dynamic>>.from(await _supabase.from(_buses).select('id').eq('driver_id', driverId));
      final busIds = buses.map((b) => b['id']).toList();

      List<Map<String, dynamic>> routes = [];
      if (busIds.isNotEmpty) {
        routes = List<Map<String, dynamic>>.from(
            await _supabase.from(_routes).select('id, fare').inFilter('bus_id', busIds));
      }
      final routeIds = routes.map((r) => r['id']).toList();

      int ticketsSold = 0;
      double revenue = 0;
      if (routeIds.isNotEmpty) {
        final bookings = List<Map<String, dynamic>>.from(await _supabase
            .from(_bookings)
            .select('route_id')
            .inFilter('route_id', routeIds)
            .neq('booking_status', 'cancelled'));
        ticketsSold = bookings.length;

        final fareByRoute = {for (final r in routes) r['id']: (r['fare'] as num?)?.toDouble() ?? 0};
        for (final b in bookings) {
          revenue += fareByRoute[b['route_id']] ?? 0;
        }
      }

      return {'myBuses': buses.length, 'myRoutes': routes.length, 'ticketsSold': ticketsSold, 'revenue': revenue};
    } catch (e) {
      debugPrint('[ApiService][getDriverStats] ERROR: $e');
      return {'myBuses': 0, 'myRoutes': 0, 'ticketsSold': 0, 'revenue': 0};
    }
  }

  Future<List<Map<String, dynamic>>> getDriverBuses({required int driverId}) async {
    try {
      final data = await _supabase
          .from(_buses)
          .select('''
            *,
            routes!buses_route_id_fkey(
              id,
              source,
              destination,
              departure_time,
              fare
            )
          ''')
          .eq('driver_id', driverId)
          .order('bus_number');
      return List<Map<String, dynamic>>.from(data);
    } catch (e) {
      debugPrint('[ApiService][getDriverBuses] ERROR: $e');
      return [];
    }
  }

  Future<Map<String, dynamic>> driverAddBus({
    required String busNumber,
    required String transportName,
    required int routeId,
    required int driverId,
    int capacity = 50,
  }) async {
    try {
      final dup = await _supabase
          .from(_buses)
          .select('id')
          .eq('route_id', routeId)
          .eq('bus_number', busNumber)
          .maybeSingle();
      if (dup != null) {
        return {
          'status': 'error',
          'message': 'This bus number is already added to this route.',
        };
      }
      final inserted = await _supabase.from(_buses).insert({
        'bus_number': busNumber,
        'transport_name': transportName,
        'route_id': routeId,
        'capacity': capacity,
        'driver_id': driverId,
        'status': 'active',
      }).select().single();
      return {'status': 'success', 'data': inserted};
    } catch (e) {
      return {'status': 'error', 'message': e.toString()};
    }
  }

  Future<Map<String, dynamic>> driverUpdateBusStatus(int busId, String status, {required int driverId}) async {
    try {
      final updated = await _supabase
          .from(_buses)
          .update({'status': status})
          .eq('id', busId)
          .eq('driver_id', driverId)
          .select()
          .maybeSingle();
      return updated == null
          ? {'status': 'error', 'message': 'Bus not found.'}
          : {'status': 'success', 'data': updated};
    } catch (e) {
      return {'status': 'error', 'message': e.toString()};
    }
  }

  Future<List<Map<String, dynamic>>> getDriverRoutes({required int driverId}) async {
    try {
      final buses = List<Map<String, dynamic>>.from(
          await _supabase.from(_buses).select('route_id').eq('driver_id', driverId));
      final routeIds = buses.map((b) => b['route_id']).whereType<Object>().toSet().toList();
      if (routeIds.isEmpty) return [];
      final data = await _supabase.from(_routes).select().inFilter('id', routeIds).order('departure_time');
      return List<Map<String, dynamic>>.from(data);
    } catch (e) {
      debugPrint('[ApiService][getDriverRoutes] ERROR: $e');
      return [];
    }
  }

  // Lets a driver create a brand-new route (source/destination/time/fare)
  // that they (or other buses later) can be assigned to. Routes are no
  // longer tied to a single bus at creation time — use driverAddBus() /
  // adminAddBus() with a routeId to actually put a bus on this route.
  Future<Map<String, dynamic>> driverAddRoute({
    required String source,
    required String destination,
    required String departureTime,
    String? arrivalTime,
    String daysOfWeek = 'Daily',
    required double fare,
  }) async {
    try {
      final inserted = await _supabase.from(_routes).insert({
        'source': source,
        'destination': destination,
        'departure_time': departureTime,
        'arrival_time': arrivalTime,
        'days_of_week': daysOfWeek,
        'fare': fare,
      }).select().single();
      return {'status': 'success', 'data': inserted};
    } catch (e) {
      return {'status': 'error', 'message': e.toString()};
    }
  }

  Future<List<Map<String, dynamic>>> getDriverPassengers({required int driverId}) async {
    try {
      final buses =
          List<Map<String, dynamic>>.from(await _supabase.from(_buses).select('id').eq('driver_id', driverId));
      final busIds = buses.map((b) => b['id']).toList();
      if (busIds.isEmpty) return [];

      final data = await _supabase
          .from(_bookings)
          .select('''
*,
users!bookings_passenger_id_fkey(
    name,
    email
),
routes(
    source,
    destination,
    departure_time
),
buses!bookings_bus_id_fkey(
    bus_number,
    transport_name
),
payments(
    amount,
    payment_status
)
''')
          .inFilter('bus_id', busIds)
          .neq('booking_status', 'cancelled')
          .order('departure_date', ascending: false);
      final rows = List<Map<String, dynamic>>.from(data);

return rows.map((e) {
  final user = e['users'] ?? {};
  final route = e['routes'] ?? {};
  final bus = e['buses'] ?? {};
  final payment = Map<String, dynamic>.from(e['payments'] ?? {});

  return {
    ...e,
    'departureDate': e['departure_date'],
    'passengerName': ((e['passenger_name'] as String?)?.trim().isNotEmpty ?? false)
        ? e['passenger_name']
        : (user['name'] ?? 'Unknown'),
    'passengerPhone': (e['passenger_phone'] as String?)?.trim() ?? '',
    'passengerEmail': user['email'] ?? '',
    'source': route['source'] ?? '-',
    'destination': route['destination'] ?? '-',
    'departureTime': route['departure_time'] ?? '-',
    'busNumber': bus['bus_number'] ?? '-',
    'transportName': bus['transport_name'] ?? '-',
    'paymentStatus': payment['payment_status'] ?? 'Pending',
    'amount': payment['amount'] ?? 0,
  };
}).toList();
    } catch (e) {
      debugPrint('[ApiService][getDriverPassengers] ERROR: $e');
      return [];
    }
  }

  Future<double> getDriverRevenue({required int driverId}) async {
    final stats = await getDriverStats(driverId: driverId);
    return (stats['revenue'] as num?)?.toDouble() ?? 0.0;
  }

  // ── PASSENGER ─────────────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> getPassengerRoutes() async {
    try {
      final data = await _supabase.from(_routes).select('''
*,
buses!buses_route_id_fkey(
  id,
  status
)
''').order('departure_time');
      final rows = List<Map<String, dynamic>>.from(data);
      // Surface a bus count so the Passenger UI can show "3 transports
      // available" without a second round trip. A route can now be served
      // by several buses, so this is no longer a single bus_number.
      return rows.map((r) {
        final busesRaw = r['buses'];
        final busList = busesRaw is List ? List<Map<String, dynamic>>.from(busesRaw) : const <Map<String, dynamic>>[];
        final activeCount = busList.where((b) => (b['status'] ?? 'active') == 'active').length;
        return {
          ...r,
          'busCount': activeCount,
        };
      }).toList();
    } catch (e) {
      debugPrint('[ApiService][getPassengerRoutes] ERROR: $e');
      return [];
    }
  }

  // All active buses/transports serving a specific route — shown to the
  // passenger after they pick a route, so they can choose which specific
  // transport (e.g. "Daewoo Express" vs "Faisal Movers") to book.
  Future<List<Map<String, dynamic>>> getRouteBuses(int routeId) async {
    try {
      final data = await _supabase
          .from(_buses)
          .select('''
            id,
            bus_number,
            transport_name,
            capacity,
            status,
            driver_id,
            drivers(
              id,
              user_id,
              users(name)
            )
          ''')
          .eq('route_id', routeId)
          .eq('status', 'active')
          .order('bus_number');
      final rows = List<Map<String, dynamic>>.from(data);
      return rows.map((b) {
        final driver = b['drivers'];
        final driverUser = (driver is Map) ? driver['users'] : null;
        final driverName = (driverUser is Map) ? (driverUser['name']?.toString() ?? '') : '';
        return {
          ...b,
          'driverName': driverName.isNotEmpty ? driverName : 'Not assigned',
        };
      }).toList();
    } catch (e) {
      debugPrint('[ApiService][getRouteBuses] ERROR: $e');
      return [];
    }
  }
Future<Uint8List> generateTicketPdf({
  required int bookingId,
  // When provided, the ticket is only generated if the booking actually
  // belongs to this passenger — prevents one passenger from downloading
  // another passenger's ticket (name/phone/payment info) by passing a
  // different booking id.
  int? passengerId,
  // When provided (Driver Dashboard), the ticket is only generated if the
  // booking's route is served by a bus assigned to this driver.
  int? driverId,
}) async {
  try {
    final row = await _supabase
        .from(_bookings)
        .select('''
          id,
          passenger_id,
          seat_number,
          departure_date,
          booking_status,
          passenger_name,
          passenger_phone,
          users!bookings_passenger_id_fkey(name, email),
          routes(
            source,
            destination,
            departure_time
          ),
          buses!bookings_bus_id_fkey(bus_number, transport_name, driver_id),
          payments(amount, payment_status, transaction_id)
        ''')
        .eq('id', bookingId)
        .single();

    if (passengerId != null && (row['passenger_id'] as num?)?.toInt() != passengerId) {
      throw Exception('You are not authorized to view this ticket.');
    }

    final user = (row['users'] is Map) ? row['users'] as Map : const {};
    final route = (row['routes'] is Map) ? row['routes'] as Map : const {};
    final bus = (row['buses'] is Map) ? row['buses'] as Map : const {};

    if (driverId != null && (bus['driver_id'] as num?)?.toInt() != driverId) {
      throw Exception('You are not authorized to view this ticket.');
    }

    final paymentsRaw = row['payments'];
    Map payment = const {};
    if (paymentsRaw is List && paymentsRaw.isNotEmpty) {
      payment = paymentsRaw.first as Map;
    } else if (paymentsRaw is Map) {
      payment = paymentsRaw;
    }

    final bookingName = (row['passenger_name'] as String?)?.trim();
    final bookingPhone = (row['passenger_phone'] as String?)?.trim();

    return _buildSingleTicketPdfBytes(
      bookingId: row['id'],
      passengerName: (bookingName != null && bookingName.isNotEmpty)
          ? bookingName
          : (user['name']?.toString() ?? 'Unknown'),
      passengerPhone: (bookingPhone != null && bookingPhone.isNotEmpty) ? bookingPhone : '',
      source: route['source']?.toString() ?? '-',
      destination: route['destination']?.toString() ?? '-',
      transportName: bus['transport_name']?.toString() ?? '-',
      busNumber: bus['bus_number']?.toString() ?? '-',
      seatNumber: row['seat_number']?.toString() ?? '-',
      departureDate: row['departure_date']?.toString() ?? '-',
      departureTime: route['departure_time']?.toString() ?? '-',
      amount: (payment['amount'] as num?)?.toDouble() ?? 0.0,
      paymentStatus: payment['payment_status']?.toString() ?? 'Pending',
      transactionId: payment['transaction_id']?.toString() ?? '-',
    );
  } catch (e) {
    debugPrint('[ApiService][generateTicketPdf] ERROR: $e');
    rethrow;
  }
}

// Builds the single-passenger e-ticket PDF shown to Passenger/Driver/Admin
// when they tap "Download Ticket". Generated locally (mirrors the layout
// the old n8n webhook produced) so it always reflects the passenger_name /
// passenger_phone captured on the booking form.
Future<Uint8List> _buildSingleTicketPdfBytes({
  required int bookingId,
  required String passengerName,
  required String passengerPhone,
  required String source,
  required String destination,
  required String transportName,
  required String busNumber,
  required String seatNumber,
  required String departureDate,
  required String departureTime,
  required double amount,
  required String paymentStatus,
  required String transactionId,
}) async {
  final doc = pw.Document();

  doc.addPage(
    pw.Page(
      pageFormat: PdfPageFormat.a4,
      build: (context) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text('SmartTransit', style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 4),
          pw.Text('Official E-Ticket', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 10),
          pw.Text('$source -> $destination',
              style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 12),
          _pdfInfoRow('Booking ID', '#$bookingId'),
          _pdfInfoRow('Passenger', passengerName),
          if (passengerPhone.isNotEmpty) _pdfInfoRow('Phone', passengerPhone),
          _pdfInfoRow('Transport', transportName),
          _pdfInfoRow('Bus', busNumber),
          _pdfInfoRow('Seat Number', seatNumber),
          _pdfInfoRow('Departure Date', departureDate),
          _pdfInfoRow('Departure Time', departureTime),
          pw.SizedBox(height: 8),
          pw.Divider(color: PdfColors.grey400),
          pw.SizedBox(height: 8),
          _pdfInfoRow('Amount', 'Rs. ${amount.toStringAsFixed(0)}'),
          _pdfInfoRow('Payment', paymentStatus),
          _pdfInfoRow('Transaction ID', transactionId),
        ],
      ),
    ),
  );

  return doc.save();
}

  // ── DAILY BUS PASSENGER MANIFEST (Driver + Admin) ─────────────────────────
  //
  // Builds a single PDF listing every passenger booked on [busId] for
  // [travelDate]. This is a bus-level manifest, distinct from the
  // single-passenger ticket produced by generateTicketPdf() above — it is
  // generated locally from Supabase data rather than via the n8n webhook.
  //
  // Pass [driverId] when calling from the Driver Dashboard — the method
  // verifies the bus is actually assigned to that driver and throws if not.
  // Leave it null for Admin, who may pull the manifest for any bus.
  Future<Uint8List> generateBusPassengerListPdf({
    required int busId,
    required String travelDate, // 'YYYY-MM-DD'
    int? driverId,
  }) async {
    try {
      // 1. Bus + assigned driver.
      final bus = await _supabase
          .from(_buses)
          .select('''
            id,
            bus_number,
            transport_name,
            capacity,
            status,
            driver_id,
            route_id,
            drivers(
              id,
              user_id,
              users(name)
            )
          ''')
          .eq('id', busId)
          .maybeSingle();

      if (bus == null) {
        throw Exception('Bus not found.');
      }

      // Driver-side access control: only the assigned driver may pull this.
      if (driverId != null) {
        final assignedDriver = bus['drivers'];
        final assignedDriverId = assignedDriver is Map ? assignedDriver['id'] : null;
        if (assignedDriverId != driverId) {
          throw Exception("You are not authorized to view this bus's passenger list.");
        }
      }

      final driverName = (() {
        final d = bus['drivers'];
        if (d is Map) {
          final u = d['users'];
          if (u is Map && (u['name'] ?? '').toString().isNotEmpty) {
            return u['name'].toString();
          }
        }
        return '';
      })();

      // 2. The single route this specific bus/transport is assigned to.
      Map<String, dynamic> primaryRoute = const {};
      final routeId = bus['route_id'];
      if (routeId != null) {
        final routeRow = await _supabase
            .from(_routes)
            .select('id, source, destination, departure_time, arrival_time')
            .eq('id', routeId)
            .maybeSingle();
        if (routeRow != null) primaryRoute = routeRow;
      }

      // 3. Bookings for THIS specific bus only (not the whole route — a
      //    route can now have several buses), scoped to the selected date.
      final data = await _supabase
          .from(_bookings)
          .select('''
            id,
            seat_number,
            booking_status,
            departure_date,
            passenger_name,
            passenger_phone,
            users!bookings_passenger_id_fkey(
              name,
              email
            ),
            payments(
              amount,
              payment_status,
              payment_method,
              transaction_id
            )
          ''')
          .eq('bus_id', busId)
          .eq('departure_date', travelDate)
          .neq('booking_status', 'cancelled')
          .order('seat_number');
      final bookings = List<Map<String, dynamic>>.from(data);

      final passengerRows = bookings.map((b) {
        final user = (b['users'] is Map) ? b['users'] as Map : const {};
        final paymentsRaw = b['payments'];
        Map paymentRow = const {};
        if (paymentsRaw is List && paymentsRaw.isNotEmpty) {
          paymentRow = paymentsRaw.first as Map;
        } else if (paymentsRaw is Map) {
          paymentRow = paymentsRaw;
        }

        final bookingName = (b['passenger_name'] as String?)?.trim();
        final bookingPhone = (b['passenger_phone'] as String?)?.trim();

        return {
          'bookingId': b['id'],
          'passengerName': (bookingName != null && bookingName.isNotEmpty)
              ? bookingName
              : (user['name'] ?? 'Unknown'),
          'contact': (bookingPhone != null && bookingPhone.isNotEmpty)
              ? bookingPhone
              : (user['email'] ?? user['phone'] ?? '-'),
          'seatNumber': b['seat_number'],
          'bookingStatus': b['booking_status'] ?? '-',
          'paymentMethod': paymentRow['payment_method'] ?? 'Cash',
          'amount': (paymentRow['amount'] as num?)?.toDouble() ?? 0.0,
          'paymentStatus': paymentRow['payment_status'] ?? 'Pending',
          'transactionId': paymentRow['transaction_id'] ?? '-',
        };
      }).toList();

      final capacity = (bus['capacity'] as num?)?.toInt() ?? 0;
      final totalBooked = passengerRows.length;
      final totalConfirmed = passengerRows
          .where((p) => (p['bookingStatus'] ?? '').toString().toLowerCase() == 'confirmed')
          .length;
      final totalAvailable = (capacity - totalBooked).clamp(0, capacity);

      return _buildBusPassengerListPdfBytes(
        busNumber: bus['bus_number']?.toString() ?? '-',
        transportName: bus['transport_name']?.toString() ?? '-',
        source: primaryRoute['source']?.toString() ?? '-',
        destination: primaryRoute['destination']?.toString() ?? '-',
        departureTime: primaryRoute['departure_time']?.toString() ?? '-',
        travelDate: travelDate,
        driverName: driverName.isNotEmpty ? driverName : 'Not assigned',
        capacity: capacity,
        totalBooked: totalBooked,
        totalConfirmed: totalConfirmed,
        totalAvailable: totalAvailable,
        passengers: passengerRows,
      );
    } catch (e) {
      debugPrint('[ApiService][generateBusPassengerListPdf] ERROR: $e');
      rethrow;
    }
  }

  Future<Uint8List> _buildBusPassengerListPdfBytes({
    required String busNumber,
    required String transportName,
    required String source,
    required String destination,
    required String departureTime,
    required String travelDate,
    required String driverName,
    required int capacity,
    required int totalBooked,
    required int totalConfirmed,
    required int totalAvailable,
    required List<Map<String, dynamic>> passengers,
  }) async {
    final doc = pw.Document();

    const headers = [
      'Booking ID', 'Passenger', 'Seat', 'Contact', 'Status', 'Method', 'Amount', 'Payment', 'Txn ID'
    ];

    final rows = passengers
        .map((p) => [
              p['bookingId']?.toString() ?? '-',
              p['passengerName']?.toString() ?? '-',
              p['seatNumber']?.toString() ?? '-',
              p['contact']?.toString() ?? '-',
              p['bookingStatus']?.toString() ?? '-',
              p['paymentMethod']?.toString() ?? '-',
              'PKR ${((p['amount'] as num?) ?? 0).toStringAsFixed(0)}',
              p['paymentStatus']?.toString() ?? '-',
              p['transactionId']?.toString() ?? '-',
            ])
        .toList();

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        build: (context) => [
          pw.Text('SmartTransit', style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold)),
          pw.Text('Daily Bus Passenger List', style: const pw.TextStyle(fontSize: 13, color: PdfColors.grey700)),
          pw.SizedBox(height: 16),
          pw.Container(
            padding: const pw.EdgeInsets.all(10),
            decoration: pw.BoxDecoration(
              border: pw.Border.all(color: PdfColors.grey400),
              borderRadius: pw.BorderRadius.circular(6),
            ),
            child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              _pdfInfoRow('Transport', transportName),
              _pdfInfoRow('Bus Number', busNumber),
              _pdfInfoRow('Route', '$source -> $destination'),
              _pdfInfoRow('Travel Date', travelDate),
              _pdfInfoRow('Departure Time', departureTime),
              _pdfInfoRow('Driver', driverName),
            ]),
          ),
          pw.SizedBox(height: 12),
          pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
            _pdfStat('Capacity', capacity.toString()),
            _pdfStat('Booked', totalBooked.toString()),
            _pdfStat('Confirmed', totalConfirmed.toString()),
            _pdfStat('Available', totalAvailable.toString()),
          ]),
          pw.SizedBox(height: 16),
          pw.Text('Passenger List', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 8),
          if (rows.isEmpty)
            pw.Padding(
              padding: const pw.EdgeInsets.symmetric(vertical: 20),
              child: pw.Text(
                'No passengers found for this bus on this date',
                style: const pw.TextStyle(fontSize: 12, color: PdfColors.grey700),
              ),
            )
          else
            pw.TableHelper.fromTextArray(
              headers: headers,
              data: rows,
              headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9, color: PdfColors.white),
              headerDecoration: const pw.BoxDecoration(color: PdfColors.indigo900),
              cellStyle: const pw.TextStyle(fontSize: 8),
              cellAlignment: pw.Alignment.centerLeft,
              border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
              columnWidths: {
                0: const pw.FlexColumnWidth(1.1),
                1: const pw.FlexColumnWidth(1.6),
                2: const pw.FlexColumnWidth(0.7),
                3: const pw.FlexColumnWidth(1.6),
                4: const pw.FlexColumnWidth(1.1),
                5: const pw.FlexColumnWidth(1.0),
                6: const pw.FlexColumnWidth(1.0),
                7: const pw.FlexColumnWidth(1.1),
                8: const pw.FlexColumnWidth(1.4),
              },
            ),
        ],
        footer: (context) => pw.Align(
          alignment: pw.Alignment.centerRight,
          child: pw.Text('Generated ${DateTime.now().toString().substring(0, 16)}',
              style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey500)),
        ),
      ),
    );

    return doc.save();
  }

  pw.Widget _pdfInfoRow(String label, String value) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 2),
      child: pw.Row(children: [
        pw.SizedBox(
          width: 110,
          child: pw.Text(label,
              style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold, color: PdfColors.grey700)),
        ),
        pw.Text(value, style: const pw.TextStyle(fontSize: 10)),
      ]),
    );
  }

  pw.Widget _pdfStat(String label, String value) {
    return pw.Column(children: [
      pw.Text(value, style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
      pw.Text(label, style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
    ]);
  }

  /// Get available seats for a specific BUS/transport on a specific date.
  /// A route can now be served by multiple buses, so seat availability is
  /// scoped to the exact bus the passenger picked, not the whole route.
  /// Returns { busId, date, capacity, booked: [], available: [], totalAvailable }
  Future<Map<String, dynamic>> getSeatAvailability(int busId, String date) async {
    try {
      debugPrint('[Seats] Fetching bus $busId for date=$date');

      final bus = await _supabase
          .from(_buses)
          .select('id, capacity')
          .eq('id', busId)
          .maybeSingle();

      if (bus == null) {
        debugPrint('[Seats] Bus not found — returning error info instead of silently failing');
        return {'available': [], 'booked': [], 'totalAvailable': 0, 'capacity': 0, 'error': 'Bus not found'};
      }

      final capacity = (bus['capacity'] as num?)?.toInt() ?? 50;

      final bookedRows = await _supabase
          .from(_bookings)
          .select('seat_number')
          .eq('bus_id', busId)
          .eq('departure_date', date)
          .neq('booking_status', 'cancelled');

      final booked = List<Map<String, dynamic>>.from(bookedRows)
          .map((r) => (r['seat_number'] as num).toInt())
          .toList();
      final available = [for (var seat = 1; seat <= capacity; seat++) if (!booked.contains(seat)) seat];

      debugPrint('[Seats] capacity=$capacity booked=${booked.length} available=${available.length}');

      return {
        'busId': busId,
        'date': date,
        'capacity': capacity,
        'booked': booked,
        'available': available,
        'totalAvailable': available.length,
      };
    } catch (e) {
      debugPrint('[Seats] EXCEPTION: $e');
      return {'available': [], 'booked': [], 'totalAvailable': 0, 'capacity': 0, 'error': e.toString()};
    }
  }

  Future<List<Map<String, dynamic>>> getPassengerBookings({required int passengerId}) async {
    try {
      final data = await _supabase
          .from(_bookings)
        .select('''
*,
routes(
    source,
    destination,
    departure_time,
    arrival_time,
    days_of_week,
    fare
),
buses!bookings_bus_id_fkey(
    bus_number,
    transport_name
),
payments(
    amount,
    payment_status
)
''')
          .eq('passenger_id', passengerId)
          .order('departure_date', ascending: false);
      return List<Map<String, dynamic>>.from(data);
    } catch (e) {
      debugPrint('[ApiService][getPassengerBookings] ERROR: $e');
      return [];
    }
  }

  /// Book a ticket on a specific bus/transport with a specific departure
  /// date. Payment is always Cash — paid to the driver on boarding.
  Future<Map<String, dynamic>> bookTicket({
    required int routeId,
    required int busId,
    required int seatNumber,
    required String departureDate, // YYYY-MM-DD
    required int passengerId,
    // Passenger contact details entered on the booking form. Optional so
    // any older caller keeps compiling; passed through to the bookings row
    // so Admin/Driver can see who they're actually driving for.
    String? passengerName,
    String? passengerPhone,
  }) async {
    try {
      // Seats are unique per BUS + date now (a route can have several
      // buses, each with their own independent seat map).
      final existing = await _supabase
          .from(_bookings)
          .select('id')
          .eq('bus_id', busId)
          .eq('departure_date', departureDate)
          .eq('seat_number', seatNumber)
          .neq('booking_status', 'cancelled')
          .maybeSingle();

      if (existing != null) {
        return {'status': 'error', 'message': 'That seat is already booked for this date.'};
      }

      final inserted = await _supabase
    .from(_bookings)
    .insert({
      'passenger_id': passengerId,
      'route_id': routeId,
      'bus_id': busId,
      'seat_number': seatNumber,
      'departure_date': departureDate,
      'booking_status': 'confirmed',
      if (passengerName != null && passengerName.trim().isNotEmpty)
        'passenger_name': passengerName.trim(),
      if (passengerPhone != null && passengerPhone.trim().isNotEmpty)
        'passenger_phone': passengerPhone.trim(),
    })
    .select()
    .single();

// Get the fare from the selected route
final route = await _supabase
    .from(_routes)
    .select('fare')
    .eq('id', routeId)
    .single();

// Create payment record
try {
  await _supabase.from(_payments).insert({
    'booking_id': inserted['id'],
    'amount': route['fare'] ?? 0,
    'payment_method': 'Cash',
    'payment_status': 'pending',
    'transaction_id':
        'TXN-${DateTime.now().millisecondsSinceEpoch}',
    'payment_date': DateTime.now().toIso8601String(),
  });

  debugPrint("PAYMENT INSERTED SUCCESSFULLY");
} catch (e) {
  debugPrint("PAYMENT INSERT ERROR:");
  debugPrint(e.toString());
}

return {
  'status': 'success',
  'data': inserted,
};
    } on PostgrestException catch (e) {
      // Unique-constraint violation on (bus_id, departure_date, seat_number)
      if (e.code == '23505') {
        return {'status': 'error', 'message': 'That seat is already booked for this date.'};
      }
      return {'status': 'error', 'message': e.message};
    } catch (e) {
      return {'status': 'error', 'message': e.toString()};
    }
  }

  /// Cancels a booking owned by [passengerId].
  ///
  /// This never chains `.single()` (or `.maybeSingle()`) directly onto an
  /// update-then-select call. Depending on Row Level Security policies, the
  /// SELECT that PostgREST performs *after* the UPDATE can legitimately come
  /// back with zero rows (for example, a policy that only lets a passenger
  /// read their own *non-cancelled* bookings would hide the row the instant
  /// it becomes 'cancelled') even though the update itself succeeded.
  /// `.single()` throws PGRST116 ("The result contains 0 rows...") in that
  /// situation, and `.maybeSingle()` would incorrectly report "Booking not
  /// found" for an update that actually worked.
  ///
  /// To avoid both problems, AND to avoid the opposite mistake — silently
  /// reporting success when the update actually matched zero rows (e.g.
  /// blocked by an UPDATE RLS policy, so nothing changed at all):
  ///   1. First look up the booking by id (a plain `.maybeSingle()` on a
  ///      pure SELECT, which legitimately returns 0 or 1 rows) to confirm it
  ///      exists and is owned by this passenger, and to give a precise error
  ///      message instead of a raw Postgrest exception.
  ///   2. Perform the UPDATE with a plain `.select()` (no `.single()`), which
  ///      returns a List. If that list is non-empty, the update is confirmed
  ///      applied — return success using the freshly-updated row.
  ///   3. If that list comes back EMPTY, do NOT assume success. Re-read the
  ///      booking's current status directly. Only report success if the
  ///      status is actually 'cancelled' in the database; otherwise report a
  ///      real error so the passenger isn't shown a false "cancelled"
  ///      confirmation for a row that never changed.
  Future<Map<String, dynamic>> cancelBooking(int bookingId, {required int passengerId}) async {
    try {
      // Step 1: verify the booking exists and belongs to this passenger.
      final existing = await _supabase
          .from(_bookings)
          .select('id, passenger_id, booking_status')
          .eq('id', bookingId)
          .maybeSingle();

      if (existing == null) {
        return {'status': 'error', 'message': 'Booking not found.'};
      }

      final ownerId = (existing['passenger_id'] as num?)?.toInt();
      if (ownerId != passengerId) {
        return {'status': 'error', 'message': 'You are not authorized to cancel this booking.'};
      }

      final currentStatus = (existing['booking_status'] ?? '').toString().trim().toLowerCase();
      if (currentStatus == 'cancelled') {
        return {'status': 'success', 'message': 'Booking is already cancelled.', 'data': existing};
      }

      // Step 2: perform the cancellation. Use a plain `.select()` (returns a
      // List) instead of `.single()`/`.maybeSingle()` so that zero rows
      // coming back from the post-update read is never treated as a thrown
      // error.
      final updatedRows = await _supabase
          .from(_bookings)
          .update({'booking_status': 'cancelled'})
          .eq('id', bookingId)
          .eq('passenger_id', passengerId)
          .select();

      final updatedList = List<Map<String, dynamic>>.from(updatedRows);

      if (updatedList.isNotEmpty) {
        // The update definitely applied and PostgREST handed the new row
        // straight back — this is the normal, confirmed-success path.
        return {
          'status': 'success',
          'message': 'Booking cancelled successfully.',
          'data': updatedList.first,
        };
      }

      // Step 3: the update's own SELECT-back returned zero rows. This is
      // ambiguous on its own — it can mean either (a) the update succeeded
      // but an RLS SELECT policy hid the now-cancelled row, or (b) the
      // update matched nothing at all (e.g. an UPDATE RLS policy silently
      // blocked it) and NOTHING changed. We must not guess "success" here —
      // re-check the booking's real status with a fresh read before
      // deciding what to tell the passenger.
      final verify = await _supabase
          .from(_bookings)
          .select('id, booking_status')
          .eq('id', bookingId)
          .maybeSingle();

      final verifiedStatus = (verify?['booking_status'] ?? '').toString().trim().toLowerCase();
      if (verifiedStatus == 'cancelled') {
        return {
          'status': 'success',
          'message': 'Booking cancelled successfully.',
          'data': verify,
        };
      }

      // The booking still isn't cancelled — the update did not apply.
      // Report a real failure instead of a false-positive success.
      return {
        'status': 'error',
        'message':
            'Could not cancel booking — the update did not go through (this may be a permissions issue). Please try again.',
      };
    } on PostgrestException catch (e) {
      return {'status': 'error', 'message': e.message};
    } catch (e) {
      return {'status': 'error', 'message': e.toString()};
    }
  }

  Future<List<Map<String, dynamic>>> getMyPayments({required int passengerId}) async {
  try {
    final data = await _supabase
        .from(_payments)
        .select('''
          *,
          bookings!inner(
            id,
            passenger_id,
            booking_status,
            seat_number,
            departure_date,
            routes(source,destination)
          )
        ''')
        .eq('bookings.passenger_id', passengerId)
        .order('payment_date', ascending: false);

    // NOTE: payment rows for cancelled bookings are intentionally still
    // returned here — they must remain in the database and in this list for
    // transaction-history purposes. It is the passenger Payments TAB (in
    // passenger_dashboard.dart) that hides them from view / Total Paid,
    // using the `booking_status` now included above; nothing is deleted or
    // filtered at the query level.
    return List<Map<String, dynamic>>.from(data);
  } catch (e) {
    debugPrint('[ApiService][getMyPayments] ERROR: $e');
    return [];
  }
}

  // Legacy alias
  Future<List<Map<String, dynamic>>> getPassengerPayments({required int passengerId}) async =>
      getMyPayments(passengerId: passengerId);

Future<List<Map<String, dynamic>>> getAdminPassengers() async  {
  try {
    final data = await _supabase
        .from(_bookings)
        .select('''
          *,
          users!bookings_passenger_id_fkey(
            name,
            email
          ),
          routes(
            source,
            destination,
            departure_time
          ),
          buses!bookings_bus_id_fkey(
            bus_number,
            transport_name
          ),
          payments(
            amount,
            payment_status
          )
        ''')
        // Was previously '.neq('booking_status', 'Cancelled')' (capital C).
        // Postgres string comparisons are case-sensitive and the DB stores
        // the lowercase value 'cancelled', so that filter silently matched
        // nothing and let cancelled bookings leak into every downstream
        // count (Passengers tab, "0 paid" header, Tickets Sold, Upcoming
        // Bookings). Use the actual stored value.
        .neq('booking_status', 'cancelled')
        .order('departure_date', ascending: false);

   final rows = List<Map<String, dynamic>>.from(data);

debugPrint("ADMIN PASSENGERS = ${rows.length}");
debugPrint(rows.toString());

return rows.map((e) {
      final user = e['users'] ?? {};
      final route = e['routes'] ?? {};
      final bus = e['buses'] ?? {};

      final payment = Map<String, dynamic>.from(e['payments'] ?? {});

      return {
        ...e,
        'departureDate': e['departure_date'],
        'passengerName': ((e['passenger_name'] as String?)?.trim().isNotEmpty ?? false)
            ? e['passenger_name']
            : (user['name'] ?? 'Unknown'),
        'passengerPhone': (e['passenger_phone'] as String?)?.trim() ?? '',
        'passengerEmail': user['email'] ?? '',
        'source': route['source'] ?? '-',
        'destination': route['destination'] ?? '-',
        'departureTime': route['departure_time'] ?? '-',
        'busNumber': bus['bus_number'] ?? '-',
        'transportName': bus['transport_name'] ?? '-',
        'paymentStatus': payment['payment_status'] ?? 'Pending',
        'amount': payment['amount'] ?? 0,
      };
    }).toList();
  } catch (e) {
    debugPrint('[ApiService][getAdminPassengers] ERROR: $e');
    return [];
  }
    }
    Future<List<Map<String, dynamic>>> getDriverPendingPayments({
  required int driverId,
}) async {
  try {
    final data = await _supabase
        .from(_payments)
        .select('''
          *,
          bookings!inner(
            id,
            passenger_id,
            seat_number,
            departure_date,
            passenger_name,
            passenger_phone,
            buses!inner(bus_number, transport_name, driver_id),
            users(name)
          )
        ''')
        .eq('payment_status', 'pending')
        .eq('bookings.buses.driver_id', driverId)
        .order('payment_date', ascending: false);

    return List<Map<String, dynamic>>.from(data).map((e) {
      final booking = e['bookings'] ?? {};
      final user = booking['users'] ?? {};
      final bus = booking['buses'] ?? {};
      return {
        ...e,
        'passengerName': ((booking['passenger_name'] as String?)?.trim().isNotEmpty ?? false)
            ? booking['passenger_name']
            : (user['name'] ?? 'Passenger'),
        'passengerPhone': (booking['passenger_phone'] as String?)?.trim() ?? '',
        'busNumber': bus['bus_number'] ?? '-',
        'transportName': bus['transport_name'] ?? '-',
      };
    }).toList();
  } catch (e) {
    debugPrint(e.toString());
    return [];
  }
}Future<bool> confirmCashPayment({
  required int paymentId,
}) async {
  try {
    await _supabase
        .from(_payments)
        .update({
          'payment_status': 'confirmed',
        })
        .eq('id', paymentId);

    return true;
  } catch (e) {
    debugPrint(e.toString());
    return false;
  }
}

    
    }