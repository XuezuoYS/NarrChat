# NarrChat Android 签名密钥配置说明

本文件说明如何为 **Android release 构建**配置自己的签名密钥，方便在本地发布
APK 或在 CI 中自动签名。**签名密钥属于敏感信息，切勿提交到代码仓库。**

## 目录

- [一、签名机制概述](#一签名机制概述)
- [二、生成自己的密钥库（keystore）](#二生成自己的密钥库keystore)
- [三、创建 key.properties 配置](#三创建-keyproperties-配置)
- [四、验证签名是否生效](#四验证签名是否生效)
- [五、CI（GitHub Actions）自动签名](#五cigitHub-actions自动签名)
- [六、安全提醒与常见问题](#六安全提醒与常见问题)

---

## 一、签名机制概述

`android/app/build.gradle.kts` 会尝试读取项目根目录下的 `android/key.properties`
文件（该文件已被 `.gitignore` 忽略，不会进入版本库）：

```
key.properties 存在  → release 构建使用你自己的正式签名
key.properties 缺失  → 自动回退 debug 签名（他人克隆 / CI 未配置时仍可构建，但产出的 APK 为调试签名）
```

这意味着：

- 直接 `flutter run --release` 或 `flutter build apk --release` 无需任何额外参数；
- 别人克隆本仓库后**不做任何签名配置也能正常构建**（产物为 debug 签名，仅用于自用测试）；
- 只有**发布** APK 时才必须配置自己的正式签名。

## 二、生成自己的密钥库（keystore）

### 1. 找到 keytool

`keytool` 随 JDK 提供。Windows 上若安装了 Android Studio，可直接使用其自带 JDK
的 keytool；macOS / Linux 上 `keytool` 通常在 PATH 中。

```bash
# Windows（Android Studio 自带 JDK，示例路径）
"C:\Program Files\Android\Android Studio\jbr\bin\keytool.exe" -version

# macOS / Linux（若在 PATH 中）
keytool -version
```

> 提示：也可以让 Flutter 打印当前使用的 JDK 路径：
> `flutter doctor -v` 中 "Java binary at:" 一行即为其所在目录。

### 2. 生成密钥库

建议将密钥库放在**项目目录之外**（例如用户主目录下），避免误提交。

```bash
# Windows PowerShell 示例（非交互式，密钥库路径请按需修改）
keytool -genkeypair -v -keystore "$HOME\.my-keys\narrchat-upload.jks" `
  -alias upload -keyalg RSA -keysize 2048 -validity 10000 `
  -storepass <你的库密码> -keypass <你的密钥密码> `
  -dname "CN=YourName, O=YourOrg, C=CN"

# macOS / Linux 示例
keytool -genkeypair -v -keystore ~/.my-keys/narrchat-upload.jks \
  -alias upload -keyalg RSA -keysize 2048 -validity 10000 \
  -storepass <你的库密码> -keypass <你的密钥密码> \
  -dname "CN=YourName, O=YourOrg, C=CN"
```

参数说明：

| 参数 | 含义 |
|---|---|
| `-keystore` | 密钥库文件保存路径（建议放仓库外） |
| `-alias` | 密钥别名，与 `key.properties` 中的 `keyAlias` 对应 |
| `-keyalg RSA -keysize 2048` | RSA 2048 位密钥（Android 推荐） |
| `-validity 10000` | 有效期天数（约 27 年，签名密钥要求远长于应用生命周期） |
| `-storepass` / `-keypass` | 库密码 / 密钥密码（≥6 位，请用强随机值） |
| `-dname` | 证书持有人信息，仅作标识，不影响功能 |

也可以省略 `-storepass` / `-keypass` / `-dname`，让 keytool 交互式提问后逐项填写。

## 三、创建 key.properties 配置

在项目根目录 `android/` 下新建 `key.properties`（**不要**提交到仓库），内容如下：

```properties
storePassword=你的库密码
keyPassword=你的密钥密码
keyAlias=upload
storeFile=C:/Users/你的用户名/.my-keys/narrchat-upload.jks
```

各字段说明：

| 字段 | 说明 |
|---|---|
| `storePassword` | 密钥库文件密码（与 `-storepass` 一致） |
| `keyPassword` | 密钥本身密码（与 `-keypass` 一致） |
| `keyAlias` | 密钥别名（与 `-alias` 一致） |
| `storeFile` | 密钥库文件的**绝对路径**（Windows 请用正斜杠 `/` 或转义反斜杠 `\\`） |

> Windows 路径注意：Java properties 中反斜杠是转义符，建议直接写正斜杠，
> 如 `C:/Users/xxx/.my-keys/narrchat-upload.jks`。

## 四、验证签名是否生效

```bash
# 1. 构建 release APK
flutter build apk --release --target-platform android-arm64

# 2. 查看产物签名证书（对比 apksigner 输出的指纹与你密钥的指纹）
# Windows 示例（apksigner 位于 Android SDK build-tools 目录）
"C:\Users\你的用户名\AppData\Local\Android\sdk\build-tools\36.0.0\apksigner.bat" verify --print-certs build\app\outputs\flutter-apk\app-release.apk
```

期望输出：`Signer #1 certificate DN: ...` 与你的 `-dname` 一致；`SHA-256 digest`
与密钥库指纹一致（可用 `keytool -list -v -keystore <文件> -storepass <密码>` 查看
密钥库自身的指纹进行比对）。若显示 debug 指纹（Android Debug 证书），说明
`key.properties` 未生效或路径错误。

## 五、CI（GitHub Actions）自动签名

开源项目若需要 CI 自动产出**官方签名**的 APK，**不要**把密钥和密码写进仓库，
而是使用仓库的加密 Secrets：

1. 将密钥库文件编码为 base64：
   ```bash
   # PowerShell
   [Convert]::ToBase64String([IO.File]::ReadAllBytes("C:\...\narrchat-upload.jks"))
   ```
2. 在 GitHub 仓库 → Settings → Secrets and variables → Actions 中新增：
   - `ANDROID_KEYSTORE_BASE64`（上一步的 base64 字符串）
   - `ANDROID_KEYSTORE_PASSWORD` / `ANDROID_KEY_PASSWORD` / `ANDROID_KEY_ALIAS`
3. 在 workflow 中解码生成 `key.properties` 与密钥库文件后再构建，例如：

   ```yaml
   - name: Set up Android signing
     env:
       KEYSTORE_B64: ${{ secrets.ANDROID_KEYSTORE_BASE64 }}
       STORE_PASS: ${{ secrets.ANDROID_KEYSTORE_PASSWORD }}
       KEY_PASS: ${{ secrets.ANDROID_KEY_PASSWORD }}
       KEY_ALIAS: ${{ secrets.ANDROID_KEY_ALIAS }}
     run: |
       mkdir -p "$RUNNER_TEMP/keys"
       echo "$KEYSTORE_B64" | base64 --decode > "$RUNNER_TEMP/keys/upload.jks"
       echo "storePassword=$STORE_PASS"  > android/key.properties
       echo "keyPassword=$KEY_PASS"     >> android/key.properties
       echo "keyAlias=$KEY_ALIAS"       >> android/key.properties
       echo "storeFile=$RUNNER_TEMP/keys/upload.jks" >> android/key.properties
   ```

   之后执行 `flutter build apk --release` 即会自动使用 CI 内的签名。

## 六、安全提醒与常见问题

### 安全提醒

- **签名密钥无法撤销**：泄漏后任何人都能以你的应用身份发布恶意更新。务必：
  - 密钥库与 `key.properties` **绝不提交**到仓库（`.gitignore` 已包含
    `*.jks`、`*.keystore`、`android/key.properties`，请勿改动）；
  - 离线加密备份密钥库与密码（密码管理器 / 加密 U 盘），丢失无法恢复；
  - 换电脑 / 换人维护时，通过安全通道移交密钥，不要放在聊天、网盘明文等位置。
- 上架 Google Play 后，此密钥即成为「上传密钥」（Play 会用它校验更新来源）。

### 常见问题

**Q1：不配置签名能构建吗？**
能。未配置 `key.properties` 时自动回退 debug 签名，`flutter run --release` 与
`flutter build apk --release` 均可用，只是 APK 为调试签名，不能作为正式发布物。

**Q2：忘记密码 / 丢失密钥库怎么办？**
无法恢复。已发布的 APK 将无法更新（新签名会被视为不同应用）。这也是必须离线备份的原因。

**Q3：`keytool` 报 "keytool 不是内部或外部命令"？**
未在 PATH 中。Windows 请使用 Android Studio 自带 JDK 的完整路径（见上文），
或把 JDK 的 `bin` 目录加入 PATH。

**Q4：`apksigner` 在哪？**
Android SDK 的 `build-tools/<版本>/` 目录下（Windows 为 `apksigner.bat`）。
可通过 `flutter doctor -v` 查看 Android SDK 路径后定位。

**Q5：如何查看自己密钥库的指纹？**
```bash
keytool -list -v -keystore <密钥库路径> -storepass <库密码>
```
输出中的 SHA1 / SHA256 即用于上架或比对 APK 签名。
