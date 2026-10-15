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

## Components

- The header contains project/session navigation, new conversation, and more actions. The transcript scrolls behind it up to the screen's top edge. A clipped backdrop blur fades out below the controls and passes through touch events; controls remain inside the system safe area. Initial transcript padding follows the measured navigation, status, and recovery-panel height. Search targets stop below that overlay.
- The session navigator retains its original list spacing, colored session/project marks, blue context and selection cues, and existing search and menu behavior.
- The composer uses a 32-point corner radius, strong glass fill, and soft shadow outside the content clip. Focus adds an accent outline. Its tools have no shared filled rail; the attachment action has a light circular seat. Send and stop retain loading and disabled states.
- Assistant replies sit directly on the page without a bubble fill or outline. User messages use a neutral gray bubble without a border or shadow. Search matches retain their temporary highlight. File cards use a faint outline and a separate neutral icon seat. Markdown headings, links, tables, and code update when appearance changes.
- A turn collects intermediate narration, reasoning, and tools into one process. Reasoning and narration retain their order within the tool history. Live thinking appears outside the tool disclosure, so folding tools never hides its animation. Completed processes use a bordered card with a colored icon; tool summaries show completion, failure, or stop state and the step count. History starts folded unless manually opened during generation. User and system-message boundaries remain separate, and search opens the process containing its target.
- Reasoning shows a fixed-center bloom animation and “思考中” with elapsed time while running. Completed reasoning shows a colored brain icon and “已深度思考”. Expanding displays selectable Markdown with a 2-point start border and natural content height. Empty completed reasoning is hidden. Timer labels describe elapsed run time rather than model-reported reasoning duration.
- Tool groups use bordered cards and colored tool icons with separate running, error, and stop cues. The latest two steps remain visible during a run; expanding shows the full sequence. Skill rows retain their name badge. Selecting a tool opens a separate bottom sheet at 40% height, expandable to 80%. The sheet has a fixed title, a scrollable body, a 32-point top radius, and a maximum width of 720 points. It updates through turn completion and preserves workspace-path navigation. Cached and remote history remain available, and permission requests retain explicit allow/deny actions.
- Menus, model pickers, settings, and the workspace use the same palette and shared glass material. Sheets separate from the page through their surface and scrim.
- Inline recovery cards use a neutral control fill and primary text for reconnect actions, keeping the alert and its recovery action below the transcript in visual emphasis.
- Startup shows the app name and the current initialization phase on the page background.

## Motion and validation

Running titles use a 2-second linear text shimmer. The thinking bloom expands and contracts through fixed-center frames over 3 seconds. Active tool titles remain visible for at least 1.2 seconds, with later updates replacing pending titles. Adjacent chevrons rotate over 200ms using Cubic(0.22, 1, 0.36, 1). Expanded content mounts at its natural height and preserves the disclosure's reading anchor. Tool sheets open and snap over 250ms and close over 200ms. Reduced motion keeps a static bloom and tool progress marker, disables shimmer, arrow rotation, and sheet transitions, and retains elapsed-time updates. Sheet snapping uses 1ms because Flutter requires a positive duration. Appearance changes apply immediately without a whole-page color crossfade.

Validate both palettes, system appearance changes, saved appearance restoration, open-sheet updates, cached Markdown colors, and draft/session preservation. Check short screens and enlarged text. Android system bars follow the active appearance.

Device acceptance must check keyboard transitions, scrolling, and permission decisions on a real device. Widget tests and browser previews do not prove native gesture behavior.
