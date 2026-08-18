-- ═══════════════════════════════════════════════════════════════════════════════
-- QUICK FIX — Complete schema sync for routes, bookings, and payments tables
-- Run this ENTIRE script in MySQL Workbench against your smart_transit database.
-- Safe to run multiple times — will not error if columns already exist.
-- ═══════════════════════════════════════════════════════════════════════════════

USE smart_transit;

-- ─── 1. routes: arrival_time + days_of_week ───────────────────────────────────
DROP PROCEDURE IF EXISTS qf_fix_routes;
DELIMITER $$
CREATE PROCEDURE qf_fix_routes()
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'routes' AND COLUMN_NAME = 'arrival_time'
  ) THEN
    ALTER TABLE routes ADD COLUMN arrival_time TIME DEFAULT NULL AFTER departure_time;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'routes' AND COLUMN_NAME = 'days_of_week'
  ) THEN
    ALTER TABLE routes ADD COLUMN days_of_week VARCHAR(50) NOT NULL DEFAULT 'Daily' AFTER arrival_time;
  END IF;
END$$
DELIMITER ;
CALL qf_fix_routes();
DROP PROCEDURE IF EXISTS qf_fix_routes;

-- ─── 2. bookings: departure_date ───────────────────────────────────────────────
DROP PROCEDURE IF EXISTS qf_fix_bookings;
DELIMITER $$
CREATE PROCEDURE qf_fix_bookings()
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'bookings' AND COLUMN_NAME = 'departure_date'
  ) THEN
    ALTER TABLE bookings ADD COLUMN departure_date DATE NOT NULL DEFAULT (CURDATE()) AFTER route_id;
  END IF;
END$$
DELIMITER ;
CALL qf_fix_bookings();
DROP PROCEDURE IF EXISTS qf_fix_bookings;

-- ─── 3. payments: cash-only schema (drops gateway_ref/fail_reason, adds notes) ─
-- Only recreates if the OLD gateway-based schema is detected (has gateway_ref column)
DROP PROCEDURE IF EXISTS qf_fix_payments;
DELIMITER $$
CREATE PROCEDURE qf_fix_payments()
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'payments' AND COLUMN_NAME = 'gateway_ref'
  ) THEN
    -- Old gateway-based table detected — drop and recreate as cash-only
    SET FOREIGN_KEY_CHECKS = 0;
    DROP TABLE payments;
    SET FOREIGN_KEY_CHECKS = 1;

    CREATE TABLE payments (
        payment_id     INT           PRIMARY KEY AUTO_INCREMENT,
        booking_id     INT           NOT NULL,
        user_id        INT           NOT NULL,
        amount         DECIMAL(10,2) NOT NULL,
        payment_method VARCHAR(20)   NOT NULL DEFAULT 'Cash',
        transaction_id VARCHAR(120)  DEFAULT NULL,
        status         VARCHAR(20)   NOT NULL DEFAULT 'Pending',
        notes          VARCHAR(255)  DEFAULT NULL,
        payment_date   TIMESTAMP     NULL DEFAULT NULL,
        created_at     TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
        CONSTRAINT fk_pay_booking FOREIGN KEY (booking_id) REFERENCES bookings(id) ON DELETE CASCADE,
        CONSTRAINT fk_pay_user    FOREIGN KEY (user_id)    REFERENCES users(id)    ON DELETE CASCADE,
        CONSTRAINT uq_pay_booking UNIQUE (booking_id)
    );

  ELSEIF NOT EXISTS (
    SELECT 1 FROM information_schema.TABLES
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'payments'
  ) THEN
    -- Table doesn't exist at all — create fresh
    CREATE TABLE payments (
        payment_id     INT           PRIMARY KEY AUTO_INCREMENT,
        booking_id     INT           NOT NULL,
        user_id        INT           NOT NULL,
        amount         DECIMAL(10,2) NOT NULL,
        payment_method VARCHAR(20)   NOT NULL DEFAULT 'Cash',
        transaction_id VARCHAR(120)  DEFAULT NULL,
        status         VARCHAR(20)   NOT NULL DEFAULT 'Pending',
        notes          VARCHAR(255)  DEFAULT NULL,
        payment_date   TIMESTAMP     NULL DEFAULT NULL,
        created_at     TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
        CONSTRAINT fk_pay_booking FOREIGN KEY (booking_id) REFERENCES bookings(id) ON DELETE CASCADE,
        CONSTRAINT fk_pay_user    FOREIGN KEY (user_id)    REFERENCES users(id)    ON DELETE CASCADE,
        CONSTRAINT uq_pay_booking UNIQUE (booking_id)
    );
  END IF;
END$$
DELIMITER ;
CALL qf_fix_payments();
DROP PROCEDURE IF EXISTS qf_fix_payments;

-- ─── Backfill departure_date on any existing bookings ────────────────────────
-- Disable safe update mode so we can UPDATE without filtering on the primary key.
-- id > 0 satisfies the safe-mode PK requirement while still matching all rows.
SET SQL_SAFE_UPDATES = 0;
UPDATE bookings
SET    departure_date = DATE(booking_date)
WHERE  id > 0
  AND  booking_date IS NOT NULL;
SET SQL_SAFE_UPDATES = 1;

-- ─── Verify everything ──────────────────────────────────────────────────────
SELECT '✓ routes columns:'   AS result; DESCRIBE routes;
SELECT '✓ bookings columns:' AS result; DESCRIBE bookings;
SELECT '✓ payments columns:' AS result; DESCRIBE payments;
