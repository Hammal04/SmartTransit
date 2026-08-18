/**
 * gateway/MockPaymentGateway.js
 *
 * Simulates a real payment provider (Stripe / Braintree / etc.).
 * Replace initiate() and verify() with real SDK calls in production.
 *
 * Test behaviour
 * ──────────────
 *  • Default                       → SUCCESS  (happy path)
 *  • gatewayRef ends with 'F'      → FAILED   (test card decline)
 *  • amount <= 0                   → FAILED   (guard)
 *  • env PAYMENT_FAIL_ALL=true     → always FAILED
 */

import crypto from 'crypto';

export class MockPaymentGateway {

  /**
   * Initiate a payment intent.
   * Returns a gatewayRef the client must send back to /verify.
   */
  static initiate({ amount, currency = 'USD', description = '' }) {
    if (!amount || amount <= 0)
      throw new Error('Payment gateway: invalid amount.');

    const gatewayRef = 'GW-' + crypto.randomBytes(8).toString('hex').toUpperCase();
    console.log(`[Gateway][initiate] amount=${amount} ${currency} ref=${gatewayRef}`);
    return { gatewayRef, status: 'initiated' };
  }

  /**
   * Verify the payment server-side.
   * The backend always calls this — we never trust a success flag from the client.
   */
  static async verify({ gatewayRef, amount }) {
    // Simulate network latency
    await new Promise(r => setTimeout(r, 60 + Math.random() * 140));

    if (process.env.PAYMENT_FAIL_ALL === 'true') {
      console.log(`[Gateway][verify] FORCED FAIL ref=${gatewayRef}`);
      return { success: false, transactionId: null, message: 'Payment declined (PAYMENT_FAIL_ALL=true).' };
    }

    if (!amount || amount <= 0)
      return { success: false, transactionId: null, message: 'Invalid payment amount.' };

    // Refs ending in 'F' simulate a card decline — useful for testing failure path
    if (gatewayRef.endsWith('F')) {
      console.log(`[Gateway][verify] SIMULATED DECLINE ref=${gatewayRef}`);
      return { success: false, transactionId: null, message: 'Card declined by issuing bank.' };
    }

    const transactionId = 'TXN-'
      + new Date().toISOString().slice(0, 10).replace(/-/g, '')
      + '-' + crypto.randomBytes(4).toString('hex').toUpperCase();

    console.log(`[Gateway][verify] SUCCESS ref=${gatewayRef} txn=${transactionId}`);
    return { success: true, transactionId, message: 'Payment verified successfully.' };
  }
}
