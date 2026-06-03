# Resources/

Thả file tài nguyên tùy biến vào đây — `Scripts/bundle.sh` sẽ copy toàn bộ
thư mục này vào `Magnet.app/Contents/Resources/` khi build.

## Đổi icon menu bar

Đặt file tên **`MenuBarIcon.png`** (hoặc `MenuBarIcon.pdf`) vào thư mục này.

- App tự nạp file này thay cho icon vẽ-bằng-code. Không có file → dùng icon mặc định.
- Nên dùng ảnh **đen trên nền trong suốt** (monochrome): app set `isTemplate = true`
  nên nó tự đổi trắng/đen theo menu bar sáng/tối.
- Ảnh được scale về cao 18pt (theo tỉ lệ). PNG nên ~36×36 px (@2x cho Retina),
  hoặc dùng PDF vector để luôn sắc nét.

```
Resources/MenuBarIcon.png   → build lại: ./Scripts/bundle.sh
```

## Đổi icon app (Finder / About panel)

Chỉ cần đặt **`AppIcon.png`** (ảnh vuông, nên 1024×1024) vào thư mục này rồi
build:

```
Resources/AppIcon.png   → ./Scripts/bundle.sh
```

`bundle.sh` tự convert PNG → `AppIcon.icns` (qua `sips` + `iconutil`) và gắn
`CFBundleIconFile` vào Info.plist. Bạn **không cần** tự tạo `.icns`.

> - Finder yêu cầu `.icns` nên PNG sẽ được convert tự động — bạn chỉ cung cấp PNG.
> - Nếu Finder vẫn hiện icon cũ (do cache), chạy: `killall Finder`.
> - Magnet là agent app (`LSUIElement`) nên không có icon trên Dock; icon app
>   chỉ xuất hiện ở Finder và About panel.
