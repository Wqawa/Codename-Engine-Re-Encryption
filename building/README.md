> **Upstream document, kept unmodified.** Everything below is Codename Engine's original build
> guide, reproduced verbatim. This fork adds a one-click Windows entry point *(added by the fork,
> not upstream)*: double-click [`Build.bat`](Build.bat) in this folder, or read
> [`lazy-build.md`](lazy-build.md). It finds or downloads Haxe + Neko, verifies the vendored
> `.haxelib` libraries and `lime.ndll`, checks MSVC, builds, and reports the result — the manual
> steps in the guide below still work exactly as described.
>
> **Second fork note (not upstream):** this fork is developed and tested on Windows only, so the
> unix helper scripts (`cne-unix.sh`, `setup-unix.sh`, `generate-docs-unix.sh`) were removed.
> The Linux/macOS instructions below still reference `setup-unix.sh`; that file no longer exists
> here, so install the libraries listed in [`libs.xml`](libs.xml) with `haxelib` by hand instead.
> Restore the scripts with `git checkout 012a6423 -- building/*.sh` if you need them.
>
> **Third fork note (not upstream):** `setup-windows.bat` and `cne-windows.bat` were removed as
> separate files too — [`Build.bat`](Build.bat) does both jobs. Run `Build.bat` to install the
> libraries and compile, or `Build.bat <command>` (`setup`, `test`, `run`, `release`, `optimize`,
> `help`) to reach the engine command line the old `cne-windows.bat` forwarded to. Restore them with
> `git checkout baseline/upstream-1.1.0 -- building/setup-windows.bat building/cne-windows.bat`.

# Compiling Codename Engine
Do you want to turn your source code into a playable build to play? Then you want to **compile the source code**, follow this guide.
> **Open the instructions for your platform.**
<details>
    <summary>Windows</summary>

1. Install [version 4.3.7 of Haxe](https://haxe.org/download/version/4.3.7/).
2. Download and install [`git-scm`](https://git-scm.com/download/win).
    - Leave all installation options as default.
3. Run `setup-windows.bat` using cmd or double-clicking it and wait for the libraries to install.
4. Once the libraries are installed, run `haxelib run lime test windows` to compile and launch the game (may take a long time)
    - ℹ You can run `haxelib run lime setup` to make the lime command global, allowing you to execute `lime test windows` directly.
</details>
<details>
    <summary>Linux</summary>

1. Install [version 4.3.7 of Haxe](https://haxe.org/download/version/4.3.7/).
2. Install `libvlc` if not present already.
    - ℹ On certain Arch based distros installing `vlc-plugins-all` might solve if `libvlc` alone doesn't work.
3. Install `g++`, if not present already.
4. Download and install [`git-scm`](https://git-scm.com/download/linux) if not present already.
5. Run `setup-unix.sh` using the terminal or double-clicking it and wait for the libraries to install.
6. Once the libraries are installed, run `haxelib run lime test linux` to compile and launch the game (may take a long time)
    - ℹ You can run `haxelib run lime setup` to make the lime command global, allowing you to execute `lime test linux` directly.
</details>
<details>
    <summary>MacOS</summary>

1. Install [version 4.3.7 of Haxe](https://haxe.org/download/version/4.3.7/).
2. Install `Xcode` to allow C++ app building.
3. Download and install [`git-scm`](https://git-scm.com/download/mac).
4. Run `setup-unix.sh` using the terminal and wait for the libraries to install.
5. Once the libraries are installed, run `haxelib run lime test mac` to compile and launch the game (may take a long time)
    - ℹ You can run `haxelib run lime setup` to make the lime command global, allowing you to execute `lime test mac` directly.
</details>

> [!TIP]
> You can also run `./cne-windows.bat -help` or `./cne-unix.sh -help` (depending on your platform) to check out more useful commands!<br>
> For example `./cne-windows test` or `./cne-unix.sh test` builds the game and uses the source assets folder instead of the export one for easier development (although you can still use `lime test` normally).
> - If you're running the terminal from the project's main folder, use instead `./building/cne-windows.bat -COMMAND HERE` or `./building/cne-unix.sh -COMMAND HERE` depending on your platform.

# Generating Codename Engine's API documentation
**Mainly recommended if you intend to fork the engine and make your own custom version to publish.**<br>Do you want to generate an API documentation so people can understand and mod your playable build? This documentation can be uploaded to your website.<br>If you just want to compile the engine normally for your hardcoded mod or for yourself you can skip this step.
> **Select your platform to continue.**
<details>
    <summary>Windows</summary>

1. Run `generate-docs-windows.bat` using cmd or double-clicking it and wait for the `doc.xml` to be generated inside the `docs` folder.
</details>
<details>
    <summary>MacOS/Linux</summary>

1. Run `generate-docs-unix.sh` using the terminal or double-clicking it and wait for the `doc.xml` to be generated inside the `docs` folder.
</details>

2. You can use this `doc.xml` file to generate a full HTML documentation (that you can open in your browser for example) using Haxe's [dox](https://github.com/HaxeFoundation/dox) generator; check [Codename Engine's webiste](https://github.com/CodenameCrew/codename-website/tree/main/api-generator) for example.

> [!CAUTION]
> The doc.xml might contain some sensible paths of your computer: make sure to filter the file before publishing it for everyone if you want to keep those paths private!<br>To filter and delete those paths, you may use Codename Engine's website's [doc filter Python script](https://github.com/CodenameCrew/codename-website/blob/main/api-generator/api/filter.py) by simply running it in the same folder of your `doc.xml` file. This script will also delete everything irrelevant to the engine that was generated in your documentation, such as libraries' (like OpenFL or Flixel) APIs.