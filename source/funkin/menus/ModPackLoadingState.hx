package funkin.menus;

import flixel.FlxG;
import flixel.FlxSprite;
import funkin.backend.assets.ModPackCrypto;
import funkin.backend.system.MainState;
import funkin.editors.ui.UIState;
import funkin.editors.ui.UIText;
import haxe.io.Path;

/**
 * Shown while an encrypted mod pack is decrypted, so a big pack does not freeze
 * the game for a few seconds with a black screen.
 *
 * The work runs on a worker thread (ModPackCrypto.startPrepare) and this state
 * only draws the progress it reports. When every pack opened, the loader runs
 * again and this time finds the decrypted copies in the cache; when some pack
 * failed, the key prompt is shown for those packs only.
 */
class ModPackLoadingState extends UIState {
	public var packs:Array<String> = [];
	public var bar:FlxSprite;
	public var percentText:UIText;
	public var packText:UIText;
	public var hintText:UIText;
	public var finished:Bool = false;
	public var startedAt:Float = 0;
	public var barWidth:Int = 0;

	public function new(packs:Array<String>) {
		super();
		this.packs = packs == null ? [] : packs;
	}

	override function create() {
		super.create();
		FlxG.camera.bgColor = 0xFF101017;

		var names = "";
		for (p in packs) {
			var n = Path.withoutExtension(Path.withoutDirectory(p));
			names += (names.length == 0 ? "" : ", ") + n;
		}
		if (packs.length > 4) names = packs.length + " mod packs";

		add(new UIText(40, 60, FlxG.width - 80, "Unlocking mod pack", 26, 0xFFFFE066, false));
		add(new UIText(40, 100, FlxG.width - 80,
			"Decrypting the pack into memory so the engine can read it. Nothing is written to disk,\n"
			+ "so this pass runs on every start and for as long as the pack stays loaded.",
			14, 0xFFB0B0BE, false));

		add(packText = new UIText(40, 168, FlxG.width - 80, "Pack: " + names, 16, 0xFFFFFFFF, false));

		barWidth = FlxG.width - 80;
		add(new FlxSprite(40, 210).makeGraphic(barWidth, 22, 0xFF2A2A34));
		bar = new FlxSprite(43, 213).makeGraphic(Std.int(barWidth - 6), 16, 0xFF61C4FF);
		// scale around the left edge, otherwise the bar grows from the middle outwards
		bar.origin.set(0, 0);
		bar.scale.x = 0.001;
		add(bar);

		add(percentText = new UIText(40, 244, FlxG.width - 80, "0%", 15, 0xFF9BE28C, false));
		add(hintText = new UIText(40, 274, FlxG.width - 80, "Working...", 13, 0xFF7A7A88, false));

		startedAt = 0;
		ModPackCrypto.startPrepare(packs);
	}

	override function update(elapsed:Float) {
		super.update(elapsed);

		var p = ModPackCrypto.progress;
		if (p < 0) p = 0;
		if (p > 1) p = 1;
		bar.scale.x = Math.max(0.001, p);
		percentText.text = Std.int(p * 100) + "%" + (ModPackCrypto.progressLabel.length > 0 ? "  -  " + ModPackCrypto.progressLabel : "");

		// a tiny animated marker, so the screen clearly still runs while a single
		// big entry is being decrypted
		startedAt += elapsed;
		var dots = Std.int(startedAt * 2) % 4;
		hintText.text = "Working" + ".".repeat(dots) + "  (the window may stop responding for a moment)";

		if (!finished && ModPackCrypto.prepareDone && !ModPackCrypto.preparing) {
			finished = true;
			if (ModPackCrypto.prepareFailed.length > 0) {
				var failed = ModPackCrypto.prepareFailed.copy();
				// drop the rejected key so the prompt does not retry it every frame
				for (p in failed) ModPackCrypto.clearSessionKey(p);
				// the key passed the quick check but decryption still failed: say so
				FlxG.switchState(new ModPackKeyState(failed,
					"Wrong password: the pack could not be decrypted. Check the password and try again."));
			}
			else
				FlxG.switchState(new MainState());
		}
	}
}
