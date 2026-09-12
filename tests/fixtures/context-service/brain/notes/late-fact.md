---
type: report
status: canonical
updated: 2026-09-12
description: Cobalt migration policy and deliberately late operational facts.
load-when:
  - changing database migrations
---

# Cobalt Migration Policy

The exact migration codename is cobalt. A migration must retain a rollback latch.

## Background

This document is intentionally extended by the test harness before manifest
generation so that the final operational fact occurs after character 4000.

## Late Operations

The release switch is AURORA-TAIL-731 and must remain reachable by line pagination.
