# LIVE_LESSONS.md

# NexusEdgeEA - Live Trading Lessons

This document records every important lesson learned from live trading.

Unlike backtests, these observations come from real market behavior and therefore have the highest level of confidence.

Every future improvement should take these lessons into account.

---

# LESSON 001
## Floating profit is more important than final profit

Observation

A trade can generate several thousand dollars of floating profit before finally closing with a much smaller secured profit.

Example

Floating Profit:
+6800 USD

Final Profit:
+197 USD

Conclusion

The EA must optimize profit retention, not only profit protection.

Future Direction

Develop adaptive protection capable of distinguishing:

- healthy pullbacks
- real reversals

instead of protecting profits too early.

---

# LESSON 002
## Price breathes before continuing

Observation

Many winning trends temporarily retrace before continuing.

Immediate tightening of Stop Loss often removes the position too early.

Conclusion

Market structure should participate in Stop Loss management.

Future Direction

Dynamic Structure Protection.

---

# LESSON 003
## Locked Stop Loss is safer than Initial Stop Loss

Observation

Once Stop Loss was moved above entry, the trade became risk free.

This significantly reduced psychological pressure.

Conclusion

Moving to secured profit remains an excellent idea.

However, future versions should continue managing this Stop Loss dynamically.

---

# LESSON 004
## Intrabar market information is valuable

Observation

Between two H1 candles, market conditions may completely change.

Current architecture only reacts mainly at candle opening.

Conclusion

Trade supervision must become continuous.

Future Direction

Create a dedicated Trade Supervision Engine.

---

# LESSON 005
## Live trading exposes behaviors invisible in backtests

Observation

Several situations appeared only in live trading:

- invalid stops
- broker restrictions
- reopening gaps
- execution timing

Conclusion

Live testing is mandatory.

Backtests cannot validate every behavior.

---

# LESSON 006
## Market reopening is dangerous

Observation

Daily reopening generated immediate price gaps.

The EA had no time to react.

Conclusion

Market reopening deserves dedicated protection.

Possible future features

- Gap detector
- Overnight risk reduction
- Session-aware protection

---

# LESSON 007
## Floating drawdown is acceptable if structure remains valid

Observation

Some trades experienced:

-3000 USD

-5000 USD

before recovering.

The structure remained valid.

Conclusion

Not every drawdown should trigger emergency protection.

Market structure must remain the primary decision factor.

---

# LESSON 008
## Dynamic Stop Loss is the future

Observation

Static Stop Loss management captures only a fraction of large trends.

Future versions should continuously evaluate:

- new swing highs
- new swing lows
- BOS
- CHOCH
- volatility
- ATR

before deciding whether Stop Loss should move.

---

# LESSON 009
## Every protection decision should be explainable

Observation

When Stop Loss remains unchanged, the trader should understand why.

Future diagnostics should answer:

Why wasn't BreakEven activated?

Why wasn't Trailing selected?

Why Structure lost?

Why PeakPercent won?

Why no modification happened?

---

# LESSON 010
## Broker behavior matters

Observation

Different brokers may:

- reject valid prices
- apply different StopLevel rules
- have different TickValue

Conclusion

Price-based calculations are preferred over money-based calculations whenever possible.

---

# LESSON 011
## Statistics drive development

Observation

Development decisions should never rely only on intuition.

Every improvement must be supported by:

- MFE
- MAE
- Floating Profit
- Holding Time
- Drawdown
- Protection Efficiency

---

# LESSON 012
## One live trade can reveal more than hundreds of backtests

Observation

Several major architectural improvements came directly from observing only a few live trades.

Conclusion

Each live trade should be analyzed in detail.

No live trade should be ignored.

---

# Permanent Development Rule

Live observations are considered part of the specification.

Whenever a new live behavior is discovered:

1. Record it.
2. Understand it.
3. Explain it.
4. Improve the architecture.
5. Never forget it.

This document should continuously grow during the life of the project.
