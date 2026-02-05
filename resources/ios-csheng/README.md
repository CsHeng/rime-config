# iOS-CsHeng

- author: CsHeng
- version: 1.0.0
- description: ANSI排列，配色参考iOS26

皮肤文件通过 `Jsonnet` 语法编写，PC 端编译时需要安装 `jsonnet` 命令行工具。

## 键盘布局

### 底行布局
```
[123] [semicolon] [    space    ] [cn2en] [enter]
```

- `123`：切换到数字/符号键盘
- `semicolon`：点按 `,`，上划 `.`（全角/半角由输入法状态决定）
- `space`：空格，显示当前输入方案名
- `cn2en`：显示"中"，点按切换到英文键盘
- `enter`：回车

### 字母区快捷键
- `q~p` 上划：`!@#$%^&*()`；下划：`1234567890`
- `a~l` 上划：`~_+{}|?:"`；下划：`` `-=[]\\/;' ``

### 中英切换
本皮肤使用独立的英文键盘（alphabetic），通过 `cn2en` 按钮切换，不使用 `#中英切换` shortcut（避免 toast 提示）。

英文键盘使用 `symbol` action 直接输出，不经过 rime 引擎。

## 自定义调整

- `jsonnet/Constants/Keyboard.libsonnet`：按键定义、上下划映射
- `jsonnet/Components/BasicStyle.libsonnet`：样式配置
- `jsonnet/Components/iPhonePinyin.libsonnet`：中文键盘布局
- `jsonnet/Components/iPhoneAlphabetic.libsonnet`：英文键盘布局

## 编译

### 手机端
长按皮肤，选择「运行 main.jsonnet」

### PC 端
```shell
make pack
```
