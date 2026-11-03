package funkin.options.categories;

import funkin.savedata.FunkinSave;

class MiscOptions extends TreeMenuScreen {
	public function new() {
		super('optionsTree.miscellaneous-name', 'optionsTree.miscellaneous-desc', 'MiscOptions.');

		var state = funkin.backend.assets.ProtectionState;

		// Locked while a pack asks for protection mode: the value is already forced off,
		// and a box that can be ticked would look like the setting still works.
		var dev = new Checkbox(getNameID('devMode'), getDescID('devMode'), 'devMode');
		dev.locked = state.isLocked();
		add(dev);

		// Live only for a pack that carries a marker; plain mods leave it grey and off.
		// Both directions cost the password - turning protection back on is not something
		// a player should be able to do just because they unlocked it once.
		var protect:Checkbox = null;
		protect = new Checkbox(getNameID('protectionMode'), getDescID('protectionMode'), 'protectionMode', function() {
			var turningOff = state.active;
			// select() already flipped the box; put it back until the password agrees
			protect.checked = turningOff;
			Options.protectionMode = turningOff;

			Logs.trace('Protection option clicked: active=' + state.active + ' available=' + state.available
				+ ' dialogOpen=' + (FlxG.state != null && FlxG.state.subState != null), INFO);

			if (!state.available || FlxG.state == null) return;
			// one dialog at a time: a second click would stack another on top
			if (FlxG.state.subState != null) return;

			FlxG.state.openSubState(new funkin.editors.ui.UIWarningSubstate(
				turningOff ? "Disable Protection Mode" : "Enable Protection Mode",
				'Type the password for "${state.owner()}".',
				[
					{
						label: turningOff ? "Disable" : "Enable",
						color: 0x969533,
						onClick: function(dialog) {
							// the dialog hands back the text and nothing else; whether it is
							// the right password is decided here
							if (!state.verify(dialog.inputValue())) {
								dialog.keepOpen = true;
								return;
							}
							state.setActive(!turningOff);
							// the boxes were built before the state changed, so re-sync them
							// now instead of making the player leave the menu and come back
							refreshProtectionBoxes(protect, dev);
						}
					},
					{label: "Cancel", color: 0x969533, onClick: function(_) {}}
				],
				false,
				true
			));
		});
		protect.locked = !state.available;
		add(protect);

		add(new Checkbox(getNameID('allowConfigWarning'), getDescID('allowConfigWarning'), 'allowConfigWarning'));
		add(new Checkbox(getNameID('wrapDecryptedPacks'), getDescID('wrapDecryptedPacks'), 'wrapDecryptedPacks'));
		#if UPDATE_CHECKING
		add(new Checkbox(getNameID('betaUpdates'), getDescID('betaUpdates'), 'betaUpdates'));
		add(new TextOption(getNameID('checkForUpdates'), getDescID('checkForUpdates'), () -> {
			var report = funkin.backend.system.updating.UpdateUtil.checkForUpdates(true);
			if (report.newUpdate) FlxG.switchState(new funkin.backend.system.updating.UpdateAvailableScreen(report));
			else {
				CoolUtil.playMenuSFX(CANCEL);
				//updateDescText(translate('checkForUpdates-noUpdateFound'));
			}
		}));
		#end

		add(new Separator());
		add(new TextOption(getNameID('resetSaveData'), getDescID('resetSaveData'), () -> {
			FunkinSave.save.erase();
			FunkinSave.highscores.clear();
			FunkinSave.flush();
		}));
	}

	/**
	 * Pushes the current protection state into the two checkboxes.
	 *
	 * Both are built once when the menu opens. Changing the state from the dialog without
	 * this leaves them showing what was true a moment ago: devMode stays grey after being
	 * unlocked, and the protection box keeps the old tick.
	 */
	static function refreshProtectionBoxes(protect:Checkbox, dev:Checkbox):Void {
		var state = funkin.backend.assets.ProtectionState;
		protect.checked = Options.protectionMode = state.active;
		protect.locked = !state.available;
		dev.checked = Options.devMode;
		dev.locked = state.isLocked();
	}
}