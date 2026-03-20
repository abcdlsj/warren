---
name: Build for iOS and macOS
tagline: Use Codex to scaffold, build, and debug SwiftUI apps for iOS and macOS.
summary: Use Codex to scaffold SwiftUI projects, keep the build loop CLI-first
  with `xcodebuild` or Tuist, and add XcodeBuildMCP or focused SwiftUI skills
  when the work gets deeper.
skills:
  - token: build-ios-apps
    url: https://github.com/openai/plugins/tree/main/plugins/build-ios-apps
    description: Build or refactor SwiftUI UI, adopt modern iOS patterns such as
      Liquid Glass, audit runtime performance, and debug apps on simulators with
      XcodeBuildMCP-backed workflows.
bestFor:
  - Greenfield SwiftUI apps where you want Codex to scaffold the app and build
    loop from scratch
  - Existing Apple-platform projects where Codex needs schemes, simulator
    output, screenshots, or UI automation before the work is done
  - Teams that want long-running native UI tasks to stay agentic and CLI-first
    instead of depending on the Xcode GUI
starterPrompt:
  title: Scaffold the App and Build Loop
  body: >-
    Scaffold a starter SwiftUI app and add a build-and-launch script I can wire
    to a `Build` action in my local environment.


    Constraints:

    - Stay CLI-first. Prefer Apple's `xcodebuild`; if a cleaner setup helps,
    it's okay to use Tuist.

    - If this repo already contains a full Xcode project, use XcodeBuildMCP to
    list targets, pick the right scheme, build, launch, and capture screenshots
    while you iterate.

    - Reuse existing models, navigation patterns, and shared utilities when they
    already exist.

    - Keep iOS and macOS compatibility intact unless I explicitly scope the work
    to one platform.

    - Use a small trustworthy validation loop after each change, then expand to
    broader builds only when the narrower check passes.

    - Tell me whether you treated this as a greenfield scaffold or an
    existing-project change.


    Deliver:

    - the app scaffold or requested feature slice

    - a small build-and-launch script with the exact commands

    - the smallest relevant validation steps you ran

    - the exact scheme, simulator, and checks you used
relatedLinks:
  - label: Model Context Protocol
    url: /codex/mcp
  - label: Agent skills
    url: /codex/skills
techStack:
  - need: UI framework
    goodDefault: "[SwiftUI](https://developer.apple.com/xcode/swiftui/)"
    why: The fastest way to prototype views, navigation, and shared state across
      Apple platforms while keeping the UI code readable.
  - need: Build tooling
    goodDefault: xcodebuild or [Tuist](https://docs.tuist.dev/)
    why: Both keep the native build loop in the terminal instead of depending on the
      Xcode GUI.
  - need: Project automation
    goodDefault: "[XcodeBuildMCP](https://www.xcodebuildmcp.com/)"
    why: A strong option once you need Codex to inspect schemes and targets, launch
      the app, capture screenshots, and keep iterating without leaving the
      agentic loop.
  - need: Distribution tooling
    goodDefault: "[App Store Connect CLI](https://asccli.sh/)"
    why: Keep your agent fully in the loop and send your app build directly to the
      App Store.
---

## Scaffold the app and build loop

For greenfield work, start with plain prompting. Ask Codex to scaffold a starter SwiftUI app and write a small build-and-launch script you can wire to a `Build` action in a [local environment](https://developers.openai.com/codex/app/local-environments).

Keep the loop CLI-first. Apple's `xcodebuild` can list schemes and handle build, test, archive, `build-for-testing`, and `test-without-building` actions from the terminal, which lets Codex stay in an agentic loop instead of bouncing into the Xcode GUI.

If you want a cleaner project generator and you're comfortable with third-party tooling, [Tuist](https://tuist.dev/) is a good next step. It can generate and build Xcode projects without needing the GUI, while still letting Codex build and launch the app from the terminal.

Use [XcodeBuildMCP](https://www.xcodebuildmcp.com/) once you're inside a full Xcode project and need deeper automation. That's when schemes, targets, simulator control, screenshots, logs, and UI interaction matter enough that plain shell commands stop being the whole story.

## Leverage skills

For the first pass, you often don't need a skill or MCP server. Add skills once the work gets specialized or you want stronger SwiftUI conventions baked into the run.

- [SwiftUI expert](https://github.com/AvdLee/SwiftUI-Agent-Skill) is a strong general-purpose SwiftUI skill with a lot of best practices already baked in.
- [SwiftUI Pro](https://github.com/twostraws/SwiftUI-Agent-Skill/blob/main/swiftui-pro/SKILL.md) is a broad SwiftUI review skill for modern APIs, maintainability, accessibility, and performance.

- [Liquid glass expert](https://github.com/Dimillian/Skills/blob/main/swiftui-liquid-glass/SKILL.md) allows the agent to understand how the new iOS and macOS 26 Liquid Glass API work and fix your components so they look good on the latest versions
- [SwiftUI performance](https://github.com/Dimillian/Skills/blob/main/swiftui-performance-audit/SKILL.md) is a great skill to use almost anytime you have a performance issue or doubt about some code as it will scan for the most common SwiftUI mistakes humans or agents make and produce a report with a priority list of what to fix and where the biggest gains are.
- [Swift concurrency expert](https://github.com/Dimillian/Skills/blob/main/swift-concurrency-expert/SKILL.md) helps when cryptic errors and compiler warnings start fighting the change you want to make. On GPT-5.4, you may need it less often, but it's still useful when Swift concurrency diagnostics get noisy.
- [SwiftUI view refactor](https://github.com/Dimillian/Skills/blob/main/swiftui-view-refactor/SKILL.md) helps keep files smaller and make SwiftUI code more consistent across the repo.
- [SwiftUI patterns](https://github.com/Dimillian/Skills/blob/main/swiftui-ui-patterns/SKILL.md) helps reach for predictable `@Observable` and `@Environment` architecture patterns as the app grows.

To learn more about how to install and use skills, see our [skills documentation](https://developers.openai.com/codex/skills).

## Iterate

Once you have a first pass working, or if you're starting from an existing project, you can start iterating on the UI or behavior.

For this part, be specific about what you want to change and how you want to change it.

Make that prompting layer explicit: tell Codex whether it's working in a greenfield repo or an existing Xcode project, which platforms must keep working, and what validation loop you expect.

### Example prompt

For example, if you want to add a feature to an existing app, you can ask Codex for a change like this:

## Practical tips

### Start with basics

Start with plain prompting for greenfield work. Ask Codex to scaffold a starter SwiftUI app and write a small build-and-launch script you can wire to a `Build` action in a [local environment](https://developers.openai.com/codex/app/local-environments). For that first pass, you often don't need any skill or MCP server.

### Use a small trustworthy validation loop

Tell Codex to run after each change the narrowest command that actually proves the contract you touched. Expand to broader builds later. This keeps Codex fast without pretending a full app build is required for every edit.

### Keep the loop CLI-first

Keep the loop CLI-first. Apple's `xcodebuild` tool can list schemes and run build, test, archive, `build-for-testing`, and `test-without-building` actions from the terminal, which lets Codex stay in an agentic loop instead of bouncing into the Xcode GUI.

### Leverage XcodeBuildMCP

Use XcodeBuildMCP as soon as you are inside a full Xcode project and need deeper automation. That's the point where schemes, targets, simulator control, screenshots, logs, and UI interaction matter enough that plain shell commands stop being the whole story.
