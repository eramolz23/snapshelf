# Command-Control Hotkeys Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make SnapShelf use Command-Control-2 for area capture and Command-Control-1 for full-screen capture.

**Architecture:** Keep existing Carbon global-hotkey implementation. Change modifier configuration, menu key equivalents, and shortcut documentation together.

**Tech Stack:** Swift 5, AppKit, Carbon HIToolbox, macOS app bundle

---

### Task 1: Correct Hotkeys

**Files:**
- Modify: `main.swift`
- Modify: `README.md`

- [x] Change Carbon modifier configuration to `cmdKey | controlKey`.
- [x] Remove obsolete Shift-based alternate registrations.
- [x] Change menu key-equivalent masks to `[.command, .control]`.
- [x] Update source comments and README shortcut labels.
- [x] Compile with Swift 5 and verify source assertions.

### Task 2: Install and Verify

**Files:**
- Update installed app: `~/Applications/SnapShelf.app`

- [x] Stop running SnapShelf process.
- [x] Build and sign installed app.
- [x] Launch installed app and confirm both registrations return status `0`.
- [ ] Physically test Command-Control-2 and Command-Control-1.
