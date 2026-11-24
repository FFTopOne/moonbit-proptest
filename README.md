# moonbit-proptest

给 MoonBit 的**整合式收缩**（integrated shrinking）属性测试与状态机测试库。

生成器不返回裸值，而是返回「值 + 它的完整收缩树」。因此失败时得到的不是"某次随机抽到的输入"，而是**能复现、可重放、已最小化**的反例。

```moonbit
test "每次拼接都会让长度加一" {
  let outcome = @prop.check(
    @gen.string(),
    text => (text + "x").length() == text.length() + 1,
  )
  match outcome {
    @prop.Falsified(counterexample~, ..) =>
      abort("反例: \{counterexample}")
    _ => ()
  }
}
```

失败时的输出长这样（真机运行，非示意）：

```
FAILED after 76 cases (0 discarded)
  counterexample : [1, 0]
  replay         : seed=0x9e2f1b7b404f802a size=2 path=[3, 3, 5, 5, 7, 3, 3, 3, 3, 3]
  shrinking      : 10 steps over 51 candidates (locally minimal)
```

`seed` + `size` + `path` 三件套足以把这个反例**从零重算出来**，不依赖任何保存下来的 fixture。

---

## 为什么要再写一个

MoonBit 标准库已有 `moonbitlang/core/quickcheck`，提供 `Generator` / `Arbitrary` / `Shrink` / `check`。本项目**不取代它**，而是补它架构上够不到的那部分。

它的 `Generator[T]` 签名是 `(Int32, RandomState) -> T` —— **只产出值**。收缩由独立的 `Shrink` trait 按类型完成。这个设计有个绕不过去的后果：

> 收缩时只能看到「最终的 T」，看不到「这个 T 是怎么被生成的」。

于是 `flat_map`（依赖式生成）无法正确收缩。举例：先生成数组长度 `n`，再生成恰好 `n` 个元素。收缩时拿到的是那个数组本身，按类型只能删元素或把元素改小，**没法把"长度"这个上游决策改小**。

整合式收缩把收缩树在生成时就地建出来，`flat_map` 在收缩外层值时**重新派生内层生成器**，于是长度和内容一起收缩，且永远满足生成器自己的约束。

| | `core/quickcheck` | 本项目 |
|---|---|---|
| 生成器返回 | 仅值 `(size, rng) -> T` | 值 + 收缩树 `(size, rng) -> Tree[T]?` |
| 收缩依据 | 独立 `Shrink` trait，按类型 | 生成时的结构（整合式） |
| 依赖式生成收缩 | 收缩不到决定形状的上游值 | `flat_map` 重新派生，上游值一起收缩 |
| 失败复现 | 种子 | 种子 + size + 收缩路径，O(1) 重放 |
| 生成器主动拒绝 | 无（`check` 只有属性侧 `filter`） | `None` = discard，带放弃率上限 |
| 状态机 / 序列测试 | 无 | `stateful.Machine`，序列可收缩 |
| 收缩过程可观测 | 无 | `Tree::shape` / `Tree::size_upto` |

---

## 包结构

| 包 | 职责 |
|---|---|
| `rng` | 自足的可分裂 PRNG（SplitMix64 流 + MurmurHash3 终结器），零依赖 |
| `tree` | 惰性玫瑰树。子节点藏在闭包里，不遍历就不构造 |
| `gen` | 生成器与组合子：`map` / `flat_map` / `filter` / `one_of` / `array_of` / … |
| `shrink` | 贪心搜索，把失败的收缩树压到局部最小 |
| `prop` | 调度、报告、重放（`Config` / `Outcome` / `Replay`） |
| `stateful` | 基于模型的命令序列测试 |
| `examples` | 三个注入缺陷的算法 + 精确到最小反例的断言 |

依赖方向严格单向：`rng → tree → gen → shrink → prop`，`stateful` 与 `examples` 在最上层。

---

## 三个关键设计决定

**1. 子节点是 thunk，不是数组。**
收缩树的分支因子是每层相乘的，而搜索只走一条路径。提前展开会把 2 秒的测试变成挂死。`tree` 测试里有个计数器专门钉住这一点：不调用 `children()` 就不允许构造。

**2. 生成器可以拒绝。**
`run` 返回 `Tree[T]?`。`None` 表示这次抽不出合法值（比如 `filter` 的谓词太紧），跑器把它计为 discard，而不是伪装成一次通过或一次失败。整轮一个有效样本都没抽到时返回 `GaveUp` —— **一次没判断过的运行不能报绿**。

**3. 重放记录的是派生结果，不是配置。**
`Replay` 存 `case_seed` / `size` / `path`，不存 base seed 和 count。所以别人把 `count` 从 100 调到 500 之后，旧反例照样能重放。路径失效时返回 `None`，而不是悄悄给一个当前代码已经产生不了的值。

---

## 证据：它真的能抓 bug

`examples` 里是三个**只改一行**的正确算法（mutant），外加每个必须收缩到的最小反例断言。断言精确到值，不是"非空"。

| 注入的缺陷 | 属性 | 最小反例 |
|---|---|---|
| 插入排序内层循环写成 `j >= 1`，下标 0 被冻住 | 结果有序 | `[1, 0]` |
| RLE 编码 `if count > 1`，单次出现的元素被丢掉 | `decode(encode(xs)) == xs` | `[0]` |
| 字符串反转跳过奇数长度的中间字符 | `rev(rev(s)) == s` | `" "` |

跑 `moon run cmd/main` 可以看到完整报告。

另外 `stateful` 里有个"减到负数"的计数器：模型说 0 减 1 还是 0，实现没有守卫。随机生成的 20 条命令，收缩后报出的是**单条 `Decrement`** —— 这就是序列收缩的意义。

对照组也写了：把 mutant 换回正确实现，同一个属性必须通过。否则失败可能来自属性本身写错，而不是被测代码。

---

## 快速开始

```bash
# 依赖：MoonBit 工具链 + git
# Windows
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser; irm https://cli.moonbitlang.cn/install/powershell.ps1 | iex
# Linux / macOS
curl -fsSL https://cli.moonbitlang.cn/install/unix.sh | bash

moon version --all
moon test                # 54 个测试
moon run cmd/main        # 缺陷演示报告
```

在 `moon.mod` 里加依赖后：

```moonbit
import {
  "moonbit-community/moonbit-proptest/gen" @gen,
  "moonbit-community/moonbit-proptest/prop" @prop,
}
```

### 基本信息

```moonbit
// 布尔属性
let outcome = @prop.check(@gen.int_range(0, 100), x => x >= 0)

// 断言属性：断言抛错即失败，收缩到仍然抛错的最小输入
let outcome = @prop.check_raise(
  @gen.int_range(0, 50),
  x => if x > 3 { assert_eq(x, 3) },
)

// 配置
@prop.Config::new(count=300, max_size=100, seed=0x5EED2026UL)
```

### 重放

```moonbit
match outcome {
  @prop.Falsified(counterexample~, ..) => {
    let record = outcome.to_replay().unwrap()
    // 从种子和路径重算出同一个反例，不信任存下来的那个值
    assert_eq(@prop.replay(generator, record).unwrap(), counterexample)
  }
  _ => ()
}
```

### 状态机

```moonbit
let machine = @stateful.Machine::new(
  initial=0,
  reset=fn() { cell[0] = 0 },
  generate=fn(state) { /* 依据模型状态生成合法命令 */ },
  apply=fn(state, cmd) { /* 推演模型 */ },
  execute=fn(cmd) { /* 打到真实系统 */ },
  verify=fn(state) { /* 模型与真实系统比对 */ },
)
let outcome = @stateful.check_machine(machine, config=@prop.Config::new(count=200))
```

命令用 `flat_map` 链式派生，所以收缩时删除或简化任意一条命令，后面的命令会依据新模型状态重新生成 —— 序列始终内部自洽，不会退化成"生成器根本产不出"的前缀。

---

## API 速览

**生成器** `@gen`
`bool` `int` `int_range` `char` `string`
`Gen::pure` `Gen::reject` `Gen::map` `Gen::flat_map` `Gen::zip_with` `Gen::filter`
`Gen::sized` `Gen::resize` `Gen::scale`
`one_of` `frequency`
`Gen::array_of` `Gen::array_with_size` `Gen::option_of` `Gen::result_of`
`Gen::sample` `Gen::samples`

**跑器** `@prop`
`Config::new` `check` `check_raise` `replay` `Outcome::to_replay`
`Outcome::describe` `Outcome::describe_with_debug`

**树** `@tree`
`Tree::singleton` `Tree::node` `Tree::lazy_node` `Tree::children`
`Tree::map` `Tree::zip_with` `Tree::filter` `Tree::unfold`
`Tree::follow` `Tree::size_upto` `Tree::shape`

---

## 已知边界

诚实写在这里，因为踩到它们的人应该提前知道。

- **收缩是局部最小，不是全局最小。** 贪心只保证"任何一个直接子节点都不会再失败"。全局最小在无限树上不可判定，Hedgehog / Hypothesis 也都是这个取舍。
- **`filter` 可能丢失收缩空间。** 若某个节点的所有直接子节点都违反谓词，它就成了叶子，收缩到此为止。硬约束优先用 `map` / `flat_map` 结构化表达，`filter` 只用于宽松约束。
- **`filter` 会重试，重试耗尽则整轮 discard。** 谓词太紧时返回 `GaveUp`，不会报一个假失败。
- **序列收缩是逐条简化，不做块级重排。** 对偶发竞态类的缺陷，需要更长的序列才有机会命中。
- **尚未实现**：覆盖率引导的模糊测试、收缩统计的自动化门禁（`collect` / `classify` 风格的分布断言）。

---

## 许可

Apache-2.0。RNG 的混合函数是 SplitMix / MurmurHash3 的公开算法；`core/quickcheck` 的设计取舍在 `docs/DESIGN.md` 中有对比说明，代码独立实现。
