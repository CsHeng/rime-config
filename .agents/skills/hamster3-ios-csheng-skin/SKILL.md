---
name: hamster3-ios-csheng-skin
description: |
  Maintain the `resources/ios-csheng.cskin` Hamster3 skin package from Jsonnet sources.
  Use when editing the iOS-CsHeng skin, keyboard layout, symbol behavior, or pack/build workflow.
---

# Skill: Hamster3 iOS-CsHeng 皮肤维护（`.cskin`）

## 目标
维护 `resources/ios-csheng.cskin`（Hamster3 `.cskin` 皮肤包），以 **iOS26 风格** 为基准：

- 键盘"矮胖"：键位间隙更小、可按区域更大
- 字母区键帽默认显示 **小写**（Shift 切换大写）
- QWERTY 区键帽顶部有 **上下划提示符号**（左=上划、右=下划）
- 支持 **长按预览浮窗**（按键本体 + 上/下划可选项）

## 底行布局
```
[123] [semicolon] [    space    ] [cn2en] [enter]
```

- `semicolonButton`：点按 `,`、上划 `.`；键帽随 `rime$ascii_mode` 动态切换（中文 `，/。`、英文 `,/.`）
- `spaceButton`：中间显示 `$rimeSchemaName`，无上划动作（避免 toast）
- `cn2enButton`：显示"中"，点按切换到 alphabetic 键盘

## 中英切换机制
**禁止使用 `#中英切换` shortcut**（会触发 toast 提示"中文：关, 英文：开"）。

正确做法：通过 `keyboardType` 切换独立键盘：
- 中文键盘（pinyin）：`cn2enButton` 使用 `action: { keyboardType: 'alphabetic' }`
- 英文键盘（alphabetic）：`en2cnButton` 使用 `action: { keyboardType: 'pinyin' }`

## Alphabetic 键盘（英文直出）
`iPhoneAlphabetic.libsonnet` 使用 `symbol` action 直接输出英文字符，绕过 rime 引擎：

```jsonnet
// character 会经过 rime 引擎处理
{ action: { character: 'a' } }  // 错误：仍输出中文

// symbol 直接输出，不经过 rime
{ action: { symbol: 'a' } }     // 正确：直接输出英文
```

`toSymbol()` 辅助函数：保留原按键所有参数（swipe hints、long press 等），仅转换 action 类型。

## 皮肤元信息
`config.yaml`（由 Jsonnet 生成）：
- `author: CsHeng`
- `name: iOS-CsHeng`
- `version: 1.0.0`

## 源码位置
源码直接在仓库目录，不在 zip 内：

```
resources/ios-csheng/
├── jsonnet/
│   ├── main.jsonnet                    # 编译入口
│   ├── Constants/
│   │   └── Keyboard.libsonnet          # 按键定义、上/下划映射
│   └── Components/
│       ├── BasicStyle.libsonnet        # 样式（isUppercase=false）
│       ├── iPhonePinyin.libsonnet      # 中文键盘布局
│       └── iPhoneAlphabetic.libsonnet  # 英文键盘（symbol action）
├── light/                              # 生成的浅色主题 yaml
├── dark/                               # 生成的深色主题 yaml
├── config.yaml                         # 生成的配置
├── Makefile
└── README.md
```

## 工作流（强制）
1. **只改 Jsonnet 源码**：不要直接编辑生成的 `*.yaml`
2. **编译命令**：必须带 `-S` 参数
   ```bash
   jsonnet -S -m . jsonnet/main.jsonnet
   ```
3. **注释规范**：
   - 允许：解释"为什么/做什么"
   - 禁止：emoji、变更记录式注释

## 编译与打包
```bash
cd resources/ios-csheng
make pack
# 输出: resources/ios-csheng.cskin
```

Makefile 只有一个变量 `SKIN_NAME := ios-csheng`，zip 内部目录名与皮肤名一致。

## 生成文件（.gitignore）
以下文件由 jsonnet 生成，不应提交：
- `light/*.yaml`, `dark/*.yaml`
- `light/.*.keyboard`, `dark/.*.keyboard`
- `config.yaml`

## 本地预览
```bash
# 中文模式
python3 cmd/hamster3/preview_keyboard_svg.py resources/ios-csheng.cskin light pinyinPortrait --out /tmp/pinyin-zh.svg

# 英文模式
python3 cmd/hamster3/preview_keyboard_svg.py resources/ios-csheng.cskin light pinyinPortrait --ascii --out /tmp/pinyin-en.svg
```

## 关键开关
在 `Keyboard.libsonnet` 按键 params 中设置：
- `showSwipeHints: true`：键帽顶部显示上/下划提示
- `showHoldSymbols: true`：长按弹出预览浮窗

## 迭代检查清单
- [ ] 字母键 `foregroundStyle` 为 3 项数组（主字母 + 上划提示 + 下划提示）
- [ ] `semicolonButton` 使用 `ConditionStyle` 随 `rime$ascii_mode` 切换
- [ ] `cn2enButton` 使用 `keyboardType: 'alphabetic'`（不是 `#中英切换`）
- [ ] Alphabetic 键盘使用 `symbol` action（不是 `character`）
- [ ] 默认显示小写：`BasicStyle.libsonnet` 中 `isUppercase=false`
- [ ] `make pack` 编译成功
