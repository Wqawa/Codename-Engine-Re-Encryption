package funkin.editors.ui;

import flixel.math.FlxRect;
import funkin.backend.utils.NativeAPI.CodeCursor;
import openfl.ui.MouseCursor;

@:allow(funkin.editors.ui.UIState)
@:allow(funkin.editors.ui.UIUtil)
class UISprite extends FlxSprite {
	public var members:Array<FlxBasic> = [];

	private var __lastDrawCameras:Array<FlxCamera> = [];
	private var __rect:FlxRect = new FlxRect();

	private var __oldDefCams:Array<FlxCamera>;

	public var hovered:Bool = false;
	public var hoveredByChild:Bool = false;
	public var pressed:Bool = false;

	public var canBeHovered:Bool = true;

	public var hoverCallback:Void->Void = null;

	public var cursor:CodeCursor = ARROW;

	public var focused(get, set):Bool;
	public var selectable:Bool = true;
	public var autoAlpha:Bool = true;

	private function get_focused():Bool {
		var state = UIState.state;
		return state != null && state.currentFocus == cast this;
	}

	private function set_focused(b:Bool):Bool {
		var state = UIState.state;
		// no state to hold the focus (a prompt opened on a plain state): nothing to record
		if (state == null) return b;
		if (get_focused()) {
			if (!b)
				state.currentFocus = null;
		} else {
			if (b)
				state.currentFocus = cast this;
		}
		return b;
	}

	public override function update(elapsed:Float) {
		hovered = false;
		pressed = false;
		hoveredByChild = false;

		super.update(elapsed);
		if (selectable)
			updateButton();

		@:privateAccess {
			__oldDefCams = FlxCamera._defaultCameras;
			FlxCamera._defaultCameras = cameras;

			for(m in members)
				if(m.exists && m.active)
					m.update(elapsed);

			FlxCamera._defaultCameras = __oldDefCams;
		}

	}

	public override function draw() {
		drawSuper();
		drawMembers();
	}

	public function drawSuper() {
		super.draw();
		__lastDrawCameras = cameras.copy();
	}

	public function drawMembers() {
		@:privateAccess {
			__oldDefCams = FlxCamera._defaultCameras;
			FlxCamera._defaultCameras = cameras;

			for(m in members)
				if(m.exists && m.visible)
					m.draw();

			FlxCamera._defaultCameras = __oldDefCams;
		}
	}

	public override function destroy() {
		super.destroy();
		members = FlxDestroyUtil.destroyArray(members);
	}

	public function updateButton() {
		if(canBeHovered)
			updateButtonHandler();
		else {
			if(FlxG.mouse.pressed) {
				updateButtonHandler();
			}
		}
	}

	public function updateButtonHandler() {
		updateSpriteRect();
		registerHover(__rect);
	}

	/**
	 * Reports this sprite's hover for the current frame.
	 *
	 * Inside an editor the state is the one that remembers the hovered sprite and runs
	 * the callback after every widget has reported, which is how overlapping widgets
	 * agree on who is on top. A prompt opened on a plain state (the mod switch prompt,
	 * the unsaved changes prompt when the window is closed) has no such state, so each
	 * widget answers for itself instead of dereferencing a null UIState.
	 */
	public function registerHover(rect:FlxRect) {
		var state = UIState.state;
		if (state != null) {
			state.updateRectButtonHandler(this, rect, onHovered);
			return;
		}
		selfHover(rect);
	}

	static var __hoverPoint:FlxPoint = new FlxPoint();

	/** Hit test against the cameras this sprite was drawn through, no state needed. */
	function selfHover(rect:FlxRect) {
		for (camera in __lastDrawCameras) {
			if (camera == null) continue;
			// getViewPosition is the name flixel 5 wants; getScreenPosition only survived as
			// a deprecated alias, and this is new code so it uses the current one
			var pos = FlxG.mouse.getViewPosition(camera, __hoverPoint);
			var left = rect.x - camera.scroll.x * scrollFactor.x;
			var top = rect.y - camera.scroll.y * scrollFactor.y;
			if (pos.x > left && pos.x < left + rect.width && pos.y > top && pos.y < top + rect.height) {
				onHovered();
				return;
			}
		}
	}

	/**
	 * Called whenever the sprite is being hovered by the mouse.
	 */
	public function onHovered() {
		hovered = true;
		if (FlxG.mouse.pressed)
			pressed = true;
		if (hoverCallback != null)
			hoverCallback();
	}

	public function updateSpriteRect() {
		__rect.set(x, y, width, height);
	}
}