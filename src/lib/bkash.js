// bKash payments: placeholder until the bKash Tokenized Checkout gateway is connected.
// Nagad works the same way today (provider "nagad"), until its gateway is connected too.
// Today the customer sends the money to our merchant number (BKASH_MERCHANT_NUMBER / NAGAD_MERCHANT_NUMBER,
// shown by GET /api/v1/payment-options) and gives the wallet number (+ TrxID) at checkout. The order is
// placed with paymentStatus PENDING and a Payment row (provider "bkash" | "nagad", PENDING, walletNumber,
// transactionId); an admin checks the merchant account, then marks it PAID or REFUNDED through
// PATCH /api/v1/admin/orders/:orderId. Only admins see walletNumber / transactionId; they are never logged.
// Vendors may confirm BKASH / NAGAD orders without waiting. The money is the platform's, not the shop's.
//
// When the gateway arrives, implement these and call them from checkout / a callback route:
//   createPayment(order)     -> { paymentId, bkashURL }   (grant token, create payment)
//   executePayment(paymentId) -> { trxID, status }        (after the customer returns)
//   refundPayment(payment, amount)                        (on cancellation)
// Store trxID in Payment.providerRef and the raw response in Payment.rawPayload.

const notConnected = () => {
  throw new Error('The bKash gateway is not connected yet');
};

export const BKASH_PROVIDER = 'bkash';
export const isGatewayConnected = () => false;
export const createPayment = notConnected;
export const executePayment = notConnected;
export const refundPayment = notConnected;
