/**
 * Smart Transit — Express API Server v2 (Supabase / PostgreSQL)
 * RBAC: Admin=1 (full access), Driver=2 (own buses/routes only), Passenger=3 (own bookings only)
 * Auth: JWT Bearer tokens — every protected route validates role server-side.
 * Registration: Passengers only. Admin/Driver accounts are created via seed.sql or admin panel.
 *
 * DB layer: converted from mysql2/promise to `pg` (node-postgres) talking to a
 * Supabase Postgres instance. Supabase's REST/JS client can't run multi-statement
 * transactions or SELECT ... FOR UPDATE, both of which this file relies on, so we
 * connect straight to the Supabase Postgres connection string with `pg`.
 */

import express   from 'express';
import cors      from 'cors';
import dotenv    from 'dotenv';
import pg        from 'pg';
import jwt       from 'jsonwebtoken';
import bcrypt    from 'bcryptjs';
import crypto    from 'crypto';
import { makePaymentRouter } from './backend/routes/paymentRoutes.js';

const { Pool } = pg;

dotenv.config();
dotenv.config();

console.log("DATABASE_URL =", process.env.DATABASE_URL);

// ─── Pakistan Standard Time (UTC+5, no DST) ──────────────────────────────────
function pktNow() {
  return new Date(Date.now() + 5 * 60 * 60 * 1000);
}
function pktISOStr() {
  return pktNow().toISOString().replace('T', ' ').slice(0, 19);
}
function pktDateStr() {
  const d = pktNow();
  return d.toISOString().slice(0, 10);
}

// ─── Numeric coercion helper ─────────────────────────────────────────────────
// node-postgres, like mysql2, returns NUMERIC/DECIMAL columns as Strings (e.g. "33.00")
// to avoid float precision loss, and BIGINT (e.g. COUNT(*)) as Strings too.
// This converts numeric fields to JS Number before sending JSON,
// preventing Flutter's toStringAsFixed() from crashing.
const NUMERIC_FIELDS = new Set([
  'amount', 'fare', 'wallet_balance', 'walletBalance', 'balance', 'totalRevenue', 'revenue',
]);
function coerceNumerics(rows) {
  return rows.map(row => {
    const out = { ...row };
    for (const key of Object.keys(out)) {
      if (NUMERIC_FIELDS.has(key) && out[key] !== null && out[key] !== undefined) {
        out[key] = Number(out[key]);
      }
    }
    return out;
  });
}


const app        = express();
const PORT       = process.env.PORT       || 8080;
const JWT_SECRET = process.env.JWT_SECRET || 'smart_transit_secure_jwt_secret_salt_2026';

app.use(cors());
app.use(express.json());

// ─── Database pool ────────────────────────────────────────────────────────────
let pool    = null;
let useMock = false;

async function initDB() {
  try {
    // Prefer a full Supabase connection string (Project Settings → Database →
    // Connection string → URI), e.g.:
    // postgresql://postgres:[YOUR-PASSWORD]@db.xxxxxxxxxxxx.supabase.co:5432/postgres
    const connectionString = process.env.DATABASE_URL;

    pool = connectionString
      ? new Pool({
          connectionString,
          ssl:              { rejectUnauthorized: false }, // required by Supabase's managed Postgres
          max:              10,
        })
      : new Pool({
          host:             process.env.DB_HOST     || '127.0.0.1',
          port:             process.env.DB_PORT     || 5432,
          user:             process.env.DB_USER     || 'postgres',
          password:         process.env.DB_PASSWORD || 'hammal12',
          database:         process.env.DB_NAME     || 'postgres',
          ssl:              process.env.DB_SSL === 'false' ? false : { rejectUnauthorized: false },
          max:              10,
        });

    // Every pooled connection should default to Pakistan Standard Time.
    pool.on('connect', (client) => {
      client.query("SET TIME ZONE 'Asia/Karachi'").catch(err =>
        console.warn(`[DB] Failed to set session timezone: ${err.message}`)
      );
    });
    pool.on('error', (err) => {
      console.error('[DB] Unexpected error on idle Postgres client:', err.message);
    });

    await pool.query('SELECT 1');
    console.log('[DB] Connected to Supabase PostgreSQL successfully (timezone: PKT UTC+5).');
    useMock = false;
  } catch (err) {
    console.warn('[DB] Supabase PostgreSQL unavailable — falling back to in-memory mock data.');
    console.warn(`[DB] Reason: ${err.message}`);
    useMock = true;
  }
}
await initDB();

// ─── In-memory mock store ─────────────────────────────────────────────────────
// Passwords are bcrypt hashes seeded by ensureMockHashes() on first use.
// admin@smarttransit.com → admin123
// driver@smarttransit.com → driver123
// m.vance@aerotech.com    → passenger123
const mock = {
  users: [
    { id: 1, name: 'System Administrator', email: 'admin@smarttransit.com',  password: null, role_id: 1, role: 'Admin',     wallet_balance: 0.00   },
    { id: 2, name: 'John Doe',             email: 'driver@smarttransit.com', password: null, role_id: 2, role: 'Driver',    wallet_balance: 0.00   },
    { id: 3, name: 'Marcus Vance',         email: 'm.vance@aerotech.com',    password: null, role_id: 3, role: 'Passenger', wallet_balance: 100.00 },
  ],
  drivers:  [{ id: 1, user_id: 2, license_number: 'TX-DRV-88910-A', status: 'active' }],
  buses:    [
    { id: 1, bus_number: 'BUS-101', driver_id: 1,    capacity: 55, status: 'active' },
    { id: 2, bus_number: 'BUS-102', driver_id: null,  capacity: 40, status: 'active' },
  ],
  routes: [
    { id: 1, bus_id: 1, source: 'Central Terminal', destination: 'North Gate',       departure_time: '08:00:00', arrival_time: '08:45:00', days_of_week: 'Mon,Tue,Wed,Thu,Fri', fare: 2.75 },
    { id: 2, bus_id: 1, source: 'Central Terminal', destination: 'Science Hub',      departure_time: '09:30:00', arrival_time: '10:15:00', days_of_week: 'Mon,Wed,Fri',         fare: 3.00 },
    { id: 3, bus_id: 2, source: 'South Airport',    destination: 'Central Terminal', departure_time: '07:00:00', arrival_time: '07:50:00', days_of_week: 'Daily',               fare: 4.50 },
  ],
  bookings: [
    { id: 1, passenger_id: 3, route_id: 1, seat_number: 12, departure_date: '2026-06-24', booking_date: '2026-06-24 08:00:00', booking_status: 'Confirmed' },
    { id: 2, passenger_id: 3, route_id: 2, seat_number:  5, departure_date: '2026-06-25', booking_date: '2026-06-25 09:30:00', booking_status: 'Pending'   },
  ],
  payments: [
    { payment_id: 1, booking_id: 1, user_id: 3, amount: 2.75, payment_method: 'Cash', transaction_id: 'CASH-20260624-001', status: 'Paid',    notes: null, payment_date: '2026-06-24 08:01:00', created_at: '2026-06-24 08:00:30' },
    { payment_id: 2, booking_id: 2, user_id: 3, amount: 3.00, payment_method: 'Cash', transaction_id: null,               status: 'Pending', notes: null, payment_date: null,                  created_at: '2026-06-25 09:30:30' },
  ],
  nextIds: { user: 4, driver: 2, bus: 3, route: 4, booking: 3, payment: 3 },
};

let mockHashesSeeded = false;
async function ensureMockHashes() {
  if (mockHashesSeeded) return;
  const plainPasswords = ['admin123', 'driver123', 'passenger123'];
  for (let i = 0; i < 3; i++) {
    mock.users[i].password = await bcrypt.hash(plainPasswords[i], 10);
  }
  mockHashesSeeded = true;
  console.log('[Mock] Bcrypt hashes seeded for all mock users.');
}

// ─── JWT middleware ───────────────────────────────────────────────────────────
function authenticateToken(req, res, next) {
  const header = req.headers['authorization'];
  const token  = header && header.split(' ')[1];
  if (!token)
    return res.status(401).json({ status: 'error', message: 'Authorization token missing.' });

  jwt.verify(token, JWT_SECRET, (err, decoded) => {
    if (err)
      return res.status(403).json({ status: 'error', message: 'Token invalid or expired. Please log in again.' });
    req.user = decoded; // { userId, email, role }
    next();
  });
}

// Role guard — rejects immediately if role not in allowed list
const requireRole = (...roles) => (req, res, next) => {
  if (!roles.includes(req.user.role)) {
    console.log(`[RBAC] DENIED user=${req.user.userId} role=${req.user.role} → ${req.method} ${req.path} (requires: ${roles.join('|')})`);
    return res.status(403).json({
      status:  'error',
      message: `Access denied. This endpoint requires role: ${roles.join(' or ')}.`,
    });
  }
  next();
};

// Helper: resolve driver.id from user.id
async function getDriverId(userId) {
  if (useMock) {
    const d = mock.drivers.find(d => d.user_id === userId);
    return d ? d.id : null;
  }
  const { rows } = await pool.query('SELECT id FROM drivers WHERE user_id = $1', [userId]);
  return rows.length > 0 ? rows[0].id : null;
}

// Helper: unique transaction ID
function newTxnId() {
  return 'TXN-' + pktISOStr().slice(0, 10).replace(/-/g, '') +
         '-' + Math.random().toString(36).slice(2, 8).toUpperCase();
}

// ═════════════════════════════════════════════════════════════════════════════
// AUTH — PUBLIC ENDPOINTS
// ═════════════════════════════════════════════════════════════════════════════

// POST /api/auth/register
// PASSENGERS ONLY. Admin and Driver accounts must be created via seed.sql or
// the Admin panel (/api/admin/drivers/hire). Any attempt to register as Admin
// or Driver is rejected with a clear error message.
app.post('/api/auth/register', async (req, res) => {
  const { name, email, password } = req.body;

  if (!name || !email || !password)
    return res.status(400).json({ status: 'error', message: 'Name, email and password are required.' });

  if (!email.includes('@'))
    return res.status(400).json({ status: 'error', message: 'Please enter a valid email address.' });

  if (password.length < 6)
    return res.status(400).json({ status: 'error', message: 'Password must be at least 6 characters.' });

  // Enforce Passenger-only self-registration
  const role   = 'Passenger';
  const roleId = 3;

  console.log(`[RBAC][register] New Passenger registration: email=${email}`);

  const hash = await bcrypt.hash(password, 10);

  if (useMock) {
    await ensureMockHashes();
    if (mock.users.find(u => u.email === email))
      return res.status(400).json({ status: 'error', message: 'An account with this email already exists.' });

    const userId = mock.nextIds.user++;
    mock.users.push({
      id: userId, name, email, password: hash,
      role_id: roleId, role, wallet_balance: 100.00,
    });
    console.log(`[RBAC][register] Mock: Passenger created id=${userId}`);
    return res.json({ status: 'success', message: 'Account created successfully. You can now log in.' });
  }

  try {
    const { rows } = await pool.query(
      'INSERT INTO users (name, email, password, role_id, wallet_balance) VALUES ($1, $2, $3, $4, $5) RETURNING id',
      [name, email, hash, roleId, 100.00]
    );
    console.log(`[RBAC][register] DB: Passenger created id=${rows[0].id}`);
    res.json({ status: 'success', message: 'Account created successfully. You can now log in.' });
  } catch (err) {
    if (err.code === '23505') // Postgres unique_violation (was ER_DUP_ENTRY in MySQL)
      return res.status(400).json({ status: 'error', message: 'An account with this email already exists.' });
    console.error(`[RBAC][register] DB ERROR: ${err.message}`);
    res.status(500).json({ status: 'error', message: 'Server error during registration.' });
  }
});

// POST /api/auth/login
// All three roles (Admin, Driver, Passenger) authenticate here.
// Returns: { status, token, user: { id, name, email, role, walletBalance } }
app.post('/api/auth/login', async (req, res) => {
  const { email, password } = req.body;

  if (!email || !password)
    return res.status(400).json({ status: 'error', message: 'Email and password are required.' });

  console.log(`[RBAC][login] Attempt: email=${email} useMock=${useMock}`);

  if (useMock) {
    await ensureMockHashes();
    const user = mock.users.find(u => u.email === email);

    if (!user) {
      console.log(`[RBAC][login] Mock: no user for email=${email}`);
      return res.status(400).json({ status: 'error', message: 'Invalid email or password.' });
    }

    const passwordMatch = await bcrypt.compare(password, user.password);
    if (!passwordMatch) {
      console.log(`[RBAC][login] Mock: wrong password for email=${email}`);
      return res.status(400).json({ status: 'error', message: 'Invalid email or password.' });
    }

    console.log(`[RBAC][login] Mock: SUCCESS id=${user.id} role=${user.role}`);
    const token = jwt.sign(
      { userId: user.id, email: user.email, role: user.role },
      JWT_SECRET,
      { expiresIn: '24h' }
    );
    const responseUser = {
      id: user.id, name: user.name, email: user.email,
      role: user.role, walletBalance: user.wallet_balance,
    };
    console.log(`[RBAC][login] Mock: response user=${JSON.stringify(responseUser)}`);
    return res.json({ status: 'success', token, user: responseUser });
  }

  try {
    // JOIN roles so we get the role name string, not just role_id
    const { rows } = await pool.query(
      `SELECT u.id, u.name, u.email, u.password, u.wallet_balance, r.name AS role
       FROM users u
       JOIN roles r ON u.role_id = r.id
       WHERE u.email = $1`,
      [email]
    );

    if (rows.length === 0) {
      console.log(`[RBAC][login] DB: no user for email=${email}`);
      return res.status(400).json({ status: 'error', message: 'Invalid email or password.' });
    }

    const user = rows[0];
    console.log(`[RBAC][login] DB: found id=${user.id} role="${user.role}"`);

    // Validate password with bcrypt
    const passwordMatch = await bcrypt.compare(password, user.password);
    if (!passwordMatch) {
      console.log(`[RBAC][login] DB: wrong password for id=${user.id}`);
      return res.status(400).json({ status: 'error', message: 'Invalid email or password.' });
    }

    const tokenPayload = { userId: user.id, email: user.email, role: user.role };
    console.log(`[RBAC][login] DB: signing JWT payload=${JSON.stringify(tokenPayload)}`);
    const token = jwt.sign(tokenPayload, JWT_SECRET, { expiresIn: '24h' });

    const responseUser = {
      id: user.id, name: user.name, email: user.email,
      role: user.role, walletBalance: Number(user.wallet_balance),
    };
    console.log(`[RBAC][login] DB: response=${JSON.stringify(responseUser)}`);
    res.json({ status: 'success', token, user: responseUser });

  } catch (err) {
    console.error(`[RBAC][login] DB ERROR: ${err.message}`);
    res.status(500).json({ status: 'error', message: 'Server error during login.' });
  }
});

// ═════════════════════════════════════════════════════════════════════════════
// ADMIN ENDPOINTS — requireRole('Admin') on every route
// ═════════════════════════════════════════════════════════════════════════════

// GET /api/admin/stats
app.get('/api/admin/stats', authenticateToken, requireRole('Admin'), async (req, res) => {
  if (useMock) {
    const paid    = mock.payments.filter(p => p.status === 'Success');
    const revenue = paid.reduce((s, p) => s + p.amount, 0);
    return res.json({
      totalTicketsSold: mock.bookings.filter(b => b.booking_status !== 'Cancelled').length,
      totalRevenue:     revenue,
      activeDrivers:    mock.drivers.filter(d => d.status === 'active').length,
      activeBuses:      mock.buses.filter(b => b.status === 'active').length,
      activeRoutes:     mock.routes.length,
      pendingPayments:  mock.payments.filter(p => p.status === 'Pending').length,
    });
  }
  try {
    const { rows: [tickets] } = await pool.query("SELECT COUNT(*) AS n FROM bookings WHERE booking_status != 'Cancelled'");
    const { rows: [revenue] } = await pool.query("SELECT COALESCE(SUM(amount),0) AS t FROM payments WHERE status='Success'");
    const { rows: [drivers] } = await pool.query("SELECT COUNT(*) AS n FROM drivers WHERE status='active'");
    const { rows: [buses] }   = await pool.query("SELECT COUNT(*) AS n FROM buses WHERE status='active'");
    const { rows: [routes] }  = await pool.query("SELECT COUNT(*) AS n FROM routes");
    const { rows: [pending] } = await pool.query("SELECT COUNT(*) AS n FROM payments WHERE status='Pending'");
    res.json({
      totalTicketsSold: Number(tickets.n),
      totalRevenue:     Number(revenue.t),
      activeDrivers:    Number(drivers.n),
      activeBuses:      Number(buses.n),
      activeRoutes:     Number(routes.n),
      pendingPayments:  Number(pending.n),
    });
  } catch (err) { res.status(500).json({ status: 'error', message: err.message }); }
});

// GET /api/admin/drivers
app.get('/api/admin/drivers', authenticateToken, requireRole('Admin'), async (req, res) => {
  if (useMock) {
    return res.json(mock.drivers.map(d => {
      const u = mock.users.find(u => u.id === d.user_id) || {};
      return { id: d.id, user_id: d.user_id, name: u.name, email: u.email, license_number: d.license_number, status: d.status };
    }));
  }
  try {
    const { rows } = await pool.query(
      'SELECT d.id, d.user_id, u.name, u.email, d.license_number, d.status FROM drivers d JOIN users u ON d.user_id = u.id ORDER BY d.id'
    );
    res.json(coerceNumerics(rows));
  } catch (err) { res.status(500).json({ status: 'error', message: err.message }); }
});

// POST /api/admin/drivers/hire
app.post('/api/admin/drivers/hire', authenticateToken, requireRole('Admin'), async (req, res) => {
  const { name, email, password, license } = req.body;
  if (!name || !email || !password || !license)
    return res.status(400).json({ status: 'error', message: 'name, email, password and license are required.' });

  const hash = await bcrypt.hash(password, 10);

  if (useMock) {
    if (mock.users.find(u => u.email === email))
      return res.status(400).json({ status: 'error', message: 'Email already exists.' });
    const userId = mock.nextIds.user++;
    mock.users.push({ id: userId, name, email, password: hash, role_id: 2, role: 'Driver', wallet_balance: 0 });
    const drvId = mock.nextIds.driver++;
    mock.drivers.push({ id: drvId, user_id: userId, license_number: license, status: 'active' });
    return res.json({ status: 'success', message: `Driver ${name} hired.`, driverId: drvId });
  }
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const { rows: [u] } = await client.query(
      'INSERT INTO users (name,email,password,role_id,wallet_balance) VALUES ($1,$2,$3,2,0) RETURNING id',
      [name, email, hash]
    );
    const { rows: [d] } = await client.query(
      'INSERT INTO drivers (user_id,license_number) VALUES ($1,$2) RETURNING id',
      [u.id, license]
    );
    await client.query('COMMIT');
    res.json({ status: 'success', message: `Driver ${name} hired.`, driverId: d.id });
  } catch (err) {
    await client.query('ROLLBACK');
    if (err.code === '23505') return res.status(400).json({ status: 'error', message: 'Email or license already exists.' });
    res.status(500).json({ status: 'error', message: err.message });
  } finally { client.release(); }
});

// PATCH /api/admin/drivers/:id/status
app.patch('/api/admin/drivers/:id/status', authenticateToken, requireRole('Admin'), async (req, res) => {
  const { status } = req.body;
  const drvId = parseInt(req.params.id);
  if (!['active', 'suspended', 'on_leave'].includes(status))
    return res.status(400).json({ status: 'error', message: 'status must be active | suspended | on_leave' });

  if (useMock) {
    const d = mock.drivers.find(d => d.id === drvId);
    if (!d) return res.status(404).json({ status: 'error', message: 'Driver not found.' });
    d.status = status;
    return res.json({ status: 'success', message: `Driver status updated to ${status}.` });
  }
  try {
    const { rowCount } = await pool.query('UPDATE drivers SET status=$1 WHERE id=$2', [status, drvId]);
    if (rowCount === 0) return res.status(404).json({ status: 'error', message: 'Driver not found.' });
    res.json({ status: 'success', message: `Driver status updated to ${status}.` });
  } catch (err) { res.status(500).json({ status: 'error', message: err.message }); }
});

// DELETE /api/admin/drivers/:id
app.delete('/api/admin/drivers/:id', authenticateToken, requireRole('Admin'), async (req, res) => {
  const drvId = parseInt(req.params.id);
  if (useMock) {
    const idx = mock.drivers.findIndex(d => d.id === drvId);
    if (idx === -1) return res.status(404).json({ status: 'error', message: 'Driver not found.' });
    const userId = mock.drivers[idx].user_id;
    mock.drivers.splice(idx, 1);
    mock.buses.forEach(b => { if (b.driver_id === drvId) b.driver_id = null; });
    mock.users.splice(mock.users.findIndex(u => u.id === userId), 1);
    return res.json({ status: 'success', message: 'Driver removed.' });
  }
  try {
    const { rows: drv } = await pool.query('SELECT user_id FROM drivers WHERE id=$1', [drvId]);
    if (drv.length === 0) return res.status(404).json({ status: 'error', message: 'Driver not found.' });
    await pool.query('DELETE FROM users WHERE id=$1', [drv[0].user_id]);
    res.json({ status: 'success', message: 'Driver removed.' });
  } catch (err) { res.status(500).json({ status: 'error', message: err.message }); }
});

// GET /api/admin/buses
app.get('/api/admin/buses', authenticateToken, requireRole('Admin'), async (req, res) => {
  if (useMock) {
    return res.json(mock.buses.map(b => {
      const d = mock.drivers.find(d => d.id === b.driver_id);
      const u = d ? mock.users.find(u => u.id === d.user_id) : null;
      return { ...b, driverName: u ? u.name : null };
    }));
  }
  try {
    const { rows } = await pool.query(
      'SELECT b.*, u.name AS "driverName" FROM buses b LEFT JOIN drivers d ON b.driver_id=d.id LEFT JOIN users u ON d.user_id=u.id ORDER BY b.id'
    );
    res.json(coerceNumerics(rows));
  } catch (err) { res.status(500).json({ status: 'error', message: err.message }); }
});

// POST /api/admin/buses
app.post('/api/admin/buses', authenticateToken, requireRole('Admin'), async (req, res) => {
  const { bus_number, driver_id, capacity, status } = req.body;
  if (!bus_number) return res.status(400).json({ status: 'error', message: 'bus_number required.' });
  if (useMock) {
    if (mock.buses.find(b => b.bus_number === bus_number))
      return res.status(400).json({ status: 'error', message: 'Bus number already exists.' });
    const id = mock.nextIds.bus++;
    mock.buses.push({ id, bus_number, driver_id: driver_id || null, capacity: capacity || 50, status: status || 'active' });
    return res.json({ status: 'success', message: 'Bus added.', busId: id });
  }
  try {
    const { rows: [b] } = await pool.query(
      'INSERT INTO buses (bus_number,driver_id,capacity,status) VALUES ($1,$2,$3,$4) RETURNING id',
      [bus_number, driver_id || null, capacity || 50, status || 'active']
    );
    res.json({ status: 'success', message: 'Bus added.', busId: b.id });
  } catch (err) {
    if (err.code === '23505') return res.status(400).json({ status: 'error', message: 'Bus number already exists.' });
    res.status(500).json({ status: 'error', message: err.message });
  }
});

// PATCH /api/admin/buses/:id
app.patch('/api/admin/buses/:id', authenticateToken, requireRole('Admin'), async (req, res) => {
  const busId = parseInt(req.params.id);
  const { bus_number, driver_id, capacity, status } = req.body;
  if (useMock) {
    const b = mock.buses.find(b => b.id === busId);
    if (!b) return res.status(404).json({ status: 'error', message: 'Bus not found.' });
    if (bus_number !== undefined) b.bus_number = bus_number;
    if (driver_id  !== undefined) b.driver_id  = driver_id;
    if (capacity   !== undefined) b.capacity   = capacity;
    if (status     !== undefined) b.status     = status;
    return res.json({ status: 'success', message: 'Bus updated.' });
  }
  try {
    const { rowCount } = await pool.query(
      'UPDATE buses SET bus_number=COALESCE($1,bus_number),driver_id=COALESCE($2,driver_id),capacity=COALESCE($3,capacity),status=COALESCE($4,status) WHERE id=$5',
      [bus_number || null, driver_id || null, capacity || null, status || null, busId]
    );
    if (rowCount === 0) return res.status(404).json({ status: 'error', message: 'Bus not found.' });
    res.json({ status: 'success', message: 'Bus updated.' });
  } catch (err) { res.status(500).json({ status: 'error', message: err.message }); }
});

// DELETE /api/admin/buses/:id
app.delete('/api/admin/buses/:id', authenticateToken, requireRole('Admin'), async (req, res) => {
  const busId = parseInt(req.params.id);
  if (useMock) {
    const idx = mock.buses.findIndex(b => b.id === busId);
    if (idx === -1) return res.status(404).json({ status: 'error', message: 'Bus not found.' });
    mock.buses.splice(idx, 1);
    mock.routes = mock.routes.filter(r => r.bus_id !== busId);
    return res.json({ status: 'success', message: 'Bus deleted.' });
  }
  try {
    const { rowCount } = await pool.query('DELETE FROM buses WHERE id=$1', [busId]);
    if (rowCount === 0) return res.status(404).json({ status: 'error', message: 'Bus not found.' });
    res.json({ status: 'success', message: 'Bus deleted.' });
  } catch (err) { res.status(500).json({ status: 'error', message: err.message }); }
});

// GET /api/admin/routes
app.get('/api/admin/routes', authenticateToken, requireRole('Admin'), async (req, res) => {
  if (useMock) {
    return res.json(mock.routes.map(r => {
      const b = mock.buses.find(b => b.id === r.bus_id);
      return { ...r, bus_number: b ? b.bus_number : null };
    }));
  }
  try {
    const { rows } = await pool.query('SELECT r.*, b.bus_number FROM routes r JOIN buses b ON r.bus_id=b.id ORDER BY r.id');
    res.json(coerceNumerics(rows));
  } catch (err) { res.status(500).json({ status: 'error', message: err.message }); }
});

// POST /api/admin/routes
app.post('/api/admin/routes', authenticateToken, requireRole('Admin'), async (req, res) => {
  const { bus_id, source, destination, departure_time, arrival_time, days_of_week, fare } = req.body;
  if (!bus_id || !source || !destination || !departure_time || fare === undefined)
    return res.status(400).json({ status: 'error', message: 'bus_id, source, destination, departure_time, fare required.' });
  const days = days_of_week || 'Daily';
  if (useMock) {
    const id = mock.nextIds.route++;
    mock.routes.push({ id, bus_id, source, destination, departure_time, arrival_time: arrival_time || null, days_of_week: days, fare: Number(fare) });
    return res.json({ status: 'success', message: 'Route added.', routeId: id });
  }
  try {
    const { rows: [rt] } = await pool.query(
      'INSERT INTO routes (bus_id,source,destination,departure_time,arrival_time,days_of_week,fare) VALUES ($1,$2,$3,$4,$5,$6,$7) RETURNING id',
      [bus_id, source, destination, departure_time, arrival_time || null, days, fare]
    );
    res.json({ status: 'success', message: 'Route added.', routeId: rt.id });
  } catch (err) { res.status(500).json({ status: 'error', message: err.message }); }
});

// PATCH /api/admin/routes/:id
app.patch('/api/admin/routes/:id', authenticateToken, requireRole('Admin'), async (req, res) => {
  const routeId = parseInt(req.params.id);
  const { bus_id, source, destination, departure_time, fare } = req.body;
  if (useMock) {
    const r = mock.routes.find(r => r.id === routeId);
    if (!r) return res.status(404).json({ status: 'error', message: 'Route not found.' });
    if (bus_id         !== undefined) r.bus_id         = bus_id;
    if (source         !== undefined) r.source         = source;
    if (destination    !== undefined) r.destination    = destination;
    if (departure_time !== undefined) r.departure_time = departure_time;
    if (fare           !== undefined) r.fare           = Number(fare);
    return res.json({ status: 'success', message: 'Route updated.' });
  }
  try {
    const { rowCount } = await pool.query(
      'UPDATE routes SET bus_id=COALESCE($1,bus_id),source=COALESCE($2,source),destination=COALESCE($3,destination),departure_time=COALESCE($4,departure_time),fare=COALESCE($5,fare) WHERE id=$6',
      [bus_id || null, source || null, destination || null, departure_time || null, fare || null, routeId]
    );
    if (rowCount === 0) return res.status(404).json({ status: 'error', message: 'Route not found.' });
    res.json({ status: 'success', message: 'Route updated.' });
  } catch (err) { res.status(500).json({ status: 'error', message: err.message }); }
});

// DELETE /api/admin/routes/:id
app.delete('/api/admin/routes/:id', authenticateToken, requireRole('Admin'), async (req, res) => {
  const routeId = parseInt(req.params.id);
  if (useMock) {
    const idx = mock.routes.findIndex(r => r.id === routeId);
    if (idx === -1) return res.status(404).json({ status: 'error', message: 'Route not found.' });
    mock.routes.splice(idx, 1);
    return res.json({ status: 'success', message: 'Route deleted.' });
  }
  try {
    const { rowCount } = await pool.query('DELETE FROM routes WHERE id=$1', [routeId]);
    if (rowCount === 0) return res.status(404).json({ status: 'error', message: 'Route not found.' });
    res.json({ status: 'success', message: 'Route deleted.' });
  } catch (err) { res.status(500).json({ status: 'error', message: err.message }); }
});

// GET /api/admin/bookings
app.get('/api/admin/bookings', authenticateToken, requireRole('Admin'), async (req, res) => {
  if (useMock) {
    return res.json(mock.bookings.map(bk => {
      const u = mock.users.find(u => u.id === bk.passenger_id);
      const r = mock.routes.find(r => r.id === bk.route_id);
      const b = r ? mock.buses.find(b => b.id === r.bus_id) : null;
      const p = mock.payments.find(p => p.booking_id === bk.id);
      return {
        id: bk.id, passengerName: u?.name, passengerEmail: u?.email,
        source: r?.source, destination: r?.destination,
        departure_date: bk.departure_date,
        departure_time: r?.departure_time, days_of_week: r?.days_of_week,
        bus_number: b?.bus_number,
        seat_number: bk.seat_number, booking_date: bk.booking_date,
        booking_status: bk.booking_status,
        amount: p?.amount, payment_status: p?.status, transaction_id: p?.transaction_id,
      };
    }));
  }
  try {
    const { rows } = await pool.query(
      `SELECT bk.id, u.name AS "passengerName", u.email AS "passengerEmail",
              r.source, r.destination, bk.departure_date,
              r.departure_time, r.days_of_week, b.bus_number,
              bk.seat_number, bk.booking_date, bk.booking_status,
              p.amount, p.status AS payment_status, p.transaction_id
       FROM bookings bk
       JOIN users u   ON bk.passenger_id = u.id
       JOIN routes r  ON bk.route_id     = r.id
       JOIN buses  b  ON r.bus_id        = b.id
       LEFT JOIN payments p ON bk.id     = p.booking_id
       ORDER BY bk.departure_date DESC, bk.seat_number ASC`
    );
    res.json(coerceNumerics(rows));
  } catch (err) { res.status(500).json({ status: 'error', message: err.message }); }
});

// GET /api/admin/payments
app.get('/api/admin/payments', authenticateToken, requireRole('Admin'), async (req, res) => {
  if (useMock) {
    return res.json(mock.payments.map(p => {
      const bk = mock.bookings.find(b => b.id === p.booking_id);
      const u  = bk ? mock.users.find(u => u.id === bk.passenger_id) : null;
      return { ...p, passengerName: u?.name };
    }));
  }
  try {
    const { rows } = await pool.query(
      `SELECT p.*, u.name AS "passengerName"
       FROM payments p
       JOIN bookings bk ON p.booking_id  = bk.id
       JOIN users u     ON bk.passenger_id = u.id
       ORDER BY p.payment_date DESC`
    );
    res.json(coerceNumerics(rows));
  } catch (err) { res.status(500).json({ status: 'error', message: err.message }); }
});

// ═════════════════════════════════════════════════════════════════════════════
// DRIVER ENDPOINTS — requireRole('Driver') on every route
// Driver can only see buses/routes/passengers where bus.driver_id = their driver.id
// ═════════════════════════════════════════════════════════════════════════════

// GET /api/driver/stats
app.get('/api/driver/stats', authenticateToken, requireRole('Driver'), async (req, res) => {
  const drvId = await getDriverId(req.user.userId);
  if (!drvId) return res.status(403).json({ status: 'error', message: 'No driver record found for this account.' });

  if (useMock) {
    const myBuses    = mock.buses.filter(b => b.driver_id === drvId);
    const busIds     = myBuses.map(b => b.id);
    const myRoutes   = mock.routes.filter(r => busIds.includes(r.bus_id));
    const routeIds   = myRoutes.map(r => r.id);
    const myBookings = mock.bookings.filter(b => routeIds.includes(b.route_id) && b.booking_status !== 'Cancelled');
    const revenue    = mock.payments
      .filter(p => myBookings.some(b => b.id === p.booking_id) && p.status === 'Success')
      .reduce((s, p) => s + p.amount, 0);
    return res.json({ myBuses: myBuses.length, myRoutes: myRoutes.length, ticketsSold: myBookings.length, revenue });
  }
  try {
    const { rows: [br] }  = await pool.query('SELECT COUNT(*) AS n FROM buses WHERE driver_id=$1', [drvId]);
    const { rows: [rr] }  = await pool.query('SELECT COUNT(*) AS n FROM routes r JOIN buses b ON r.bus_id=b.id WHERE b.driver_id=$1', [drvId]);
    const { rows: [tr] }  = await pool.query("SELECT COUNT(*) AS n FROM bookings bk JOIN routes r ON bk.route_id=r.id JOIN buses b ON r.bus_id=b.id WHERE b.driver_id=$1 AND bk.booking_status!='Cancelled'", [drvId]);
    const { rows: [rev] } = await pool.query("SELECT COALESCE(SUM(p.amount),0) AS t FROM payments p JOIN bookings bk ON p.booking_id=bk.id JOIN routes r ON bk.route_id=r.id JOIN buses b ON r.bus_id=b.id WHERE b.driver_id=$1 AND p.status='Success'", [drvId]);
    res.json({ myBuses: Number(br.n), myRoutes: Number(rr.n), ticketsSold: Number(tr.n), revenue: Number(rev.t) });
  } catch (err) { res.status(500).json({ status: 'error', message: err.message }); }
});

// GET /api/driver/buses
app.get('/api/driver/buses', authenticateToken, requireRole('Driver'), async (req, res) => {
  const drvId = await getDriverId(req.user.userId);
  if (!drvId) return res.status(403).json({ status: 'error', message: 'No driver record found.' });
  if (useMock) return res.json(mock.buses.filter(b => b.driver_id === drvId));
  try {
    const { rows } = await pool.query('SELECT * FROM buses WHERE driver_id=$1', [drvId]);
    res.json(coerceNumerics(rows));
  } catch (err) { res.status(500).json({ status: 'error', message: err.message }); }
});

// POST /api/driver/buses
app.post('/api/driver/buses', authenticateToken, requireRole('Driver'), async (req, res) => {
  const drvId = await getDriverId(req.user.userId);
  if (!drvId) return res.status(403).json({ status: 'error', message: 'No driver record found.' });
  const { bus_number, capacity, status } = req.body;
  if (!bus_number) return res.status(400).json({ status: 'error', message: 'bus_number required.' });
  if (useMock) {
    if (mock.buses.find(b => b.bus_number === bus_number))
      return res.status(400).json({ status: 'error', message: 'Bus number already exists.' });
    const id = mock.nextIds.bus++;
    mock.buses.push({ id, bus_number, driver_id: drvId, capacity: capacity || 50, status: status || 'active' });
    return res.json({ status: 'success', message: 'Bus added.', busId: id });
  }
  try {
    const { rows: [b] } = await pool.query(
      'INSERT INTO buses (bus_number,driver_id,capacity,status) VALUES ($1,$2,$3,$4) RETURNING id',
      [bus_number, drvId, capacity || 50, status || 'active']
    );
    res.json({ status: 'success', message: 'Bus added.', busId: b.id });
  } catch (err) {
    if (err.code === '23505') return res.status(400).json({ status: 'error', message: 'Bus number already exists.' });
    res.status(500).json({ status: 'error', message: err.message });
  }
});

// PATCH /api/driver/buses/:id — driver can only update own buses
app.patch('/api/driver/buses/:id', authenticateToken, requireRole('Driver'), async (req, res) => {
  const busId = parseInt(req.params.id);
  const drvId = await getDriverId(req.user.userId);
  const { status } = req.body;
  if (useMock) {
    const b = mock.buses.find(b => b.id === busId && b.driver_id === drvId);
    if (!b) return res.status(403).json({ status: 'error', message: 'Bus not found or not assigned to you.' });
    if (status) b.status = status;
    return res.json({ status: 'success', message: 'Bus updated.' });
  }
  try {
    const { rowCount } = await pool.query(
      'UPDATE buses SET status=COALESCE($1,status) WHERE id=$2 AND driver_id=$3',
      [status || null, busId, drvId]
    );
    if (rowCount === 0)
      return res.status(403).json({ status: 'error', message: 'Bus not found or not assigned to you.' });
    res.json({ status: 'success', message: 'Bus updated.' });
  } catch (err) { res.status(500).json({ status: 'error', message: err.message }); }
});

// GET /api/driver/routes
app.get('/api/driver/routes', authenticateToken, requireRole('Driver'), async (req, res) => {
  const drvId = await getDriverId(req.user.userId);
  if (!drvId) return res.status(403).json({ status: 'error', message: 'No driver record found.' });
  if (useMock) {
    const busIds = mock.buses.filter(b => b.driver_id === drvId).map(b => b.id);
    return res.json(mock.routes.filter(r => busIds.includes(r.bus_id)));
  }
  try {
    const { rows } = await pool.query(
      'SELECT r.*, b.bus_number FROM routes r JOIN buses b ON r.bus_id=b.id WHERE b.driver_id=$1', [drvId]
    );
    res.json(coerceNumerics(rows));
  } catch (err) { res.status(500).json({ status: 'error', message: err.message }); }
});

// POST /api/driver/routes — bus ownership verified before insert
app.post('/api/driver/routes', authenticateToken, requireRole('Driver'), async (req, res) => {
  const drvId = await getDriverId(req.user.userId);
  if (!drvId) return res.status(403).json({ status: 'error', message: 'No driver record found.' });
  const { bus_id, source, destination, departure_time, arrival_time, days_of_week, fare } = req.body;
  if (!bus_id || !source || !destination || !departure_time || fare === undefined)
    return res.status(400).json({ status: 'error', message: 'bus_id, source, destination, departure_time, fare required.' });
  const days = days_of_week || 'Daily';
  if (useMock) {
    const b = mock.buses.find(b => b.id === bus_id && b.driver_id === drvId);
    if (!b) return res.status(403).json({ status: 'error', message: 'Bus not assigned to you.' });
    const id = mock.nextIds.route++;
    mock.routes.push({ id, bus_id, source, destination, departure_time, arrival_time: arrival_time || null, days_of_week: days, fare: Number(fare) });
    return res.json({ status: 'success', message: 'Route added.', routeId: id });
  }
  try {
    const { rows: check } = await pool.query('SELECT id FROM buses WHERE id=$1 AND driver_id=$2', [bus_id, drvId]);
    if (check.length === 0)
      return res.status(403).json({ status: 'error', message: 'Bus not assigned to you.' });
    const { rows: [rt] } = await pool.query(
      'INSERT INTO routes (bus_id,source,destination,departure_time,arrival_time,days_of_week,fare) VALUES ($1,$2,$3,$4,$5,$6,$7) RETURNING id',
      [bus_id, source, destination, departure_time, arrival_time || null, days, fare]
    );
    res.json({ status: 'success', message: 'Route added.', routeId: rt.id });
  } catch (err) { res.status(500).json({ status: 'error', message: err.message }); }
});

// GET /api/driver/passengers
app.get('/api/driver/passengers', authenticateToken, requireRole('Driver'), async (req, res) => {
  const drvId = await getDriverId(req.user.userId);
  if (!drvId) return res.status(403).json({ status: 'error', message: 'No driver record found.' });
  if (useMock) {
    const busIds   = mock.buses.filter(b => b.driver_id === drvId).map(b => b.id);
    const routeIds = mock.routes.filter(r => busIds.includes(r.bus_id)).map(r => r.id);
    return res.json(mock.bookings.filter(bk => routeIds.includes(bk.route_id)).map(bk => {
      const u = mock.users.find(u => u.id === bk.passenger_id);
      const r = mock.routes.find(r => r.id === bk.route_id);
      const p = mock.payments.find(p => p.booking_id === bk.id);
      return {
        bookingId: bk.id, passengerName: u?.name,
        seatNumber: bk.seat_number, bookingDate: bk.booking_date,
        departureDate: bk.departure_date, bookingStatus: bk.booking_status,
        source: r?.source, destination: r?.destination, busNumber: b?.bus_number,
        paymentStatus: p?.status || 'Pending', paymentMethod: p?.payment_method || 'Cash',
      };
    }));
  }
  try {
    const { rows } = await pool.query(
      `SELECT bk.id AS "bookingId", u.name AS "passengerName",
              bk.seat_number AS "seatNumber", bk.booking_date AS "bookingDate",
              bk.booking_status AS "bookingStatus",
              r.source, r.destination,
              COALESCE(p.status,'Pending') AS "paymentStatus"
       FROM bookings bk
       JOIN users u    ON bk.passenger_id = u.id
       JOIN routes r   ON bk.route_id     = r.id
       JOIN buses  b2  ON r.bus_id        = b2.id
       LEFT JOIN payments p ON bk.id     = p.booking_id
       WHERE b2.driver_id = $1
       ORDER BY bk.departure_date DESC, bk.seat_number ASC`, [drvId]
    );
    res.json(coerceNumerics(rows));
  } catch (err) { res.status(500).json({ status: 'error', message: err.message }); }
});

// GET /api/driver/revenue
app.get('/api/driver/revenue', authenticateToken, requireRole('Driver'), async (req, res) => {
  const drvId = await getDriverId(req.user.userId);
  if (!drvId) return res.status(403).json({ status: 'error', message: 'No driver record found.' });
  if (useMock) {
    const busIds   = mock.buses.filter(b => b.driver_id === drvId).map(b => b.id);
    const routeIds = mock.routes.filter(r => busIds.includes(r.bus_id)).map(r => r.id);
    const bkIds    = mock.bookings.filter(b => routeIds.includes(b.route_id)).map(b => b.id);
    const total    = mock.payments.filter(p => bkIds.includes(p.booking_id) && p.status === 'Success')
                                  .reduce((s, p) => s + p.amount, 0);
    return res.json({ status: 'success', totalRevenue: total });
  }
  try {
    const { rows: [row] } = await pool.query(
      `SELECT COALESCE(SUM(p.amount),0) AS t
       FROM payments p
       JOIN bookings bk ON p.booking_id = bk.id
       JOIN routes r    ON bk.route_id  = r.id
       JOIN buses  b    ON r.bus_id     = b.id
       WHERE b.driver_id=$1 AND p.status='Success'`, [drvId]
    );
    res.json({ status: 'success', totalRevenue: Number(row.t) });
  } catch (err) { res.status(500).json({ status: 'error', message: err.message }); }
});

// ═════════════════════════════════════════════════════════════════════════════
// PASSENGER ENDPOINTS — requireRole('Passenger') on every route
// Passengers can only see their own bookings and payments.
// ═════════════════════════════════════════════════════════════════════════════

// GET /api/passenger/routes — browse all active routes
app.get('/api/passenger/routes', authenticateToken, requireRole('Passenger'), async (req, res) => {
  if (useMock) {
    return res.json(mock.routes.map(r => {
      const b = mock.buses.find(b => b.id === r.bus_id);
      return { ...r, bus_number: b?.bus_number, busStatus: b?.status };
    }));
  }
  try {
    const { rows } = await pool.query(
      `SELECT r.*, b.bus_number, b.status AS "busStatus" FROM routes r JOIN buses b ON r.bus_id=b.id WHERE b.status='active' ORDER BY r.departure_time`
    );
    res.json(coerceNumerics(rows));
  } catch (err) { res.status(500).json({ status: 'error', message: err.message }); }
});

// GET /api/passenger/bookings — own bookings only
app.get('/api/passenger/bookings', authenticateToken, requireRole('Passenger'), async (req, res) => {
  const uid = req.user.userId;
  if (useMock) {
    return res.json(mock.bookings.filter(b => b.passenger_id === uid).map(bk => {
      const r = mock.routes.find(r => r.id === bk.route_id);
      const b = r ? mock.buses.find(b => b.id === r.bus_id) : null;
      const p = mock.payments.find(p => p.booking_id === bk.id);
      return {
        id: bk.id, route_id: bk.route_id,
        departure_date: bk.departure_date,
        source: r?.source, destination: r?.destination,
        departure_time: r?.departure_time, arrival_time: r?.arrival_time,
        days_of_week: r?.days_of_week, fare: r?.fare, bus_number: b?.bus_number,
        seat_number: bk.seat_number, booking_date: bk.booking_date,
        booking_status: bk.booking_status,
        payment_status: p?.status || 'Pending',
        payment_method: p?.payment_method || 'Cash',
        transaction_id: p?.transaction_id || null,
        amount: p?.amount || r?.fare || 0,
      };
    }));
  }
  try {
    const { rows } = await pool.query(
      `SELECT bk.id, bk.route_id, r.source, r.destination, r.departure_time, r.fare,
              b.bus_number, bk.seat_number, bk.booking_date, bk.booking_status,
              COALESCE(p.status,'Pending') AS payment_status,
              p.transaction_id, COALESCE(p.amount,r.fare) AS amount
       FROM bookings bk
       JOIN routes r ON bk.route_id = r.id
       JOIN buses  b ON r.bus_id    = b.id
       LEFT JOIN payments p ON bk.id = p.booking_id
       WHERE bk.passenger_id = $1
       ORDER BY bk.booking_date DESC`, [uid]
    );
    res.json(coerceNumerics(rows));
  } catch (err) { res.status(500).json({ status: 'error', message: err.message }); }
});

// GET /api/passenger/routes/:routeId/seats?date=YYYY-MM-DD — available seats for a date
app.get('/api/passenger/routes/:routeId/seats', authenticateToken, requireRole('Passenger'), async (req, res) => {
  const routeId = parseInt(req.params.routeId);
  const date    = req.query.date;
  console.log(`[Seats] GET routeId=${routeId} date=${date} useMock=${useMock}`);

  if (!date) return res.status(400).json({ status: 'error', message: 'date query param required (YYYY-MM-DD).' });
  if (isNaN(routeId)) return res.status(400).json({ status: 'error', message: 'Invalid route id.' });

  if (useMock) {
    const route = mock.routes.find(r => r.id === routeId);
    if (!route) {
      console.log(`[Seats] Mock: route ${routeId} not found. Known route ids: ${mock.routes.map(r=>r.id).join(',')}`);
      return res.status(404).json({ status: 'error', message: 'Route not found.' });
    }
    const bus = mock.buses.find(b => b.id === route.bus_id);
    const capacity = bus ? bus.capacity : 50;
    const booked = mock.bookings
      .filter(b => b.route_id === routeId && b.departure_date === date && b.booking_status !== 'Cancelled')
      .map(b => b.seat_number);
    const available = Array.from({ length: capacity }, (_, i) => i + 1).filter(s => !booked.includes(s));
    console.log(`[Seats] Mock: capacity=${capacity} booked=${booked.length} available=${available.length}`);
    return res.json({ routeId, date, capacity, booked, available, totalAvailable: available.length });
  }
  try {
    const { rows: routes } = await pool.query('SELECT r.*, b.capacity FROM routes r JOIN buses b ON r.bus_id=b.id WHERE r.id=$1', [routeId]);
    if (routes.length === 0) {
      console.log(`[Seats] DB: route ${routeId} not found (no JOIN match — check routes.bus_id points to a valid buses.id)`);
      return res.status(404).json({ status: 'error', message: 'Route not found.' });
    }
    const capacity = routes[0].capacity;
    console.log(`[Seats] DB: route ${routeId} found, bus capacity=${capacity}`);
    const { rows: bookedRows } = await pool.query(
      "SELECT seat_number FROM bookings WHERE route_id=$1 AND departure_date=$2 AND booking_status!='Cancelled'",
      [routeId, date]
    );
    const booked    = bookedRows.map(r => r.seat_number);
    const available = Array.from({ length: capacity }, (_, i) => i + 1).filter(s => !booked.includes(s));
    console.log(`[Seats] DB: booked=${booked.length} available=${available.length}`);
    return res.json({ routeId, date, capacity, booked, available, totalAvailable: available.length });
  } catch (err) {
    console.error(`[Seats] DB ERROR: ${err.message}`);
    res.status(500).json({ status: 'error', message: err.message });
  }
});

// POST /api/passenger/bookings — book a ticket (cash payment, specific date)
app.post('/api/passenger/bookings', authenticateToken, requireRole('Passenger'), async (req, res) => {
  const { route_id, seat_number, departure_date } = req.body;
  if (!route_id || !seat_number || !departure_date)
    return res.status(400).json({ status: 'error', message: 'route_id, seat_number, and departure_date are required.' });

  // Validate date format YYYY-MM-DD
  if (!/^\d{4}-\d{2}-\d{2}$/.test(departure_date))
    return res.status(400).json({ status: 'error', message: 'departure_date must be YYYY-MM-DD.' });

  const uid = req.user.userId;

  if (useMock) {
    const route = mock.routes.find(r => r.id === route_id);
    if (!route) return res.status(400).json({ status: 'error', message: 'Route not found.' });
    const conflict = mock.bookings.find(b =>
      b.route_id === route_id && b.seat_number === seat_number &&
      b.departure_date === departure_date && b.booking_status !== 'Cancelled'
    );
    if (conflict) return res.status(400).json({ status: 'error', message: `Seat ${seat_number} is already booked on ${departure_date}.` });
    const bkId = mock.nextIds.booking++;
    const pyId = mock.nextIds.payment++;
    mock.bookings.push({ id: bkId, passenger_id: uid, route_id, seat_number, departure_date, booking_date: pktISOStr(), booking_status: 'Confirmed' });
    mock.payments.push({ payment_id: pyId, booking_id: bkId, user_id: uid, amount: route.fare, payment_method: 'Cash', transaction_id: null, status: 'Pending', notes: 'Pay driver on boarding', payment_date: null, created_at: pktISOStr() });
    return res.json({ status: 'success', message: 'Booking confirmed! Pay cash to the driver on boarding.', bookingId: bkId, fare: route.fare });
  }

  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const { rows: routes } = await client.query('SELECT r.fare, b.capacity FROM routes r JOIN buses b ON r.bus_id=b.id WHERE r.id=$1', [route_id]);
    if (routes.length === 0) throw new Error('Route not found.');
    const fare = Number(routes[0].fare);

    const { rows: conflict } = await client.query(
      "SELECT id FROM bookings WHERE route_id=$1 AND seat_number=$2 AND departure_date=$3 AND booking_status!='Cancelled' FOR UPDATE",
      [route_id, seat_number, departure_date]
    );
    if (conflict.length > 0) throw new Error(`Seat ${seat_number} is already booked on ${departure_date}.`);

    const { rows: [bk] } = await client.query(
      'INSERT INTO bookings (passenger_id,route_id,seat_number,departure_date,booking_status) VALUES ($1,$2,$3,$4,$5) RETURNING id',
      [uid, route_id, seat_number, departure_date, 'Confirmed']
    );
    const bkId = bk.id;
    await client.query(
      "INSERT INTO payments (booking_id,user_id,amount,payment_method,status,notes) VALUES ($1,$2,$3,'Cash','Pending',$4)",
      [bkId, uid, fare, 'Pay driver on boarding']
    );
    await client.query('COMMIT');
    res.json({ status: 'success', message: 'Booking confirmed! Pay cash to the driver on boarding.', bookingId: bkId, fare });
  } catch (err) {
    await client.query('ROLLBACK');
    res.status(400).json({ status: 'error', message: err.message });
  } finally { client.release(); }
});

// POST /api/passenger/bookings/:id/cancel
app.post('/api/passenger/bookings/:id/cancel', authenticateToken, requireRole('Passenger'), async (req, res) => {
  const bkId = parseInt(req.params.id);
  const uid  = req.user.userId;
  if (useMock) {
    const bk = mock.bookings.find(b => b.id === bkId && b.passenger_id === uid);
    if (!bk) return res.status(404).json({ status: 'error', message: 'Booking not found.' });
    if (bk.booking_status === 'Cancelled') return res.status(400).json({ status: 'error', message: 'Already cancelled.' });
    bk.booking_status = 'Cancelled';
    const py = mock.payments.find(p => p.booking_id === bkId);
    if (py && py.status === 'Success') {
      mock.users.find(u => u.id === uid).wallet_balance += py.amount;
      py.status = 'Failed';
    }
    return res.json({ status: 'success', message: 'Booking cancelled.' });
  }
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const { rows: bks } = await client.query("SELECT * FROM bookings WHERE id=$1 AND passenger_id=$2 FOR UPDATE", [bkId, uid]);
    if (bks.length === 0) throw new Error('Booking not found.');
    if (bks[0].booking_status === 'Cancelled') throw new Error('Already cancelled.');
    await client.query("UPDATE bookings SET booking_status='Cancelled' WHERE id=$1", [bkId]);
    const { rows: pys } = await client.query("SELECT * FROM payments WHERE booking_id=$1", [bkId]);
    if (pys.length > 0 && pys[0].status === 'Success') {
      await client.query("UPDATE users    SET wallet_balance=wallet_balance+$1 WHERE id=$2", [pys[0].amount, uid]);
      await client.query("UPDATE payments SET status='Failed' WHERE booking_id=$1", [bkId]);
    }
    await client.query('COMMIT');
    res.json({ status: 'success', message: 'Booking cancelled.' });
  } catch (err) {
    await client.query('ROLLBACK');
    res.status(400).json({ status: 'error', message: err.message });
  } finally { client.release(); }
});

// GET /api/passenger/payments — own payment history only
app.get('/api/passenger/payments', authenticateToken, requireRole('Passenger'), async (req, res) => {
  const uid = req.user.userId;
  if (useMock) {
    return res.json(mock.payments
      .filter(p => mock.bookings.find(b => b.id === p.booking_id && b.passenger_id === uid))
      .map(p => {
        const bk = mock.bookings.find(b => b.id === p.booking_id);
        const r  = bk ? mock.routes.find(r => r.id === bk.route_id) : null;
        return { ...p, source: r?.source, destination: r?.destination };
      })
    );
  }
  try {
    const { rows } = await pool.query(
      `SELECT p.*, r.source, r.destination
       FROM payments p
       JOIN bookings bk ON p.booking_id = bk.id
       JOIN routes   r  ON bk.route_id  = r.id
       WHERE bk.passenger_id=$1
       ORDER BY p.payment_date DESC`, [uid]
    );
    res.json(coerceNumerics(rows));
  } catch (err) { res.status(500).json({ status: 'error', message: err.message }); }
});


// POST /api/auth/forgot-password
// Security: always returns success regardless of whether email exists
// (prevents email enumeration attacks). In production, send a real reset email.
app.post('/api/auth/forgot-password', async (req, res) => {
  const { email } = req.body;
  if (!email) return res.status(400).json({ status: 'error', message: 'Email is required.' });

  console.log(`[Auth][forgot-password] Reset requested for email=${email}`);

  if (!useMock) {
    try {
      const { rows } = await pool.query('SELECT id, name FROM users WHERE email = $1', [email]);
      if (rows.length > 0) {
        // TODO: In production — generate a signed reset token, store it with expiry,
        // and email it to the user via a mail service (SendGrid, SES, etc.)
        const resetToken = crypto.randomBytes(32).toString('hex');
        console.log(`[Auth][forgot-password] MOCK reset token for id=${rows[0].id}: ${resetToken}`);
        // For now: just log it. In production:
        // UPDATE users SET reset_token=$1, reset_expires = NOW() + INTERVAL '1 hour' WHERE id=$2
      }
    } catch (err) {
      console.error(`[Auth][forgot-password] DB error: ${err.message}`);
    }
  }

  // Always return the same success message (security: do not reveal if email exists)
  return res.json({
    status:  'success',
    message: 'If this email is registered, a password reset link has been sent.',
  });
});

// ═════════════════════════════════════════════════════════════════════════════
// PAYMENT ROUTES — MVC router (Passenger: create/verify/my | Admin: all/summary)
// ═════════════════════════════════════════════════════════════════════════════
// In DB mode: PaymentController uses req.app.locals.pool
// NOTE: makePaymentRouter / PaymentController (./backend/routes/paymentRoutes.js)
// was not provided for this conversion. It receives the same `pool` object here,
// which is now a `pg` Pool rather than a mysql2 Pool — any raw SQL inside that
// file (placeholders, `.query()` destructuring, `insertId`/`affectedRows`, error
// codes like ER_DUP_ENTRY) needs the same conversion pattern applied in this file:
//   • '?' placeholders → '$1', '$2', ...
//   • [rows] = await pool.query(...) → const { rows } = await pool.query(...)
//   • INSERT ... → add "RETURNING id" and read result.rows[0].id instead of insertId
//   • result.affectedRows → result.rowCount
//   • err.code === 'ER_DUP_ENTRY' → err.code === '23505'
//   • pool.getConnection()/beginTransaction()/commit()/rollback() → pool.connect(),
//     client.query('BEGIN'), client.query('COMMIT'), client.query('ROLLBACK')
// Share that file if you'd like it converted too.
// In mock mode: the mock payment endpoints below handle the same paths
if (!useMock) {
  app.locals.pool = pool;
  app.use('/api/payments', makePaymentRouter(authenticateToken, requireRole));
} else {
  // ─── Mock payment endpoints (mirror PaymentController behaviour) ───────────
  app.get('/api/payments/summary', authenticateToken, requireRole('Admin'), (req, res) => {
    const total   = mock.payments.reduce((s,p) => s + (p.status==='Success' ? p.amount : 0), 0);
    return res.json({ totalRevenue: total, totalPayments: mock.payments.length, successCount: mock.payments.filter(p=>p.status==='Success').length, pendingCount: mock.payments.filter(p=>p.status==='Pending').length, failedCount: mock.payments.filter(p=>p.status==='Failed').length });
  });

  app.get('/api/payments/my', authenticateToken, requireRole('Passenger'), (req, res) => {
    const uid = req.user.userId;
    return res.json(mock.payments.filter(p => p.user_id === uid).map(p => {
      const bk = mock.bookings.find(b => b.id === p.booking_id);
      const r  = bk ? mock.routes.find(r => r.id === bk.route_id) : null;
      const b  = r  ? mock.buses.find(b => b.id === r.bus_id) : null;
      return { ...p, source: r?.source, destination: r?.destination, departure_time: r?.departure_time, bus_number: b?.bus_number, seat_number: bk?.seat_number };
    }));
  });

  app.get('/api/payments/:bookingId', authenticateToken, (req, res) => {
    const bookingId = parseInt(req.params.bookingId);
    const py = mock.payments.find(p => p.booking_id === bookingId);
    if (!py) return res.status(404).json({ status:'error', message:'No payment for this booking.' });
    if (req.user.role === 'Passenger' && py.user_id !== req.user.userId)
      return res.status(403).json({ status:'error', message:'Access denied.' });
    return res.json(py);
  });

  app.get('/api/payments', authenticateToken, requireRole('Admin'), (req, res) => {
    return res.json(mock.payments.map(p => {
      const u  = mock.users.find(u => u.id === p.user_id);
      const bk = mock.bookings.find(b => b.id === p.booking_id);
      const r  = bk ? mock.routes.find(r => r.id === bk.route_id) : null;
      const b  = r  ? mock.buses.find(b => b.id === r.bus_id) : null;
      return { ...p, passenger_name: u?.name, passenger_email: u?.email, source: r?.source, destination: r?.destination, bus_number: b?.bus_number, seat_number: bk?.seat_number, booking_status: bk?.booking_status };
    }));
  });
}

// ─── Start ────────────────────────────────────────────────────────────────────
app.listen(PORT, () => {
  console.log(`[SmartTransit] Server running on port ${PORT}`);
  console.log(`[SmartTransit] DB mode: ${useMock ? 'IN-MEMORY MOCK' : 'Supabase PostgreSQL'}`);
  console.log(`[SmartTransit] RBAC: Admin=full | Driver=own buses | Passenger=own bookings`);
  console.log(`[SmartTransit] Registration: Passenger only (Admin/Driver via seed.sql or admin panel)`);
  console.log(`[SmartTransit] Payment system: POST /api/payments/create | POST /api/payments/verify`);
});
