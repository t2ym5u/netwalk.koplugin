# Changelog

All notable changes to this project will be documented in this file.

## [1.1.2] - 2026-11-04

### Fixed
- A game no longer crashes when an outdated plugin is installed alongside:
  shared modules left behind by an older plugin are replaced by this
  plugin's own copy instead of being used as they are.

## [1.1.1] - 2026-11-04

### Changed
- Uses less memory: the game loads when you open it, not when KOReader
  starts, so it no longer takes memory or startup time while unplayed.

## [1.1.0] - 2026-11-04

### Changed
- Faster puzzle generation, same puzzles: each candidate network is rated
  one reasoning level after the other instead of from scratch, and the
  local-rule pass is quicker. Hard went from up to 55-75 ms on a desktop
  (about 2 s on a Kobo) to roughly a third of that.
- A progress bar appears if Hard takes more than a moment to generate.

## [1.0.3] - 2026-11-03

### Changed
- Picks up game-common 1.11.0: the shared on-screen keyboard (where used)
  gives every key the same letter size, and the no-repeat history helper.

## [1.0.2] - 2026-11-02

### Changed
- Picks up game-common 1.10.0: the shared Tools → Games menu also lists
  the games' new "· multiplayer" entries under Party & quiz.

## [1.0.1] - 2026-11-02

### Changed
- Listed under **Tools → Games**, grouped by category, instead of its own
  entry in the Tools menu (game-common 1.9.1).

## [1.0.0] - 2026-10-30

### Added
- First release: Net (NetWalk) on 5×5 to 11×11 grids, without wrapping.
- Generator grows a random spanning tree from the central source and keeps
  only puzzles its deductive solver cracks at the chosen difficulty, which
  also proves the solution unique.
- Tap to turn a tile (clockwise or counter-clockwise, set in the menu),
  long-press to lock it. Powered pipes drawn solid, unpowered ones hollow.
- Hint, Undo, Restart, Show solution, move counter, timer, best time,
  auto-save. French translation.
