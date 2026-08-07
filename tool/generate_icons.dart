// ignore_for_file: depend_on_referenced_packages
import 'dart:io';

import 'package:image/image.dart' as img;

/// Generate two PNG icons for the app launcher.
void main() {
  const int size = 1024;
  final dark = img.ColorRgba8(24, 25, 29, 255); // #18191D
  final green = img.ColorRgba8(77, 170, 144, 255); // #4DAA90 (up / bull)
  final greenLight = img.ColorRgba8(127, 210, 185, 255); // lighter green

  // ── Foreground (transparent bg) ──────────────────────────────────────
  final fg = img.Image(width: size, height: size, numChannels: 4);
  img.fill(fg, color: img.ColorRgba8(0, 0, 0, 0));

  // Candle wick
  _drawRect(fg, 494, 150, 36, 720, green);
  // Candle body (green = up in Chinese market)
  _drawRect(fg, 340, 280, 340, 520, green);
  // Highlight on left side of body
  _drawRect(fg, 340, 280, 80, 520, greenLight);

  File('assets/icons/icon_foreground.png').writeAsBytesSync(img.encodePng(fg));
  print('Generated assets/icons/icon_foreground.png');

  // ── Full icon (dark bg) ──────────────────────────────────────────────
  final bg = img.Image(width: size, height: size, numChannels: 4);
  img.fill(bg, color: dark);

  _drawRect(bg, 494, 150, 36, 720, green);
  _drawRect(bg, 340, 280, 340, 520, green);
  _drawRect(bg, 340, 280, 80, 520, greenLight);

  File('assets/icons/icon.png').writeAsBytesSync(img.encodePng(bg));
  print('Generated assets/icons/icon.png');
}

void _drawRect(img.Image image, int x, int y, int w, int h, img.ColorRgba8 c) {
  for (int row = y; row < y + h; row++) {
    for (int col = x; col < x + w; col++) {
      if (row >= 0 && row < image.height && col >= 0 && col < image.width) {
        image.setPixelRgba(col, row, c.r, c.g, c.b, c.a);
      }
    }
  }
}
