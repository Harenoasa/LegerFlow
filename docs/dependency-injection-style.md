# 依赖注入风格：构造器注入 vs 注解字段注入

> 记录于 2026-11-04。结论：项目当前采用 `@Resource` 字段注入；构造器注入是通用最佳实践，但不是强制要求。

## 1. 结论

- **通用建议**：优先构造器注入（`private final` 字段 + 构造器，或 Lombok `@RequiredArgsConstructor`），依赖更显式、对象不可变、测试更方便。
- **本项目选择**：`@Resource` 字段注入。`CreateService` 依赖较多，构造器很长；当前每个类型只有一个实现，字段注入更简洁；项目也还没有大量脱离 Spring 的单元测试。
- **如果只在 `@Resource` 和 `@Autowired` 里选**：选 `@Resource`。它是 Jakarta 标准注解，默认按字段名匹配 bean，在多实现场景下比 `@Autowired` 少写 `@Qualifier`。
- **例外**：`SnowflakeIdGenerator` 的构造器注入的是 `@Value` 配置值，不是 Spring bean，保留构造器注入以便在构造时校验 `workerId` / `datacenterId` 范围。

## 2. 两种方式对比

| 维度 | 构造器注入 | 字段注入 |
|---|---|---|
| 依赖是否显式 | 构造器签名一眼看全 | 分散在字段上，需要往下翻 |
| 不可变 | 可以使用 `final` | 不能使用 `final` |
| 缺依赖 | 启动时即失败 | 可能运行到方法里才 NPE |
| 单元测试 | `new Service(mock...)` 即可 | 需要 Spring 容器或反射 |
| 循环依赖 | 更容易暴露设计问题 | 可能被容器悄悄解决 |
| 样板代码 | 依赖多时构造器很长 | 一个注解一行，简洁 |

## 3. 为什么通常推荐构造器注入

推荐 final / 构造器注入，核心是三个收益：

1. **依赖显式化**：看到构造器就知道这个类依赖什么，不需要在类里找 `@Resource` 字段。
2. **不可变与 fail-fast**：依赖在构造完成后不能替换；缺少 bean 时启动失败，而不是运行到业务方法才报空指针。
3. **可测试性**：不启动 Spring 也能直接 `new` 出对象并传入 mock，测试更快、更独立。

这些是通用工程实践，不是“必须遵守”的语法规则。

## 4. 什么时候字段注入更合适

- 依赖很多，构造器参数列表过长；
- 每个接口只有一个实现，不存在按类型注入的歧义；
- 团队更看重代码简洁和统一风格；
- 当前没有大量纯单元测试，构造器注入的最大优势暂时用不上；
- 团队更看重风格一致性时，字段注入也是可接受的工程选择。

## 5. 本项目的具体选择

现有代码统一使用 `@Resource` 字段注入：

```java
@Service
public class CreateService {

    @Resource
    private OrdersMapper ordersMapper;

    @Resource
    private OrderNoGenerator orderNoGenerator;

    // ...
}
```

控制器和服务同样使用字段注入。`SnowflakeIdGenerator` 保留 `@Value` 构造器，因为它注入的是配置值而不是 bean：

```java
public SnowflakeIdGenerator(
        @Value("${ledgerflow.snowflake.worker-id:0}") long workerId,
        @Value("${ledgerflow.snowflake.datacenter-id:0}") long datacenterId) {
    // 构造时校验取值范围
}
```

## 6. 以后什么时候可以再评估

- 开始写大量不启动 Spring 的单元测试；
- 出现同一接口的多个实现，需要明确选择；
- 出现循环依赖，需要靠构造器暴露设计问题；
- 依赖数量减少，构造器不再冗长。

如果只是不喜欢手写构造器，可以保留 `final` 字段并使用 Lombok：

```java
@Service
@RequiredArgsConstructor
public class CreateService {

    private final OrdersMapper ordersMapper;
    private final OrderNoGenerator orderNoGenerator;

    // 不用手写构造器
}
```

这样既保留构造器注入的优点，也没有样板代码。
