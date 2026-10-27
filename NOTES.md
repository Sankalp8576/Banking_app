# NOTES

## What can go wrong, and what the user sees

| Situation | App behavior | What Eva sees |
|---|---|---|
| Lost answer | The idempotency key and an unconfirmed payment are stored before the request. A later sync reconciles the bank's matching transaction without creating another one. | “Payment is unconfirmed. Sync to verify it.” |
| Unreachable | The request is not queued. Its details remain as a durable “not sent” item, and only Eva can tap Try Again. | Last known balance marked “Possibly out of date” and a Try Again button. |
| Busy | The service retries the same idempotent request after the server-provided delay. | Payment remains “Sending” until the bank replies. |
| Repeated feed entries | Feed changes are upserted by transaction ID. | One row per transaction, with its newest status. |
| Balance ahead of feed | The response's balance_cents is always used, even when the feed has no corresponding row yet. | The bank-provided balance immediately; the incoming row appears when the bank releases it. |
| Late rejection | A changed transaction replaces the completed one and the response balance replaces the local balance. | The row becomes rejected, shows its reason, and the corrected balance is displayed. |
| App killed | Transactions, balance, cursor, freshness indicator, and the local payment state are persisted before or after each meaningful transition. | On relaunch, an ambiguous payment remains visible until a sync confirms it; a definitely unsent one requires an explicit retry. |

## The prompt that got me furthest

“Compare the existing iOS project line-by-line with this coding assignment. Keep the fake bank behind URLSession, make bank responses the source of truth, persist every state required to recover after termination, and write a direct test for every scenario before polishing the UI.”

It worked because it put reconciliation and failure semantics ahead of screen details.

## Where the AI was wrong

An earlier implementation retried a lost-answer payment automatically whenever the user synced. Although the idempotency key prevented a duplicate transaction, that still acted like an automatic outgoing queue. I changed sync to be read-only: it only reconciles feed data. A payment that definitely was not sent now remains visible and requires Eva to select Try Again.

## What's next

With two more hours, I would add a small persistent repository abstraction with a dedicated test store, improve API-error presentation for final validation failures, and add UI automation for the visible stale and payment-state labels.

## Bonus: fifty thousand transactions

I would page the feed into a database keyed by transaction ID, apply change pages in a transaction, and render a cursor-backed query rather than retaining every decoded row in memory. The bank balance and feed cursor would remain independent persisted values.
