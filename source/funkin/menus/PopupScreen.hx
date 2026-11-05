package funkin.menus;

import flixel.FlxG;
import flixel.FlxSprite;
import funkin.editors.ui.UIButton;
import funkin.editors.ui.UISliceSprite;
import funkin.editors.ui.UIState;
import funkin.editors.ui.UIText;

/** One button of the footer row. */
typedef PopupButton = {
	var label:String;
	var onClick:Void->Void;
	/** Defaults to BUTTON_W; widen it when the label does not fit. */
	var ?width:Int;
	/** Tints the grayscale button frames, the way UIWarningSubstate colours its own. */
	var ?color:Int;
}

/**
 * A whole screen that looks like one of the engine's own popups: dimmed backdrop, a
 * `normal-popup` 9-slice with its title bar, and the buttons in the row
 * UIWarningSubstate uses (30 px title bar, 25 px padding, 160x30 buttons).
 *
 * The startup screens used to draw their own near-black background, yellow headings
 * and a hand-mixed blue bar, which matched nothing else in the game. Everything here
 * comes out of the editor UI set - UISliceSprite, UIText, UIButton, UITextBox - with
 * the engine's own accent colours, so these screens look like the rest of Codename.
 *
 * The panel grows around its content and is centred afterwards. Subclasses lay their
 * rows out with row()/place() instead of absolute 1280x720 coordinates, so the same
 * screen works at any window size.
 */
class PopupScreen extends UIState {
	/** Title bar baked into the normal-popup skin. */
	public static inline var TITLE_H:Int = 30;
	/** Inner padding, same as UIWarningSubstate. */
	public static inline var PAD:Int = 25;
	public static inline var ROW_GAP:Float = 10;

	public static inline var BUTTON_W:Int = 160;
	public static inline var BUTTON_H:Int = 30;
	public static inline var BUTTON_GAP:Int = 20;

	/** White body text; the accents are the ones UIWarningSubstate uses. */
	public static inline var COLOR_TEXT:Int = 0xFFFFFFFF;
	public static inline var COLOR_WARN:Int = 0xFFFFFF00;
	public static inline var COLOR_ERROR:Int = 0xFFFF0000;
	public static inline var COLOR_OK:Int = 0x969533;
	public static inline var COLOR_INFO:Int = 0xFF4D9EFF;
	/** Tint of a destructive button, the one the engine's own close prompt uses for "Exit Game". */
	public static inline var COLOR_DANGER:Int = 0xFF6B6B;

	static inline var MAX_PANEL_W:Int = 880;
	static inline var MIN_PANEL_W:Int = 320;
	static inline var SHADE:Int = 0xB4000000;

	public var panel:UISliceSprite;
	public var titleText:UIText;
	public var buttons:Array<UIButton> = [];
	/** Percentage label of addProgress(), if that was used. */
	public var progressLabel:UIText;

	public var contentX(default, null):Float = 0;
	public var contentW(default, null):Int = 0;

	// next free row, measured from the top of the panel; endPanel() shifts everything
	// down to where the panel ends up
	var cursor:Float = 0;
	var panelW:Int = 0;
	var moved:Array<FlxSprite> = [];
	var buttonDefs:Array<PopupButton> = null;
	/** Current vertical shift of the content; see setContentOffset(). */
	var contentOffset:Float = 0;

	override function create() {
		super.create();
		// the shade sits on a black camera, so every screen is dimmed by the same amount
		FlxG.camera.bgColor = 0xFF000000;
		var shade = new FlxSprite().makeSolid(FlxG.width, FlxG.height, SHADE);
		shade.scrollFactor.set(0, 0);
		add(shade);
	}

	/**
	 * Creates the popup. Call this first in create(), then add rows, then endPanel().
	 *
	 * @param width Panel width; by default the smaller of 880 and the window minus a
	 *              margin, so long paragraphs do not wrap into a narrow column.
	 */
	public function beginPanel(title:String, ?width:Int):Void {
		panelW = width == null ? Std.int(Math.min(FlxG.width - 160, MAX_PANEL_W)) : width;
		if (panelW > FlxG.width - 24) panelW = FlxG.width - 24;
		if (panelW < MIN_PANEL_W) panelW = MIN_PANEL_W;

		panel = new UISliceSprite(Std.int((FlxG.width - panelW) / 2), 0, panelW, 120, 'editors/ui/normal-popup');
		add(panel);
		moved.push(panel);

		if (title != null && title.length > 0) {
			titleText = new UIText(panel.x + PAD, 0, panelW - PAD * 2, title, 15, COLOR_TEXT);
			add(titleText);
			moved.push(titleText);
		}

		contentX = panel.x + PAD;
		contentW = panelW - PAD * 2;
		cursor = TITLE_H + 16;
	}

	/**
	 * Reserves a row of `height` px and returns its top edge.
	 *
	 * The value is in final screen coordinates only for the x axis; the panel is still
	 * at y = 0 here, and endPanel() moves every placed sprite into place.
	 */
	public function row(height:Float, ?gap:Float = PopupScreen.ROW_GAP):Float {
		var y = cursor;
		cursor += height + gap;
		return y;
	}

	/** Adds a sprite that endPanel() has to move along with the panel. */
	public function place<T:FlxSprite>(sprite:T):T {
		add(sprite);
		moved.push(sprite);
		return sprite;
	}

	/** A wrapping line of body text; the panel grows by its measured height. */
	public function addText(text:String, ?size:Int = 15, ?color:Int = PopupScreen.COLOR_TEXT, ?gap:Float = PopupScreen.ROW_GAP):UIText {
		var txt = new UIText(contentX, cursor, contentW, text, size, color);
		txt.wordWrap = true;
		place(txt);
		cursor += txt.height + gap;
		return txt;
	}

	/**
	 * A progress bar across the content width with its percentage on the right.
	 *
	 * @param labelW Width reserved for the percentage; 0 puts the bar across the whole row.
	 */
	public function addProgress(?height:Int = 14, ?labelW:Int = 56):PopupProgress {
		final barW = contentW - (labelW > 0 ? labelW + 12 : 0);
		final y = row(height, ROW_GAP);
		final bar = place(new PopupProgress(contentX, y, barW, height));

		if (labelW > 0) {
			progressLabel = new UIText(contentX + contentW - labelW, y, labelW, "0%", 13, COLOR_TEXT);
			progressLabel.alignment = RIGHT;
			// centre the label against the bar, not against the row
			progressLabel.y = y + ((height - progressLabel.height) / 2);
			place(progressLabel);
		}
		return bar;
	}

	public function setButtons(items:Array<PopupButton>):Void
		buttonDefs = items;

	/**
	 * Slides everything this screen laid out, panel and buttons included, by `offset` px.
	 *
	 * For screens that idle-animate: the file check bobs the way the crash overlay does,
	 * because a frame that keeps moving makes its hitches far less obvious. The shade stays
	 * put - only what the panel owns moves.
	 */
	public function setContentOffset(offset:Float):Void {
		final delta = offset - contentOffset;
		if (delta == 0) return;
		contentOffset = offset;
		for (sprite in moved) sprite.y += delta;
		for (button in buttons) button.y += delta;
	}

	/** Sizes and centres the panel around what was added, then builds the footer row. */
	public function endPanel():Void {
		if (panel == null) return;

		final hasButtons = buttonDefs != null && buttonDefs.length > 0;
		if (hasButtons) cursor += 8;

		var panelH = Std.int(cursor + (hasButtons ? BUTTON_H + PAD : PAD));
		final minH = TITLE_H + PAD * 2;
		if (panelH < minH) panelH = minH;

		panel.resize(panelW, panelH);
		var panelY = Std.int((FlxG.height - panelH) / 2);
		if (panelY < 8) panelY = 8;
		for (sprite in moved) sprite.y += panelY;

		if (titleText != null) titleText.y = panel.y + ((TITLE_H - titleText.height) / 2);

		if (hasButtons) buildButtons(panel.y + panelH - PAD - BUTTON_H);
	}

	function buildButtons(y:Float):Void {
		var total = 0;
		for (i in 0...buttonDefs.length) {
			final w = buttonDefs[i].width == null ? BUTTON_W : buttonDefs[i].width;
			total += w + (i > 0 ? BUTTON_GAP : 0);
		}

		var x = panel.x + Math.round((panelW - total) / 2);
		for (def in buttonDefs) {
			final w = def.width == null ? BUTTON_W : def.width;
			final button = new UIButton(x, y, def.label, def.onClick, w, BUTTON_H);
			if (def.color != null) {
				// the engine's way of colouring a button: tint the grayscale frames
				button.frames = Paths.getFrames('editors/ui/grayscale-button');
				button.color = def.color;
			}
			add(button);
			buttons.push(button);
			x += w + BUTTON_GAP;
		}
	}
}
