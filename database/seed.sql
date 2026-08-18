-- Smart Transit — Seed Data v2
-- All passwords are bcrypt (cost 10), compatible with bcryptjs used in server.js
--
-- Credentials:
--   admin@smarttransit.com   password: admin123
--   driver@smarttransit.com  password: driver123
--   m.vance@aerotech.com     password: passenger123
--
-- Admin and Driver accounts are seeded here and cannot be registered from the app.
-- Passengers register themselves through the registration screen.

USE smart_transit;

-- ── Roles ─────────────────────────────────────────────────────────────────────
INSERT INTO roles (id, name) VALUES
  (1, 'Admin'),
  (2, 'Driver'),
  (3, 'Passenger')
ON DUPLICATE KEY UPDATE name = VALUES(name);

-- ── Users (bcrypt hashes, cost 10) ────────────────────────────────────────────
INSERT INTO users (id, name, email, password, role_id, wallet_balance) VALUES
  (1, 'System Administrator', 'admin@smarttransit.com',
      '$2b$10$PNJldbZW4mlzSYA4npEpP.Eqi44JlUXGQ5AQr7gdG2Dh2g.1Bpe7q',
      1, 0.00),
  (2, 'John Doe', 'driver@smarttransit.com',
      '$2b$10$bq24YNirU6.btDNdsnGLL.v3VqkbENBiu2JhwvzwxPxtdOSxrUhl.',
      2, 0.00),
  (3, 'Marcus Vance', 'm.vance@aerotech.com',
      '$2b$10$LsFGf0Ix3kKKsp/lZfKIB.x6vR2QrJmj1lxNce8Snng/uFMdpaoye',
      3, 100.00)
ON DUPLICATE KEY UPDATE
  name           = VALUES(name),
  role_id        = VALUES(role_id),
  wallet_balance = VALUES(wallet_balance);

-- ── Drivers ───────────────────────────────────────────────────────────────────
INSERT INTO drivers (id, user_id, license_number, status) VALUES
  (1, 2, 'TX-DRV-88910-A', 'active')
ON DUPLICATE KEY UPDATE status = VALUES(status);

-- ── Buses ─────────────────────────────────────────────────────────────────────
INSERT INTO buses (id, bus_number, driver_id, capacity, status) VALUES
  (1, 'BUS-101', 1,    55, 'active'),
  (2, 'BUS-102', NULL, 40, 'active')
ON DUPLICATE KEY UPDATE bus_number = VALUES(bus_number);

-- ── Routes ────────────────────────────────────────────────────────────────────
-- Each route runs on specific days at a fixed departure + arrival time.
-- Days: Mon Tue Wed Thu Fri Sat Sun  (or 'Daily' / 'Weekdays' / 'Weekends')
INSERT INTO routes (id, bus_id, source, destination, departure_time, arrival_time, days_of_week, fare) VALUES
  (1, 1, 'Central Terminal', 'North Gate',       '08:00:00', '08:45:00', 'Mon,Tue,Wed,Thu,Fri', 2.75),
  (2, 1, 'Central Terminal', 'Science Hub',      '09:30:00', '10:15:00', 'Mon,Wed,Fri',         3.00),
  (3, 2, 'South Airport',    'Central Terminal', '07:00:00', '07:50:00', 'Daily',               4.50)
ON DUPLICATE KEY UPDATE
  departure_time = VALUES(departure_time),
  arrival_time   = VALUES(arrival_time),
  days_of_week   = VALUES(days_of_week),
  fare           = VALUES(fare);

-- ── Bookings ──────────────────────────────────────────────────────────────────
INSERT INTO bookings (id, passenger_id, route_id, seat_number, booking_date, booking_status) VALUES
  (1, 3, 1, 12, '2026-06-24 08:00:00', 'Confirmed'),
  (2, 3, 2,  5, '2026-06-25 09:30:00', 'Pending')
ON DUPLICATE KEY UPDATE booking_status = VALUES(booking_status);

-- ── Payments ──────────────────────────────────────────────────────────────────
INSERT INTO payments (id, booking_id, amount, payment_method, payment_status, transaction_id) VALUES
  (1, 1, 2.75, 'Wallet', 'Paid',    'TXN-20260624-001'),
  (2, 2, 3.00, 'Wallet', 'Pending', NULL)
ON DUPLICATE KEY UPDATE payment_status = VALUES(payment_status);
