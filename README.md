# Codename Engine Re-Encryption

![Animated-Banner](https://github.com/user-attachments/assets/5830221d-d954-4be3-afe8-caae364a5881)

**Codename Engine Re-Encryption** (short: **CNE Re-Encryption**) is a fork of
[Codename Engine](https://github.com/CodenameCrew/CodenameEngine) that adds **content protection**
on top of the engine: encrypted mod packs, password protected zips and protected scripts, all
produced and unpacked by an in-game tool.

It is a *sub engine* of Codename Engine, not a replacement for it. Everything the upstream engine
can do, this fork can do; the only differences are the additions listed below.

```text
upstream baseline   112aa91   clean Codename Engine 1.1.0
working branch      migration/crypto-1.1.0
```

> [!NOTE]
> **中文速览** —— 本仓库是 Codename Engine 1.1.0 的加密分支：给 mod 包（zip）和脚本（.hx）加静态保护，
> 打包/解包在游戏内的 *Encryption Tool* 编辑器里完成。功能说明与安全边界见
> [docs/RE-ENCRYPTION.md](docs/RE-ENCRYPTION.md)，协作规则见 [AGENTS.md](AGENTS.md)。

---

## What this fork adds

| Area | What it does | Main code |
| --- | --- | --- |
| **Encrypted mod packs (CNEZ)** | Seals a `.zip` mod into a container only this engine can open: ChaCha20 ciphertext plus a random salt/nonce and an HMAC-SHA256 tag, so tampering is detected. | `source/funkin/backend/assets/ModPackCrypto.hx` |
| **Password protected zips** | Reads zips that other tools encrypted: classic ZipCrypto (`.zip` password) and WinZip AES-128/192/256 (7-Zip, WinRAR, Bandizip). The engine decrypts a copy into a hidden cache, so the pack loads like a plain zip. | `ZipPassword.hx`, `ZipAes.hx` |
| **Protected scripts (`.hxb` / CNX2)** | One of two protection modes per script — ChaCha20 key encryption + HMAC tag (source recoverable), or compilation to a bytecode VM with a per-file random opcode permutation (source discarded) — plus two optional stackable byte layers: a random bit rotation and a shuffle/split with padding. Only the VM mode is lossy, so any mix of the other layers stays reversible, while key + VM is what used to embed a source fallback. The engine keeps loading them by name, and `.hx` can be deleted once protected. | `source/funkin/backend/scripting/bytecode/*`, `scripting/crypto/*` |
| **Encryption Tool editor** | Editor-picker entry (`F7` menu) with *Mod Pack* / *Scripts* / *Help* tabs: seal or unwrap a pack, protect scripts, export an AES zip other tools can open, and turn keys into shareable tokens. | `source/funkin/editors/EncryptionEditor.hx` |
| **Key prompt & key tokens** | A sealed pack asks for its key before the mod loads (or a `CNEK1-...` token that resolves back to the key), and can fall back to playing without mods. | `ModPackKeyState.hx`, `scripting/crypto/ScriptCrypto.hx` |
| **Memory hygiene** | Secrets are kept wrapped in a per-session ChaCha20 stream and wiped when no longer needed; raises the bar against memory scanners, nothing more. | `backend/system/MemoryGuard.hx` |
| **Quality of life** | Loading screens for song assets and character frames, tile wipe-in transition, crash mascot, the fork's own name/version on the main menu. | `menus/SongLoadingScreen.hx`, `MusicBeatTransition.hx`, ... |

> [!WARNING]
> This is **static protection, not runtime protection**. The engine has to decrypt a pack to load
> it, so the contents are readable in the cache folder while the game runs, and the built-in
> default key is compiled into the executable. Read [docs/RE-ENCRYPTION.md](docs/RE-ENCRYPTION.md)
> before shipping anything that must stay secret — it lists exactly what is and is not covered.

---

## Documentation map

| File | Content | Origin |
| --- | --- | --- |
| [docs/RE-ENCRYPTION.md](docs/RE-ENCRYPTION.md) | How the encryption works: container formats, script layers, keys and tokens, editor usage, security boundaries | **This fork** |
| [AGENTS.md](AGENTS.md) | Collaboration rules, file-change checklist, build notes | **This fork** |
| [FEATURES.md](FEATURES.md) | Full feature list of the engine | Upstream |
| [CHANGELOG.md](CHANGELOG.md) | Upstream v0.4.0 changelog | Upstream |
| [PATCHNOTES.md](PATCHNOTES.md) | Upstream "Charter Update" patch notes | Upstream |
| [building/README.md](building/README.md) | How to compile the engine | Upstream |

The three upstream documents are kept unmodified as a reference for what the base engine contains;
they do not describe this fork's additions.

---

## Building

Requirements and library setup are described in [building/README.md](building/README.md).
On Windows, with Haxe 4.3.7 in `PATH` and the game closed:

```powershell
haxelib run lime build windows -nocolor
```

The result is `export/release/windows/bin/CodenameEngine.exe`. Only a clean compile is verified by
the maintainer; in-game behaviour is tested manually.

A one-click alternative lives in [`Build.bat`](Build.bat) (repository root): it finds or downloads
Haxe + Neko, checks the vendored `.haxelib` libraries and the lime native library, checks MSVC,
builds, and reports the result. Details: [`tools/lazy-build/README.md`](tools/lazy-build/README.md).

---

## Upstream

Codename Engine is a cross platform [Friday Night Funkin'](https://github.com/FunkinCrew/Funkin)
engine aimed at simplifying modding, focusing on softcoding, extensibility and ease of use. It uses
[HaxeFlixel](https://haxeflixel.com/) and its own fork of [hscript](https://github.com/CodenameCrew/hscript-improved).
The official engine, wiki, downloads and community links live at
[codename-engine.com](https://codename-engine.com/) and
[github.com/CodenameCrew/CodenameEngine](https://github.com/CodenameCrew/CodenameEngine).

<details>
  <summary><h2>Usage Info (inherited from Codename Engine)</h2></summary>

  This project is a fork of Codename Engine and remains bound by the upstream usage rules.

  ### Feel free to:
  - Download and play the engine with its mods and modpacks
  - Mod and fork the engine (without using it for illicit purposes)
  - Contribute to the engine (for example through *Pull Requests*, *Issues*, etc.)
  - Create a sub engine with Codename Engine as **TEMPLATE** with **CREDITS** (for example leaving the *credits menu submenu with the GitHub contributors* and putting the *[main devs](https://github.com/CodenameCrew)* in a *README* specifying that it's a *sub engine from Codename Engine*)
  - Release excutable mods that use Codename Engine as source (specifing that uses Codename Engine by for example the same way written above this)
  - Release Codename Engine modpacks

  ### Please do not:
  - Create a *side/new/etc* engine (or mod that doesn't use Codename Engine) using Codename Engine's code
  - Steal code from Codename Engine for another different project that is not Codename Engine related (Codename Engine mods excluded) without properly crediting
  - Release the entirety of Codename Engine on platforms (mods that use Codename Engine as source are fine)

  #### *If you need more info or feel like asking to do something which is not listed here, ask the Codename Crew directly on their [discord server](https://discord.gg/codename-crew)!*
</details>

<details>
  <summary><h2>Credits</h2></summary>

  ### Codename Engine (upstream)
  - All main Credits can be seen inside the Engine and specifically [HERE](https://github.com/CodenameCrew/CodenameEngine/graphs/contributors)
  - Credits to the [FlxAnimate](https://github.com/Dot-Stuff/flxanimate) team for the Animate Atlas support
  - Credits to Smokey555 for the backup Animate Atlas to spritesheet code
  - Credits to MAJigsaw77 for [hxvlc](https://github.com/MAJigsaw77/hxvlc) (video cutscene/mp4 support) and [hxdiscord_rpc](https://github.com/MAJigsaw77/hxdiscord_rpc) (discord rpc integration)
  - Credits to [TheoDev](https://github.com/TheoDevelops) for [FunkinModchart](https://lib.haxe.org/p/funkin-modchart/). ***(library used for modcharting features)***
  - Credits to [Ninjamuffin99](https://github.com/ninjamuffin99) and the [Funkin Crew](https://github.com/FunkinCrew) for the base game Friday Night Funkin'

  ### Re-Encryption additions (this fork)
  - Mod pack container, zip password/AES readers and the protected script container, bytecode VM
    and encryption tool are additions of this fork.
  - Cryptography is implemented in plain Haxe in `source/funkin/backend/scripting/crypto/`
    (ChaCha20, AES, SHA-1/SHA-256, HMAC, PBKDF2) and is **not** audited. See
    [docs/RE-ENCRYPTION.md](docs/RE-ENCRYPTION.md).
</details>
