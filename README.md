# Snappy

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

| Hành động                        | Phím             |
| -------------------------------- | ---------------- |
| Left / Right / Top / Bottom Half | ⌃⌥ ← / → / ↑ / ↓ |
| First / Center / Last Third      | ⌃⌥ D / F / G     |
| First / Last Two Thirds          | ⌃⌥ E / T         |
| Move to Previous / Next Display  | ⌃⌥⌘ ← / →        |

Đổi phím trong **menu bar ▸ Settings…**

## Build & chạy

```bash
swift test              # chạy unit test cho lõi logic
./Scripts/bundle.sh     # build release + đóng gói Snappy.app
open ./Snappy.app
```

Lần đầu chạy sẽ hỏi quyền **Accessibility** (System Settings ▸ Privacy &
Security ▸ Accessibility) — bật Snappy rồi phím tắt sẽ hoạt động.

## ⚠️ Quan trọng: quyền Accessibility & rebuild

macOS gắn quyền Accessibility với **chữ ký code** của app. Khi ký **ad-hoc**
(mặc định), mỗi lần `bundle.sh` build lại sẽ tạo chữ ký mới → quyền đã cấp
**mất hiệu lực**, và snap "im lặng không chạy".

**Khắc phục ngay (sau mỗi lần build ad-hoc):** vào System Settings ▸ Privacy &
Security ▸ Accessibility, **xóa Snappy bằng nút “–” rồi thêm lại** bản build mới
(hoặc tick lại). App cũng sẽ tự hiện hướng dẫn khi bạn bấm phím tắt mà chưa có quyền.

**Khắc phục triệt để (khuyến nghị):** ký bằng một self-signed certificate ổn
định để quyền được giữ qua mọi lần rebuild:

1. Keychain Access ▸ Certificate Assistant ▸ _Create a Certificate…_
   - Name: `Snappy Self-Signed`, Type: **Code Signing**
2. Build với identity đó:
   ```bash
   export SNAPPY_SIGN_IDENTITY="Snappy Self-Signed"
   ./Scripts/bundle.sh
   ```
   Cấp quyền Accessibility **một lần** — các lần build sau giữ nguyên quyền.

## Kiến trúc

- **`SnappyCore`** — logic thuần, không phụ thuộc nền tảng, có unit test đầy đủ:
  - `LayoutCalculator` — tính `CGRect` đích cho mỗi layout
  - `Geometry` — đổi hệ tọa độ AppKit ↔ Accessibility
  - `DisplayMapper` — remap tỉ lệ cửa sổ sang màn hình khác
  - `DisplayOrdering` — chọn màn hình kế tiếp/trước (sắp theo vị trí)
- **`Snappy`** — tầng app (AppKit + Accessibility API + KeyboardShortcuts):
  - `WindowEngine` (AX get/set), `ScreenProvider`, `WindowManager`,
    `HotkeyManager`, `MenuBarIcon`, `StatusMenuController`, `SettingsView`, `AppDelegate`

Thiết kế chi tiết: `docs/superpowers/specs/2026-06-04-macos-window-manager-design.md`

## Đổi icon

Thả `MenuBarIcon.png` (hoặc `.pdf`, ảnh đen nền trong suốt) vào thư mục
`Resources/` rồi `./Scripts/bundle.sh` — app tự dùng ảnh đó thay icon mặc định.
Chi tiết (kể cả icon app): xem `Resources/README.md`.

## Tác giả

Tony Woo (Ngô Thanh Tùng)

## Ghi chú

- App chạy **non-sandboxed** (sandbox chặn điều khiển cửa sổ app khác qua AX) →
  không phát hành qua Mac App Store. Phù hợp công cụ cá nhân.
- Phụ thuộc: [`KeyboardShortcuts`](https://github.com/sindresorhus/KeyboardShortcuts).
