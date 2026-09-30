# Vendored third-party files

| File | Project | License |
| --- | --- | --- |
| `v86/libv86.js`, `v86/v86.wasm` | [v86](https://github.com/copy/v86) 0.5.462 (npm package `v86`) | BSD-2-Clause (`v86/LICENSE`) |
| `bios/seabios.bin` | [SeaBIOS](https://www.seabios.org/), build from the v86 repository (`bios/`) | LGPL-3.0 |
| `bios/vgabios.bin` | VGA BIOS from the v86 repository (`bios/`) | LGPL-2.1 |

To update v86:

```sh
npm pack v86 && tar xzf v86-*.tgz
cp package/build/libv86.js package/build/v86.wasm package/LICENSE vendor/v86/
```
