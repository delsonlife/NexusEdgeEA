# KNOWN_ISSUES.md

# NexusEdgeEA - Known Issues & Live Observations

This document records every important issue discovered during live trading and backtesting.

These observations are considered part of the project knowledge.

They should always be reviewed before implementing new features.

---

# ISSUE 001
## ProfitGuard PeakPercent generated impossible Stop Loss prices

Status:
Fixed (Sprint 2)

Description:

During live trading, ProfitGuard PeakPercent occasionally proposed Stop Loss levels that were above prices never reached by the market.

Example:

Current market:
4078

Generated Stop Loss:
4093

The broker correctly rejected these levels with "Invalid Stops".

Root Cause:

The mechanism converted floating profit ($) into price using TickValue / TickSize.

The conversion was broker dependent and produced unrealistic prices.

Decision:

Remove the dollar-to-price conversion.

Future implementations must calculate protection directly from price movement.

Priority:

Critical

---

# ISSUE 002
## PeakPercent always defeated every other protection

Status:
Fixed (Sprint 2)

Description:

PeakPercent always proposed the "best" theoretical Stop Loss.

Therefore:

- BreakEven lost
- Trailing lost
- Structure lost

Even when PeakPercent generated an invalid Stop Loss.

Result:

The engine selected an impossible candidate.

Priority:

Critical

---

# ISSUE 003
## Backtest and Live behavior are different

Status:
Open

Description:

Live trading protects profits much better than current backtests.

Backtests often finish at Initial Stop Loss.

Live trades frequently activate protection.

Current hypothesis:

The execution timing is different.

The protection engine behaves differently in Strategy Tester.

This difference must be investigated.

Priority:

Critical

---

# ISSUE 004
## Profit protection only reacts at H1 updates

Status:
Open

Description:

The SignalManager recalculates mainly at the opening of each H1 candle.

Open positions are not supervised continuously.

Consequence:

The market can completely change during the next 60 minutes.

Future Direction:

Introduce continuous intrabar supervision.

Priority:

Very High

---

# ISSUE 005
## Protection must become dynamic

Status:
Open

Description:

Once a Stop Loss is locked, it rarely adapts again.

Live observations suggest that the EA should:

- Detect healthy pullbacks
- Detect continuation structures
- Move Stop Loss accordingly
- Avoid exiting profitable trends too early

Priority:

Very High

---

# ISSUE 006
## Gap Risk after market reopening

Status:
Open

Description:

Daily reopening generated immediate gaps.

One live trade lost nearly $10,000 floating before the EA could react.

The Stop Loss was hit instantly.

The EA never had the opportunity to compute new information.

Future Solution:

Implement Gap Protection.

Examples:

- Suspend entries before close.
- Reduce exposure.
- Force BreakEven before close.
- Avoid overnight positions when appropriate.

Priority:

Critical

---

# ISSUE 007
## Session Closing Risk

Status:
Open

Description:

The EA currently ignores upcoming daily market closures.

Future versions should know:

- Remaining minutes before close.
- Daily reopening.
- Weekend reopening.

Trading decisions should take these events into account.

Priority:

High

---

# ISSUE 008
## Server Time vs Local Time

Status:
Observed

Description:

Broker server time differs from local time.

Example:

Local:
20:00

Server:
22:00

Future improvements should always rely on broker server time internally.

Priority:

Medium

---

# ISSUE 009
## Missing diagnostics during open trades

Status:
Open

Description:

Once a trade is open, very little information is displayed.

The user cannot know:

- Current structure
- Current score
- Why SL stays unchanged
- Why protection is inactive

Future versions should continuously explain the current decision.

Priority:

High

---

# ISSUE 010
## Signal recalculation

Status:
Open

Description:

Signals are mainly computed at new H1 candles.

The EA should distinguish:

Decision Engine

and

Trade Supervision Engine

A trade already open should continue learning from the market.

Priority:

Very High

---

# ISSUE 011
## Profit Protection wins too early

Status:
Observed

Description:

One live trade reached:

Floating Profit:
6800 USD

Final secured profit:
197 USD

The protection worked correctly.

However, the trend might have continued.

Future improvements:

Adaptive trailing using market structure.

Priority:

High

---

# ISSUE 012
## Live observations have priority

Permanent Rule

Whenever:

Live Trading

contradicts

Backtesting

Live observations become the reference.

The code must explain reality.

Reality must never be modified to fit the backtest.

---

# ISSUE 013
## Every trade should become explainable

Future Goal

At any moment the EA should explain:

Why this trade exists.

Why this SL.

Why this TP.

Why this protection.

Why another protection lost.

Why no modification occurred.

The objective is complete transparency.

---

# Future Development Priorities

1. Finish ProfitProtection Sprint 2
2. Investigate Live vs Backtest differences
3. Intrabar Trade Supervision
4. Dynamic Structure-based Stop Loss
5. Gap Protection
6. Session Closing Awareness
7. Adaptive Trailing
8. Continuous Diagnostics
9. Trade Explanation Engine
10. Self-learning Statistics
