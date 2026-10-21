package funkin.editors;

import flixel.math.FlxRect;
import funkin.backend.assets.ModPackCrypto;
import funkin.backend.assets.ZipAes;
import funkin.backend.assets.ZipPassword;
import funkin.backend.scripting.bytecode.ScriptPackager;
import funkin.backend.scripting.crypto.ScriptCrypto;
import funkin.editors.ui.*;
import funkin.editors.ui.UITopMenu.UITopMenuButton;
import funkin.menus.MainMenuState;
import haxe.io.Bytes;
import haxe.io.Path;
import lime.ui.FileDialog;
import lime.ui.FileDialogType;
import sys.io.File;

/**
 * One loaded script file. Preview blocks are rebuilt on every reload, so
 * `label`, `top` and `blockHeight` are layout state owned by the editor.
 */
class ScriptEntry {
	public var path:String;
	public var bytes:Bytes = null;

	/** Decrypted source text; null when the file only contains bytecode. */
	public var source:String = null;
	public var mode:Int = -1;
	public var functions:Int = 0;
	public var info:String = "Unknown.";
	public var error:String = null;

	public var label:UIText = null;
	public var top:Float = 0;
	public var blockHeight:Float = 0;

	public function new(path:String)
		this.path = path;

	public function fileName():String
		return Path.withoutDirectory(path);

	public function baseName():String
		return Path.withoutExtension(Path.withoutDirectory(path));
}

/**
 * General purpose encryption tool, reachable from the editor picker (F7 menu).
 *
 * It protects HScript files (encrypted source, keyless VM bytecode, or both) and
 * wraps zip mod packs into encrypted containers, plus the key token helper that
 * turns a key into a shareable string and back.
 *
 * Supports selecting several files at once: every file gets its own block in
 * the scrollable preview (file name on the first line of each block), and a
 * multi file save writes all files into a chosen folder, renamed to
 * `name_encrypted.hxb` / `name_decrypted.hx`.
 */
class EncryptionEditor extends UIState {
	static inline var PANEL_Y:Float = 268;
	static inline var BLOCK_GAP:Float = 14;
	static inline var SCROLL_STEP:Float = 64;
	static inline var TAB_Y:Float = 34;
	static inline var TAB_H:Int = 30;
	static inline var CONTENT_Y:Float = 74;

	static inline var TAB_SCRIPTS:Int = 0;
	static inline var TAB_MODPACK:Int = 1;
	static inline var TAB_HELP:Int = 2;
	static var TAB_NAMES:Array<String> = ["Scripts", "Mod Pack", "Help"];

	public var topMenu:UITopMenu;
	public var bg:FlxSprite;

	public var pathText:UIText;
	public var infoText:UIText;
	public var modeSource:UIRadioButton;
	public var modeBytecode:UIRadioButton;
	public var modeBoth:UIRadioButton;
	public var passwordBox:UITextBox;
	public var statusText:UIText;

	public var panel:FlxSprite;
	public var previewHeader:UIText;
	public var scrollBar:UIScrollBar;

	public var entries:Array<ScriptEntry> = [];
	// every preview block ever created lives here, so nothing can be leaked when
	// the entry list is replaced (that is what used to leave stale text on screen)
	public var previewLabels:Array<UIText> = [];

	public var scroll:Float = 0;
	public var contentHeight:Float = 0;

	public var fileDialogOpen:Bool = false;
	public var lastDirectory:String = null;

	/** 0 = encrypted source, 1 = keyless VM bytecode, 2 = bytecode + encrypted source. */
	public var currentMode:Int = 2;

	/** 0 = CNEZ container (strong), 1 = standard AES-256 password zip. */
	public var packModeStrong:UIRadioButton;
	public var packModeStandard:UIRadioButton;
	public var packModeText:UIText;
	public var currentPackMode:Int = 0;

	// tab bar: every tab owns a list of widgets that are simply hidden while
	// another tab is selected, the way the rest of the editor screens work
	public var tabs:Array<UIButton> = [];
	public var tabGroups:Array<Array<FlxSprite>> = [[], [], []];
	public var currentTab:Int = TAB_SCRIPTS;

	// key token widgets - they share the Mod Pack tab
	public var tokenKeyBox:UITextBox;
	public var tokenTokenBox:UITextBox;

	// help tab
	public var helpText:UIText;
	public var helpBar:UIScrollBar;
	public var helpScroll:Float = 0;
	public var helpHeight:Float = 0;
	var helpViewX:Float = 20;
	var helpViewY:Float = 100;
	var helpViewW:Float = 100;
	var helpViewH:Float = 100;

	// preview viewport, computed in create()
	var viewX:Float = 10;
	var viewY:Float = 0;
	var viewW:Float = 100;
	var viewH:Float = 100;

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
					{label: "Open Script(s)...", onSelect: (_) -> openScriptDialog()},
					{label: "Reload / Preview", onSelect: (_) -> reloadPreview()},
					{label: "Reload Key File (script_key.txt)", onSelect: (_) -> reloadKeyFile()},
					{label: "Encrypt & Save...", onSelect: (_) -> encryptAndSave()},
					{label: "Save Decrypted Source...", onSelect: (_) -> saveDecrypted()},
					null,
					{label: "Clear List", onSelect: (_) -> clearEntries()},
					{label: "Exit", onSelect: (_) -> exitEditor()}
				]
			},
			{
				label: "Tools",
				childs: [
					{label: "Scripts tab", onSelect: (_) -> showTab(TAB_SCRIPTS)},
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
		buildScriptTab();
		buildModPackTab();
		buildHelpTab();


		add(statusText = new UIText(10, FlxG.height - 30, FlxG.width - 20, "", 14, 0xFFFFE066, false));

		showTab(TAB_SCRIPTS);

		rebuildPreview();
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

		if (scrollBar != null) {
			scrollBar.visible = index == TAB_SCRIPTS;
			scrollBar.active = index == TAB_SCRIPTS; // 修复：单独处理动态创建的滚动条
		}

		for (i in 0...tabs.length)
			tintButton(tabs[i], i == index ? 0xFFFFFFFF : 0xFF8A8A96);

		applyScroll();
		applyHelpScroll();
		if (index == TAB_HELP) status("Help - scroll the text with the mouse wheel.");
	}

	function tintButton(btn:UIButton, color:Int) {
		if (btn == null) return;
		btn.color = color;
		if (btn.field != null) btn.field.color = color;
	}

	function buildScriptTab() {
		var g = tabGroups[TAB_SCRIPTS];

		track(g, pathText = new UIText(10, CONTENT_Y, FlxG.width - 20, "No script loaded - press File > Open Script(s)...", 15, 0xFFFFFFFF, false));
		track(g, infoText = new UIText(10, CONTENT_Y + 24, FlxG.width - 20, "Encrypted scripts use the .hxb extension and can be loaded like any other script.", 13, 0xFFFFFFFF, false));

		track(g, modeSource = new UIRadioButton(10, CONTENT_Y + 54, "Encrypt source only (needs key)", false, "modeSource", 280));
		track(g, modeBytecode = new UIRadioButton(300, CONTENT_Y + 54, "VM bytecode only (no key)", false, "modeBytecode", 280));
		track(g, modeBoth = new UIRadioButton(590, CONTENT_Y + 54, "Both: bytecode + encrypted source", true, "modeBoth", 400));

		modeSource.onChecked = function(_) selectMode(0);
		modeBytecode.onChecked = function(_) selectMode(1);
		modeBoth.onChecked = function(_) selectMode(2);

		track(g, new UIText(10, CONTENT_Y + 84, 90, "Password:", 15));
		track(g, passwordBox = new UITextBox(100, CONTENT_Y + 80, ScriptCrypto.getPassword(), 360));
		track(g, new UIText(472, CONTENT_Y + 86, FlxG.width - 490, "empty = use the key script_key.txt has for each script", 12, 0xFF9A9AA8, false));

		var half = Std.int((FlxG.width - 30) / 2);
		track(g, new UIButton(10, CONTENT_Y + 122, "Open Script(s)...", openScriptDialog, half, 32));
		track(g, new UIButton(20 + half, CONTENT_Y + 122, "Decrypt Preview", reloadPreview, half, 32));
		track(g, new UIButton(10, CONTENT_Y + 160, "Encrypt & Save...", encryptAndSave, half, 32));
		track(g, new UIButton(20 + half, CONTENT_Y + 160, "Save Decrypted...", saveDecrypted, half, 32));

		var panelW = FlxG.width - 20;
		var panelH = FlxG.height - PANEL_Y - 44;
		if (panelH < 90) panelH = 90;

		track(g, panel = new FlxSprite(10, PANEL_Y).makeSolid(Std.int(panelW), Std.int(panelH), 0xFF1B1B21));

		viewX = 20;
		viewW = panelW - 46;
		viewY = PANEL_Y + 30;
		viewH = panelH - 40;
		if (viewH < 24) viewH = 24;

		track(g, previewHeader = new UIText(20, PANEL_Y + 7, panelW - 40, "Preview - nothing loaded", 14, 0xFFFFE066, false));
	}

	function buildModPackTab() {
		var g = tabGroups[TAB_MODPACK];
		var panelH = FlxG.height - CONTENT_Y - 46;
		if (panelH < 500) panelH = 500;

		track(g, new FlxSprite(10, CONTENT_Y).makeSolid(Std.int(FlxG.width - 20), Std.int(panelH), 0xFF1B1B21));

		// key tokens exist for encrypted mod packs only, so they sit on top of the
		// pack exporter and nowhere else
		track(g, new UIText(30, CONTENT_Y + 12, FlxG.width - 60, "Key Token Tool - for encrypted mod packs", 17, 0xFFFFE066, false));
		track(g, new UIText(30, CONTENT_Y + 40, FlxG.width - 70,
			"A token (CNEK1-...) is the key rewritten as different text: hand it to players instead of the key.\n"
			+ "They paste it into the prompt that opens an encrypted mod pack. Encrypted .hx scripts use the plain key.",
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
	}

	static var HELP_BODY:String =
		"WHAT THIS TOOL DOES\n\n"
		+ "The Scripts tab turns HScript files into protected .hxb containers. The Mod Pack tab wraps a zip\n"
		+ "mod into a CNEZ container (or turns it into a standard AES-256 password zip), and it turns a key\n"
		+ "into a shareable token and back too.\n\n"
		+ "scripts - three modes, picked with the radio buttons\n\n"
		+ "  - source only: the text is encrypted, a key is needed to load it.\n"
		+ "  - VM bytecode only: compiled to the CNE virtual machine, runs without any key, no readable source.\n"
		+ "  - both (default): bytecode plus an encrypted copy of the source, a key is needed.\n\n"
		+ "Select several files at once: every file becomes its own block in the scrollable preview (the\n"
		+ "file name is on the first line of each block and stays in the preview title) and a multi file save\n"
		+ "writes them all into one folder as name_encrypted.hxb / name_decrypted.hx.\n\n"
		+ "keys\n\n"
		+ "The key comes from the Password field, script_key.txt, or the built-in engine key. A custom key\n"
		+ "must also be written into script_key.txt (next to the executable), otherwise the engine cannot\n"
		+ "open the files again. File > Reload Key File re-reads the file without restarting.\n\n"
		+ "script_key.txt accepts two formats:\n\n"
		+ "  - one key for everything: nothing but the key on the first line.\n"
		+ "  - one key per file: name = key per line, where name is a file name, a name without extension,\n"
		+ "    a mod relative path, or * as fallback. Lines starting with # or // are comments.\n\n"
		+ "key tokens (mod packs only)\n\n"
		+ "A token (CNEK1-...) is the key rewritten as different text, made on the Mod Pack tab above the\n"
		+ "pack exporter. It is what players paste into the prompt that opens an encrypted zip mod; encrypted\n"
		+ ".hx scripts keep using the plain key. Copy Key / Copy Token put either one on the clipboard.\n\n"
		+ "zip mod packs\n\n"
		+ "Encrypted packs are asked for a key before the mod loads, with the option to play without mods.\n"
		+ "Two export formats, picked with the radio buttons on the Mod Pack tab:\n"
		+ "  - enhanced: a CNEZ container. No archive tool can open it, only the engine can (needs the key).\n"
		+ "  - standard: a normal zip whose entries are AES-256 encrypted (WinZip AES). 7-Zip, WinRAR and\n"
		+ "    Bandizip open it with the password - and so does the engine, so players only type it once.\n"
		+ "Plain zips load as before. Password zips from other tools load too (ZipCrypto and AES-128/192/256):\n"
		+ "the password is asked at startup and the engine keeps a readable copy in .cne_mods/.\n\n"
		+ "tips\n\n"
		+ "While a text field is focused, Backspace edits the text and ESC only drops the focus.\n"
		+ "ESC again leaves the editor. Scroll long text with the mouse wheel over it.\n";

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
		helpHeight = Math.ceil(helpText.textField.textHeight) + 8;
		helpScroll = 0;

		if (helpHeight > helpViewH) {
			var length = helpHeight - helpViewH;
			var size = (helpViewH / helpHeight) * helpViewH;
			if (size < 24) size = 24;
			if (size > helpViewH) size = helpViewH;
			helpBar = new UIScrollBar(FlxG.width - 40, helpViewY, length, -size * 0.5, size, 20, Std.int(helpViewH));
			helpBar.alpha = 1;
			helpBar.onChange = function(v) {
				setHelpScroll(v);
				if (helpBar != null) helpBar.start = helpScroll - helpBar.size * 0.5;
			};
			track(g, helpBar);
		}
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

		if (FlxG.mouse.wheel != 0 && !fileDialogOpen) {
			if (currentTab == TAB_SCRIPTS && isMouseOverPreview())
				setScroll(scroll - FlxG.mouse.wheel * SCROLL_STEP);
			else if (currentTab == TAB_HELP && isMouseOverHelp())
				setHelpScroll(helpScroll - FlxG.mouse.wheel * SCROLL_STEP);
		}
	}

	function isMouseOverPreview():Bool {
		var mx = FlxG.mouse.x;
		var my = FlxG.mouse.y;
		return mx >= viewX - 6 && mx <= viewX + viewW + 26 && my >= viewY && my <= viewY + viewH;
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
		status("Password field unfocused - press ESC or Backspace again to leave the editor.");
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

	// ------------------------------------------------------------- encrypt mode

	function selectMode(index:Int) {
		currentMode = index;
		setRadio(modeSource, index == 0);
		setRadio(modeBytecode, index == 1);
		setRadio(modeBoth, index == 2);
		status("Mode: " + modeDescription(index) + ".");
	}

	function setRadio(radio:UIRadioButton, on:Bool) {
		if (radio == null) return;
		radio.checked = on;
		radio.targetScale = on ? 1 : 0;
	}

	function modeDescription(index:Int):String {
		switch (index) {
			case 0: return "encrypted source - needs a key to open";
			case 1: return "VM bytecode - runs without a key, no readable source";
			case 2: return "bytecode + encrypted source - needs a key, best hiding";
		}
		return "unknown";
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
		var dialog = new FileDialog();
		dialog.onSelect.add(function(path:String) encryptModPackFile(path));
		dialog.onCancel.add(function() fileDialogOpen = false);
		fileDialogOpen = true;
		if (!dialog.browse(OPEN, "*.zip", lastDirectory, "Choose the mod pack (.zip) to encrypt")) {
			fileDialogOpen = false;
			status("This platform does not support file dialogs.");
		}
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
		var dialog = new FileDialog();
		dialog.onSelect.add(function(outPath:String) {
			fileDialogOpen = false;
			try {
				if (standard) {
					ZipAes.encryptZip(path, outPath, key);
					status("Password zip saved to " + outPath + ". 7-Zip / WinRAR open it with the key; the engine asks players for the same password or a token.");
				} else {
					var bytes = ModPackCrypto.pack(File.getBytes(path), key);
					File.saveBytes(outPath, bytes);
					status("Encrypted mod pack saved to " + outPath + " (" + bytes.length + " bytes). Put the key or a key token into the readme.");
				}
			} catch(e:Dynamic) {
				status("Failed to save: " + Std.string(e));
			}
		});
		dialog.onCancel.add(function() fileDialogOpen = false);
		fileDialogOpen = true;
		if (!dialog.browse(SAVE, "*.zip", defaultPath, standard ? "Save AES-256 Password Zip" : "Save Encrypted Mod Pack")) {
			fileDialogOpen = false;
			status("This platform does not support file dialogs.");
		}
	}

	// ---------------------------------------------------------------- file input

	function openScriptDialog() {
		var dialog = new FileDialog();

		dialog.onSelectMultiple.add(function(paths:Array<String>) handlePaths(paths));
		dialog.onSelect.add(function(path:String) handlePaths([path]));
		dialog.onCancel.add(function() fileDialogOpen = false);

		var startDir = lastDirectory;
		if (startDir == null && entries.length > 0) {
			var d = Path.directory(entries[0].path);
			if (d != null && d.length > 0)
				startDir = normalizeDirectory(d);
		}

		fileDialogOpen = true;
		if (!dialog.browse(OPEN_MULTIPLE, "*.hx;*.hscript;*.hsc;*.hxs;*.hxb", startDir, "Open Script(s)")) {
			fileDialogOpen = false;
			status("This platform does not support file dialogs.");
		}
	}

	function handlePaths(paths:Array<String>) {
		fileDialogOpen = false;
		if (paths == null || paths.length == 0) return;

		var dir = Path.directory(paths[0]);
		if (dir != null && dir.length > 0)
			lastDirectory = normalizeDirectory(dir);

		loadFiles(paths);
	}

	function normalizeDirectory(dir:String):String {
		if (dir == null) return null;
		dir = StringTools.replace(dir, "\\", "/");
		while (dir.length > 1 && StringTools.endsWith(dir, "/"))
			dir = dir.substr(0, dir.length - 1);
		if (dir.length == 0) return null;
		return dir;
	}

	function loadFiles(paths:Array<String>) {
		clearPreviewBlocks();
		entries = [];

		var failed = 0;
		for (path in paths) {
			var entry = new ScriptEntry(path);
			try {
				entry.bytes = File.getBytes(path);
			} catch(e:Dynamic) {
				entry.error = "Failed to read file: " + Std.string(e);
				failed++;
			}
			entries.push(entry);
		}

		if (entries.length == 1)
			pathText.text = entries[0].path;
		else
			pathText.text = entries.length + " scripts selected - preview shows each one in order";

		reloadPreview();

		if (failed > 0)
			status("Loaded " + (entries.length - failed) + " file(s), " + failed + " could not be read.");
	}

	function clearEntries() {
		clearPreviewBlocks();
		entries = [];
		pathText.text = "No script loaded - press File > Open Script(s)...";
		infoText.text = "Encrypted scripts use the .hxb extension and can be loaded like any other script.";
		rebuildPreview();
		status("Cleared the file list.");
	}

	/** Re-reads script_key.txt so an edited key file is used without a restart. */
	function reloadKeyFile() {
		ScriptCrypto.reloadKeys();
		var summary = ScriptCrypto.keyFileSummary();
		var resolved = ScriptCrypto.getPassword();
		passwordBox.label.text = resolved;
		reloadPreview();
		status("Reloaded the key file: " + summary + ". Password field now shows the default key.");
	}

	public function reloadPreview() {
		if (entries.length == 0) {
			status("No script loaded.");
			rebuildPreview();
			return;
		}

		var ok = 0;
		var failed = 0;
		var bytecodeOnly = 0;

		for (entry in entries) {
			entry.error = null;
			entry.source = null;
			entry.mode = -1;
			entry.functions = 0;

			if (entry.bytes == null) {
				if (entry.error == null) entry.error = "File was not read.";
				failed++;
				continue;
			}

			try {
				if (ScriptPackager.isObfuscated(entry.bytes)) {
					// keyless bytecode: nothing to unlock, only describe it
					var packed = ScriptPackager.unpack(entry.bytes);
					entry.mode = packed.mode;
					entry.functions = packed.chunk == null ? 0 : packed.chunk.functions.length;
					entry.source = null;
					try {
						entry.info = ScriptPackager.describe(entry.bytes);
					} catch(e:Dynamic) {
						entry.info = "VM bytecode (" + entry.bytes.length + " bytes)";
					}
					bytecodeOnly++;
				} else if (ScriptPackager.isEncrypted(entry.bytes)) {
					// script_key.txt may give every script its own key, so try the
					// typed password first and fall back to the configured ones.
					var packed = null;
					var usedKey:String = null;
					for (candidate in keyCandidates(entry)) {
						try {
							packed = ScriptPackager.unpack(entry.bytes, candidate);
							usedKey = candidate;
							break;
						} catch(e:Dynamic) {}
					}
					if (packed == null) throw "None of the configured keys opened this file.";

					entry.mode = packed.mode;
					entry.functions = packed.chunk == null ? 0 : packed.chunk.functions.length;
					entry.source = packed.source;
					try {
						entry.info = ScriptPackager.describe(entry.bytes, usedKey);
					} catch(e:Dynamic) {
						entry.info = "encrypted script (" + entry.bytes.length + " bytes)";
					}
					if (usedKey != ScriptCrypto.getPassword())
						entry.info += " | key: script_key.txt";
					if (entry.source == null) bytecodeOnly++;
				} else {
					entry.mode = -1;
					entry.source = entry.bytes.toString();
					entry.info = "plain script (" + entry.source.length + " characters)";
				}
				ok++;
			} catch(e:Dynamic) {
				entry.error = "Failed to decrypt (check the password field): " + Std.string(e);
				failed++;
			}
		}

		if (entries.length == 1) {
			var entry = entries[0];
			pathText.text = entry.path;
			infoText.text = entry.error != null ? entry.error : (entry.info + (entry.mode >= 0 ? " | " + modeName(entry.mode) : ""));
		} else {
			infoText.text = ok + " / " + entries.length + " file(s) decoded with the current key"
				+ (bytecodeOnly > 0 ? " (" + bytecodeOnly + " bytecode only)" : "")
				+ (failed > 0 ? ", " + failed + " failed" : "");
		}

		rebuildPreview();

		if (failed > 0)
			status("Decoded " + ok + " of " + entries.length + " file(s); " + failed + " failed (see the preview blocks).");
		else
			status("Decoded " + ok + " file(s).");
	}

	function modeName(mode:Int):String {
		switch (mode) {
			case ScriptCrypto.MODE_BYTECODE: return "encrypted bytecode";
			case ScriptCrypto.MODE_BOTH: return "bytecode + source backup";
			case ScriptPackager.MODE_OBFUSCATED: return "VM bytecode, no key";
			case 0: return "encrypted source";
		}
		return "unknown";
	}

	// ------------------------------------------------------------------- preview

	function clearPreviewBlocks() {
		for (label in previewLabels) {
			label.visible = false;
			remove(label, true);
			label.destroy();
		}
		previewLabels = [];

		for (entry in entries)
			entry.label = null;

		if (scrollBar != null) {
			remove(scrollBar, true);
			scrollBar.destroy();
			scrollBar = null;
		}

		scroll = 0;
		contentHeight = 0;
	}

	function rebuildPreview() {
		clearPreviewBlocks();

		if (entries.length == 0) {
			previewHeader.text = "Preview - nothing loaded";
			return;
		}

		var y = 0.0;
		for (entry in entries) {
			var label = new UIText(viewX, viewY, viewW, previewTextFor(entry), 13, 0xFFFFFFFF, false);
			label.wordWrap = true;
			add(label);
			previewLabels.push(label);

			var h = Math.ceil(label.textField.textHeight) + 6;
			if (h < 20) h = 20;

			entry.label = label;
			entry.top = y;
			entry.blockHeight = h;
			y += h + BLOCK_GAP;
		}

		contentHeight = y - BLOCK_GAP;
		if (contentHeight < 0) contentHeight = 0;

		if (contentHeight > viewH) {
			var length = contentHeight - viewH;
			var size = (viewH / contentHeight) * viewH;
			if (size < 24) size = 24;
			if (size > viewH) size = viewH;

			var barX = 10 + (FlxG.width - 20) - 34;
			scrollBar = new UIScrollBar(barX, viewY, length, -size * 0.5, size, 20, Std.int(viewH));
			scrollBar.alpha = 1;
			scrollBar.visible = currentTab == TAB_SCRIPTS;
			scrollBar.active = currentTab == TAB_SCRIPTS; // 修复：动态创建时同步交互状态
			scrollBar.onChange = function(v) {
				setScroll(v);
				if (scrollBar != null) scrollBar.start = scroll - scrollBar.size * 0.5;
			};
			add(scrollBar);
		}

		applyScroll();
	}

	function previewTextFor(entry:ScriptEntry):String {
		var head = "// " + entry.path;
		if (entry.error != null)
			return head + "\n// ERROR: " + entry.error;

		if (entry.source != null) {
			var body = normalizeNewlines(entry.source);
			var note = entry.mode >= 0 ? "// " + modeName(entry.mode) + ", " + entry.bytes.length + " bytes\n" : "";
			return head + "\n" + note + body;
		}

		return head + "\n// " + entry.info
			+ "\n// No source text is embedded in this file; only the CNE virtual machine can execute it."
			+ "\n// Function prototypes: " + entry.functions
			+ "\n// Total size: " + (entry.bytes == null ? 0 : entry.bytes.length) + " bytes";
	}

	function normalizeNewlines(text:String):String {
		if (text == null) return "";
		text = StringTools.replace(text, "\r\n", "\n");
		return StringTools.replace(text, "\r", "\n");
	}

	function setScroll(value:Float) {
		var maxScroll = contentHeight - viewH;
		if (maxScroll < 0) maxScroll = 0;
		if (value < 0) value = 0;
		if (value > maxScroll) value = maxScroll;
		scroll = value;
		applyScroll();
	}

	function applyScroll() {
		if (entries.length == 0) return;

		var onTab = currentTab == TAB_SCRIPTS;
		for (entry in entries) {
			var label = entry.label;
			if (label == null) continue;
			if (!onTab) {
				label.visible = false;
				continue;
			}

			var v = scroll - entry.top;
			var from = v < 0 ? 0 : v;
			var to = v + viewH;
			if (to > entry.blockHeight) to = entry.blockHeight;

			if (to <= from) {
				label.visible = false;
				continue;
			}

			label.visible = true;
			label.offset.y = v;

			var clip = label.clipRect;
			if (clip == null) clip = new FlxRect();
			clip.set(0, from, viewW, to - from);
			label.clipRect = clip;
		}

		var current = topEntryAt(scroll);
		if (current == null) {
			previewHeader.text = "Preview - " + entries.length + " script(s)";
		} else {
			var index = entries.indexOf(current) + 1;
			var suffix = entries.length > 1 ? " (" + index + "/" + entries.length + ")" : "";
			previewHeader.text = "Preview - " + current.fileName() + suffix;
		}
	}

	function topEntryAt(value:Float):ScriptEntry {
		for (entry in entries) {
			if (value + 0.5 >= entry.top && value < entry.top + entry.blockHeight + BLOCK_GAP)
				return entry;
		}
		return entries.length > 0 ? entries[entries.length - 1] : null;
	}

	// --------------------------------------------------------------- file output

	function encryptAndSave() {
		var targets = new Array<ScriptEntry>();
		for (entry in entries)
			if (entry.source != null && entry.bytes != null)
				targets.push(entry);

		if (targets.length == 0) {
			status(entries.length == 0 ? "No script loaded." : "No loaded file has source text (bytecode only).");
			return;
		}

		if (entries.length == 1) {
			encryptSingle(targets[0]);
			return;
		}

		askForDirectory("Select the folder for the encrypted scripts", function(dir:String) {
			var saved = 0;
			var failed = 0;
			var anyCustom = false;
			var notes = new StringBuf();

			for (entry in targets) {
				var outPath = dir + "/" + entry.baseName() + "_encrypted.hxb";
				var pass = keyForEncrypt(entry);
				if (currentMode != 1 && usesCustomKey(entry, pass)) anyCustom = true;
				try {
					var bytes = packEntry(entry, pass);
					File.saveBytes(outPath, bytes);
					saved++;
				} catch(e:Dynamic) {
					failed++;
					notes.add("\n" + entry.fileName() + ": " + Std.string(e));
				}
			}

			var note = anyCustom ? " Remember to put the keys used for these files into script_key.txt (next to the executable) or the engine will not be able to load them." : "";
			if (failed > 0)
				status("Saved " + saved + " file(s) to " + dir + "; " + failed + " failed." + notes.toString());
			else
				status("Saved " + saved + " encrypted script(s) to " + dir + "." + note);
		});
	}

	function encryptSingle(entry:ScriptEntry) {
		var pass = keyForEncrypt(entry);
		var bytes:Bytes = null;
		var usedBytecode = false;

		try {
			bytes = packEntry(entry, pass);
			usedBytecode = currentMode != 0;
		} catch(e:Dynamic) {
			status("Failed to encrypt: " + Std.string(e));
			return;
		}

		var defaultPath = siblingPath(entry.path, "hxb", "_encrypted");
		var dialog = new FileDialog();
		dialog.onSelect.add(function(outPath:String) {
			fileDialogOpen = false;
			try {
				File.saveBytes(outPath, bytes);
				var note = (currentMode != 1 && usesCustomKey(entry, pass)) ? " Remember to add this key for " + entry.fileName() + " in script_key.txt (next to the executable) or the engine will not be able to load it." : "";
				status('Saved ' + (usedBytecode ? "bytecode" : "encrypted source") + ' script to ' + outPath + ' (' + bytes.length + ' bytes).' + note);
			} catch(e:Dynamic) {
				status("Failed to save: " + Std.string(e));
			}
		});
		dialog.onCancel.add(function() fileDialogOpen = false);
		fileDialogOpen = true;
		if (!dialog.browse(SAVE, "*.hxb", defaultPath, "Save Encrypted Script")) {
			fileDialogOpen = false;
			status("This platform does not support file dialogs.");
		}
	}

	function packEntry(entry:ScriptEntry, pass:String):Bytes {
		if (entry.source == null) throw "This file has no source text.";

		if (currentMode == 1) {
			// Keyless bytecode: the VM runs it without any password and the file
			// still contains no readable source text.
			try {
				return ScriptPackager.packObfuscatedSource(entry.source, entry.fileName());
			} catch(e:Dynamic) {
				status('Bytecode compilation of ' + entry.fileName() + ' failed, falling back to encrypted source: ' + Std.string(e));
				return ScriptPackager.packSource(entry.source, pass);
			}
		}

		if (currentMode == 2) {
			try {
				return ScriptPackager.packBytecode(entry.source, entry.fileName(), pass);
			} catch(e:Dynamic) {
				status('Bytecode compilation of ' + entry.fileName() + ' failed, falling back to encrypted source: ' + Std.string(e));
			}
		}

		return ScriptPackager.packSource(entry.source, pass);
	}

	function saveDecrypted() {
		var targets = new Array<ScriptEntry>();
		for (entry in entries)
			if (entry.source != null)
				targets.push(entry);

		if (targets.length == 0) {
			status(entries.length == 0 ? "No script loaded." : "No loaded file has source text (bytecode only).");
			return;
		}

		if (entries.length == 1) {
			var entry = targets[0];
			var defaultPath = siblingPath(entry.path, "hx", "_decrypted");
			var dialog = new FileDialog();
			dialog.onSelect.add(function(outPath:String) {
				fileDialogOpen = false;
				try {
					File.saveContent(outPath, entry.source);
					status("Saved decrypted source to " + outPath + ".");
				} catch(e:Dynamic) {
					status("Failed to save: " + Std.string(e));
				}
			});
			dialog.onCancel.add(function() fileDialogOpen = false);
			fileDialogOpen = true;
			if (!dialog.browse(SAVE, "*.hx;*.hscript;*.hsc;*.hxs", defaultPath, "Save Decrypted Source")) {
				fileDialogOpen = false;
				status("This platform does not support file dialogs.");
			}
			return;
		}

		askForDirectory("Select the folder for the decrypted scripts", function(dir:String) {
			var saved = 0;
			var failed = 0;
			var notes = new StringBuf();
			for (entry in targets) {
				var outPath = dir + "/" + entry.baseName() + "_decrypted.hx";
				try {
					File.saveContent(outPath, entry.source);
					saved++;
				} catch(e:Dynamic) {
					failed++;
					notes.add("\n" + entry.fileName() + ": " + Std.string(e));
				}
			}

			if (failed > 0)
				status("Saved " + saved + " file(s) to " + dir + "; " + failed + " failed." + notes.toString());
			else
				status("Saved " + saved + " decrypted script(s) to " + dir + ".");
		});
	}

	function askForDirectory(title:String, callback:String->Void) {
		var dialog = new FileDialog();
		dialog.onSelect.add(function(dir:String) {
			fileDialogOpen = false;
			if (dir == null) return;
			dir = normalizeDirectory(dir);
			if (dir == null) {
				status("Invalid folder.");
				return;
			}
			callback(dir);
		});
		dialog.onCancel.add(function() fileDialogOpen = false);

		fileDialogOpen = true;
		if (!dialog.browse(OPEN_DIRECTORY, null, lastDirectory, title)) {
			fileDialogOpen = false;
			status("This platform does not support directory dialogs.");
		}
	}

	// ------------------------------------------------------------------- helpers

	/**
	 * Every key worth trying for one file, in order: the password typed into the
	 * field, the key script_key.txt maps to this script, then the global key.
	 */
	function keyCandidates(entry:ScriptEntry):Array<String> {
		var keys:Array<String> = [];
		var typed = getPasswordInput();
		if (typed != null) keys.push(typed);
		if (entry != null) keys.push(ScriptCrypto.getPassword(entry.path));
		keys.push(ScriptCrypto.getPassword());

		var unique:Array<String> = [];
		for (key in keys)
			if (key != null && key.length > 0 && unique.indexOf(key) < 0)
				unique.push(key);
		return unique;
	}

	/**
	 * Key used when writing a mod pack: the Key field of the token tool wins, then the
	 * key script_key.txt (or the engine) has for that pack name. Mod packs never use
	 * the Password field of the Scripts tab.
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

	/**
	 * Key used when writing this file: a password typed into the field wins,
	 * otherwise the key script_key.txt maps to this script is used so a mod can
	 * keep one key per script.
	 */
	function keyForEncrypt(entry:ScriptEntry):String {
		var typed = getPasswordInput();
		if (typed != null && typed != ScriptCrypto.getPassword())
			return typed;
		return ScriptCrypto.getPassword(entry == null ? null : entry.path);
	}

	/** True when the file is written with a key no key file knows about. */
	function usesCustomKey(entry:ScriptEntry, pass:String):Bool {
		var expected = ScriptCrypto.getPassword(entry == null ? null : entry.path);
		return pass != null && pass != expected;
	}

	function getPasswordInput():String {
		var pass = passwordBox.label.text;
		if (pass == null) return null;
		pass = StringTools.trim(pass);
		if (pass.length <= 0) return null;
		return pass;
	}

	function siblingPath(path:String, ext:String, suffix:String = ""):String {
		if (path == null) return "script" + suffix + "." + ext;
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