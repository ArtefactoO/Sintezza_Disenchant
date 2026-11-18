# Changelog

## 1.3.0

- Add a disenchant queue shortcut to the Blizzard backpack, combined bags, and EllesmereUI Bags.
- Restore the disenchant queue shortcut at the bottom left of Baganator's backpack.

## 1.2.0

- Add optional Sintezza Perf developer measurements for disenchant estimates.
- Keep item and queue panel anchors attached during selection changes. Reuse the existing layout while queue visibility is unchanged, and replace only the relevant anchors when it changes.
- Include viewport dimensions, row visibility and pending refresh state in `/sde check` and `/sde copy` before the diagnostic bag scan.
- Keep the first item and queue draw deferred until after window layout. Do not cancel the pending refresh while viewport dimensions are still unresolved, which could leave the list blank.
- Use WoW quality names in English and Russian instead of color names, and widen the selector for the full labels.
- Keep the main window version beside the title on the left, matching Vendor, including after returning from the profession tab.
- Stabilize item and material icons while resizing: width changes leave row heights untouched, and material previews use fixed-height text areas with matching top anchors.
- Size the item and queue lists to the available window area, reusing only visible rows. Resizing no longer rebuilds the entire bag list or recalculates material previews; scrolling, selection and queue actions keep their current item identities.
- Replace the native scroll children in the item and queue lists with fixed viewports to avoid blank lists when resizing or opening the queue.
- Use the game's window list to close standalone Disenchant windows with Escape outside combat and preserve native target clearing.
- Reuse queue protection decisions when counting items skipped only by price, avoiding repeated checks during compact queue refreshes.
- Fixed the version overlapping the statistics button in the queue window header.
- Changed the exclusions button to match Vendor and placed it first in the header.
- In compact mode, show the current item's material preview below its name and the next item in the queue underneath.
- Aligned the compact window's action and Full buttons to the same height.
- Simplified queue protection settings with a compact quality selector, smaller threshold fields and visible material preview options.
- Enlarged and cropped material icons in queue previews to remove their default borders.
- Keep excluded items visible and dimmed, with a per-item button to exclude or restore them. Excluded items cannot enter the queue.
- Replaced the queue's blacklist button with a smaller, right-aligned action button.
- Removed chat messages for exclusion changes made in the addon windows.
- Moved the Compact button next to the queue action, matched its height and show it only when the queue has items.
- Refresh the item list and its scroll range when returning from compact mode.
- Correct item and queue row anchors so their positions stay within the scroll area after resizing or reopening.

## 1.1.0

- The settings header shows the addon version.
- The disenchant queue window shows the version beside the title.
- Left-clicking the minimap icon opens or closes the window.
- Connected window scale, opacity, and layer to the shared Theme settings. The WoW AddOns settings launcher uses the shared Theme helper.
- Updated the project logo and in-game addon icon.

## 1.0.37

- Localized the fallback name for Luminous Residue, the generic mail error, and the add-on category.

## 1.0.36

- Mark profitable disenchants from the full list, using optional advice and complete fallback estimates. Sale comparisons account for the auction fee once.
- Report items blocked for disenchanting to Sintezza Vendor.

## 1.0.35

- Added themed hints for item level and price limits in queue protection.

## 1.0.34

Release baseline for WoW Forever.

- Queue items from your bags, protect gear during bulk selection, and disenchant one item per press.
- Filter for Mastercraft recommendations, estimate material value using optional price providers, and share estimates with Sintezza Vendor.
- Track session and all-time results, exchange statistics via CSV, and manage learned results.
- Open the queue from the profession window or minimap, and mail gear from the inbox shortcut.
- Updated the project documentation and recorded the MIT notice for Sintezza alongside the Disenchant Helper notice.
