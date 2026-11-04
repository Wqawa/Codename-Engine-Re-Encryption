package funkin.menus;

import funkin.editors.ui.UISprite;

using flixel.util.FlxSpriteUtil;

/**
 * Read-only progress bar.
 *
 * Drawn with the same rounded shapes and the same colours the engine's own UISlider
 * uses (light rim, near-black groove, purple fill), so a progress screen has the bar
 * the editor already has instead of a hand-mixed blue rectangle. No input handling:
 * it is a readout, not a control.
 */
class PopupProgress extends UISprite {
	public var barWidth(default, null):Int = 100;
	public var barHeight(default, null):Int = 12;

	/** UI fill colour, the one UISlider tints its bar with. */
	public static inline var FILL:Int = 0xFF67009B;

	public var value(default, set):Float = 0;

	function set_value(v:Float):Float {
		if (v < 0) v = 0;
		else if (v > 1) v = 1;
		// keep a sliver of the rounded left cap, otherwise an empty bar looks broken
		fill.scale.x = v < 0.004 ? 0.004 : v;
		return value = v;
	}

	var fill:UISprite;

	public function new(x:Float, y:Float, width:Int, height:Int = 12) {
		super(x, y);
		barWidth = width < 24 ? 24 : width;
		barHeight = height < 8 ? 8 : height;
		// not a control: it must never take hover away from a field or a button
		selectable = false;
		autoAlpha = false;

		final radius = barHeight / 2;
		makeGraphic(barWidth, barHeight, 0x00000000, true);
		this.drawRoundRect(0, 0, barWidth, barHeight, radius, radius, 0xFFC0C0C0);
		this.drawRoundRect(1, 1, barWidth - 2, barHeight - 2, radius, radius, 0xFF140013);

		fill = new UISprite(x + 1, y + 1);
		fill.makeGraphic(barWidth - 2, barHeight - 2, 0x00000000, true);
		fill.drawRoundRect(0, 0, barWidth - 2, barHeight - 2, radius - 1, radius - 1, 0xFFFFFFFF);
		// scale around the left edge, otherwise the fill grows from the middle outwards
		fill.origin.set(0, 0);
		fill.colorTransform.color = FILL;
		fill.selectable = false;
		fill.autoAlpha = false;
		members.push(fill);

		value = 0;
	}

	override function update(elapsed:Float) {
		// members are drawn at their own position, so the fill follows the bar here
		fill.setPosition(x + 1, y + 1);
		super.update(elapsed);
	}

	// UISprite does not pass alpha or visibility on to its members, so the fill has to
	// be told as well - otherwise a faded-out bar keeps a fully opaque purple fill
	override function set_alpha(value:Float):Float {
		if (fill != null) fill.alpha = value;
		return super.set_alpha(value);
	}

	override function set_visible(value:Bool):Bool {
		if (fill != null) fill.visible = value;
		return super.set_visible(value);
	}
}
