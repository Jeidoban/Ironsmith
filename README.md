<p align="center">
  <img src="assets/readme/app-icon-rounded.png" alt="Ironsmith app icon" width="128" height="128">
</p>

<h1 align="center">Ironsmith</h1>

[Ironsmith](https://ironsmith.app) is a free, open-source macOS menu bar app for making small, personal Mac apps with AI. Describe what you want, and Ironsmith generates, builds, and saves a native SwiftUI app you can launch, edit, and export to your Applications folder.

<br>

<p align="center">
  <img src="assets/readme/all-apps.png" alt="Several generated Mac apps with the Ironsmith menu bar popover open in front.">
</p>

## What It Does

- **Builds real Mac apps.** Generated apps are native Swift and SwiftUI apps that you can create, run, edit, and export from the menu bar.
- **Works with local AI.** Ironsmith was designed with local AI support in mind, and has Ollama support out of the box. You can also connect any OpenAI compatible API, so LM Studio and Llama.cpp work great too.
- **Supports hosted models too.** Bring your own API keys for OpenAI, Anthropic, and Gemini, log in or skip the API key and sign into Ironsmith to access them immediately. Using your existing ChatGPT login is also supported.
- **Offers specialized coding agents.** Choose Ironsmith's in-house agents for tiny macOS apps or OpenAI's Codex for more complex projects.
- **Doesn't require Xcode.** Every generated app is a Swift package and is built entirely with the lightweight Xcode command line tools rather than full Xcode. In fact Ironsmith itself doesn't even use Xcode!
- **Sandboxes every app by default.** Generated apps are built as signed app bundles with sandboxing and hardened runtime enabled, greatly reducing the impact of bugs, mistakes, or malicious behavior. Sensitive permissions such as camera and microphone access must also be explicitly enabled. However, you can disable these protections, and if you do, it’s highly recommended that you review the code before running it.

## Examples

Ironsmith works best for focused utilities: the small apps you wish existed but wouldn't want to hunt down or build yourself. That said, with more capable models like GPT‑5.6 Sol or Fable 5, you can create some surprisingly sophisticated apps.

| Synthesizer | Painting App | HEIF Converter |
| --- | --- | --- |
| <img src="assets/readme/synthesizer.png" alt="Synthesizer generated with Ironsmith." width="280"> | <img src="assets/readme/drawing-tools.png" alt="Painting app generated with Ironsmith." width="280"> | <img src="assets/readme/heif-converter.png" alt="HEIF converter generated with Ironsmith." width="280"> |

| SVG Editor | Notepad | Network Visualizer |
| --- | --- | --- |
| <img src="assets/readme/svg-editor.png" alt="SVG editor generated with Ironsmith." width="280"> | <img src="assets/readme/notepad.png" alt="Notepad generated with Ironsmith." width="280"> | <img src="assets/readme/network-visualizer.png" alt="Network visualizer generated with Ironsmith." width="280"> |

Some examples of prompts you can try:

- "Make a utility that renames a folder of screenshots by date and window title."
- "Build a tiny app that splits a PDF into one file per page."
- "Build a clipboard cleaner that strips tracking parameters from copied URLs."
- "Make a small CSV inspector that highlights duplicate rows and missing values."

## Install

Download the latest Ironsmith build from [GitHub Releases](https://github.com/Jeidoban/Ironsmith/releases/latest) or [the website](https://ironsmith.app).

Ironsmith requires macOS 26 or newer and supports both Intel and Apple Silicon Macs. Make sure Apple Intelligence is enabled where available; Ironsmith uses it to create app icons and provide the built-in Foundation Model.

On first launch, Ironsmith checks for the Xcode Command Line Tools as generated apps are compiled locally. If they are missing, macOS will prompt you to install them. You can also install them manually:

```sh
xcode-select --install
```

## Develop

Development requires macOS 26 or newer and the Xcode Command Line Tools. Xcode itself is not required.

Build the development app:

```sh
script/build.sh
```

Build and run the development app:

```sh
script/build.sh run
```

Run tests:

```sh
script/test.sh
```

Clean SwiftPM and script outputs:

```sh
script/clean.sh
```
Copy `Config/.env.example` to `Config/.env` and fill in `IRONSMITH_DEV_SIGN_IDENTITY` with your Apple Development ID to avoid repeated keychain asks when running new builds.

## Contribute

Issues and pull requests are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md) for the local workflow and PR expectations.

## License

Ironsmith is licensed under the [GNU General Public License v3.0](LICENSE).

## OpenAI Build Week instructions

To use, make sure you are on macOS 26, preferably an Apple silicon Mac. The Xcode command line tools are needed, but Ironsmith will walk you through installing those.
After that, I recommend logging in with your ChatGPT account, but you can also use an API key or use Claude, Gemini, or any OpenAI compatible API you want. 
The onboarding screen should give you the option to log in with your ChatGPT account in the third option, but if you don't see it, 
Go to settings, click the plus button next to providers, and select OpenAI. Then click the signin button to sign in with your ChatGPT account.

After you're signed in, ask for whatever app you want using whatever model you'd like. I recommend GPT 5.6 Sol on High reasoning.

To test features added during build week, try adding an image. You can drag and drop or add one manually. OpenAI models default to codex as the coding agent, but feel free to give
Flame a try too. Its pretty token efficient for smaller apps and uses about 1/2 - 2/3 the usage of Codex. Try the new apps list view as well. In
the hamburger menu on the top right of the popover, you should have an option to change the view.

### Using 5.6 Sol

The entirety of Icon generation, image input, Spark improvements, the new apps list view, and adding the 5.6 models themselves to Ironsmith was supercharged by 5.6 Sol.
For example when testing the new 5.6 Luna model, I found that most calls it made to the responses endpoint were failing even though I hadn't changed anything. 
I used 5.6 Sol Ultra mode to diagnose the issue, and it searched through the actual Codex binary and found that these models make use of a [new responses lite endpoint shape](https://github.com/Jeidoban/Ironsmith/blob/main/Ironsmith/Core/Inference/Providers/OpenAICodexLanguageModel.swift) for their requests and figured out what to change.
It solved a problems that would have taken hours to days to research, and it did it in 20 minutes.

It also helped greatly in helping me improve the Spark agent. Previously both Flame and Spark made use of Aider style search and replace for repairing code. However I kept finding small models
like Gemma 4 E2B kept messing up that syntax, and instead reverted to using unified diffs. So to play to small models strengths I had 5.6 Sol [write a new unified diff parser](https://github.com/Jeidoban/Ironsmith/blob/main/Ironsmith/Core/AgentPipeline/ContentRepair/ContentViewRepairDiffApplier.swift) so small models 
can more easily repair the code, and it worked like a charm. I've had much better success rates in having small models correctly repair their code.
