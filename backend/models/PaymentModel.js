/**
 * models/PaymentModel.js
 * Cash-only payment model. No gateway_ref column.
 * status: Pending | Paid | Failed
 */

export class PaymentModel {

  static async createPending(conn, { bookingId, userId, amount, notes }) {
    const [r] = await conn.query(
      `INSERT INTO payments (booking_id, user_id, amount, payment_method, status, notes)
       VALUES (?, ?, ?, 'Cash', 'Pending', ?)`,
      [bookingId, userId, amount, notes || 'Pay driver on boarding']
    );
    return r.insertId;
  }

  static async markPaid(conn, { paymentId, transactionId }) {
    await conn.query(
      `UPDATE payments SET status = 'Paid', transaction_id = ?, payment_date = NOW()
        WHERE payment_id = ?`,
      [transactionId, paymentId]
    );
  }

  static async markFailed(conn, { paymentId, notes }) {
    await conn.query(
      `UPDATE payments SET status = 'Failed', notes = ?, payment_date = NOW()
        WHERE payment_id = ?`,
      [notes || 'Cancelled', paymentId]
    );
  }

  static async findByBookingId(conn, bookingId) {
    const [rows] = await conn.query(
      `SELECT p.*, u.name AS passenger_name, u.email AS passenger_email
         FROM payments p JOIN users u ON p.user_id = u.id
        WHERE p.booking_id = ?`, [bookingId]
    );
    return rows[0] || null;
  }

  static async findAll(conn) {
    const [rows] = await conn.query(
      `SELECT p.payment_id, p.booking_id, p.user_id,
              u.name AS passenger_name, u.email AS passenger_email,
              p.amount, p.payment_method, p.transaction_id,
              p.status, p.notes, p.payment_date, p.created_at,
              r.source, r.destination, r.departure_time,
              bk.departure_date, bk.seat_number, bk.booking_status,
              b.bus_number
         FROM payments p
         JOIN users    u  ON p.user_id       = u.id
         JOIN bookings bk ON p.booking_id    = bk.id
         JOIN routes   r  ON bk.route_id     = r.id
         JOIN buses    b  ON r.bus_id        = b.id
        ORDER BY bk.departure_date DESC, p.created_at DESC`
    );
    return rows;
  }

  static async summary(conn) {
    const [[row]] = await conn.query(
      `SELECT
          COALESCE(SUM(CASE WHEN status='Paid' THEN amount ELSE 0 END), 0) AS totalRevenue,
          COUNT(*)                     AS totalPayments,
          SUM(status = 'Paid')         AS successCount,
          SUM(status = 'Pending')      AS pendingCount,
          SUM(status = 'Failed')       AS failedCount
         FROM payments`
    );
    return {
      totalRevenue:  Number(row.totalRevenue),
      totalPayments: row.totalPayments,
      successCount:  row.successCount,
      pendingCount:  row.pendingCount,
      failedCount:   row.failedCount,
    };
  }

  static async findByUserId(conn, userId) {
    const [rows] = await conn.query(
      `SELECT p.payment_id, p.booking_id, p.amount, p.payment_method,
              p.transaction_id, p.status, p.notes, p.payment_date,
              r.source, r.destination, r.departure_time,
              bk.departure_date, bk.seat_number, b.bus_number
         FROM payments p
         JOIN bookings bk ON p.booking_id = bk.id
         JOIN routes   r  ON bk.route_id  = r.id
         JOIN buses    b  ON r.bus_id     = b.id
        WHERE p.user_id = ?
        ORDER BY bk.departure_date DESC`, [userId]
    );
    return rows;
  }
}
