/* Disable Touchpad Swipe Gestures for GNOME Shell.
 *
 * GNOME Shell handles every touchpad swipe with >= 3 fingers
 * (swipeTracker.js: GESTURE_FINGER_COUNT = 3). This extension makes the shell
 * ignore all touchpad swipe gestures by reporting a finger count of 0, so an
 * external gesture daemon (gestures) can own 3- and 4-finger gestures.
 * Scrolling, tapping and clicking are unaffected.
 */

import Clutter from 'gi://Clutter';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

export default class DisableTouchpadSwipeExtension extends Extension {
    enable() {
        this._trackers = [
            Main.overview?._swipeTracker?._touchpadGesture,
            Main.wm?._workspaceAnimation?._swipeTracker?._touchpadGesture,
            Main.overview?._overview?._controls?._workspacesDisplay?._swipeTracker?._touchpadGesture,
        ].filter(tracker => tracker);

        this._trackers.forEach(tracker => {
            tracker._originalHandleEvent = tracker._handleEvent.bind(tracker);
            tracker._disableHandleEvent = (actor, event) => {
                if (event.type() === Clutter.EventType.TOUCHPAD_SWIPE) {
                    const realFingerCount = event.get_touchpad_gesture_finger_count;
                    event.get_touchpad_gesture_finger_count = () => 0;
                    try {
                        return tracker._originalHandleEvent(actor, event);
                    } finally {
                        event.get_touchpad_gesture_finger_count = realFingerCount;
                    }
                }
                return tracker._originalHandleEvent(actor, event);
            };

            global.stage.disconnectObject(tracker);
            global.stage.connectObject(
                'captured-event::touchpad',
                tracker._disableHandleEvent,
                tracker);
        });
    }

    disable() {
        this._trackers?.forEach(tracker => {
            global.stage.disconnectObject(tracker);
            if (tracker._originalHandleEvent) {
                global.stage.connectObject(
                    'captured-event::touchpad',
                    tracker._originalHandleEvent,
                    tracker);
                delete tracker._originalHandleEvent;
            }
            delete tracker._disableHandleEvent;
        });
        this._trackers = [];
    }
}
