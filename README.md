# Equalizer for NADI

A [NADI](https://github.com/Llyme/not-another-dynamic-island) plugin for [Equalizer APO](https://sourceforge.net/projects/equalizerapo/): the equalizer on your screen's
edge.

- **At hand:** its widget shows the preamp; the mouse wheel over it turns the preamp. A click opens a small panel with the preamp, the
  on/off switch, and Reset (back to the preset as saved) when something changed. Pop it out (its widget's menu) for the whole equalizer.
- **One page:** the preset at its top (pressed: every preset), undo, redo and save; the curve; the band picked under it (its type, its
  frequency, gain and Q, typed); the preamp and Clip Guard; flatten, expand, compress, which channels, even bands, speakers and device.
- **Bands:** as many as you like, anywhere from 10 Hz to 22 kHz, each a peak, low or high shelf, low or high pass, band pass, notch or
  all pass. Drag a point on the curve (across: frequency; up and down: gain), turn the wheel over it for its Q, double-click the curve to
  add one.
- **Speakers:** each speaker's volume and delay, mono, swapped or one-sided mixing, and the balance.
- **Presets:** its own. The first time, what Equalizer APO plays then is kept as "Now", beside "Flat". Changes are heard at once but kept
  apart from the preset until you save them; undo and redo step through them.

## On and off

Equalizer APO reads plain text files and applies a change as soon as one is saved. On, the plugin writes its own file, `nadi-eq.txt`,
into Equalizer APO's config folder, and points `config.txt` at it in place of what it included before. Off, `config.txt` names what it
named before again, so another app (or Equalizer APO's own editor) has it as it was. Other apps' files are only ever read. A copy of
`config.txt` as it was before is kept in the plugin's data folder (`%APPDATA%\NADI\plugin-data\apo-equalizer\config.before.txt`).

The plugin itself (Luau) runs in NADI's sandbox; its helper (`bin/apo-helper.exe`, built from `helper/`) does what the sandbox cannot:
reading and writing those files and listing the playback devices.

## Building

```powershell
./build.ps1
```

Builds the helper (Rust), runs the tests (with `nadi-plugin` on the PATH) and makes `nadi-plugins.tar.gz`, the file a release carries for
NADI to install.

## License

GPL-3.0. See [LICENSE](LICENSE).
