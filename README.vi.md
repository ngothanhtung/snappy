# Snappy

[English](README.md) | **Tiếng Việt**

Snappy là app thường trú trên menu bar macOS để snap cửa sổ đang focus bằng phím
tắt toàn cục.

## Tính Năng

- **Halves:** trái 1/2, phải 1/2, trên 1/2, dưới 1/2
- **Thirds:** 1/3 đầu, 1/3 giữa, 1/3 cuối, 2/3 đầu, 2/3 cuối
- **Chuyển màn hình:** đẩy cửa sổ sang màn hình kế tiếp hoặc trước đó, giữ vị trí và kích thước theo tỉ lệ
- Phím tắt toàn cục có thể tùy chỉnh trong cửa sổ Settings
- Hỗ trợ đa màn hình; snap trong màn hình chứa cửa sổ
- Icon menu bar custom dạng template, tự đổi màu theo light/dark
- Launch at login

## Phím Tắt Mặc Định

| Hành động | Phím |
| --- | --- |
| Left / Right / Top / Bottom Half | Control + Option + Arrow |
| First / Center / Last Third | Control + Option + D / F / G |
| First / Last Two Thirds | Control + Option + E / T |
| Move to Previous / Next Display | Control + Option + Command + Left / Right |

Đổi phím trong **menu bar -> Settings...**

## Build Và Chạy

```bash
swift test              # chạy unit test cho lõi logic
./Scripts/bundle.sh     # build release và đóng gói Snappy.app
open ./Snappy.app
```

Lần đầu chạy, macOS sẽ hỏi quyền **Accessibility**. Bật Snappy trong **System
Settings -> Privacy & Security -> Accessibility**, sau đó phím tắt toàn cục sẽ
hoạt động.

## Quan Trọng: Quyền Accessibility Và Rebuild

macOS gắn quyền Accessibility với **chữ ký code** của app. Khi ký ad hoc, là mặc
định trong `bundle.sh`, mỗi lần rebuild sẽ có chữ ký mới. Quyền đã cấp trước đó
sẽ mất hiệu lực, nên snap có thể không chạy và không báo lỗi rõ ràng.

Cách xử lý nhanh sau mỗi lần build ad hoc: vào **System Settings -> Privacy &
Security -> Accessibility**, xóa Snappy bằng nút trừ, rồi thêm lại bản app vừa
build. App cũng sẽ tự hiện hướng dẫn khi bạn bấm phím tắt mà chưa có quyền.

Cách khuyến nghị: ký bằng một self-signed code-signing certificate ổn định để
quyền được giữ qua các lần rebuild.

1. Mở **Keychain Access -> Certificate Assistant -> Create a Certificate...**
2. Dùng:
   - Name: `Snappy Self-Signed`
   - Type: `Code Signing`
3. Build với identity đó:

```bash
export SNAPPY_SIGN_IDENTITY="Snappy Self-Signed"
./Scripts/bundle.sh
```

Cấp quyền Accessibility một lần. Các lần build sau nếu ký bằng cùng identity sẽ
giữ nguyên quyền.

## Kiến Trúc

`SnappyCore` chứa logic thuần, không phụ thuộc nền tảng, có unit test:

- `LayoutCalculator` tính `CGRect` đích cho từng layout
- `Geometry` đổi hệ tọa độ AppKit và Accessibility
- `DisplayMapper` remap cửa sổ theo tỉ lệ giữa các màn hình
- `DisplayOrdering` chọn màn hình kế tiếp hoặc trước đó theo vị trí

`Snappy` là tầng app, dùng AppKit, Accessibility API và KeyboardShortcuts:

- `WindowEngine`
- `ScreenProvider`
- `WindowManager`
- `HotkeyManager`
- `MenuBarIcon`
- `StatusMenuController`
- `SettingsView`
- `AppDelegate`

Thiết kế chi tiết:
[`docs/superpowers/specs/2026-06-04-macos-window-manager-design.md`](docs/superpowers/specs/2026-06-04-macos-window-manager-design.md)

## Đổi Icon

Thả `MenuBarIcon.png` hoặc `MenuBarIcon.pdf` vào `Resources/`, rồi build lại:

```bash
./Scripts/bundle.sh
```

App sẽ dùng file này thay cho icon menu bar mặc định. Nên dùng ảnh đen trên nền
trong suốt vì Snappy xử lý nó như template image và tự đổi màu theo light/dark.

Chi tiết về icon menu bar và icon app: xem [`Resources/README.md`](Resources/README.md).

## Yêu Cầu

- macOS 14 trở lên
- Swift 5.9 trở lên
- Quyền Accessibility

## Ghi Chú

- Snappy chạy non-sandboxed vì macOS sandbox chặn điều khiển cửa sổ app khác qua
  Accessibility API.
- App phù hợp làm công cụ cá nhân và hiện không phù hợp để phát hành qua Mac App
  Store.
- Phụ thuộc: [`KeyboardShortcuts`](https://github.com/sindresorhus/KeyboardShortcuts)

## Tác Giả

Tony Woo (Ngô Thanh Tùng)
