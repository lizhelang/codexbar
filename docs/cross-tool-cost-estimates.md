# 跨工具用量价值与费用来源

核对日期：2026-10-01。`ToolCostEstimator` 只补缺失的用量价值，不将其当作实际账单。

- `costUSD`：来源明确提供的用量价值，或按当前标准 API 单价估算的完整费用。
- `costEvidence`：`reported` 或 `estimated`。
- `billedCostUSD`：仅保留来源明确给出的实际收费。Cursor 套餐内请求收费可为零，但其 API 等值用量不为零。
- 日汇总 `knownCostUSD`：缺少部分模型价格时保留已知部分；`costUSD` 仍为空，因此界面继续显示费用下界。
- 未知模型、缺少输入输出分项的总数不估价。OpenCode 的未定价 `cost: 0` 不等同于免费；带明确免费型号后缀及 Big Pickle 的已上报零价保留。
- 对全部历史统一采用本次核验的标准单价，没有重建历史价格、区域优惠、套餐折扣、搜索等额外收费；DeepSeek 使用标准峰时价。因此这些数值不用于账单核对。
- 旧缓存读取时也重新补价，增量扫描无需等待新的日志。

## 官方价格依据

| 模型来源 | 官方文档 | 采用的口径 |
| --- | --- | --- |
| Claude | https://platform.claude.com/docs/en/about-claude/pricing | USD 标准输入、输出、缓存命中、5 分钟缓存写入；未保存 1 小时 TTL 时使用 5 分钟参考价 |
| DeepSeek | https://api-docs.deepseek.com/quick_start/pricing/ | USD 峰时价；Flash 旧 ID 与 vision-exp 别名使用 Flash 标准价 |
| Xiaomi MiMo | https://mimo.mi.com/docs/en-US/price/pay-as-you-go | 海外 USD 实时 API 单价；缓存写入按文档为零 |
| MiniMax | https://platform.minimax.io/subscribe/token-plan?tab=api-enterprise | M2.7 标准和 highspeed 的独立价格 |
| OpenCode 免费标识 | https://opencode.ai/docs/zen/ | 明确免费型号不补收费 |

## Token 分项

Claude、OpenCode、Cursor 导出和 DSH 持久化记录的四个桶是非缓存输入、输出、缓存命中和缓存写入。本机 DSH `@deepseek-ai/dsh-llm-deepseek` 的 `mapUsage` 会从 wire 的 `prompt_tokens` 扣掉 `prompt_cache_hit_tokens` 再写入 `inputTokens`。估算器要求四项之和与 `totalTokens` 相等，避免对不完整的导出内容估价。

## Codex 的 GPT-6.1 Sol 历史费用修复

`LocalCostPricing` 补充 [GPT-6.1 Sol 官方价格](https://developers.openai.com/api/docs/models/gpt-6.1-sol)：每百万 Token 输入 $2、缓存输入 $0.10、输出 $10；Fast 为两倍。单次请求输入超过 272,000 时，输入与缓存费率乘 2、输出乘 1.5，可与 Fast 叠加。用户自定义价格保持优先。

Codex 日志的输入数包含缓存输入，因此先扣除缓存部分再分别计算。SQLite 索引升级到版本 3，从已有逐请求事件修正计费分类，保留原始事件与扫描进度；模型、会话和总计都使用同一价格表重新计算，无需重读全部会话日志。

回归覆盖定价、缓存折扣、长上下文临界值、Fast、自定义价格、版本 2 迁移，以及 44 个短请求合计 3,382,803 Token 的历史案例（用量价值 $0.9007276）。
