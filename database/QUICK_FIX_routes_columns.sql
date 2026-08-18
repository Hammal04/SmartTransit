-- ═══════════════════════════════════════════════════════════════════════════════
-- QUICK FIX — Adds arrival_time + days_of_week to the routes table
-- Run this ENTIRE script in MySQL Workbench against your smart_transit database.
-- Safe to run multiple times — will not error if columns already exist.
-- ═══════════════════════════════════════════════════════════════════════════════

USE smart_transit;

DROP PROCEDURE IF EXISTS qf_add_route_columns;

DELIMITER $$
CREATE PROCEDURE qf_add_route_columns()
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

CALL qf_add_route_columns();
DROP PROCEDURE IF EXISTS qf_add_route_columns;

-- ── Verify the fix worked ───────────────────────────────────────────────────
SELECT 'Routes table now has these columns:' AS result;
DESCRIBE routes;
