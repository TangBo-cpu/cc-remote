# CC Remote design system

CC Remote is a mobile console for supervising desktop Claude Code and Codex sessions. The transcript, current task state, and permission decisions take priority over decoration.

## Appearance

The app provides two palettes: light and dark. Settings offers Follow system, Light, and Dark; Follow system is the default. An explicit choice is stored locally and restored on launch. Switching appearance preserves the current session, draft, transcript position, and open settings page.

Pages and transcript text use the active light or dark palette. Floating controls, the composer, and panels use neutral glass with restrained backdrop blur, near-white or charcoal fills, faint highlight edges, and soft offset shadows. Old background preferences are ignored.

## Colors

`AppPalette.of(context)` selects semantic colors from the active Flutter theme. Components read these roles instead of choosing raw palette values. `AppColors` remains a light-palette compatibility facade for static style defaults and existing callers.

| Role | Light | Dark |
| --- | --- | --- |
| Page | `#F9F9F9` | `#111111` |
| Surface | `#FFFFFF` | `#1B1B1B` |
| Control | `#F0F0F0` | `#292929` |
| Primary text | `#202020` | `#EEEEEE` |
| Secondary text | `#626262` | `#B0B0B0` |
| Primary action / focus | `#303030` | `#E7E7E7` |
| Selection surface | `#EAEAEA` | `#343434` |
| Link text | `#505050` | `#D0D0D0` |
| Success feedback | `#4C7D63` | `#91B19E` |
| Session navigation cue | `#3877A7` | `#87B7DB` |
| Error / destructive action | `#B42318` | `#FF8A80` |
| Warning | `#8A5A20` | `#EAB86A` |
| Divider | `#E5E5E5` | `#363636` |

Primary actions use charcoal in light mode and near-white in dark mode. Links use their own neutral text role with a thin underline. Selection uses neutral surfaces, icons, and font weight. Ordinary controls use neutral colors; session navigation keeps its original blue cues and colored identity marks. Success color is limited to small confirmation feedback; errors and warnings keep their own roles and accompany a label or icon. Filled buttons use their paired foreground role: `onCta` for primary actions and `onStop` for destructive actions.

Body text and action labels require at least 4.5:1 contrast against their actual background. Disabled controls use their disabled role. Photos and camera content retain their own content colors.

## Layout and typography

Keep the existing navigation and chat layout. Separate groups with spacing and alignment before adding borders or surfaces. Avoid nested decorative cards.

Use the platform UI font for interface and transcript text, and a monospace font for code, paths, and commands. Preserve reading-size settings and system text scaling. Text must wrap or scroll within its viewport without hiding controls.

Spacing follows 4, 8, 12, 16, 20, 24, and 32 points. Reuse the shared radius and touch-target constants. Compact visible icons retain an accessible touch target.

Surfaces that float above the page carry a three-layer shadow: a tight contact
edge, a directed blur, and a wide ambient wash. Sheets and dialogs share
`AppElevation.overlay`; cards use `AppElevation.softCard`. Negative spread
keeps the wide layer from smearing past the surface, and every layer stays
below 0.1 alpha. The chat header casts a short gradient band instead of a box
shadow, because it sits over a live scrolling list. Transcript content carries
no shadow: user bubbles, assistant replies, reasoning, and tool groups stay
flat so the reading column keeps one plane.

## Components

- The header contains project/session navigation, a compact center notification, new conversation, and more actions. Its center stays between the side controls without overlap and can grow with system text scaling. The transcript scrolls behind it up to the screen's top edge. A clipped backdrop blur fades out below the controls and passes through touch events; controls remain inside the system safe area. Initial transcript padding follows the measured navigation and permission-status height. Search targets stop below that overlay.
- The session navigator retains its original list spacing, colored session/project marks, blue context and selection cues, and existing search and menu behavior.
- The composer uses a 32-point corner radius, strong glass fill, and soft shadow outside the content clip. Focus adds an accent outline. Its tools have no shared filled rail; the attachment action has a light circular seat. Send and stop retain loading and disabled states.
- Assistant replies sit directly on the page without a bubble fill or outline. User messages use a neutral gray bubble without a border or shadow. Search matches retain their temporary highlight. File cards use a faint outline and a separate neutral icon seat. Markdown headings, links, tables, and code update when appearance changes.
- A turn keeps intermediate narration, reasoning, and tools in message order on the page. Process history has no card fill or outline and is expanded by default. A lightweight tool-group heading can fold the history; live thinking stays outside that disclosure so its animation remains visible. User and system-message boundaries remain separate, and search opens the group and tool detail containing its target.
- Process headings share the reply's leading edge. A process group sits directly above its final reply without an extra list gap or reply top inset. Headings retain a minimum 48-point touch target; expanded details stay in message order.
- Reasoning shows a fixed-center bloom animation and “思考中” with elapsed time while running. Completed reasoning shows a brain icon and “已深度思考”. Selectable Markdown is visible by default with a 1-point start border and natural content height. Its headings, lists, code, and body use the 13-point process-text size, below the 15-point reply body, and respect system text scaling. Tapping the title folds the content in place. Empty completed reasoning is hidden. Timer labels describe elapsed run time.
- Tool groups use text rows and colored tool icons with separate running, error, and stop cues. All steps and available details are visible by default. Tapping a step folds its detail in place, without opening another page or sheet. Commands use selectable 13-point monospace text, wrap to the viewport, and update with status and duration through completion. File paths remain selectable and open the workspace. When the group is manually folded during a run, the latest two steps remain visible. Skill rows retain their name badge. Cached and remote history remain available, and permission requests retain explicit allow/deny actions.
- Menus, model pickers, settings, and the workspace use the same palette and shared glass material. Sheets separate from the page through their surface and scrim.
- Connection, completion, stop, and failure notices share one icon-and-text slot in the header and remain visible with the keyboard open. Recovery and failure notices open scrollable details with the full selectable error and existing recovery actions; unresolved states stay visible until resolved or explicitly dismissed. Detail sheets close when their session state changes. Notifications and recovery actions retain 48-point touch targets. Permission decisions keep their existing presentation.
- Startup shows the app name and the current initialization phase on the page background.

## Motion and validation

Running titles use a 2-second linear text shimmer. The thinking bloom expands and contracts through fixed-center frames over 3 seconds. Active tool titles remain visible for at least 1.2 seconds, with later updates replacing pending titles. Adjacent chevrons rotate over 200ms using Cubic(0.22, 1, 0.36, 1). Expanded content mounts at its natural height and preserves the disclosure's reading anchor. Reduced motion keeps a static bloom and tool progress marker, disables shimmer and arrow rotation, and retains elapsed-time updates. Appearance changes apply immediately without a whole-page color crossfade.

Live user messages and the first nonempty assistant reply fade in and settle upward by at most 6dp over 160ms. Fresh permission cards use the same timing with at most 4dp of travel. UI-only cues originate at the send, text, and permission event handlers and are consumed once; streaming updates do not replay them. Initial render, cached history, applied snapshots, session changes, search jumps, background events, and updates while reading older output show content directly. Scroll following remains unchanged.

A successful `done` event with exit code 0 triggers one 220ms check-stroke confirmation in the header notification. Completion and confirmed-stop notices disappear after 1.8 seconds. Idle status, recovery, stop, and failure do not imply success. Repeated terminal events for the same run do not restart the confirmation. Copy icons crossfade in a fixed slot over 150ms only after the clipboard write succeeds; repeated copies reset the existing feedback timer, and clipboard failures show a retry message. Reduced motion presents final states immediately. These effects add no animation dependency or persisted message fields.

Validate both palettes, system appearance changes, saved appearance restoration, inline detail updates, cached Markdown colors, and draft/session preservation. Check short screens and enlarged text. Android system bars follow the active appearance.

Device acceptance must check keyboard transitions, scrolling, and permission decisions on a real device. Widget tests and browser previews do not prove native gesture behavior.
