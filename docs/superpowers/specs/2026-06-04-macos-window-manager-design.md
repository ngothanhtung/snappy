# Magnet — macOS Window Manager (menubar app)

Date: 2026-06-04
Status: Approved (Hướng B)

## Mục tiêu
Công cụ cá nhân: app thường trú trên menubar macOS, dùng phím tắt toàn cục để
snap cửa sổ đang focus theo các layout halves + thirds.

## Phạm vi v1
Actions:
- Halves: Left ½, Right ½, Top ½, Bottom ½
- Thirds: First ⅓, Center ⅓, Last ⅓, First ⅔, Last ⅔

Ngoài phạm vi (YAGNI): quarters, maximize/center, di chuyển sang màn hình khác,
snap khi kéo chuột, layout tùy biến. (Có thể thêm sau.)

## Hướng tiếp cận
Hướng B: Native Swift app + thư viện `KeyboardShortcuts` (Sindre Sorhus) cho phím
tắt + recorder UI. Tự viết lõi AX (`WindowEngine`) và tính toán (`LayoutCalculator`).

Nếu không fetch được dependency, fallback: tự wrap Carbon `RegisterEventHotKey`.

## Ràng buộc kỹ thuật
- Agent app: `LSUIElement = true` (không icon Dock).
- **App Sandbox TẮT** — sandbox chặn điều khiển cửa sổ app khác qua AX.
- Cần quyền **Accessibility** (System Settings > Privacy & Security > Accessibility).
- Đổi hệ tọa độ: AppKit (gốc dưới-trái) ↔ Accessibility/Quartz (gốc trên-trái).

## Kiến trúc & Module
| Module | Nhiệm vụ | Test |
|--------|----------|------|
| `WindowLayout` (enum) | Khai báo các layout | — |
| `LayoutCalculator` | (visibleFrame, layout) → CGRect đích. Hàm thuần | Unit test đầy đủ |
| `Geometry` | Đổi hệ tọa độ AppKit ↔ AX. Hàm thuần | Unit test |
| `WindowEngine` | AX: frontmost app → focused window → get/set pos+size | Manual |
| `ScreenProvider` | Xác định NSScreen chứa cửa sổ hiện tại | Manual |
| `HotkeyManager` | KeyboardShortcuts.Name cho từng action → callback | Manual |
| `StatusMenuController` | NSStatusItem + menu | Manual |
| `SettingsView` | SwiftUI: Recorder gán phím + Launch at Login (SMAppService) | Manual |
| `AppDelegate` | Vòng đời, kiểm tra quyền AX | Manual |

Nguyên tắc: dồn mọi logic vào `LayoutCalculator`/`Geometry` (thuần, test được);
giữ `WindowEngine` mỏng nhất có thể.

## Luồng dữ liệu
Nhấn phím tắt → callback KeyboardShortcuts → `WindowAction(layout)` →
`WindowEngine` lấy cửa sổ focus + screen của nó (`ScreenProvider`) →
`LayoutCalculator` tính CGRect từ `screen.visibleFrame` →
`Geometry` đổi sang tọa độ AX → `WindowEngine` set position + size.

## Xử lý lỗi / edge cases
- Chưa cấp quyền AX → alert + nút mở System Settings (`AXIsProcessTrustedWithOptions` prompt).
- Không có cửa sổ focus (vd desktop Finder) → no-op im lặng.
- App có cửa sổ kích thước cố định → AX set trả lỗi → bắt và bỏ qua êm.
- Đa màn hình / rút màn hình → luôn tính lại từ screen hiện tại mỗi lần.

## Testing
- `LayoutCalculator`: unit test với các frame mẫu (1440×900, 1920×1080), kiểm tra
  halves, thirds, làm tròn pixel.
- `Geometry`: unit test đổi tọa độ với chiều cao màn hình mẫu.
- `WindowEngine`/AX: kiểm thử thủ công (cần cửa sổ thật).

## Build & đóng gói
- Swift Package: target executable `Magnet` + library `MagnetCore` (testable) + test target.
- Dependency: `KeyboardShortcuts`.
- Script `Scripts/bundle.sh`: build release rồi lắp vào `Magnet.app` kèm `Info.plist`
  (LSUIElement). Chạy non-sandboxed.
