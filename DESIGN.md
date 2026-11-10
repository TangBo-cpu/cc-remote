# CC Remote design system

CC Remote is a mobile console for supervising desktop Claude Code and Codex sessions. The transcript, current task state, and permission decisions take priority over decoration.

## Appearance

The app provides two palettes: light and dark. Settings offers Follow system, Light, and Dark; Follow system is the default. An explicit choice is stored locally and restored on launch. Switching appearance preserves the current session, draft, transcript position, and open settings page.

Pages and transcript text use the active light or dark palette. The stationary page backdrop combines a vertical gradient with broad blue and violet glows. Chat navigation capsules and the composer use translucent glass with a fading top rim and shadows painted only outside the shape. Old background preferences are ignored.

## Colors

`AppPalette.of(context)` selects semantic colors from the active Flutter theme. Components read these roles instead of choosing raw palette values. `AppColors` remains a light-palette compatibility facade for static style defaults and existing callers.

| Role | Light | Dark |
| --- | --- | --- |
| Page base | `#F2F5FC` | `#1C1F28` |
| Session sidebar | `#F5F6F8` | `#1C1F28` |
| Current session | `#FFFFFF` | `#30343D` |
| Background top / bottom | `#EBF1FE` / `#F6F7FC` | `#1D222C` / `#1B1C23` |
| Surface | `#FBFCFF` | `#252A34` |
| Control | `#E9EDF5` | `#303641` |
| User bubble | `#E5EBF5` | `#2C3545` |
| Primary text | `#202020` | `#EEEEEE` |
| Secondary text | `#626262` | `#B0B0B0` |
| Primary action / focus | `#303030` | `#E7E7E7` |
| Selection surface | `#EAEAEA` | `#343434` |
| Link text | `#2E6A9B` | `#87B7DB` |
| Success feedback | `#4C7D63` | `#91B19E` |
| Session navigation cue | `#3877A7` | `#87B7DB` |
| Error / destructive action | `#B42318` | `#FF8A80` |
| Warning | `#8A5A20` | `#EAB86A` |
| Divider | `#DDE3EE` | `#3B4352` |

Primary actions use charcoal in light mode and near-white in dark mode. Links use their own text role with a thin underline. Selection uses neutral surfaces and font weight. Pictorial icons use the existing Noto color artwork. Chat navigation and plus symbols use blue line artwork; the effort gauge uses the same blue, and the permission shield uses green or danger red. Explicit status colors and filled-button foregrounds retain line artwork in chat. Disabled controls remain dimmed. Filled buttons use `onCta` or `onStop`. Brand marks retain their artwork. Errors and warnings accompany a label or icon.

Body text and action labels require at least 4.5:1 contrast against their actual background. Disabled controls use their disabled role. Photos and camera content retain their own content colors.

The session sidebar and its create/project flows use the installed Phosphor Regular line icons. Navigation glyphs are 24 points, paired with 17-point labels; menu glyphs are 20 points. Neutral icons use the secondary content color; running and permission cues retain semantic colors. On the light sidebar, primary and secondary text contrast is 15.1:1 and 5.6:1. On the dark sidebar, it is 14.2:1 and 7.6:1.

## Layout and typography

Keep the existing navigation and chat layout. Separate groups with spacing and alignment before adding borders or surfaces. Avoid nested decorative cards.

Use the platform UI font for interface and transcript text, and a monospace font for code, paths, and commands. Preserve reading-size settings and system text scaling. Text must wrap or scroll within its viewport without hiding controls.

Spacing follows 4, 8, 12, 16, 20, 24, and 32 points. Reuse the shared radius and touch-target constants. Compact visible icons retain an accessible touch target.

Chat glass uses a soft 24-point shadow offset by 8 points and a 3-point contact shadow offset by 1 point. Both are clipped outside the shape. The surface has a half-point hairline and a top highlight that fades by 45% of its height. Background blur uses sigma 18 with a small saturation gain; scrolling and high contrast disable blur and make the fill opaque without remounting controls. The bottom veil repaints the same full-page background coordinates as the page so keyboard resizing does not create a color seam.

Other surfaces that float above the page carry a three-layer shadow: a tight contact
edge, a directed blur, and a wide ambient wash. Sheets and dialogs share
`AppElevation.overlay`; cards use `AppElevation.softCard`. Negative spread
keeps the wide layer from smearing past the surface, and every layer stays
below 0.1 alpha. The full-width header backdrop casts no shadow: a clipped backdrop blur
carries a soft gradient fade, so scrolling text passes into haze instead of
under a painted band. Transcript content carries no shadow either: user
bubbles, assistant replies, reasoning, and tool groups stay flat so the
reading column keeps one plane.

## Components

- The header contains project/session navigation, a compact center notification, new conversation, and more actions. Its center stays between the side controls without overlap and can grow with system text scaling. The transcript scrolls behind it up to the screen's top edge. A clipped backdrop blur fades out below the controls and passes through touch events; controls remain inside the system safe area. Initial transcript padding follows the measured navigation and permission-status height. Search targets stop below that overlay.
- The session sidebar uses a solid light-gray surface (`#F5F6F8`) in light mode and the page surface in dark mode. It slides in from the left, leaving a dimmed chat strip with 28-point left corners; the area outside those corners continues the sidebar background. The header shows CC Remote and an overflow menu for engine filtering, archived sessions, and closing the sidebar. Plain icon-and-text rows open search, project selection, and desktop session sync. The list initially shows the active project, with pinned sessions first and recent sessions below, without folder nesting or duplicate entries. Selecting all projects adds a muted project name beneath each title. Search opens on demand, retains title-and-message matching and independent filters, and restores list position when closed. Rows use 17-point titles and a 52-point minimum height. The current session uses a white surface in light mode, a neutral raised surface in dark mode, a half-point edge, and a faint contact shadow. High contrast adds a one-point text-color outline. Running and permission cues stay compact. Long press, secondary click, and accessibility actions open the existing session menu; the current row also shows a visible menu button. Touch targets remain at least 48 points. The bottom-right new-session capsule opens the existing project/engine confirmation sheet. Busy-state restrictions, mutation errors, and separate archived history remain available. The persistent wide-screen rail shares this layout.
- The composer uses 28-point continuous corners and the same glass as the header capsules. Focus adds an accent outline. Its bottom edge becomes square and loses elevation when the keyboard is visible. Tools are flat at rest, with a subtle fill on press; functional glyphs are 20 points and model marks are 21 points. Attachment, effort, model, and permission controls stay visible in their existing order with 48-point touch targets. The effort gauge retains its selected-level feedback. Permission uses a shield, with a danger shield and semantic color for unrestricted access. Send, queue, stop, and disabled behavior are preserved.
- Assistant replies sit directly on the page without a bubble fill or outline. User messages use a muted blue-gray bubble with 22-point corners and no border or shadow. Search matches retain their temporary highlight. File cards use a faint outline and a separate neutral icon seat. Markdown headings, links, tables, and code update when appearance changes.
- A turn keeps intermediate narration, reasoning, and tools in message order on the page. Process history has no card fill or outline and is expanded by default. A lightweight tool-group heading can fold the history; live thinking stays outside that disclosure so its animation remains visible. User and system-message boundaries remain separate, and search opens the group and tool detail containing its target.
- Process headings share the reply's leading edge. A process group sits directly above its final reply without an extra list gap or reply top inset. Headings retain a minimum 48-point touch target; expanded details stay in message order.
- Reasoning shows a fixed-center bloom animation and “思考中” with elapsed time while running. Completed reasoning shows a brain icon and “已深度思考”. Selectable Markdown is visible by default with a 1-point start border and natural content height. Its headings, lists, code, and body use the 13-point process-text size, below the 15-point reply body, and respect system text scaling. Tapping the title folds the content in place. Empty completed reasoning is hidden. Timer labels describe elapsed run time.
- Tool groups use text rows and colored tool icons with separate running, error, and stop cues. Short details remain fully visible; long details show a three-line preview with an explicit inline expand/collapse action. Manually expanded details stay expanded across updates, and search targets reveal the full detail. Tapping a step folds its detail in place, without opening another page or sheet or adding an inner scrolling panel. Commands use selectable 13-point monospace text when fully shown and wrap to the viewport. File paths retain workspace links. When the group is manually folded during a run, the latest two steps remain visible. Skill rows retain their name badge. Cached and remote history remain available, and permission requests retain explicit allow/deny actions.
- Tool-detail interaction references: [Happy's compact mobile tool rows](https://github.com/slopus/happy/blob/ee1eb59039c0898c248855b1e1d38749008b863c/packages/happy-app/sources/components/tools/ToolView.tsx) and [assistant-ui's bounded terminal disclosure](https://github.com/assistant-ui/tool-ui/blob/49a870286facdbf28160cd647f0d337ebdc9b275/apps/www/components/tool-ui/terminal/terminal.tsx). These interaction patterns are adapted to the existing Flutter layout, not imported as components.
- Menus, model pickers, settings, and the workspace use the same palette and shared glass material. Sheets separate from the page through their surface and scrim.
- Sheets, dialogs, and settings share 28-point continuous corners, a fine top rim, and the chat glass's external shadows. Model and access-mode pickers retain one blurred panel; larger settings surfaces and dialogs use opaque fills. High contrast removes translucency. Option rows share 16-point corners, a 32-point icon column, 15-point titles, 12-point descriptions, and a minimum 48-point touch target. Selection uses a flat neutral fill and a blue check; danger and disabled states retain their labels and semantic flags. Attachment, project, directory, and native-session lists use the same row component. Settings groups remain flat inside the modal.
- Connection, completion, stop, and failure notices share one icon-and-text slot in the header and remain visible with the keyboard open. Recovery and failure notices open scrollable details with the full selectable error and existing recovery actions; unresolved states stay visible until resolved or explicitly dismissed. Detail sheets close when their session state changes. Notifications and recovery actions retain 48-point touch targets. Permission decisions keep their existing presentation.
- Transcript errors use a full-width, left-aligned neutral card with an error icon, title, at most two summary lines, and a details action. Long logs stay in a bounded, scrollable, selectable monospace region in the shared failure details. Display and copy remove terminal formatting and mask common credentials without changing stored messages. Dismissing the header notice keeps the historical error card; no action retries a command automatically.
- Startup shows the app name and the current initialization phase on the page background.

## Motion and validation

Model and access-mode pickers expand from their own composer button over 320ms with ease-out cubic and contract over 160ms. Only the painted geometry changes; the option list retains its layout. Moving snapshots cap raster density at 2x while their child retains the real device metrics; settled content returns to live rendering at full device resolution. Pickers use opaque fills during movement, then restore blur and a stronger 94% fill so transcript text does not show through the catalogue. Callers without a compact trigger use a bottom-origin entrance. The modal retains barrier dismissal, Escape/back, closed-loop keyboard traversal, and focus restoration. Reduced motion presents the final geometry immediately. Permission confirmations and stored selections retain their existing rules.

Running titles use a 2-second linear text shimmer. The thinking bloom expands and contracts through fixed-center frames over 3 seconds. Active tool titles remain visible for at least 1.2 seconds, with later updates replacing pending titles. Adjacent chevrons rotate over 200ms using Cubic(0.22, 1, 0.36, 1). Expanded content mounts at its natural height and preserves the disclosure's reading anchor. Reduced motion keeps a static bloom and tool progress marker, disables shimmer and arrow rotation, and retains elapsed-time updates. Appearance changes apply immediately without a whole-page color crossfade.

Live user messages and the first nonempty assistant reply fade in and settle upward by at most 6dp over 160ms. Fresh permission cards use the same timing with at most 4dp of travel. UI-only cues originate at the send, text, and permission event handlers and are consumed once; streaming updates do not replay them. Initial render, cached history, applied snapshots, session changes, search jumps, background events, and updates while reading older output show content directly. Scroll following remains unchanged.

A successful `done` event with exit code 0 triggers one 220ms check-stroke confirmation in the header notification. Completion and confirmed-stop notices disappear after 1.8 seconds. Idle status, recovery, stop, and failure do not imply success. Repeated terminal events for the same run do not restart the confirmation. Copy icons crossfade in a fixed slot over 150ms only after the clipboard write succeeds; repeated copies reset the existing feedback timer, and clipboard failures show a retry message. Reduced motion presents final states immediately. These effects add no animation dependency or persisted message fields.

Validate both palettes, system appearance changes, saved appearance restoration, inline detail updates, cached Markdown colors, and draft/session preservation. Check short screens and enlarged text. Android system bars follow the active appearance.

Device acceptance must check keyboard transitions, scrolling, and permission decisions on a real device. Widget tests and browser previews do not prove native gesture behavior.

The chat material direction references [dsh-Go's surface parameters](https://github.com/ccch1mneyyy/dsh-Go/blob/aee64450219e21c5d16b127f5f01350697de05da/app/lib/ui/theme/surfaces.dart) and [glass layering](https://github.com/ccch1mneyyy/dsh-Go/blob/aee64450219e21c5d16b127f5f01350697de05da/app/lib/ui/theme/glass.dart). CC Remote implements the material locally with its existing state and accessibility behavior.
