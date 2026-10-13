# Phát hành và cài đặt Twanotch

Ghi chú vận hành cho chủ repo: build, ký, phát hành và cài đặt. README chỉ hướng dẫn người dùng cài bằng Homebrew.

## Phát hành bản mới

1. Commit và push mọi thay đổi lên `main`.
2. Tạo tag phiên bản và push tag:

   ```bash
   git tag v1.0.2 && git push origin v1.0.2
   ```

3. Theo dõi CI. Mỗi lần chạy mất khoảng 4 phút:

   ```bash
   gh run list --repo twan-nguyen/twanotch --limit 3
   gh run watch --repo twan-nguyen/twanotch
   ```

4. Kiểm tra kết quả:

   ```bash
   curl -sL https://github.com/twan-nguyen/twanotch/releases/latest/download/appcast.xml | grep shortVersionString
   gh api repos/twan-nguyen/homebrew-tap/contents/Casks/twanotch.rb --jq .content | base64 -d | grep 'version "'
   ```

5. Trên máy đã cài app, bấm **Kiểm tra cập nhật…** ở icon menu bar để nhận bản mới.

Workflow [release.yml](../.github/workflows/release.yml) làm lần lượt các bước sau:
- Build bản Release universal và ký bằng "TwaNotch Self-Signed".
- Nén thành `TwaNotch-X.Y.Z.zip` và tạo `appcast.xml`, ký bằng khoá EdDSA.
- Tạo GitHub Release.
- Cập nhật `Casks/twanotch.rb` trong [homebrew-tap](https://github.com/twan-nguyen/homebrew-tap).

### Quy tắc

- Tag phải có dạng `vX.Y.Z`, ví dụ `v1.2.3`. Tag sai dạng sẽ làm CI dừng ngay.
- **Mỗi bản phát hành phải nằm trên một commit mới.** Build number bằng số commit (`git rev-list --count HEAD`), và Sparkle so sánh bản mới với bản cũ dựa trên build number. Gắn tag mới lên cùng commit với tag trước thì build number không tăng, nên app sẽ không nhận bản đó. Nếu không có thay đổi gì, tạo một commit rỗng: `git commit --allow-empty -m "chore: release 1.0.2"`.
- Số phiên bản lấy từ tag, nên không cần sửa `MARKETING_VERSION` trong project. Bản build trên máy luôn hiện `1.0.0 (1)`.

### Khi phát hành hỏng

Xem log của lần chạy lỗi bằng `gh run view --log-failed --repo twan-nguyen/twanotch`. Sửa lỗi, rồi xoá release và tag cũ trước khi gắn lại:

```bash
gh release delete v1.0.2 --cleanup-tag --yes --repo twan-nguyen/twanotch
git tag -d v1.0.2
git tag v1.0.2 && git push origin v1.0.2
```

Nếu CI đã kịp cập nhật cask trước khi hỏng, lần chạy sau sẽ ghi đè lên.

## Build và cài trên máy, không qua phát hành

```bash
scripts/install.sh
```

Script làm lần lượt các bước sau:
1. Build bản Release vào `build/DerivedData`.
2. Ký bằng keychain riêng, nếu máy đã có keychain đó.
3. Thoát app đang chạy, thay `/Applications/TwaNotch.app` và mở lại.

App cài theo cách này dùng chung chữ ký với bản phát hành, nên giữ được quyền Accessibility. Nút cập nhật vẫn hoạt động: bản build trên máy có build number `1`, nên Sparkle sẽ đề nghị cập nhật lên bản phát hành mới nhất.

## Cài cho người dùng

```bash
brew install --cask twan-nguyen/tap/twanotch
```

- Sau khi cài, bật quyền Accessibility cho Twanotch một lần trong System Settings > Privacy & Security > Accessibility.
- `brew list --versions` vẫn hiện số phiên bản lúc cài, kể cả sau khi Sparkle đã cập nhật app. Đây là hành vi bình thường của cask có `auto_updates`.
- Gỡ app: `brew uninstall --cask twanotch`. Thêm `--zap` nếu muốn xoá cả cài đặt và dữ liệu.

## Khoá và chứng chỉ nằm ở đâu

| Thứ | Ở đâu trên máy | Trên GitHub |
|---|---|---|
| Chứng chỉ ký "TwaNotch Self-Signed" (hạn 2046) | `~/Library/Keychains/twanotch-signing.keychain-db`. Mật khẩu keychain lưu trong login keychain, mục `twanotch-signing-keychain` | Secret `SIGNING_CERT_P12_BASE64` và `SIGNING_CERT_PASSWORD` |
| Khoá EdDSA của Sparkle | Login keychain, account `twanotch` | Secret `SPARKLE_PRIVATE_KEY` |
| Deploy key để đẩy cask | Không lưu trên máy | Secret `TAP_DEPLOY_KEY`, kèm deploy key có quyền ghi trên repo tap |

Khoá công khai Sparkle nằm ở `SUPublicEDKey` trong [Info.plist](../Twanotch/Info.plist). Đọc lại bằng lệnh `generate_keys --account twanotch -p`. Công cụ `generate_keys` nằm trong `DerivedData/.../SourcePackages/artifacts/sparkle/Sparkle/bin/`.

Hiện không có bản sao lưu ngoài hai nơi trên. CI vẫn phát hành được kể cả khi máy hỏng, vì nó chỉ dùng secret.

### Dùng một máy Mac khác để build

1. Trên máy cũ, export chứng chỉ ra file `.p12`. Mở khoá keychain riêng trước, rồi nhập một mật khẩu mới cho file khi được hỏi:

   ```bash
   security unlock-keychain ~/Library/Keychains/twanotch-signing.keychain-db
   security export -k ~/Library/Keychains/twanotch-signing.keychain-db -t identities -f pkcs12 -P "<mật khẩu cho file p12>" -o ~/TwaNotch-Self-Signed.p12
   ```

   Lệnh đầu hỏi mật khẩu của keychain riêng. Lấy mật khẩu đó bằng `security find-generic-password -s twanotch-signing-keychain -w`.

2. Chép file sang máy mới, rồi chạy `scripts/setup-signing-keychain.sh ~/TwaNotch-Self-Signed.p12`. Xoá file `.p12` sau khi xong.

### Khi mất cả khoá trên máy lẫn secret

1. Tạo chứng chỉ tự ký mới, dùng lại các lệnh `openssl` đã dùng lúc đầu: `keyUsage=digitalSignature` và `extendedKeyUsage=codeSigning`. Sau đó chạy `scripts/setup-signing-keychain.sh`.
2. Tạo khoá Sparkle mới bằng `generate_keys --account twanotch` và thay `SUPublicEDKey` trong Info.plist.
3. Đặt lại các secret bằng `gh secret set ... --repo twan-nguyen/twanotch`.
4. Mỗi máy đang cài phải chạy `brew reinstall --cask twanotch` một lần, vì bản cũ không nhận bản cập nhật ký bằng khoá mới. Sau đó bật lại quyền Accessibility một lần.

## Ghi chú phát triển

- Cần macOS 15.6 trở lên và Xcode 26 trở lên. Mở `Twanotch.xcodeproj` rồi chạy scheme `Twanotch` để có bản debug.
- Chuỗi giao diện nằm trong `Twanotch/Localizable.xcstrings`. Build bằng dòng lệnh không thêm chuỗi mới vào catalog. Sau khi thêm chữ trên giao diện, build một lần trong Xcode hoặc chạy `xcodebuild -exportLocalizations -project Twanotch.xcodeproj -localizationPath /tmp/twanotch-loc -exportLanguage vi`, rồi thêm bản dịch `vi`.
- Icon gốc là [Configuration/branding/twanotch-icon.svg](../Configuration/branding/twanotch-icon.svg). Sửa xong thì tạo lại các PNG trong `Twanotch/Assets.xcassets/AppIcon.appiconset`, ví dụ bằng `rsvg-convert`.
- `Twanotch.entitlements` phải có `com.apple.security.cs.disable-library-validation`, vì app không do team Apple ký và có link `MediaRemoteAdapter.framework`. Thiếu entitlement này app sẽ crash ngay khi mở với lỗi "different Team IDs".

## Sự cố hay gặp

- **`errSecInternalComponent` khi ký:** codesign không được phép dùng khoá riêng, hoặc keychain đang khoá. Nếu khoá nằm trong keychain riêng thì `install.sh` tự mở khoá được. Lỗi này thường xảy ra khi chứng chỉ bị import nhầm vào login keychain.
- **`ambiguous` khi ký:** có hai chứng chỉ cùng tên "TwaNotch Self-Signed". Xoá bản thừa trong login keychain bằng `security delete-identity -c "TwaNotch Self-Signed" ~/Library/Keychains/login.keychain-db`.
- **Gatekeeper chặn khi mở zip tải bằng trình duyệt:** chạy `xattr -dr com.apple.quarantine /Applications/TwaNotch.app`. Cài qua Homebrew thì cask đã tự gỡ quarantine.
- **HUD không hiện sau khi cài bản build trên máy:** kiểm tra chữ ký bằng `codesign -dvv /Applications/TwaNotch.app | grep Authority`. Nếu kết quả không phải "TwaNotch Self-Signed", app đã được ký ad-hoc và cần bật lại quyền Accessibility.
- **Homebrew báo tap không tin cậy:** chạy `brew trust --tap twan-nguyen/tap` một lần.
