-- Smart Transit Management System — RBAC Schema v2
-- MySQL 8.0+  |  roles: 1=Admin, 2=Driver, 3=Passenger

CREATE DATABASE IF NOT EXISTS smart_transit;
USE smart_transit;

-- ─── 1. Roles ────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS roles (
    id   INT         PRIMARY KEY AUTO_INCREMENT,
    name VARCHAR(20) NOT NULL UNIQUE
);

-- ─── 2. Users ─────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS users (
    id             INT           PRIMARY KEY AUTO_INCREMENT,
    name           VARCHAR(100)  NOT NULL,
    email          VARCHAR(100)  NOT NULL UNIQUE,
    password       VARCHAR(255)  NOT NULL,
    role_id        INT           NOT NULL,
    wallet_balance DECIMAL(10,2) DEFAULT 0.00,
    created_at     TIMESTAMP     DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (role_id) REFERENCES roles(id)
);

-- ─── 3. Drivers ───────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS drivers (
    id             INT         PRIMARY KEY AUTO_INCREMENT,
    user_id        INT         NOT NULL UNIQUE,
    license_number VARCHAR(50) NOT NULL UNIQUE,
    status         VARCHAR(20) DEFAULT 'active',
    hired_date     TIMESTAMP   DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);

-- ─── 4. Buses ─────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS buses (
    id         INT         PRIMARY KEY AUTO_INCREMENT,
    bus_number VARCHAR(20) NOT NULL UNIQUE,
    driver_id  INT         DEFAULT NULL,
    capacity   INT         NOT NULL DEFAULT 50,
    status     VARCHAR(20) DEFAULT 'active',
    FOREIGN KEY (driver_id) REFERENCES drivers(id) ON DELETE SET NULL
);

-- ─── 5. Routes ────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS routes (
    id             INT           PRIMARY KEY AUTO_INCREMENT,
    bus_id         INT           NOT NULL,
    source         VARCHAR(100)  NOT NULL,
    destination    VARCHAR(100)  NOT NULL,
    departure_time TIME          NOT NULL,
    arrival_time   TIME          DEFAULT NULL,
    days_of_week   VARCHAR(50)   NOT NULL DEFAULT 'Mon,Tue,Wed,Thu,Fri',
    -- days_of_week: comma-separated abbreviations e.g. 'Mon,Wed,Fri' or 'Daily'
    fare           DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    FOREIGN KEY (bus_id) REFERENCES buses(id) ON DELETE CASCADE
);

-- ─── 6. Bookings ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS bookings (
    id             INT         PRIMARY KEY AUTO_INCREMENT,
    passenger_id   INT         NOT NULL,
    route_id       INT         NOT NULL,
    seat_number    INT         NOT NULL,
    booking_date   TIMESTAMP   DEFAULT CURRENT_TIMESTAMP,
    booking_status VARCHAR(20) DEFAULT 'Pending',
    FOREIGN KEY (passenger_id) REFERENCES users(id)  ON DELETE CASCADE,
    FOREIGN KEY (route_id)     REFERENCES routes(id) ON DELETE CASCADE
);

-- ─── 7. Payments ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS payments (
    id             INT           PRIMARY KEY AUTO_INCREMENT,
    booking_id     INT           NOT NULL UNIQUE,
    amount         DECIMAL(10,2) NOT NULL,
    payment_method VARCHAR(50)   DEFAULT 'Wallet',
    payment_status VARCHAR(20)   DEFAULT 'Pending',
    transaction_id VARCHAR(100)  DEFAULT NULL,
    payment_date   TIMESTAMP     DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (booking_id) REFERENCES bookings(id) ON DELETE CASCADE
);

-- ─── Indexes ──────────────────────────────────────────────────────────────────
-- MySQL 8.0 does NOT support CREATE INDEX IF NOT EXISTS or DROP INDEX IF EXISTS.
-- We use a stored procedure that checks information_schema before acting,
-- making this script fully safe to run on both a fresh and existing database.

DROP PROCEDURE IF EXISTS smart_transit_create_indexes;

DELIMITER $$

CREATE PROCEDURE smart_transit_create_indexes()
BEGIN
    -- Helper: drop an index only if it already exists
    IF EXISTS (
        SELECT 1 FROM information_schema.STATISTICS
        WHERE TABLE_SCHEMA = 'smart_transit'
          AND TABLE_NAME   = 'buses'
          AND INDEX_NAME   = 'idx_buses_driver'
    ) THEN
        DROP INDEX idx_buses_driver ON buses;
    END IF;

    IF EXISTS (
        SELECT 1 FROM information_schema.STATISTICS
        WHERE TABLE_SCHEMA = 'smart_transit'
          AND TABLE_NAME   = 'routes'
          AND INDEX_NAME   = 'idx_routes_bus'
    ) THEN
        DROP INDEX idx_routes_bus ON routes;
    END IF;

    IF EXISTS (
        SELECT 1 FROM information_schema.STATISTICS
        WHERE TABLE_SCHEMA = 'smart_transit'
          AND TABLE_NAME   = 'bookings'
          AND INDEX_NAME   = 'idx_bookings_passenger'
    ) THEN
        DROP INDEX idx_bookings_passenger ON bookings;
    END IF;

    IF EXISTS (
        SELECT 1 FROM information_schema.STATISTICS
        WHERE TABLE_SCHEMA = 'smart_transit'
          AND TABLE_NAME   = 'bookings'
          AND INDEX_NAME   = 'idx_bookings_route'
    ) THEN
        DROP INDEX idx_bookings_route ON bookings;
    END IF;

    -- Create all indexes fresh
    CREATE INDEX idx_buses_driver       ON buses(driver_id);
    CREATE INDEX idx_routes_bus         ON routes(bus_id);
    CREATE INDEX idx_bookings_passenger ON bookings(passenger_id);
    CREATE INDEX idx_bookings_route     ON bookings(route_id);
END$$

DELIMITER ;

CALL smart_transit_create_indexes();
DROP PROCEDURE IF EXISTS smart_transit_create_indexes;
