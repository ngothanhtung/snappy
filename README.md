# Magnet

App thường trú trên menu bar macOS để snap cửa sổ đang focus bằng phím tắt toàn cục.

## Tính năng (v1)

- **Halves:** trái ½, phải ½, trên ½, dưới ½
- **Thirds:** ⅓ đầu, ⅓ giữa, ⅓ cuối, ⅔ đầu, ⅔ cuối
- **Chuyển màn hình:** đẩy cửa sổ sang màn hình kế tiếp/trước, giữ vị trí + kích thước tỉ lệ
- Phím tắt toàn cục có thể tùy chỉnh (cửa sổ Settings)
- Hỗ trợ đa màn hình (snap trong màn hình chứa cửa sổ)
- Icon menu bar custom (template, tự đổi màu theo light/dark)
- Launch at login

## Phím tắt mặc định

| Hành động | Phím |
|-----------|------|
| Left / Right / Top / Bottom Half | ⌃⌥ ← / → / ↑ / ↓ |
| First / Center / Last Third | ⌃⌥ D / F / G |
| First / Last Two Thirds | ⌃⌥ E / T |
| Move to Previous / Next Display | ⌃⌥⌘ ← / → |

Đổi phím trong **menu bar ▸ Settings…**

## Build & chạy

```bash
swift test              # chạy unit test cho lõi logic
./Scripts/bundle.sh     # build release + đóng gói Magnet.app
open ./Magnet.app
```

Lần đầu chạy sẽ hỏi quyền **Accessibility** (System Settings ▸ Privacy &
Security ▸ Accessibility) — bật Magnet rồi phím tắt sẽ hoạt động.

## Kiến trúc

- **`MagnetCore`** — logic thuần, không phụ thuộc nền tảng, có unit test đầy đủ:
  - `LayoutCalculator` — tính `CGRect` đích cho mỗi layout
  - `Geometry` — đổi hệ tọa độ AppKit ↔ Accessibility
  - `DisplayMapper` — remap tỉ lệ cửa sổ sang màn hình khác
  - `DisplayOrdering` — chọn màn hình kế tiếp/trước (sắp theo vị trí)
- **`Magnet`** — tầng app (AppKit + Accessibility API + KeyboardShortcuts):
  - `WindowEngine` (AX get/set), `ScreenProvider`, `WindowManager`,
    `HotkeyManager`, `MenuBarIcon`, `StatusMenuController`, `SettingsView`, `AppDelegate`

Thiết kế chi tiết: `docs/superpowers/specs/2026-06-04-macos-window-manager-design.md`

## Ghi chú

- App chạy **non-sandboxed** (sandbox chặn điều khiển cửa sổ app khác qua AX) →
  không phát hành qua Mac App Store. Phù hợp công cụ cá nhân.
- Phụ thuộc: [`KeyboardShortcuts`](https://github.com/sindresorhus/KeyboardShortcuts).
