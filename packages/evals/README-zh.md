# Pi evals

Pi evals 是用于 Pi 工作流的、由模型驱动的行为检查。它们会把真实的 `AgentSession` 适配到 `vitest-evals`，在隔离的临时项目目录和 agent 目录中运行，并附加原生 Pi 会话产物。
可用它们衡量端到端行为，并比较 prompt、工具、skill、模型或其他 harness 配置。

## 运行 evals

在仓库根目录运行，并指定默认 provider 和模型：

```bash
npm run eval -- --provider openai --model gpt-5.6-sol
```

等价的环境变量写法是：

```bash
PI_PROVIDER=openai PI_MODEL=gpt-5.6-sol npm run eval
```

CLI 参数优先级更高，并会成为未显式选择模型的 harness 的默认值。Provider 和模型必须同时提供。如果每个被执行的 harness 都配置了自己的模型，runner 也允许不设置默认值。
认证来自 Pi 常规的 `ModelRuntime`，包括 Pi 订阅凭据和 provider API key 环境变量。

额外参数会转发给 Vitest：

```bash
npm run eval -- src/extensions.eval.ts
npm run eval -- -t "creates, reloads, and uses"
```

每次调用都会打印一个被忽略的 `.eval/` 产物目录。`runs.jsonl` 会索引已完成的 harness run，以及它们在 `sessions/` 下的原生 Pi 会话 JSONL 附件。这些文件可能包含 prompt、响应、源代码和工具输出。

## 编写 evals

通用的 suite、judge、assertion 和 normalized trace 指南请参考 [`vitest-evals`](https://github.com/getsentry/vitest-evals)。Pi 专用 eval 使用 `src/pi-harness.ts` 中的 `createPiCodingAgentHarness(...)`，每个 harness 绑定到一个 `describeEval(...)` suite：

```ts
import { expect } from "vitest";
import { describeEval } from "vitest-evals";
import { createPiCodingAgentHarness } from "./pi-harness.ts";

const harness = createPiCodingAgentHarness({ noTools: "all" });

describeEval("Pi smoke", { harness }, (it) => {
	it("answers a factual question", async ({ run }) => {
		const result = await run("What is the capital of France? Reply with only the city name.");
		expect(result.output).toBe("Paris");
	});
});
```

### 配置 Pi harness

`createPiCodingAgentHarness(...)` 接受：

- `name`：用于报告和比较的稳定 harness 标识。
- `model`：可选的 `{ provider, id }` 选择。它会覆盖 runner 的默认模型。
- `noTools`：Pi 的工具禁用配置。
- `transformSystemPrompt`：在 eval 开始前转换完整的默认 prompt。
- `output`：把最终响应和 `AgentSession` 转换为 JSON 安全的领域结果。

显式选择模型可以让模型比较 harness 不依赖 runner 默认值：

```ts
const harness = createPiCodingAgentHarness({
	name: "claude-opus-4-6",
	model: { provider: "anthropic", id: "claude-opus-4-6" },
});
```

一次 run 可以接受单个 prompt，也可以接受 prompt 和 reload 步骤序列。当前一个 prompt 创建或修改 Pi 资源时，reload 步骤很有用：

```ts
const result = await run([
	{ type: "prompt", content: "Create a Pi extension." },
	{ type: "reload" },
	{ type: "prompt", content: "Use the extension." },
]);
```

### 转换 harness 输出

使用 `output` 暴露场景专用、JSON 安全的行为，而不必把这些行为加入通用 Pi adapter：

```ts
const harness = createPiCodingAgentHarness({
	output: ({ response, session }) => ({
		response,
		activeTools: session.getActiveToolNames(),
		extensionErrors: session.resourceLoader.getExtensions().errors,
	}),
});
```

在 `result.output` 上断言应用行为。在 `result.session` 上断言模型和工具 trace，可使用 `vitest-evals` 的 helper，例如 `toolCalls(...)`。

### 编写对比 eval 集合

使用 `evalHarnessTable(...)` 和 Vitest 原生的 `describe.for(...)`，把相同输入跑在多个 harness 上。Harness 可以在 prompt、工具、skill、模型或任何其他 Pi 配置上不同：

```ts
import { describe } from "vitest";
import { createJudge, describeEval } from "vitest-evals";
import { evalHarnessTable } from "./vitest-evals/harness-table.ts";

const TargetTaskJudge = createJudge<string, string>("TargetTaskJudge", ({ output }) => ({
	score: output === "expected result" ? 1 : 0,
}));

const harnessTable = evalHarnessTable(
	"target skill effectiveness",
	{
		baseline: withoutTargetSkillHarness,
		candidate: withTargetSkillHarness,
		repetitions: 6,
	},
);

describe.for(harnessTable)("$name repetition $repetition", ({ harness }) => {
	describeEval("target skill effectiveness", { harness, judges: [TargetTaskJudge], judgeThreshold: null }, (it) => {
		it("completes the target task", async ({ run }) => {
			await run("Complete the target task.");
		});
	});
});
```

对比 suite 应使用确定性 judge 或模型驱动 judge 记录正确性，并设置 `judgeThreshold: null`。这样低分会作为观察结果保留，而不是让 Vitest 调用失败。硬断言只应当用于 suite 不变量和基础设施契约。`expect.soft(...)` 仍然会让测试失败，它不是评分机制。

Pi harness 会在删除临时 workspace 前快照原生会话 JSONL。一个 eval 专用的 `afterEach` hook 会在 reporter 运行前，把该快照注册到明确的 Vitest test task 上。

Harness 名称在一个 eval 集合内必须稳定且唯一。分组 key 会把 repetition 与一个非空字符串 `input.id` 组合；如果没有 `input.id`，则使用严格规范化 JSON 输入的 SHA-256 哈希。单个处理组使用 `candidate`，多个处理组使用 `candidates`。每个 candidate 只会与声明的 baseline 比较。
对于每个匹配的输入和 repetition，reporter 会根据每次 run 记录的平均 judge score 计算通过率提升，并把至少为 `1` 的 score 视为通过。提升值是 candidate 通过率减去 baseline 通过率，单位是百分点。缺失的 judge score 会报告为不完整观察。Token、延迟和预估成本会作为独立的 candidate-minus-baseline 成对差值保留；缺失的遥测数据仍会标记为不可用。如果需要执行顺序随机化，请使用 Vitest 内置的 sequence shuffling。

关于对比 eval 方法论、重复策略、可信 judge 和遥测解读，请参考 [`skill-eval-harness`](https://github.com/adewale/skill-eval-harness/) 指南。
