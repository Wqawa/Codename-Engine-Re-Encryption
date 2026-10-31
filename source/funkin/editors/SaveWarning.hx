package funkin.editors;

/**
 * The "unsaved changes" prompt.
 *
 * Shared by the editors and by anything else that has to ask before work is thrown
 * away: a packed mod with staged edits (ZipEditCache), the window closing, and a mod
 * switch.
 *
 * Every label goes through TU.translate with an English fallback. The editors'
 * language file is not guaranteed to be loaded when this prompt is shown - closing
 * the window from the title screen is one case - and a missing key used to render as
 * a literal "{saveWarning.warningTitle}" on screen.
 */
class SaveWarning {
	public static var showWarning(default, set):Bool;
	public static function set_showWarning(warning:Bool):Bool
		return WindowUtils.preventClosing = showWarning = warning;

	public static var selectionClass:Class<EditorTreeMenu> = null;
	public static var saveFunc:Void->Void = null;

	public static function init() {
		showWarning = false;

		WindowUtils.onClosing = function () {
			if (SaveWarning.showWarning) triggerWarning(true);
		}
	}

	public static var warningFunc:Bool->Void = null;
	public static function triggerWarning(?closingWindow:Bool = false) {
		if (warningFunc != null) warningFunc(closingWindow);

		// Not limited to UIState: the window can be closed from any state, and callers
		// other than the editors (a pending mod merge, for one) rely on this prompt too.
		if (FlxG.state == null) return;

		// The save warning labels live in the editors' language file. When that file did
		// not make it into the language map the dialog used to render the raw keys -
		// "{saveWarning.warningTitle}" and friends - with nothing in the log to explain it.
		// Say it once; the English fallbacks below keep the dialog readable.
		if (!TU.exists("saveWarning.cancel"))
			Logs.warn("The save warning labels are missing from the language map, showing English.", "Language");

		var title = TU.translate("saveWarning.warningTitle", null, "Unsaved Changes!");
		var message = TU.translate("saveWarning.warningDesc", null,
			"Your changes will be lost if you don't save them. (Can't be recovered)\n\n\nWould you like to Cancel?");

		FlxG.state.openSubState(new UIWarningSubstate(title, message, [
			{
				label: TU.translate("saveWarning.cancel", null, "Cancel"),
				color: 0x969533,
				onClick: function(_) {
					if (closingWindow) WindowUtils.resetClosing();
				}
			},
			{
				label: closingWindow
					? TU.translate("saveWarning.exitGame", null, "Exit Game")
					: TU.translate("saveWarning.exitToMenu", null, "Exit To Menu"),
				color: 0x969533,
				onClick: function(_) {
					if (closingWindow) exitGame();
					else leaveWithoutSaving();
				}
			},
			{
				label: closingWindow
					? TU.translate("saveWarning.saveAndExitGame", null, "Save & Exit Game")
					: TU.translate("saveWarning.saveAndExitToMenu", null, "Save & Exit To Menu"),
				color: 0x969533,
				onClick: function(_) {
					if (saveFunc != null) saveFunc();
					if (closingWindow) exitGame();
					else leaveWithoutSaving();
				}
			}
		], false));
	}

	static function leaveWithoutSaving():Void {
		if (selectionClass != null) FlxG.switchState(Type.createInstance(SaveWarning.selectionClass, []));
	}

	/**
	 * Closes the game, through the mod cleanup screen when a decrypted pack is still
	 * held.
	 *
	 * Merging the staged edits used to exit straight away, which skipped the wipe
	 * screen entirely - the merge prompt was swallowing the cleanup instead of handing
	 * over to it. The exit hook would still have wiped the buffers, but without the
	 * pass the player is told about.
	 */
	static function exitGame():Void {
		// clear the flag first: it holds preventClosing up, and the cleanup screen has to
		// be able to take this close over
		showWarning = false;
		WindowUtils.resetClosing();

		if (funkin.backend.assets.ModPackCrypto.needsCleanup() && FlxG.state != null) {
			FlxG.switchState(new funkin.menus.ModPackCleanupState());
			return;
		}
		openfl.system.System.exit(0);
	}

	public static inline function reset() {
		SaveWarning.showWarning = false;
		SaveWarning.selectionClass = null;
		SaveWarning.saveFunc = null;
		SaveWarning.warningFunc = null;
	}
}
