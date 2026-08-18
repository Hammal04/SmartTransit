-- ═══════════════════════════════════════════════════════════════════════════════
-- Smart Transit — Complete Schema Migration (v3)
-- Run this in MySQL Workbench after schema.sql.
-- Safe to re-run on any existing database.
-- ═══════════════════════════════════════════════════════════════════════════════

USE smart_transit;
SET FOREIGN_KEY_CHECKS = 0;

-- ─── 1. Add arrival_time + days_of_week to routes ────────────────────────────
DROP PROCEDURE IF EXISTS st_add_route_columns;
DELIMITER $$
CREATE PROCEDURE st_add_route_columns()
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'routes'
      AND COLUMN_NAME = 'arrival_time'
  ) THEN
    ALTER TABLE routes ADD COLUMN arrival_time TIME DEFAULT NULL AFTER departure_time;
    SELECT 'Added arrival_time to routes' AS migration_log;
  ELSE
    SELECT 'arrival_time already exists' AS migration_log;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'routes'
      AND COLUMN_NAME = 'days_of_week'
  ) THEN
    ALTER TABLE routes ADD COLUMN days_of_week VARCHAR(50) NOT NULL DEFAULT 'Daily' AFTER arrival_time;
    SELECT 'Added days_of_week to routes' AS migration_log;
  ELSE
    SELECT 'days_of_week already exists' AS migration_log;
  END IF;
END$$
DELIMITER ;
CALL st_add_route_columns();
DROP PROCEDURE IF EXISTS st_add_route_columns;

-- ─── 2. Add departure_date to bookings ────────────────────────────────────────
-- Passengers now choose a specific travel date when booking.
DROP PROCEDURE IF EXISTS st_add_booking_date;
DELIMITER $$
CREATE PROCEDURE st_add_booking_date()
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'bookings'
      AND COLUMN_NAME = 'departure_date'
  ) THEN
    ALTER TABLE bookings ADD COLUMN departure_date DATE NOT NULL DEFAULT (CURDATE()) AFTER route_id;
    SELECT 'Added departure_date to bookings' AS migration_log;
  ELSE
    SELECT 'departure_date already exists' AS migration_log;
  END IF;
END$$
DELIMITER ;
CALL st_add_booking_date();
DROP PROCEDURE IF EXISTS st_add_booking_date;

-- ─── 3. Recreate payments table (Cash-only, no gateway) ───────────────────────
DROP TABLE IF EXISTS payments;
CREATE TABLE payments (
    payment_id     INT           PRIMARY KEY AUTO_INCREMENT,
    booking_id     INT           NOT NULL,
    user_id        INT           NOT NULL,
    amount         DECIMAL(10,2) NOT NULL,
    payment_method VARCHAR(20)   NOT NULL DEFAULT 'Cash',
    transaction_id VARCHAR(120)  DEFAULT NULL,
    status         VARCHAR(20)   NOT NULL DEFAULT 'Pending',  -- Pending | Paid | Failed
    notes          VARCHAR(255)  DEFAULT NULL,
    payment_date   TIMESTAMP     NULL DEFAULT NULL,
    created_at     TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_pay_booking FOREIGN KEY (booking_id) REFERENCES bookings(id) ON DELETE CASCADE,
    CONSTRAINT fk_pay_user    FOREIGN KEY (user_id)    REFERENCES users(id)    ON DELETE CASCADE,
    CONSTRAINT uq_pay_booking UNIQUE (booking_id)
);

-- Seed sample payments
INSERT INTO payments (payment_id, booking_id, user_id, amount, payment_method, transaction_id, status, payment_date)
VALUES
  (1, 1, 3, 2.75, 'Cash', 'CASH-20260624-001', 'Paid',    '2026-06-24 08:01:00'),
  (2, 2, 3, 3.00, 'Cash', NULL,                 'Pending', NULL)
ON DUPLICATE KEY UPDATE status = VALUES(status);

-- Indexes
DROP INDEX IF EXISTS idx_pay_user   ON payments;
DROP INDEX IF EXISTS idx_pay_status ON payments;
CREATE INDEX idx_pay_user   ON payments(user_id);
CREATE INDEX idx_pay_status ON payments(status);

-- ─── 4. Update seeded routes with new columns ─────────────────────────────────
UPDATE routes SET
  arrival_time = '08:45:00',
  days_of_week = 'Mon,Tue,Wed,Thu,Fri'
WHERE id = 1;

UPDATE routes SET
  arrival_time = '10:15:00',
  days_of_week = 'Mon,Wed,Fri'
WHERE id = 2;

UPDATE routes SET
  arrival_time = '07:50:00',
  days_of_week = 'Daily'
WHERE id = 3;

-- Update existing bookings with a departure_date
UPDATE bookings SET departure_date = '2026-06-24' WHERE id = 1;
UPDATE bookings SET departure_date = '2026-06-25' WHERE id = 2;

SET FOREIGN_KEY_CHECKS = 1;

-- ─── Verify ───────────────────────────────────────────────────────────────────
SELECT 'routes columns:' AS info; SHOW COLUMNS FROM routes;
SELECT 'bookings columns:' AS info; SHOW COLUMNS FROM bookings;
SELECT 'payments columns:' AS info; SHOW COLUMNS FROM payments;
