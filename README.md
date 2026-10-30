# Downstroke

A macOS menu bar app that plays mechanical-keyboard sounds as you type. Work in progress.

## Credits

Sound packs and licence notices live in `LICENSES/`: Switchcraft (MIT), Mechvibes (MIT), kbsim (MIT), olvvier/apple-silicon-accelerometer (MIT) and freesound CC0 recordings by humi74 and bonesawmgraw.

## Build

```bash
scripts/vendor-packs.sh   # refresh the vendored sound packs
scripts/test.sh
scripts/bundle.sh --debug # builds and signs build/Downstroke.app
```

See `docs/signing.md` for the signing identity.
