// Dart models — Smart Transit v2
// Database roles: 1=Admin, 2=Driver, 3=Passenger

/// Role constants — must match the `roles` table in MySQL exactly.
class UserRoles {
  static const String admin     = 'Admin';
  static const String driver    = 'Driver';
  static const String passenger = 'Passenger';

  /// Convert a numeric role_id (from the DB) into the canonical role string.
  static String fromRoleId(int roleId) {
    switch (roleId) {
      case 1: return admin;
      case 2: return driver;
      case 3: return passenger;
      default:
        throw ArgumentError(
          '[RBAC] Unknown role_id=$roleId — expected 1=Admin, 2=Driver, 3=Passenger.');
    }
  }
}

// ─── User ─────────────────────────────────────────────────────────────────────
class User {
  final int    id;
  final String name;
  final String email;
  final String role;           // 'Admin' | 'Driver' | 'Passenger'
  final double walletBalance;

  const User({
    required this.id,
    required this.name,
    required this.email,
    required this.role,
    required this.walletBalance,
  });

  factory User.fromJson(Map<String, dynamic> json) {
    // Resolve role from the string field first, fall back to numeric role_id.
    // DO NOT default to 'Passenger' — a missing role is a server bug that must
    // surface immediately so it can be fixed at the source.
    String resolvedRole;

    final dynamic rawRole   = json['role'];
    final dynamic rawRoleId = json['role_id'] ?? json['roleId'];

    if (rawRole is String && rawRole.isNotEmpty) {
      resolvedRole = rawRole;
    } else if (rawRoleId != null) {
      resolvedRole = UserRoles.fromRoleId(rawRoleId as int);
    } else {
      throw StateError(
        '[RBAC] Server response is missing the "role" field.\n'
        'Raw user JSON: $json\n'
        'Fix the backend login handler to always include "role".',
      );
    }

    // ignore: avoid_print
    print('[RBAC][User.fromJson] id=${json['id']} '
        'raw_role=$rawRole raw_role_id=$rawRoleId resolved_role=$resolvedRole');

    return User(
      id:            json['id'] as int,
      name:          json['name'] as String,
      email:         json['email'] as String,
      role:          resolvedRole,
      walletBalance: (json['walletBalance'] ?? json['wallet_balance'] ?? 0.0).toDouble(),
    );
  }

  Map<String, dynamic> toJson() => {
    'id':            id,
    'name':          name,
    'email':         email,
    'role':          role,
    'walletBalance': walletBalance,
  };

  User copyWith({double? walletBalance}) => User(
    id: id, name: name, email: email, role: role,
    walletBalance: walletBalance ?? this.walletBalance,
  );
}

// ─── Bus (mirrors the `buses` table) ─────────────────────────────────────────
class Bus {
  final int     id;
  final String  busNumber;
  final int?    driverId;
  final int     capacity;
  final String  status;
  final String? driverName;

  const Bus({
    required this.id,
    required this.busNumber,
    this.driverId,
    required this.capacity,
    required this.status,
    this.driverName,
  });

  factory Bus.fromJson(Map<String, dynamic> json) => Bus(
    id:         json['id'] as int,
    busNumber:  json['bus_number'] as String,
    driverId:   json['driver_id'] as int?,
    capacity:   (json['capacity'] ?? 50) as int,
    status:     json['status'] ?? 'active',
    driverName: json['driverName'] as String?,
  );
}

// ─── Route (mirrors the `routes` table) ──────────────────────────────────────
class TransitRoute {
  final int    id;
  final int    busId;
  final String source;
  final String destination;
  final String departureTime;
  final double fare;
  final String? busNumber;

  const TransitRoute({
    required this.id,
    required this.busId,
    required this.source,
    required this.destination,
    required this.departureTime,
    required this.fare,
    this.busNumber,
  });

  factory TransitRoute.fromJson(Map<String, dynamic> json) => TransitRoute(
    id:            json['id'] as int,
    busId:         json['bus_id'] as int,
    source:        json['source'] as String,
    destination:   json['destination'] as String,
    departureTime: json['departure_time'] as String,
    fare:          (json['fare'] ?? 0.0).toDouble(),
    busNumber:     json['bus_number'] as String?,
  );
}

// ─── Booking (mirrors the `bookings` table) ───────────────────────────────────
class Booking {
  final int    id;
  final int    passengerId;
  final int    routeId;
  final int    seatNumber;
  final String bookingDate;
  final String bookingStatus;     // Pending | Confirmed | Cancelled
  // Joined fields
  final String? source;
  final String? destination;
  final String? departureTime;
  final String? busNumber;
  final String? paymentStatus;    // Paid | Pending | Failed
  final String? transactionId;
  final double? amount;

  const Booking({
    required this.id,
    required this.passengerId,
    required this.routeId,
    required this.seatNumber,
    required this.bookingDate,
    required this.bookingStatus,
    this.source,
    this.destination,
    this.departureTime,
    this.busNumber,
    this.paymentStatus,
    this.transactionId,
    this.amount,
  });

  factory Booking.fromJson(Map<String, dynamic> json) => Booking(
    id:             json['id'] as int,
    passengerId:    json['passenger_id'] as int? ?? 0,
    routeId:        json['route_id'] as int,
    seatNumber:     json['seat_number'] as int,
    bookingDate:    json['booking_date']?.toString() ?? '',
    bookingStatus:  json['booking_status'] ?? 'Pending',
    source:         json['source'] as String?,
    destination:    json['destination'] as String?,
    departureTime:  json['departure_time'] as String?,
    busNumber:      json['bus_number'] as String?,
    paymentStatus:  json['payment_status'] as String?,
    transactionId:  json['transaction_id'] as String?,
    amount:         (json['amount'] ?? json['fare'] ?? 0.0).toDouble(),
  );
}

// ─── Payment (mirrors the `payments` table) ───────────────────────────────────
class Payment {
  final int    id;
  final int    bookingId;
  final double amount;
  final String paymentMethod;
  final String paymentStatus;     // Paid | Pending | Failed
  final String? transactionId;
  final String paymentDate;
  // Joined fields
  final String? source;
  final String? destination;

  const Payment({
    required this.id,
    required this.bookingId,
    required this.amount,
    required this.paymentMethod,
    required this.paymentStatus,
    this.transactionId,
    required this.paymentDate,
    this.source,
    this.destination,
  });

  factory Payment.fromJson(Map<String, dynamic> json) => Payment(
    id:             json['id'] as int,
    bookingId:      json['booking_id'] as int,
    amount:         (json['amount'] ?? 0.0).toDouble(),
    paymentMethod:  json['payment_method'] ?? 'Wallet',
    paymentStatus:  json['payment_status'] ?? 'Pending',
    transactionId:  json['transaction_id'] as String?,
    paymentDate:    json['payment_date']?.toString() ?? '',
    source:         json['source'] as String?,
    destination:    json['destination'] as String?,
  );
}

// ─── Vehicle (kept for backwards compatibility with any live-map usage) ────────
class Vehicle {
  final String id;
  final String name;
  final String mode;
  final double lat;
  final double lng;
  final String status;

  const Vehicle({
    required this.id,
    required this.name,
    required this.mode,
    required this.lat,
    required this.lng,
    required this.status,
  });

  factory Vehicle.fromJson(Map<String, dynamic> json) => Vehicle(
    id:     json['id']?.toString() ?? '',
    name:   json['name'] ?? '',
    mode:   json['mode'] ?? 'bus',
    lat:    (json['lat'] ?? json['latitude'] ?? 0.0).toDouble(),
    lng:    (json['lng'] ?? json['longitude'] ?? 0.0).toDouble(),
    status: json['status'] ?? 'on_time',
  );
}
