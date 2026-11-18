# URI Scheme 规格（literaturesearch://）

> 深链动词规格。与 `Sources/LiteratureCore/DeepLink.swift` 一一对应。构造
> 只经 `DeepLink.build()`，解析只经 `DeepLink.parse(_:)`；两处之外的手拼/手解
> 均为违例（DesignGuard 机检断言定 CLI 不手拼）。

## 总则

- **scheme**：`literaturesearch`（小写不敏感，解析时统一小写比较）。
- **动词**（URL host 段）：`search` / `quote` / `open` / `collection` 四个。
  未知 host 一律返回 nil（fail-closed，不猜测不回退）。
- **编码**：参数值经 URL 查询串 percent-encoding（`URLComponents` 天然处理；
  `+`、`/`、`=`、中文等特殊字符往返不丢，测试断言定）。
- **fail-closed 语义**：必填参数缺失或空白 → 整体 nil；可选参数非法 →
  该参数按缺省处理（open 的 page）或整体 nil（collection 的 id），逐动词
  写明如下。
- **平台边界**：macOS 已注册（`app/Support/LiteratureSearch-Info.plist`
  CFBundleURLTypes）；iOS 接收面未接。

## 注册现状（macOS）

`app/Support/LiteratureSearch-Info.plist`：

```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLName</key>…</key>
    <key>CFBundleURLSchemes</key>
    <array><string>literaturesearch</string></array>
  </dict>
</array>
```

App 入口 `onOpenURL` 先烧 `skipSessionRestore()` 还原守卫再处理深链
（先到先得，幂等，次序不动）。

---

## 动词一：search（检索预填）

打开应用并把检索框预填为给定查询串后立即执行检索。

| 项 | 值 |
|---|---|
| 形态 | `literaturesearch://search?q=<url-encoded query>` |
| 参数 | `q`：查询串（可含中文与空格） |
| 缺省行为 | `q` 缺失时按空串处理（预填空并执行）——与 widget 既有行为一致 |
| build 限制 | 空白查询 `build()` 返回 nil（调用方不得产出无意义深链去回退 file:///） |
| 示例 | `literaturesearch://search?q=计算理论%20graph%20检索` |

## 动词二：quote（每日一句）

跳转到每日一句区（DailyQuoteWidget 点按目标）。

| 项 | 值 |
|---|---|
| 形态 | `literaturesearch://quote` |
| 参数 | 无 |
| 缺省行为 | 无参数、恒可 build（永不 nil） |
| 示例 | `literaturesearch://quote` |

## 动词三：open（定位书/页）

定位到某本书；可带页号直达该书某物理页；可带批注行 id 直达该批注所在页。

| 项 | 值 |
|---|---|
| 形态 | `literaturesearch://open?doc=<bookID>&page=<N>&hl=<id>` |
| 参数 | `doc`：书的 id（books.id，内容寻址形如 `b`+sha 前 20 位——书目重建不失效，favorites 无外键同哲学）；`page`：物理页号（1 起，可选）；`hl`：批注行 id（user_highlights.id，Int64，可选） |
| fail-closed | `doc` 空白/缺失 → build 与 parse 双向 nil；`page` 非数字或缺失 → 解析为 `page=nil`（只选书不开页），不整体拒绝；`hl` 非数字或缺失 → 解析为 `hl=nil`，不整体拒绝 |
| 独立性 | `hl` 与 `page` **独立可选、不强制一致**——`hl` 是批注行 ID 更精确，消费侧以 hl 行的 `pageNumber` 打开（行缺 → 显式提示「深链指向的批注行不在了」，不静默）；build 仅在参数非 nil 时携带对应查询串 |
| App 行为 | 有 hl：以批注行页号走既有 openGuard 管线打开（双指纹守卫自动生效；当前版本只做页级跳转，行级滚动未做）；无 hl 有 page：打开该书该页；两者皆无：书级打开（书目详情，不开页）。书不在库中 → 显式提示「深链指向的书不在库中」，不静默 |
| 示例 | `literaturesearch://open?doc=b1a2b3c4d5e6f7a8b9c0&page=42`；`literaturesearch://open?doc=b1a2b3c4d5e6f7a8b9c0&hl=17` |

## 动词四：collection（定位收藏行）

打开收藏页并定位到某一行。

| 项 | 值 |
|---|---|
| 形态 | `literaturesearch://collection?id=<rowID>` |
| 参数 | `id`：favorites 行 id，必须为正整数 |
| fail-closed | `id` 缺失、非数字、0 或负数 → 整体 nil |
| App 行为 | 切到收藏页并把该行置入整理（多选）选中集；**选中态仅在「整理」模式可见——非整理模式无可见高亮、无滚动定位**；行已删除 → 显式提示「深链指向的收藏行不在了」，不静默 |
| 示例 | `literaturesearch://collection?id=7` |

---

## 与 CLI 的同构关系

CLI 子命令 `open` 与 App 深链共用同一动词层：

```
literaturesearch-cli open --doc <bookID> [--page N] [--hl <id>] [--print]
```

- URL 构造**必须**经 `DeepLink.open(doc:page:).build()`（CLI 源码不含
  scheme 字面——DesignGuard 机检，防双实现漂移）。
- `--print` 只打印 URL（GUI 会话不可得时的机器验证通道）；缺省经
  `/usr/bin/open` 拉起。
- 真实拉起需要 GUI 会话，CLI 无法验证——真实拉起需要 GUI 会话，CLI 无法验证。

## 动词对照表（实现 ↔ 规格）

| 动词 | DeepLink case | parse host | build 参数 | 规格节 |
|---|---|---|---|---|
| search | `.search(query:)` | `search` | `q` | 动词一 |
| quote | `.quote` | `quote` | 无 | 动词二 |
| open | `.open(doc:page:highlight:)` | `open` | `doc`、`page`、`hl` | 动词三 |
| collection | `.collection(id:)` | `collection` | `id` | 动词四 |

未知 host（含 `literaturesearch://` 空主机）→ parse 返回 nil。
