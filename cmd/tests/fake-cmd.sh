#!/bin/sh
# fake-cmd.sh — 假前端命令：记录调用与关键环境，可注入失败。
# 环境变量:
#   FAKE_LOG       记录文件路径（必填；未设置时静默成功）
#   FAKE_FAIL_ARG  若任一参数等于该值，则以 FAKE_EXIT（默认 7）退出
#   FAKE_EXIT      失败退出码（默认 7）
# 输出格式（每次调用一组，参数边界可区分）:
#   CMD:<basename> ARGC:<n>
#   ARGV[<i>]:<arg>     （每个参数一行；空参数为 "ARGV[<i>]:"，内嵌换行原样出现）
#   ENV_MARK:<value of RIME_TEST_ENV_MARK or <unset>>
if [ -n "${FAKE_LOG:-}" ]; then
  {
    printf 'CMD:%s ARGC:%d\n' "$(basename "$0")" "$#"
    i=0
    for a in "$@"; do
      printf 'ARGV[%d]:%s\n' "$i" "$a"
      i=$((i + 1))
    done
    printf 'ENV_MARK:%s\n' "${RIME_TEST_ENV_MARK:-<unset>}"
  } >> "$FAKE_LOG"
fi
if [ -n "${FAKE_FAIL_ARG:-}" ]; then
  for a in "$@"; do
    if [ "$a" = "$FAKE_FAIL_ARG" ]; then
      exit "${FAKE_EXIT:-7}"
    fi
  done
fi
exit 0
