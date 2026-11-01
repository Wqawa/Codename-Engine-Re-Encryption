package funkin.menus;

import flixel.FlxG;
import flixel.FlxSprite;
import funkin.backend.assets.ZipEditCache;
import funkin.editors.ui.UIState;
import funkin.editors.ui.UIText;

/**
 * Shown while the staged files of a packed mod are merged into its pack.
 *
 * Merging copies every entry of the archive and re-encrypts it when the pack is
 * encrypted, so on a big mod it is seconds of work - and doing that from the button's
 * callback left the window frozen with no sign of life. The work runs on a worker thread
 * (ZipEditCache.startMergeAsync) and this screen only reports it, then hands over to
 * whatever the caller wanted to do next (usually the mod switch).
 *
 * A failed merge still continues: the staged files are left on disk on purpose, so the
 * player keeps their work, and the error is shown long enough to read.
 */
class ModPackMergeState extends UIState {
	static inline var MARGIN:Int = 40;
	static inline var MIN_VISIBLE:Float = 0.4;
	static inline var ERROR_VISIBLE:Float = 3;

	public var mod:String;
	public var next:Void->Void;

	public var statusText:UIText;
	public var hintText:UIText;
	public var done:Bool = false;
	public var waited:Float = 0;
	public var finishedAt:Float = -1;

	public function new(mod:String, next:Void->Void) {
		super();
		this.mod = mod;
		this.next = next;
	}

	override function create() {
		super.create();
		FlxG.camera.bgColor = 0xFF101017;

		final w = FlxG.width - MARGIN * 2;
		add(new UIText(MARGIN, 176, w, "Merging staged files", 34, 0xFFFFE066, false));
		add(new UIText(MARGIN, 226, w,
			'The files saved for "$mod" are written into its pack now.\n'
			+ "The whole archive is rewritten, so this takes a moment on a big mod.",
			14, 0xFFB0B0BE, false));

		add(statusText = new UIText(MARGIN, 300, w, ZipEditCache.mergeMessage, 15, 0xFF9BE28C, false));
		add(hintText = new UIText(MARGIN, 336, w, "", 13, 0xFF7A7A88, false));
		add(new FlxSprite(MARGIN, FlxG.height - 40).makeGraphic(w, 2, 0xFF2A2A34));

		ZipEditCache.startMergeAsync(mod);
	}

	override function update(elapsed:Float) {
		super.update(elapsed);
		waited += elapsed;

		if (statusText != null) {
			statusText.text = ZipEditCache.mergeMessage;
			statusText.color = ZipEditCache.mergeFailed ? 0xFFFF5A5A : 0xFF9BE28C;
		}
		if (hintText != null) {
			var dots = ".".repeat(Std.int(waited * 2) % 4);
			hintText.text = ZipEditCache.mergeFailed
				? "The staged files were left on disk, so nothing was lost."
				: "Working" + dots;
		}

		if (!ZipEditCache.mergeDone) {
			finishedAt = -1;
			return;
		}
		if (finishedAt < 0) finishedAt = waited;

		// a failed merge is worth reading; a successful one only needs a beat so the
		// screen does not flash
		var hold = ZipEditCache.mergeFailed ? ERROR_VISIBLE : MIN_VISIBLE;
		if (waited - finishedAt < hold) return;

		if (done) return;
		done = true;
		var target = next;
		next = null;
		if (target != null) target();
	}
}
