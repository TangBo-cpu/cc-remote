---
name: CC Remote Cool Glass Console
description: A restrained Apple-inspired blue-gray glass control surface for supervising desktop Claude Code sessions.
colors:
  paper: "#F1F5F9"
  surface: "#F7FAFC"
  surface-elevated: "#FBFCFD"
  control: "#EEEFF0"
  ink: "#1C1C1E"
  muted: "#636B74"
  inactive: "#8E8E93"
  inactive-light: "#BEC7D0"
  accent: "#3877A7"
  accent-soft: "#E4EFF7"
  danger: "#B54747"
  warning: "#94662D"
  glass: "rgba(248,251,254,0.80)"
  glass-strong: "rgba(249,251,253,0.92)"
  glass-control: "rgba(255,255,255,0.75)"
  glass-highlight: "rgba(255,255,255,0.70)"
  scrim: "rgba(17,24,32,0.29)"
typography:
  headline:
    fontFamily: "system-ui, -apple-system, BlinkMacSystemFont, Segoe UI, sans-serif"
    fontSize: "21px"
    fontWeight: 700
    lineHeight: 1.25
    letterSpacing: "-0.02em"
  title:
    fontFamily: "system-ui, -apple-system, BlinkMacSystemFont, Segoe UI, sans-serif"
    fontSize: "16px"
    fontWeight: 700
    lineHeight: 1.35
  body:
    fontFamily: "system-ui, -apple-system, BlinkMacSystemFont, Segoe UI, sans-serif"
    fontSize: "15px"
    fontWeight: 400
    lineHeight: 1.6
  label:
    fontFamily: "system-ui, -apple-system, BlinkMacSystemFont, Segoe UI, sans-serif"
    fontSize: "12px"
    fontWeight: 500
    lineHeight: 1.35
  code:
    fontFamily: "JetBrains Mono, SFMono-Regular, Consolas, monospace"
    fontSize: "12px"
    fontWeight: 500
    lineHeight: 1.45
rounded:
  compact: "8px"
  control: "12px"
  surface: "16px"
  header: "22px"
  composer: "28px"
  pill: "999px"
spacing:
  xxs: "4px"
  xs: "8px"
  sm: "12px"
  md: "16px"
  lg: "20px"
  xl: "24px"
  xxl: "32px"
components:
  button-primary:
    backgroundColor: "{colors.accent}"
    textColor: "{colors.surface-elevated}"
    typography: "{typography.label}"
    rounded: "{rounded.control}"
    height: "52px"
    padding: "0 20px"
  session-header:
    backgroundColor: "transparent"
    textColor: "{colors.ink}"
    rounded: "{rounded.header}"
    height: "48px"
    padding: "0"
  composer:
    backgroundColor: "{colors.glass-strong}"
    textColor: "{colors.ink}"
    rounded: "{rounded.composer}"
    height: "110px"
    padding: "14px 12px 12px"
  activity-card:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.ink}"
    rounded: "{rounded.surface}"
    padding: "14px 16px"
---

# Design System: CC Remote Cool Glass Console

## Overview

**Creative North Star: “Cool Glass Control Surface”**

Operate-mode mobile UI for remote supervision of a real desktop Claude Code session. The replacement world is pale blue, cool gray, and Apple-inspired: content remains a standard readable material, while controls and navigation use restrained translucent surfaces. Glass is a material treatment, not the product identity; blue is a sparse action cue.

The chat surface is calm. No ornamental motion, glow, saturated or blue-purple decorative gradient, terminal chrome, or generic glassmorphism. The current low-contrast static cool blue-gray background gradient is allowed. The implementation is Flutter-native; bounded header/composer chrome may sample the background with real backdrop blur, while content and text-heavy sheets stay static.

## Colors

`AppColors` and `AppLiquidGlass` in `mobile/lib/signal_console_theme.dart` are normative. `paper`, `surface`, and `surfaceElevated` form the cool near-white content field. Ordinary controls use neutral graphite-gray fills and ink; blue is reserved for primary, selected, focus, and active states. `Liquid Thin` and `Liquid Strong` provide static fallbacks plus lower-opacity backdrop variants for bounded floating chrome. `danger` and `warning` remain independent semantic colors.

## Typography

Use platform system UI for interface and assistant reading text. Use system monospace / JetBrains Mono fallback for commands, paths, code, diffs, and numeric evidence. Baseline body text is 15px with 1.6 line height; labels remain at least 12px. Respect system text scaling and the app reading-scale setting.

## Layout

Reference phone is 390×844 with 20px horizontal safe margins and a 4px base / 8px primary rhythm. Preserve the existing information order: connection/session header, transcript and activity evidence, then composer. Visual controls may be 36px, but every interactive control keeps a minimum 48dp hit area. Sheets and drawers remain platform-native and reachable with one hand.

## Elevation & Depth

Depth comes from cool tonal layering, a directional top-left highlight, a faint lower-right thickness cue, and neutral shadow rings instead of tinted outlines. Header controls use bounded `Liquid Thin` backdrop blur; the floating composer uses bounded `Liquid Strong` backdrop blur over the transcript. Prompt chips, compact controls, settings, and app sheets retain static fallbacks. Never add blur or filters to individual scrolling rows.

## Shapes

Use 8px compact, 12px control, 16px surface, 22px header, and 28px composer radii. Pills are reserved for compact selectors and tags. Chrome icons stay linear Lucide, optically 20–24px. Session, project, and model identity marks use Phosphor Fill. Hit areas are 48dp even when the visible icon/control is 36px.

## Components

### Content and transcript

Content stays on standard cool near-white materials for comfortable reading. User bubbles, assistant reading blocks, code, diff, activity evidence, and recovery states retain their existing hierarchy and copy; short assistant replies hug content, long replies wrap in the column, and separation comes from tone, spacing, a hairline outline, icon, and text rather than a card wall.

### Navigation and controls

Header and `PromptChip` use `Liquid Thin`; the composer and `AppSheetSurface` use `Liquid Strong`; model, permission, effort, and attachment controls use the compact thin recipe inside the strong composer. Ordinary control ink is graphite; blue marks only primary, selected, focus, or active state. Dangerous stop/error actions use `danger`; warnings use `warning`.

### Settings and effort gauge

`_SettingsModalSurface` uses the high-opacity `Liquid Strong` recipe with only the static top arc highlight and no real blur. The existing effort gauge may retain its established bounded blur. This is not a general invitation to blur transcript content.

## Do's and Don'ts

### Do:

- Use glass only for controls and navigation; keep content on standard material.
- Use thicker translucent material for text-heavy overlays.
- Contract the highlight and reduce shadow depth while pressed; restore over 160ms.
- Keep blue quiet, semantic colors independent, and state readable through icon + text + tone.
- Preserve Reduce Motion behavior and 48dp hit areas.
- Let authoritative host events define stopped, completed, and failed states.

### Don't:

- Don't use terracotta/warm-paper styling as the chat console world.
- Don't use blue-purple gradients, glow, HUD chrome, black control docks, or stacked generic glass cards.
- Don't add fragment shaders, continuous material animation, or blur to text-heavy sheets and scrolling rows before device profiling.
- Don't apply real blur to every scrolling message or activity item.
- Don't use color alone for connection, warning, danger, or completion.
- Don't claim a task stopped because a local timer expired.

## Unresolved

Dark mode is out of scope for this replacement and remains a follow-up decision. The bounded header/composer blur still needs device screenshot review and real-device profile measurement before any shader dependency is considered.
