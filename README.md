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

### Smart Freeze Toggle

Measures the post-FX response at the actual end of each selected track's
material, including material feeding it through receives or folder routing,
before freezing:

- audio tracks are tested with a temporary 10 ms broadband-noise burst;
- instrument tracks are detected automatically and tested with a short MIDI
  note;
- one second of safety is added after the measured response;
- a track is left unfrozen, with a warning, if its response needs more than
  five seconds or never reaches silence.

The script renders only the short diagnostic window, then removes the test
signal, temporary stem, and rendered measurement file before REAPER's native
stereo freeze runs. Running the script on an already frozen track invokes
REAPER's native unfreeze action. The script requires the
[SWS/S&M extension](https://www.sws-extension.org/) so it can temporarily
change the freeze-tail preference and restore the user's original value.
