package funkin.menus;

import funkin.backend.assets.ZipEditCache;
import funkin.editors.ui.UIText;

/**
 * Shown while the staged files of a packed mod are merged into its pack.
 *
 * Merging copies every entry of the archive and re-encrypts it when the pack is
 * encrypted, so a big mod means seconds of work. That runs on a worker thread
 * (ZipEditCache.startMergeAsync); this screen only reports it and then hands over to
 * whatever the caller wanted to do next (usually the mod switch).
 *
 * A failed merge still continues: the staged files are left on disk on purpose, so the
 * player keeps their work.
 */
class ModPackMergeState extends PopupScreen {
	/** How long a finished merge stays up before the next screen, in seconds. */
	static inline var MIN_VISIBLE:Float = 0.4;
	static inline var ERROR_VISIBLE:Float = 3;

	public var mod:String;
	public var onDone:Void->Void;

	public var statusText:UIText;
	public var hintText:UIText;
	public var bar:PopupProgress;
	public var done:Bool = false;
	public var waited:Float = 0;
	public var finishedAt:Float = -1;
	var appliedMerge:Bool = false;

	public function new(mod:String, onDone:Void->Void) {
		super();
		this.mod = mod;
		this.onDone = onDone;
	}

	override function create() {
		super.create();

		beginPanel("Merging staged files", 720);
		addText('The files saved for "$mod" are written into its pack now. The whole archive is rewritten, '
			+ "so this takes a moment on a big mod.", 13, PopupScreen.COLOR_TEXT, 16);

		bar = addProgress(14);
		// the real message is only set once startMergeAsync runs, below
		statusText = addText("Reading the staged files", 13, PopupScreen.COLOR_INFO, 10);
		hintText = addText("Working", 13, PopupScreen.COLOR_TEXT, 0);
		endPanel();

		ZipEditCache.startMergeAsync(mod);
	}

	override function update(elapsed:Float) {
		super.update(elapsed);
		waited += elapsed;

		if (statusText != null) {
			statusText.text = ZipEditCache.mergeMessage;
			statusText.color = ZipEditCache.mergeFailed ? PopupScreen.COLOR_ERROR : PopupScreen.COLOR_INFO;
		}
		if (hintText != null) {
			var dots = ".".repeat(Std.int(waited * 2) % 4);
			hintText.text = ZipEditCache.mergeFailed
				? "The staged files were left on disk, so nothing was lost."
				: "Working" + dots;
		}
		if (bar != null) {
			bar.value = Math.min(1, ZipEditCache.mergeProgress);
			if (progressLabel != null) progressLabel.text = Std.int(bar.value * 100) + "%";
		}

		if (!ZipEditCache.mergeDone) {
			finishedAt = -1;
			return;
		}
		if (!appliedMerge) {
			appliedMerge = true;
			// the merge replaced the archive, so the copy decrypted from the old bytes must
			// not be handed to the loader any more. A failed merge left the file alone.
			if (!ZipEditCache.mergeFailed) ZipEditCache.forgetDecryptedCopy(mod);
		}
		if (finishedAt < 0) finishedAt = waited;

		// a failed merge is worth reading; a successful one only needs a beat
		var hold = ZipEditCache.mergeFailed ? ERROR_VISIBLE : MIN_VISIBLE;
		if (waited - finishedAt < hold) return;

		if (done) return;
		done = true;
		var target = onDone;
		onDone = null;
		if (target == null) return;
		// a broken switch must not leave the player on a screen that never moves again
		try {
			target();
		} catch (e:Dynamic) {
			Logs.error('The screen after the merge failed: ' + e);
		}
	}
}
