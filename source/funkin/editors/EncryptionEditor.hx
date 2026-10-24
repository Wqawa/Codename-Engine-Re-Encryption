package funkin.editors;

import flixel.math.FlxRect;
import funkin.backend.assets.ModPackCrypto;
import funkin.backend.assets.ZipAes;
import funkin.backend.assets.ZipPassword;
import funkin.backend.scripting.crypto.ScriptCrypto;
import funkin.editors.ui.*;
import funkin.editors.ui.UITopMenu.UITopMenuButton;
import funkin.menus.MainMenuState;
import haxe.io.Path;
import lime.ui.FileDialog;
import lime.ui.FileDialogFilter;
import sys.io.File;

/**
 * General purpose encryption tool, reachable from the editor picker (F7 menu).
 *
 * It wraps zip mod packs into encrypted containers (or unwraps them again) and
 * holds the key token helper that turns a key into a shareable string and back.
 * Script level encryption is not part of this tool any more.
 */
class EncryptionEditor extends UIState {
	static inline var SCROLL_STEP:Float = 64;
	static inline var TAB_Y:Float = 34;
	static inline var TAB_H:Int = 30;
	static inline var CONTENT_Y:Float = 74;

	static inline var TAB_MODPACK:Int = 0;
	static inline var TAB_HELP:Int = 1;
	static var TAB_NAMES:Array<String> = ["Mod Pack", "Help"];

	public var topMenu:UITopMenu;
	public var bg:FlxSprite;

	public var statusText:UIText;

	public var fileDialogOpen:Bool = false;
	public var lastDirectory:String = null;

	/** 0 = CNEZ container (strong), 1 = standard AES-256 password zip. */
	public var packModeStrong:UIRadioButton;
	public var packModeStandard:UIRadioButton;
	public var packModeText:UIText;
	public var currentPackMode:Int = 0;

	// pack jobs: sealing a mod pack or unwrapping one again. Both run on a worker
	// thread, so update() only reads these plain values while it writes them.
	static inline var JOB_NONE:Int = 0;
	static inline var JOB_ENCRYPT:Int = 1;
	static inline var JOB_DECRYPT:Int = 2;
	public var jobBarBg:FlxSprite;
	public var jobBar:FlxSprite;
	public var jobText:UIText;
	public var jobActive:Bool = false;
	public var jobKind:Int = JOB_NONE;
	public var jobProgress:Float = 0;
	public var jobDone:Bool = false;
	public var jobError:String = null;
	public var jobOut:String = null;
	public var jobName:String = "";
	/** 0..1 opacity of the progress row; it fades in for a job and out afterwards. */
	public var jobFade:Float = 0;
	public var jobFadeTarget:Float = 0;
	/** seconds the finished result stays readable before the row fades away. */
	public var jobHold:Float = 0;

	// tab bar: every tab owns a list of widgets that are simply hidden while
	// another tab is selected, the way the rest of the editor screens work
	public var tabs:Array<UIButton> = [];
	public var tabGroups:Array<Array<FlxSprite>> = [[], []];
	public var currentTab:Int = TAB_MODPACK;

	// key token widgets - they share the Mod Pack tab
	public var tokenKeyBox:UITextBox;
	public var tokenTokenBox:UITextBox;

	// help tab
	public var helpText:UIText;
	public var helpBar:UIScrollBar;
	public var helpScroll:Float = 0;
	public var helpHeight:Float = 0;
	/** frames left to keep re-measuring the help text while its font is still settling. */
	var helpMeasureFrames:Int = 0;
	var helpViewX:Float = 20;
	var helpViewY:Float = 100;
	var helpViewW:Float = 100;
	var helpViewH:Float = 100;

	public override function create() {
		super.create();

		FlxG.camera.fade(0xFF000000, 0.5, true, null, true);
		FlxG.mouse.useSystemCursor = FlxG.mouse.visible = true;

		add(bg = new FlxSprite().makeSolid(FlxG.width, FlxG.height, 0xFF2B2B33));
		bg.updateHitbox();
		bg.scrollFactor.set();

		add(topMenu = new UITopMenu([
			{
				label: "File",
				childs: [
					{label: "Reload Key File (script_key.txt)", onSelect: (_) -> reloadKeyFile()},
					null,
					{label: "Exit", onSelect: (_) -> exitEditor()}
				]
			},
			{
				label: "Tools",
				childs: [
					{label: "Mod Pack tab", onSelect: (_) -> showTab(TAB_MODPACK)}
				]
			},
			{
				label: "Help",
				childs: [
					{label: "About / Help", onSelect: (_) -> showTab(TAB_HELP)}
				]
			}
		]));

		buildTabs();
		buildModPackTab();
		buildHelpTab();

		add(statusText = new UIText(10, FlxG.height - 30, FlxG.width - 20, "", 14, 0xFFFFE066, false));

		showTab(TAB_MODPACK);
		status("Keys: " + ScriptCrypto.keyFileSummary() + ".");
	}

	// ------------------------------------------------------------------- tabs

	function track(group:Array<FlxSprite>, sprite:FlxSprite):FlxSprite {
		add(sprite);
		group.push(sprite);
		return sprite;
	}

	function buildTabs() {
		var x = 10.0;
		for (i in 0...TAB_NAMES.length) {
			var name = TAB_NAMES[i];
			var w = Std.int(Math.max(120, name.length * 9 + 44));
			var btn = new UIButton(x, TAB_Y, name, null, w, TAB_H);
			btn.autoAlpha = false;
			btn.callback = function() showTab(i);
			add(btn);
			tabs.push(btn);
			x += w + 8;
		}
	}

	function showTab(index:Int) {
		if (index < 0 || index >= tabGroups.length) return;
		currentTab = index;

		for (i in 0...tabGroups.length)
			for (member in tabGroups[i]) {
				member.visible = i == index;
				member.active = i == index; // 修复：同步禁用/启用交互，防止隐藏的按钮被误触
			}

		if (isEditingText()) unfocusTextBox();

		for (i in 0...tabs.length)
			tintButton(tabs[i], i == index ? 0xFFFFFFFF : 0xFF8A8A96);

		if (index == TAB_HELP) {
			// the text may only have its final height now that the tab is on screen
			helpMeasureFrames = 0;
			refreshHelpLayout(true);
			status("Help - scroll the text with the mouse wheel.");
		} else applyHelpScroll();
	}

	function tintButton(btn:UIButton, color:Int) {
		if (btn == null) return;
		btn.color = color;
		if (btn.field != null) btn.field.color = color;
	}

	function buildModPackTab() {
		var g = tabGroups[TAB_MODPACK];
		var panelH = FlxG.height - CONTENT_Y - 46;
		if (panelH < 540) panelH = 540;

		track(g, new FlxSprite(10, CONTENT_Y).makeSolid(Std.int(FlxG.width - 20), Std.int(panelH), 0xFF1B1B21));

		// key tokens exist for encrypted mod packs only, so they sit on top of the
		// pack exporter and nowhere else
		track(g, new UIText(30, CONTENT_Y + 12, FlxG.width - 60, "Key Token Tool - for encrypted mod packs", 17, 0xFFFFE066, false));
		track(g, new UIText(30, CONTENT_Y + 40, FlxG.width - 70,
			"A token (CNEK1-...) is the key rewritten as different text: hand it to players instead of the key.\n"
			+ "They paste it into the prompt that opens an encrypted mod pack.",
			12, 0xFFB0B0BE, false));

		track(g, new UIText(30, CONTENT_Y + 112, 60, "Key:", 14, 0xFFFFFFFF, false));
		track(g, tokenKeyBox = new UITextBox(94, CONTENT_Y + 108, ScriptCrypto.getPassword(), 500));
		track(g, new UIButton(610, CONTENT_Y + 108, "Make Token", onMakeToken, 180, 32));
		track(g, new UIButton(800, CONTENT_Y + 108, "Copy Key", onCopyKey, 150, 32));

		track(g, new UIText(30, CONTENT_Y + 160, 60, "Token:", 14, 0xFFFFFFFF, false));
		track(g, tokenTokenBox = new UITextBox(94, CONTENT_Y + 156, "", 500));
		track(g, new UIButton(610, CONTENT_Y + 156, "Recover Key", onRecoverKey, 180, 32));
		track(g, new UIButton(800, CONTENT_Y + 156, "Copy Token", onCopyToken, 150, 32));

		// -- the pack exporter itself
		track(g, new UIText(30, CONTENT_Y + 206, FlxG.width - 60, "Encrypt a zip mod pack", 18, 0xFFFFE066, false));

		track(g, packModeStrong = new UIRadioButton(30, CONTENT_Y + 238, "Enhanced: CNE container (CNEZ, needs the key)", true, "packModeStrong", 540));
		track(g, packModeStandard = new UIRadioButton(575, CONTENT_Y + 238, "Standard: password zip (AES-256)", false, "packModeStandard", 520));
		packModeStrong.onChecked = function(_) selectPackMode(0);
		packModeStandard.onChecked = function(_) selectPackMode(1);

		track(g, packModeText = new UIText(30, CONTENT_Y + 272, FlxG.width - 70, packModeDescription(0), 13, 0xFFC8C8D2, false));
		packModeText.wordWrap = true;

		track(g, new UIButton(30, CONTENT_Y + 430, "Choose .zip and Encrypt...", encryptModPack, 400, 40));
		track(g, new UIButton(440, CONTENT_Y + 430, "Choose encrypted .zip and Decrypt...", decryptModPack, 440, 40));

		// pack job progress, laid out like the loading screen the game shows when it
		// decrypts a pack at start up. The row is invisible until a job needs it and
		// updateJob() fades it in and out, so it never sits there as dead UI.
		track(g, jobText = new UIText(30, CONTENT_Y + 476, FlxG.width - 60, "", 13, 0xFF9BE28C, false));
		track(g, jobBarBg = new FlxSprite(30, CONTENT_Y + 496).makeGraphic(Std.int(FlxG.width - 60), 18, 0xFF2A2A34));
		track(g, jobBar = new FlxSprite(33, CONTENT_Y + 498).makeGraphic(Std.int(FlxG.width - 66), 14, 0xFF61C4FF));
		// scaling around the left edge keeps the bar growing to the right
		jobBar.origin.set(0, 0);
		jobBar.scale.x = 0.001;
		jobText.alpha = jobBarBg.alpha = jobBar.alpha = 0;
		jobBarBg.visible = jobBar.visible = false;
	}

	static var HELP_BODY:String =
		"WHAT THIS TOOL DOES\n\n"
		+ "The Mod Pack tab seals a zip mod into a CNEZ container or an AES-256 password zip, unwraps\n"
		+ "either one into a plain zip again, and turns keys into shareable tokens.\n"
		+ "\n"
		+ "keys\n"
		+ "\n"
		+ "The key is whatever sits in the Key field of the token tool. Empty means: the key\n"
		+ "script_key.txt (next to the executable or in the mod folder) has for that pack name, or the\n"
		+ "built-in engine key. A custom key must also be in script_key.txt, or the engine cannot open\n"
		+ "the pack again. File > Reload Key File re-reads it without a restart. script_key.txt holds\n"
		+ "either one key on its first line, or one \"name = key\" per line, where name is a file name,\n"
		+ "a name without extension, a mod relative path, or * as fallback; # and // start a comment.\n"
		+ "\n"
		+ "key tokens: a token (CNEK1-...) is the key rewritten as different text. Players paste it\n"
		+ "into the prompt that opens an encrypted zip mod. Copy Key / Copy Token put either one on\n"
		+ "the clipboard.\n"
		+ "\n"
		+ "mod pack formats\n"
		+ "\n"
		+ "  CNEZ container: only the engine can open it, the key is required.\n"
		+ "  AES-256 zip: 7-Zip, WinRAR and Bandizip open it with the password, and so does the\n"
		+ "  engine, so players only type the password once.\n"
		+ "\n"
		+ "Encrypting and decrypting both run in the background with a progress bar and write a new\n"
		+ "file next to the source: name_encrypted.zip, name_password.zip or name_decrypted.zip.\n"
		+ "Plain zips load as before; password zips from other tools load too (ZipCrypto, AES-128/192/\n"
		+ "256) - the password is asked at startup and the readable copy stays in the hidden\n"
		+ ".CNE_mods folder, which is deleted when the game closes.\n"
		+ "\n"
		+ "tips: while a text field is focused Backspace edits it and ESC only drops the focus, ESC\n"
		+ "again leaves the editor. The mouse wheel scrolls this page.\n";

	function buildHelpTab() {
		var g = tabGroups[TAB_HELP];

		helpViewX = 20;
		helpViewW = FlxG.width - 66;
		helpViewY = CONTENT_Y + 30;
		helpViewH = FlxG.height - helpViewY - 44;
		if (helpViewH < 80) helpViewH = 80;

		track(g, new FlxSprite(10, CONTENT_Y).makeSolid(Std.int(FlxG.width - 20), Std.int(helpViewH + 40), 0xFF1B1B21));
		track(g, new UIText(20, CONTENT_Y + 7, FlxG.width - 40, "Help & About", 14, 0xFFFFE066, false));

		track(g, helpText = new UIText(helpViewX, helpViewY, helpViewW, HELP_BODY, 13, 0xFFE0E0E8, false));
		helpText.wordWrap = true;
		helpScroll = 0;
		// the height of a wrapped text is only final once the font has been laid out,
		// so the page measures itself again on the first frames it is on screen
		refreshHelpLayout(true);
	}

	/**
	 * Measures the help text and creates, resizes or drops the scroll bar to match.
	 * A stale measurement is what used to leave the bar with a wrong thumb, or no
	 * bar at all on a page taller than the window.
	 */
	function refreshHelpLayout(force:Bool = false) {
		if (helpText == null) return;

		var h = Math.ceil(helpText.textField.textHeight) + 8;
		if (!force && Math.abs(h - helpHeight) < 1) return;
		helpHeight = h;

		var maxScroll = helpHeight - helpViewH;
		if (maxScroll < 0) maxScroll = 0;

		if (maxScroll <= 0) {
			if (helpBar != null) {
				tabGroups[TAB_HELP].remove(helpBar);
				remove(helpBar, true);
				helpBar.destroy();
				helpBar = null;
			}
			setHelpScroll(0);
			return;
		}

		var size = (helpViewH / helpHeight) * helpViewH;
		if (size < 24) size = 24;
		if (size > helpViewH) size = helpViewH;

		if (helpBar == null) {
			helpBar = new UIScrollBar(FlxG.width - 40, helpViewY, maxScroll, -size * 0.5, size, 20, Std.int(helpViewH));
			helpBar.alpha = 1;
			// the thumb is placed by setHelpScroll, so the wheel and a drag agree
			helpBar.onChange = function(v) setHelpScroll(v);
			track(tabGroups[TAB_HELP], helpBar);
			helpBar.visible = currentTab == TAB_HELP;
			helpBar.active = currentTab == TAB_HELP;
		} else {
			helpBar.length = maxScroll;
			helpBar.size = size;
		}

		setHelpScroll(helpScroll);
	}

	function isMouseOverHelp():Bool {
		return FlxG.mouse.x >= helpViewX - 6 && FlxG.mouse.x <= helpViewX + helpViewW + 30
			&& FlxG.mouse.y >= helpViewY && FlxG.mouse.y <= helpViewY + helpViewH;
	}

	function setHelpScroll(value:Float) {
		var maxScroll = helpHeight - helpViewH;
		if (maxScroll < 0) maxScroll = 0;
		if (value < 0) value = 0;
		if (value > maxScroll) value = maxScroll;
		helpScroll = value;
		// also move the thumb when the wheel scrolled, not only when it was dragged
		if (helpBar != null) helpBar.start = helpScroll - helpBar.size * 0.5;
		applyHelpScroll();
	}

	function applyHelpScroll() {
		if (helpText == null) return;
		if (currentTab != TAB_HELP) {
			helpText.visible = false;
			return;
		}

		var short = helpHeight <= helpViewH;
		var from = short ? 0 : helpScroll;
		var to = short ? helpHeight : helpScroll + helpViewH;
		if (to > helpHeight) to = helpHeight;
		if (to <= from) {
			helpText.visible = false;
			return;
		}

		helpText.visible = true;
		helpText.offset.set(0, short ? 0 : helpScroll);

		var clip = helpText.clipRect;
		if (clip == null) clip = new FlxRect();
		clip.set(0, from, helpViewW, to - from);
		helpText.clipRect = clip;
	}

	public override function update(elapsed:Float) {
		super.update(elapsed);
		handleBackInput();
		updateJob(elapsed);

		// the wrapped help text settles its height over the first frames it is shown,
		// so keep measuring for a moment and resize the scroll bar when it changes
		if (currentTab == TAB_HELP && helpMeasureFrames < 12) {
			helpMeasureFrames++;
			refreshHelpLayout();
		}

		if (FlxG.mouse.wheel != 0 && !fileDialogOpen && currentTab == TAB_HELP && isMouseOverHelp())
			setHelpScroll(helpScroll - FlxG.mouse.wheel * SCROLL_STEP);
	}

	// ------------------------------------------------------------- back handling

	function handleBackInput() {
		if (isEditingText() && FlxG.keys.justPressed.ESCAPE) {
			unfocusTextBox();
			return;
		}
		if (!controls.BACK) return;
		if (topMenu != null && topMenu.anyMenuOpened) {
			closeOpenMenus();
			return;
		}
		if (isEditingText()) return;
		if (fileDialogOpen) return;
		exitEditor();
	}

	function isEditingText():Bool
		return currentFocus != null && currentFocus is UITextBox;

	function unfocusTextBox() {
		if (!isEditingText()) return;
		var box:UITextBox = cast currentFocus;
		box.focused = false;
		status("Text field unfocused - press ESC again to leave the editor.");
	}

	function closeOpenMenus() {
		if (topMenu == null) return;
		for (member in topMenu.members) {
			if (!(member is UITopMenuButton)) continue;
			var btn:UITopMenuButton = cast member;
			if (btn.curMenu != null && btn.curMenu.contextMenuOpened())
				btn.curMenu.close();
		}
	}

	function exitEditor() {
		FlxG.switchState(new MainMenuState());
	}

	// ------------------------------------------------------------ key token tool

	function onMakeToken() {
		var key = tokenKeyBox.label.text;
		if (key == null || StringTools.trim(key).length == 0) {
			status("Type the key first, then press Make Token.");
			return;
		}
		tokenTokenBox.label.text = ScriptCrypto.encodeKeyToken(StringTools.trim(key));
		status("Token created - it turns back into the same key with Recover Key.");
	}

	function onRecoverKey() {
		var token = tokenTokenBox.label.text;
		if (token == null || StringTools.trim(token).length == 0) {
			status("Paste a token first, then press Recover Key.");
			return;
		}
		var key = ScriptCrypto.decodeKeyToken(StringTools.trim(token));
		if (key == null) {
			status("That token is not valid (it must start with " + ScriptCrypto.TOKEN_PREFIX + ").");
			return;
		}
		tokenKeyBox.label.text = key;
		status("Key recovered from the token.");
	}

	/** Puts a value on the system clipboard so it can be sent to a player. */
	function copyToClipboard(value:String, label:String) {
		if (value == null) value = "";
		value = StringTools.trim(value);
		if (value.length == 0) {
			status("Nothing to copy - " + label + " is empty.");
			return;
		}
		lime.system.Clipboard.text = value;
		status(label + " copied to the clipboard.");
	}

	function onCopyKey() copyToClipboard(tokenKeyBox.label.text, "Key");

	function onCopyToken() copyToClipboard(tokenTokenBox.label.text, "Token");

	// ----------------------------------------------------------- mod pack export

	function selectPackMode(index:Int) {
		currentPackMode = index;
		setRadio(packModeStrong, index == 0);
		setRadio(packModeStandard, index == 1);
		if (packModeText != null) packModeText.text = packModeDescription(index);
		status("Export format: " + (index == 1 ? "standard AES-256 password zip" : "enhanced CNEZ container") + ".");
	}

	function setRadio(radio:UIRadioButton, on:Bool) {
		if (radio == null) return;
		radio.checked = on;
		radio.targetScale = on ? 1 : 0;
	}

	function packModeDescription(index:Int):String {
		if (index == 1)
			return "Standard: the zip stays a normal zip, but every entry is encrypted with AES-256 (WinZip AES).\n"
				+ "7-Zip, WinRAR and Bandizip open it with the password, and so does the engine - players are asked\n"
				+ "for that password at startup. Hand out the key or a token: the same password works in both.";
		return "Enhanced: the zip is wrapped in a CNEZ container. No archive tool can open it at all - only\n"
			+ "Codename Engine can, with the key (or a token). Safest option, but nobody can browse the mod in\n"
			+ "7-Zip and every tool that expects a real zip just sees garbage.";
	}

	/**
	 * Encrypts a .zip mod pack. The method comes from the radio buttons above:
	 * CNEZ container (strong) or a standard AES-256 password zip.
	 */
	function encryptModPack() {
		if (jobActive) {
			status("Wait for the current pack job to finish - watch the progress bar.");
			return;
		}
		fileDialogOpen = true;
		FileDialog.openFile(FlxG.stage.window, "Choose the mod pack (.zip) to encrypt", function(files, filter) {
			if (files == null || files.length == 0) {
				fileDialogOpen = false;
				return;
			}
			encryptModPackFile(files[0]);
		}, [new FileDialogFilter("Mod pack", "zip"), new FileDialogFilter("All files", "*")], lastDirectory);
	}

	function encryptModPackFile(path:String) {
		fileDialogOpen = false;
		var key = packKey(path);
		var standard = currentPackMode == 1;

		try {
			if (ModPackCrypto.isEncryptedPackFile(path)) {
				status("That file is already an encrypted (CNEZ) mod pack.");
				return;
			}
			var handle = File.read(path, true);
			var head = handle.read(4);
			handle.close();
			if (head == null || head.length < 4 || head.get(0) != 0x50 || head.get(1) != 0x4B) {
				status("That file is not a zip archive.");
				return;
			}
		} catch(e:Dynamic) {
			status("Cannot read " + path + ": " + Std.string(e));
			return;
		}

		if (ZipPassword.isProtected(path)) {
			status("That zip is already password protected. Remove its password first, the exporter needs a plain zip.");
			return;
		}

		var defaultPath = siblingPath(path, "zip", standard ? "_password" : "_encrypted");
		fileDialogOpen = true;
		FileDialog.saveFile(FlxG.stage.window, standard ? "Save AES-256 Password Zip" : "Save Encrypted Mod Pack", function(outPath, filter) {
			fileDialogOpen = false;
			if (outPath == null || outPath.length == 0) return;
			startPackJob(JOB_ENCRYPT, path, outPath, key, standard);
		}, [new FileDialogFilter("Mod pack", "zip"), new FileDialogFilter("All files", "*")], defaultPath);
	}

	// ------------------------------------------------------------- pack restore

	/**
	 * Restores an encrypted mod pack: a CNEZ container or a password zip becomes a
	 * plain zip again. The work runs on a worker thread so the editor keeps
	 * drawing while a 100+ MB pack is processed, the same way the game shows a
	 * progress screen when it has to decrypt a pack at start up.
	 */
	function decryptModPack() {
		if (jobActive) {
			status("Wait for the current pack job to finish - watch the progress bar.");
			return;
		}
		fileDialogOpen = true;
		FileDialog.openFile(FlxG.stage.window, "Choose the encrypted mod pack (.zip) to decrypt", function(files, filter) {
			if (files == null || files.length == 0) {
				fileDialogOpen = false;
				return;
			}
			decryptModPackFile(files[0]);
		}, [new FileDialogFilter("Mod pack", "zip"), new FileDialogFilter("All files", "*")], lastDirectory);
	}

	function decryptModPackFile(path:String) {
		fileDialogOpen = false;
		if (path == null) return;

		var container = ModPackCrypto.isEncryptedPackFile(path);
		var protectedZip = !container && ZipPassword.isProtected(path);
		if (!container && !protectedZip) {
			status("Nothing to decrypt: " + Path.withoutDirectory(path) + " is already a plain zip.");
			return;
		}

		var defaultPath = siblingPath(path, "zip", "_decrypted");
		fileDialogOpen = true;
		FileDialog.saveFile(FlxG.stage.window, "Save the decrypted (plain) mod pack", function(outPath, filter) {
			fileDialogOpen = false;
			if (outPath == null || outPath.length == 0) return;
			startPackJob(JOB_DECRYPT, path, outPath, packKey(path), false);
		}, [new FileDialogFilter("Mod pack", "zip"), new FileDialogFilter("All files", "*")], defaultPath);
	}

	/**
	 * Runs an encrypt or a decrypt job on a worker thread. Both go through the same
	 * progress row, so the editor never freezes on a 100+ MB pack.
	 */
	function startPackJob(kind:Int, srcPath:String, outPath:String, key:String, standard:Bool) {
		if (jobActive) return;

		jobActive = true;
		jobKind = kind;
		jobDone = false;
		jobError = null;
		jobProgress = 0;
		jobOut = outPath;
		jobName = Path.withoutDirectory(srcPath);
		jobHold = 0;
		jobFadeTarget = 1;
		if (jobText != null) {
			jobText.color = 0xFF9BE28C;
			jobText.text = "0%  -  reading " + jobName + "...";
		}
		status((kind == JOB_ENCRYPT ? "Encrypting " : "Decrypting ") + jobName + " ...");

		var work = function() {
			try {
				if (kind == JOB_ENCRYPT) {
					if (standard) {
						ZipAes.encryptZip(srcPath, outPath, key, function(p:Float) jobProgress = p * 0.98);
					} else {
						var data = File.getBytes(srcPath);
						jobProgress = 0.03;
						var bytes = ModPackCrypto.pack(data, key, function(p:Float) jobProgress = 0.03 + p * 0.92);
						File.saveBytes(outPath, bytes);
					}
				} else if (ModPackCrypto.isEncryptedPackFile(srcPath)) {
					var data = File.getBytes(srcPath);
					var plain = ModPackCrypto.unpack(data, key, function(p:Float) jobProgress = p * 0.9);
					jobProgress = 0.95;
					File.saveBytes(outPath, plain);
				} else {
					var cached = ZipPassword.extractToCache(srcPath, key, function(p:Float) jobProgress = p * 0.85);
					if (cached == null) throw "nothing was decrypted";
					jobProgress = 0.9;
					// copy, do not move: the game may still be reading that copy
					File.copy(cached, outPath);
				}
				jobProgress = 1;
			} catch (e:Dynamic) {
				jobError = Std.string(e);
				jobProgress = 1;
			}
			jobDone = true;
		};

		#if target.threaded
		try sys.thread.Thread.create(work) catch (e:Dynamic) work(); // no thread: blocking is still correct
		#else
		work();
		#end
	}

	/** Fades the progress row in and out, and reports the result once the worker is done. */
	function updateJob(elapsed:Float) {
		if (jobFade != jobFadeTarget) {
			var step = elapsed * 6;
			if (step > 1) step = 1;
			jobFade = FlxMath.lerp(jobFade, jobFadeTarget, step);
			if (Math.abs(jobFade - jobFadeTarget) < 0.01) jobFade = jobFadeTarget;
		}

		var p = jobProgress;
		if (p < 0) p = 0;
		if (p > 1) p = 1;
		var percent = Std.int(p * 100) + "%";
		var verb = jobKind == JOB_ENCRYPT ? "encrypting" : "decrypting";

		if (jobActive) {
			if (jobBar != null) jobBar.scale.x = Math.max(0.001, p);
			if (jobText != null) jobText.text = percent + "  -  " + verb + " " + jobName + " ...";
		}

		if (jobActive && jobDone) {
			jobActive = false;
			jobHold = 2.5; // keep the result readable, then let the row fade away
			if (jobError != null) {
				if (jobText != null) {
					jobText.color = 0xFFFF6B6B;
					jobText.text = "Failed: " + jobError;
				}
				status("Could not " + verb + " " + jobName + ": " + jobError);
			} else {
				if (jobBar != null) jobBar.scale.x = 1;
				var size = 0.0;
				try size = sys.FileSystem.stat(jobOut).size catch (e:Dynamic) {}
				var mb = Std.int(size / 1048576);
				if (jobText != null) jobText.text = "100%  -  " + Path.withoutDirectory(jobOut) + " (" + mb + " MB).";
				status((jobKind == JOB_ENCRYPT ? "Encrypted " : "Decrypted ") + jobName + " to " + jobOut + " (" + mb + " MB).");
			}
		} else if (!jobActive && jobHold > 0) {
			jobHold -= elapsed;
			if (jobHold <= 0) {
				jobHold = 0;
				jobFadeTarget = 0;
			}
		}

		var shown = jobFade > 0.001;
		if (jobText != null) {
			jobText.alpha = jobFade;
			jobText.visible = shown;
		}
		if (jobBarBg != null) {
			jobBarBg.alpha = jobFade;
			jobBarBg.visible = shown;
		}
		if (jobBar != null) {
			jobBar.alpha = jobFade;
			jobBar.visible = shown;
		}
	}

	/** Re-reads script_key.txt so an edited key file is used without a restart. */
	function reloadKeyFile() {
		ScriptCrypto.reloadKeys();
		var summary = ScriptCrypto.keyFileSummary();
		tokenKeyBox.label.text = ScriptCrypto.getPassword();
		status("Reloaded the key file: " + summary + ". The Key field now shows the default key.");
	}

	// ------------------------------------------------------------------- helpers

	/**
	 * Key used when writing a mod pack: the Key field of the token tool wins, then the
	 * key script_key.txt (or the engine) has for that pack name.
	 */
	function packKey(path:String):String {
		var typed = tokenKeyBox.label.text;
		if (typed != null) {
			typed = StringTools.trim(typed);
			if (typed.length > 0) {
				var resolved = ScriptCrypto.resolveKeyValue(typed);
				if (resolved != null) return resolved;
			}
		}

		var stem = path == null ? null : Path.withoutExtension(Path.withoutDirectory(path));
		var fallback = ScriptCrypto.getPassword(stem);
		if (fallback == null) fallback = ScriptCrypto.getPassword();
		return fallback;
	}

	function siblingPath(path:String, ext:String, suffix:String = ""):String {
		if (path == null) return "pack" + suffix + "." + ext;
		var dir = Path.directory(path);
		if (dir == null) dir = "";
		var sep = "";
		if (dir.length > 0 && !StringTools.endsWith(dir, "/") && !StringTools.endsWith(dir, "\\"))
			sep = "/";
		var base = Path.withoutExtension(Path.withoutDirectory(path));
		var curExt = Path.extension(path);
		if (curExt != null && curExt.toLowerCase() == ext.toLowerCase())
			base += suffix;
		return dir + sep + base + "." + ext;
	}

	function status(message:String) {
		statusText.text = message;
		Logs.trace(message, INFO);
	}
}
