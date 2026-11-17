# Offline checks

Run from the Sintezza_Disenchant repository with Python 3.12 and Lupa 2.6 built for Lua 5.1.

~~~powershell
python .\Tests\run.py --runtime 'D:\Games\WoW_addons\.execute-verification\.perf-verification-20261117\runtime'
~~~

The runner compiles the addon's Lua sources and exercises its actual local queue policy in an isolated environment. It covers manual and automatic selection, exclusions, blocked targets, equipment-set and level protection, price boundaries, missing prices, corrupt saved thresholds, non-equipment modes, item identity, order, and repeated builds.

For a differential check against a source snapshot, add its path.

~~~powershell
python .\Tests\run.py --runtime 'D:\Games\WoW_addons\.execute-verification\.perf-verification-20261117\runtime' --baseline 'D:\Games\WoW_addons\.execute-verification\disenchant-refactor-20261117\source-before\Sintezza_Disenchant.lua'
~~~

The Escape mock checks that Disenchant uses the game's special window list even when direct handler registration is available. It tests all standalone windows, stock dispatch when they are closed, and transitions into and out of combat and the profession page. Secure casting, bag events, addon price APIs, actual Escape dispatch, and rendering require their own checks.

The list regression runs the real row constructors, item rendering, Mark best picks handler, selection/removal handlers, panel layout and viewport refresh functions against a frame geometry mock. With 1,000 items it checks that only visible rows are allocated and priced, width resizing does no further bag scans or material estimates, both viewports share a deferred refresh, and every displayed row fits. Continuous height resizing reuses both row pools and prices only newly exposed rows. Item and material geometry stays fixed across 140 width changes, without resetting row height. Material previews have enough height for their icons, and titles fit when previews are disabled. It also covers wheel/scrollbar navigation, offscreen selection, recycled row identity and tooltips, empty/short lists, reopening, and deferred combat handling. The opening case holds viewport height at zero through Show/RefreshUI, resolves it before the queued callback, and verifies the callback still paints the list. The header restores its natural title width after leaving the profession tab. Expected output includes `List refresh: 64 assertions passed`.

The two-item selection regression runs 32 cycles through the actual row click, Mark best picks and Clear selection handlers without resizing. It observes viewport dimensions after every geometry mutation, rejects transient detachment/collapse, and verifies that an already-visible queue does not rebuild panel anchors. Viewport diagnostics are checked for populated/hidden rows and absence of scan/refresh side effects.

To run against an earlier source snapshot, pass `--list-source PATH`. The source before the selection-layout fix fails the intermediate-geometry assertion because it clears panel anchors on each click. The earlier immediate-opening version also loses a queued draw while dimensions are unresolved. Native clipping, actual game input dispatch, optional price APIs and controller navigation still require in-game checks.
