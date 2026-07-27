# icanscriptsounds

A personal collection of scripts for [REAPER](https://www.reaper.fm/), distributed through [ReaPack](https://reapack.com/).

## Install with ReaPack

1. In REAPER, open `Extensions > ReaPack > Import repositories...`.
2. Paste this URL:

   ```text
   https://raw.githubusercontent.com/lsooxlla8/icanscriptsounds/main/index.xml
   ```

3. Synchronize packages.
4. Open `Extensions > ReaPack > Browse packages...`.
5. Find and install the desired script.

Installed scripts are registered in REAPER's Action List.

## Packages

### Freeze Toggle

Toggles every selected track independently:

- unfrozen track → freeze to stereo;
- frozen track → unfreeze one freeze layer.

The script preserves the original track selection and safely handles mixed selections containing both frozen and unfrozen tracks.
