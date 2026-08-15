// The Visual Viewport API reports the area of the layout viewport that is
// currently visible on screen. Mobile soft keyboards overlay the layout
// viewport (iOS, and Android Chrome without interactive-widget support), so
// the difference between the two heights is the keyboard inset. When the
// layout viewport itself resizes (Android Chrome with
// interactive-widget=resizes-content), the inset is zero and the regular
// CSS bottom:0 anchoring is already correct.
export function keyboardInset(layoutHeight, viewportHeight, viewportOffsetTop = 0) {
  const covered = layoutHeight - (viewportHeight + viewportOffsetTop);
  return covered > 2 ? covered : 0;
}
