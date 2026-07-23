# PROJECT_CONTEXT.md

# NexusEdgeEA - Project Context

## Overview

NexusEdgeEA is a professional algorithmic trading system developed for MetaTrader 5 (MT5).

The objective is **not** to create a high-frequency trading robot, but to build an institutional-grade decision engine capable of trading XAUUSD with robust risk management and continuous evolution based on real trading observations.

The project follows a modular architecture where each component has a single responsibility.

The EA is designed to evolve through successive sprints, each validated by compilation, backtests and live demo testing before any new feature is added.

---

# Main Objectives

The long-term objectives are:

- Produce high-quality trading decisions rather than many trades.
- Preserve capital above all else.
- Maximize captured profit during strong trends.
- Protect floating profits intelligently.
- Learn from every trade using diagnostics and statistics.
- Keep the architecture clean and maintainable.

---

# Trading Philosophy

The EA does not rely on indicators alone.

Decisions are based on multiple confirmations including:

- Market Structure
- Trend Context
- Candlestick Patterns
- Support / Resistance
- Fibonacci Levels
- Market Sessions
- News Filter
- Volatility
- Risk Filters

The SignalManager aggregates these elements into Bull Score and Bear Score before generating BUY, SELL or NONE.

---

# Current Architecture

Pipeline:

Market Data
↓
Indicators
↓
Market Context
↓
Pattern Detection
↓
Support / Resistance
↓
Market Structure
↓
Session Filter
↓
News Filter
↓
Global Filters
↓
SignalManager
↓
Validator
↓
RiskManager
↓
TradeManager
↓
ProfitProtectionEngine
↓
PositionManager
↓
TradeLifecycleTracker
↓
Statistics
↓
Diagnostics
↓
Dashboard

---

# Development Philosophy

Every modification must respect these principles:

- Never break the modular architecture.
- Avoid quick fixes.
- Prefer robust solutions over temporary patches.
- Every modification must be justified technically.
- Backtest results alone are NOT considered sufficient.
- Live observations always have priority over theoretical assumptions.
- Every sprint must compile successfully before moving to the next one.

---

# Current Development Status

The EA already includes:

- Modular architecture
- Signal scoring engine
- Validator
- Risk Manager
- Trade Manager
- Statistics Engine
- Trade Lifecycle Tracker
- Dashboard
- Diagnostics
- Profit Protection Engine

---

# Current Focus

Current development focuses on improving the Profit Protection Engine.

The existing mechanisms are:

- BreakEven
- Classic Trailing
- ProfitGuard Structure
- ProfitGuard PeakPercent
- Emergency Protection

---

# Important Live Observations

Several important behaviors have been observed during live trading.

## 1. Live differs from Backtest

The live EA protects profits much better than current backtests.

This difference must be investigated.

---

## 2. Gap Risk

Daily market reopening can generate large gaps.

Some trades have been stopped immediately after reopening before the EA could react.

Gap protection must become part of the architecture.

---

## 3. Profit Protection

Current protection activates correctly in many situations.

However improvements are still required:

- Better SL positioning
- Dynamic structure adaptation
- Avoid impossible Stop Loss proposals
- Better handling of broker restrictions

---

## 4. Intrabar Management

Currently most strategic calculations occur at the beginning of each H1 candle.

Future versions should continuously monitor the market during the life of an open trade instead of waiting for the next H1 candle.

This is considered one of the highest priority future improvements.

---

## 5. Live First Philosophy

When live behavior contradicts backtest behavior:

Live trading observations are considered the reference.

The code must explain reality, not force reality to match the backtest.

---

# Coding Rules

When modifying the code:

- Do not rewrite large portions unnecessarily.
- Keep backward compatibility whenever possible.
- Respect existing interfaces.
- Preserve logging.
- Preserve diagnostics.
- Preserve statistics.
- Preserve modularity.

Every modification should remain easy to audit.

---

# Diagnostics

Diagnostics are an essential part of the project.

Every important decision should be explainable.

The EA should always be able to answer questions such as:

- Why was a trade rejected?
- Why was a SL modified?
- Why was a protection selected?
- Why did another protection lose?
- Why was no signal generated?

If a decision cannot be explained, diagnostics should be improved.

---

# Statistics Philosophy

Statistics are not decorative.

They drive development.

Future improvements must always rely on measurable observations such as:

- MFE
- MAE
- Heat
- Win Rate
- Time in Profit
- Time in Loss
- Protection Efficiency
- Activation Delay

---

# Future Vision

The long-term vision is to transform NexusEdgeEA into an adaptive institutional trading engine capable of:

- Dynamic market understanding
- Continuous trade supervision
- Intelligent profit maximization
- Adaptive protection
- Self-diagnostic capabilities
- Data-driven evolution

Every sprint should move the project closer to this objective.

---

# Important Rule for AI Assistants

Before proposing any modification:

1. Understand the existing architecture.
2. Search for the root cause.
3. Prefer minimal and robust modifications.
4. Preserve compatibility with the rest of the project.
5. Explain the technical reasoning before writing code.

Architecture quality always has priority over development speed.
